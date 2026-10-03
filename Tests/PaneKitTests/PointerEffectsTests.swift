import CoreImage
import XCTest
@testable import PaneKit

final class PointerEffectsTests: XCTestCase {
    /// Still for a second, moves for a second, then still again, with one click.
    let track = PointerTrack(
        samples: [
            .init(time: 0, x: 0.2, y: 0.2, isHand: false),
            .init(time: 1, x: 0.2, y: 0.2, isHand: false),
            .init(time: 2, x: 0.6, y: 0.4, isHand: true),
            .init(time: 6, x: 0.6, y: 0.4, isHand: true),
        ],
        clicks: [.init(time: 2.5, x: 0.6, y: 0.4, button: .left, isHand: true, duration: 0.1)],
        pointSize: 1.0 / 900,
        cameraCircle: CGRect(x: 0.8, y: 0.8, width: 0.15, height: 0.2)
    )

    func testPositionFollowsSamples() throws {
        let middle = try XCTUnwrap(track.position(at: 1.5))
        XCTAssertEqual(middle.point.x, 0.4, accuracy: 0.001)
        XCTAssertEqual(middle.point.y, 0.3, accuracy: 0.001)
        XCTAssertEqual(track.position(at: 10)?.point.x, 0.6)
    }

    func testSavesWithTheVideoFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pointer-\(UUID()).mp4")
        try Data("not really a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(PointerTrack.load(from: url))
        try track.save(to: url)
        XCTAssertEqual(PointerTrack.load(from: url), track)
    }

    func testHighlightShowsWhileMovingAndFadesWhenStill() throws {
        let renderer = try XCTUnwrap(PointerRenderer(track: track, style: PointerEffectStyle(),
                                                     videoSize: CGSize(width: 1600, height: 900)))
        XCTAssertFalse(renderer.isActive(at: 0.5), "still before moving")
        XCTAssertTrue(renderer.isActive(at: 1.5), "moving")
        XCTAssertTrue(renderer.isActive(at: 2.55), "click ring")
        XCTAssertFalse(renderer.isActive(at: 5), "faded after stopping")

        var always = PointerEffectStyle()
        always.fadeWhenStill = false
        let steady = try XCTUnwrap(PointerRenderer(track: track, style: always, videoSize: CGSize(width: 1600, height: 900)))
        XCTAssertTrue(steady.isActive(at: 5))
    }

    func testNothingDrawnBehindTheCamera() throws {
        var hidden = track
        hidden.samples = hidden.samples.map { var s = $0; s.x = 0.87; s.y = 0.9; return s }
        hidden.samples[2].x = 0.88
        hidden.clicks = []
        let renderer = try XCTUnwrap(PointerRenderer(track: hidden, style: PointerEffectStyle(),
                                                     videoSize: CGSize(width: 1600, height: 900)))
        XCTAssertFalse(renderer.isActive(at: 1.5))
    }

    func testTurnedOffClicksAreSkipped() throws {
        var quiet = track
        quiet.clicks[0].isEnabled = false
        var style = PointerEffectStyle()
        style.highlight = false
        let renderer = try XCTUnwrap(PointerRenderer(track: quiet, style: style, videoSize: CGSize(width: 1600, height: 900)))
        XCTAssertFalse(renderer.isActive(at: 2.55))
    }

    func testDrawsOnFrames() throws {
        let renderer = try XCTUnwrap(PointerRenderer(track: track, style: PointerEffectStyle(),
                                                     videoSize: CGSize(width: 160, height: 90)))
        let frame = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        let output = renderer.apply(to: frame, at: 2.55)
        XCTAssertEqual(output.extent, frame.extent)

        // The pixel under the click is tinted, not white.
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 96, y: 36, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        XCTAssertLessThan(pixel[2], 230, "blue channel drops where yellow is drawn")
    }
}
