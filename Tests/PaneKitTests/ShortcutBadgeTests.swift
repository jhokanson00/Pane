import CoreGraphics
import CoreImage
import XCTest
@testable import PaneKit

final class ShortcutBadgeTests: XCTestCase {
    // US layout key codes.
    let r: UInt16 = 15, a: UInt16 = 0, z: UInt16 = 6, two: UInt16 = 19
    let space: UInt16 = 49, escape: UInt16 = 53, ret: UInt16 = 36, tab: UInt16 = 48, delete: UInt16 = 51
    let left: UInt16 = 123, f5: UInt16 = 96

    // MARK: - Names

    func testModifiersUseApplesOrder() {
        XCTAssertEqual(KeyShortcut(modifiers: [.command, .shift], key: "R").label, "⇧ ⌘ R")
        XCTAssertEqual(KeyShortcut(modifiers: [.command, .shift, .option, .control], key: "K").label, "⌃ ⌥ ⇧ ⌘ K")
        XCTAssertEqual(KeyShortcut(modifiers: [], key: "Esc").label, "Esc")
    }

    func testModifiersFromEventFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskSecondaryFn, .maskAlphaShift, .maskNumericPad]
        XCTAssertEqual(KeyModifiers(flags), [.command, .shift], "Fn and Caps Lock aren't part of a shortcut")
        XCTAssertEqual(KeyModifiers([.maskControl, .maskAlternate]), [.control, .option])
    }

    func testKeyNames() {
        XCTAssertEqual(KeyNames.name(keyCode: space, characters: " "), "Space")
        XCTAssertEqual(KeyNames.name(keyCode: ret, characters: "\r"), "Return")
        XCTAssertEqual(KeyNames.name(keyCode: escape, characters: "\u{1b}"), "Esc")
        XCTAssertEqual(KeyNames.name(keyCode: tab, characters: "\t"), "Tab")
        XCTAssertEqual(KeyNames.name(keyCode: delete, characters: "\u{7f}"), "Delete")
        XCTAssertEqual(KeyNames.name(keyCode: left, characters: nil), "←")
        XCTAssertEqual(KeyNames.name(keyCode: 124, characters: nil), "→")
        XCTAssertEqual(KeyNames.name(keyCode: 126, characters: nil), "↑")
        XCTAssertEqual(KeyNames.name(keyCode: 125, characters: nil), "↓")
        XCTAssertEqual(KeyNames.name(keyCode: 122, characters: nil), "F1")
        XCTAssertEqual(KeyNames.name(keyCode: f5, characters: nil), "F5")
        XCTAssertEqual(KeyNames.name(keyCode: 111, characters: nil), "F12")
    }

    func testCharacterKeysUseTheLayoutThenFallBackToUS() {
        XCTAssertEqual(KeyNames.name(keyCode: r, characters: "r"), "R")
        XCTAssertEqual(KeyNames.name(keyCode: two, characters: "2"), "2")
        // A French layout types "a" on the US Q key: show what the user's key says.
        XCTAssertEqual(KeyNames.name(keyCode: 12, characters: "a"), "A")
        // No usable characters (a dead key, or Control's control character): US names.
        XCTAssertEqual(KeyNames.name(keyCode: z, characters: nil), "Z")
        XCTAssertEqual(KeyNames.name(keyCode: a, characters: "\u{1}"), "A")
        XCTAssertEqual(KeyNames.name(keyCode: 42, characters: ""), "\\")
    }

    // MARK: - What gets logged

    func testPlainTypingIsNeverLogged() {
        for code in KeyNames.us.keys {
            for modifiers: KeyModifiers in [[], [.shift], [.option], [.option, .shift]] {
                XCTAssertFalse(KeyShortcut.shouldLog(keyCode: code, modifiers: modifiers),
                               "key \(code) with \(modifiers.symbols) types text")
            }
        }
        XCTAssertFalse(KeyShortcut.shouldLog(keyCode: space, modifiers: []), "Space is typing")
        XCTAssertFalse(KeyShortcut.shouldLog(keyCode: space, modifiers: [.shift]))
    }

    func testTypedCharactersAreNeverRead() {
        var asked = false
        let shortcut = KeyShortcut.logged(keyCode: a, modifiers: [.shift]) {
            asked = true
            return "A"
        }
        XCTAssertNil(shortcut)
        XCTAssertFalse(asked, "the characters of ordinary typing must not even be looked at")
    }

    func testShortcutsAreLogged() {
        XCTAssertEqual(KeyShortcut.logged(keyCode: r, modifiers: [.command, .shift]) { "r" }?.label, "⇧ ⌘ R")
        XCTAssertEqual(KeyShortcut.logged(keyCode: a, modifiers: [.control]) { "a" }?.label, "⌃ A")
        XCTAssertEqual(KeyShortcut.logged(keyCode: space, modifiers: [.command]) { " " }?.label, "⌘ Space")
        XCTAssertEqual(KeyShortcut.logged(keyCode: f5, modifiers: [.option, .command]) { nil }?.label, "⌥ ⌘ F5")
    }

    func testNonTypingKeysAreLoggedAlone() {
        for code in [escape, ret, tab, delete, left, 124, 125, 126, 122, f5, 111] {
            XCTAssertTrue(KeyShortcut.shouldLog(keyCode: code, modifiers: []), "key \(code)")
        }
        XCTAssertEqual(KeyShortcut.logged(keyCode: tab, modifiers: [.shift]) { "\t" }?.label, "⇧ Tab")
        XCTAssertEqual(KeyShortcut.logged(keyCode: left, modifiers: [.option]) { nil }?.label, "⌥ ←")
    }

    // MARK: - Timing

    func press(_ time: Double, _ key: String, _ modifiers: KeyModifiers = [.command]) -> ShortcutTrack.Press {
        .init(time: time, shortcut: KeyShortcut(modifiers: modifiers, key: key))
    }

    func testBadgeFadesInAndOut() throws {
        let timeline = ShortcutBadgeTimeline(presses: [press(1, "S")])
        XCTAssertNil(timeline.state(at: 0.99))
        XCTAssertEqual(timeline.state(at: 1.0)?.opacity ?? 0, 0, accuracy: 0.001, "starts invisible")
        XCTAssertEqual(try XCTUnwrap(timeline.state(at: 1.06)).opacity, 0.5, accuracy: 0.01, "halfway through fading in")
        XCTAssertEqual(try XCTUnwrap(timeline.state(at: 1.5)).opacity, 1)
        XCTAssertEqual(try XCTUnwrap(timeline.state(at: 2.1)).opacity, 1, "fully up until the fade out")
        let fading = try XCTUnwrap(timeline.state(at: 2.3)).opacity
        XCTAssertGreaterThan(fading, 0.1)
        XCTAssertLessThan(fading, 0.9)
        XCTAssertNil(timeline.state(at: 2.5), "gone 1.5 s after the press")
        XCTAssertEqual(timeline.state(at: 1.5)?.text, "⌘ S")
    }

    func testNewShortcutReplacesTheBadgeImmediately() throws {
        let timeline = ShortcutBadgeTimeline(presses: [press(1, "C"), press(1.6, "V")])
        XCTAssertEqual(timeline.state(at: 1.59)?.label, "⌘ C")
        let swapped = try XCTUnwrap(timeline.state(at: 1.6))
        XCTAssertEqual(swapped.label, "⌘ V")
        XCTAssertEqual(swapped.opacity, 1, accuracy: 0.001, "no flicker: starts as strong as the one it replaced")
        XCTAssertEqual(timeline.state(at: 2.8)?.label, "⌘ V", "the old badge's fade doesn't cut the new one short")
        XCTAssertNil(timeline.state(at: 3.1))
    }

    func testRepeatedPressesCount() throws {
        let timeline = ShortcutBadgeTimeline(presses: [press(1, "Z"), press(1.4, "Z"), press(2.5, "Z"), press(5, "Z")])
        XCTAssertEqual(timeline.state(at: 1.2)?.text, "⌘ Z")
        XCTAssertEqual(timeline.state(at: 1.5)?.text, "⌘ Z  ×2")
        XCTAssertEqual(timeline.state(at: 2.6)?.text, "⌘ Z  ×3", "a repeat within the badge's life keeps counting")
        XCTAssertEqual(try XCTUnwrap(timeline.state(at: 3.5)).opacity, 1, "each press keeps it up longer")
        XCTAssertNil(timeline.state(at: 4.2))
        XCTAssertEqual(timeline.state(at: 5.2)?.text, "⌘ Z", "after it has faded, counting starts over")
        XCTAssertEqual(timeline.badges.count, 2)
    }

    func testSameKeyWithOtherModifiersIsADifferentShortcut() {
        let timeline = ShortcutBadgeTimeline(presses: [press(1, "Z"), press(1.3, "Z", [.command, .shift])])
        XCTAssertEqual(timeline.state(at: 1.4)?.text, "⇧ ⌘ Z")
    }

    // MARK: - Saving

    func testSavesWithTheVideoFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID()).mp4")
        try Data("not really a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let track = ShortcutTrack(presses: [press(2.5, "Z"), press(0.4, "←", []), press(1, "R", [.command, .shift])],
                                  cameraCircle: CGRect(x: 0.8, y: 0.05, width: 0.15, height: 0.27))
        XCTAssertEqual(track.presses.map(\.time), [0.4, 1, 2.5], "kept in time order")
        XCTAssertNil(ShortcutTrack.load(from: url))
        try track.save(to: url)
        XCTAssertEqual(ShortcutTrack.load(from: url), track)
        XCTAssertNil(PointerTrack.load(from: url), "kept apart from the pointer log")
    }

    // MARK: - Drawing

    func testDrawsAPillNearTheBottomCenter() throws {
        let renderer = try XCTUnwrap(ShortcutBadgeRenderer(
            track: ShortcutTrack(presses: [press(1, "S")], cameraCircle: nil), videoSize: CGSize(width: 1280, height: 720)))
        XCTAssertFalse(renderer.isActive(at: 0.5))
        XCTAssertTrue(renderer.isActive(at: 1.5))
        XCTAssertFalse(renderer.isActive(at: 3))

        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let output = renderer.apply(to: white, at: 1.5)
        XCTAssertEqual(output.extent, white.extent)
        let context = CIContext()
        func gray(_ x: Int, _ y: Int) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixel[0]
        }
        // About 6% up from the bottom: a dark pill under the text, with white text in it.
        let bottom = Int((720 * ShortcutBadgeRenderer.marginFraction).rounded())
        let middle = bottom + Int(720 * ShortcutBadgeRenderer.heightFraction / 2)
        XCTAssertLessThan(gray(640, bottom + 3), 90, "dark pill below the text")
        XCTAssertGreaterThan((620...660).map { gray($0, middle) }.max()!, 200, "white text")
        XCTAssertGreaterThan(gray(640, 400), 250, "the rest of the frame is untouched")
        XCTAssertGreaterThan(gray(200, middle), 250)
        XCTAssertGreaterThan(gray(640, bottom - 3), 250, "nothing below the pill")
    }

    func testKeepsClearOfTheCamera() throws {
        let canvas = CGSize(width: 1280, height: 720)
        let size = CGSize(width: 300, height: 40)
        func placement(_ circle: CGRect?) throws -> CGRect {
            try XCTUnwrap(ShortcutBadgeRenderer(track: ShortcutTrack(presses: [press(1, "S")], cameraCircle: circle),
                                                videoSize: canvas)).placement(size: size, in: canvas)
        }
        func pixels(_ circle: CGRect) -> CGRect {
            CGRect(x: circle.minX * 1280, y: circle.minY * 720, width: circle.width * 1280, height: circle.height * 720)
        }
        // A camera in the corner is already clear: stay centered.
        XCTAssertEqual(try placement(CGRect(x: 0.82, y: 0.03, width: 0.15, height: 0.27)).midX, 640, accuracy: 1)

        // A big camera reaching the middle: slide left of it.
        let wide = CGRect(x: 0.55, y: 0.03, width: 0.3, height: 0.53)
        let beside = try placement(wide)
        XCTAssertFalse(beside.intersects(pixels(wide)))
        XCTAssertLessThan(beside.midX, 640)
        XCTAssertEqual(beside.minY, 720 * ShortcutBadgeRenderer.marginFraction, accuracy: 1, "same height as usual")

        // No room beside it: go above.
        let middle = CGRect(x: 0.2, y: 0.02, width: 0.6, height: 0.3)
        let above = try placement(middle)
        XCTAssertFalse(above.intersects(pixels(middle)))
        XCTAssertGreaterThan(above.minY, pixels(middle).maxY)
    }

    /// With captions burned in, the pill sits above where a two-line caption goes, at any
    /// size the frame is drawn.
    func testSitsAboveBurnedInCaptions() throws {
        let video = CGSize(width: 1920, height: 1080)
        let captions = try XCTUnwrap(CaptionRenderer(
            captions: Captions(cues: [Caption(start: 0, end: 2, text: "Two lines\nof caption text")], language: "en"),
            videoSize: video, cameraCircle: nil))
        let image = try XCTUnwrap(CaptionRenderer.draw(["Two lines", "of caption text"], videoSize: video))
        let captionBox = CGRect(origin: captions.place(CGSize(width: image.width, height: image.height)),
                                size: CGSize(width: image.width, height: image.height))
        let badges = try XCTUnwrap(ShortcutBadgeRenderer(
            track: ShortcutTrack(presses: [press(1, "S")], cameraCircle: nil), videoSize: video,
            reservedBottom: CaptionRenderer.reservedHeight(videoSize: video)))
        let pill = badges.placement(size: CGSize(width: 200, height: 65), in: video)
        XCTAssertGreaterThan(pill.minY, captionBox.maxY)
        XCTAssertLessThan(pill.minY - captionBox.maxY, 60, "close above, not far up the screen")
        // The preview draws at half size: same place, scaled.
        let half = badges.placement(size: CGSize(width: 100, height: 33), in: CGSize(width: 960, height: 540))
        XCTAssertEqual(half.minY, pill.minY / 2, accuracy: 1)
    }
}
