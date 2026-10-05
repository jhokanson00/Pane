import Darwin
import XCTest
@testable import PaneKit

final class VideoLibraryTests: XCTestCase {
    private var root: URL!
    private var clips: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("VideoLibraryTests \(UUID().uuidString)")
        root = base.appendingPathComponent("Pane")
        clips = base.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.date(from: text)!
    }

    private func make(_ path: String, in folder: URL? = nil, bytes: Int = 10) throws {
        let url = (folder ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func testNames() {
        let date = day("2026-10-05 09.19")
        XCTAssertEqual(VideoLibrary.name(title: "Share a Project", date: date), "Share a Project 2026-10-05")
        XCTAssertEqual(VideoLibrary.name(title: "Share a Project", date: date, take: 2), "Share a Project 2026-10-05 Take 2")
        XCTAssertEqual(VideoLibrary.name(title: "  ", date: date), "Untitled 2026-10-05 09.19")
        XCTAssertEqual(VideoLibrary.name(title: "Folders/files: a tour", date: date), "Folders-files- a tour 2026-10-05")
        XCTAssertEqual(VideoLibrary.title(of: "Share a Project 2026-10-05 Take 2"), "Share a Project")
        XCTAssertEqual(VideoLibrary.title(of: "Untitled 2026-10-05 09.19"), "")
        XCTAssertEqual(VideoLibrary.title(of: "Something else"), "Something else")
    }

    func testANameAlreadyTakenGetsTheNextTake() throws {
        let date = day("2026-10-05 09.19")
        try make("Demo 2026-10-05/Demo 2026-10-05.mp4")
        try make("Demo 2026-10-05 Take 2/Demo 2026-10-05 Take 2.mp4")
        XCTAssertEqual(VideoLibrary.uniqueName(title: "Demo", date: date, in: root), "Demo 2026-10-05 Take 3")
    }

    func testListsFoldersLooseRecordingsAndTheRest() throws {
        try make("Demo 2026-10-05/Demo 2026-10-05.mp4", bytes: 5000)
        try make("Demo 2026-10-05/Demo 2026-10-05 (Edited).mp4")
        try make("Demo 2026-10-05/Demo 2026-10-05 (Edited).srt")
        try make("Pane Recording 2026-10-02 at 12.11.29.mp4")
        try make("Pane Recording 2026-10-02 at 12.11.29 (Edited).mp4")
        try make("Pane Recording 2026-10-02 at 12.11.29 (Final Cut)/project.fcpxml")
        try make("Pane Recording 2026-10-02 at 12.11.29/Camera.mov", in: clips)
        try make("Pane Recording 2026-09-30 at 08.00.00/Camera.mov", in: clips)

        let items = VideoLibrary.items(in: root, legacyClips: clips)
        let demo = try XCTUnwrap(items.first { $0.kind == .folder })
        XCTAssertEqual(demo.title, "Demo")
        XCTAssertNotNil(demo.edited)
        XCTAssertNotNil(demo.captions)
        XCTAssertGreaterThanOrEqual(demo.size, 5000)

        let loose = try XCTUnwrap(items.first { $0.kind == .loose })
        XCTAssertEqual(loose.files.count, 3)  // the recording, its edited copy and its clips
        XCTAssertNotNil(loose.clips)
        XCTAssertEqual(loose.date, day("2026-10-02 12.11").addingTimeInterval(29))

        let others = items.filter { $0.kind == .other }.map(\.name).sorted()
        XCTAssertEqual(others, ["Clips from recordings that are gone", "Pane Recording 2026-10-02 at 12.11.29 (Final Cut)"])
        XCTAssertEqual(items.first?.title, "Demo")  // Newest first.
    }

    func testOrganizeGathersLooseRecordingsIntoFolders() throws {
        try make("Pane Recording 2026-10-02 at 12.11.29.mp4")
        try make("Pane Recording 2026-10-02 at 12.11.29 (Edited).mp4")
        try make("Pane Recording 2026-10-02 at 12.11.29 (Edited).srt")
        try make("Pane Recording 2026-10-02 at 12.11.29 (Final Cut)/project.fcpxml")
        try make("Pane Recording 2026-10-02 at 12.11.29/Camera.mov", in: clips)
        try make("Veil Recording 2026-10-02 at 12.11.50.mp4")
        try make("Veil Recording 2026-10-02 at 12.11.50 (Blurred).mp4")

        XCTAssertEqual(try VideoLibrary.organize(root, legacyClips: clips), 2)
        let first = "Untitled 2026-10-02 12.11"
        XCTAssertTrue(exists("\(first)/\(first).mp4"))
        XCTAssertTrue(exists("\(first)/\(first) (Edited).mp4"))
        XCTAssertTrue(exists("\(first)/\(first) (Edited).srt"))
        XCTAssertTrue(exists("\(first)/Clips for Final Cut/Camera.mov"))
        XCTAssertTrue(exists("Untitled 2026-10-02 12.11 Take 2/Untitled 2026-10-02 12.11 Take 2.mp4"))
        // The first versions' "(Blurred)" copy is the edited copy.
        XCTAssertTrue(exists("Untitled 2026-10-02 12.11 Take 2/Untitled 2026-10-02 12.11 Take 2 (Edited).mp4"))
        // The Final Cut folder stays put, for projects already in Final Cut.
        XCTAssertTrue(exists("Pane Recording 2026-10-02 at 12.11.29 (Final Cut)/project.fcpxml"))
        XCTAssertFalse(exists("Pane Recording 2026-10-02 at 12.11.29.mp4"))
        XCTAssertEqual(VideoLibrary.items(in: root, legacyClips: clips).filter { $0.kind == .loose }, [])
    }

    func testRenameMovesTheFolderAndTheFilesNamedAfterIt() throws {
        let old = "Untitled 2026-10-05 09.19"
        try make("\(old)/\(old).mp4")
        try make("\(old)/\(old) (Edited).mp4")
        try make("\(old)/\(old) (Final Cut)/project.fcpxml")
        try make("\(old)/Clips for Final Cut/Camera.mov")
        // The pointer log and the like live in the recording's extended attributes.
        let video = root.appendingPathComponent("\(old)/\(old).mp4")
        XCTAssertEqual(setxattr(video.path, "com.jacobhokanson.pane.test", "x", 1, 0, 0), 0)
        try make("Share 2026-10-05/Share 2026-10-05.mp4")

        let renamed = try VideoLibrary.rename(root.appendingPathComponent(old), title: "Share")
        let new = "Share 2026-10-05 Take 2"
        XCTAssertEqual(renamed.lastPathComponent, new)
        XCTAssertTrue(exists("\(new)/\(new).mp4"))
        XCTAssertTrue(exists("\(new)/\(new) (Edited).mp4"))
        XCTAssertTrue(exists("\(new)/\(new) (Final Cut)/project.fcpxml"))
        XCTAssertTrue(exists("\(new)/Clips for Final Cut/Camera.mov"))
        XCTAssertFalse(exists(old))
        XCTAssertEqual(getxattr(VideoLibrary.video(in: renamed).path, "com.jacobhokanson.pane.test", nil, 0, 0, 0), 1)
        XCTAssertTrue(VideoLibrary.isInFolder(VideoLibrary.video(in: renamed), root: root))
    }
}
