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
/// app underneath stays usable. ⌃⌥→ and ⌃⌥← move it a line forward or back.
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
            status = .problem("The microphone is off: use ⌃⌥→ to move on.")
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

    /// Moves to the start of the next spoken line, or back to the start of this one (or
    /// the one before, if already there).
    func nudge(lines step: Int) {
        let spoken = script.lines.filter { !$0.words.isEmpty }.map(\.words.lowerBound)
        guard !spoken.isEmpty else { return }
        let target: Int
        if step > 0 {
            target = spoken.first { $0 > position } ?? script.words.count
        } else {
            let earlier = spoken.filter { $0 < position }
            target = earlier.count >= 2 && position == (spoken.last { $0 <= position } ?? 0)
                ? earlier[earlier.count - 2] : (earlier.last ?? 0)
        }
        follower.jump(to: target)
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
        let width = min(1000, screen.frame.width * 0.62)
        // Room for three lines, any of them wrapping once, plus the status row.
        let height = size.points * 1.3 * 4 + 44
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

/// What the strip shows: the line you're on and the two after it. Said words dim; cues are
/// orange, ticked when done.
private struct PrompterStrip: View {
    @EnvironmentObject private var prompter: PrompterController

    var body: some View {
        let script = prompter.script
        let first = prompter.focusLine
        let shown = Array(first..<min(script.lines.count, first + 3))
        let size = prompter.textSize.points

        VStack(alignment: .leading, spacing: size * 0.35) {
            ForEach(shown, id: \.self) { index in
                line(index, script: script, size: size)
                    // Lines further down are dimmer, but a cue line stays easy to see.
                    .opacity(index == first || script.lines[index].words.isEmpty ? 1 : 0.72)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
            if shown.isEmpty || (prompter.position >= script.words.count && prompter.activeCue == nil) {
                Text(script.words.isEmpty ? "No script yet" : "End of script")
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            statusRow
        }
        .animation(.easeOut(duration: 0.25), value: first)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func line(_ index: Int, script: PrompterScript, size: CGFloat) -> some View {
        let line = script.lines[index]
        var text = Text("")
        var words = line.words.makeIterator()
        var nextWord = words.next()
        var cues = line.cues.makeIterator()
        var nextCue = cues.next()
        var first = true
        func space() -> Text { first ? Text("") : Text(" ") }
        // Words and cues in order: a cue goes before the word it's written in front of.
        while nextWord != nil || nextCue != nil {
            if let cue = nextCue, nextWord.map({ script.cues[cue].beforeWord <= $0 }) ?? true {
                let done = prompter.isDone(cue: cue)
                let active = prompter.activeCue == cue
                text = text + space() + Text((done ? "✓ " : "▸ ") + script.cues[cue].text)
                    .font(.system(size: size * 0.8, weight: .bold, design: .rounded))
                    .foregroundColor(done ? .orange.opacity(0.45) : active ? .orange : .orange.opacity(0.85))
                nextCue = cues.next()
            } else if let word = nextWord {
                let said = word < prompter.position
                text = text + space() + Text(script.words[word].text)
                    .foregroundColor(said ? .white.opacity(0.32) : .white)
                nextWord = words.next()
            }
            first = false
        }
        return text
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .lineSpacing(size * 0.15)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(statusText)
            Spacer()
            Text("⌃⌥← →  line back / forward")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
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

/// ⌃⌥→ and ⌃⌥← for the teleprompter, as system hot keys: they work in any app and need no
/// permission. Registered only while the strip is showing.
final class PrompterHotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    fileprivate let action: (Int) -> Void

    private static let signature = OSType(0x5041_4E45)  // "PANE"
    private static let keys: [(code: Int, step: Int)] = [(kVK_RightArrow, 1), (kVK_LeftArrow, -1)]

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

