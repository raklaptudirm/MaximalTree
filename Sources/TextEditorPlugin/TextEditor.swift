import SwiftUI
import UniformTypeIdentifiers
import MaximalEditorKit
import MaximalTreeKit

/// A second plugin whose only job is to provide a better canvas for *text* files —
/// files that the FileSystem plugin provides. It proves three things:
///   1. Cross-plugin rendering: a renderer here matches nodes another plugin owns.
///   2. Priority resolution: it registers above FileSystem's Quick Look canvas and
///      matches a narrower content type, so it wins for text while other files still
///      fall through to Quick Look.
///   3. Editor plugins stay thin: the engine lives in MaximalEditorKit (embedded
///      once by the host), not in each plugin bundle.
@objc(TextEditorPlugin)
final class TextEditorPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        registry.register(canvas: CanvasContribution(
            priority: 100,                       // beats FileSystem's Quick Look (0)
            matches: Self.handlesAsText(_:),
            // First open pays the highlighter's JS load behind the host's
            // loading indicator, not inside the first paint.
            prepare: { _ in await SyntaxTokenizer.warmUp() },
            make: { id, host in AnyView(TextEditorCanvas(nodeID: id).environment(host)) }
        ))
    }

    /// Whether this node should open in the text editor rather than fall through
    /// to Quick Look.
    ///
    /// Content type alone isn't enough: macOS has **no registered UTI for most
    /// source and config files** — Rust, Nix, Elixir, Lua, Kotlin, Scala,
    /// `.conf`, `.gradle` all resolve to `dyn.…` types that conform to nothing,
    /// and extensionless files (Makefile, Dockerfile) have no type at all. So we
    /// also claim anything the editor has a grammar for: if we can highlight it,
    /// we can edit it.
    static func handlesAsText(_ node: Node) -> Bool {
        // Directories are containers, never documents — and a directory named
        // `foo.d` would otherwise look like a D source file.
        guard node.id.scheme == "file", node.type != TypeID("file.directory")
        else { return false }
        if let uti = node.uti, let type = UTType(uti), type.conforms(to: .text) {
            return true
        }
        guard let url = URL(string: node.id.uri) else { return false }
        return EditorLanguage.id(for: url) != nil
    }
}

struct TextEditorCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    @State private var text = ""
    /// What's on disk. `dirty` is derived from this rather than tracked with a flag,
    /// so the editor echoing its binding back on load can't fake an edit.
    @State private var savedText = ""
    @State private var loadError: String?
    /// Which node `text` currently holds. Gating on identity (not a Bool) is what
    /// keeps the editor from ever being built with another file's contents — the
    /// engine reads its text binding exactly once, at construction.
    @State private var loadedNode: NodeID?

    private var dirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            if loadedNode != nodeID {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                MaximalEditor(text: $text, fileURL: fileURL, style: .code(),
                              tokenizer: fileURL.flatMap(SyntaxTokenizer.init(fileURL:)))
                    .id(nodeID)      // per-document identity: switching files rebuilds
                    .clipped()       // AppKit-backed: keep it inside our layout
            }
        }
        // Content-only canvas: metadata lives in the inspector, saving on the
        // (invisible) shortcut, unsaved state on a corner dot.
        .overlay(alignment: .topTrailing) {
            if dirty {
                Circle().fill(.secondary).frame(width: 7, height: 7).padding(10)
                    .help("Unsaved changes \u{2014} \u{2318}S")
            }
        }
        .background(
            Button("", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        )
        .task(id: nodeID) {
            loadedNode = nil     // stop showing the previous file immediately
            await load()
            loadedNode = nodeID  // set either way: this node is resolved, error or not
        }
        // Guarded on the load having finished: `load()` assigns `text` too, and
        // opening a file is not editing it.
        .onChange(of: text) {
            guard loadedNode == nodeID else { return }
            host.markEdited(nodeID)   // this tab is work now, not a preview
        }
    }

    private var fileURL: URL? {
        guard nodeID.scheme == "file" else { return nil }
        return URL(string: nodeID.uri)
    }

    private func load() async {
        loadError = nil
        guard let url = fileURL else { loadError = "Not a file."; return }
        do {
            // Off-main: a large file must not stall the app loop while the
            // ProgressView above is showing.
            let contents = try await Task.detached(priority: .userInitiated) {
                try String(contentsOf: url, encoding: .utf8)
            }.value
            text = contents
            savedText = contents
        } catch {
            text = ""
            savedText = ""
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            // Tell the host we changed the file in place, so the FileSystem plugin's
            // inspector (size, modified date) doesn't go stale.
            host.notify([.modified(nodeID)])
        } catch {
            loadError = error.localizedDescription
        }
    }
}
