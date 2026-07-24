import Testing
import Foundation
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
            #expect(HighlightrTokenizer.isSupported(id), "unsupported language id: \(id)")
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

/// The stock tokenizer driving the real highlight.js engine.
@MainActor
@Suite struct HighlightrTokenizerTests {
    @Test func fileURLInitFollowsLanguageDetection() {
        #expect(HighlightrTokenizer(fileURL: URL(fileURLWithPath: "/a/b.swift")) != nil)
        #expect(HighlightrTokenizer(fileURL: URL(fileURLWithPath: "/p/Dockerfile")) != nil)
        #expect(HighlightrTokenizer(fileURL: URL(fileURLWithPath: "/a/b.xyzunknown")) == nil)
    }

    @Test func highlightsSwiftSourceWithPairedColors() {
        let tokenizer = HighlightrTokenizer(language: "swift")
        let tokens = tokenizer.tokens(in: "let x = 1 // done")
        #expect(!tokens.isEmpty)
        #expect(tokens.allSatisfy {
            if case .colored = $0.kind { return true } else { return false }
        })
    }

    @Test func unknownLanguagesYieldNothingRatherThanGuesses() {
        // No auto-detection fallback: a language we can't name paints nothing.
        #expect(HighlightrTokenizer.highlight("let x = 1", language: "notalanguage").isEmpty)
    }

    @Test func highlightsAcrossTheBreadthOfTheTable() {
        // A spread of grammars, each producing colored runs for real snippets.
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
            #expect(!HighlightrTokenizer.highlight(code, language: language).isEmpty,
                    "no highlighting for \(language)")
        }
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

@Suite struct TypstRefTests {
    @Test func urisRoundTripAndCanonicalize() throws {
        let refs = [
            TypstRef.section(file: "/Users/x/my notes/doc.typ", line: 12),
            TypstRef.task(file: "/Users/x/doc.typ", index: 3),
            TypstRef.agenda(dir: "/Users/x/notes"),
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
                                               documentURL: doc)
        #expect(output.pdf != nil)
        #expect(output.diagnostics.isEmpty)
    }

    @Test func exportsPDF() async throws {
        let doc = try tempDocURL()
        let dest = doc.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let diagnostics = await TypstEngine.export(
            source: "= Hello", documentURL: doc, format: .pdf, to: dest)
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty)
        let data = try Data(contentsOf: dest)
        #expect(data.starts(with: Array("%PDF".utf8)))
    }

    @Test func exportsWholeDocumentAsOneSVG() async throws {
        let doc = try tempDocURL()
        let dest = doc.deletingLastPathComponent().appendingPathComponent("out.svg")
        let diagnostics = await TypstEngine.export(
            source: "= Page One\n#pagebreak()\n= Page Two",
            documentURL: doc, format: .svg, to: dest)
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty)
        let svg = try String(contentsOf: dest, encoding: .utf8)
        #expect(svg.contains("<svg"))   // both pages, stacked in one file
    }

    @Test func exportsPNGPerPageWhenMultiPage() async throws {
        let doc = try tempDocURL()
        let dir = doc.deletingLastPathComponent()
        let dest = dir.appendingPathComponent("out.png")
        let diagnostics = await TypstEngine.export(
            source: "one\n#pagebreak()\ntwo", documentURL: doc, format: .png, to: dest)
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
            source: "just one page", documentURL: doc, format: .png, to: dest)
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func exportSurfacesCompileErrorsAndWritesNothing() async throws {
        let doc = try tempDocURL()
        let dest = doc.deletingLastPathComponent().appendingPathComponent("bad.svg")
        let diagnostics = await TypstEngine.export(
            source: "#nonexistent()", documentURL: doc, format: .svg, to: dest)
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
                                               documentURL: try tempDocURL())
        #expect(output.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(output.pdf != nil)
    }
}
