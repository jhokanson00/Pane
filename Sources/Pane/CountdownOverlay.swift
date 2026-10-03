import AppKit

/// The 3-2-1 shown before recording starts. Pane's own windows are excluded from
/// capture, so this never ends up in the video.
@MainActor
final class CountdownOverlay {
    private var panel: NSPanel?

    /// Returns false if `isCancelled` became true before the countdown finished.
    func run(seconds: Int, on screen: NSScreen?, isCancelled: () -> Bool) async -> Bool {
        let size: CGFloat = 160
        let screenFrame = (screen ?? NSScreen.main)?.frame ?? .zero
        let rect = NSRect(
            x: screenFrame.midX - size / 2, y: screenFrame.midY - size / 2,
            width: size, height: size
        )

        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 32

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 88, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        label.frame = NSRect(x: 0, y: (size - 110) / 2, width: size, height: 110)
        background.addSubview(label)

        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel
        defer {
            panel.orderOut(nil)
            self.panel = nil
        }

        for n in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(n)"
            try? await Task.sleep(for: .seconds(1))
            if isCancelled() { return false }
        }
        return true
    }
}
