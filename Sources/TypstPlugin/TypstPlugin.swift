import SwiftUI
import AppKit
import PDFKit
import CodeEditSourceEditor
import CodeEditLanguages
import MaximalTreeKit

/// A Typst document editor: source on the left, live-compiled PDF preview on the
/// right. The preview compiles the *buffer* (debounced) by piping it to `typst`
/// via stdin with `--root` at the document's directory — unsaved edits render
/// live, and relative imports/images still resolve.
///
/// This is the first compiler-backed canvas: it embeds its own SourceEditor (the
/// TextEditor plugin's views are internal to that bundle) and composes it with
/// PDFKit and a CLI toolchain, all inside one plugin bundle.
@objc(TypstPlugin)
final class TypstPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        registry.register(canvas: CanvasContribution(
            priority: 150,     // above TextEditor (100): .typ is text, but ours is better
            matches: { node in
                node.id.scheme == "file" && node.id.uri.lowercased().hasSuffix(".typ")
            },
            make: { id, host in AnyView(TypstCanvas(nodeID: id).environment(host)) }
        ))
    }
}

// MARK: - Canvas

struct TypstCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    @State private var savedText = ""
    @State private var loadedNode: NodeID?
    @State private var loadError: String?
    @State private var editorState = SourceEditorState()

    @State private var preview: PDFDocument?
    @State private var previewData: Data?
    @State private var diagnostics: [TypstDiagnostic] = []
    @State private var compiling = false
    @State private var showPreview = true
    @State private var editorFraction: CGFloat = 0.5
    @State private var compileTask: Task<Void, Never>?

    private var dirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if loadedNode != nodeID {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                editorAndPreview
            }

            if !diagnostics.isEmpty {
                Divider()
                DiagnosticsBar(diagnostics: diagnostics) { diagnostic in
                    jump(to: diagnostic)
                }
            }
        }
        .task(id: nodeID) {
            loadedNode = nil
            load()
            loadedNode = nodeID
            if loadError == nil { scheduleCompile(delay: .zero) }   // first render
        }
    }

    // MARK: Layout

    private var header: some View {
        HStack(spacing: 10) {
            Text(host.node(nodeID)?.label ?? "")
                .font(.headline)
                .lineLimit(1)
            if dirty { Text("Edited").font(.caption).foregroundStyle(.secondary) }

            Spacer()

            if compiling {
                ProgressView().controlSize(.small)
            }
            if let preview {
                Text("\(preview.pageCount) page\(preview.pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                exportPDF()
            } label: {
                Label("Export PDF", systemImage: "square.and.arrow.up")
            }
            .disabled(previewData == nil)
            .help("Export the compiled PDF")
            Toggle(isOn: $showPreview) {
                Image(systemName: "sidebar.squares.trailing")
            }
            .toggleStyle(.button)
            .help("Show preview")
            Button("Save", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty)
        }
        .padding(8)
    }

    @ViewBuilder
    private var editorAndPreview: some View {
        GeometryReader { geo in
            let handle: CGFloat = 7
            let available = max(geo.size.width - (showPreview ? handle : 0), 1)
            let editorWidth = showPreview
                ? min(max(available * editorFraction, 200), max(available - 200, 200))
                : geo.size.width

            HStack(spacing: 0) {
                editor.frame(width: editorWidth)
                if showPreview {
                    divider(available: available)
                    previewColumn.frame(maxWidth: .infinity)
                }
            }
            .coordinateSpace(name: "typst-split")
        }
    }

    private var editor: some View {
        // Same identity-gating as the TextEditor plugin: SourceEditor reads its
        // binding once at construction, so it must never exist while `text` holds
        // another file. (No tree-sitter grammar for Typst in CodeEditLanguages yet,
        // so highlighting is plain — line numbers and editing niceties still apply.)
        SourceEditor(
            $text,
            language: .default,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: colorScheme == .dark ? .typstDark : .typstLight,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: true               // prose-like source: wrap, don't scroll
                ),
                behavior: .init(indentOption: .spaces(count: 2))
            ),
            state: $editorState
        )
        .id(nodeID)
        .clipped()
        .onChange(of: text) {
            guard loadedNode == nodeID else { return }
            scheduleCompile(delay: .milliseconds(400))
        }
    }

    private func divider(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(width: 7)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("typst-split"))
                .onChanged { value in
                    editorFraction = min(max(value.location.x / available, 0.15), 0.85)
                }
        )
        .onTapGesture(count: 2) { editorFraction = 0.5 }
    }

    @ViewBuilder
    private var previewColumn: some View {
        if !TypstCompiler.isAvailable {
            ContentUnavailableView {
                Label("Typst Not Installed", systemImage: "doc.richtext")
            } description: {
                Text("Install the typst CLI (e.g. `brew install typst`) to enable live preview.")
            }
        } else if let preview {
            PDFPreview(document: preview)
        } else if diagnostics.contains(where: { $0.severity == .error }) {
            ContentUnavailableView("Compile Failed", systemImage: "exclamationmark.triangle",
                                   description: Text("Fix the errors below to see the preview."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: File IO

    private var fileURL: URL? {
        guard nodeID.scheme == "file" else { return nil }
        return URL(string: nodeID.uri)
    }

    private func load() {
        loadError = nil
        preview = nil
        previewData = nil
        diagnostics = []
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
            host.notify([.modified(nodeID)])
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Compilation

    private func scheduleCompile(delay: Duration) {
        compileTask?.cancel()
        guard TypstCompiler.isAvailable, let url = fileURL else { return }
        let source = text
        compileTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            compiling = true
            let output = await TypstCompiler.compile(source: source, documentURL: url)
            guard !Task.isCancelled else { compiling = false; return }
            compiling = false
            diagnostics = output.diagnostics
            if let pdf = output.pdf {
                previewData = pdf
                preview = PDFDocument(data: pdf)
            }
            // On error, keep showing the last good preview alongside the diagnostics.
        }
    }

    private func jump(to diagnostic: TypstDiagnostic) {
        guard let line = diagnostic.line else { return }
        // typst reports 1-based lines, 0-based columns; CursorPosition is 1-based.
        editorState.cursorPositions = [
            CursorPosition(line: line, column: (diagnostic.column ?? 0) + 1)
        ]
    }

    private func exportPDF() {
        guard let data = previewData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (host.node(nodeID)?.label as NSString?)?
            .deletingPathExtension.appending(".pdf") ?? "document.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

// MARK: - Diagnostics bar

private struct DiagnosticsBar: View {
    let diagnostics: [TypstDiagnostic]
    let jump: (TypstDiagnostic) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(diagnostics) { diagnostic in
                    Button {
                        jump(diagnostic)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: diagnostic.severity == .error
                                  ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(diagnostic.severity == .error ? .red : .yellow)
                            if let line = diagnostic.line {
                                Text("\(line):\((diagnostic.column ?? 0) + 1)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text(diagnostic.message).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 76)
    }
}

// MARK: - PDF preview

/// PDFKit-backed preview that keeps the reader's place: on recompile it swaps the
/// document and restores the previous destination instead of jumping to page 1.
private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastDocument: PDFDocument?
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.lastDocument !== document else { return }
        context.coordinator.lastDocument = document

        let destination = view.currentDestination
        let pageIndex = destination?.page.map { view.document?.index(for: $0) ?? 0 } ?? 0
        view.document = document
        if let destination, document.pageCount > 0 {
            let index = min(pageIndex, document.pageCount - 1)
            if let page = document.page(at: index) {
                view.go(to: PDFDestination(page: page, at: destination.point))
            }
        }
    }
}

// MARK: - Theme (matches the TextEditor plugin's Xcode-like themes)

private extension EditorTheme {
    static var typstLight: EditorTheme {
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

    static var typstDark: EditorTheme {
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
