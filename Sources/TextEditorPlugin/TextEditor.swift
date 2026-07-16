import SwiftUI
import UniformTypeIdentifiers
import MaximalTreeKit

/// A second plugin whose only job is to provide a better canvas for *text* files —
/// files that the FileSystem plugin provides. It proves two things about the
/// architecture:
///   1. Cross-plugin rendering: a renderer here matches nodes another plugin owns.
///   2. Priority resolution: it registers at higher priority than FileSystem's
///      Quick Look canvas and matches a narrower content type, so it wins for text
///      files while non-text files still fall through to Quick Look.
///
/// Content editing is *not* a `GraphMutation` — that vocabulary is for structural
/// (tree) changes like rename/delete. Reading and writing a file's bytes is
/// type-specific manipulation the plugin does directly through the canvas escape
/// hatch. (A shared document/content model could be added later; v1 keeps it direct.)
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
    @State private var dirty = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(host.node(nodeID)?.label ?? "")
                    .font(.headline)
                    .lineLimit(1)
                if dirty {
                    Text("Edited").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty)
            }
            .padding(8)
            Divider()

            if let loadError {
                ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                TextEditor(text: Binding(
                    get: { text },
                    set: { text = $0; dirty = true }
                ))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
            }
        }
        .task(id: nodeID) { load() }
        .navigationTitle(host.node(nodeID)?.label ?? "")
    }

    private var fileURL: URL? {
        guard nodeID.scheme == "file" else { return nil }
        return URL(string: nodeID.uri)
    }

    private func load() {
        loadError = nil
        dirty = false
        guard let url = fileURL else { loadError = "Not a file."; return }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            text = ""
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
        } catch {
            loadError = error.localizedDescription
        }
    }
}
