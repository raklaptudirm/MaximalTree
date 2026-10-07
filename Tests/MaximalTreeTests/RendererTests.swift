import Testing
import SwiftUI
@testable import MaximalTreeKit
@testable import MaximalTree

@MainActor
@Suite struct RendererResolutionTests {
    /// Mirrors the real setup: a low-priority "any file" canvas (FileSystem's Quick
    /// Look) and a high-priority text-only canvas (the TextEditor plugin). The text
    /// canvas must win for text and lose for non-text — cross-plugin resolution.
    private func registry() -> Registry {
        let registry = Registry()
        registry.registerCanvas(forType: TypeID("file.file")) { _, _ in AnyView(Text("quicklook")) }
        registry.register(canvas: CanvasContribution(priority: 100,
            matches: { $0.uti == "public.plain-text" }) { _, _ in AnyView(Text("editor")) })
        return registry
    }

    private func fileNode(_ uri: String, uti: String) -> Node {
        Node(id: NodeID(uri)!, type: "file.file", attributes: Attributes(["uti": .string(uti)]))
    }

    @Test func textFileGoesToHigherPriorityEditor() {
        let node = fileNode("file:///a.txt", uti: "public.plain-text")
        #expect(registry().canvas(for: node)?.priority == 100)
    }

    @Test func nonTextFileFallsBackToQuickLook() {
        let node = fileNode("file:///a.jpg", uti: "public.jpeg")
        #expect(registry().canvas(for: node)?.priority == 0)
    }

    /// The async `prepare` seam: it must survive registration and resolution
    /// (the host awaits it off-main before `make`), and default to nil so
    /// prepare-less canvases render without an extra hop.
    @Test func canvasPrepareCarriesThroughResolution() async {
        let registry = Registry()
        let prepared = Prepared()
        registry.register(canvas: CanvasContribution(
            priority: 100,
            matches: { $0.uti == "public.plain-text" },
            prepare: { id in await prepared.record(id) },
            make: { _, _ in AnyView(Text("editor")) }))
        registry.registerCanvas(forType: TypeID("file.file")) { _, _ in AnyView(Text("quicklook")) }

        let text = fileNode("file:///a.txt", uti: "public.plain-text")
        let canvas = registry.canvas(for: text)
        #expect(canvas?.prepare != nil)
        await canvas?.prepare?(text.id)
        #expect(await prepared.ids == [text.id])

        let image = fileNode("file:///a.jpg", uti: "public.jpeg")
        #expect(registry.canvas(for: image)?.prepare == nil)   // default: no prepare
    }

    private actor Prepared {
        var ids: [NodeID] = []
        func record(_ id: NodeID) { ids.append(id) }
    }

    @Test func inspectorsCompose_allMatchesReturned() {
        let registry = Registry()
        registry.register(inspector: InspectorContribution(priority: 10,
            matches: { $0.type.raw.hasPrefix("file.") }) { _, _ in AnyView(EmptyView()) })
        registry.register(inspector: InspectorContribution(priority: 5,
            matches: { $0.uti == "public.plain-text" }) { _, _ in AnyView(EmptyView()) })

        let node = fileNode("file:///a.txt", uti: "public.plain-text")
        let sections = registry.inspectors(for: node, in: HostContext())
        #expect(sections.count == 2)                 // both match, both shown
        // Sorted most-specific first, and each paired with the node it should
        // be rendered for — see `Node.identities`.
        #expect(sections.map(\.contribution.priority) == [10, 5])
        #expect(sections.allSatisfy { $0.id == node.id })
    }
}

/// Which files the text editor claims from Quick Look.
///
/// Regression: the matcher used to test *only* UTI conformance to `public.text`,
/// but macOS registers no UTI for most source and config files — Rust, Nix,
/// Elixir, Kotlin, `.conf` and friends resolve to `dyn.…` types that conform to
/// nothing, and extensionless files (Makefile, Dockerfile) have no type at all.
/// Those all fell through to Quick Look and couldn't be edited or highlighted.
@Suite struct TextEditorMatchingTests {
    private func node(_ path: String, uti: String? = nil,
                      type: TypeID = "file.file") -> Node {
        var attrs = Attributes()
        if let uti { attrs["uti"] = .string(uti) }
        return Node(id: NodeID(fileURL: URL(fileURLWithPath: path))!,
                    type: type, attributes: attrs)
    }

    @Test func claimsSourceFilesMacOSHasNoUTIFor() {
        // No UTI at all (the realistic case for these extensions).
        #expect(TextEditorPlugin.handlesAsText(node("/p/main.rs")))
        #expect(TextEditorPlugin.handlesAsText(node("/p/flake.nix")))
        #expect(TextEditorPlugin.handlesAsText(node("/p/app.ex")))
        #expect(TextEditorPlugin.handlesAsText(node("/p/Main.kt")))
        #expect(TextEditorPlugin.handlesAsText(node("/p/server.conf")))
        // A dynamic UTI conforms to nothing — must not disqualify the file.
        #expect(TextEditorPlugin.handlesAsText(
            node("/p/main.rs", uti: "dyn.ah62d4rv4ge81e62")))
    }

    @Test func claimsExtensionlessBuildFilesAndPlainText() {
        #expect(TextEditorPlugin.handlesAsText(node("/p/Makefile")))
        #expect(TextEditorPlugin.handlesAsText(node("/p/Dockerfile")))
        #expect(TextEditorPlugin.handlesAsText(node("/p/LICENSE")))
        #expect(TextEditorPlugin.handlesAsText(node("/p/.gitignore")))
    }

    @Test func stillClaimsAnythingTypedAsText() {
        // The original path: a registered text UTI we have no grammar for.
        #expect(TextEditorPlugin.handlesAsText(
            node("/p/notes.weird", uti: "public.plain-text")))
    }

    @Test func leavesBinariesAndDirectoriesAlone() {
        #expect(!TextEditorPlugin.handlesAsText(node("/p/photo.jpeg", uti: "public.jpeg")))
        #expect(!TextEditorPlugin.handlesAsText(node("/p/archive.zip")))
        // A directory named like a D source file is still a directory.
        #expect(!TextEditorPlugin.handlesAsText(node("/p/src.d", type: "file.directory")))
    }
}

/// End-to-end canvas resolution for source files, through the *real* plugin
/// registrations: a node built by the FileSystem provider must resolve to the
/// text editor's canvas (priority 100), not Quick Look (0).
@MainActor
@Suite struct SourceFileCanvasResolutionTests {
    private func registry() -> Registry {
        let registry = Registry()
        FileSystemPlugin().register(with: registry)   // Quick Look canvas, priority 0
        TextEditorPlugin().register(with: registry)   // editor canvas, priority 100
        return registry
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func sourceFilesResolveToTheEditorNotQuickLook() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let canvases = registry()

        // Files whose UTI is dynamic (or absent) — the ones that regressed.
        for name in ["main.rs", "flake.nix", "app.ex", "Main.kt", "Dockerfile",
                     "Makefile", "server.conf", "build.gradle", ".gitignore"] {
            let url = dir.appendingPathComponent(name)
            try "x = 1\n".write(to: url, atomically: true, encoding: .utf8)
            let id = try #require(NodeID(fileURL: url))
            let node = try #require(FileSystemProvider.makeNode(url: url, id: id))
            #expect(canvases.canvas(for: node)?.priority == 100,
                    "\(name) should open in the editor")
        }
    }

    @Test func binariesStillFallThroughToQuickLook() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("image.jpeg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        let id = try #require(NodeID(fileURL: url))
        let node = try #require(FileSystemProvider.makeNode(url: url, id: id))
        #expect(registry().canvas(for: node)?.priority == 0)
    }
}
