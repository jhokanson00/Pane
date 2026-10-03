import AppKit

/// While recording, shows you your camera in the same corner of the screen or window that
/// it will appear in the video.
/// Pane's windows are excluded from capture, so this is never recorded twice; clicks pass
/// straight through it.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?
    private var imageLayer: CALayer?
    /// The area being recorded (a screen or a window), in AppKit global coordinates.
    private var area: CGRect?

    var isVisible: Bool { panel != nil }

    func show(in area: CGRect, style: CameraStyle) {
        self.area = area
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let view = NSView()
            view.wantsLayer = true
            let imageLayer = CALayer()
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.masksToBounds = true
            view.layer?.addSublayer(imageLayer)
            panel.contentView = view

            self.panel = panel
            self.imageLayer = imageLayer
        }
        apply(style: style)
        panel?.orderFrontRegardless()
    }

    /// Moves and restyles the bubble to match `style`.
    func apply(style: CameraStyle) {
        guard let panel, let area, let root = panel.contentView?.layer, let imageLayer else { return }
        let layout = OverlayLayout(style: style, canvas: area.size, topLeftOrigin: false)
        let outer = layout.outerDiameter
        panel.setFrame(NSRect(
            x: area.minX + layout.center.x - outer / 2,
            y: area.minY + layout.center.y - outer / 2,
            width: outer, height: outer
        ), display: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.cornerRadius = outer / 2
        root.backgroundColor = layout.ring > 0 ? style.borderColor.cgColor : .clear
        imageLayer.frame = CGRect(x: layout.ring, y: layout.ring, width: layout.radius * 2, height: layout.radius * 2)
        imageLayer.cornerRadius = layout.radius
        CATransaction.commit()
    }

    func update(_ image: CGImage) {
        guard let imageLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        imageLayer = nil
        area = nil
    }
}
