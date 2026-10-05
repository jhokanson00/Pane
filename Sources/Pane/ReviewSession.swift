import AVFoundation
import Combine
import SwiftUI
import PaneKit

/// The state behind one review window: the recording, its blur layers, pointer effects,
/// and export.
@MainActor
final class ReviewSession: ObservableObject, Identifiable {
    enum ExportState: Equatable {
        case idle
        case exporting(Double)
        case done(URL)
        /// The files for Final Cut are in this folder, and Final Cut is importing them.
        case sentToFinalCut(URL)
        case failed(String)
    }

    enum Tool: Equatable {
        case none
        /// Drag on the video to draw a box.
        case drawBox
        /// Drag on the video to draw a circle (an oval filling the drag).
        case drawCircle
        /// Click a word in the video to blur it everywhere.
        case pickText

        var isDrawing: Bool { self == .drawBox || self == .drawCircle }
    }

    let id = UUID()
    let sourceURL: URL
    let player: AVPlayer
    let videoSize: CGSize
    let duration: Double

    @Published var findings: [Finding] {
        didSet {
            preview.findings = findings
            refreshPausedFrame()
        }
    }
    /// Where the pointer went, for recordings Pane made. Clicks can be turned off one by one.
    @Published var pointer: PointerTrack? {
        didSet { updatePointerEffects() }
    }
    @Published var pointerStyle: PointerEffectStyle {
        didSet {
            if let data = try? JSONEncoder().encode(pointerStyle) {
                UserDefaults.standard.set(data, forKey: "pointerStyle")
            }
            updatePointerEffects()
        }
    }
    /// The keyboard shortcuts pressed, for recordings made with them on.
    let shortcuts: ShortcutTrack?
    @Published var showShortcuts: Bool {
        didSet {
            ShortcutBadgeRenderer.shownInExports = showShortcuts
            updatePointerEffects()
        }
    }
    @Published var currentTime: Double = 0
    @Published var tool: Tool = .none {
        didSet {
            if (tool == .none) != (oldValue == .none) { updatePointerEffects() }
        }
    }
    /// The zoom toward clicks shown in the preview, so outlines drawn over the video
    /// can follow it.
    @Published private(set) var previewZoom: ClickZoom?
    @Published var exportState: ExportState = .idle
    /// The export in progress is for Final Cut.
    @Published private(set) var isSendingToFinalCut = false
    @Published var notice: String?
    /// The part of the recording to keep, in seconds; nil keeps it all. Export Video cuts
    /// the rest off, and Send to Final Cut trims the clips. Only for this window.
    @Published var trim: ClosedRange<Double>?
    /// Captions made from the narration (see ReviewCaptions.swift).
    @Published var captions: Captions? {
        didSet { updatePointerEffects() }
    }
    @Published var burnCaptions = false {
        didSet { updatePointerEffects() }
    }
    @Published var captionState: CaptionState = .idle
    var captionTask: Task<Void, Never>?
    /// The narration's words with their times, from speech recognition, once heard.
    /// Captions and retakes share them (see ReviewRetakes.swift).
    @Published var spokenWords: [CaptionWord]?
    /// The teleprompter script the recording was made with, if it was.
    let script: PrompterScript?
    /// Sentences said again, each cut from exports unless kept.
    @Published var retakes: [RetakeCut] = [] {
        didSet { updateCuts() }
    }
    /// How loud the narration is, every 10 ms, for placing cuts in the silence.
    var audioLevels: AudioLevels?
    /// How much of the silence before each retake is kept, so it doesn't start abruptly.
    @Published var cutPause: CutEdges.Pause = .saved {
        didSet {
            UserDefaults.standard.set(cutPause.rawValue, forKey: CutEdges.Pause.key)
            updateCuts()
        }
    }
    /// The parts left out of exports and the preview: the cut retakes, placed in the
    /// silence around them (see `updateCuts` in ReviewRetakes.swift).
    @Published var cuts: [ClosedRange<Double>] = [] {
        didSet {
            guard cuts != oldValue else { return }
            updatePointerEffects()
            rebuildPreview()
        }
    }
    @Published var retakeState: RetakeState = .idle
    var retakeTask: Task<Void, Never>?

    /// What the text scan read, once the recording has been scanned. Blur Text needs it.
    @Published private(set) var scan: ScanResult?
    private let preview = PreviewLayers()
    /// What the player plays: the recording less the cuts, as exported. Everything else
    /// here works in the recording's own time (see `seek` and `currentTime`).
    private var previewEdit = VideoEdit()
    private var previewTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var exportTask: Task<Void, Never>?
    private var pointerSwitch: AnyCancellable?

    init(sourceURL: URL, scan: ScanResult?, videoSize: CGSize, duration: Double) {
        self.sourceURL = sourceURL
        self.scan = scan
        self.findings = scan?.findings ?? []
        self.videoSize = videoSize
        self.duration = duration
        let pointer = PointerTrack.load(from: sourceURL)
        let pointerStyle = PointerEffectStyle.saved
        self.pointer = pointer
        self.pointerStyle = pointerStyle
        shortcuts = ShortcutTrack.load(from: sourceURL)
        showShortcuts = ShortcutBadgeRenderer.shownInExports
        script = PrompterScript.load(from: sourceURL).map(PrompterScript.init)

        // The player shows the same blur and pointer effects the export will write.
        let item = AVPlayerItem(url: sourceURL)
        preview.findings = scan?.findings ?? []
        self.player = AVPlayer(playerItem: item)
        updatePointerEffects()
        Task { [preview] in
            item.videoComposition = await Self.videoComposition(for: item.asset, preview: preview, edit: VideoEdit(),
                                                                duration: duration)
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = self.previewEdit.sourceTime(time.seconds, duration: self.duration)
            }
        }
        // The Pointer effects switch, in settings or here, applies right away. (It sends
        // the new value before the setting itself changes.)
        pointerSwitch = RecorderModel.shared.$pointerEffects.dropFirst().sink { [weak self] on in
            MainActor.assumeIsolated { self?.updatePointerEffects(enabled: on) }
        }
        // A recording made with the teleprompter: look for retakes straight away.
        if script != nil { findRetakes() }
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        exportTask?.cancel()
        captionTask?.cancel()
        retakeTask?.cancel()
        previewTask?.cancel()
    }

    var destinationURL: URL { Self.editedURL(for: sourceURL) }

    /// Where the copy with blurs and pointer effects goes: next to the recording.
    static func editedURL(for source: URL) -> URL {
        let name = source.deletingPathExtension().lastPathComponent + " (Edited)"
        return source.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("mp4")
    }

    // MARK: - Layers

    // MARK: - Pointer

    /// - Parameter enabled: The Pointer effects switch; nil reads it.
    private func updatePointerEffects(enabled: Bool? = nil) {
        // While drawing on the video, the preview isn't zoomed, so what you draw lands
        // where you see it.
        let effects = frameEffects(pointerEffects: enabled, zoom: tool == .none)
        preview.effects = effects
        previewZoom = effects.lazy.compactMap { ($0 as? ClickZoomEffect)?.zoom }.first
        refreshPausedFrame()
    }

    /// Everything drawn over the video after the blurs, in order. Preview, export and
    /// Send to Final Cut all use this, so they match. Add new effects here.
    /// - Parameters:
    ///   - pointerEffects: The Pointer effects switch; nil reads it.
    ///   - cameraSeparate: The camera is its own layer (Send to Final Cut), so nothing
    ///     needs to stay clear of where it was.
    ///   - zoom: Zoom toward clicks, when the style asks for it.
    func frameEffects(pointerEffects: Bool? = nil, cameraSeparate: Bool = false, zoom: Bool = true) -> [any FrameEffect] {
        var effects: [any FrameEffect] = []
        if pointerEffects ?? RecorderModel.shared.pointerEffects, var track = pointer {
            if cameraSeparate { track.cameraCircle = nil }
            if let renderer = PointerRenderer(track: track, style: pointerStyle, videoSize: videoSize) {
                effects.append(renderer)
            }
            // After the pointer effects, so they grow with the picture.
            if zoom, let clickZoom = ClickZoomEffect(track: track, zoom: pointerStyle.zoom) {
                effects.append(clickZoom)
            }
        }
        if pointerEffects ?? RecorderModel.shared.pointerEffects, showShortcuts, var keys = shortcuts {
            if cameraSeparate { keys.cameraCircle = nil }
            // Above burned-in captions, which take the bottom center.
            let reserved = burnCaptions && captions != nil ? CaptionRenderer.reservedHeight(videoSize: videoSize) : 0
            if let badges = ShortcutBadgeRenderer(track: keys, videoSize: videoSize, reservedBottom: reserved) {
                effects.append(badges)
            }
        }
        // Last, so nothing is drawn over the captions.
        if let captions = captionEffect(cameraSeparate: cameraSeparate) { effects.append(captions) }
        return effects
    }

    /// The clicks that get a click sound in exports, with the Pointer effects switch on.
    /// The preview stays silent; only exports have the sound.
    func clickSounds() -> [PointerTrack.Click] {
        guard RecorderModel.shared.pointerEffects, let pointer else { return [] }
        return pointer.clickSounds(style: pointerStyle)
    }

    func setAllClicks(enabled: Bool) {
        guard pointer != nil else { return }
        for index in pointer!.clicks.indices { pointer!.clicks[index].isEnabled = enabled }
    }

    /// A paused player keeps showing the old frame, so redraw it with the new layers.
    private func refreshPausedFrame() {
        guard player.rate == 0, let item = player.currentItem else { return }
        item.videoComposition = item.videoComposition?.copy() as? AVVideoComposition
    }

    /// Shows `time` of the recording; inside a cut, where the cut ends.
    func seek(to time: Double) {
        let parts = previewEdit.kept(duration: duration)
        let shown = previewEdit.outputTime(time, duration: duration)
            ?? parts.first { $0.lowerBound >= time }.flatMap { previewEdit.outputTime($0.lowerBound, duration: duration) }
            ?? previewEdit.outputDuration(duration: duration)
        player.seek(to: CMTime(seconds: shown, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Preview

    /// Plays the recording without the cuts, as the export will be: kept parts played one
    /// after another, with the same short fades where they meet. Rebuilt when the cuts
    /// change, keeping the place and whether it's playing.
    private func rebuildPreview() {
        let edit = VideoEdit(cuts: cuts)
        guard edit != previewEdit else { return }
        previewTask?.cancel()
        previewTask = Task { [sourceURL, duration, preview] in
            // Clicking through several retakes rebuilds once.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let item = try? await Self.previewItem(url: sourceURL, edit: edit, duration: duration, preview: preview),
                  !Task.isCancelled else { return }
            let time = currentTime, playing = player.rate != 0
            previewEdit = edit
            player.replaceCurrentItem(with: item)
            seek(to: time)
            if playing { player.play() }
        }
    }

    /// The recording, or with cuts a composition of its kept parts.
    private static func previewItem(url: URL, edit: VideoEdit, duration: Double,
                                    preview: PreviewLayers) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let item: AVPlayerItem
        if edit.keepsAll(duration: duration) {
            item = AVPlayerItem(asset: asset)
        } else {
            let composition = AVMutableComposition()
            let parts = edit.kept(duration: duration).map {
                CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 600_000),
                            end: CMTime(seconds: $0.upperBound, preferredTimescale: 600_000))
            }
            let mix = AVMutableAudioMix()
            for track in try await asset.load(.tracks)
            where track.mediaType == .video || track.mediaType == .audio {
                guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                var at = CMTime.zero
                for part in parts {
                    try copy.insertTimeRange(part, of: track, at: at)
                    at = at + part.duration
                }
                if track.mediaType == .video {
                    copy.preferredTransform = try await track.load(.preferredTransform)
                } else {
                    mix.inputParameters.append(joinFades(for: copy, parts: parts))
                }
            }
            composition.naturalSize = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
            item = AVPlayerItem(asset: composition)
            item.audioMix = mix
        }
        item.videoComposition = await videoComposition(for: item.asset, preview: preview, edit: edit, duration: duration)
        return item
    }

    /// The export's 10 ms fades where kept parts meet (see `JoinFades`).
    private static func joinFades(for track: AVCompositionTrack, parts: [CMTimeRange]) -> AVAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let fade = CMTime(seconds: JoinFades.length, preferredTimescale: 600_000)
        var at = CMTime.zero
        for part in parts.dropLast() {
            at = at + part.duration
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: at - fade, duration: fade))
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: at, duration: fade))
        }
        return parameters
    }

    /// Draws the blurs and effects on each frame, at its time in the recording.
    private static func videoComposition(for asset: AVAsset, preview: PreviewLayers, edit: VideoEdit,
                                         duration: Double) async -> AVVideoComposition? {
        try? await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let time = edit.sourceTime(request.compositionTime.seconds, duration: duration)
            let output = Redaction.apply(to: request.sourceImage, findings: preview.findings, at: time)
            request.finish(with: preview.effects.apply(to: output, at: time), context: nil)
        }
    }

    func setAll(enabled: Bool) {
        for index in findings.indices { findings[index].isEnabled = enabled }
    }

    func remove(_ id: Finding.ID) {
        findings.removeAll { $0.id == id }
    }

    /// A box or circle you drew. It's always on, covering the whole video so nothing
    /// slips through before the moment it was drawn; narrow it by dragging its ends in the timeline.
    /// - Parameter rect: Normalized, bottom-left origin.
    func addShape(_ rect: CGRect, shape: BlurShape) {
        let name = shape == .ellipse ? "Circle" : "Box"
        findings.append(Finding(kind: .manual, text: "\(name) at \(Self.format(currentTime))",
                                samples: [BoxSample(time: currentTime, rect: rect)],
                                start: 0, end: duration, shape: shape))
        tool = .none
    }

    /// Adds what a text scan found, keeping the layers already here.
    func add(scan: ScanResult) {
        self.scan = scan
        findings += scan.findings
    }

    /// Blurs the word under `point` (normalized, bottom-left origin) everywhere it
    /// appears in the recording.
    func pickText(at point: CGPoint) {
        tool = .none
        guard let scan else { return }
        guard let frame = scan.frames.min(by: { abs($0.time - currentTime) < abs($1.time - currentTime) }),
              let word = frame.words
                .filter({ $0.rect.insetBy(dx: -0.005, dy: -0.005).contains(point) })
                .min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })
        else {
            notice = "No text found there. Try clicking directly on a word, or draw a box instead."
            return
        }

        let tracked = FindingTracker.track(text: word.text, frames: scan.frames,
                                           interval: scan.interval, duration: scan.duration)
        findings.append(contentsOf: tracked)
        let times = tracked.count == 1 ? "1 place" : "\(tracked.count) places"
        notice = "Blurring \"\(word.text)\" in \(times)."

        // Follow it frame by frame, as the scan does for what it finds.
        let source = sourceURL
        let interval = scan.interval
        Task {
            guard let refined = try? await MotionTracker.refine(findings: tracked, url: source, interval: interval)
            else { return }
            for finding in refined {
                guard let index = findings.firstIndex(where: { $0.id == finding.id }) else { continue }
                var updated = finding
                updated.isEnabled = findings[index].isEnabled
                findings[index] = updated
            }
        }
    }

    // MARK: - Export

    func export() {
        guard exportTask == nil else { return }
        player.pause()
        exportState = .exporting(0)
        let source = sourceURL
        let destination = destinationURL
        let findings = findings
        let effects = frameEffects()
        let trim = trim
        let cuts = cuts
        let clickSounds = self.clickSounds()
        exportTask = Task {
            do {
                try await RedactionExporter.export(source: source, to: destination, findings: findings,
                                                   effects: effects, clickSounds: clickSounds, timeRange: trim,
                                                   cuts: cuts) { value in
                    Task { @MainActor [weak self] in
                        if case .exporting = self?.exportState { self?.exportState = .exporting(value) }
                    }
                }
                try saveCaptions(besideVideo: destination, edit: VideoEdit(trim: trim, cuts: cuts))
                exportState = .done(destination)
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = .failed(error.localizedDescription)
            }
            exportTask = nil
        }
    }

    /// Final Cut Pro, if it's installed.
    static let finalCut = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FinalCut")

    /// Where the files for Final Cut go: a folder next to the recording.
    var finalCutFolder: URL {
        sourceURL.deletingLastPathComponent()
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + " (Final Cut)", isDirectory: true)
    }

    /// Exports the screen with its blurs and pointer effects, sets it out with the camera
    /// clip (when the camera was kept separately) and a project, and opens that in Final
    /// Cut, which asks which library to import into.
    func sendToFinalCut() {
        guard exportTask == nil, let finalCut = Self.finalCut else { return }
        player.pause()
        isSendingToFinalCut = true
        exportState = .exporting(0)

        let clips = RecorderModel.separateClips(for: sourceURL)
        let separate = [clips.screen, clips.camera].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        // With the camera on its own layer, which may be moved in Final Cut, effects are
        // drawn everywhere, including where the camera was. Captions go over as Final Cut
        // captions instead of being drawn in.
        let effects = frameEffects(cameraSeparate: separate).filter { !($0 is CaptionRenderer) }
        let captions = exportCaptions
        let cuts = cuts
        let name = sourceURL.deletingPathExtension().lastPathComponent
        let source = separate ? clips.screen : sourceURL
        let folder = finalCutFolder
        let findings = findings
        let clicks = pointer?.clicks ?? []
        let trim = trim
        let clickSounds = self.clickSounds()
        exportTask = Task {
            do {
                let project = try await FinalCutHandoff.prepare(
                    name: name, screen: source, camera: separate ? clips.camera : nil, findings: findings,
                    effects: effects, clicks: clicks, clickSounds: clickSounds, in: folder, trim: trim,
                    cuts: cuts, captions: captions
                ) { value in
                    Task { @MainActor [weak self] in
                        if case .exporting = self?.exportState { self?.exportState = .exporting(value) }
                    }
                }
                try await NSWorkspace.shared.open([project], withApplicationAt: finalCut,
                                                  configuration: NSWorkspace.OpenConfiguration())
                exportState = .sentToFinalCut(folder)
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = .failed(error.localizedDescription)
            }
            isSendingToFinalCut = false
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension PointerEffectStyle {
    /// The look last chosen in a review window.
    static var saved: PointerEffectStyle {
        UserDefaults.standard.data(forKey: "pointerStyle")
            .flatMap { try? JSONDecoder().decode(PointerEffectStyle.self, from: $0) } ?? PointerEffectStyle()
    }
}

/// The blur layers and effects, readable from the player's video thread.
private final class PreviewLayers: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFindings: [Finding] = []
    private var storedEffects: [any FrameEffect] = []

    var findings: [Finding] {
        get { lock.withLock { storedFindings } }
        set { lock.withLock { storedFindings = newValue } }
    }

    var effects: [any FrameEffect] {
        get { lock.withLock { storedEffects } }
        set { lock.withLock { storedEffects = newValue } }
    }
}
