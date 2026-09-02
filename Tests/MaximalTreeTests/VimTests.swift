import Testing
import Foundation
@testable import MaximalEditorKit

/// Modal editing, checked the way it is used: type keys at a buffer and say
/// where the caret went and what the text became.
@MainActor
@Suite struct VimTests {
    /// Drives the engine like a keyboard, applying each edit as it comes.
    @MainActor
    private final class Buffer {
        let engine = VimEngine()
        var text: String
        var caret: Int
        var selection: NSRange?
        /// The mode the app would be holding — the engine has none of its own.
        var mode: VimMode = .normal

        init(_ text: String, caret: Int = 0) {
            self.text = text
            self.caret = caret
        }

        /// One named key — `ESC`, `RET` — which `type` can't spell.
        @discardableResult
        func press(_ key: String) -> Buffer { feed(key) }

        @discardableResult
        func type(_ keys: String) -> Buffer {
            for character in keys {
                let key = character == " " ? "SPC" : String(character)
                feed(key)
            }
            return self
        }

        @discardableResult
        private func feed(_ key: String) -> Buffer {
            guard let outcome = engine.handle(VimKey(key), mode: mode,
                                              text: text, caret: caret)
            else { return self }
            // The mode comes back with the outcome; nothing holds a second
            // copy of it, here or in the app.
            mode = outcome.mode
            if let edit = outcome.edit {
                let ns = NSMutableString(string: text)
                ns.replaceCharacters(in: edit.range, with: edit.replacement)
                text = ns as String
            }
            caret = min(max(outcome.caret, 0), (text as NSString).length)
            selection = outcome.selection
            return self
        }

        /// The text with the caret marked, which reads better in a failure
        /// than two numbers do.
        var marked: String {
            let ns = text as NSString
            return ns.substring(to: caret) + "|" + ns.substring(from: caret)
        }
    }

    // MARK: Motions

    @Test func hjklMoveAndStopAtTheEdges() {
        let buffer = Buffer("abc\ndef", caret: 0)
        #expect(buffer.type("l").marked == "a|bc\ndef")
        #expect(buffer.type("ll").marked == "abc|\ndef", "l ran past the end of the line")
        #expect(buffer.type("j").marked == "abc\ndef|")
        #expect(buffer.type("h").marked == "abc\nde|f")
        #expect(buffer.type("k").marked == "ab|c\ndef", "k lost the column")
    }

    @Test func countsMultiplyMotions() {
        let buffer = Buffer("abcdefgh", caret: 0)
        #expect(buffer.type("3l").marked == "abc|defgh")
        #expect(buffer.type("2h").marked == "a|bcdefgh")
    }

    @Test func lineMotionsFindTheirEnds() {
        let buffer = Buffer("    indented line\nsecond", caret: 6)
        #expect(buffer.type("0").marked == "|    indented line\nsecond")
        #expect(buffer.type("^").marked == "    |indented line\nsecond")
        #expect(buffer.type("$").marked == "    indented line|\nsecond",
                "$ should stop before the newline, not after it")
    }

    @Test func ggAndGReachTheEnds() {
        let buffer = Buffer("one\ntwo\nthree", caret: 5)
        #expect(buffer.type("gg").marked == "|one\ntwo\nthree")
        #expect(buffer.type("G").marked == "one\ntwo\n|three")
        // A count makes G a line number.
        #expect(buffer.type("2G").marked == "one\n|two\nthree")
    }

    /// Punctuation is its own kind of word, which is why `w` stops at the
    /// bracket in `foo(bar)` instead of skipping to `bar`.
    @Test func wordMotionsTreatPunctuationAsItsOwnWord() {
        let buffer = Buffer("foo(bar) baz", caret: 0)
        #expect(buffer.type("w").marked == "foo|(bar) baz")
        #expect(buffer.type("w").marked == "foo(|bar) baz")
        #expect(buffer.type("w").marked == "foo(bar|) baz")
        #expect(buffer.type("w").marked == "foo(bar) |baz")
        #expect(buffer.type("b").marked == "foo(bar|) baz")
    }

    @Test func eLandsOnTheLastCharacterOfTheWord() {
        let buffer = Buffer("alpha beta", caret: 0)
        #expect(buffer.type("e").marked == "alph|a beta")
        #expect(buffer.type("e").marked == "alpha bet|a")
    }

    // MARK: Operators

    @Test func dwDeletesToTheNextWord() {
        let buffer = Buffer("alpha beta gamma", caret: 0)
        #expect(buffer.type("dw").text == "beta gamma")
        #expect(buffer.caret == 0)
    }

    @Test func ddDeletesWholeLinesAndCountsThem() {
        #expect(Buffer("one\ntwo\nthree", caret: 4).type("dd").text == "one\nthree")
        #expect(Buffer("one\ntwo\nthree", caret: 0).type("2dd").text == "three")
    }

    @Test func dDollarDeletesToTheEndOfTheLine() {
        let buffer = Buffer("keep this\nnext", caret: 4)
        #expect(buffer.type("d$").text == "keep\nnext")
    }

    @Test func changeEntersInsertWithTheTextGone() {
        let buffer = Buffer("alpha beta", caret: 0)
        buffer.type("cw")
        #expect(buffer.text == "beta")
        #expect(buffer.mode == .insert, "c must leave you typing")
    }

    /// `cc` empties the line but keeps it — and keeps its indentation, which
    /// is the whole point of using it over `dd` then `O`.
    @Test func ccKeepsTheLineAndItsIndent() {
        let buffer = Buffer("def one():\n    return 1\n", caret: 15)
        buffer.type("cc")
        #expect(buffer.text == "def one():\n    \n")
        #expect(buffer.mode == .insert)
        #expect(buffer.marked == "def one():\n    |\n")
    }

    @Test func yankThenPastePutsItBack() {
        let buffer = Buffer("alpha beta", caret: 0)
        buffer.type("yw")
        #expect(buffer.text == "alpha beta", "yank must not change the text")
        buffer.type("$p")
        #expect(buffer.text == "alpha betaalpha ")
    }

    @Test func linewiseYankPastesAsAWholeLine() {
        let buffer = Buffer("one\ntwo", caret: 0)
        buffer.type("yy")
        buffer.type("p")
        #expect(buffer.text == "one\none\ntwo")
    }

    @Test func xDeletesUnderTheCaretAndStopsAtTheLineEnd() {
        #expect(Buffer("abc", caret: 1).type("x").text == "ac")
        #expect(Buffer("abc", caret: 0).type("5x").text == "",
                "x ran past the end of the line")
    }

    @Test func capitalDDeletesToTheEndOfTheLine() {
        #expect(Buffer("keep this\nnext", caret: 4).type("D").text == "keep\nnext")
    }

    // MARK: Insert entries

    @Test func insertEntriesLandInTheRightPlace() {
        #expect(Buffer("abc", caret: 1).type("i").caret == 1)
        #expect(Buffer("abc", caret: 1).type("a").caret == 2, "a is after the caret")
        #expect(Buffer("  abc", caret: 4).type("I").caret == 2, "I is the first non-blank")
        #expect(Buffer("abc\ndef", caret: 0).type("A").caret == 3, "A is the end of the line")
    }

    /// `o` opens a line below and carries the indentation down with it.
    @Test func oOpensAnIndentedLineBelow() {
        let buffer = Buffer("    first\nsecond", caret: 5)
        buffer.type("o")
        #expect(buffer.text == "    first\n    \nsecond")
        #expect(buffer.mode == .insert)
        #expect(buffer.marked == "    first\n    |\nsecond")
    }

    @Test func capitalOOpensAbove() {
        let buffer = Buffer("  first", caret: 3)
        buffer.type("O")
        #expect(buffer.text == "  \n  first")
    }

    // MARK: Modes

    @Test func escapeLeavesInsertMode() {
        let buffer = Buffer("abc", caret: 0)
        buffer.type("i")
        #expect(buffer.mode == .insert)
        buffer.press("ESC")
        #expect(buffer.mode == .normal)
    }

    /// In insert mode the engine must keep its hands off: everything except
    /// Escape belongs to the text view.
    @Test func insertModePassesKeysThrough() {
        let engine = VimEngine()
        #expect(engine.handle(VimKey("d"), mode: .insert, text: "abc", caret: 0) == nil,
                "insert mode is typing: the engine wants none of it")
        #expect(engine.handle(VimKey("ESC"), mode: .insert, text: "abc", caret: 0)?.mode == .normal)
    }

    @Test func visualModeSelectsAsItMoves() {
        let buffer = Buffer("alpha beta", caret: 0)
        buffer.type("v")
        #expect(buffer.mode == .visual)
        buffer.type("ll")
        // Inclusive of both ends, as Vim highlights it: a, l and p.
        #expect(buffer.selection == NSRange(location: 0, length: 3))
        buffer.type("d")
        #expect(buffer.text == "ha beta", "visual delete took the wrong range")
        #expect(buffer.mode == .normal)
    }

    /// A dead end abandons the command rather than half-running it.
    @Test func anUnknownOperatorTargetDoesNothing() {
        let buffer = Buffer("alpha beta", caret: 0)
        buffer.type("dz")
        #expect(buffer.text == "alpha beta")
        #expect(buffer.mode == .normal)
    }

    @Test func editingAnEmptyBufferIsHarmless() {
        let buffer = Buffer("", caret: 0)
        buffer.type("dwddxG$")
        #expect(buffer.text == "")
        #expect(buffer.caret == 0)
    }
}
