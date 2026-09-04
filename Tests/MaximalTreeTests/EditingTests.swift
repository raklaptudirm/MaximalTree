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

        init(_ text: String, at location: Int = 0) {
            self.text = text
            let length = (text as NSString).length
            self.selection = NSRange(location: location,
                                     length: location < length ? 1 : 0)
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

        @discardableResult
        private func feed(_ key: String) -> Buffer {
            guard let outcome = engine.handle(EditKey(key), mode: mode,
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
            return self
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

    @Test func percentSelectsEverything() {
        #expect(Buffer("one\ntwo").type("%").selected == "one\ntwo")
    }

    @Test func ggAndGReachTheEnds() {
        #expect(Buffer("one\ntwo\nthree", at: 5).type("gg").selected == "one\nt")
        #expect(Buffer("one\ntwo\nthree").type("G").selected == "one\ntwo\n")
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

    /// In insert mode the engine keeps its hands off: everything except
    /// Escape belongs to the text view.
    @Test func insertModePassesKeysThrough() {
        let engine = EditEngine()
        let cursor = NSRange(location: 0, length: 1)
        #expect(engine.handle(EditKey("d"), mode: .insert, text: "abc", selection: cursor) == nil)
        #expect(engine.handle(EditKey("ESC"), mode: .insert, text: "abc",
                              selection: cursor)?.mode == .normal)
    }

    /// A control chord is not the letter inside it, and the engine binds none
    /// of them: `C-w` is the app's window prefix, not a word motion.
    @Test func controlChordsBelongToTheApp() {
        let engine = EditEngine()
        let cursor = NSRange(location: 0, length: 1)
        for letter in ["w", "o", "i", "d", "g"] {
            #expect(engine.handle(EditKey(letter, control: true), mode: .normal,
                                  text: "alpha beta", selection: cursor) == nil,
                    "C-\(letter) should fall through to the app")
        }
    }

    @Test func editingAnEmptyBufferIsHarmless() {
        let buffer = Buffer("")
        buffer.type("wd")
        #expect(buffer.text == "")
        buffer.type("x")
        #expect(buffer.text == "")
    }
}

/// The editor's declared keys and the keys it actually answers to.
///
/// `EditEngine` decides by pattern-matching over key sequences, and a switch
/// cannot be asked what it matches — so the list which-key shows is written by
/// hand beside it. This is what keeps the two honest: a key added to the
/// switch without being listed stays invisible, and a key listed but not
/// handled is worse, because the overlay promises something that does nothing.
@MainActor
@Suite struct DeclaredEditorKeysTests {
    private let text = "hello world\nsecond line\nthird line\n"

    @Test func theEngineAnswersToEveryKeyTheEditorClaims() {
        for binding in MaximalEditor.EditorTextView.modalBindings {
            let engine = EditEngine()
            var selection = NSRange(location: 0, length: 0)
            var outcome: EditOutcome?
            // A sequence is written with spaces, and every key of it has to
            // land — `g` alone is pending, `g g` is the motion.
            for key in binding.key.split(separator: " ") {
                outcome = engine.handle(EditKey(String(key)), mode: .normal,
                                        text: text, selection: selection)
                if let outcome { selection = outcome.selection }
            }
            #expect(outcome != nil,
                    "\(binding.key) — \(binding.title) — is claimed but the engine declines it")
        }
    }

    /// Every claim is for a mode the app actually has, and reads as something.
    @Test func theClaimsAreWellFormed() {
        let bindings = MaximalEditor.EditorTextView.modalBindings
        #expect(!bindings.isEmpty)
        for binding in bindings {
            #expect(!binding.title.isEmpty, "\(binding.key) has no label to show")
            #expect(!binding.key.isEmpty)
        }
        // No duplicates: the overlay identifies rows by key, and two rows with
        // the same id is a SwiftUI list that drops one silently.
        let keys = bindings.filter { $0.mode == .normal }.map(\.key)
        #expect(Set(keys).count == keys.count, "a key is claimed twice")
    }
}

