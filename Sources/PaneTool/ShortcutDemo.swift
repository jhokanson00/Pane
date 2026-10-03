import CoreGraphics
import PaneKit

/// Scripted keyboard shortcuts over the 5-second sample video: one alone, one pressed
/// three times, quick replacements, every modifier at once, keys pressed alone, and a
/// fade out at the end.
enum ShortcutDemo {
    static let presses: [(time: Double, modifiers: KeyModifiers, key: String)] = [
        (0.2, [.command], "S"),
        (0.9, [.command], "Z"),
        (1.15, [.command], "Z"),
        (1.4, [.command], "Z"),
        (2.0, [.command, .shift], "R"),
        (2.4, [.control, .option, .shift, .command], "K"),
        (2.8, [.command], "Space"),
        (3.0, [], "Esc"),
        // Fades out from 4.3 s and is gone at 4.7 s.
        (3.2, [.option], "←"),
    ]

    /// - Parameter camera: Add a large camera circle near the bottom middle, so the badge
    ///   has to move out of its way.
    static func track(camera: Bool) -> ShortcutTrack {
        ShortcutTrack(
            presses: presses.map { .init(time: $0.time, shortcut: KeyShortcut(modifiers: $0.modifiers, key: $0.key)) },
            // 250 px across in the 1280×720 sample, its left edge just right of center.
            cameraCircle: camera ? CGRect(x: 0.53, y: 0.03, width: 250.0 / 1280, height: 250.0 / 720) : nil)
    }
}
