import Testing
import SwiftUI
@testable import MaximalTreeKit
@testable import MaximalTree

@MainActor
@Suite struct RendererResolutionTests {
    /// Mirrors the real setup: a low-priority "any file" canvas (FileSystem's Quick
    /// Look) and a high-priority text-only canvas (the TextEditor plugin). The text
    /// canvas must win for text and lose for non-text — cross-plugin resolution.
    private func store() -> GraphStore {
        let registry = Registry()
        registry.registerCanvas(forType: TypeID("file.file")) { _, _ in AnyView(Text("quicklook")) }
        registry.register(canvas: CanvasContribution(priority: 100,
            matches: { $0.uti == "public.plain-text" }) { _, _ in AnyView(Text("editor")) })
        return GraphStore(context: HostContext(), registry: registry, nav: NavigationModel())
    }

    private func fileNode(_ uri: String, uti: String) -> Node {
        Node(id: NodeID(uri)!, type: "file.file", attributes: Attributes(["uti": .string(uti)]))
    }

    @Test func textFileGoesToHigherPriorityEditor() {
        let node = fileNode("file:///a.txt", uti: "public.plain-text")
        #expect(store().canvas(for: node)?.priority == 100)
    }

    @Test func nonTextFileFallsBackToQuickLook() {
        let node = fileNode("file:///a.jpg", uti: "public.jpeg")
        #expect(store().canvas(for: node)?.priority == 0)
    }

    @Test func inspectorsCompose_allMatchesReturned() {
        let registry = Registry()
        registry.register(inspector: InspectorContribution(priority: 10,
            matches: { $0.type.raw.hasPrefix("file.") }) { _, _ in AnyView(EmptyView()) })
        registry.register(inspector: InspectorContribution(priority: 5,
            matches: { $0.uti == "public.plain-text" }) { _, _ in AnyView(EmptyView()) })
        let store = GraphStore(context: HostContext(), registry: registry, nav: NavigationModel())

        let node = fileNode("file:///a.txt", uti: "public.plain-text")
        let sections = store.inspectors(for: node)
        #expect(sections.count == 2)                 // both match, both shown
        #expect(sections.map(\.priority) == [10, 5]) // sorted most-specific first
    }
}
