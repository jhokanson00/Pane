import AVKit
import SwiftUI
import PaneKit

/// Review what Pane found, adjust the blur layers and pointer effects, and export a copy.
struct ReviewView: View {
    @ObservedObject var session: ReviewSession
    @State private var panel: Panel = .blur

    enum Panel: String, CaseIterable, Identifiable {
        case blur = "Blur", pointer = "Pointer"
        var id: Self { self }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    PlayerView(player: session.player)
                    LayerOverlay(session: session)
                }
                .aspectRatio(session.videoSize, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ToolBar(session: session)
                ReviewTimeline(session: session)

                if let notice = session.notice {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(notice)
                        Spacer()
                        Button("OK") { session.notice = nil }.controlSize(.small)
                    }
                    .font(.callout)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)

            Divider()

            VStack(spacing: 0) {
                Picker("", selection: $panel) {
                    ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 12)

                switch panel {
                case .blur: LayerList(session: session)
                case .pointer: PointerPanel(session: session)
                }
                Divider()
                ExportPanel(session: session)
            }
            .frame(width: 330)
        }
        .frame(minWidth: 980, minHeight: 600)
        .onExitCommand { session.tool = .none }
    }
}

// MARK: - Video overlay

/// AppKit's player view. (SwiftUI's VideoPlayer crashes when loaded from a Swift
/// package executable.)
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

/// Draws the blur layers on top of the video and handles drawing / picking.
private struct LayerOverlay: View {
    @ObservedObject var session: ReviewSession
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                ForEach(session.findings) { finding in
                    if let rect = visibleRect(finding) {
                        let frame = viewRect(rect, in: size)
                        layerShape(for: finding, frame: frame)
                    }
                }

                if let dragStart, let dragCurrent {
                    let frame = CGRect(origin: dragStart, size: .zero).union(CGRect(origin: dragCurrent, size: .zero))
                    let style = StrokeStyle(lineWidth: 2, dash: [6, 4])
                    Group {
                        if session.tool == .drawCircle {
                            Ellipse().strokeBorder(Color.accentColor, style: style)
                                .background(Ellipse().fill(Color.accentColor.opacity(0.15)))
                        } else {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, style: style)
                                .background(Color.accentColor.opacity(0.15))
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                }

                if session.tool != .none {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(gesture(in: size))
                        .onContinuousHover { phase in
                            if case .active = phase {
                                (session.tool == .pickText ? NSCursor.iBeam : NSCursor.crosshair).set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
                }
            }
        }
        .allowsHitTesting(session.tool != .none)
    }

    /// The video itself shows the blur, so enabled layers draw nothing extra; disabled
    /// ones show as a dashed outline.
    private func visibleRect(_ finding: Finding) -> CGRect? {
        var probe = finding
        probe.isEnabled = true
        return probe.coverRect(at: session.currentTime, aspect: session.videoSize.width / max(session.videoSize.height, 1))
    }

    @ViewBuilder
    private func layerShape(for finding: Finding, frame: CGRect) -> some View {
        if !finding.isEnabled {
            let style = StrokeStyle(lineWidth: 1.5, dash: [5, 4])
            Group {
                if finding.shape == .ellipse {
                    Ellipse().strokeBorder(finding.kind.color.opacity(0.8), style: style)
                } else {
                    RoundedRectangle(cornerRadius: min(frame.height, frame.width) * 0.25)
                        .strokeBorder(finding.kind.color.opacity(0.8), style: style)
                }
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
        }
    }

    private func viewRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        var rect = rect
        // Follow the zoom toward clicks, so outlines stay on what they mark.
        if let shown = session.previewZoom?.viewRect(at: session.currentTime) {
            rect = CGRect(x: (rect.minX - shown.minX) / shown.width, y: (rect.minY - shown.minY) / shown.height,
                          width: rect.width / shown.width, height: rect.height / shown.height)
        }
        return CGRect(x: rect.minX * size.width, y: (1 - rect.maxY) * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    private func gesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard session.tool.isDrawing else { return }
                dragStart = value.startLocation
                dragCurrent = value.location
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }
                switch session.tool {
                case .pickText:
                    session.pickText(at: CGPoint(x: value.location.x / size.width,
                                                 y: 1 - value.location.y / size.height))
                case .drawBox, .drawCircle:
                    let frame = CGRect(origin: value.startLocation, size: .zero)
                        .union(CGRect(origin: value.location, size: .zero))
                    guard frame.width > 6, frame.height > 6 else { return }
                    session.addShape(CGRect(x: frame.minX / size.width, y: 1 - frame.maxY / size.height,
                                            width: frame.width / size.width, height: frame.height / size.height),
                                     shape: session.tool == .drawCircle ? .ellipse : .rectangle)
                case .none:
                    break
                }
            }
    }
}

// MARK: - Toolbar

private struct ToolBar: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        HStack(spacing: 10) {
            Text("\(ReviewSession.format(session.currentTime)) / \(ReviewSession.format(session.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            switch session.tool {
            case .pickText:
                Text("Click any word in the video to blur it everywhere.").foregroundStyle(.secondary)
            case .drawBox, .drawCircle:
                Text("Drag over the area to blur. It stays blurred for the whole video.").foregroundStyle(.secondary)
            case .none:
                EmptyView()
            }

            Toggle(isOn: toolBinding(.pickText)) {
                Label("Blur Text", systemImage: "character.cursor.ibeam")
            }
            .disabled(session.scan == nil)
            .help(session.scan == nil
                  ? "Scan for sensitive info first; Blur Text uses what the scan read"
                  : "Click a word in the video to blur it wherever it appears")
            Toggle(isOn: toolBinding(.drawBox)) {
                Label("Draw Box", systemImage: "rectangle.dashed")
            }
            .help("Drag to blur an area for the whole video")
            Toggle(isOn: toolBinding(.drawCircle)) {
                Label("Draw Circle", systemImage: "circle.dashed")
            }
            .help("Drag to blur a round area for the whole video")
        }
        .toggleStyle(.button)
    }

    private func toolBinding(_ tool: ReviewSession.Tool) -> Binding<Bool> {
        Binding(
            get: { session.tool == tool },
            set: { on in
                session.tool = on ? tool : .none
                if on { session.player.pause() }
            }
        )
    }
}

// MARK: - Layer list

private struct LayerList: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blur layers").font(.headline)
                    Text("\(session.findings.filter(\.isEnabled).count) of \(session.findings.count) on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Turn All On") { session.setAll(enabled: true) }
                    Button("Turn All Off") { session.setAll(enabled: false) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(12)

            if session.scan == nil {
                ScanPrompt(session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            if session.findings.isEmpty {
                VStack(spacing: 8) {
                    if session.scan == nil {
                        Image(systemName: "rectangle.dashed").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No blur layers yet.")
                        Text("Use Draw Box or Draw Circle to blur an area.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.shield").font(.largeTitle).foregroundStyle(.green)
                        Text("Nothing sensitive was found.")
                        Text("Use Blur Text, Draw Box or Draw Circle to add your own.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($session.findings) { $finding in
                        LayerRow(finding: $finding, session: session)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

/// For a video that hasn't been scanned: scan it from here, and show the progress.
private struct ScanPrompt: View {
    @ObservedObject var session: ReviewSession
    @ObservedObject private var model = RecorderModel.shared

    /// The scan status belongs to whichever video the main window shows.
    private var state: RecorderModel.ScanState {
        model.lastRecordingURL == session.sourceURL ? model.scanState : .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.autoBlur {
                Text("Auto-blur is off, so this video wasn't scanned. Turn it on in Pane's main window to find "
                     + "emails, phone numbers and keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .scanning(let progress) = state {
                ProgressView(value: progress) {
                    Text("Scanning… \(Int(progress * 100))%").font(.caption)
                }
            } else {
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Text("Not scanned for sensitive info. Scan to find emails, phone numbers and keys, "
                     + "and to use Blur Text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Scan for Sensitive Info") { model.scan(for: session) }
                    .controlSize(.small)
                    .disabled(model.state != .idle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LayerRow: View {
    @Binding var finding: Finding
    @ObservedObject var session: ReviewSession

    private var isActiveNow: Bool {
        session.currentTime >= finding.start && session.currentTime <= finding.end
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $finding.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(systemName: finding.shape == .ellipse ? "circle.dashed" : finding.kind.symbol)
                .foregroundStyle(finding.kind.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(finding.maskedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(finding.isEnabled ? .primary : .secondary)
                Text("\(finding.kind.label) · \(ReviewSession.format(finding.start))–\(ReviewSession.format(finding.end))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if session.canRetime(finding) {
                    Button(role: .destructive) { session.remove(finding.id) } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.mini)
                    .help("Remove this blur. To change when it shows, drag its ends in the timeline.")
                }
            }

            Spacer(minLength: 0)

            if isActiveNow {
                Circle().fill(finding.kind.color).frame(width: 6, height: 6).padding(.top, 6)
                    .help("On screen now")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { session.seek(to: finding.start + 0.01) }
        .contextMenu {
            Button("Jump to Start") { session.seek(to: finding.start + 0.01) }
            Button("Remove Layer", role: .destructive) { session.remove(finding.id) }
        }
    }
}

// MARK: - Pointer

private struct PointerPanel: View {
    @ObservedObject var session: ReviewSession
    @ObservedObject private var model = RecorderModel.shared

    var body: some View {
        if session.pointer == nil {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines").font(.largeTitle).foregroundStyle(.secondary)
                Text("No pointer recording")
                Text("Pointer effects work on videos recorded with this version of Pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Toggle("Pointer effects", isOn: $model.pointerEffects)
                    .toggleStyle(.switch)
                    .font(.headline)
                    .padding([.horizontal, .top], 12)
                Group {
                    StyleControls(style: $session.pointerStyle)
                        .padding(12)
                    ShortcutBadgeToggle(session: session)
                    Divider()
                    ClickList(session: session)
                }
                .disabled(!model.pointerEffects)
            }
        }
    }
}

private struct StyleControls: View {
    @Binding var style: PointerEffectStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Highlight the pointer", isOn: $style.highlight)
            Toggle("Fade out when the pointer stops", isOn: $style.fadeWhenStill)
                .disabled(!style.highlight)
                .padding(.leading, 20)
            Toggle("Show clicks", isOn: $style.clicks)
            Toggle("Click sounds", isOn: $style.clickSounds)
                .help("A mouse click sound at every click in the exported video. Send to Final Cut puts each one on its own clip.")

            HStack {
                Text("Color")
                Spacer()
                ForEach(PointerEffectStyle.Tint.allCases) { tint in
                    let selected = style.tint == tint
                    Button { style.tint = tint } label: {
                        Circle()
                            .fill(Color(.sRGB, red: tint.rgb.r, green: tint.rgb.g, blue: tint.rgb.b))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.5),
                                                           lineWidth: selected ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(tint.label)
                }
            }
            .disabled(!style.highlight && !style.clicks)

            HStack {
                Text("Size")
                Spacer()
                Picker("", selection: $style.size) {
                    ForEach(PointerEffectStyle.Size.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            .disabled(!style.highlight && !style.clicks)

            HStack {
                Text("Zoom toward clicks")
                Spacer()
                Picker("", selection: $style.zoom) {
                    ForEach(PointerEffectStyle.Zoom.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            .help("Moves in closer just before each click and follows the pointer, then eases back out. "
                  + "Clicks close together share one zoom.")
        }
    }
}

private struct ClickList: View {
    @ObservedObject var session: ReviewSession

    private var clicks: Binding<[PointerTrack.Click]> {
        Binding(get: { session.pointer?.clicks ?? [] }, set: { session.pointer?.clicks = $0 })
    }

    var body: some View {
        let all = clicks.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clicks").font(.headline)
                    Text("\(all.filter(\.isEnabled).count) of \(all.count) shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Show All") { session.setAllClicks(enabled: true) }
                    Button("Hide All") { session.setAllClicks(enabled: false) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(12)

            if all.isEmpty {
                Text("No clicks in this recording.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(clicks) { $click in
                        ClickRow(click: $click, session: session)
                    }
                }
                .listStyle(.inset)
            }
        }
        .disabled(!session.pointerStyle.clicks && !session.pointerStyle.clickSounds)
    }
}

private struct ClickRow: View {
    @Binding var click: PointerTrack.Click
    @ObservedObject var session: ReviewSession

    private var description: (symbol: String, title: String) {
        switch (click.button, click.isHand) {
        case (.right, _): ("contextualmenu.and.cursorarrow", "Right-click")
        case (_, true): ("hand.point.up.left.fill", "Clicked a link or button")
        default: ("cursorarrow.click", "Click")
        }
    }

    private var isActiveNow: Bool {
        session.currentTime >= click.time && session.currentTime <= click.time + 0.6
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $click.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(systemName: description.symbol)
                .frame(width: 18)
                .foregroundStyle(click.isEnabled ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(description.title)
                    .foregroundStyle(click.isEnabled ? .primary : .secondary)
                Text(ReviewSession.format(click.time) + (click.duration > 0.4 ? " · held" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isActiveNow {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .help("Happening now")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { session.seek(to: max(0, click.time - 0.4)) }
    }
}

// MARK: - Export

private struct ExportPanel: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaptionsSection(session: session)
            switch session.exportState {
            case .idle, .failed:
                if case .failed(let message) = session.exportState {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                Button {
                    session.export()
                } label: {
                    Label("Export Video", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if ReviewSession.finalCut != nil {
                    Button {
                        session.sendToFinalCut()
                    } label: {
                        Label("Send to Final Cut", systemImage: "film.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help("Opens a Final Cut project with the screen (blurred, with pointer effects), the camera on its "
                          + "own layer, and a marker at every click")
                }
                Text("Saves a new copy with the blur and pointer effects. Your original recording stays unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .exporting(let progress):
                ProgressView(value: progress) {
                    Text(session.isSendingToFinalCut
                         ? "Preparing for Final Cut… \(Int(progress * 100))%"
                         : "Exporting… \(Int(progress * 100))%")
                }
                Button("Cancel") { session.cancelExport() }

            case .sentToFinalCut(let folder):
                Label("Opened in Final Cut Pro", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Pick a library in Final Cut to import into. The project is in the Pane event, and Final Cut "
                     + "uses the files from \(folder.lastPathComponent).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Spacer()
                    Button("Send Again") { session.sendToFinalCut() }
                    Button("Export Video") { session.export() }
                }
                .controlSize(.small)

            case .done(let url):
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(2)
                HStack {
                    Button("Play") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Spacer()
                    Button("Export Again") { session.export() }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
    }
}

extension SensitiveKind {
    var color: Color {
        switch self {
        case .email: .blue
        case .phone: .green
        case .secret: .orange
        case .cardNumber: .purple
        case .governmentID: .pink
        case .customWord: .teal
        case .manual: .gray
        }
    }
}
