import AVFoundation
import PaneKit

/// `pane-tool zoom-export`: exports a recording with the default pointer effects and
/// zoom toward clicks, and prints how the zoom moves so its smoothness can be checked.
enum ZoomTool {
    static func run(_ args: [String]) async throws {
        let usage = "usage: pane-tool zoom-export <video> <out.mp4> [subtle|strong] [--camera-separate]"
        let separate = args.contains("--camera-separate")
        let rest = args.filter { $0 != "--camera-separate" }
        guard rest.count == 3 || rest.count == 4 else { fail(usage) }
        let level = rest.count == 4 ? PointerEffectStyle.Zoom(rawValue: rest[3]) : .subtle
        guard let level, level != .off else { fail(usage) }

        let url = URL(fileURLWithPath: rest[1])
        guard var track = PointerTrack.load(from: url) else { fail("No pointer recording in \(rest[1])") }
        // As Send to Final Cut does when the camera is its own clip.
        if separate { track.cameraCircle = nil }
        guard let videoTrack = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { fail("No video") }
        let size = try await videoTrack.load(.naturalSize)
        let fps = Double(try await videoTrack.load(.nominalFrameRate))
        var style = PointerEffectStyle()
        style.zoom = level
        guard let zoom = ClickZoomEffect(track: track, zoom: level) else { fail("No clicks on the video to zoom toward") }
        let curve = zoom.zoom

        print("Zoom \(level.label) (\(level.scale)×), camera circle: \(track.cameraCircle.map { "\($0)" } ?? "none")")
        for stretch in curve.stretches {
            print(String(format: "stretch: clicks %.2f–%.2fs, zoomed %.2f–%.2fs", stretch.firstClick, stretch.lastClick,
                         stretch.firstClick - 0.4, stretch.lastClick + 1.6))
        }
        // Per video frame: how far the view moves and how much the scale changes, in
        // output pixels, and how sharply that movement changes.
        let step = 1 / max(fps, 1)
        var previous = curve.viewRect(at: 0)
        var previousMove = 0.0
        var worstMove = 0.0, worstChange = 0.0, worstScale = 0.0
        for t in stride(from: step, through: (track.samples.last?.time ?? 0) + 2, by: step) {
            let view = curve.viewRect(at: t)
            let scale = 1 / view.width
            let move = hypot(view.midX - previous.midX, view.midY - previous.midY) * size.width * scale
            worstMove = max(worstMove, move)
            worstChange = max(worstChange, abs(move - previousMove))
            worstScale = max(worstScale, abs(scale - 1 / previous.width))
            if view.minX < -1e-6 || view.minY < -1e-6 || view.maxX > 1 + 1e-6 || view.maxY > 1 + 1e-6 {
                print(String(format: "OUTSIDE THE VIDEO at %.2fs: %@", t, "\(view)"))
            }
            if curve.amount(at: t) > 0 && Int((t / step).rounded()) % 3 == 0 {
                print(String(format: "  %6.2fs  scale %.3f  center (%.3f, %.3f)  moved %.1f px", t, scale,
                             view.midX, view.midY, move))
            }
            previous = view
            previousMove = move
        }
        print(String(format: "Per frame at %.0f fps: view moved at most %.1f px, its speed changed at most %.1f px, "
                     + "scale changed at most %.4f", fps, worstMove, worstChange, worstScale))

        let start = Date()
        var effects: [any FrameEffect] = []
        if let renderer = PointerRenderer(track: track, style: style, videoSize: size) { effects.append(renderer) }
        effects.append(zoom)
        try await RedactionExporter.export(source: url, to: URL(fileURLWithPath: rest[2]), findings: [], effects: effects)
        print("Exported \(rest[2]) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }
}
