import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaneKit

/// The window Pane opens to: set up camera, audio and privacy, then press Record.
struct MainView: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                LayoutPreview(feed: model.cameraFeed)
                Text(model.cameraEnabled ? "Click a corner to move your camera." : "Camera is off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let problem = model.problem {
                    ProblemView(problem: problem)
                }
                if let url = model.lastRecordingURL {
                    LastRecordingRow(url: url)
                }

                Spacer(minLength: 0)
                HStack {
                    Button("How to Use Pane") { WindowPresenter.showHelp() }
                        .buttonStyle(.link)
                        .help("A short guide to recording, blurring and exporting (⌘?)")
                    Spacer()
                    Button("Blur an Existing Video…") { model.chooseVideoToReview() }
                        .buttonStyle(.link)
                        .help("Scan any video for sensitive info. You can also drop a video on Pane's Dock icon.")
                }
                VideoNameField()
                RecordButton()
            }
            .padding(20)
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            SettingsForm()
                .frame(width: 340)
        }
        .frame(minHeight: 520)
        .sheet(isPresented: $model.isChoosingWindow) {
            WindowPickerSheet()
                .environmentObject(model)
        }
    }
}

// MARK: - Preview

/// A mock of your screen showing exactly where the camera circle will sit in the video.
private struct LayoutPreview: View {
    @EnvironmentObject private var model: RecorderModel
    @ObservedObject var feed: CameraFeed

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if model.captureMode == .window, let thumbnail = model.selectedWindow?.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color(white: 0.22), Color(white: 0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    // A stand-in "app window" so the preview reads as a screen.
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: size.width * 0.56, height: size.height * 0.58)
                        .offset(x: size.width * 0.22, y: size.height * 0.18)
                }

                if model.cameraEnabled {
                    let layout = OverlayLayout(style: model.cameraStyle, canvas: size, topLeftOrigin: true)
                    CameraCircle(image: feed.image, layout: layout, borderColor: model.cameraStyle.borderColor.color)
                        .position(layout.center)
                        .animation(.snappy, value: model.cameraStyle)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard model.cameraEnabled else { return }
                let left = location.x < size.width / 2
                let top = location.y < size.height / 2
                model.cameraStyle.corner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
            }
        }
        .aspectRatio(model.displayAspectRatio, contentMode: .fit)
    }
}

private struct CameraCircle: View {
    let image: CGImage?
    let layout: OverlayLayout
    let borderColor: Color

    var body: some View {
        let diameter = layout.radius * 2
        ZStack {
            if layout.ring > 0 {
                Circle().fill(borderColor).frame(width: layout.outerDiameter, height: layout.outerDiameter)
            }
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.black.opacity(0.6)
                        Image(systemName: "video").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

// MARK: - Controls

/// What the next recording is called, and the folder it will go in.
private struct VideoNameField: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Name")
                TextField("Untitled", text: $model.videoTitle)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.state != .idle)
            }
            Text("Saves as \u{201C}\(VideoLibrary.uniqueName(title: model.videoTitle, date: Date(), in: RecorderModel.recordingsFolder))\u{201D} "
                 + "in its own folder in Movies \u{25B8} Pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("Another recording with the same name today becomes Take 2. A script that starts with "
              + "a line like \u{201C}# Share a Project\u{201D} fills this in.")
    }
}

private struct RecordButton: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        Button {
            Task { await model.startRecording() }
        } label: {
            Label("Start Recording", systemImage: "record.circle.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.extraLarge)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(model.state != .idle)
        .help("Start recording (⇧⌘R). Stop from the menu bar.")
    }
}

private struct LastRecordingRow: View {
    @EnvironmentObject private var model: RecorderModel
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved \(url.deletingPathExtension().lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Play") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }

            HStack {
                switch model.scanState {
                case .idle:
                    Text(model.autoBlur ? "Not scanned for sensitive info." : "Auto-blur is off.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review") { model.reviewLastRecording() }
                        .help("Draw blur boxes and circles and set up pointer effects, without scanning")
                    if model.autoBlur {
                        Button("Scan & Review") { model.scanLastRecording() }
                    }
                case .scanning(let progress):
                    ProgressView(value: progress) {
                        Text(progress == 0
                             ? "Getting ready… the first scan after installing Pane can take about 30 seconds."
                             : progress < 0.6
                             ? "Checking for sensitive info… \(Int(progress * 100))%"
                             : "Making sure the blurs cover it… \(Int(progress * 100))%")
                    }
                case .finished(let found):
                    Image(systemName: found == 0 ? "checkmark.shield" : "eye.slash")
                        .foregroundStyle(found == 0 ? .green : .orange)
                    Text(found == 0 ? "Nothing sensitive found." : "Found \(found) item\(found == 1 ? "" : "s") to blur.")
                    Spacer()
                    Button("Review") { model.reviewLastRecording() }
                case .addingPointer(let progress):
                    ProgressView(value: progress) {
                        Text("Adding pointer effects… \(Int(progress * 100))%")
                    }
                case .exported(let edited):
                    Image(systemName: "cursorarrow.click.2").foregroundStyle(.green)
                    Text("Saved a copy with pointer effects.")
                    Spacer()
                    Button("Play") { NSWorkspace.shared.open(edited) }
                    Button("Review") { model.reviewLastRecording() }
                        .help("Draw blur boxes and circles, or change the pointer effects, then export again")
                case .failed(let message):
                    WarningText(message, lineLimit: 2)
                    Spacer()
                    Button("Try Again") { model.autoBlur ? model.scanLastRecording() : model.addPointerEffects() }
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ProblemView: View {
    @EnvironmentObject private var model: RecorderModel
    let problem: RecorderModel.Problem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WarningText(problem.message)
            // Side by side when there's room; stacked in the narrow menu bar panel.
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.35)))
    }

    @ViewBuilder
    private var buttons: some View {
        if case .permission(let pane, _) = problem {
            Button("Open Settings") { Permissions.openSettings(pane) }
            // Reopening ends a recording, so it's only offered when idle.
            if pane == .screenRecording || pane == .inputMonitoring, model.state == .idle {
                Button("Quit & Reopen") { Permissions.relaunch() }
            }
        }
        Button("Dismiss") { model.problem = nil }
    }
}

/// A warning that stays readable on any background: the icon carries the color, the text
/// stays in the normal text color.
struct WarningText: View {
    let message: String
    var font: Font = .callout
    var lineLimit: Int?

    init(_ message: String, font: Font = .callout, lineLimit: Int? = nil) {
        self.message = message
        self.font = font
        self.lineLimit = lineLimit
    }

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .font(font)
    }
}

// MARK: - Settings

/// Words and phrases to always blur, one per line.
private struct WordListSheet: View {
    @EnvironmentObject private var model: RecorderModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Always blur these words").font(.headline)
            Text("One per line: names, client names, project code names, anything. Matching ignores upper and lower case.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 200)
                .border(.separator)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.customWords = text
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { text = model.customWords.joined(separator: "\n") }
    }
}

/// A color picker for one CameraStyle color.
///
/// The picker owns the exact Color it hands out. Feeding it back a converted copy (our
/// saved sRGB value) makes macOS disconnect the color well from the Colors window after
/// the first pick, so later picks are silently ignored.
private struct StyleColorPicker: View {
    @EnvironmentObject private var model: RecorderModel
    let title: String
    let keyPath: WritableKeyPath<CameraStyle, RGBA>
    @State private var color: Color?

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { color ?? model.cameraStyle[keyPath: keyPath].color },
            set: { newColor in
                color = newColor
                model.cameraStyle[keyPath: keyPath] = RGBA(newColor)
            }
        ), supportsOpacity: false)
    }
}

private struct SettingsForm: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var isEditingWords = false

    var body: some View {
        Form {
            Section("Record") {
                Picker("Record", selection: $model.captureMode) {
                    ForEach(RecorderModel.CaptureMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.captureMode {
                case .display:
                    if NSScreen.screens.count > 1 {
                        Picker("Display", selection: $model.selectedDisplayID) {
                            Text("Main display").tag(CGDirectDisplayID?.none)
                            ForEach(NSScreen.screens, id: \.displayID) { screen in
                                Text(screen.localizedName).tag(screen.displayID)
                            }
                        }
                    }
                    Toggle("Hide desktop icons", isOn: $model.hideDesktopIcons)
                        .help("Leaves the icons on your desktop out of the recording. They stay on your desktop. Notifications are always left out.")
                case .window:
                    HStack {
                        if let window = model.selectedWindow {
                            if let icon = window.appIcon {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            }
                            VStack(alignment: .leading) {
                                Text(window.displayTitle).lineLimit(1)
                                Text(window.appName).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No window chosen").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.selectedWindow == nil ? "Choose…" : "Change…") {
                            model.isChoosingWindow = true
                        }
                    }
                }
            }

            Section("Camera") {
                Toggle("Show camera", isOn: $model.cameraEnabled)
                if model.cameraEnabled {
                    Picker("Camera", selection: $model.cameraID) {
                        Text("Default").tag(String?.none)
                        ForEach(Devices.cameras, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(Optional(device.uniqueID))
                        }
                    }
                    Picker("Corner", selection: $model.cameraStyle.corner) {
                        ForEach(CameraStyle.Corner.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Size", selection: $model.cameraStyle.size) {
                        ForEach(CameraStyle.Size.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Mirror", isOn: $model.cameraStyle.mirrored)
                    Toggle("Show bubble on screen while recording", isOn: $model.cameraStyle.showBubbleWhileRecording)
                    Toggle("Keep the camera as its own clip for Final Cut", isOn: $model.finalCutClips)
                        .help("Also saves the screen and the camera separately, so Send to Final Cut puts the camera on "
                              + "its own layer you can move, resize or cut. Uses more disk space.")
                }
            }

            if model.cameraEnabled {
                Section("Camera background") {
                    Picker("Background", selection: $model.cameraStyle.background) {
                        ForEach(CameraStyle.Background.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch model.cameraStyle.background {
                    case .color:
                        StyleColorPicker(title: "Color", keyPath: \.backgroundColor)
                    case .image:
                        HStack {
                            Text(model.cameraStyle.backgroundImagePath.map {
                                URL(fileURLWithPath: $0).lastPathComponent
                            } ?? "No image chosen")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            Spacer()
                            Button("Choose…", action: chooseBackgroundImage)
                        }
                    case .none, .blur:
                        EmptyView()
                    }

                    Toggle("Border", isOn: $model.cameraStyle.borderEnabled)
                    if model.cameraStyle.borderEnabled {
                        StyleColorPicker(title: "Border color", keyPath: \.borderColor)
                    }
                }
            }

            Section("Audio") {
                Toggle("Microphone", isOn: $model.micEnabled)
                if model.micEnabled {
                    Picker("Mic", selection: $model.micID) {
                        Text("Default").tag(String?.none)
                        ForEach(Devices.microphones, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(Optional(device.uniqueID))
                        }
                    }
                }
                Toggle("System audio", isOn: $model.systemAudioEnabled)
                    .help("Sound from apps, like a video you're demoing.")
            }

            Section {
                Toggle(isOn: $model.autoBlur) {
                    VStack(alignment: .leading) {
                        Text("Auto-blur")
                        Text(model.autoBlur
                             ? "Each recording is scanned when it stops, and what's found is blurred."
                             : "Off. Recordings open in Review, where you can draw boxes and circles to blur.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Group {
                    Toggle("Emails & phone numbers", isOn: kinds([.email, .phone]))
                    Toggle("Keys, tokens & passwords", isOn: kinds([.secret]))
                    Toggle("Card & ID numbers", isOn: kinds([.cardNumber, .governmentID]))
                    Toggle("My word list", isOn: kinds([.customWord]))
                    if model.detectedKinds.contains(.customWord) {
                        HStack {
                            Text(model.customWords.isEmpty
                                 ? "No words yet"
                                 : model.customWords.prefix(3).joined(separator: ", ") + (model.customWords.count > 3 ? "…" : ""))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Edit…") { isEditingWords = true }
                        }
                    }
                }
                .disabled(!model.autoBlur)
            } header: {
                Text("Auto-blur")
            }

            Section("Pointer") {
                Toggle(isOn: $model.pointerEffects) {
                    VStack(alignment: .leading) {
                        Text("Pointer effects")
                        Text(model.pointerEffects
                             ? (model.autoBlur
                                ? "A highlight follows the pointer and clicks show as rings, in Review and exports."
                                : "Each recording gets a copy with a pointer highlight and click rings as soon as it stops.")
                             : "Off. Exports show the pointer as it was recorded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                ShortcutSetting()
            }

            PrompterSetting()

            Section("Privacy") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Never record")
                        Text("\(model.hiddenBundleIDs.count) apps hidden from recordings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { WindowPresenter.showHiddenApps() }
                }
                Button("Open Recordings Folder") {
                    try? FileManager.default.createDirectory(
                        at: RecorderModel.recordingsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(RecorderModel.recordingsFolder)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditingWords) {
            WordListSheet()
        }
    }

    /// One toggle that turns a group of detection types on or off together.
    private func kinds(_ group: Set<SensitiveKind>) -> Binding<Bool> {
        Binding(
            get: { group.isSubset(of: model.detectedKinds) },
            set: { on in
                if on { model.detectedKinds.formUnion(group) } else { model.detectedKinds.subtract(group) }
            }
        )
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setBackgroundImage(from: url)
    }
}

/// The teleprompter's switch in the main window, with the script a click away.
private struct PrompterSetting: View {
    @ObservedObject private var prompter = PrompterController.shared

    var body: some View {
        Section("Teleprompter") {
            Toggle(isOn: $prompter.enabled) {
                VStack(alignment: .leading) {
                    Text("Show while recording")
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!prompter.isAvailable)
            HStack {
                Text(prompter.hasScript ? "\(prompter.script.lines.filter { !$0.words.isEmpty }.count) lines ready" : "No script yet")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(prompter.hasScript ? "Edit Script…" : "Write Script…") { WindowPresenter.showPrompter() }
            }
        }
    }

    private var caption: String {
        guard prompter.isAvailable else { return "Needs macOS 26 or later." }
        return "Your script at the top of the screen, following your voice as you speak. Never in the recording."
    }
}
