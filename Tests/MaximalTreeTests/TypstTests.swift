import Testing
import Foundation
import PDFKit
@testable import MaximalTreeKit
@testable import MaximalTree
@testable import MaximalEditorKit

/// File/tag → highlighter language detection: the mapping tables themselves.
@Suite struct EditorLanguageTests {
    private func id(_ path: String) -> String? {
        EditorLanguage.id(for: URL(fileURLWithPath: path))
    }

    /// **The** invariant: every id we can produce must be a language the bundled
    /// highlight.js actually knows. An unknown name doesn't fail loudly — it
    /// silently triggers auto-detection, which paints wrong colors confidently.
    @MainActor
    @Test func everyMappedLanguageIsSupportedByTheHighlighter() {
        let ids = Set(EditorLanguage.idsByExtension.values)
            .union(EditorLanguage.idsByFileName.values)
            .union(EditorLanguage.aliases.values)
        for id in ids.sorted() {
            #expect(SyntaxTokenizer.isSupported(id), "unsupported language id: \(id)")
        }
        // The table is meant to be broad, not a token gesture.
        #expect(ids.count > 100, "expected wide language coverage, got \(ids.count)")
    }

    @Test func detectsLanguagesByExtension() {
        #expect(id("/a/b.swift") == "swift")
        #expect(id("/a/b.rs") == "rust")
        #expect(id("/a/b.py") == "python")
        #expect(id("/a/b.tsx") == "typescript")
        #expect(id("/a/b.hpp") == "cpp")
        #expect(id("/a/b.ex") == "elixir")
        #expect(id("/a/b.tf") == nil, "terraform has no grammar here — stay plain")
    }

    @Test func mapsFormatsOntoTheGrammarsThatModelThem() {
        #expect(id("/a/b.toml") == "ini")        // hljs models TOML as INI
        #expect(id("/a/index.html") == "xml")
        #expect(id("/a/b.sh") == "bash")
        #expect(id("/a/b.yml") == "yaml")
        #expect(id("/a/b.plist") == "xml")
    }

    @Test func detectsExtensionlessBuildFilesAndDotfiles() {
        #expect(id("/p/Makefile") == "makefile")
        #expect(id("/p/Dockerfile") == "dockerfile")
        #expect(id("/p/Podfile") == "ruby")
        #expect(id("/p/.zshrc") == "bash")
        #expect(id("/p/.gitconfig") == "ini")
        // Whole-name matches beat the extension: this is CMake, not plain text.
        #expect(id("/p/CMakeLists.txt") == "cmake")
        #expect(id("/p/README.txt") == "plaintext")
    }

    /// Grammar-less text files still resolve — to `plaintext`, which is what
    /// makes them *editable* (the text canvas claims what it can name) without
    /// inventing syntax for them.
    @Test func grammarlessTextFilesResolveToPlaintext() {
        #expect(id("/p/LICENSE") == "plaintext")
        #expect(id("/p/.gitignore") == "plaintext")
        #expect(id("/p/build.log") == "plaintext")
        #expect(id("/p/notes.bin") == nil, "unknown binary stays unclaimed")
    }

    @Test func normalizesRawBlockTags() {
        #expect(EditorLanguage.id(forTag: "yml") == "yaml")
        #expect(EditorLanguage.id(forTag: "C++") == "cpp")
        #expect(EditorLanguage.id(forTag: " Rust ") == "rust")
        #expect(EditorLanguage.id(forTag: "objective-c") == "objectivec")
        #expect(EditorLanguage.id(forTag: "") == nil)
    }

    @Test func displayNamesReadLikeLanguages() {
        #expect(editorLanguageName(for: URL(fileURLWithPath: "/a/b.cpp")) == "C++")
        #expect(editorLanguageName(for: URL(fileURLWithPath: "/a/b.m")) == "Objective-C")
        #expect(editorLanguageName(for: URL(fileURLWithPath: "/a/b.swift")) == "Swift")
        #expect(editorLanguageName(for: URL(fileURLWithPath: "/a/b.zzz")) == nil)
    }
}

/// The typst tokenizer memoizes its last parse, since repaints (a click into
/// another paragraph, a theme switch) far outnumber edits. A cache is only
/// worth having if it cannot serve tokens for text that no longer exists.
@MainActor
@Suite struct TypstTokenizerCacheTests {
    private func kinds(_ tokens: [(range: NSRange, kind: EditorTokenKind)]) -> [String] {
        tokens.map { "\($0.range)-\($0.kind)" }
    }

    @Test func repeatedRepaintsOfUnchangedTextAgree() {
        let tokenizer = TypstTokenizer()
        let text = "= Heading\n\nProse with $x^2$ and *strong* words."
        let first = tokenizer.tokens(in: text)
        let second = tokenizer.tokens(in: text)
        #expect(!first.isEmpty)
        #expect(kinds(first) == kinds(second))
    }

    @Test func editedTextIsReparsedNotServedFromTheCache() {
        let tokenizer = TypstTokenizer()
        _ = tokenizer.tokens(in: "= Heading\n\nJust prose here.")
        // Same length would not save it either; the heading moved and gained math.
        let edited = "Just prose here.\n\n= Heading\n\n$x^2$ trailing"
        let tokens = tokenizer.tokens(in: edited)
        let ns = edited as NSString
        for token in tokens {
            #expect(token.range.upperBound <= ns.length, "token outside the new text")
        }
        #expect(tokens.contains { if case .math = $0.kind { return true } else { return false } },
                "the re-parse missed math the first text didn't have")
        #expect(tokens.contains { if case .heading = $0.kind {
            return $0.range.location > 10
        } else { return false } }, "heading token still at its old location")
    }
}

/// The stock tokenizer driving the real highlight.js engine.
@MainActor
@Suite struct SyntaxTokenizerTests {
    @Test func fileURLInitFollowsLanguageDetection() {
        #expect(SyntaxTokenizer(fileURL: URL(fileURLWithPath: "/a/b.swift")) != nil)
        #expect(SyntaxTokenizer(fileURL: URL(fileURLWithPath: "/p/Dockerfile")) != nil)
        #expect(SyntaxTokenizer(fileURL: URL(fileURLWithPath: "/a/b.xyzunknown")) == nil)
    }

    /// The point of running highlight.js ourselves: tokens come back in the
    /// editor's own vocabulary, so the palette themes them and one pass serves
    /// both appearances.
    @Test func emitsSemanticKindsNotBakedInColours() {
        let tokens = SyntaxTokenizer(language: "swift")
            .tokens(in: "let x = 1 // done")
        #expect(!tokens.isEmpty)
        #expect(tokens.contains { $0.kind == .keyword }, "`let` is a keyword")
        #expect(tokens.contains { $0.kind == .number }, "`1` is a number")
        #expect(tokens.contains { $0.kind == .comment }, "`// done` is a comment")
        #expect(!tokens.contains {
            if case .colored = $0.kind { return true } else { return false }
        }, "code should not carry pinned colours")
    }

    /// Ranges must land on the *source* text, not highlight.js's escaped HTML.
    @Test func rangesSurviveEscapingAndUnicode() {
        let code = "let s = \"a<b & c\" // ✅ done"
        let tokens = SyntaxTokenizer(language: "swift").tokens(in: code)
        let ns = code as NSString
        let string = tokens.first { $0.kind == .string }
        #expect(string.map { ns.substring(with: $0.range) } == "\"a<b & c\"",
                "the escaped `<` and `&` must not shift offsets")
        let comment = tokens.first { $0.kind == .comment }
        #expect(comment.map { ns.substring(with: $0.range) } == "// ✅ done",
                "a non-BMP emoji must not shift offsets either")
    }

    @Test func markupKindsNeverLeakFromCode() {
        // Markdown emits sections/bullets; mapping those to markup kinds would
        // conceal characters inside a code block, so they must arrive as
        // colour-only kinds.
        let tokens = SyntaxTokenizer(language: "markdown")
            .tokens(in: "# Title\n\n- item\n")
        #expect(!tokens.isEmpty)
        for token in tokens {
            switch token.kind {
            case .heading, .punctuation, .listItem, .listMarker, .aligned,
                 .math, .struck, .underlined, .term, .strong, .emphasis:
                Issue.record("markup kind \(token.kind) leaked from a code tokenizer")
            default: break
            }
        }
    }

    @Test func unknownLanguagesYieldNothingRatherThanGuesses() {
        // No auto-detection fallback: a language we can't name paints nothing.
        #expect(SyntaxTokenizer.highlight("let x = 1", language: "notalanguage").isEmpty)
    }

    @Test func highlightsAcrossTheBreadthOfTheTable() {
        // A spread of grammars, each producing tokens for real snippets.
        let samples: [(String, String)] = [
            ("python", "def f(x):\n    return x  # ok"),
            ("ruby", "def f(x)\n  x # ok\nend"),
            ("go", "func main() { /* hi */ }"),
            ("rust", "fn main() { let x = 1; }"),
            ("java", "class A { int x = 1; }"),
            ("bash", "echo \"hi\" # comment"),
            ("yaml", "key: value # comment"),
            ("json", "{\"a\": 1}"),
            ("ini", "[section]\nkey = 1"),
            ("dockerfile", "FROM alpine\nRUN echo hi"),
            ("makefile", "all:\n\techo hi"),
            ("sql", "SELECT * FROM t WHERE x = 1"),
            ("xml", "<a href=\"b\">c</a>"),
            ("haskell", "main = putStrLn \"hi\""),
            ("lua", "local x = 1 -- comment"),
        ]
        for (language, code) in samples {
            #expect(!SyntaxTokenizer.highlight(code, language: language).isEmpty,
                    "no highlighting for \(language)")
        }
    }

    /// Diff hunks read *as* colours — the one case with no semantic equivalent.
    @Test func diffsKeepPinnedColours() {
        let tokens = SyntaxTokenizer.highlight("--- a\n+++ b\n+added\n-removed\n",
                                               language: "diff")
        #expect(tokens.contains {
            if case .colored = $0.1 { return true } else { return false }
        })
    }
}

/// The HTML→runs scanner, exercised without the JS engine.
@MainActor
@Suite struct SyntaxEngineParsingTests {
    @Test func decodesEntitiesAndNesting() {
        let html = "<span class=\"hljs-keyword\">if</span> a &lt; b &amp;&amp; c"
        let runs = SyntaxEngine.parse(html: html, matching: "if a < b && c")
        #expect(runs.count == 1)
        #expect(runs[0].0 == NSRange(location: 0, length: 2))
        #expect(runs[0].1 == "hljs-keyword")
    }

    @Test func innermostClassWins() {
        let html = "<span class=\"hljs-function\">f<span class=\"hljs-title\">g</span></span>"
        let runs = SyntaxEngine.parse(html: html, matching: "fg")
        #expect(runs.map(\.1) == ["hljs-function", "hljs-title"])
        #expect(runs[1].0 == NSRange(location: 1, length: 1))
    }

    /// If the decoded text ever stops matching the source, offsets would be
    /// wrong — paint nothing rather than paint in the wrong place.
    @Test func mismatchedOutputPaintsNothing() {
        #expect(SyntaxEngine.parse(html: "totally different", matching: "abc").isEmpty)
        #expect(SyntaxEngine.parse(html: "<div>x</div>", matching: "x").isEmpty)
    }
}

@Suite struct TypstNotesTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func packageInstallIsIdempotent() throws {
        let data = try tempDir()
        defer { try? FileManager.default.removeItem(at: data) }

        let dir = try TypstNotes.installPackage(dataDirectory: data)
        let manifest = dir.appendingPathComponent("typst.toml")
        let library = dir.appendingPathComponent("lib.typ")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(try String(contentsOf: library, encoding: .utf8) == TypstNotes.library)

        let firstDate = try FileManager.default
            .attributesOfItem(atPath: library.path)[.modificationDate] as? Date
        try TypstNotes.installPackage(dataDirectory: data)   // second run: no rewrite
        let secondDate = try FileManager.default
            .attributesOfItem(atPath: library.path)[.modificationDate] as? Date
        #expect(firstDate == secondDate)
    }

    @Test func newNoteURLsAreUniqued() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)

        let first = TypstNotes.newNoteURL(in: dir, date: date)
        try "x".write(to: first, atomically: true, encoding: .utf8)
        let second = TypstNotes.newNoteURL(in: dir, date: date)

        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix(" 2.typ"))
    }

    @Test func dailyNoteURLIsStableForADay() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let noon = Date(timeIntervalSince1970: 1_790_000_000)
        let laterSameDay = noon.addingTimeInterval(3600)
        #expect(TypstNotes.dailyNoteURL(in: dir, date: noon)
                == TypstNotes.dailyNoteURL(in: dir, date: laterSameDay))
    }

    @Test func templatesImportThePackage() {
        #expect(TypstNotes.noteTemplate(title: "T").contains("@local/mtnotes"))
        #expect(TypstNotes.dailyNoteTemplate().contains("@local/mtnotes"))
    }
}

/// The preview node: a document's pages under a second name.
@MainActor
@Suite struct TypstPreviewNodeTests {
    private func tempDoc() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc = dir.appendingPathComponent("doc.typ")
        try "= Title".write(to: doc, atomically: true, encoding: .utf8)
        return doc
    }

    /// The claim the whole design rests on. The pages are not a thing derived
    /// from the document — they *are* the document, under another name — so
    /// every action the file understands reaches a pane showing them, and any
    /// list of things shows one entry rather than two.
    @Test func thePagesClaimTheDocumentAsTheirIdentity() throws {
        let doc = try tempDoc()
        defer { try? FileManager.default.removeItem(at: doc.deletingLastPathComponent()) }
        let node = TypstProvider.previewNode(file: doc)

        #expect(node.type == TypeID("typst.preview"))
        #expect(node.identities == [NodeID(doc.standardizedFileURL.absoluteString)!],
                "the pages answer to no other name: \(node.identities)")
        #expect(node.label == "doc", "shown under the document's own name")
        #expect(!node.hasChildren)
    }

    /// A phony node still has to be a real file underneath, the same check the
    /// sections and tasks make.
    @Test func itResolvesForAFileAndNotForADirectory() throws {
        let doc = try tempDoc()
        let dir = doc.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = TypstProvider()

        #expect(provider.resolve(TypstRef.preview(file: doc.path).uri) != nil)
        #expect(provider.resolve(TypstRef.preview(file: dir.path).uri) == nil)
        #expect(provider.resolve(TypstRef.preview(file: "/nowhere/gone.typ").uri) == nil)
    }

    /// It is one document, not a container of anything.
    @Test func itHasNoChildren() async throws {
        let doc = try tempDoc()
        defer { try? FileManager.default.removeItem(at: doc.deletingLastPathComponent()) }
        let id = try #require(NodeID(TypstRef.preview(file: doc.path).uri))
        let page = await TypstProvider().children(of: id, page: nil)
        #expect(page.items.isEmpty)
    }
}

@Suite struct TypstRefTests {
    @Test func urisRoundTripAndCanonicalize() throws {
        let refs = [
            TypstRef.section(file: "/Users/x/my notes/doc.typ", line: 12),
            TypstRef.task(file: "/Users/x/doc.typ", index: 3),
            TypstRef.agenda(dir: "/Users/x/notes"),
            TypstRef.preview(file: "/Users/x/my notes/doc.typ"),
        ]
        for ref in refs {
            #expect(TypstRef(uri: ref.uri) == ref)
            let canonical = try #require(NodeID(ref.uri)?.uri)
            #expect(NodeID(canonical)?.uri == canonical)      // idempotent
            #expect(TypstRef(uri: canonical) == ref)          // survives canonicalization
        }
    }
}

@Suite struct TypstStructureTests {
    private let doc = """
    = Project
    #task[Top-level thing]

    == Design
    Some prose.
    #task(done: true)[Sketch the API]
    #task(due: "2026-07-20", tags: ("deep", "urgent"))[Write the core]

    == Build
    #task(done: false)[Set up CI]

    = Appendix
    """

    @Test func outlineFindsSectionsAndTasks() {
        let items = TypstStructure.outline(of: doc)
        let sections = items.compactMap { if case .section(let s) = $0 { return s } else { return nil } }
        let tasks = items.compactMap { if case .task(let t) = $0 { return t } else { return nil } }

        #expect(sections.map(\.title) == ["Project", "Design", "Build", "Appendix"])
        #expect(sections.map(\.level) == [1, 2, 2, 1])
        #expect(tasks.count == 4)
        #expect(tasks[0].body == "Top-level thing")
        #expect(tasks[1].done)
        #expect(tasks[2].due == "2026-07-20")
        #expect(tasks[2].tags == ["deep", "urgent"])
        #expect(!tasks[3].done)
    }

    @Test func nestingAssignsChildrenCorrectly() throws {
        let items = TypstStructure.outline(of: doc)

        // Top level: the two level-1 sections; the top task belongs to "Project".
        let top = TypstStructure.directChildren(ofSectionAt: nil, in: items)
        #expect(top.count == 2)

        let projectLine = 1
        let projectChildren = TypstStructure.directChildren(ofSectionAt: projectLine, in: items)
        // task + Design + Build (the deeper tasks belong to those subsections)
        #expect(projectChildren.count == 3)
        guard case .task(let firstChild) = projectChildren[0] else {
            Issue.record("expected the top-level task first"); return
        }
        #expect(firstChild.body == "Top-level thing")

        guard case .section(let design) = projectChildren[1] else {
            Issue.record("expected Design"); return
        }
        let designChildren = TypstStructure.directChildren(ofSectionAt: design.line, in: items)
        #expect(designChildren.count == 2)     // its two tasks
    }

    @Test func togglingFlipsExplicitDone() throws {
        let toggled = try #require(TypstStructure.togglingTask(at: 1, in: doc))
        #expect(toggled.contains("#task(done: false)[Sketch the API]"))
        let back = try #require(TypstStructure.togglingTask(at: 1, in: toggled))
        #expect(back.contains("#task(done: true)[Sketch the API]"))
    }

    @Test func togglingInsertsDoneIntoExistingArgs() throws {
        let toggled = try #require(TypstStructure.togglingTask(at: 2, in: doc))
        #expect(toggled.contains(#"#task(done: true, due: "2026-07-20""#))
    }

    @Test func togglingBareTaskGainsArgs() throws {
        let toggled = try #require(TypstStructure.togglingTask(at: 0, in: doc))
        #expect(toggled.contains("#task(done: true)[Top-level thing]"))
    }

    @Test func agendaScansAndSorts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-agenda-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "#task(due: \"2026-09-01\")[Later]\n#task(done: true)[Finished]"
            .write(to: dir.appendingPathComponent("b.typ"), atomically: true, encoding: .utf8)
        try "#task(due: \"2026-08-01\")[Sooner]\n#task[Undated]"
            .write(to: dir.appendingPathComponent("a.typ"), atomically: true, encoding: .utf8)

        let tasks = TypstStructure.agendaTasks(under: dir)
        #expect(tasks.map { $0.task.body } == ["Sooner", "Later", "Undated", "Finished"])
    }
}

@Suite struct TypstEditTests {
    private func apply(_ edit: TypstEdit.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func wrapSelection() {
        let text = "make this bold"
        let edit = TypstEdit.toggleWrap("*", in: text, selection: NSRange(location: 10, length: 4))
        #expect(apply(edit, to: text) == "make this *bold*")
        #expect(edit.selection == NSRange(location: 11, length: 4))   // inner text stays selected
    }

    @Test func unwrapWhenSelectionIncludesMarkers() {
        let text = "make this *bold*"
        let edit = TypstEdit.toggleWrap("*", in: text, selection: NSRange(location: 10, length: 6))
        #expect(apply(edit, to: text) == "make this bold")
    }

    @Test func unwrapWhenMarkersSitOutsideSelection() {
        let text = "make this *bold*"
        let edit = TypstEdit.toggleWrap("*", in: text, selection: NSRange(location: 11, length: 4))
        #expect(apply(edit, to: text) == "make this bold")
        #expect(edit.selection == NSRange(location: 10, length: 4))
    }

    @Test func emptySelectionInsertsPairWithCaretInside() {
        let edit = TypstEdit.toggleWrap("_", in: "ab", selection: NSRange(location: 1, length: 0))
        #expect(apply(edit, to: "ab") == "a__b")
        #expect(edit.selection == NSRange(location: 2, length: 0))
    }

    @Test func insertTaskWrapsSelection() {
        let text = "Buy milk"
        let edit = TypstEdit.insertTask(in: text, selection: NSRange(location: 0, length: 8))
        #expect(apply(edit, to: text) == "#task[Buy milk]")
    }

    @Test func insertTaskAtCaret() {
        let edit = TypstEdit.insertTask(in: "", selection: NSRange(location: 0, length: 0))
        #expect(apply(edit, to: "") == "#task[]")
        #expect(edit.selection == NSRange(location: 6, length: 0))    // caret in brackets
    }
}

@Suite struct TypstLinksTests {
    @Test func parsesIncludesAndImportsSkippingPackages() {
        let source = """
        #import "@local/mtnotes:0.1.0": *
        #import "helpers.typ": thing
        #include "chapters/one.typ"
        """
        #expect(TypstStructure.links(of: source) == ["helpers.typ", "chapters/one.typ"])
    }

    @Test func backlinksResolveRelativePaths() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("target.typ")
        try "= Target".write(to: target, atomically: true, encoding: .utf8)
        try "#include \"../target.typ\"".write(
            to: dir.appendingPathComponent("sub/linker.typ"), atomically: true, encoding: .utf8)
        try "= Unrelated".write(
            to: dir.appendingPathComponent("other.typ"), atomically: true, encoding: .utf8)

        let backlinks = TypstStructure.backlinks(to: target, under: dir)
        #expect(backlinks.map(\.lastPathComponent) == ["linker.typ"])
    }
}

/// Parser-backed tokens (the real typst parser via FFI). Hermetic.
@Suite struct TypstEngineTokenTests {
    private func kinds(_ source: String) -> [String] {
        (TypstEngine.tokens(in: source) ?? []).map(\.k)
    }

    @Test func proseQuotesAreNotStrings_butImportPathsAre() {
        // The regex tokenizer could never distinguish these; the parser can.
        #expect(!kinds("He said \"hello\" to me.").contains("string"))
        #expect(kinds("#import \"@local/mtnotes:0.1.0\": *").contains("string"))
    }

    @Test func headingsCarryLevels() throws {
        let tokens = try #require(TypstEngine.tokens(in: "== Sub\n"))
        let heading = try #require(tokens.first { $0.k == "heading" })
        #expect(heading.n == 2)
    }

    @Test func alignEmitsBodyAndConcealableHead() throws {
        let source = "#align(center)[Hi there]"
        let tokens = try #require(TypstEngine.tokens(in: source))
        let aligned = try #require(tokens.first { $0.k == "aligned" })
        #expect(aligned.a == "center")
        #expect((source as NSString).substring(with: aligned.range) == "Hi there")
        // # + head + [ + ] — all punct, so the editor can conceal the machinery.
        let puncts = tokens.filter { $0.k == "punct" }
        #expect(puncts.count == 4)
        #expect((source as NSString).substring(with: puncts[0].range) == "#")
        #expect((source as NSString).substring(with: puncts[1].range) == "align(center)")
        #expect(!tokens.contains { $0.k == "function" })
    }

    @Test func strikeAndUnderlineDecorateTheirBodies() throws {
        let source = "#strike[gone] and #underline[kept]"
        let tokens = try #require(TypstEngine.tokens(in: source))
        let struck = try #require(tokens.first { $0.k == "struck" })
        #expect((source as NSString).substring(with: struck.range) == "gone")
        let underlined = try #require(tokens.first { $0.k == "underlined" })
        #expect((source as NSString).substring(with: underlined.range) == "kept")
        // Heads are concealable punct, not function runs.
        #expect(!tokens.contains { $0.k == "function" })
    }

    @Test func decoratedBodiesStillStyleNestedMarkup() throws {
        let tokens = try #require(TypstEngine.tokens(in: "#strike[*bold* text]"))
        #expect(tokens.contains { $0.k == "struck" })
        #expect(tokens.contains { $0.k == "strong" })
    }

    @Test func listItemsEmitItemAndMarker() throws {
        let source = "- first\n+ second\n"
        let tokens = try #require(TypstEngine.tokens(in: source))
        #expect(tokens.filter { $0.k == "item" }.count == 2)
        let markers = tokens.filter { $0.k == "marker" }
        #expect(markers.count == 2)
        #expect((source as NSString).substring(with: markers[0].range) == "-")
        #expect((source as NSString).substring(with: markers[1].range) == "+")
    }

    @Test func termItemsBoldTheTerm() throws {
        let source = "/ Forest: a set of rooted trees\n"
        let tokens = try #require(TypstEngine.tokens(in: source))
        let term = try #require(tokens.first { $0.k == "term" })
        #expect((source as NSString).substring(with: term.range) == "Forest")
        #expect(tokens.contains { $0.k == "item" })
    }

    @Test func mathEmitsConcealableDollars() throws {
        let source = "Euler: $e^(i pi) + 1 = 0$."
        let tokens = try #require(TypstEngine.tokens(in: source))
        let math = try #require(tokens.first { $0.k == "math" })
        #expect((source as NSString).substring(with: math.range) == "$e^(i pi) + 1 = 0$")
        let dollars = tokens.filter {
            $0.k == "punct" && (source as NSString).substring(with: $0.range) == "$"
        }
        #expect(dollars.count == 2)
    }

    @Test func blockEquationsAreFlagged() throws {
        let inline = try #require(TypstEngine.tokens(in: "so $x^2$ holds"))
        #expect(try #require(inline.first { $0.k == "math" }).a == nil)
        let block = try #require(TypstEngine.tokens(in: "$ x^2 $"))
        #expect(try #require(block.first { $0.k == "math" }).a == "block")
    }

    @Test func codeBlocksEmitEmbedRegionsForTheHighlighter() throws {
        let source = "```rust\nlet x = 1; // one\n```"
        let tokens = try #require(TypstEngine.tokens(in: source))
        // Foreign code is handed to the editor's highlighting library as one
        // region carrying its language — the FFI does no foreign lexing itself.
        let embed = try #require(tokens.first { $0.k == "embed" })
        #expect(embed.a == "rust")
        #expect((source as NSString).substring(with: embed.range) == "\nlet x = 1; // one\n")
        // Fences and the language tag are concealable punct.
        let puncts = tokens.filter { $0.k == "punct" }
            .map { (source as NSString).substring(with: $0.range) }
        #expect(puncts.contains("rust"))
        #expect(puncts.filter { $0 == "```" }.count == 2)
    }

    @Test func typstCodeBlocksUseTheRealParserNotTheHighlighter() throws {
        let tokens = try #require(TypstEngine.tokens(in: "```typ\n= Heading\n*b*\n```"))
        #expect(tokens.contains { $0.k == "heading" && $0.n == 1 })
        #expect(tokens.contains { $0.k == "strong" })
        #expect(!tokens.contains { $0.k == "embed" })
    }

    @Test func inlineRawWithoutLanguageHasNoEmbedRegion() throws {
        let tokens = try #require(TypstEngine.tokens(in: "some `code` here"))
        #expect(tokens.contains { $0.k == "raw" })
        #expect(!tokens.contains { $0.k == "embed" })
    }

    @Test func autolinksAreLinkTokens() throws {
        let source = "See https://typst.app for docs."
        let tokens = try #require(TypstEngine.tokens(in: source))
        let link = try #require(tokens.first { $0.k == "link" })
        #expect((source as NSString).substring(with: link.range) == "https://typst.app")
    }

    @Test func rangesAreUTF16() throws {
        // "😀" is 2 UTF-16 units; byte offsets would misplace the heading.
        let source = "😀\n= Title"
        let tokens = try #require(TypstEngine.tokens(in: source))
        let heading = try #require(tokens.first { $0.k == "heading" })
        #expect(heading.range.location == 3)   // 2 (emoji) + 1 (newline)
        #expect((source as NSString).substring(with: heading.range) == "= Title")
    }

    @Test func markupAndCodeKindsAppear() {
        let source = """
        = H
        *bold* _emph_ `raw` $x$ <lab> @lab
        #task(done: true)[Body prose]
        // comment
        """
        let found = Set(kinds(source))
        for expected in ["heading", "strong", "emphasis", "raw", "math",
                         "tag", "property", "function", "punct", "comment"] {
            #expect(found.contains(expected), "missing \(expected)")
        }
    }
}

/// The in-process engine (Vendor/typst-ffi). NOT gated on the CLI — the library is
/// linked into the test target, making these hermetic.
@Suite struct TypstEngineTests {
    private func tempRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func compilesToPDF() throws {
        let output = TypstEngine.compile(source: "= Hello\nFrom the engine.",
                                         root: try tempRoot())
        let result = try #require(output, "engine must not internal-error")
        #expect(result.pdf != nil)
        #expect(result.diagnostics.isEmpty)
    }

    @Test func reportsLocatedErrors() throws {
        let output = TypstEngine.compile(source: "= Bad\n#nonexistent()",
                                         root: try tempRoot())
        let result = try #require(output)
        #expect(result.pdf == nil)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.line == 2 })
    }

    @Test func resolvesRelativeFilesAgainstRoot() throws {
        let root = try tempRoot()
        try "world".write(to: root.appendingPathComponent("data.txt"),
                          atomically: true, encoding: .utf8)
        let output = TypstEngine.compile(source: "#read(\"data.txt\")", root: root)
        let result = try #require(output)
        #expect(result.pdf != nil)
    }

    @Test func rendersMathToPNGWithBaseline() throws {
        let render = try #require(
            TypstEngine.renderMath(equation: "$x^2 + y_0$", fontSize: 15,
                                   dark: false, scale: 2),
            "a valid equation must render")
        #expect(render.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))   // PNG magic
        // Auto-sized page: hugs an inline equation, nowhere near paper-sized.
        #expect(render.w > 0 && render.w < 200)
        #expect(render.h > 0 && render.h < 60)
        // The baseline lies strictly inside the image: ascenders above it,
        // the y₀ subscript's descender below it.
        #expect(render.b > 0 && render.b < render.h)
    }

    /// Regression: the baseline comes from the strut on the paragraph's main
    /// line, NOT the image bottom. A subscript deepens the image below the
    /// baseline but must not move the baseline itself — when it did, subscripted
    /// chemistry formulas rode visibly high in the editor.
    @Test func subscriptsDeepenTheImageNotTheBaseline() throws {
        let plain = try #require(TypstEngine.renderMath(equation: "$x$",
                                                        fontSize: 15, dark: false, scale: 2))
        let sub = try #require(TypstEngine.renderMath(equation: "$\"HNO\"_3$",
                                                      fontSize: 15, dark: false, scale: 2))
        // Same main baseline; the subscript hangs below it into the page's
        // vertical margin (typst's default bottom edge IS the baseline, so the
        // page doesn't grow — the margin is what keeps the descender unclipped).
        #expect(abs(plain.b - sub.b) < 0.5)
        #expect(abs(sub.h - sub.b - 15 * 0.35) < 0.5)
    }

    /// Regression: block equations render standalone — no baseline strut. The
    /// strut formed its own phantom line above the display equation, bloating
    /// the image with dead space (huge gap above, equation spilling below its
    /// reserved line in the editor).
    @Test func blockEquationsRenderTightWithoutStrutLine() throws {
        let block = try #require(TypstEngine.renderMath(equation: "$ x + y $",
                                                        fontSize: 15, dark: false,
                                                        scale: 2, block: true))
        // One display line + margins — nowhere near two lines plus block gaps.
        #expect(block.h < 15 * 2)
        let inline = try #require(TypstEngine.renderMath(equation: "$x + y$",
                                                         fontSize: 15, dark: false,
                                                         scale: 2))
        #expect(abs(block.h - inline.h) < 15)
    }

    @Test func mathRenderReturnsNilForInvalidEquations() {
        #expect(TypstEngine.renderMath(equation: "$#nonexistent()$",
                                       fontSize: 15, dark: false, scale: 2) == nil)
    }

    @Test func resolvesLocalPackages() throws {
        try TypstNotes.installPackage()
        let source = """
        \(TypstNotes.packageImport)
        #task[Engine-compiled task]
        """
        let output = TypstEngine.compile(source: source, root: try tempRoot())
        let result = try #require(output)
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(result.pdf != nil)
    }
}

/// The LSP client's pure parts — position mapping, snippet cleanup, response
/// decoding — hermetic, no server needed.
@Suite struct TinymistProtocolTests {
    @Test func positionMappingRoundTrips() {
        let text = "abc\ndef\ng" as NSString
        let position = TinymistClient.position(ofOffset: 6, in: text)
        #expect(position == TinymistClient.Position(line: 1, character: 2))
        #expect(TinymistClient.offset(of: position, in: text) == 6)
        #expect(TinymistClient.position(ofOffset: 0, in: text)
                == TinymistClient.Position(line: 0, character: 0))
        #expect(TinymistClient.offset(of: .init(line: 9, character: 9), in: text)
                == text.length)   // clamped, never out of bounds
    }

    @Test func snippetSyntaxStripsToPlainText() {
        #expect(TinymistClient.strippingSnippetSyntax("image(${1:path})") == "image(path)")
        #expect(TinymistClient.strippingSnippetSyntax("strong[$1]$0") == "strong[]")
        #expect(TinymistClient.strippingSnippetSyntax("plain") == "plain")
    }

    @Test func completionResponsesDecodeWithEditRanges() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"isIncomplete":false,"items":[
          {"label":"image","kind":3,"detail":"insert an image",
           "textEdit":{"range":{"start":{"line":0,"character":1},
                                "end":{"line":0,"character":3}},
                       "newText":"image(${1:path})"}},
          {"label":"emph","kind":3,"insertText":"emph[$1]"}]}}
        """
        let completions = TinymistClient.parseCompletions(
            from: Data(json.utf8), in: "#im" as NSString)
        #expect(completions.count == 2)
        let image = try #require(completions.first)
        #expect(image.label == "image")
        #expect(image.insertText == "image(path)")
        #expect(image.replaceRange == NSRange(location: 1, length: 2))
        #expect(completions[1].insertText == "emph[]")
        #expect(completions[1].replaceRange == nil)
    }

    @Test func malformedResponsesYieldNothing() {
        #expect(TinymistClient.parseCompletions(from: Data("junk".utf8),
                                                in: "" as NSString).isEmpty)
        #expect(TinymistClient.parseCompletions(from: Data(#"{"id":1,"result":null}"#.utf8),
                                                in: "" as NSString).isEmpty)
    }
}

/// Live tests against a real tinymist; skipped on machines without it.
@Suite(.enabled(if: TinymistClient.isAvailable))
struct TinymistLiveTests {
    @Test func serverCompletesTypstCalls() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tinymist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.typ")
        let text = "#im"
        try text.write(to: file, atomically: true, encoding: .utf8)

        let completions = await TinymistClient.shared
            .completions(fileURL: file, text: text, offset: text.count)
        #expect(completions.contains { $0.label.hasPrefix("im") },
                "expected image/import among \(completions.prefix(5).map(\.label))")
    }
}

/// The engine's canvas-facing facade (compile-by-document-URL and exports).
/// Hermetic: everything runs through the in-process engine — there is no CLI.
@Suite struct TypstExportTests {
    /// The document's directory must exist — it becomes the compile root.
    private func tempDocURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("doc.typ")
    }

    @Test func compileFacadeResolvesRootFromDocumentURL() async throws {
        let doc = try tempDocURL()
        try "world".write(to: doc.deletingLastPathComponent()
            .appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let output = await TypstEngine.compile(source: "#read(\"data.txt\")",
                                               documentURL: doc, mountedRoots: [])
        #expect(output.pdf != nil)
        #expect(output.diagnostics.isEmpty)
    }

    /// An export's outcome is kept, and shown on the canvas of the document
    /// that produced it. It used to be discarded at the call site, so a
    /// document that could not compile and one that wrote a file looked
    /// identical: nothing on screen either way.
    @MainActor
    @Test func anExportReportsItselfToItsOwnDocument() {
        let state = TypstUIState.shared
        defer { state.clearExportReport() }
        let document = URL(fileURLWithPath: "/tmp/note.typ")
        let other = URL(fileURLWithPath: "/tmp/elsewhere.typ")

        state.exportReport = TypstUIState.ExportReport(
            document: document, destination: URL(fileURLWithPath: "/tmp/note.pdf"),
            diagnostics: [TypstDiagnostic(severity: .error, line: 3, column: 1,
                                          message: "unknown variable")])
        #expect(state.exportReport(for: document)?.failed == true)
        #expect(state.exportReport(for: other) == nil, "another document's canvas")
        #expect(state.exportReport(for: nil) == nil)

        // Nothing to say is nothing to show — a clean export is the file
        // appearing, not a bar reporting that it did.
        state.exportReport = TypstUIState.ExportReport(
            document: document, destination: URL(fileURLWithPath: "/tmp/note.pdf"),
            diagnostics: [])
        #expect(state.exportReport(for: document) == nil)
    }

    /// A document may sit below the folder it belongs to, and reach above
    /// itself for what it imports. The scope that makes that legal is the set
    /// of mounted roots — and the export path used to take the default of
    /// none, so the project root became the document's own directory and
    /// anything above it "would escape project root". The preview passed the
    /// roots and worked; export did not and did not.
    @Test func exportUsesTheMountedRootAsTheProjectScope() async throws {
        let workspace = try tempDocURL().deletingLastPathComponent()
        let sub = workspace.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "Shared prose.".write(to: workspace.appendingPathComponent("notes.typ"),
                                  atomically: true, encoding: .utf8)
        let doc = sub.appendingPathComponent("doc.typ")
        let source = "#include \"../notes.typ\"\n= Title"
        try source.write(to: doc, atomically: true, encoding: .utf8)
        let destination = sub.appendingPathComponent("out.pdf")

        // Without the workspace, the root is `sub` and the include escapes it.
        let escaped = await TypstEngine.export(source: source, documentURL: doc,
                                               format: .pdf, to: destination,
                                               mountedRoots: [])
        #expect(escaped.contains { $0.severity == .error },
                "a parent import outside every root should be refused")

        // With it, the root is the workspace and the include is inside.
        let allowed = await TypstEngine.export(source: source, documentURL: doc,
                                               format: .pdf, to: destination,
                                               mountedRoots: [workspace])
        #expect(allowed.filter { $0.severity == .error }.isEmpty,
                "refused inside its own workspace: \(allowed.map(\.message))")
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func exportsPDF() async throws {
        let doc = try tempDocURL()
        let dest = doc.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let diagnostics = await TypstEngine.export(
            source: "= Hello", documentURL: doc, format: .pdf, to: dest,
            mountedRoots: [])
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty)
        let data = try Data(contentsOf: dest)
        #expect(data.starts(with: Array("%PDF".utf8)))
    }

    @Test func exportsWholeDocumentAsOneSVG() async throws {
        let doc = try tempDocURL()
        let dest = doc.deletingLastPathComponent().appendingPathComponent("out.svg")
        let diagnostics = await TypstEngine.export(
            source: "= Page One\n#pagebreak()\n= Page Two",
            documentURL: doc, format: .svg, to: dest, mountedRoots: [])
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty)
        let svg = try String(contentsOf: dest, encoding: .utf8)
        #expect(svg.contains("<svg"))   // both pages, stacked in one file
    }

    @Test func exportsPNGPerPageWhenMultiPage() async throws {
        let doc = try tempDocURL()
        let dir = doc.deletingLastPathComponent()
        let dest = dir.appendingPathComponent("out.png")
        let diagnostics = await TypstEngine.export(
            source: "one\n#pagebreak()\ntwo", documentURL: doc, format: .png, to: dest,
            mountedRoots: [])
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty)
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        for page in 1...2 {
            let url = dir.appendingPathComponent("out-\(page).png")
            let data = try Data(contentsOf: url)
            #expect(data.starts(with: magic))
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path),
                "multi-page PNG never writes the un-numbered name")
    }

    @Test func singlePagePNGUsesThePlainName() async throws {
        let doc = try tempDocURL()
        let dest = doc.deletingLastPathComponent().appendingPathComponent("one.png")
        let diagnostics = await TypstEngine.export(
            source: "just one page", documentURL: doc, format: .png, to: dest,
            mountedRoots: [])
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func exportSurfacesCompileErrorsAndWritesNothing() async throws {
        let doc = try tempDocURL()
        let dest = doc.deletingLastPathComponent().appendingPathComponent("bad.svg")
        let diagnostics = await TypstEngine.export(
            source: "#nonexistent()", documentURL: doc, format: .svg, to: dest,
            mountedRoots: [])
        #expect(diagnostics.contains { $0.severity == .error && $0.line == 1 })
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    /// The whole notes convention hinges on this: the bundled package installs into
    /// typst's real data directory and a `#task` document compiles against it.
    @Test func bundledPackageCompiles() async throws {
        try TypstNotes.installPackage()
        let source = """
        \(TypstNotes.packageImport)

        = Notes
        #task[Buy milk]
        #task(done: true, due: "2026-07-20", tags: ("errands",))[Post letter]
        """
        let output = await TypstEngine.compile(source: source,
                                               documentURL: try tempDocURL(),
                                               mountedRoots: [])
        #expect(output.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(output.pdf != nil)
    }
}

/// The inspector's live stats: the buffer channel that carries an open
/// document's text to views outside the canvas, and the counting itself.
///
/// The word count used to read the *file*, in a `.task(id: nodeID)` — so it
/// never moved while you typed, and even after a save it lagged by an
/// autosave. Both halves of that are covered here; the SwiftUI wiring that
/// joins them is not.
@MainActor
@Suite struct TypstLiveStatsTests {
    @Test func wordCountCountsTheSourceAsWritten() {
        #expect(TypstStructure.wordCount(of: "") == 0)
        #expect(TypstStructure.wordCount(of: "   \n\t ") == 0)
        #expect(TypstStructure.wordCount(of: "one") == 1)
        #expect(TypstStructure.wordCount(of: "one two  three") == 3)
        // Newlines separate words the same as spaces; markup counts as written.
        #expect(TypstStructure.wordCount(of: "= Heading\n\nbody text") == 4)
        #expect(TypstStructure.wordCount(of: "*bold* and _italic_") == 3)
    }

    /// A document outlives any one canvas looking at it.
    ///
    /// The source and the pages are two panes on one document, so closing the
    /// editor must not cancel the compile and take the pages down with it —
    /// which is what dropping the document on any canvas disappearing did.
    @Test func aDocumentSurvivesUntilTheLastCanvasCloses() {
        let state = TypstUIState.shared
        let url = URL(fileURLWithPath: "/tmp/maximaltree-two-readers.typ")
        defer { state.releaseDocument(for: url) }

        state.retainDocument(for: url)          // the editor
        state.retainDocument(for: url)          // the pages beside it
        state.setBuffer("body", for: url)

        state.releaseDocument(for: url)
        #expect(state.buffer(for: url) == "body",
                "closing one pane took the document from the other")
        state.releaseDocument(for: url)
        #expect(state.buffer(for: url) == nil, "nobody is looking and it stayed")
    }

    @Test func bufferChannelIsPerDocumentAndClears() throws {
        let state = TypstUIState.shared
        let a = URL(fileURLWithPath: "/tmp/maximaltree-a.typ")
        let b = URL(fileURLWithPath: "/tmp/maximaltree-b.typ")
        defer { state.releaseDocument(for: a); state.releaseDocument(for: b) }

        #expect(state.buffer(for: a) == nil, "no canvas open means no buffer")
        state.retainDocument(for: a)
        state.retainDocument(for: b)
        state.setBuffer("hello world", for: a)
        state.setBuffer("just b", for: b)
        #expect(state.buffer(for: a) == "hello world")
        #expect(state.buffer(for: b) == "just b")

        // The count the inspector shows comes from the buffer, not the file —
        // which need not exist at all.
        let live = try #require(state.buffer(for: a))
        #expect(TypstStructure.wordCount(of: live) == 2)

        // Closing one document leaves the other's buffer alone.
        state.releaseDocument(for: a)
        #expect(state.buffer(for: a) == nil)
        #expect(state.buffer(for: b) == "just b")
        #expect(state.buffer(for: nil) == nil)
    }
}

/// Packages the document imports have to arrive on their own — a user writing
/// `#import "@preview/…"` shouldn't have to go install anything by hand, and
/// the old behaviour (resolve locally or fail) surfaced as a baffling
/// "file typst.toml is missing".
///
/// These talk to Typst Universe, so they skip themselves when the network
/// isn't reachable rather than failing a local test run.
@Suite struct TypstPackageDownloadTests {
    /// Small, stable, no assets — enough to prove the path end to end.
    private let package = "@preview/oxifmt:0.2.1"

    private func temporaryPackagesDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-packages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var registryIsReachable: Bool {
        TypstPackages.download(URL(string: "https://packages.typst.org/preview/index.json")!,
                               to: FileManager.default.temporaryDirectory
                                   .appendingPathComponent("mt-index-\(UUID().uuidString)")) == 0
    }

    @Test func animportedPackageIsDownloadedOnFirstCompile() throws {
        TypstPackages.install()
        guard registryIsReachable else { return }

        let packages = try temporaryPackagesDir()
        defer { try? FileManager.default.removeItem(at: packages) }

        let output = TypstEngine.compile(
            source: """
                    #import "\(package)": strfmt
                    #strfmt("{}", 1)
                    """,
            root: FileManager.default.temporaryDirectory,
            packagesNamespaceDir: packages)

        let errors = (output?.diagnostics ?? []).filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors.map { $0.message })")
        #expect(output?.pdf != nil)
        // And it landed where the engine looks, so the next compile is offline.
        let installed = packages.appendingPathComponent("preview/oxifmt/0.2.1/typst.toml")
        #expect(FileManager.default.fileExists(atPath: installed.path))
    }

    /// A package that doesn't exist must say so, not blame a missing toml.
    @Test func amissingPackageReportsItselfAsAPackageError() throws {
        TypstPackages.install()
        guard registryIsReachable else { return }

        let packages = try temporaryPackagesDir()
        defer { try? FileManager.default.removeItem(at: packages) }

        let output = TypstEngine.compile(
            source: "#import \"@preview/mt-no-such-package:9.9.9\": *",
            root: FileManager.default.temporaryDirectory,
            packagesNamespaceDir: packages)

        let messages = (output?.diagnostics ?? []).map(\.message).joined(separator: " ")
        #expect(messages.contains("package"), "\(messages)")
        #expect(!messages.contains("typst.toml"), "\(messages)")
    }
}

/// Which directory a document counts as living in.
///
/// Typst won't read anything outside the compilation root, so this decides
/// which imports are legal. Compiling every file against its own directory —
/// where this started — rejects `#import "../shared.typ"` with "escapes
/// project root", which is an ordinary way to keep notes: shared definitions
/// above, documents in folders below.
@Suite struct TypstProjectRootTests {
    private func makeTree() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "#let shared = [from the parent]\n"
            .write(to: base.appendingPathComponent("shared.typ"),
                   atomically: true, encoding: .utf8)
        try "#let sibling = [from next door]\n"
            .write(to: base.appendingPathComponent("notes/sibling.typ"),
                   atomically: true, encoding: .utf8)
        return base
    }

    private func errors(compiling source: String, at document: URL,
                        mountedRoots: [URL]) async -> [String] {
        let root = TypstProject.root(for: document, mountedRoots: mountedRoots)
        let output = TypstEngine.compile(
            source: source, root: root,
            mainPath: TypstProject.mainPath(of: document, in: root),
            packagesNamespaceDir: TypstEngine.packagesRoot())
        return (output?.diagnostics ?? [])
            .filter { $0.severity == .error }.map(\.message)
    }

    @Test func aDocumentCanImportFromItsParentDirectory() async throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = base.appendingPathComponent("notes/today.typ")

        let errors = await errors(
            compiling: "#import \"../shared.typ\": shared\n#shared",
            at: document, mountedRoots: [base])
        #expect(errors.isEmpty, "\(errors)")
    }

    /// The other half of the fix. Widening the root alone would have broken
    /// this: relative imports resolve against the importing file's directory,
    /// so a document compiled as `<root>/main.typ` looks for its siblings at
    /// the root instead of beside itself.
    @Test func aDocumentCanStillImportItsSiblings() async throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = base.appendingPathComponent("notes/today.typ")

        let errors = await errors(
            compiling: "#import \"sibling.typ\": sibling\n#sibling",
            at: document, mountedRoots: [base])
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test func aTypstTomlMarksTheProjectRoot() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "[package]\n".write(to: base.appendingPathComponent("notes/typst.toml"),
                                atomically: true, encoding: .utf8)
        let document = base.appendingPathComponent("notes/today.typ")

        // The marker wins over the mounted folder above it: it's an explicit
        // statement about where this project begins.
        #expect(TypstProject.root(for: document, mountedRoots: [base]).standardizedFileURL
                == base.appendingPathComponent("notes").standardizedFileURL)
    }

    @Test func theMountedFolderIsTheRootWhenThereIsNoMarker() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = base.appendingPathComponent("notes/today.typ")

        #expect(TypstProject.root(for: document, mountedRoots: [base]).standardizedFileURL
                == base.standardizedFileURL)
    }

    /// Nothing mounted, no marker: the old behaviour, and the document's own
    /// directory is as much as we can justify exposing.
    @Test func anUnmountedDocumentKeepsItsOwnDirectory() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = base.appendingPathComponent("notes/today.typ")

        #expect(TypstProject.root(for: document).standardizedFileURL
                == base.appendingPathComponent("notes").standardizedFileURL)
    }

    @Test func theMainPathLocatesTheDocumentInsideTheRoot() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = base.appendingPathComponent("notes/today.typ")

        #expect(TypstProject.mainPath(of: document, in: base) == "/notes/today.typ")
        // A document outside the root has no place in it; the placeholder is
        // what unsaved and synthetic sources compile as.
        #expect(TypstProject.mainPath(of: URL(fileURLWithPath: "/elsewhere/x.typ"),
                                      in: base) == "/main.typ")
    }
}

/// Dark mode for the typeset preview. The pixels are Core Image's business;
/// what's worth pinning is that the view is actually *set up* to filter (the
/// opt-in below is silently ignorable), that light mode is left as it was, and
/// that the gutter colour survives its own inversion.
@MainActor
@Suite struct PDFAppearanceTests {
    @Test func darkModeFiltersTheView() {
        let view = PDFView()
        PDFAppearance.apply(dark: true, to: view, defaultBackground: view.backgroundColor)

        #expect(view.layerUsesCoreImageFilters,
                "without the opt-in macOS accepts the filters and ignores them")
        let names = (view.layer?.filters as? [CIFilter])?.map(\.name)
        #expect(names == ["CIColorInvert", "CIHueAdjust"],
                "order matters: invert, then put the hues back")
    }

    /// What the pairing is *for*. Inverting alone flips every hue halfway
    /// round the wheel — blue links come out orange — so the chain has to
    /// darken the page while leaving colours recognisably themselves.
    @Test func theChainDarkensThePageAndKeepsHues() {
        func filtered(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let rgb = color.usingColorSpace(.sRGB)!
            var image = CIImage(color: CIColor(red: rgb.redComponent,
                                               green: rgb.greenComponent,
                                               blue: rgb.blueComponent))
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            for filter in PDFAppearance.filters() {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage!
            }
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
                .render(image, toBitmap: &pixel, rowBytes: 4,
                        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
        }

        // The page turns dark and its text turns light.
        let paper = filtered(.white)
        #expect(paper.r < 0.05 && paper.g < 0.05 && paper.b < 0.05, "\(paper)")
        let ink = filtered(.black)
        #expect(ink.r > 0.95 && ink.g > 0.95 && ink.b > 0.95, "\(ink)")

        // A blue stays blue and a red stays red — blue is still the largest
        // channel, red still is. Plain inversion would swap them over.
        let blue = filtered(NSColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        #expect(blue.b > blue.g && blue.g > blue.r, "blue came out \(blue)")
        let red = filtered(NSColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        #expect(red.r > red.g && red.r > red.b, "red came out \(red)")
    }

    @Test func lightModeLeavesThePreviewAlone() {
        let view = PDFView()
        let original = try! #require(view.backgroundColor)
        PDFAppearance.apply(dark: true, to: view, defaultBackground: original)
        PDFAppearance.apply(dark: false, to: view, defaultBackground: original)

        #expect(view.layer?.filters?.isEmpty == true)
        #expect(view.backgroundColor == original)
    }

    /// Switching appearance with the same document on screen has to take
    /// effect — the update path returns early when the document is unchanged,
    /// which is exactly the case a theme switch hits.
    @Test func theFilterClearsWhenLeavingDarkMode() {
        let view = PDFView()
        PDFAppearance.apply(dark: true, to: view, defaultBackground: view.backgroundColor)
        #expect(view.layer?.filters?.isEmpty == false)

        PDFAppearance.apply(dark: false, to: view, defaultBackground: view.backgroundColor)
        #expect(view.layer?.filters?.isEmpty == true)
    }

    /// The gutter is inside the filtered view, so it's assigned pre-treated:
    /// what the reader sees is the chain applied to what we set. The gutter is
    /// neutral precisely so this round trip is exact rather than approximate.
    @Test func theGutterIsSetToComeOutAsTheIntendedColour() throws {
        let view = PDFView()
        PDFAppearance.apply(dark: true, to: view, defaultBackground: view.backgroundColor)

        let assigned = try #require(view.backgroundColor)
        let onScreen = try #require(PDFAppearance.hueRotated(PDFAppearance.inverted(assigned))
            .usingColorSpace(.sRGB))
        let intended = try #require(PDFAppearance.darkGutter.usingColorSpace(.sRGB))
        #expect(abs(onScreen.redComponent - intended.redComponent) < 0.005)
        #expect(abs(onScreen.greenComponent - intended.greenComponent) < 0.005)
        #expect(abs(onScreen.blueComponent - intended.blueComponent) < 0.005)
    }
}

/// What is left of the modes: how a document's own text is set.
@MainActor
@Suite struct TypstSourceStyleTests {
    private let url = URL(fileURLWithPath: "/tmp/maximaltree-style.typ")
    private var legacyKey: String { "typst.mode.\(url.absoluteString)" }
    private var key: String { "typst.sourceStyle.\(url.absoluteString)" }

    private func withCleanDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let savedLegacy = defaults.string(forKey: legacyKey)
        let saved = defaults.string(forKey: key)
        defaults.removeObject(forKey: legacyKey)
        defaults.removeObject(forKey: key)
        body()
        if let savedLegacy { defaults.set(savedLegacy, forKey: legacyKey) }
        else { defaults.removeObject(forKey: legacyKey) }
        if let saved { defaults.set(saved, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    @Test func aDocumentNobodyHasSetIsSource() {
        withCleanDefaults {
            #expect(TypstSourceStyle.stored(forFile: url) == .source)
        }
    }

    /// A document that still remembers a mode keeps how it was being worked
    /// on. Writing was prose; typesetting and reading were the source.
    @Test func aRememberedModeBecomesTheStyleItMeant() {
        withCleanDefaults {
            UserDefaults.standard.set("write", forKey: legacyKey)
            #expect(TypstSourceStyle.stored(forFile: url) == .prose)
            // Written back under the new name, so the old one is read once.
            #expect(UserDefaults.standard.string(forKey: key) == "prose")
        }
        withCleanDefaults {
            UserDefaults.standard.set("typeset", forKey: legacyKey)
            #expect(TypstSourceStyle.stored(forFile: url) == .source)
        }
        withCleanDefaults {
            UserDefaults.standard.set("read", forKey: legacyKey)
            #expect(TypstSourceStyle.stored(forFile: url) == .source)
        }
    }

    /// A choice made since beats a mode remembered from before.
    @Test func aStyleAlreadyChosenWinsOverTheOldMode() {
        withCleanDefaults {
            UserDefaults.standard.set("write", forKey: legacyKey)
            TypstSourceStyle.source.store(forFile: url)
            #expect(TypstSourceStyle.stored(forFile: url) == .source)
        }
    }

    /// Prose saves itself; source waits for ⌘S. The one thing the modes
    /// carried that was never about layout.
    @Test func proseSavesItselfAndSourceDoesNot() {
        #expect(TypstSourceStyle.prose.autosaves)
        #expect(!TypstSourceStyle.source.autosaves)
    }
}

/// What a host with no window gets from typst: documents' structure, the
/// agenda, and notes made and opened. The Mac adds how a document is shown.
@MainActor
@Suite struct TypstSplitTests {
    @Test func theCoreHalfIsStructureAndNotes() {
        let core = CoreContributions()
        TypstCore.register(with: core)
        #expect(core.providers.contains { $0.schemes.contains("typst") })
        #expect(core.childContributions.count == 1)
        #expect(Set(core.actions.map(\.id))
                == ["typst.notesFolder", "typst.preview", "typst.newNote", "typst.dailyNote"])
    }

    /// A shell showing the agenda hears when its folder changes — told, since
    /// the core has no idea what is on screen.
    @Test func anAgendaFolderThatChangesSaysSo() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenda-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let told = Told()
        let provider = TypstProvider(onAgendaChanged: { told.mark() })
        let root = try #require(NodeID(TypstRef.agenda(dir: dir.resolvingSymlinksInPath().path).uri))
        let stream = try #require(provider.changes(under: root))
        let consumer = Task { for await _ in stream {} }
        defer { consumer.cancel() }

        // Written until heard: FSEvents takes a moment to start listening.
        await waitUntil("the agenda's change was never passed on") {
            try? "- [ ] a task".write(to: dir.appendingPathComponent("note.typ"),
                                      atomically: true, encoding: .utf8)
            return told.marked
        }
    }

    private final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var marked: Bool { lock.withLock { value } }
        func mark() { lock.withLock { value = true } }
    }
}
