import XCTest
@testable import PaneKit

final class SensitiveDetectorTests: XCTestCase {
    let detector = SensitiveDetector(options: .init(customWords: ["Acme Corp", "Menno"]))

    func found(_ line: String) -> [(SensitiveKind, String)] {
        detector.matches(in: line).map { ($0.kind, String($0.text)) }
    }

    func assertFinds(_ line: String, _ kind: SensitiveKind, _ text: String, file: StaticString = #filePath, line l: UInt = #line) {
        XCTAssertTrue(found(line).contains { $0 == (kind, text) }, "\(found(line)) in \"\(line)\"", file: file, line: l)
    }

    func testEmails() {
        assertFinds("Contact: jane.doe@example.com", .email, "jane.doe@example.com")
        assertFinds("reach me at J.Smith+news@mail.co.uk today", .email, "J.Smith+news@mail.co.uk")
    }

    func testPhones() {
        assertFinds("Phone: (555) 123-4567", .phone, "(555) 123-4567")
        assertFinds("call +1 555.123.4567", .phone, "+1 555.123.4567")
        XCTAssertTrue(found("Due 2026-10-02 at 10:30").isEmpty)
    }

    func testCards() {
        assertFinds("Card on file 4242 4242 4242 4242", .cardNumber, "4242 4242 4242 4242")
        // Fails the Luhn checksum, so not a card.
        XCTAssertFalse(found("Order 4242 4242 4242 4241").contains { $0.0 == .cardNumber })
    }

    func testGovernmentID() {
        assertFinds("SSN 123-45-6789", .governmentID, "123-45-6789")
    }

    func testSecrets() {
        assertFinds("OPENAI_API_KEY=sk-proj-A1b2C3d4E5f6G7h8I9j0K1l2", .secret, "sk-proj-A1b2C3d4E5f6G7h8I9j0K1l2")
        assertFinds("token ghp_abcdefghijklmnopqrstuvwxyz0123456789", .secret, "ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        assertFinds("aws AKIAIOSFODNN7EXAMPLE", .secret, "AKIAIOSFODNN7EXAMPLE")
        assertFinds("password: hunter2!", .secret, "hunter2!")
        assertFinds("x-api-key Zq8mT2vLp9Xr4Wn7Ks1Bd6Hc3Jf", .secret, "Zq8mT2vLp9Xr4Wn7Ks1Bd6Hc3Jf")
    }

    func testOrdinaryTextIsLeftAlone() {
        XCTAssertTrue(found("Next steps: send the proposal on Friday").isEmpty)
        // A lowercase git commit hash isn't a secret.
        XCTAssertTrue(found("commit 3f2a9c1e8b7d6f5a4c3b2a1908f7e6d5c4b3a291").isEmpty)
    }

    func testCustomWords() {
        assertFinds("Meeting with acme corp tomorrow", .customWord, "acme corp")
        assertFinds("Notes from Menno.", .customWord, "Menno")
        XCTAssertTrue(found("Mennonite history").isEmpty)
    }

    func testDisabledKindsAreSkipped() {
        let emailsOnly = SensitiveDetector(options: .init(kinds: [.email]))
        XCTAssertTrue(emailsOnly.matches(in: "Phone: (555) 123-4567").isEmpty)
    }
}

final class FindingTests: XCTestCase {
    func testInterpolatesBetweenSamples() {
        var finding = Finding(kind: .manual, text: "", samples: [
            BoxSample(time: 0, rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)),
            BoxSample(time: 1, rect: CGRect(x: 0.02, y: 0.04, width: 0.1, height: 0.1)),
        ], start: 0, end: 2)
        let mid = finding.coverRect(at: 0.5, aspect: 1)!
        XCTAssertEqual(mid.minX, 0.01, accuracy: 0.0001)
        XCTAssertEqual(mid.minY, 0.02, accuracy: 0.0001)
        XCTAssertNil(finding.coverRect(at: 2.5, aspect: 1))
        finding.isEnabled = false
        XCTAssertNil(finding.coverRect(at: 0.5, aspect: 1))
    }

    func testCoversWholePathAcrossUntrackedJump() {
        let a = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.05)
        let b = CGRect(x: 0.1, y: 0.7, width: 0.1, height: 0.05)
        // Frame by frame (1/30 s apart), the box slides.
        let tracked = Finding(kind: .manual, text: "", samples: [BoxSample(time: 0, rect: a), BoxSample(time: 1.0 / 30, rect: b)],
                              start: 0, end: 1)
        XCTAssertEqual(tracked.coverRect(at: 1.0 / 60, aspect: 1)!.height, 0.05, accuracy: 0.0001)
        // Across a gap, any point on the way is covered.
        let gap = Finding(kind: .manual, text: "", samples: [BoxSample(time: 0, rect: a), BoxSample(time: 0.3, rect: b)],
                          start: 0, end: 1)
        XCTAssertEqual(gap.coverRect(at: 0.1, aspect: 1), a.union(b))
    }

    func testTrackerFollowsScrollingText() {
        let frames = (0..<6).map { i in
            FrameText(time: Double(i) / 3, matches: [
                TextBox(text: "jane@example.com", rect: CGRect(x: 0.1, y: 0.5 + Double(i) * 0.05, width: 0.3, height: 0.04), kind: .email),
            ], words: [])
        }
        let findings = FindingTracker.build(frames: frames, boxes: \.matches, interval: 1.0 / 3, duration: 2)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].samples.count, 6)
        XCTAssertEqual(findings[0].start, 0)
    }
}
