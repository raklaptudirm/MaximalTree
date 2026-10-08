import Testing
import Foundation
import STTextView
@testable import MaximalEditorKit

/// What typing does in code, as rules: text and a caret in, the text and caret
/// out. `|` marks the caret in each case.
@Suite struct TypingTests {
    /// Splits "a|b" into the text and the caret's offset.
    private func at(_ marked: String) -> (text: String, caret: NSRange) {
        let ns = marked as NSString
        let bar = ns.range(of: "|")
        return (ns.replacingCharacters(in: bar, with: ""), NSRange(location: bar.location, length: 0))
    }

    /// Applies an outcome, and marks where the caret went.
    private func result(_ outcome: EditOutcome?, on text: String) -> String? {
        guard let outcome else { return nil }
        let ns = NSMutableString(string: text)
        if let edit = outcome.edit { ns.replaceCharacters(in: edit.range, with: edit.replacement) }
        ns.insert("|", at: outcome.selection.location)
        return ns as String
    }

    private func newline(_ marked: String, code: Bool = true) -> String? {
        let (text, caret) = at(marked)
        return result(Typing.newline(in: text, selection: caret, indentUnit: "    ", code: code), on: text)
    }

    private func type(_ character: String, _ marked: String) -> String? {
        let (text, caret) = at(marked)
        return result(Typing.typed(character, in: text, selection: caret, indentUnit: "    ", code: true),
                      on: text)
    }

    private func backspace(_ marked: String) -> String? {
        let (text, caret) = at(marked)
        return result(Typing.deleteBackward(in: text, selection: caret, indentUnit: "    ", code: true),
                      on: text)
    }

    // MARK: A new line

    @Test func aNewLineKeepsItsIndent() {
        #expect(newline("    let x = 1|") == "    let x = 1\n    |")
    }

    @Test func afterAnOpenerItGoesALevelDeeper() {
        #expect(newline("if x {|") == "if x {\n    |")
        #expect(newline("case .a:|") == "case .a:\n    |")
    }

    /// Between a bracket and its closer, the closer gets its own line.
    @Test func betweenAPairItOpensABlock() {
        #expect(newline("  f {|}") == "  f {\n      |\n  }")
        #expect(newline("call(|  )") == "call(\n    |\n)")
    }

    /// Prose keeps its indent and nothing more.
    @Test func proseOnlyKeepsItsIndent() {
        #expect(newline("  notes {|}", code: false) == "  notes {\n  |}")
    }

    // MARK: Pairs

    @Test func anOpenerComesWithItsCloser() {
        #expect(type("(", "f|") == "f(|)")
        #expect(type("{", "x = |\n") == "x = {|}\n")
    }

    /// Not in front of a word: the closer would land in the middle of it.
    @Test func notInFrontOfAWord() {
        #expect(type("(", "|word") == nil)
    }

    @Test func typingTheCloserStepsOverIt() {
        #expect(type(")", "f(|)") == "f()|")
        #expect(type("\"", "\"a|\"") == "\"a\"|")
    }

    @Test func quotesPairButNotAfterAWord() {
        #expect(type("\"", "x = |") == "x = \"|\"")
        #expect(type("'", "don|") == nil, "an apostrophe opened a string")
    }

    @Test func aSelectionIsWrapped() {
        let outcome = Typing.typed("(", in: "a b", selection: NSRange(location: 2, length: 1),
                                   indentUnit: "    ", code: true)
        #expect(outcome?.edit?.replacement == "(b)")
        #expect(outcome?.selection == NSRange(location: 3, length: 1), "the inside stays selected")
    }

    /// A closer on a line of only indent closes the block above: a level out.
    @Test func aCloserFindsItsLevel() {
        #expect(type("}", "if x {\n    y\n    |") == "if x {\n    y\n}|")
    }

    @Test func proseTypesBracketsAsTheyAre() {
        #expect(Typing.typed("(", in: "a", selection: NSRange(location: 1, length: 0),
                             indentUnit: "  ", code: false) == nil)
    }

    // MARK: Backspace

    @Test func backspaceTakesAnEmptyPair() {
        #expect(backspace("f(|)") == "f|")
        #expect(backspace("\"|\"") == "|")
    }

    @Test func backspaceTakesAWholeIndent() {
        #expect(backspace("        |") == "    |")
        #expect(backspace("      |") == "    |", "a part indent goes back to the level below it")
    }

    @Test func otherwiseBackspaceIsBackspace() {
        #expect(backspace("ab|") == nil)
        #expect(backspace("x   |") == nil, "spaces after text are not indent")
    }
}

/// The same rules, reached the way typing reaches them: through the text
/// view's own input methods, with the code style applied.
@MainActor
@Suite struct TypingInTheEditorTests {
    private func editor(_ text: String, caret: Int) -> MaximalEditor.EditorTextView {
        let scrollView = MaximalEditor.EditorTextView.scrollableTextView()
        let view = scrollView.documentView as! MaximalEditor.EditorTextView
        MaximalEditor.apply(style: .code(), to: view)
        view.text = text
        view.textSelection = NSRange(location: caret, length: 0)
        return view
    }

    @Test func returnOpensABlock() {
        let view = editor("if x {}", caret: 6)
        view.insertNewline(nil)
        #expect(view.text == "if x {\n    \n}")
    }

    @Test func anOpenerTypedPairs() {
        let view = editor("f", caret: 1)
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.text == "f()")
    }

    @Test func backspaceTakesThePair() {
        let view = editor("f()", caret: 2)
        view.deleteBackward(nil)
        #expect(view.text == "f")
    }

    @Test func tabIsOneIndent() {
        let view = editor("", caret: 0)
        view.insertTab(nil)
        #expect(view.text == "    ")
    }

    /// A paste is not typing: it goes in as it is.
    @Test func aPasteIsNotTyped() {
        let view = editor("f", caret: 1)
        view.insertText("(", replacementRange: NSRange(location: 1, length: 0))
        #expect(view.text == "f(")
    }
}
