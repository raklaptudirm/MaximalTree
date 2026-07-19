import SwiftUI
import AppKit
import PDFKit
import MaximalEditorKit
import MaximalTreeKit

// The document canvas (Write/Typeset/Read) and its supporting views. Content-
// only by design: controls live in Actions and the document inspector; the
// buffer's keybindings are registered invisibly (see hiddenShortcuts).

// MARK: - Canvas

struct TypstCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    @State private var savedText = ""
    @State private var loadedNode: NodeID?
    @State private var loadError: String?
    @State private var tokenizer = TypstTokenizer()
    @State private var editor = EditorController()
    private let uiState = TypstUIState.shared

    private var mode: TypstMode { uiState.mode(for: fileURL) }

    @State private var preview: PDFDocument?
    @State private var previewData: Data?
    @State private var diagnostics: [TypstDiagnostic] = []
    @State private var compiling = false
    @State private var editorFraction: CGFloat = 0.5
    @State private var compileTask: Task<Void, Never>?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var consumedFragment: UUID?

    private var dirty: Bool { text != savedText }
    private var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    var body: some View {
        VStack(spacing: 0) {
            if loadedNode != nodeID {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                switch mode {
                case .write: writeLayout
                case .typeset: typesetLayout
                case .read: previewColumn
                }
            }

            if mode == .typeset && !diagnostics.isEmpty {
                Divider()
                DiagnosticsBar(diagnostics: diagnostics) { jump(to: $0) }
            }
        }
        // The one piece of status the canvas keeps: a corner dot for compile
        // errors (any mode) or unsaved changes (explicit-save Typeset). All
        // controls live in Actions (menu bar, palette, context menu) and the
        // document inspector — the canvas is content.
        .overlay(alignment: .topTrailing) {
            if hasErrors {
                Circle().fill(.red).frame(width: 7, height: 7).padding(10)
                    .help("Compile errors — see Typeset mode")
            } else if mode == .typeset && dirty {
                Circle().fill(.secondary).frame(width: 7, height: 7).padding(10)
                    .help("Unsaved changes — \u{2318}S")
            }
        }
        .background(hiddenShortcuts)
        .task(id: nodeID) {
            loadedNode = nil
            await load()
            loadedNode = nodeID
            if loadError == nil { scheduleCompile(delay: .zero) }
            handleFragment()   // a phony-node open may have posted before we existed
        }
        .onChange(of: host.activeFragment) { _, _ in handleFragment() }
        .onChange(of: mode) { previous, current in
            // Entering an autosave mode (or leaving Typeset with edits pending)
            // flushes, so disk always matches what Write/Read show.
            if current.autosaves && dirty { saveToDisk() }
        }
        .onDisappear {
            if mode.autosaves && dirty && loadedNode == nodeID { saveToDisk() }
        }
    }

    /// The buffer's keybindings, registered invisibly: canvas chrome is gone,
    /// but these act on the live editor selection, which only the canvas can
    /// reach — they stay here rather than becoming plugin Actions.
    private var hiddenShortcuts: some View {
        HStack {
            Button("", action: saveToDisk)
                .keyboardShortcut("s", modifiers: .command)
            Button("") { applyFormat { TypstEdit.toggleWrap("*", in: $0, selection: $1) } }
                .keyboardShortcut("b", modifiers: .command)
            Button("") { applyFormat { TypstEdit.toggleWrap("_", in: $0, selection: $1) } }
                .keyboardShortcut("i", modifiers: .command)
            Button("") { applyFormat { TypstEdit.toggleWrap("`", in: $0, selection: $1) } }
                .keyboardShortcut("e", modifiers: .command)
            Button("") { applyFormat { TypstEdit.insertTask(in: $0, selection: $1) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    // MARK: Layouts

    /// Prose layout: a centered column on the page color, nothing else.
    private var writeLayout: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 24)
            editor(fontSize: 14)
                .frame(maxWidth: 760)
            Spacer(minLength: 24)
        }
        .background(Color(nsColor: pageBackground))
    }

    private var typesetLayout: some View {
        GeometryReader { geo in
            let handle: CGFloat = 7
            let available = max(geo.size.width - handle, 1)
            let editorWidth = min(max(available * editorFraction, 200),
                                  max(available - 200, 200))

            HStack(spacing: 0) {
                editor(fontSize: 12).frame(width: editorWidth)
                divider(available: available)
                previewColumn.frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "typst-split")
        }
    }

    private func editor(fontSize: CGFloat) -> some View {
        // Write reads like a manuscript (serif, roomy); Typeset is a code editor
        // that wraps (prose-like source).
        MaximalEditor(
            text: $text,
            style: mode == .write ? .prose()
                                  : .code(size: fontSize, wrapLines: true, indentSpaces: 2),
            tokenizer: tokenizer,
            mathRenderer: TypstMathRenderer.shared,
            completionProvider: fileURL.map(TypstCompletionProvider.init),
            controller: editor
        )
        .id(nodeID)
        .clipped()
        .onChange(of: text) {
            guard loadedNode == nodeID else { return }
            scheduleCompile(delay: .milliseconds(400))
            if mode.autosaves { scheduleAutosave() }
        }
    }

    /// Compute a formatting edit against the live text/selection and apply it.
    private func applyFormat(_ makeEdit: (String, NSRange) -> TypstEdit.Edit) {
        guard let (currentText, selection) = editor.textAndSelection() else { return }
        let edit = makeEdit(currentText, selection)
        editor.applyEdit(range: edit.range, replacement: edit.replacement,
                         selection: edit.selection)
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
        if let preview {
            PDFPreview(document: preview)
        } else if hasErrors {
            ContentUnavailableView("Compile Failed", systemImage: "exclamationmark.triangle",
                                   description: Text(mode == .typeset
                                        ? "Fix the errors below to see the preview."
                                        : "Open Typeset mode to see the errors."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pageBackground: NSColor {
        colorScheme == .dark ? NSColor(hex: "292A30") : NSColor(hex: "FFFFFF")
    }

    // MARK: File IO

    private var fileURL: URL? {
        guard nodeID.scheme == "file" else { return nil }
        return URL(string: nodeID.uri)
    }

    /// A phony node (section/task) was opened onto this canvas: jump to its
    /// line. The nonce guard makes each jump one-shot — re-renders and later
    /// direct opens of the same file don't replay it.
    private func handleFragment() {
        guard let fragment = host.activeFragment,
              fragment.target == nodeID,
              fragment.nonce != consumedFragment,
              loadedNode == nodeID,
              fragment.fragment.hasPrefix("line="),
              let line = Int(fragment.fragment.dropFirst("line=".count))
        else { return }
        consumedFragment = fragment.nonce
        Task { @MainActor in
            // On a fresh open the editor mounts a beat after the canvas —
            // wait for it (bounded), then jump. No editor in Read mode: no-op.
            for _ in 0..<10 where editor.textAndSelection() == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            editor.moveCursor(toLine: line, column: 1)
        }
    }

    /// The document's *file node* — what change notifications must target, even
    /// when this canvas was opened via a section/task node.
    private var fileNodeID: NodeID? {
        fileURL.flatMap { NodeID($0.absoluteString) }
    }

    private func load() async {
        loadError = nil
        preview = nil
        previewData = nil
        diagnostics = []
        guard let url = fileURL else { loadError = "Not a file."; return }
        do {
            // Off-main: a large document must not stall the app loop while the
            // canvas's own ProgressView is showing.
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

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, dirty else { return }
            saveToDisk()
        }
    }

    private func saveToDisk() {
        guard let url = fileURL, dirty else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            // childrenChanged too: the document's contributed outline (sections,
            // tasks) may have changed shape with the edit.
            if let fileNodeID {
                host.notify([.modified(fileNodeID), .childrenChanged(fileNodeID)])
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Compilation

    private func scheduleCompile(delay: Duration) {
        compileTask?.cancel()
        guard let url = fileURL else { return }
        let source = text
        compileTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            compiling = true
            let output = await TypstEngine.compile(source: source, documentURL: url)
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
        // typst reports 1-based lines, 0-based columns; the editor is 1-based.
        editor.moveCursor(toLine: line, column: (diagnostic.column ?? 0) + 1)
    }

}

// MARK: - Document inspector (links + backlinks)

/// The graph-y side of a document, stacked under the FileSystem inspector: what it
/// includes/imports, and which documents point back at it.
struct TypstDocumentInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    @State private var links: [URL] = []
    @State private var backlinks: [URL] = []
    @State private var loaded = false
    @State private var wordCount: Int?
    private let uiState = TypstUIState.shared

    private var fileURL: URL? {
        nodeID.scheme == "file" ? URL(string: nodeID.uri) : nil
    }

    var body: some View {
        Form {
            // The manipulation surface for what the chrome-free canvas dropped:
            // mode switching (also actions, \u{2325}\u{2318}1/2/3) and stats.
            Section("Document") {
                Picker("Mode", selection: Binding(
                    get: { uiState.mode(for: fileURL) },
                    set: { uiState.setMode($0, for: fileURL) })) {
                    ForEach(TypstMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if let wordCount {
                    let minutes = max(1, Int((Double(wordCount) / 200).rounded()))
                    LabeledContent("Words", value: "\(wordCount) \u{00B7} ~\(minutes) min")
                }
            }
            if !links.isEmpty {
                Section("Links") { rows(links) }
            }
            if !backlinks.isEmpty {
                Section("Backlinks") { rows(backlinks) }
            }
            if loaded && links.isEmpty && backlinks.isEmpty {
                Section("Document") {
                    Text("No links to or from this document.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: nodeID) {
            await countWords()
            await reload()
        }
    }

    private func countWords() async {
        guard let url = fileURL else { return }
        wordCount = await Task.detached {
            (try? String(contentsOf: url, encoding: .utf8))?
                .split { $0.isWhitespace || $0.isNewline }.count
        }.value
    }

    private func rows(_ urls: [URL]) -> some View {
        ForEach(urls, id: \.absoluteString) { url in
            Button {
                host.openURI(url.absoluteString)
            } label: {
                Label(url.deletingPathExtension().lastPathComponent,
                      systemImage: "doc.text")
                    .lineLimit(1)
            }
        }
    }

    private func reload() async {
        loaded = false
        guard nodeID.scheme == "file", let file = URL(string: nodeID.uri) else { return }
        let result = await Task.detached(priority: .utility) { () -> ([URL], [URL]) in
            let base = file.deletingLastPathComponent()
            let forward = (try? String(contentsOf: file, encoding: .utf8))
                .map(TypstStructure.links(of:))?
                .map { URL(fileURLWithPath: $0, relativeTo: base).standardizedFileURL }
                .filter { FileManager.default.fileExists(atPath: $0.path) } ?? []
            let back = TypstStructure.backlinks(to: file, under: base)
            return (forward, back)
        }.value
        links = result.0
        backlinks = result.1
        loaded = true
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

// MARK: - Helpers

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
