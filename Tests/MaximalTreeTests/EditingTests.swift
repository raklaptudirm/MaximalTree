import Testing
import Foundation
@testable import MaximalEditorKit

/// Modal editing, checked the way it is used: type keys at a buffer and say
/// what is selected, where the caret went, and what the text became.
///
/// Helix's order throughout — a thing is selected and *then* acted on — so
/// nearly every test here reads as two halves: what `w` selected, and what `d`
/// did to it.
@MainActor
@Suite struct EditingTests {
    /// Drives the engine like a keyboard, applying each edit as it comes.
    @MainActor
    private final class Buffer {
        let engine = EditEngine()
        var text: String
        var selection: NSRange
        /// The mode the app would be holding — the engine has none of its own.
        var mode: EditMode = .normal
        /// The end of the selection the cursor is on, which is what the view
        /// scrolls to. Kept exactly as `EditorTextView.apply` keeps it.
        var caret: Int

        init(_ text: String, at location: Int = 0) {
            self.text = text
            let length = (text as NSString).length
            self.selection = NSRange(location: location,
                                     length: location < length ? 1 : 0)
            self.caret = location
        }

        @discardableResult
        func press(_ key: String) -> Buffer { feed(key) }

        @discardableResult
        func type(_ keys: String) -> Buffer {
            for character in keys {
                feed(character == " " ? "SPC" : String(character))
            }
            return self
        }

        /// Keys typed towards a command, and the repeat in front of them.
        ///
        /// The engine no longer parses either: the core's trie resolves the
        /// sequence and carries the count, and the engine is handed a named
        /// command. This does the same job so the tests can go on reading as
        /// keys — and, better, it resolves them through the very table the app
        /// ships, so what these exercise is the real binding.
        private var pending = ""
        private var repeat_ = 0

        @discardableResult
        private func feed(_ key: String) -> Buffer {
            // Escape is the app's, not the editor's: it means normal mode.
            if key == "ESC" {
                let leavingInsert = mode == .insert
                mode = .normal
                pending = ""
                repeat_ = 0
                // What the app does: leaving insert puts a selection back,
                // because normal mode always has one.
                if leavingInsert { return run(.collapseSelection, count: 1) }
                return self
            }
            // A digit before a sequence is a count, unless one is being typed.
            if pending.isEmpty, key.count == 1, let digit = Int(key),
               digit > 0 || repeat_ > 0 {
                repeat_ = repeat_ * 10 + digit
                return self
            }
            let sequence = pending.isEmpty ? key : pending + " " + key
            guard let command = Self.command(for: sequence) else {
                // Not a command yet: hold it if anything starts this way.
                pending = Self.isPrefix(sequence) ? sequence : ""
                return self
            }
            pending = ""
            let count = max(repeat_, 1)
            repeat_ = 0
            return run(command, count: count)
        }

        @discardableResult
        private func run(_ command: EditCommand, count: Int) -> Buffer {
            guard let outcome = engine.perform(command, count: count, mode: mode,
                                               text: text, selection: selection)
            else { return self }
            mode = outcome.mode
            if let edit = outcome.edit {
                let ns = NSMutableString(string: text)
                ns.replaceCharacters(in: edit.range, with: edit.replacement)
                text = ns as String
            }
            let length = (text as NSString).length
            let start = min(max(outcome.selection.location, 0), length)
            selection = NSRange(location: start,
                                length: min(outcome.selection.length, length - start))
            caret = min(max(outcome.caret, 0), length)
            return self
        }

        /// The command a key sequence runs, from the bindings the app ships.
        static func command(for sequence: String) -> EditCommand? {
            EditorKeys.bindings.first { $0.key == sequence }?.command
        }

        /// Whether anything the editor binds starts this way.
        static func isPrefix(_ sequence: String) -> Bool {
            EditorKeys.bindings.contains { $0.key.hasPrefix(sequence + " ") }
        }

        /// What is selected, in brackets — which reads better in a failure
        /// than two numbers do.
        var marked: String {
            let ns = text as NSString
            return ns.substring(to: selection.location) + "["
                + ns.substring(with: selection) + "]"
                + ns.substring(from: NSMaxRange(selection))
        }

        var selected: String { (text as NSString).substring(with: selection) }
    }

    // MARK: Selecting

    /// The cursor is a selection, always at least one character. That is what
    /// makes a bare `d` mean something without a motion after it.
    @Test func theCursorIsAlwaysASelection() {
        #expect(Buffer("abc").marked == "[a]bc")
        #expect(Buffer("abc", at: 2).marked == "ab[c]")
    }

    @Test func hjklMoveTheCursorAndStopAtTheEdges() {
        let buffer = Buffer("abc\ndef")
        #expect(buffer.type("l").marked == "a[b]c\ndef")
        #expect(buffer.type("ll").marked == "ab[c]\ndef", "l ran past the end of the line")
        #expect(buffer.type("j").marked == "abc\nde[f]")
        #expect(buffer.type("h").marked == "abc\nd[e]f")
        // Column 1, because `h` just moved there — a block cursor sits *on* a
        // character, so it can't rest past the end of a line the way a caret
        // between characters could.
        #expect(buffer.type("k").marked == "a[b]c\ndef", "k lost the column")
    }

    /// `w` selects the word it crosses rather than just landing past it —
    /// this is the half of `wd` that Vim spelled as the second half of `dw`.
    @Test func wSelectsTheWordItCrosses() {
        #expect(Buffer("alpha beta").type("w").selected == "alpha ")
        #expect(Buffer("alpha beta").type("ww").selected == "beta")
    }

    @Test func countsMultiplySelections() {
        #expect(Buffer("alpha beta gamma").type("2w").selected == "alpha beta ")
        #expect(Buffer("abcdefgh").type("3l").marked == "abc[d]efgh")
    }

    @Test func bSelectsBackwardsAndESelectsToTheWordEnd() {
        #expect(Buffer("alpha beta", at: 6).type("b").selected == "alpha ")
        #expect(Buffer("alpha beta").type("e").selected == "alpha")
    }

    /// Punctuation is its own word, which is why `w` stops at the bracket.
    @Test func wordsTreatPunctuationAsItsOwn() {
        let buffer = Buffer("foo(bar) baz")
        #expect(buffer.type("w").selected == "foo")
        #expect(buffer.type("w").selected == "(")
    }

    @Test func lineMotionsSelectToTheirEnds() {
        let buffer = Buffer("    indented line\nsecond", at: 6)
        #expect(buffer.type("0").selected == "    in")
        #expect(Buffer("    indented line\nsecond", at: 6).type("^").selected == "in")
        #expect(Buffer("    indented", at: 4).type("$").selected == "indented")
    }

    /// `x` selects the line — the deleting is `d`'s job, on whatever is
    /// selected. In Vim this key deleted a character; here that is `d` with a
    /// one-character selection, which is what the cursor already is.
    @Test func xSelectsWholeLines() {
        #expect(Buffer("one\ntwo\nthree", at: 4).type("x").selected == "two\n")
        #expect(Buffer("one\ntwo\nthree").type("2x").selected == "one\ntwo\n")
    }

    /// `g e` is the end of the document. It used to answer exactly what `G`
    /// answers — the *start* of the last line — so the app shipped two keys
    /// for one place and no key for the end of the file.
    @Test func goToEndReachesTheEndOfTheDocument() {
        let buffer = Buffer("one\ntwo\nthree").type("ge")
        #expect(buffer.selection.location == ("one\ntwo\nthree" as NSString).length)
        // And that is somewhere G does not go.
        #expect(Buffer("one\ntwo\nthree").type("G").selection.location == 8)
    }

    /// What goes in the register follows one rule, whichever verb filled it.
    /// Delete recorded "never whole lines" while yank worked it out from the
    /// text, so `x d p` put the line back inside another one while `x y p`
    /// put it on its own — the same selection, the same paste, two answers.
    @Test func deletingAndYankingFillTheRegisterTheSameWay() {
        let deleted = Buffer("one\ntwo\nthree").type("xdp").text
        let yanked = Buffer("one\ntwo\nthree").type("xyp").text
        #expect(deleted == "two\none\nthree", "d then p: \(deleted)")
        #expect(yanked == "one\none\ntwo\nthree", "y then p: \(yanked)")
        // Neither leaves a blank line behind: a linewise paste goes *between*
        // lines, and the register already carries the newline that makes one.
        #expect(!deleted.contains("\n\n") && !yanked.contains("\n\n"))
    }

    /// Vertical motion is the one thing the engine cannot work out from text.
    ///
    /// With wrapping on, the line below you is a line on screen, not a line in
    /// the file — so `j` asks the view, and only falls back to source lines
    /// when nobody can answer.
    @Test func verticalMotionPrefersWhatTheViewSays() {
        let engine = EditEngine()
        let text = "a long first line\nsecond"
        var asked: (offset: Int, delta: Int)?

        let outcome = engine.perform(.down, count: 1, mode: .normal, text: text,
                                     selection: NSRange(location: 0, length: 1),
                                     visualLine: { offset, delta in
            asked = (offset, delta)
            return 7        // wherever the layout says, not where the text does
        })
        #expect(asked?.delta == 1)
        #expect(outcome?.selection.location == 7, "took the source line over the view")

        // Nobody to ask: the file's own lines, as before.
        let fallback = engine.perform(.down, count: 1, mode: .normal, text: text,
                                      selection: NSRange(location: 0, length: 1))
        #expect(fallback?.selection.location == 18)
    }

    @Test func percentSelectsEverything() {
        #expect(Buffer("one\ntwo").type("%").selected == "one\ntwo")
    }

    /// A goto moves the cursor; it does not drag a selection behind it.
    /// `g g` used to select everything above you, which is a surprise every
    /// time — a word motion selects what it crosses, but a jump is not
    /// crossing anything you meant to keep.
    @Test func ggAndGMoveTheCursorToTheEnds() {
        let toTop = Buffer("one\ntwo\nthree", at: 5).type("gg")
        #expect(toTop.selection.location == 0)
        #expect(toTop.selected == "o", "the goto swept a selection along")

        let toEnd = Buffer("one\ntwo\nthree").type("G")
        #expect(toEnd.selection.location == 8)
        #expect(toEnd.selected == "t")
    }

    /// In visual mode they still extend, which is how a selection is grown to
    /// the ends of the file.
    @Test func aGotoStillExtendsWhileSelecting() {
        let buffer = Buffer("one\ntwo\nthree", at: 5)
        buffer.type("v").type("gg")
        #expect(buffer.mode == .visual)
        #expect(buffer.selection.location == 0)
        #expect(buffer.selection.length > 1, "visual mode should have grown the selection")
    }

    /// The line gotos move too — the same family, the same rule.
    @Test func theLineGotosMoveAsWell() {
        let buffer = Buffer("alpha beta\ngamma", at: 6)
        buffer.type("gh")
        #expect(buffer.selection.location == 0)
        #expect(buffer.selected == "a", "g h swept instead of moving")
    }

    // MARK: Acting on the selection

    /// The headline: select, then delete. No verb ever waits for an object.
    @Test func wdDeletesTheWordThatWasSelected() {
        let buffer = Buffer("alpha beta gamma")
        buffer.type("w")
        #expect(buffer.selected == "alpha ")
        buffer.type("d")
        #expect(buffer.text == "beta gamma")
    }

    @Test func xdDeletesTheLineThatWasSelected() {
        #expect(Buffer("one\ntwo\nthree", at: 4).type("xd").text == "one\nthree")
        #expect(Buffer("one\ntwo\nthree").type("2xd").text == "three")
    }

    /// A bare cursor is a one-character selection, so `d` on its own is Vim's
    /// `x` without needing a key of its own.
    @Test func dOnABareCursorDeletesOneCharacter() {
        #expect(Buffer("abc", at: 1).type("d").text == "ac")
    }

    @Test func cChangesWhatIsSelectedAndLeavesYouTyping() {
        let buffer = Buffer("alpha beta")
        buffer.type("wc")
        #expect(buffer.text == "beta")
        #expect(buffer.mode == .insert, "c must leave you typing")
    }

    @Test func yankThenPastePutsItBack() {
        let buffer = Buffer("alpha beta")
        buffer.type("wy")
        #expect(buffer.text == "alpha beta", "yank must not change the text")
        buffer.type("p")
        #expect(buffer.text == "alpha alpha beta")
    }

    @Test func insertEntriesLandAtEitherEndOfTheSelection() {
        let buffer = Buffer("alpha beta")
        buffer.type("w")                       // selects "alpha "
        buffer.type("i")
        #expect(buffer.selection.location == 0, "i goes to the start of the selection")
        #expect(buffer.mode == .insert)

        let other = Buffer("alpha beta")
        other.type("wa")
        #expect(other.selection.location == 6, "a goes to the end of the selection")
    }

    @Test func capitalIAndAGoToTheEndsOfTheLine() {
        #expect(Buffer("  abc", at: 4).type("I").selection.location == 2)
        #expect(Buffer("abc\ndef").type("A").selection.location == 3)
    }

    /// `o` opens a line below and carries the indentation down with it.
    @Test func oOpensAnIndentedLineBelow() {
        let buffer = Buffer("    first\nsecond", at: 5)
        buffer.type("o")
        #expect(buffer.text == "    first\n    \nsecond")
        #expect(buffer.mode == .insert)
        #expect(buffer.selection.location == 14)
    }

    @Test func capitalOOpensAbove() {
        #expect(Buffer("  first", at: 3).type("O").text == "  \n  first")
    }

    // MARK: Modes

    /// Select mode extends rather than replaces, so a selection can be built
    /// up a piece at a time before anything is done to it.
    @Test func selectModeExtendsWithEachMotion() {
        let buffer = Buffer("alpha beta gamma")
        buffer.type("v")
        #expect(buffer.mode == .visual)
        buffer.type("w")
        #expect(buffer.selected == "alpha ")
        buffer.type("w")
        #expect(buffer.selected == "alpha beta ", "the second motion should have extended")
        buffer.type("d")
        #expect(buffer.text == "gamma")
        #expect(buffer.mode == .normal)
    }

    @Test func vTogglesBackOutOfSelectMode() {
        let buffer = Buffer("alpha")
        buffer.type("v")
        #expect(buffer.mode == .visual)
        buffer.type("v")
        #expect(buffer.mode == .normal)
    }

    @Test func escapeLeavesInsertModeWithACursorAgain() {
        let buffer = Buffer("abc")
        buffer.type("i")
        #expect(buffer.mode == .insert)
        buffer.press("ESC")
        #expect(buffer.mode == .normal)
        #expect(buffer.selection.length == 1, "normal mode always has something selected")
    }

    @Test func semicolonCollapsesASelectionToACursor() {
        let buffer = Buffer("alpha beta")
        buffer.type("w")
        #expect(buffer.selected == "alpha ")
        buffer.type(";")
        #expect(buffer.selected == "a")
    }

    /// In insert mode the engine keeps its hands off. The core does not
    /// dispatch commands there at all, but an action can be run from a list,
    /// and "Delete" from the finder mid-word would be a surprise.
    @Test func nothingIsACommandWhileTyping() {
        let engine = EditEngine()
        let cursor = NSRange(location: 0, length: 1)
        for command in EditCommand.allCases {
            #expect(engine.perform(command, count: 1, mode: .insert,
                                   text: "abc", selection: cursor) == nil,
                    "\(command) acted in insert mode")
        }
    }

    /// A control chord is the app's — `C-w` is how you leave for another
    /// surface — so the editor binds none of them.
    @Test func theEditorBindsNoControlChords() {
        for binding in EditorKeys.bindings {
            #expect(!binding.key.contains("C-"),
                    "\(binding.key) would take a chord the app needs")
        }
    }

    @Test func editingAnEmptyBufferIsHarmless() {
        let buffer = Buffer("")
        buffer.type("wd")
        #expect(buffer.text == "")
        buffer.type("x")
        #expect(buffer.text == "")
    }

    // MARK: Which end the cursor is on

    /// A selection has a direction even though a range does not, and the end
    /// the reader is moving is the end the view has to keep on screen.
    ///
    /// Growing a selection downward sorts the moving end to `NSMaxRange`, so a
    /// view reading `selection.location` scrolls to the line the cursor left —
    /// once per keystroke, which is a page that jerks backwards the whole time
    /// you are selecting.
    @Test func extendingDownwardLeavesTheCursorAtTheFarEnd() {
        let buffer = Buffer("one\ntwo\nthree\nfour", at: 0)
        buffer.type("v").type("jj")
        #expect(buffer.selection.location == 0, "the anchor stays where selecting began")
        #expect(buffer.caret > buffer.selection.location,
                "the cursor is at the far end, not on the anchor")
        #expect(buffer.caret >= 8, "two lines down is past the start of the third line")
    }

    /// Upward, the two coincide — which is why following the start looked
    /// right for as long as anyone only tested it in one direction.
    @Test func extendingUpwardLeavesTheCursorAtTheStart() {
        let buffer = Buffer("one\ntwo\nthree\nfour", at: 14)
        buffer.type("v").type("kk")
        #expect(buffer.caret == buffer.selection.location)
    }

    /// A sweep to the end of a line is the same shape: the selection starts
    /// where the cursor was, and the cursor is now at the other end.
    @Test func sweepingToTheLineEndLeavesTheCursorThere() {
        let buffer = Buffer("alpha beta gamma\nnext", at: 0)
        buffer.press("$")
        #expect(buffer.caret >= 16, "the cursor went to the end of the line")
        #expect(buffer.selection.location == 0)
    }

    /// A plain motion has no far end to get wrong, and must not acquire one.
    @Test func aPlainMotionPutsTheCursorWhereItLands() {
        let buffer = Buffer("one\ntwo\nthree", at: 0)
        buffer.press("j")
        #expect(buffer.caret == buffer.selection.location)
    }

}

/// The editor's keys and the commands they name.
///
/// There were two lists once — what `handleKey` implemented and what it
/// declared for which-key — and a test to check they agreed. They are one
/// table now, so what is left to check is that the commands in it are ones the
/// engine answers to, and that the table is well formed.
@MainActor
@Suite struct EditorBindingTests {
    private let text = "one\ntwo\nthree\n"

    @Test func theEngineAnswersToEveryCommandTheEditorBinds() {
        for binding in EditorKeys.bindings {
            let engine = EditEngine()
            let outcome = engine.perform(binding.command, count: 1, mode: .normal,
                                         text: text, selection: NSRange(location: 0, length: 1))
            #expect(outcome != nil,
                    "\(binding.key) names \(binding.command), which the engine declines")
        }
    }

    /// Every command the engine has is reachable. One with no key is a feature
    /// nobody can use.
    @Test func everyCommandHasAKey() {
        let bound = Set(EditorKeys.bindings.map(\.command))
        for command in EditCommand.allCases {
            #expect(bound.contains(command), "\(command) has no key")
        }
    }

    @Test func theTableIsWellFormed() {
        let keys = EditorKeys.bindings.map(\.key)
        #expect(Set(keys).count == keys.count, "a key is bound twice")
        for binding in EditorKeys.bindings {
            #expect(!binding.key.isEmpty)
            #expect(!binding.title.isEmpty, "\(binding.key) has no label")
        }
        // Action ids follow from the command, so the keys and the
        // registrations cannot name different things.
        #expect(EditorKeys.id(for: .wordForward) == "editor.wordForward")
    }
}

/// Finding text in the document you are editing.
@MainActor
@Suite struct EditorSearchTests {
    private let text = "alpha beta\nGamma beta\ndelta"

    @Test func findsTheNextMatchAfterTheCaret() {
        let hit = EditorSearch.match(for: "beta", in: text, from: 0, forward: true)
        #expect(hit == NSRange(location: 6, length: 4))

        // And the one after that, rather than the one it is sitting on.
        let next = EditorSearch.match(for: "beta", in: text, from: 7, forward: true)
        #expect(next == NSRange(location: 17, length: 4))
    }

    /// Round the end and carry on: a search that stopped at the bottom would
    /// make `n` a key that sometimes does nothing for no visible reason.
    @Test func itWrapsPastTheEndAndBeforeTheStart() {
        let wrapped = EditorSearch.match(for: "alpha", in: text, from: 20, forward: true)
        #expect(wrapped == NSRange(location: 0, length: 5))

        let back = EditorSearch.match(for: "delta", in: text, from: 0, forward: false)
        #expect(back == NSRange(location: 22, length: 5))
    }

    @Test func backwardsFindsTheMatchBeforeTheCaret() {
        let hit = EditorSearch.match(for: "beta", in: text, from: 17, forward: false)
        #expect(hit == NSRange(location: 6, length: 4))
    }

    /// Case-insensitive, which is what "find" means until someone says
    /// otherwise — finding too much is recoverable, finding nothing looks
    /// broken.
    @Test func caseDoesNotMatter() {
        #expect(EditorSearch.match(for: "gamma", in: text, from: 0, forward: true)
                    == NSRange(location: 11, length: 5))
    }

    @Test func nothingToFindIsNotAMatch() {
        #expect(EditorSearch.match(for: "zeta", in: text, from: 0, forward: true) == nil)
        #expect(EditorSearch.match(for: "", in: text, from: 0, forward: true) == nil)
        #expect(EditorSearch.match(for: "a", in: "", from: 0, forward: true) == nil)
    }

    /// A caret past the end, or before the start, still searches.
    @Test func anOutOfRangeCaretIsClamped() {
        #expect(EditorSearch.match(for: "alpha", in: text, from: 9_999, forward: true)
                    == NSRange(location: 0, length: 5))
        #expect(EditorSearch.match(for: "alpha", in: text, from: -5, forward: true)
                    == NSRange(location: 0, length: 5))
    }
}

// MARK: - Code: indenting, commenting, brackets

extension EditingTests {
    /// `>` shifts every line the selection touches, keeps them selected so a
    /// second press shifts again, and leaves blank lines blank.
    @Test func indentShiftsTheSelectedLines() {
        let buffer = Buffer("a\n\nb\n", at: 0)
        buffer.selection = NSRange(location: 0, length: 5)     // all three lines
        buffer.press(">")
        #expect(buffer.text == "    a\n\n    b\n")
        #expect(buffer.selected == "    a\n\n    b\n")
        buffer.press(">")
        #expect(buffer.text == "        a\n\n        b\n")
    }

    @Test func indentTakesACountAndTheFilesUnit() {
        let buffer = Buffer("a\n", at: 0)
        buffer.engine.indentUnit = "\t"
        buffer.type("2>")
        #expect(buffer.text == "\t\ta\n")
    }

    /// `<` takes off a level, a tab or a unit of spaces, and a line indented
    /// by less than a unit comes out at the margin rather than staying put.
    @Test func outdentStopsAtTheMargin() {
        let buffer = Buffer("        a\n  b\nc\n\tc\n", at: 0)
        buffer.selection = NSRange(location: 0, length: (buffer.text as NSString).length)
        buffer.press("<")
        #expect(buffer.text == "    a\nb\nc\nc\n")
    }

    /// `g c` comments lines out at their shallowest indent, so the block keeps
    /// its shape — and the same keys put it back.
    @Test func gcCommentsLinesOutAndBackIn() {
        let original = "    if x {\n        y()\n\n    }\n"
        let buffer = Buffer(original, at: 0)
        buffer.engine.commentSyntax = .line("//")
        buffer.selection = NSRange(location: 0, length: (original as NSString).length)
        buffer.type("gc")
        #expect(buffer.text == "    // if x {\n    //     y()\n\n    // }\n")
        buffer.type("gc")
        #expect(buffer.text == original)
    }

    /// A block where only some lines are comments is commented as a whole,
    /// not toggled line by line.
    @Test func aPartlyCommentedBlockIsCommented() {
        let buffer = Buffer("# a\nb\n", at: 0)
        buffer.engine.commentSyntax = .line("#")
        buffer.selection = NSRange(location: 0, length: 6)
        buffer.type("gc")
        #expect(buffer.text == "# # a\n# b\n")
    }

    /// Languages with only a block comment wrap what is between the first and
    /// last character, keeping the indent and the newline outside it.
    @Test func blockCommentsWrapAndUnwrap() {
        let buffer = Buffer("  a { b }\n", at: 0)
        buffer.engine.commentSyntax = .block("/*", "*/")
        buffer.type("gc")
        #expect(buffer.text == "  /* a { b } */\n")
        buffer.type("gc")
        #expect(buffer.text == "  a { b }\n")
    }

    /// Without a comment syntax — JSON, plain text — nothing is changed.
    @Test func gcDoesNothingWhereThereAreNoComments() {
        let buffer = Buffer("a\n", at: 0)
        buffer.type("gc")
        #expect(buffer.text == "a\n")
    }

    /// `m m` goes to the bracket that closes the one under the cursor —
    /// counting nesting — and back again.
    @Test func mmJumpsToTheMatchingBracket() {
        let text = "f(a(b), c)"
        let buffer = Buffer(text, at: 1)
        buffer.type("mm")
        #expect(buffer.caret == 9)
        buffer.type("mm")
        #expect(buffer.caret == 1)
    }

    /// Not on a bracket: the first one after the cursor on the line.
    @Test func mmFindsTheNextBracketOnTheLine() {
        let buffer = Buffer("let x = [1, [2]]", at: 0)
        buffer.type("mm")
        #expect(buffer.caret == 15)
    }

    @Test func mmStaysPutWithNoBracket() {
        let buffer = Buffer("plain words", at: 3)
        buffer.type("mm")
        #expect(buffer.caret == 3)
    }
}

/// Which languages comment how — the table `g c` reads.
@Suite struct CommentSyntaxTests {
    @Test func languagesCommentTheirOwnWay() {
        func syntax(_ name: String) -> CommentSyntax? {
            EditorLanguage.commentSyntax(for: URL(fileURLWithPath: "/tmp/" + name))
        }
        #expect(syntax("a.swift") == .line("//"))
        #expect(syntax("a.py") == .line("#"))
        #expect(syntax("a.lua") == .line("--"))
        #expect(syntax("Makefile") == .line("#"))
        #expect(syntax("a.html") == .block("<!--", "-->"))
        #expect(syntax("a.typ") == .line("//"))
        #expect(syntax("a.json") == nil)
    }
}
