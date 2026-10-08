import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree
@testable import MaximalEditorKit

/// A service that serves one extension and answers with its own name.
private struct Named: LanguageService {
    let name: String
    let ext: String
    func serves(_ url: URL) -> Bool { url.pathExtension == ext }
    func completions(in document: CodeDocument, at offset: Int) async -> [CodeCompletion] {
        [CodeCompletion(label: name, insertText: name)]
    }
}

/// How a file's language service is found: registered by a plugin, looked up
/// by the host for any canvas that asks.
@MainActor
@Suite struct LanguageServiceLookupTests {
    @Test func theFirstRegisteredIsAskedFirst() async throws {
        let registry = CoreContributions()
        registry.register(languageService: Named(name: "particular", ext: "swift"))
        registry.register(languageService: Named(name: "general", ext: "swift"))
        let service = try #require(registry.languageService(for: URL(fileURLWithPath: "/a.swift")))
        let answer = await service.completions(in: CodeDocument(url: URL(fileURLWithPath: "/a.swift"), text: ""), at: 0)
        #expect(answer.map(\.label) == ["particular"])
        #expect(registry.languageService(for: URL(fileURLWithPath: "/a.py")) == nil)
    }

    /// A canvas asks its host; the host asks the registry.
    @Test func aCanvasFindsItThroughTheHost() throws {
        let registry = Registry()
        registry.register(languageService: Named(name: "swift", ext: "swift"))
        let host = HostContext()
        let store = GraphStore(context: host, registry: registry, nav: NavigationModel())
        _ = store
        #expect(host.languageService(for: URL(fileURLWithPath: "/a.swift")) != nil)
        #expect(host.languageService(for: URL(fileURLWithPath: "/a.rs")) == nil)
    }

    /// The text editor registers every server installed here but typst's,
    /// which is typst's to register.
    @Test func theTextEditorRegistersWhatIsInstalledButTypsts() {
        let registry = CoreContributions()
        TextEditorCore.register(with: registry)
        let installed = LanguageServer.installed().map(\.config.name).filter { $0 != "tinymist" }
        let registered = registry.languageServices.compactMap { ($0 as? LanguageServer)?.config.name }
        #expect(registered == installed)
        #expect(!registered.contains("tinymist"))
    }

    @Test func typstRegistersTinymistWhereItIsInstalled() {
        let registry = CoreContributions()
        TypstCore.register(with: registry)
        let installed = LanguageServerConfig.known.first { $0.name == "tinymist" }?.installedAt() != nil
        #expect((registry.languageService(for: URL(fileURLWithPath: "/a.typ")) != nil) == installed)
    }
}

/// Where the completion window opens without being asked: after a sigil in
/// prose, after a `.` or two letters into a word in code.
@Suite struct CompletionTriggerTests {
    private func fires(_ trigger: EditorCompletionTrigger, _ marked: String) -> Bool {
        let ns = marked as NSString
        let caret = ns.range(of: "|").location
        return trigger.fires(at: caret, in: ns.replacingCharacters(in: NSRange(location: caret, length: 1),
                                                                  with: "") as NSString)
    }

    @Test func codeOpensItAfterADotOrTwoLetters() {
        #expect(fires(.code, "point.|"))
        #expect(fires(.code, "let co|"))
        #expect(!fires(.code, "let c|"), "one letter is not yet a word")
        #expect(!fires(.code, "x = 12|"), "a number is not a name")
        #expect(!fires(.code, "done |"))
    }

    @Test func proseOpensItOnlyAfterASigil() {
        let typst: EditorCompletionTrigger = .sigils(["#", "@"])
        #expect(fires(typst, "#ima|"))
        #expect(fires(typst, "see @fig|"))
        #expect(!fires(typst, "plain words|"))
    }
}
