import Testing
import Foundation
@testable import MaximalTreeKit

/// What language servers send, read into one shape per question — the part
/// of the client that needs no server, run everywhere CI runs.
@Suite struct LanguageServerProtocolTests {
    private func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    @Test func framesAreReadWholeAndInTurn() {
        let one = #"{"id":1}"#, two = #"{"id":2}"#
        var buffer = Data("Content-Length: \(one.utf8.count)\r\n\r\n\(one)Content-Length: \(two.utf8.count)\r\n\r\n".utf8)
        #expect(LSP.nextFrame(from: &buffer) == Data(one.utf8))
        #expect(LSP.nextFrame(from: &buffer) == nil, "a frame whose body hasn't arrived was read")
        buffer.append(Data(two.utf8))
        #expect(LSP.nextFrame(from: &buffer) == Data(two.utf8))
        #expect(buffer.isEmpty)
    }

    /// Line and character count UTF-16, as the editor does — an emoji is two.
    @Test func positionsCountWhatTheEditorCounts() {
        let text = "a😀b\nnext"
        let position = CodePosition(offset: 3, in: text)
        #expect(position == CodePosition(line: 0, character: 3))
        #expect(position.offset(in: text) == 3)
        #expect(CodePosition(offset: 6, in: text) == CodePosition(line: 1, character: 1))
        #expect(CodePosition(line: 9, character: 9).offset(in: text) == (text as NSString).length)
    }

    /// An error, a null, or something that isn't a response at all: nothing.
    @Test func whatIsNotAnAnswerIsNothing() {
        #expect(LSP.result(of: Data("junk".utf8)) == nil)
        #expect(LSP.result(of: Data(#"{"id":1,"result":null}"#.utf8)) == nil)
        #expect(LSP.result(of: Data(#"{"id":1,"error":{"code":-32601,"message":"no"}}"#.utf8)) == nil)
        #expect(LSP.completions(from: nil, in: "").isEmpty)
    }

    @Test func completionsComeAsAListOrInOne() {
        let list = json(#"{"isIncomplete":false,"items":[{"label":"count","kind":10,"insertText":"count"}]}"#)
        let completions = LSP.completions(from: list, in: "")
        #expect(completions == [CodeCompletion(label: "count", detail: "property", insertText: "count")])
        let array = json(#"[{"label":"f","insertTextFormat":2,"insertText":"f(${1:x})$0"}]"#)
        #expect(LSP.completions(from: array, in: "").first?.insertText == "f(x)")
    }

    @Test func aCompletionsEditSaysWhatItReplaces() {
        let text = "p.cou"
        let result = json(#"[{"label":"count","textEdit":{"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":5}},"newText":"count"}}]"#)
        #expect(LSP.completions(from: result, in: text).first?.replaceRange == NSRange(location: 2, length: 3))
    }

    @Test func hoverIsTextHoweverItIsWrapped() {
        #expect(LSP.hover(from: json(#"{"contents":{"kind":"markdown","value":"**Int**"}}"#)) == "**Int**")
        #expect(LSP.hover(from: json(#"{"contents":["a",{"language":"swift","value":"b"}]}"#)) == "a\n\nb")
        #expect(LSP.hover(from: json(#"{"contents":""}"#)) == nil)
    }

    @Test func locationsComeInThreeShapes() {
        let range = #"{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}"#
        let expected = [CodeLocation(url: URL(string: "file:///a.swift")!,
                                     range: CodeRange(start: CodePosition(line: 1, character: 2),
                                                      end: CodePosition(line: 1, character: 5)))]
        #expect(LSP.locations(from: json(#"{"uri":"file:///a.swift","range":\#(range)}"#)) == expected)
        #expect(LSP.locations(from: json(#"[{"uri":"file:///a.swift","range":\#(range)}]"#)) == expected)
        #expect(LSP.locations(from: json(#"[{"targetUri":"file:///a.swift","targetRange":\#(range),"targetSelectionRange":\#(range)}]"#)) == expected)
    }

    @Test func symbolsNestAsTheFileDoes() {
        let range = #"{"start":{"line":0,"character":0},"end":{"line":2,"character":1}}"#
        let result = json(#"[{"name":"Point","kind":23,"range":\#(range),"selectionRange":\#(range),"children":[{"name":"x","kind":7,"range":\#(range),"selectionRange":\#(range)}]}]"#)
        let symbols = LSP.symbols(from: result)
        #expect(symbols.map(\.name) == ["Point"])
        #expect(symbols.first?.kind == "struct")
        #expect(symbols.first?.children.map(\.name) == ["x"])
        // The older flat shape, with a location instead of ranges.
        let flat = json(#"[{"name":"f","kind":12,"location":{"uri":"file:///a","range":\#(range)}}]"#)
        #expect(LSP.symbols(from: flat).first?.kind == "function")
    }

    @Test func editsApplyFromTheEnd() {
        let text = "let a = 1\nlet b = 2"
        let edits = [CodeEdit(range: CodeRange(start: .init(line: 0, character: 4), end: .init(line: 0, character: 5)), newText: "first"),
                     CodeEdit(range: CodeRange(start: .init(line: 1, character: 4), end: .init(line: 1, character: 5)), newText: "second")]
        #expect(CodeEdit.apply(edits, to: text) == "let first = 1\nlet second = 2")
    }

    @Test func aRenameTouchesEveryFileItNames() {
        let range = #"{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}"#
        let changes = LSP.workspaceEdit(from: json(#"{"changes":{"file:///a":[{"range":\#(range),"newText":"y"}]}}"#))
        #expect(changes[URL(string: "file:///a")!]?.first?.newText == "y")
        let documentChanges = LSP.workspaceEdit(from: json(#"{"documentChanges":[{"textDocument":{"uri":"file:///b","version":1},"edits":[{"range":\#(range),"newText":"z"}]}]}"#))
        #expect(documentChanges[URL(string: "file:///b")!]?.count == 1)
    }

    @Test func diagnosticsSayHowBad() {
        let range = #"{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}"#
        let diagnostics = LSP.diagnostics(from: json(#"[{"range":\#(range),"severity":2,"message":"unused","source":"swiftc"}]"#))
        #expect(diagnostics == [CodeDiagnostic(range: CodeRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 1)),
                                               severity: .warning, message: "unused", source: "swiftc")])
    }

    /// A project's root is the nearest folder with one of the server's markers.
    @Test func aProjectsRootIsItsMarker() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lsp-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"),
                                                withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        let swift = LanguageServerConfig.known.first { $0.name == "sourcekit-lsp" }!
        #expect(swift.root(of: root.appendingPathComponent("Sources/App/main.swift")).path == root.path)
        #expect(swift.serves(URL(fileURLWithPath: "/a/b.swift")))
        #expect(!swift.serves(URL(fileURLWithPath: "/a/b.py")))
    }
}

#if os(macOS) || os(Linux)
/// A real server, on a real file — sourcekit-lsp, which ships with Swift on
/// both platforms CI runs. Skipped where it isn't installed.
@Suite(.timeLimit(.minutes(2)))
struct LanguageServerLiveTests {
    private static let source = """
        struct Point {
            var x: Int
            func length() -> Int { x }
        }
        let p = Point(x: 1)
        let y = p.
        """

    private func swift() throws -> (LanguageServer, CodeDocument)? {
        guard let config = LanguageServerConfig.known.first(where: { $0.name == "sourcekit-lsp" }),
              let server = LanguageServer(config) else {
            // Skipped where Swift's server isn't installed — but not in CI,
            // whose images ship it: there a skip would be a pass that proved
            // nothing.
            if ProcessInfo.processInfo.environment["CI"] != nil {
                Issue.record("sourcekit-lsp isn't installed on this runner")
            }
            return nil
        }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lsp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("main.swift")
        try Data(Self.source.utf8).write(to: file)
        return (server, CodeDocument(url: file, text: Self.source))
    }

    @Test func itAnswersAboutTheCode() async throws {
        guard let (server, document) = try swift() else { return }
        let text = document.text as NSString

        let members = await server.completions(in: document, at: text.length)
        #expect(members.contains { $0.label.hasPrefix("x") }, "\(members.map(\.label))")
        #expect(members.contains { $0.label.hasPrefix("length") })

        let symbols = await server.symbols(in: document)
        let point = symbols.first { $0.name == "Point" }
        #expect(point?.kind == "struct", "\(symbols.map(\.name))")
        #expect(point?.children.map(\.name).contains("x") == true)

        // `Point` in `Point(x: 1)` was defined on the first line.
        let use = text.range(of: "Point(x").location
        let definition = await server.definition(in: document, at: use)
        #expect(definition.first?.range.start.line == 0, "\(definition)")

        let hover = await server.hover(in: document, at: use)
        #expect(hover?.contains("Point") == true, "\(hover ?? "nothing")")
    }

    /// The unfinished member access is an error, and the server says so.
    @Test func itSaysWhatIsWrong() async throws {
        guard let (server, document) = try swift() else { return }
        let diagnostics = await server.diagnostics(in: document)
        #expect(diagnostics.contains { $0.severity == .error && $0.range.start.line == 5 },
                "\(diagnostics.map(\.message))")
    }
}
#endif
