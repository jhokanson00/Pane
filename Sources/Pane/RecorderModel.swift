import AppKit
import AVFoundation
import ScreenCaptureKit
import PaneKit

/// Live camera frames for SwiftUI previews. Kept separate from RecorderModel so 30
/// updates a second only redraw the preview, not the whole window.
@MainActor
final class CameraFeed: ObservableObject {
    @Published var image: CGImage?
}

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()

    enum State: Equatable {
        case idle, countingDown, recording, finishing
    }

    enum Problem: Equatable {
        case permission(Permissions.Pane, String)
        case other(String)

        var message: String {
            switch self {
            case .permission(_, let message), .other(let message): return message
            }
        }
    }

    /// Apps hidden by default: password managers and private messages.
    static let defaultHiddenBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.apple.MobileSMS",
    ]

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// Recording, but writing nothing until resumed. The state stays `.recording`.
    @Published private(set) var isPaused = false
    @Published private(set) var lastRecordingURL: URL?
    @Published var problem: Problem?

    enum CaptureMode: String, CaseIterable, Identifiable {
        case display, window
        var id: Self { self }
        var label: String { self == .display ? "Full screen" : "Window" }
    }

    @Published var captureMode: CaptureMode { didSet { save(captureMode.rawValue, "captureMode") } }
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindow: WindowChoice?
    @Published var isChoosingWindow = false
    @Published var cameraEnabled: Bool { didSet { save(cameraEnabled, "cameraEnabled"); updateCamera() } }
    @Published var cameraID: String? { didSet { save(cameraID, "cameraID"); updateCamera() } }
    @Published var cameraStyle: CameraStyle { didSet { cameraStyleChanged() } }
    @Published var micEnabled: Bool { didSet { save(micEnabled, "micEnabled") } }
    @Published var micID: String? { didSet { save(micID, "micID") } }
    @Published var systemAudioEnabled: Bool { didSet { save(systemAudioEnabled, "systemAudioEnabled") } }
    @Published var hiddenBundleIDs: Set<String> { didSet { save(Array(hiddenBundleIDs), "hiddenBundleIDs") } }
    /// Full screen only: leave Finder's desktop icons out of the recording. The icons
    /// stay on the real desktop. (Notification banners are always left out.)
    @Published var hideDesktopIcons: Bool { didSet { save(hideDesktopIcons, "hideDesktopIcons") } }

    enum ScanState: Equatable {
        case idle
        case scanning(Double)
        case finished(found: Int)
        case failed(String)
        /// With Auto-blur off: saving the "(Edited)" copy with pointer effects.
        case addingPointer(Double)
        case exported(URL)
    }

    /// Pointer highlight and click rings, in previews and exports. With Auto-blur off, a
    /// recording gets its "(Edited)" copy with them as soon as it stops.
    @Published var pointerEffects: Bool { didSet { save(pointerEffects, "pointerEffects") } }
    /// With the camera on, also keep the screen and the camera as separate clips, so
    /// Send to Final Cut can put the camera on its own layer.
    @Published var finalCutClips: Bool { didSet { save(finalCutClips, "finalCutClips") } }
    /// What the next recording is called, such as "Share a Project". Empty makes it
    /// "Untitled" with the time. Kept after recording, so another take gets "Take 2".
    @Published var videoTitle: String { didSet { save(videoTitle, "videoTitle") } }
    /// The folder the recording in progress goes into, so the Recordings list leaves it out.
    @Published private(set) var recordingFolder: URL?
    /// Log keyboard shortcuts while recording, shown as badges in exports. Needs Input
    /// Monitoring, which is asked for only when this is turned on.
    @Published var showShortcuts: Bool { didSet { save(showShortcuts, "showShortcuts"); showShortcutsChanged() } }
    @Published var inputMonitoringAllowed = Permissions.inputMonitoringAllowed

    /// The master switch: on, each recording is scanned when it stops and what's found is
    /// blurred; off, nothing is scanned and recordings go straight to review, where drawn
    /// boxes and circles still work. (Stored under its old name, so the setting carries over.)
    @Published var autoBlur: Bool { didSet { save(autoBlur, "autoScan") } }
    @Published var detectedKinds: Set<SensitiveKind> { didSet { save(detectedKinds.map(\.rawValue), "detectedKinds") } }
    @Published var customWords: [String] { didSet { save(customWords, "customWords") } }
    @Published private(set) var scanState: ScanState = .idle
    private var reviewSession: ReviewSession?
    private var scanTask: Task<Void, Never>?

    let cameraFeed = CameraFeed()
    private let camera = CameraEngine()
    private let bubble = CameraBubble()
    private let countdown = CountdownOverlay()
    private var recorder: ScreenRecorder?
    private var pointerRecorder: PointerRecorder?
    /// The teleprompter script this recording was made with, saved into the file so
    /// Review can find retakes.
    private var recordedScript: String?
    private var distractionGuard: DistractionGuard?
    private var startTime: CFTimeInterval?
    /// For the elapsed time, which counts only time actually recorded.
    private var pauses = RecordingPauses()
    var shortcutRecorder: ShortcutRecorder?
    private var timer: Timer?
    private var mainWindowVisible = false

    static let recordingsFolder: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("Pane", isDirectory: true)
    }()

    /// Where a recording's separate screen and camera clips are kept (see SeparateClips):
    /// in its folder, or for recordings from before folders, in Application Support.
    static func separateClips(for recording: URL) -> SeparateClips.Files {
        let folder = VideoLibrary.isInFolder(recording, root: recordingsFolder)
            ? recording.deletingLastPathComponent().appendingPathComponent(VideoLibrary.clipsFolderName, isDirectory: true)
            : legacyClipsFolder.appendingPathComponent(recording.deletingPathExtension().lastPathComponent, isDirectory: true)
        return SeparateClips.Files(screen: folder.appendingPathComponent("Screen.mp4"),
                                   camera: folder.appendingPathComponent("Camera.mov"))
    }

    /// Where clips were kept before each video had its own folder.
    static var legacyClipsFolder: URL { supportFolder.appendingPathComponent("Clips", isDirectory: true) }

    static let supportFolder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Pane", isDirectory: true)
    }()

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "cameraEnabled": true,
            "micEnabled": true,
            "systemAudioEnabled": false,
            "hiddenBundleIDs": Array(Self.defaultHiddenBundleIDs),
            "autoScan": true,
            "pointerEffects": true,
            "finalCutClips": true,
            "hideDesktopIcons": false,
            "showShortcuts": false,
            "detectedKinds": SensitiveKind.allCases.filter { $0 != .manual }.map(\.rawValue),
        ])
        autoBlur = defaults.bool(forKey: "autoScan")
        pointerEffects = defaults.bool(forKey: "pointerEffects")
        finalCutClips = defaults.bool(forKey: "finalCutClips")
        videoTitle = defaults.string(forKey: "videoTitle") ?? ""
        showShortcuts = defaults.bool(forKey: "showShortcuts")
        detectedKinds = Set((defaults.stringArray(forKey: "detectedKinds") ?? []).compactMap(SensitiveKind.init))
        customWords = defaults.stringArray(forKey: "customWords") ?? []
        captureMode = defaults.string(forKey: "captureMode").flatMap(CaptureMode.init) ?? .display
        cameraEnabled = defaults.bool(forKey: "cameraEnabled")
        cameraID = defaults.string(forKey: "cameraID")
        cameraStyle = defaults.data(forKey: "cameraStyle")
            .flatMap { try? JSONDecoder().decode(CameraStyle.self, from: $0) } ?? CameraStyle()
        micEnabled = defaults.bool(forKey: "micEnabled")
        micID = defaults.string(forKey: "micID")
        systemAudioEnabled = defaults.bool(forKey: "systemAudioEnabled")
        hiddenBundleIDs = Set(defaults.stringArray(forKey: "hiddenBundleIDs") ?? [])
        hideDesktopIcons = defaults.bool(forKey: "hideDesktopIcons")

        camera.style = cameraStyle
        camera.onPreview = { [weak self] image in
            self?.cameraFeed.image = image
            self?.bubble.update(image)
        }
    }

    var elapsedString: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Width / height of what will be recorded, for the layout preview.
    var displayAspectRatio: CGFloat {
        let size = captureMode == .window ? selectedWindow?.frame.size : selectedScreen?.frame.size
        guard let size, size.height > 0 else { return 16 / 10 }
        return size.width / size.height
    }

    // MARK: - Recording

    func startRecording() async {
        guard state == .idle else { return }
        problem = nil

        if captureMode == .window && selectedWindow == nil {
            WindowPresenter.showMain()
            isChoosingWindow = true
            return
        }
        guard await Permissions.ensureScreenRecording() else {
            problem = .permission(.screenRecording,
                "Pane needs Screen Recording access. Turn it on in System Settings, then click Quit & Reopen Pane. "
                + "If Pane is already on there, select it, remove it with the − button, and try again.")
            return
        }
        if micEnabled, !(await Permissions.requestCapture(.audio)) {
            problem = .permission(.microphone, "Pane needs Microphone access, or turn the microphone off.")
            return
        }
        if cameraEnabled {
            guard await Permissions.requestCapture(.video) else {
                problem = .permission(.camera, "Pane needs Camera access, or turn the camera off.")
                return
            }
            guard camera.start(deviceID: cameraID) else {
                problem = .other("Couldn't start the camera. Pick a different one or turn the camera off.")
                return
            }
        }

        let target: CaptureTarget
        do {
            target = try await makeCaptureTarget()
        } catch {
            problem = .other(error.localizedDescription)
            return
        }

        state = .countingDown
        WindowPresenter.hideMain()
        if cameraEnabled, cameraStyle.showBubbleWhileRecording {
            bubble.show(in: target.frame, style: cameraStyle)
        }
        // Up during the countdown so the first line can be read, listening once recording.
        let prompter = PrompterController.shared
        let usesPrompter = prompter.showsWhileRecording
        if usesPrompter {
            prompter.begin(on: target.screen, listen: micEnabled, ownMicrophone: false, microphoneID: micID)
            prompter.pause()
        }
        recordedScript = usesPrompter ? prompter.scriptText : nil

        let finished = await countdown.run(seconds: 3, on: target.screen) { [weak self] in
            self?.state != .countingDown
        }
        guard finished, state == .countingDown else { return }

        // Each video in its own folder, named after it (see VideoLibrary).
        let name = VideoLibrary.uniqueName(title: videoTitle, date: Date(), in: Self.recordingsFolder)
        let folder = Self.recordingsFolder.appendingPathComponent(name, isDirectory: true)
        do {
            let filter = target.filter
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            recordingFolder = folder
            let outputURL = folder.appendingPathComponent(name + ".mp4")
            let recorder = ScreenRecorder(outputURL: outputURL, camera: cameraEnabled ? camera : nil)
            recorder.onUnexpectedStop = { [weak self] error in
                Task { await self?.stopRecording(reason: error) }
            }
            if usesPrompter, micEnabled {
                recorder.microphoneTap = { [audio = prompter.audio] buffer in audio.append(buffer) }
            }
            try await recorder.start(filter: filter, options: .init(
                captureMicrophone: micEnabled,
                microphoneID: micID,
                captureSystemAudio: systemAudioEnabled,
                cameraStyle: cameraEnabled ? cameraStyle : nil,
                separateClips: cameraEnabled && finalCutClips ? Self.separateClips(for: outputURL) : nil
            ))
            self.recorder = recorder
            target.distractions?.start(updating: recorder)
            distractionGuard = target.distractions
            let pointer = PointerRecorder(area: target.windowID.map { .window($0, target.frame) } ?? .display(target.frame))
            pointer.onPress = { PrompterController.shared.clicked() }
            pointer.start()
            pointerRecorder = pointer
            startShortcuts()
            beginTimer()
            state = .recording
            if usesPrompter { prompter.resume() }
        } catch {
            problem = .other("Couldn't start recording: \(error.localizedDescription)")
            // Nothing was recorded: don't leave an empty folder behind.
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
            resetAfterRecording()
        }
    }

    func togglePause() {
        isPaused ? resumeRecording() : pauseRecording()
    }

    /// Stops writing the video, audio and pointer until resumed. The camera bubble stays
    /// on screen.
    func pauseRecording() {
        guard state == .recording, !isPaused, let recorder else { return }
        recorder.pause()
        pointerRecorder?.pause()
        shortcutRecorder?.pause()
        PrompterController.shared.pause()
        pauses.pause(at: CACurrentMediaTime())
        isPaused = true
        updateElapsed()
    }

    /// Continues the same file with no gap where the pause was.
    func resumeRecording() {
        guard state == .recording, isPaused, let recorder else { return }
        pointerRecorder?.resume()
        shortcutRecorder?.resume()
        recorder.resume()
        PrompterController.shared.resume()
        pauses.resume(at: CACurrentMediaTime())
        isPaused = false
    }

    func cancelCountdown() {
        guard state == .countingDown else { return }
        resetAfterRecording()
    }

    func stopRecording(reason: Error? = nil) async {
        guard state == .recording, let recorder else { return }
        state = .finishing
        timer?.invalidate()

        pointerRecorder?.stop()
        distractionGuard?.stop()
        shortcutRecorder?.stop()
        PrompterController.shared.end()
        do {
            let url = try await recorder.stop()
            savePointer(for: url)
            if let recordedScript { try? PrompterScript.save(recordedScript, to: url) }
            lastRecordingURL = url
            reviewSession?.close()
            reviewSession = nil
            scanState = .idle
            if let reason {
                problem = .other("Recording stopped early (\(reason.localizedDescription)). What was captured was saved.")
            }
            if autoBlur {
                scanLastRecording()
            } else if pointerEffects {
                addPointerEffects()
            }
        } catch {
            problem = .other("Couldn't save the recording: \(error.localizedDescription)")
        }
        resetAfterRecording()
    }

    /// Saves where the pointer went with the recording, for pointer effects at export.
    private func savePointer(for url: URL) {
        guard let pointerRecorder, let timeline = recorder?.timeline() else { return }
        var cameraCircle: CGRect?
        if cameraEnabled, timeline.size.width > 0, timeline.size.height > 0 {
            let layout = OverlayLayout(style: cameraStyle, canvas: timeline.size, topLeftOrigin: false)
            let r = layout.radius + layout.ring
            cameraCircle = CGRect(x: (layout.center.x - r) / timeline.size.width,
                                  y: (layout.center.y - r) / timeline.size.height,
                                  width: 2 * r / timeline.size.width, height: 2 * r / timeline.size.height)
        }
        try? pointerRecorder.track(timeline: timeline, cameraCircle: cameraCircle).save(to: url)
        try? shortcutRecorder?.track(timeline: timeline, cameraCircle: cameraCircle).save(to: url)
    }

    // MARK: - Auto-blur

    /// Opens the review window for the last recording, without scanning it if it hasn't
    /// been scanned. Drawn boxes and circles and pointer effects don't need a scan.
    func reviewLastRecording() {
        guard let url = lastRecordingURL else { return }
        if let reviewSession, reviewSession.sourceURL == url {
            WindowPresenter.showReview(reviewSession)
            return
        }
        Task {
            do {
                let (videoSize, duration) = try await Self.measure(url)
                guard url == lastRecordingURL else { return }
                let session = ReviewSession(sourceURL: url, scan: nil, videoSize: videoSize, duration: duration)
                reviewSession = session
                WindowPresenter.showReview(session)
            } catch {
                scanState = .failed(error.localizedDescription)
            }
        }
    }

    /// Reviews any video, not just one Pane recorded, scanning it first if Auto-blur is on.
    func review(videoAt url: URL) {
        guard state == .idle else { return }
        scanTask?.cancel()
        scanTask = nil
        reviewSession?.close()
        reviewSession = nil
        lastRecordingURL = url
        scanState = .idle
        WindowPresenter.showMain()
        if autoBlur { scanLastRecording() } else { reviewLastRecording() }
    }

    private static func measure(_ url: URL) async throws -> (size: CGSize, duration: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScanError.noVideoTrack }
        return (try await track.load(.naturalSize), try await asset.load(.duration).seconds)
    }

    /// Saves the last recording's "(Edited)" copy with pointer effects in the style last
    /// chosen in Review, without scanning. Nothing has to be read, so it takes a fraction
    /// of a scan's time: about 2 seconds for a 17-second recording.
    func addPointerEffects() {
        guard let url = lastRecordingURL, scanTask == nil, let track = PointerTrack.load(from: url) else { return }
        scanState = .addingPointer(0)
        scanTask = Task {
            defer { scanTask = nil }
            do {
                let (videoSize, _) = try await Self.measure(url)
                let style = PointerEffectStyle.saved
                // The zoom goes after the pointer effects so they grow with it, and the
                // shortcut badges after the zoom so they don't.
                let effects: [any FrameEffect] = [PointerRenderer(track: track, style: style, videoSize: videoSize) as (any FrameEffect)?,
                                                  ClickZoomEffect(track: track, zoom: style.zoom),
                                                  ShortcutBadgeRenderer.saved(for: url, videoSize: videoSize)].compactMap { $0 }
                let clickSounds = track.clickSounds(style: style)
                guard !effects.isEmpty || !clickSounds.isEmpty else {
                    scanState = .idle
                    return
                }
                let destination = ReviewSession.editedURL(for: url)
                try await RedactionExporter.export(source: url, to: destination, findings: [], effects: effects,
                                                   clickSounds: clickSounds) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .addingPointer(let shown) = self.scanState, progress > shown else { return }
                        self.scanState = .addingPointer(progress)
                    }
                }
                guard url == lastRecordingURL else { return }
                scanState = .exported(destination)
            } catch is CancellationError {
                scanState = .idle
            } catch {
                scanState = .failed("Couldn't add pointer effects: \(error.localizedDescription)")
            }
        }
    }

    var scanOptions: SensitiveDetector.Options {
        SensitiveDetector.Options(kinds: detectedKinds, customWords: customWords)
    }

    func chooseVideoToReview() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.directoryURL = Self.recordingsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        review(videoAt: url)
    }

    /// Scans the video an open review window shows, adding what it finds there.
    func scan(for session: ReviewSession) {
        if session.sourceURL != lastRecordingURL {
            guard scanTask == nil, state == .idle else { return }
            lastRecordingURL = session.sourceURL
            scanState = .idle
        }
        reviewSession = session
        scanLastRecording()
    }

    /// Scans the last recording for sensitive text, then reviews it. If its review window
    /// is already open, what the scan finds is added to the layers there.
    func scanLastRecording() {
        guard let url = lastRecordingURL, scanTask == nil else { return }
        scanState = .scanning(0)
        let options = scanOptions

        scanTask = Task {
            defer { scanTask = nil }
            do {
                let (videoSize, _) = try await Self.measure(url)
                let result = try await RecordingScanner.scan(url: url, options: options) { progress in
                    Task { @MainActor [weak self] in
                        // Frames are read a few at a time, so updates can arrive out of order.
                        guard let self, case .scanning(let shown) = self.scanState, progress > shown else { return }
                        self.scanState = .scanning(progress)
                    }
                }
                guard url == lastRecordingURL else { return }
                scanState = .finished(found: result.findings.count)
                if let reviewSession, reviewSession.sourceURL == url {
                    reviewSession.add(scan: result)
                    WindowPresenter.showReview(reviewSession)
                } else {
                    let session = ReviewSession(sourceURL: url, scan: result, videoSize: videoSize,
                                                duration: result.duration)
                    reviewSession = session
                    WindowPresenter.showReview(session)
                }
            } catch {
                scanState = .failed(error.localizedDescription)
            }
        }
    }

    private func resetAfterRecording() {
        recordedScript = nil
        recordingFolder = nil
        if !PrompterController.shared.isRehearsing { PrompterController.shared.end() }
        timer?.invalidate()
        timer = nil
        recorder = nil
        pointerRecorder?.stop()
        pointerRecorder = nil
        distractionGuard?.stop()
        distractionGuard = nil
        startTime = nil
        pauses = RecordingPauses()
        isPaused = false
        shortcutRecorder?.stop()
        shortcutRecorder = nil
        elapsed = 0
        state = .idle
        bubble.hide()
        WindowPresenter.showMain()
    }

    private func beginTimer() {
        startTime = CACurrentMediaTime()
        pauses = RecordingPauses()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
    }

    private func updateElapsed() {
        guard let startTime else { return }
        elapsed = pauses.recordedDuration(from: startTime, to: CACurrentMediaTime())
    }

    /// What to capture, plus where it is on screen (for the bubble and countdown).
    private struct CaptureTarget {
        let filter: SCContentFilter
        /// In AppKit global coordinates.
        let frame: CGRect
        /// Set when recording a single window.
        var windowID: CGWindowID?
        /// Set when recording a display: keeps the filter up to date while recording.
        var distractions: DistractionGuard?
        var screen: NSScreen? {
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
        }
    }

    private enum CaptureError: LocalizedError {
        case windowClosed
        var errorDescription: String? { "The window you chose has closed or moved to another desktop. Choose it again." }
    }

    /// Full screen: the chosen display minus Pane's own windows, every hidden app and
    /// notification banners (and the desktop icons, if asked; see DistractionGuard).
    /// Window: just that window, even when other windows pass in front of it.
    private func makeCaptureTarget() async throws -> CaptureTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        switch captureMode {
        case .window:
            guard let id = selectedWindow?.id, let window = content.windows.first(where: { $0.windowID == id }) else {
                selectedWindow = nil
                throw CaptureError.windowClosed
            }
            return CaptureTarget(
                filter: SCContentFilter(desktopIndependentWindow: window),
                frame: WindowCatalog.appKitFrame(fromCaptureFrame: window.frame),
                windowID: window.windowID
            )

        case .display:
            let display = content.displays.first { $0.displayID == selectedDisplayID }
                ?? content.displays.first { $0.displayID == CGMainDisplayID() }
                ?? content.displays[0]
            let distractions = DistractionGuard(displayID: display.displayID, neverRecord: hiddenBundleIDs,
                                                hideDesktopIcons: hideDesktopIcons)
            let screen = NSScreen.screens.first { $0.displayID == display.displayID }
            return CaptureTarget(
                filter: distractions.filter(display: display, content: content),
                frame: screen?.frame ?? NSScreen.main?.frame ?? .zero,
                distractions: distractions
            )
        }
    }

    private var selectedScreen: NSScreen? {
        let id = selectedDisplayID ?? CGMainDisplayID()
        return NSScreen.screens.first { $0.displayID == id } ?? NSScreen.main
    }

    // MARK: - Camera

    func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisible = visible
        updateCamera()
    }

    /// The camera runs while the main window shows its preview, or while recording.
    private var cameraNeeded: Bool {
        cameraEnabled && (mainWindowVisible || state != .idle)
    }

    private func updateCamera() {
        guard cameraNeeded else {
            camera.stop()
            cameraFeed.image = nil
            return
        }
        Task {
            guard await Permissions.requestCapture(.video) else {
                problem = .permission(.camera, "Pane needs Camera access to show your camera.")
                return
            }
            guard cameraNeeded else { return }
            if !camera.start(deviceID: cameraID) {
                problem = .other("No camera found. Plug one in or turn the camera off.")
            }
        }
    }

    private func cameraStyleChanged() {
        if let data = try? JSONEncoder().encode(cameraStyle) {
            UserDefaults.standard.set(data, forKey: "cameraStyle")
        }
        camera.style = cameraStyle
        bubble.apply(style: cameraStyle)
    }

    /// Copies a chosen image into Pane's support folder so it keeps working if the
    /// original moves.
    func setBackgroundImage(from url: URL) {
        do {
            try FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
            let destination = Self.supportFolder
                .appendingPathComponent("camera-background-\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension)
            try FileManager.default.copyItem(at: url, to: destination)
            if let old = cameraStyle.backgroundImagePath {
                try? FileManager.default.removeItem(atPath: old)
            }
            cameraStyle.backgroundImagePath = destination.path
            cameraStyle.background = .image
        } catch {
            problem = .other("Couldn't use that image: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private func save(_ value: Any?, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
