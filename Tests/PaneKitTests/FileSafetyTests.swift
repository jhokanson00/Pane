import Darwin
import XCTest
@testable import PaneKit

/// Reading what's stored with a video (it can come from anywhere), and writing outputs
/// next to it.
final class FileSafetyTests: XCTestCase {
    private var folder: URL!
    private var video: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileSafetyTests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        video = folder.appendingPathComponent("Video.mp4")
        try Data(count: 10).write(to: video)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func track(time: Double = 1, pointSize: Double = 0.001) -> PointerTrack {
        PointerTrack(samples: [.init(time: 0, x: 0.5, y: 0.5, isHand: false), .init(time: time, x: 0.6, y: 0.4, isHand: true)],
                     clicks: [.init(time: time, x: 0.6, y: 0.4, button: .left, isHand: true, duration: 0.1)],
                     pointSize: pointSize, cameraCircle: nil)
    }

    func testPointerTrackRoundTrip() throws {
        let original = track()
        try original.save(to: video)
        XCTAssertEqual(PointerTrack.load(from: video), original)
    }

    func testImplausibleTracksAreIgnored() throws {
        // A time this large traps converting to Int; a huge one allocates for hours of
        // video that isn't there.
        try track(time: 1e300).save(to: video)
        XCTAssertNil(PointerTrack.load(from: video))
        try track(time: 1e9).save(to: video)
        XCTAssertNil(PointerTrack.load(from: video))
        try track(pointSize: 0).save(to: video)
        XCTAssertNil(PointerTrack.load(from: video))

        let shortcut = KeyShortcut(modifiers: [], key: String(repeating: "A", count: 1000))
        try ShortcutTrack(presses: [.init(time: 1, shortcut: shortcut)], cameraCircle: nil).save(to: video)
        XCTAssertNil(ShortcutTrack.load(from: video))
    }

    func testPackedAttributeThatUnpacksTooFarIsIgnored() throws {
        // A few hundred KB that unpack to over the limit.
        let bomb = try (Data(count: FileAttribute.unpackedLimit + 1) as NSData).compressed(using: .lzfse) as Data
        XCTAssertLessThan(bomb.count, 1 << 20)
        try FileAttribute.write(bomb, name: PointerTrack.attributeName, to: video)
        XCTAssertNil(PointerTrack.load(from: video))
    }

    func testOversizedScriptIsIgnored() throws {
        try PrompterScript.save("Every click gets a ring.", to: video)
        XCTAssertEqual(PrompterScript.load(from: video), "Every click gets a ring.")
        try PrompterScript.save(String(repeating: "word ", count: 300_000), to: video)
        XCTAssertNil(PrompterScript.load(from: video))
    }

    func testOutputIsPlacedWhole() throws {
        let destination = folder.appendingPathComponent("Video (Edited).mp4")
        try OutputFile.write(Data("first".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
        XCTAssertTrue(OutputFile.isPanes(destination))

        // An earlier copy Pane wrote is replaced in place.
        try OutputFile.write(Data("second".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))

        // Nothing is left behind where the copy was written.
        let scratch = try OutputFile.scratch(for: destination)
        try Data("unfinished".utf8).write(to: scratch)
        OutputFile.discard(scratch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))
    }

    func testBlurTextMatchesTheWordWithPunctuation() {
        let key = FindingTracker.wordKey("Hokanson")
        for written in ["Hokanson,", "(Hokanson)", "Hokanson's", "HOKANSON.", "Hokanson’s"] {
            XCTAssertEqual(FindingTracker.wordKey(written), key, written)
        }
        XCTAssertNotEqual(FindingTracker.wordKey("Hokansons"), key)
        XCTAssertEqual(FindingTracker.wordKey("—"), "—")
    }

    func testBlurLayersAreKeptWithTheVideo() throws {
        let drawn = Finding(kind: .manual, text: "Box at 0:01", samples: [BoxSample(time: 1, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))],
                            start: 0, end: 5)
        let picked = Finding(kind: .customWord, text: "Hokanson", samples: [BoxSample(time: 2, rect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.03))],
                             start: 1.5, end: 3)
        let email = Finding(kind: .email, text: "a@b.com", samples: [BoxSample(time: 2, rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.03))],
                            start: 1.5, end: 3)
        try Finding.save([drawn, picked, email], to: video)
        XCTAssertEqual(Finding.load(from: video), [drawn, picked, email])

        // A new scan replaces what the earlier one found; drawn and picked blurs stay.
        var newEmail = email
        newEmail.id = UUID()
        XCTAssertEqual(Finding.merging([drawn, picked, email], scanned: [newEmail]), [drawn, picked, newEmail])
        // A picked word the word list now finds isn't kept twice.
        var listed = picked
        listed.id = UUID()
        XCTAssertEqual(Finding.merging([drawn, picked], scanned: [listed]), [drawn, listed])
    }
}
