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

    private var sourceStyle: TypstSourceStyle { uiState.sourceStyle(for: fileURL) }

    /// What compiling this document produced. Owned by the document, not by
    /// this view: the preview is another pane on the same thing, and a canvas
    /// that owned the output would mean two compiles or a preview that only
    /// worked while its editor was on screen.
    private var document: TypstDocument? {
        fileURL.map { TypstUIState.shared.document(for: $0) }
    }
    private var preview: PDFDocument? { document?.preview }
    private var diagnostics: [TypstDiagnostic] { document?.diagnostics ?? [] }
    @State private var autosaveTask: Task<Void, Never>?
    @State private var consumedFragment: UUID?
    /// The file's contents when it changed on disk under unsaved edits. Blocks
    /// autosave until the reader picks a side — following an external change
    /// is one thing, silently overwriting it is another.
    @State private var conflict: String?

    private var dirty: Bool { text != savedText }
    private var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    var body: some View {
        VStack(spacing: 0) {
            if conflict != nil {
                ExternalChangeBanner(reload: takeDiskVersion, keep: { conflict = nil })
            }
            // Above the text it searches, where the change banner sits: what
            // you are looking for belongs beside the line you are reading.
            if EditorFind.shared.isActive { EditorFindBar() }
            if loadedNode != nodeID {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Can't Open", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                documentBody
            }

            if sourceStyle == .source && !diagnostics.isEmpty {
                Divider()
                DiagnosticsBar(diagnostics: diagnostics) { jump(to: $0) }
            }
            // An export's own diagnostics, in any mode — you can export from
            // Write and Read too, and a failure there was silent.
            if let report = TypstUIState.shared.exportReport(for: fileURL) {
                Divider()
                DiagnosticsBar(diagnostics: report.diagnostics) { jump(to: $0) }
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
            } else if !sourceStyle.autosaves && dirty {
                Circle().fill(.secondary).frame(width: 7, height: 7).padding(10)
                    .help("Unsaved changes — \u{2318}S")
            }
        }
        .background(hiddenShortcuts)
        .task(id: nodeID) {
            loadedNode = nil
            conflict = nil
            if let fileURL { TypstUIState.shared.retainDocument(for: fileURL) }
            await load()
            loadedNode = nodeID
            if loadError == nil { scheduleCompile(delay: .zero) }
            handleFragment()   // a phony-node open may have posted before we existed
        }
        .onChange(of: host.activeFragment) { _, _ in handleFragment() }
        .onChange(of: host.externalEdit) { _, notice in
            guard let notice, notice.node == nodeID || notice.node == fileNodeID else { return }
            Task { await reconcileWithDisk() }
        }
        .onChange(of: sourceStyle) { previous, current in
            // Entering an autosave mode (or leaving Typeset with edits pending)
            // flushes, so disk always matches what Write/Read show.
            if current.autosaves && dirty { saveToDisk() }
        }
        .onDisappear {
            if sourceStyle.autosaves && dirty && loadedNode == nodeID { saveToDisk() }
            TypstUIState.shared.releaseDocument(for: fileURL)
        }
    }

    /// The buffer's keybindings, registered invisibly: canvas chrome is gone,
    /// but these act on the live editor selection, which only the canvas can
    /// reach — they stay here rather than becoming plugin Actions.
    private var hiddenShortcuts: some View {
        HStack {
            Button("") { saveToDisk(deliberate: true) }
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
    ///
    /// The column is measured from the text rather than taken as a share of
    /// the window: a line whose length moves when the sidebar comes and goes
    /// is what makes a full-width editor tiring to read, and a fixed number of
    /// points means a different measure in every face and at every size. The
    /// width follows the type, so making the text bigger makes the column
    /// wider and the line still holds about the same number of words.
    /// One editor, set the way this document is being worked on: a manuscript
    /// column on the page colour, or the source monospaced.
    ///
    /// There were two layouts because one of them also drew the preview. The
    /// pages are the pane next door now, so what is left is a style.
    @ViewBuilder
    private var documentBody: some View {
        if sourceStyle == .prose {
            editor(fontSize: 14).background(Color(nsColor: pageBackground))
        } else {
            editor(fontSize: 12)
        }
    }

    /// The manuscript's style — the chosen face at the chosen size. Held in
    /// one place because the column's width is measured from it: the editor
    /// and the frame around it have to be describing the same text.
    private var proseStyle: EditorStyle {
        .prose(size: TypstUIState.shared.proseSize,
               family: TypstUIState.shared.proseFont.family)
    }

    private func editor(fontSize: CGFloat) -> some View {
        // Write reads like a manuscript (serif, roomy); Typeset is a code editor
        // that wraps (prose-like source).
        MaximalEditor(
            text: $text,
            style: sourceStyle == .prose
                ? proseStyle
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
            // Publish the buffer so views outside the canvas (the inspector's
            // word count) reflect what's on screen rather than what's on disk.
            scheduleCompile(delay: .milliseconds(400))
            // Taking the disk version leaves text == saved, and following a
            // file is not editing it.
            guard dirty else { return }
            host.pin(nodeID)          // this tab is work now, not a preview
            if sourceStyle.autosaves { scheduleAutosave() }
        }
    }

    /// Compute a formatting edit against the live text/selection and apply it.
    private func applyFormat(_ makeEdit: (String, NSRange) -> TypstEdit.Edit) {
        guard let (currentText, selection) = editor.textAndSelection() else { return }
        let edit = makeEdit(currentText, selection)
        editor.applyEdit(range: edit.range, replacement: edit.replacement,
                         selection: edit.selection)
    }

    private var pageBackground: NSColor {
        colorScheme == .dark ? NSColor(hex: "292A30") : NSColor(hex: "FFFFFF")
    }

    // MARK: File IO

    private var fileURL: URL? {
        guard nodeID.scheme == "file" else { return nil }
        return URL(string: nodeID.uri)
    }

    /// The folders the user mounted, which is the scope a document is allowed
    /// to import from — a file may sit several directories down and still
    /// belong to the workspace above it (see TypstProject).
    private var mountedRoots: [URL] { TypstProject.mountedRoots(in: host) }

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
        Task { @MainActor in
            // On a fresh open the editor mounts a beat after the canvas, and
            // being mounted is not the same as being scrollable — until it is
            // in a window with a laid-out scroll view, TextKit drops the
            // scroll and the jump sets a selection you cannot see. Waiting
            // only for the view to exist is why this used to take two clicks.
            for _ in 0..<20 where !editor.canScroll {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard editor.canScroll else { return }
            // Spent only on a jump that happened. Marking it consumed before
            // the attempt meant a dropped one was never retried — and the
            // second click worked because it carried a new nonce.
            consumedFragment = fragment.nonce
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

    /// The file moved under us. Follow it when nothing would be lost, and ask
    /// when something would — see `ExternalEdit` for why this compares
    /// contents rather than trusting timing.
    private func reconcileWithDisk() async {
        guard loadedNode == nodeID, let url = fileURL else { return }
        let onDisk = try? await Task.detached(priority: .userInitiated) {
            try String(contentsOf: url, encoding: .utf8)
        }.value

        switch ExternalEdit.outcome(onDisk: onDisk, buffer: text, saved: savedText) {
        case .unchanged:
            break
        case .adoptAsSaved(let contents):
            savedText = contents
        case .reload(let contents):
            takeContents(contents)
        case .conflict(let contents):
            // Stop the clock: autosave would otherwise write our version over
            // theirs a second later, before the reader has answered.
            autosaveTask?.cancel()
            conflict = contents
        @unknown default:
            break
        }
    }

    private func takeDiskVersion() {
        guard let contents = conflict else { return }
        takeContents(contents)
    }

    private func takeContents(_ contents: String) {
        // Baseline first, so the text change can't read as an edit.
        savedText = contents
        text = contents
        conflict = nil
        TypstUIState.shared.setBuffer(contents, for: fileURL)
    }

    /// - Parameter deliberate: whether the reader asked for this save (⌘S).
    ///   An unresolved conflict blocks every *automatic* save — the idle
    ///   autosave, the flush on leaving Typeset, the flush on close — because
    ///   each of them would quietly overwrite the other program's version.
    ///   Pressing ⌘S is the reader saying theirs wins, so it goes through.
    private func saveToDisk(deliberate: Bool = false) {
        guard let url = fileURL, dirty else { return }
        guard deliberate || conflict == nil else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            conflict = nil          // saving is an explicit "mine wins"
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

    /// Hand the text to the document and let it compile.
    ///
    /// The import scope goes with it: only a canvas has a host to ask, and a
    /// compile rooted at the document's own directory is the mistake the
    /// export path made — a note that includes `../notes.typ` escapes it.
    private func scheduleCompile(delay: Duration) {
        guard let document else { return }
        document.mountedRoots = mountedRoots
        document.setBuffer(text, compileAfter: delay)
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
    @State private var countTask: Task<Void, Never>?
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
                Picker("Source", selection: Binding(
                    get: { uiState.sourceStyle(for: fileURL) },
                    set: { uiState.setSourceStyle($0, for: fileURL) })) {
                    ForEach(TypstSourceStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                if let wordCount {
                    let minutes = max(1, Int((Double(wordCount) / 200).rounded()))
                    LabeledContent("Words", value: "\(wordCount) \u{00B7} ~\(minutes) min")
                }
            }
            Section("Typeface") { typefacePicker }
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
        // Reading the live buffer here registers the dependency, so an edit in
        // the canvas re-runs the count. Debounced: recounting a 30KB document
        // on every keystroke is work nobody asked for, and the number is only
        // ever read at a glance.
        .onChange(of: TypstUIState.shared.buffer(for: fileURL)) { _, _ in
            countTask?.cancel()
            countTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await countWords()
            }
        }
        .onDisappear { countTask?.cancel() }
    }

    /// The faces Write mode can be set in, each row drawn in its own — which
    /// is the only way a list of typeface names tells you anything.
    @ViewBuilder
    private var typefacePicker: some View {
        Picker("Font", selection: Binding(
            get: { uiState.proseFont },
            set: { uiState.proseFont = $0 })) {
            ForEach(ProseFont.available) { font in
                Text(font.name)
                    .font(font.family.map { Font.custom($0, size: 13) }
                          ?? .system(size: 13, design: .serif))
                    .tag(font)
            }
        }
        Text(uiState.proseFont.note)
            .font(.caption)
            .foregroundStyle(.secondary)
        // Beside the face because it is the same decision: these families are
        // not the same size at the same size.
        Stepper(value: Binding(get: { uiState.proseSize },
                               set: { uiState.proseSize = ProseSize.clamped($0) }),
                in: ProseSize.range, step: 1) {
            LabeledContent("Size", value: "\(Int(uiState.proseSize)) pt")
        }
        // Shown in every mode, and says so when it isn't in effect. Hiding it
        // outside Write mode meant finding it required already being in the
        // mode it configures — and the rest of this app greys a control out
        // rather than moving it, so a thing stays where you last saw it.
        if uiState.sourceStyle(for: fileURL) != .prose {
            Text("Applies to prose; the source is set monospaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Words in the document as it currently reads. Prefers the open buffer —
    /// disk lags by an autosave, and an unsaved edit is exactly when the count
    /// is being watched — and falls back to the file for documents that have no
    /// canvas open (selected in the sidebar, never opened).
    private func countWords() async {
        if let live = TypstUIState.shared.buffer(for: fileURL) {
            wordCount = await Task.detached { TypstStructure.wordCount(of: live) }.value
            return
        }
        guard let url = fileURL else { return }
        wordCount = await Task.detached {
            (try? String(contentsOf: url, encoding: .utf8))
                .map(TypstStructure.wordCount(of:))
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

/// A document's rendered pages, as a canvas of its own.
///
/// The other half of the split, and the reason the preview is a node: two
/// panes on two names for one document, rather than one canvas drawing both
/// halves and multiplexing a single key map between them.
///
/// It compiles nothing itself — the document does — but it does make sure a
/// compile has happened, because the pages may be opened without the editor
/// ever having been.
struct TypstPreviewCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @Environment(\.colorScheme) private var colorScheme

    private var fileURL: URL? { TypstRef(uri: nodeID.uri).map(\.fileURL) }
    private var document: TypstDocument? {
        fileURL.map { TypstUIState.shared.document(for: $0) }
    }

    var body: some View {
        Group {
            if let preview = document?.preview {
                PDFPreview(document: preview, dark: colorScheme == .dark)
            } else if document?.hasErrors == true {
                ContentUnavailableView(
                    "Compile Failed", systemImage: "exclamationmark.triangle",
                    description: Text("The errors are on the source, beside this."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: nodeID) {
            if let fileURL { TypstUIState.shared.retainDocument(for: fileURL) }
            await ensureCompiled()
        }
        .onDisappear { TypstUIState.shared.releaseDocument(for: fileURL) }
    }

    /// Pages for a document nothing has opened for editing.
    ///
    /// Read mode is this canvas alone, so the buffer may be empty and no
    /// compile scheduled. Reading the file here is not the editor's job being
    /// duplicated — the editor publishes what is on screen, and this is what
    /// to show when there is no screen with it on.
    private func ensureCompiled() async {
        guard let url = fileURL, let document else { return }
        document.mountedRoots = TypstProject.mountedRoots(in: host)
        guard document.preview == nil else { return }
        if document.buffer.isEmpty {
            let text = await Task.detached(priority: .userInitiated) {
                (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }.value
            document.setBuffer(text, compileAfter: .zero)
        } else {
            document.compile()
        }
    }
}

// MARK: - PDF preview

/// PDFKit-backed preview that keeps the reader's place: on recompile it swaps the
/// document and restores the previous destination instead of jumping to page 1.
private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    /// Invert the page in dark mode — see PDFAppearance.
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastDocument: PDFDocument?
        /// PDFKit's own background, so light mode looks untouched.
        var defaultBackground: NSColor?
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        context.coordinator.defaultBackground = view.backgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Before the document check: the appearance can change on its own,
        // with the same document still on screen.
        PDFAppearance.apply(dark: dark, to: view,
                            defaultBackground: context.coordinator.defaultBackground)
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
