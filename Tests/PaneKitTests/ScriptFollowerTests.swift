import XCTest
@testable import PaneKit

final class ScriptFollowerTests: XCTestCase {
    let text = """
    This is Pane, a free screen recorder for Mac. [Point at the stats]

    Everything here is private: names, emails, phone numbers.
    [Click Priya Duarte]
    Card numbers and ID numbers too.
    Keyboard shortcuts show up on screen, so viewers can follow along.
    """

    func testParsesWordsCuesAndLines() {
        let script = PrompterScript(text)
        XCTAssertEqual(script.lines.count, 5)
        XCTAssertEqual(script.cues.map(\.text), ["Point at the stats", "Click Priya Duarte"])
        XCTAssertEqual(script.words.first?.key, "this")
        XCTAssertEqual(script.words[2].text, "Pane,")
        XCTAssertEqual(script.words[2].key, "pane")
        // The first cue comes after the first line's nine words; the second sits on its own line.
        XCTAssertEqual(script.cues[0].beforeWord, 9)
        XCTAssertEqual(script.lines[2].words.count, 0)
        XCTAssertEqual(script.cues[1].beforeWord, script.lines[3].words.lowerBound)
        XCTAssertEqual(PrompterScript.key("Two,"), "2")
    }

    func testFollowsWordByWord() {
        var follower = ScriptFollower(script: PrompterScript(text))
        var heard: [String] = []
        for word in "This is Pane a free screen recorder".split(separator: " ") {
            heard.append(String(word))
            follower.hear(heard)
        }
        XCTAssertEqual(follower.position, 7)
    }

    func testSkippedAndMisheardWordsStillMoveOn() {
        var follower = ScriptFollower(script: PrompterScript(text))
        follower.hear("this is pane a free screen recorder for mac".split(separator: " ").map(String.init))
        XCTAssertEqual(follower.position, 9)
        // Leaves out "here is", mishears "private" and says "phone" without "numbers" yet.
        follower.hear("everything privet names emails phone".split(separator: " ").map(String.init))
        XCTAssertEqual(follower.script.words[follower.position].key, "numbers")
        XCTAssertEqual(follower.reachedCues, 1)
    }

    func testAdLibbingDoesNotMove() {
        var follower = ScriptFollower(script: PrompterScript(text))
        follower.hear(["this", "is", "pane"])
        let before = follower.position
        follower.hear(["this", "is", "pane", "oh", "wait", "let", "me", "grab", "some", "coffee", "first"])
        XCTAssertEqual(follower.position, before)
    }

    func testCommonWordsAloneDoNotJumpAhead() {
        var follower = ScriptFollower(script: PrompterScript(text))
        follower.hear(["so", "and", "the"])
        XCTAssertEqual(follower.position, 0)
    }

    func testJumpsAheadWhenSeveralWordsAgree() {
        var follower = ScriptFollower(script: PrompterScript(text))
        follower.hear(["this", "is", "pane"])
        // Skips straight to the keyboard line.
        follower.hear(["this", "is", "pane", "keyboard", "shortcuts", "show", "up"])
        XCTAssertEqual(follower.script.words[follower.position].text, "on")
    }

    func testGoesBackOnlyForAClearReread() {
        let script = PrompterScript(text)
        var follower = ScriptFollower(script: script)
        let all = script.words.map(\.key)
        let cardLine = script.lines[3].words.lowerBound
        follower.hear(Array(all[..<(cardLine + 6)]))
        XCTAssertEqual(follower.position, cardLine + 6)
        // One word from earlier isn't enough to go back...
        follower.hear(Array(all[..<(cardLine + 6)]) + ["names"])
        XCTAssertEqual(follower.position, cardLine + 6)
        // ...but rereading the whole line is.
        follower.hear(Array(all[..<(cardLine + 6)]) + ["everything", "here", "is", "private", "names"])
        XCTAssertEqual(script.words[follower.position].key, "emails")
    }

    func testHalfSaidWordAtTheEnd() {
        var follower = ScriptFollower(script: PrompterScript(text))
        follower.hear("this is pane a free screen recorder for mac everything here is private names emails phone num"
            .split(separator: " ").map(String.init))
        XCTAssertEqual(follower.script.words[follower.position].key, "card")
    }

    func testSentenceStarts() {
        let script = PrompterScript(text)
        let starts = script.sentenceStarts.map { script.words[$0].text }
        XCTAssertEqual(starts, ["This", "Everything", "Card", "Keyboard"])
        XCTAssertEqual(PrompterScript("One. Two! Three? \"Four.\" Five").sentenceStarts, [0, 1, 2, 3, 4])
    }

    func testSentenceBackAndForward() {
        let script = PrompterScript(text)
        var follower = ScriptFollower(script: script)
        let everything = script.sentenceStarts[1]
        follower.jump(to: everything + 4)
        follower.sentenceBack()
        XCTAssertEqual(follower.position, everything, "mid-sentence: back to its start")
        follower.sentenceBack()
        XCTAssertEqual(follower.position, 0, "at a start: to the sentence before")
        follower.sentenceForward()
        XCTAssertEqual(follower.position, everything)
    }

    /// After going back by hand, the words just said mustn't pull the place forward again.
    func testJumpBackIsNotUndoneByWhatWasJustHeard() {
        let script = PrompterScript(text)
        var follower = ScriptFollower(script: script)
        var heard = "this is pane a free screen recorder for mac everything here is private".split(separator: " ").map(String.init)
        follower.hear(heard)
        XCTAssertEqual(script.words[follower.position].key, "names")
        follower.sentenceBack()
        XCTAssertEqual(script.words[follower.position].key, "everything")
        // The recognizer reports a bit more of the flubbed attempt, then the retake begins.
        heard.append("um")
        follower.hear(heard)
        XCTAssertEqual(script.words[follower.position].key, "everything")
        heard += ["everything", "here"]
        follower.hear(heard)
        XCTAssertEqual(script.words[follower.position].key, "is")
    }
}
