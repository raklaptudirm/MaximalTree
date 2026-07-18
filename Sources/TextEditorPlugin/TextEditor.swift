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
            matches: { node in
                guard let uti = node.uti, let type = UTType(uti) else { return false }
                return type.conforms(to: .text)  // plain text, source code, …
            },
            make: { id, host in AnyView(TextEditorCanvas(nodeID: id).environment(host)) }
        ))
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
            header
            Divider()

            if loadedNode != nodeID {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                MaximalEditor(text: $text, fileURL: fileURL, style: .code())
                    .id(nodeID)      // per-document identity: switching files rebuilds
                    .clipped()       // AppKit-backed: keep it inside our layout
            }
        }
        .task(id: nodeID) {
            loadedNode = nil     // stop showing the previous file immediately
            load()
            loadedNode = nodeID  // set either way: this node is resolved, error or not
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(host.node(nodeID)?.label ?? "")
                .font(.headline)
                .lineLimit(1)
            if dirty {
                Text("Edited").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = fileURL, let language = editorLanguageName(for: url) {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Save", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty)
        }
        .padding(8)
    }

    private var fileURL: URL? {
        guard nodeID.scheme == "file" else { return nil }
        return URL(string: nodeID.uri)
    }

    private func load() {
        loadError = nil
        guard let url = fileURL else { loadError = "Not a file."; return }
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
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
