import CoreImage

/// Something drawn onto each frame after the blurs: pointer effects, and anything else
/// added at export. Effects are applied in order, by export and by the review window's
/// preview alike.
public protocol FrameEffect: Sendable {
    /// Whether this frame has anything to draw; frames where no effect is active are
    /// copied unchanged, which is much faster.
    func isActive(at time: Double) -> Bool
    func apply(to frame: CIImage, at time: Double) -> CIImage
}

extension PointerRenderer: FrameEffect {}

extension [any FrameEffect] {
    /// Every active effect applied to `frame` in order.
    public func apply(to frame: CIImage, at time: Double) -> CIImage {
        reduce(frame) { image, effect in effect.isActive(at: time) ? effect.apply(to: image, at: time) : image }
    }

    public func isActive(at time: Double) -> Bool {
        contains { $0.isActive(at: time) }
    }
}
