import AppKit
import AVFoundation
import Carbon.HIToolbox
import PaneKit
import SwiftUI

/// The teleprompter: a strip at the top of the screen showing the next lines of a script,
/// with `[cues]` for what to do, that moves as you speak (no auto-scroll).
///
/// While recording it listens to the microphone audio Pane is already recording; when
/// rehearsing it opens the microphone itself. It's one of Pane's windows, so it's never in
/// a recording. Clicks pass through it, and it fades while the pointer is over it, so the
/// app underneath stays usable. ⌃⌥↑ goes back to the start of the sentence (to start it
/// over), ⌃⌥↓ on to the next one.
@MainActor
final class PrompterController: ObservableObject {
    static let shared = PrompterController()

    enum Status: Equatable {
        case off
        case starting(String)
        case listening
        case paused
        case problem(String)
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var points: CGFloat {
            switch self {
            case .small: 22
            case .medium: 28
            case .large: 36
            }
        }
    }

    @Published var scriptText: String {
        didSet {
            UserDefaults.standard.set(scriptText, forKey: Keys.script)
            // A new "# Title" names the next video.
            if let title = PrompterScript.title(in: scriptText), title != PrompterScript.title(in: oldValue) {
                RecorderModel.shared.videoTitle = title
            }
            script = PrompterScript(scriptText)
            // Edited while showing (rehearsing): keep the place, as near as the new text allows.
            follower = ScriptFollower(script: script)
            follower.jump(to: isShowing ? position : 0)
            position = follower.position
            doneCues = []
        }
    }
    /// Show the teleprompter while recording.
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }
    @Published var textSize: TextSize {
        didSet { UserDefaults.standard.set(textSize.rawValue, forKey: Keys.textSize); panel.resize(for: self) }
    }

    @Published private(set) var script: PrompterScript
    /// The next word to say.
    @Published private(set) var position = 0
    /// Cues ticked off by a click, by index into `script.cues`.
    @Published private(set) var doneCues: Set<Int> = []
    @Published private(set) var status: Status = .off
    @Published private(set) var isRehearsing = false
    @Published private(set) var isShowing = false

    /// Recorder-queue side: where microphone buffers go.
    let audio = PrompterAudio()

    private var follower: ScriptFollower
    private var ownMicrophone: MicrophoneCapture?
    private let audioQueue = DispatchQueue(label: "com.jacobhokanson.pane.prompter")
    private let panel = PrompterPanel()
    private var hotKeys: PrompterHotKeys?
    private var session = 0
    private var layoutCache: (key: String, layout: PrompterLayout)?

    /// The script cut into rows for the strip, remembered until the text or size changes.
    func layout(width: CGFloat, size: CGFloat) -> PrompterLayout {
        let key = "\(Int(width))|\(size)|\(scriptText)"
        if let layoutCache, layoutCache.key == key { return layoutCache.layout }
        let layout = PrompterLayout(script: script, width: width, size: size)
        layoutCache = (key, layout)
        return layout
    }

    private enum Keys {
        static let script = "prompterScript"
        static let enabled = "prompterEnabled"
        static let textSize = "prompterTextSize"
    }

    private init() {
        let defaults = UserDefaults.standard
        let text = defaults.string(forKey: Keys.script) ?? ""
        scriptText = text
        script = PrompterScript(text)
        follower = ScriptFollower(script: PrompterScript(text))
        enabled = defaults.bool(forKey: Keys.enabled)
        textSize = TextSize(rawValue: defaults.string(forKey: Keys.textSize) ?? "") ?? .medium
    }

    var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var hasScript: Bool { !script.words.isEmpty || !script.cues.isEmpty }

    /// Whether recording should bring the teleprompter up.
    var showsWhileRecording: Bool { enabled && hasScript && isAvailable }

    // MARK: - Showing

    /// Shows the strip from the top of the script and starts listening. With
    /// `ownMicrophone`, opens the microphone itself (rehearsing); otherwise audio comes from
    /// `audio.append` (the recorder's microphone). Without `listen` (recording with the
    /// microphone off) it only shows the script, moved with the keys.
    func begin(on screen: NSScreen?, listen: Bool = true, ownMicrophone: Bool, microphoneID: String?) {
        end()
        session += 1
        let current = session
        follower = ScriptFollower(script: script)
        position = 0
        doneCues = []
        isShowing = true
        status = .starting("Starting…")
        panel.show(on: screen ?? NSScreen.main, controller: self)
        hotKeys = PrompterHotKeys { [weak self] step in self?.nudge(lines: step) }

        guard listen else {
            status = .problem("Microphone off: Control-Option ↓ moves on.")
            return
        }
        guard #available(macOS 26, *) else {
            status = .problem("Following your voice needs macOS 26.")
            return
        }
        if ownMicrophone {
            self.ownMicrophone = MicrophoneCapture(deviceID: microphoneID, queue: audioQueue) { [audio] buffer in
                audio.append(buffer)
            }
            if self.ownMicrophone == nil {
                status = .problem("Couldn't open the microphone.")
                return
            }
            self.ownMicrophone?.start()
        }
        let vocabulary = script.vocabulary
        Task { [weak self] in
            if await CaptionTranscriber.needsDownload() {
                self?.setStatus(.starting("Getting the speech model…"), session: current)
            }
            do {
                let transcriber = try await LiveTranscriber.start(vocabulary: vocabulary) { heard in
                    let words = heard.all
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { PrompterController.shared.heard(words, session: current) }
                    }
                }
                guard let self, self.session == current else {
                    await transcriber.cancel()
                    return
                }
                self.audio.start(transcriber)
                self.status = self.audio.isPaused ? .paused : .listening
            } catch {
                self?.setStatus(.problem(error.localizedDescription), session: current)
            }
        }
    }

    /// Hides the strip and stops listening.
    func end() {
        session += 1
        ownMicrophone?.stop()
        ownMicrophone = nil
        audio.stop()
        audio.isPaused = false
        hotKeys = nil
        panel.hide()
        isShowing = false
        isRehearsing = false
        status = .off
    }

    func rehearse(microphoneID: String?) {
        Task {
            guard await Permissions.requestCapture(.audio) else {
                Permissions.openSettings(.microphone)
                return
            }
            begin(on: NSScreen.main, ownMicrophone: true, microphoneID: microphoneID)
            isRehearsing = true
        }
    }

    func pause() {
        guard isShowing else { return }
        audio.isPaused = true
        if status == .listening { status = .paused }
    }

    func resume() {
        guard isShowing else { return }
        audio.isPaused = false
        if status == .paused { status = .listening }
    }

    // MARK: - Following

    private func heard(_ words: [String], session: Int) {
        guard session == self.session, !audio.isPaused else { return }
        if follower.hear(words) { position = follower.position }
    }

    private func setStatus(_ status: Status, session: Int) {
        if session == self.session { self.status = status }
    }

    /// A click ticks off the cue you're at, such as "[Click Settings]".
    func clicked() {
        if let cue = activeCue { doneCues.insert(cue) }
    }

    /// The cue you're at: every word before it said, not yet ticked off.
    var activeCue: Int? {
        script.cues.indices.first { $0 < script.cues.count && script.cues[$0].beforeWord == position && !doneCues.contains($0) }
    }

    func isDone(cue index: Int) -> Bool {
        doneCues.contains(index) || script.cues[index].beforeWord < position
    }

    /// The line the strip starts at: the active cue's, or the next word's.
    var focusLine: Int {
        if let cue = activeCue { return script.cues[cue].line }
        if position < script.words.count { return script.words[position].line }
        return max(0, script.lines.count - 1)
    }

    /// Back to the start of the sentence (or the one before, if already there), or on to
    /// the next sentence.
    func nudge(lines step: Int) {
        if step > 0 { follower.sentenceForward() } else { follower.sentenceBack() }
        position = follower.position
        doneCues = doneCues.filter { script.cues[$0].beforeWord < position }
    }
}

/// Audio for the teleprompter, fed from the recorder's or its own microphone queue.
final class PrompterAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: AnyObject?
    private var paused = false

    var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    @available(macOS 26, *)
    func start(_ transcriber: LiveTranscriber) {
        lock.withLock { self.transcriber = transcriber }
    }

    func stop() {
        let old = lock.withLock { () -> AnyObject? in
            defer { transcriber = nil }
            return transcriber
        }
        if #available(macOS 26, *), let old = old as? LiveTranscriber {
            Task { await old.cancel() }
        }
    }

    func append(_ buffer: CMSampleBuffer) {
        guard #available(macOS 26, *) else { return }
        let target = lock.withLock { paused ? nil : transcriber as? LiveTranscriber }
        target?.append(buffer)
    }
}

// MARK: - Window

/// The strip's window: borderless, above other windows, on every Space, never taking
/// clicks. Fades nearly away while the pointer is over it.
@MainActor
private final class PrompterPanel {
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var faded = false
    /// Where the strip is, in screen coordinates: the hover test uses this, not the
    /// window's frame.
    private var area = NSRect.zero

    func show(on screen: NSScreen?, controller: PrompterController) {
        hide()
        guard let screen else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingView(rootView: PrompterStrip().environmentObject(controller))
        // Otherwise SwiftUI sizes the window to the script's longest line, unwrapped: far
        // wider than the strip, and the pointer seemed to be "over" it everywhere.
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        place(on: screen, size: controller.textSize)
        panel.orderFrontRegardless()

        let fade: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFade() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: fade) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            fade(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func resize(for controller: PrompterController) {
        guard let screen = panel?.screen else { return }
        place(on: screen, size: controller.textSize)
    }

    private func place(on screen: NSScreen, size: PrompterController.TextSize) {
        let visible = screen.visibleFrame
        // Narrow, so the eyes barely move from side to side while reading.
        let width = min(575, screen.frame.width * 0.36)
        // Three rows, padding and the status row.
        let height = PrompterLayout.pitch(size.points) * CGFloat(PrompterLayout.visibleRows) + 52
        area = NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 6, width: width, height: height)
        panel?.setFrame(area, display: true)
    }

    func hide() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        faded = false
    }

    private func updateFade() {
        guard let panel else { return }
        let over = area.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
        guard over != faded else { return }
        faded = over
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = over ? 0.1 : 1
        }
    }
}

/// The script cut into rows that fit the strip's width, so a long paragraph scrolls a row at
/// a time like short lines do. A script line always starts a new row.
struct PrompterLayout {
    enum Item: Equatable {
        case word(Int)
        case cue(Int)
    }

    static let visibleRows = 3

    let rows: [[Item]]
    private let rowOfWord: [Int]
    private let rowOfCue: [Int]

    /// Text sizes: row height plus the gap to the next row.
    static func pitch(_ size: CGFloat) -> CGFloat { size * 1.55 }
    static func wordFont(_ size: CGFloat) -> NSFont { rounded(size, .semibold) }
    static func cueFont(_ size: CGFloat) -> NSFont { rounded(size * 0.8, .bold) }

    init(script: PrompterScript, width: CGFloat, size: CGFloat) {
        let wordFont = Self.wordFont(size), cueFont = Self.cueFont(size)
        func measure(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let space = measure(" ", wordFont)
        var rows: [[Item]] = []
        var rowOfWord = Array(repeating: 0, count: script.words.count)
        var rowOfCue = Array(repeating: 0, count: script.cues.count)
        for line in script.lines {
            // This line's words and cues in order; a cue goes before the word it's written in front of.
            var items: [Item] = []
            var cue = line.cues.lowerBound
            for word in line.words {
                while cue < line.cues.upperBound, script.cues[cue].beforeWord <= word { items.append(.cue(cue)); cue += 1 }
                items.append(.word(word))
            }
            while cue < line.cues.upperBound { items.append(.cue(cue)); cue += 1 }

            var row: [Item] = [], used: CGFloat = 0
            for item in items {
                let itemWidth = switch item {
                case .word(let w): measure(script.words[w].text, wordFont)
                case .cue(let c): measure("▸ " + script.cues[c].text, cueFont)
                }
                if !row.isEmpty, used + space + itemWidth > width {
                    rows.append(row)
                    row = []
                    used = 0
                }
                used += (row.isEmpty ? 0 : space) + itemWidth
                row.append(item)
                switch item {
                case .word(let w): rowOfWord[w] = rows.count
                case .cue(let c): rowOfCue[c] = rows.count
                }
            }
            if !row.isEmpty { rows.append(row) }
        }
        self.rows = rows
        self.rowOfWord = rowOfWord
        self.rowOfCue = rowOfCue
    }

    /// The row to keep at the top: the active cue's, or the next word's.
    func focusRow(position: Int, activeCue: Int?) -> Int {
        if let activeCue { return rowOfCue[activeCue] }
        if position < rowOfWord.count { return rowOfWord[position] }
        return max(0, rows.count - 1)
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

/// What the strip shows: the row you're on at the top and the next two, scrolling up a row
/// at a time as you read. Said words dim; cues are orange, ticked when done.
private struct PrompterStrip: View {
    @EnvironmentObject private var prompter: PrompterController

    var body: some View {
        let size = prompter.textSize.points
        let pitch = PrompterLayout.pitch(size)
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                let layout = prompter.layout(width: geometry.size.width, size: size)
                let finished = prompter.position >= prompter.script.words.count && prompter.activeCue == nil
                // Past the last row comes one more: "End of script" (or "No script yet").
                let focus = finished ? layout.rows.count
                    : layout.focusRow(position: prompter.position, activeCue: prompter.activeCue)
                // A row above and a few below, so rows slide in and out instead of popping.
                let first = max(0, focus - 1)
                let last = min(layout.rows.count + 1, focus + PrompterLayout.visibleRows + 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(first..<max(first, last), id: \.self) { index in
                        Group {
                            if index < layout.rows.count {
                                row(layout.rows[index], size: size)
                            } else {
                                Text(prompter.script.words.isEmpty ? "No script yet" : "End of script")
                                    .font(Font(PrompterLayout.wordFont(size)))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .frame(height: pitch, alignment: .leading)
                        .opacity(index == focus ? 1 : index < focus ? 0 : 0.72)
                    }
                }
                .offset(y: -CGFloat(focus - first) * pitch)
                .animation(.easeOut(duration: 0.3), value: focus)
            }
            .frame(height: pitch * CGFloat(PrompterLayout.visibleRows))
            .clipped()
            statusRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ items: [PrompterLayout.Item], size: CGFloat) -> some View {
        let script = prompter.script
        var text = Text("")
        for (index, item) in items.enumerated() {
            if index > 0 { text = text + Text(" ") }
            switch item {
            case .cue(let cue):
                let done = prompter.isDone(cue: cue)
                let active = prompter.activeCue == cue
                text = text + Text((done ? "✓ " : "▸ ") + script.cues[cue].text)
                    .font(Font(PrompterLayout.cueFont(size)))
                    .foregroundColor(done ? .orange.opacity(0.45) : active ? .orange : .orange.opacity(0.85))
            case .word(let word):
                text = text + Text(script.words[word].text)
                    .foregroundColor(word < prompter.position ? .white.opacity(0.32) : .white)
            }
        }
        return text
            .font(Font(PrompterLayout.wordFont(size)))
            .lineLimit(1)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(statusText)
            Spacer()
            Text("Control-Option ↑ again  ↓ skip")
                .help("Control-Option-Up starts the sentence over; Control-Option-Down skips to the next one.")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.top, 6)
    }

    private var statusText: String {
        switch prompter.status {
        case .off: ""
        case .starting(let text): text
        case .listening: prompter.isRehearsing ? "Rehearsing: listening" : "Listening"
        case .paused: "Paused"
        case .problem(let text): text
        }
    }

    private var dotColor: Color {
        switch prompter.status {
        case .listening: .green
        case .problem: .red
        case .starting: .yellow
        default: .gray
        }
    }
}

// MARK: - Keys

/// ⌃⌥↑ and ⌃⌥↓ for the teleprompter, as system hot keys: they work in any app and need no
/// permission, and plain arrow keys stay with the app being recorded. Registered only
/// while the strip is showing.
final class PrompterHotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    fileprivate let action: (Int) -> Void

    private static let signature = OSType(0x5041_4E45)  // "PANE"
    private static let keys: [(code: Int, step: Int)] = [(kVK_DownArrow, 1), (kVK_UpArrow, -1)]

    /// Whether a key press is one of these, so it's never shown as a shortcut badge.
    static func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keys.contains { Int(keyCode) == $0.code }
            && flags.contains(.maskControl) && flags.contains(.maskAlternate) && !flags.contains(.maskCommand)
    }

    init(action: @escaping (Int) -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), prompterHotKeyHandler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        for (index, key) in Self.keys.enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key.code), UInt32(controlKey | optionKey),
                                EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    deinit {
        for case let ref? in refs { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    fileprivate func pressed(id: UInt32) {
        guard Int(id) < Self.keys.count else { return }
        let step = Self.keys[Int(id)].step
        DispatchQueue.main.async { self.action(step) }
    }
}

private func prompterHotKeyHandler(_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    Unmanaged<PrompterHotKeys>.fromOpaque(userData).takeUnretainedValue().pressed(id: id.id)
    return noErr
}


