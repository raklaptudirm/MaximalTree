import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CodeEditSourceEditor
import CodeEditLanguages
import MaximalTreeKit

/// A second plugin whose only job is to provide a better canvas for *text* files —
/// files that the FileSystem plugin provides. It proves three things:
///   1. Cross-plugin rendering: a renderer here matches nodes another plugin owns.
///   2. Priority resolution: it registers above FileSystem's Quick Look canvas and
///      matches a narrower content type, so it wins for text while other files still
///      fall through to Quick Look.
///   3. A plugin can carry its own third-party dependencies (here a full source
///      editor plus tree-sitter grammars) inside its loadable bundle.
///
/// Content editing is *not* a `GraphMutation` — that vocabulary is for structural
/// (tree) changes like rename/delete. Reading and writing a file's bytes is
/// type-specific manipulation the plugin does directly through the canvas escape
/// hatch.
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
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    /// What's on disk. `dirty` is derived from this rather than tracked with a flag,
    /// so the editor echoing its binding back on load can't fake an edit.
    @State private var savedText = ""
    @State private var language: CodeLanguage = .default
    @State private var editorState = SourceEditorState()
    @State private var loadError: String?
    /// Gates editor construction until `text` holds the file's contents — see below.
    @State private var loaded = false

    private var dirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let loadError {
                ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if loaded {
                // SourceEditor reads the text binding exactly once, in
                // makeNSViewController — updateNSViewController never pushes external
                // changes in (so it can't clobber typing). So the editor must not be
                // built until `text` is populated, and it needs a per-file identity or
                // switching files would reuse the controller and show stale contents.
                SourceEditor(
                    $text,
                    language: language,
                    configuration: SourceEditorConfiguration(
                        appearance: .init(
                            theme: colorScheme == .dark ? .maximalDark : .maximalLight,
                            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                            wrapLines: false          // code editor: scroll, don't wrap
                        ),
                        behavior: .init(indentOption: .spaces(count: 4))
                    ),
                    state: $editorState
                )
                .id(nodeID)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: nodeID) {
            loaded = false
            load()
            loaded = loadError == nil
        }
        .navigationTitle(host.node(nodeID)?.label ?? "")
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
            if language != .default {
                Text(language.id.rawValue)
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
            language = CodeLanguage.detectLanguageFrom(url: url)
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
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Theme

extension EditorTheme {
    /// Adapted from CodeEditSourceEditor's example themes (Xcode-like).
    static var maximalLight: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor(hex: "000000")),
            insertionPoint: NSColor(hex: "000000"),
            invisibles: Attribute(color: NSColor(hex: "D6D6D6")),
            background: NSColor(hex: "FFFFFF"),
            lineHighlight: NSColor(hex: "ECF5FF"),
            selection: NSColor(hex: "B2D7FF"),
            keywords: Attribute(color: NSColor(hex: "9B2393"), bold: true),
            commands: Attribute(color: NSColor(hex: "326D74")),
            types: Attribute(color: NSColor(hex: "0B4F79")),
            attributes: Attribute(color: NSColor(hex: "815F03")),
            variables: Attribute(color: NSColor(hex: "0F68A0")),
            values: Attribute(color: NSColor(hex: "6C36A9")),
            numbers: Attribute(color: NSColor(hex: "1C00CF")),
            strings: Attribute(color: NSColor(hex: "C41A16")),
            characters: Attribute(color: NSColor(hex: "1C00CF")),
            comments: Attribute(color: NSColor(hex: "267507"))
        )
    }

    static var maximalDark: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor(hex: "FFFFFF")),
            insertionPoint: NSColor(hex: "007AFF"),
            invisibles: Attribute(color: NSColor(hex: "53606E")),
            background: NSColor(hex: "292A30"),
            lineHighlight: NSColor(hex: "2F3239"),
            selection: NSColor(hex: "646F83"),
            keywords: Attribute(color: NSColor(hex: "FF7AB2"), bold: true),
            commands: Attribute(color: NSColor(hex: "78C2B3")),
            types: Attribute(color: NSColor(hex: "6BDFFF")),
            attributes: Attribute(color: NSColor(hex: "CC9768")),
            variables: Attribute(color: NSColor(hex: "4EB0CC")),
            values: Attribute(color: NSColor(hex: "B281EB")),
            numbers: Attribute(color: NSColor(hex: "D9C97C")),
            strings: Attribute(color: NSColor(hex: "FF8170")),
            characters: Attribute(color: NSColor(hex: "D9C97C")),
            comments: Attribute(color: NSColor(hex: "7F8C98"))
        )
    }
}

private extension NSColor {
    /// "RRGGBB" → color. The example themes rely on a helper like this.
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
