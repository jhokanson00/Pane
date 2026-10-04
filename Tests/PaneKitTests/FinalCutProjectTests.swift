import Foundation
import XCTest
@testable import PaneKit

final class FinalCutProjectTests: XCTestCase {
    private let project = FinalCutProject(
        name: "Pane Recording 2026-10-03 at 12.35.34 & more",
        width: 1560, height: 960, frameRate: 30, frames: 900,
        screen: URL(fileURLWithPath: "/Users/me/Movies/Pane/Recording (Final Cut)/Screen.mp4"),
        audioTracks: 2, audioChannels: 1,
        camera: URL(fileURLWithPath: "/Users/me/Movies/Pane/Recording (Final Cut)/Camera.mov"), cameraFrames: 899,
        markers: [(5.1, "Click"), (7.87, "Click a link or button"), (99, "Click")]
    )

    func testLaysOutScreenCameraAndClickMarkers() {
        let xml = project.xml
        XCTAssertTrue(xml.contains(#"<format id="r1" frameDuration="1/30s" width="1560" height="960""#))
        // Paths are file URLs, with spaces and brackets escaped.
        XCTAssertTrue(xml.contains("file:///Users/me/Movies/Pane/Recording%20(Final%20Cut)/Screen.mp4"))
        // The camera rides above the screen for as long as both last.
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r3" lane="1" offset="0s" name="Camera" duration="899/30s"/>"#))
        XCTAssertTrue(xml.contains(#"<marker start="153/30s" duration="1/30s" value="Click"/>"#))
        XCTAssertTrue(xml.contains(#"value="Click a link or button""#))
        // A click past the end is kept on the last frame.
        XCTAssertTrue(xml.contains(#"<marker start="899/30s""#))
        XCTAssertTrue(xml.contains(#"name="Pane Recording 2026-10-03 at 12.35.34 &amp; more""#))
    }

    /// Trimmed to 3–12.5 s (frames 90–375): the files stay whole, the clips start at
    /// frame 90 and last 285 frames, and only the clicks inside are marked.
    private var trimmed: FinalCutProject {
        var project = project
        project.trim = 90..<375
        return project
    }

    func testTrimSetsClipStartsAndDropsClicksOutside() {
        let xml = trimmed.xml
        // The assets are still the whole files.
        XCTAssertTrue(xml.contains(#"<asset id="r2" name="Screen" start="0s" duration="900/30s""#))
        XCTAssertTrue(xml.contains(#"<asset id="r3" name="Camera" start="0s" duration="899/30s""#))
        XCTAssertTrue(xml.contains(#"<sequence format="r1" duration="285/30s""#))
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r2" offset="0s" name="Screen" start="90/30s" duration="285/30s""#))
        // The camera is placed on the screen clip's own timeline, so it starts with it.
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r3" lane="1" offset="90/30s" name="Camera" start="90/30s" duration="285/30s"/>"#))
        // Markers keep their times in the recording; the click at 99 s is cut off.
        XCTAssertTrue(xml.contains(#"<marker start="153/30s""#))
        XCTAssertTrue(xml.contains(#"<marker start="236/30s""#))
        XCTAssertEqual(xml.components(separatedBy: "<marker ").count - 1, 2)

        // A trim past the camera's end leaves the camera out instead of an empty clip.
        var late = project
        late.trim = 899..<900
        XCTAssertFalse(late.xml.contains(#"ref="r3" lane="1""#))
        // Without a trim, nothing changes.
        XCTAssertTrue(project.xml.contains(#"<asset-clip ref="r2" offset="0s" name="Screen" duration="900/30s""#))
    }

    private var projectWithClickSounds: FinalCutProject {
        var project = project
        let folder = URL(fileURLWithPath: "/Users/me/Movies/Pane/Recording (Final Cut)")
        project.soundEffects = [
            .init(name: "Click", file: folder.appendingPathComponent("Click.wav"), samples: 2880,
                  times: [5.1, 7.87, 7.9, 99]),
            .init(name: "Right-click", file: folder.appendingPathComponent("Right-click.wav"), samples: 2880,
                  times: [0, 12.5]),
        ]
        return project
    }

    func testPlacesClickSoundsAsEditableClips() {
        let xml = projectWithClickSounds.xml
        XCTAssertTrue(xml.contains(#"<asset id="r4" name="Click" start="0s" duration="2880/48000s" hasAudio="1" audioSources="1" audioChannels="1" audioRate="48000">"#))
        XCTAssertTrue(xml.contains("file:///Users/me/Movies/Pane/Recording%20(Final%20Cut)/Right-click.wav"))
        // To the sample, below the screen, in the effects role.
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r4" lane="-1" offset="244800/48000s" name="Click" duration="2880/48000s" audioRole="effects"/>"#))
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r5" lane="-1" offset="0s" name="Right-click""#))
        // A click 30 ms after another, while the first still sounds, goes on the next lane.
        XCTAssertTrue(xml.contains(#"lane="-1" offset="377760/48000s""#))
        XCTAssertTrue(xml.contains(#"lane="-2" offset="379200/48000s""#))
        // Past the end of the video: left out.
        XCTAssertEqual(xml.components(separatedBy: #"audioRole="effects""#).count - 1, 5)
        // The clips come before the markers, as Final Cut's definition requires.
        XCTAssertLessThan(xml.range(of: #"audioRole="effects""#, options: .backwards)!.lowerBound,
                          xml.range(of: "<marker")!.lowerBound)

        // Trimmed to 3–12.5 s: sounds keep their place on the screen clip's timeline,
        // and the ones cut off (0 s, 12.5 s, 99 s) are left out.
        var trimmed = projectWithClickSounds
        trimmed.trim = 90..<375
        XCTAssertTrue(trimmed.xml.contains(#"lane="-1" offset="244800/48000s""#))
        XCTAssertEqual(trimmed.xml.components(separatedBy: #"audioRole="effects""#).count - 1, 3)

        // Without sounds the project is unchanged.
        XCTAssertFalse(project.xml.contains("audioRole=\"effects\""))
    }

    func testPrepareWritesTheClickSoundFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pane-fcp-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let effects = try FinalCutProject.SoundEffect.clicks([
            .init(time: 2, x: 0.5, y: 0.5, button: .left, isHand: true, duration: 0.1),
            .init(time: 1, x: 0.5, y: 0.5, button: .other, isHand: false, duration: 0.1),
        ], in: folder)
        XCTAssertEqual(effects.map(\.name), ["Click"], "no right-clicks, so no right-click file")
        XCTAssertEqual(effects[0].times, [1, 2])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Click.wav")), ClickSound.wav(for: .left))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Right-click.wav").path))
    }

    private var captioned: FinalCutProject {
        var project = project
        project.captions = Captions(cues: [
            Caption(start: 0.6, end: 2.82, text: "Okay, we're trying this once again."),
            // Rounds to the same frame the last one ended on, so it starts there.
            Caption(start: 2.81, end: 5.5, text: "Click <Save> & then\n\"Done\""),
            // Past the end of the video: dropped.
            Caption(start: 31, end: 33, text: "Bye."),
        ], language: "en")
        return project
    }

    func testCaptionsAreConnectedToTheScreen() {
        let xml = captioned.xml
        XCTAssertEqual(xml.components(separatedBy: "<caption ").count - 1, 2)
        XCTAssertTrue(xml.contains(#"<caption lane="2" offset="18/30s" name="Okay, we're trying this once again." "#))
        XCTAssertTrue(xml.contains(#"duration="67/30s" role="iTT?captionFormat=ITT.en">"#))
        XCTAssertTrue(xml.contains(#"<caption lane="2" offset="85/30s""#))
        XCTAssertTrue(xml.contains(#"<text-style ref="ts2">Click &lt;Save&gt; &amp; then&#10;&quot;Done&quot;</text-style>"#))
        // Captions come before the markers, as Final Cut's format requires.
        XCTAssertLessThan(xml.range(of: "<caption ")!.lowerBound, xml.range(of: "<marker ")!.lowerBound)
        // Without the camera, the captions take its lane.
        var single = captioned
        single.camera = nil
        XCTAssertTrue(single.xml.contains(#"<caption lane="1" offset="18/30s""#))
        // Trimmed to 1–4 s: captions are cut to the kept part, on the file's timeline.
        var trimmed = captioned
        trimmed.trim = 30..<120
        XCTAssertTrue(trimmed.xml.contains(#"<caption lane="2" offset="30/30s" name="Okay, we're trying this once again." duration="55/30s""#))
        XCTAssertTrue(trimmed.xml.contains(#"<caption lane="2" offset="85/30s" name="Click &lt;Save&gt; &amp; then &quot;Done&quot;" duration="35/30s""#))
        // Projects without captions are unchanged.
        XCTAssertFalse(project.xml.contains("caption"))
    }

    /// Checked against the format definition Final Cut itself uses, when it's installed.
    func testMatchesFinalCutsDefinition() throws {
        let dtd = "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/"
            + "FCPXMLv\(FinalCutProject.version.replacingOccurrences(of: ".", with: "_")).dtd"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dtd), "Final Cut Pro isn't installed")
        let plain = { var p = self.project; p.camera = nil; p.audioTracks = 0; p.markers = []; return p }()
        let soundsOnly = { var p = self.projectWithClickSounds; p.camera = nil; p.audioTracks = 0; return p }()
        let trimmedWithSounds = { var p = self.projectWithClickSounds; p.trim = 90..<375; return p }()
        let captionsOnly = { var p = self.captioned; p.camera = nil; p.markers = []; return p }()
        let everything = { var p = trimmedWithSounds; p.captions = self.captioned.captions; return p }()
        let everythingCut = { var p = everything; p.cuts = [150..<180, 240..<260]; return p }()
        for project in [project, plain, trimmed, projectWithClickSounds, soundsOnly, trimmedWithSounds, captioned,
                        captionsOnly, everything, everythingCut] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pane-\(UUID()).fcpxml")
            try project.xml.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let lint = Process()
            lint.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
            // As a URL: xmllint reads the path as one, and it has spaces.
            lint.arguments = ["--noout", "--dtdvalid", URL(fileURLWithPath: dtd).absoluteString, file.path]
            let errors = Pipe()
            lint.standardError = errors
            try lint.run()
            lint.waitUntilExit()
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(lint.terminationStatus, 0, message)
        }
    }

    /// A retake cut from frames 150–180 inside the 90–375 trim: two screen clips back to
    /// back, each with its own camera and only its own clicks; a click in the cut is left out.
    func testCutsMakeOneClipPerPartKept() {
        var cut = trimmed
        cut.cuts = [150..<180]
        cut.markers = [(4.0, "Click"), (5.5, "Click"), (7.0, "Click")]  // frames 120, 165 (cut), 210
        let xml = cut.xml
        XCTAssertTrue(xml.contains(#"<sequence format="r1" duration="255/30s""#), "285 frames less 30 cut")
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r2" offset="0s" name="Screen" start="90/30s" duration="60/30s""#))
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r2" offset="60/30s" name="Screen" start="180/30s" duration="195/30s""#))
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r3" lane="1" offset="90/30s" name="Camera" start="90/30s" duration="60/30s"/>"#))
        XCTAssertTrue(xml.contains(#"<asset-clip ref="r3" lane="1" offset="180/30s" name="Camera" start="180/30s" duration="195/30s"/>"#))
        XCTAssertTrue(xml.contains(#"<marker start="120/30s""#))
        XCTAssertTrue(xml.contains(#"<marker start="210/30s""#))
        XCTAssertFalse(xml.contains(#"<marker start="165/30s""#))
    }
}
