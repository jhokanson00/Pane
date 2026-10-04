import AppKit
import SwiftUI
import PaneKit

// MARK: - Timing changes

extension ReviewSession {
    /// The part kept, whether or not the recording is trimmed.
    var keptRange: ClosedRange<Double> { trim ?? 0...duration }

    /// Moves one end of the kept part, keeping at least `Trim.minimumLength`.
    func setTrim(start: Double? = nil, end: Double? = nil) {
        guard duration > Trim.minimumLength else { return }
        var lower = keptRange.lowerBound, upper = keptRange.upperBound
        if let start { lower = min(max(start, 0), upper - Trim.minimumLength) }
        if let end { upper = max(min(end, duration), lower + Trim.minimumLength) }
        trim = Trim.normalized(lower...upper, duration: duration)
    }

    func clearTrim() {
        trim = nil
    }

    /// Blurs you drew and word-list blurs can start and stop anywhere. The ones the scan
    /// found keep the times it tracked the text for.
    func canRetime(_ finding: Finding) -> Bool {
        finding.kind == .manual || finding.kind == .customWord
    }

    /// Moves when a blur starts or stops, keeping it at least a tenth of a second long.
    func setTimes(of id: Finding.ID, start: Double? = nil, end: Double? = nil) {
        guard let index = findings.firstIndex(where: { $0.id == id }) else { return }
        if let start { findings[index].start = min(max(start, 0), findings[index].end - 0.1) }
        if let end { findings[index].end = max(min(end, duration), findings[index].start + 0.1) }
    }
}

// MARK: - Timeline

/// Everything in the recording laid out over time under the player: the video (drag its
/// ends to trim), each blur layer (drag the ends of the ones you can change), the clicks
/// and the captions, with a ruler and the playhead. Click anywhere to move the playhead.
struct ReviewTimeline: View {
    @ObservedObject var session: ReviewSession

    static let labelWidth: CGFloat = 150
    static let laneHeight: CGFloat = 18
    static let laneSpacing: CGFloat = 3

    private var clicks: [PointerTrack.Click] {
        (session.pointer?.clicks ?? []).filter(\.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Self.laneSpacing) {
                    Lane(label: { Text("") }) { width in Ruler(session: session, width: width) }
                    Lane(label: { LaneTitle(symbol: "film", text: "Video") }) { width in
                        TrimTrack(session: session, width: width)
                    }
                    if session.script != nil {
                        Lane(label: { RetakeLabel(session: session) }) { width in
                            RetakeTrack(session: session, width: width)
                        }
                    }
                    if !session.findings.isEmpty {
                        ScrollView(.vertical) {
                            VStack(spacing: Self.laneSpacing) {
                                ForEach($session.findings) { $finding in
                                    Lane(label: { FindingLabel(finding: $finding) }) { width in
                                        FindingTrack(session: session, finding: finding, width: width)
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.automatic)
                        .frame(height: min(CGFloat(session.findings.count), 6) * (Self.laneHeight + Self.laneSpacing))
                    }
                    if !clicks.isEmpty {
                        Lane(label: { LaneTitle(symbol: "cursorarrow.click", text: "Clicks") }) { width in
                            ClickTrack(session: session, clicks: clicks, width: width)
                        }
                    }
                    if let captions = session.exportCaptions, !captions.cues.isEmpty {
                        Lane(label: { LaneTitle(symbol: "captions.bubble", text: "Captions") }) { width in
                            CaptionTrack(session: session, captions: captions, width: width)
                        }
                    }
                }
                Playhead(session: session)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 8) {
                Text("Drag the ends of the Video bar to trim, and the ends of a blur to change when it shows.")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(summary)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !session.retakes.isEmpty {
                    if session.retakes.allSatisfy(\.isCut) {
                        Button("Keep All Retakes") { session.setAllRetakes(cut: false) }
                    } else {
                        Button("Cut All Retakes") { session.setAllRetakes(cut: true) }
                    }
                }
                if session.trim != nil {
                    Button("Clear Trim") { session.clearTrim() }
                        .help("Keep the whole video again")
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let trim = session.trim {
            parts.append("Keeping \(ReviewSession.format(trim.lowerBound))–\(ReviewSession.format(trim.upperBound)) "
                         + "(\(ReviewSession.format(trim.upperBound - trim.lowerBound)))")
        }
        let cut = session.retakes.filter(\.isCut).count
        if cut > 0 {
            parts.append("cutting \(cut) retake\(cut == 1 ? "" : "s") (\(String(format: "%.1f", session.cutLength)) s)")
        }
        guard !parts.isEmpty else { return "Keeping the whole video" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// A label on the left and a track on the right, the track as wide as all the others.
private struct Lane<Label: View, Track: View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var track: (CGFloat) -> Track

    var body: some View {
        HStack(spacing: 0) {
            label()
                .frame(width: ReviewTimeline.labelWidth, alignment: .leading)
            GeometryReader { geo in
                track(geo.size.width)
            }
            .frame(height: ReviewTimeline.laneHeight)
        }
    }
}

private struct LaneTitle: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).frame(width: 16)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct FindingLabel: View {
    @Binding var finding: Finding

    var body: some View {
        HStack(spacing: 5) {
            Toggle("", isOn: $finding.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Image(systemName: finding.shape == .ellipse ? "circle.dashed" : finding.kind.symbol)
                .foregroundStyle(finding.kind.color)
                .frame(width: 14)
            Text(finding.maskedText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(finding.isEnabled ? .primary : .secondary)
        }
        .font(.caption)
        .padding(.trailing, 8)
    }
}

/// Seconds to x and back, for a track `width` wide.
private struct TimeScale {
    let duration: Double
    let width: CGFloat

    func x(_ time: Double) -> CGFloat { width * CGFloat(min(max(time / max(duration, 0.001), 0), 1)) }
    func time(_ x: CGFloat) -> Double { duration * Double(min(max(x / max(width, 1), 0), 1)) }
}

/// Click or drag on a track's empty part to move the playhead.
private struct SeekArea: View {
    @ObservedObject var session: ReviewSession
    let width: CGFloat

    var body: some View {
        let scale = TimeScale(duration: session.duration, width: width)
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.secondary.opacity(0.08))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                session.seek(to: scale.time(value.location.x))
            })
    }
}

/// A grab handle for one end of a bar: a thin rounded bar, with a wider invisible area
/// to grab and the left-right resize pointer over it.
private struct EdgeHandle: View {
    let color: Color
    let onDrag: (CGFloat) -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 4)
            .frame(width: 12, height: ReviewTimeline.laneHeight)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { value in
                onDrag(value.location.x)
            })
    }
}

private struct Ruler: View {
    @ObservedObject var session: ReviewSession
    let width: CGFloat

    var body: some View {
        let scale = TimeScale(duration: session.duration, width: width)
        let step = Self.step(duration: session.duration, width: width)
        let marks = stride(from: 0, through: session.duration, by: step).map { $0 }
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(marks, id: \.self) { time in
                VStack(alignment: .leading, spacing: 1) {
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 4)
                    Text(ReviewSession.format(time))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .offset(x: scale.x(time))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            session.seek(to: scale.time(value.location.x))
        })
    }

    /// A round number of seconds between labels, leaving room for each.
    static func step(duration: Double, width: CGFloat) -> Double {
        let fits = max(Double(width) / 70, 1)
        return [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800].first { duration / $0 <= fits } ?? 3600
    }
}

/// The whole recording, the kept part in color with a handle at each end.
private struct TrimTrack: View {
    @ObservedObject var session: ReviewSession
    let width: CGFloat

    var body: some View {
        let scale = TimeScale(duration: session.duration, width: width)
        let kept = session.keptRange
        let start = scale.x(kept.lowerBound), end = scale.x(kept.upperBound)
        ZStack(alignment: .leading) {
            SeekArea(session: session, width: width)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.15))
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(session.trim == nil ? 0.35 : 0.55))
                .frame(width: max(end - start, 2))
                .offset(x: start)
                .allowsHitTesting(false)
            // What the cut retakes leave out.
            ForEach(Array(session.cuts.enumerated()), id: \.offset) { _, cut in
                Rectangle()
                    .fill(Color.red.opacity(0.45))
                    .frame(width: max(scale.x(cut.upperBound) - scale.x(cut.lowerBound), 2))
                    .offset(x: scale.x(cut.lowerBound))
                    .allowsHitTesting(false)
            }
            EdgeHandle(color: .accentColor) { x in
                session.setTrim(start: scale.time(x))
                session.seek(to: session.keptRange.lowerBound)
            }
            .offset(x: start - 6)
            .help("Drag to cut off the start")
            EdgeHandle(color: .accentColor) { x in
                session.setTrim(end: scale.time(x))
                session.seek(to: session.keptRange.upperBound)
            }
            .offset(x: end - 6)
            .help("Drag to cut off the end")
        }
        .coordinateSpace(name: "track")
    }
}

/// When one blur layer shows. Click it to jump to its start.
private struct FindingTrack: View {
    @ObservedObject var session: ReviewSession
    let finding: Finding
    let width: CGFloat

    var body: some View {
        let scale = TimeScale(duration: session.duration, width: width)
        let start = scale.x(finding.start), end = scale.x(finding.end)
        let color = finding.kind.color
        ZStack(alignment: .leading) {
            SeekArea(session: session, width: width)
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(finding.isEnabled ? 0.55 : 0.18))
                .frame(width: max(end - start, 3), height: ReviewTimeline.laneHeight - 4)
                .offset(x: start)
                .onTapGesture { session.seek(to: finding.start + 0.01) }
                .help("\(finding.kind.label) · \(ReviewSession.format(finding.start))–\(ReviewSession.format(finding.end))")
            if session.canRetime(finding) {
                EdgeHandle(color: color) { x in
                    session.setTimes(of: finding.id, start: scale.time(x))
                    session.seek(to: session.findings.first { $0.id == finding.id }?.start ?? 0)
                }
                .offset(x: start - 6)
                .help("Drag to change when this blur starts")
                EdgeHandle(color: color) { x in
                    session.setTimes(of: finding.id, end: scale.time(x))
                    session.seek(to: session.findings.first { $0.id == finding.id }?.end ?? 0)
                }
                .offset(x: end - 6)
                .help("Drag to change when this blur stops")
            }
        }
        .coordinateSpace(name: "track")
    }
}

/// A tick at each click shown. Click one to jump to just before it.
private struct ClickTrack: View {
    @ObservedObject var session: ReviewSession
    let clicks: [PointerTrack.Click]
    let width: CGFloat

    var body: some View {
        let scale = TimeScale(duration: session.duration, width: width)
        ZStack(alignment: .leading) {
            SeekArea(session: session, width: width)
            ForEach(clicks.indices, id: \.self) { index in
                let click = clicks[index]
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 3, height: ReviewTimeline.laneHeight - 6)
                    .frame(width: 9, height: ReviewTimeline.laneHeight)
                    .contentShape(Rectangle())
                    .offset(x: scale.x(click.time) - 4.5)
                    .onTapGesture { session.seek(to: max(click.time - 0.4, 0)) }
                    .help("Click at \(ReviewSession.format(click.time))")
            }
        }
    }
}

/// Each caption, where it shows.
private struct CaptionTrack: View {
    @ObservedObject var session: ReviewSession
    let captions: Captions
    let width: CGFloat

    var body: some View {
        let scale = TimeScale(duration: session.duration, width: width)
        ZStack(alignment: .leading) {
            SeekArea(session: session, width: width)
            ForEach(captions.cues.indices, id: \.self) { index in
                let cue = captions.cues[index]
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: max(scale.x(cue.end) - scale.x(cue.start) - 1, 2), height: ReviewTimeline.laneHeight - 4)
                    .offset(x: scale.x(cue.start))
                    .onTapGesture { session.seek(to: cue.start + 0.01) }
                    .help(cue.text)
            }
        }
    }
}

/// The playhead, a line down through every lane.
private struct Playhead: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - ReviewTimeline.labelWidth
            let x = ReviewTimeline.labelWidth + TimeScale(duration: session.duration, width: width).x(session.currentTime)
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: geo.size.height)
                .offset(x: x - 1)
        }
    }
}

// MARK: - Retakes

private struct RetakeLabel: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.uturn.backward").frame(width: 16)
            switch session.retakeState {
            case .working(let text):
                ProgressView().controlSize(.mini)
                Text(text).lineLimit(1)
            case .failed:
                Text("Retakes: couldn't look").lineLimit(1)
            case .idle:
                Text(session.retakes.isEmpty ? "No retakes" : "Retakes")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(session.retakeState.failureMessage ?? "Sentences you said again. Click one to keep or cut its first try.")
    }
}

/// Each retake's first try: red when it's cut from exports, an outline when it's kept.
/// Click one to switch.
private struct RetakeTrack: View {
    @ObservedObject var session: ReviewSession
    let width: CGFloat

    var body: some View {
        let scale = TimeScale(duration: session.duration, width: width)
        ZStack(alignment: .leading) {
            SeekArea(session: session, width: width)
            ForEach(session.retakes) { item in
                let start = scale.x(item.retake.cut.lowerBound)
                let length = max(scale.x(item.retake.cut.upperBound) - start, 4)
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.isCut ? Color.red.opacity(0.7) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.red.opacity(0.8), lineWidth: 1))
                    .frame(width: length)
                    .offset(x: start)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        session.setRetake(item.id, cut: !item.isCut)
                        session.seek(to: item.retake.cut.lowerBound)
                    }
                    .help((item.isCut ? "Cut: " : "Kept: ") + "\"\(item.retake.text)…\" said again. Click to "
                          + (item.isCut ? "keep this try." : "cut this try."))
            }
        }
        .coordinateSpace(name: "track")
    }
}

extension ReviewSession.RetakeState {
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
