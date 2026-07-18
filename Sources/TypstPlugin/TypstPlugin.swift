import SwiftUI
import AppKit
import PDFKit
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages
import MaximalTreeKit

/// Typst as a daily driver: one canvas, three modes.
///
/// - **Write** — notes/prose: editor only, centered column, word count, autosave.
///   The compiler runs silently (so Read/Typeset are instant); errors are a dot,
///   not a strip.
/// - **Typeset** — the IDE: editor + live preview + diagnostics, explicit ⌘S.
/// - **Read** — rendered document only, autosave-safe.
///
/// The mode is remembered per file. Conventions (tasks, tags) are typst-native via
/// the bundled `@local/mtnotes` package, installed into typst's data directory at
/// plugin load — documents render correctly with plain `typst compile` anywhere.
@objc(TypstPlugin)
final class TypstPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        // Make `@local/mtnotes` importable before any compile can need it.
        Task.detached(priority: .utility) {
            do { try TypstNotes.installPackage() }
            catch { NSLog("[TypstPlugin] package install failed: \(error.localizedDescription)") }
        }

        registry.register(canvas: CanvasContribution(
            priority: 150,     // above TextEditor (100): .typ is text, but ours is better
            matches: { node in
                node.id.scheme == "file" && node.id.uri.lowercased().hasSuffix(".typ")
            },
            make: { id, host in AnyView(TypstCanvas(nodeID: id).environment(host)) }
        ))

        // Structure: sections/tasks under .typ files, and the mountable agenda.
        registry.register(provider: TypstProvider())
        registry.register(children: ChildContribution(
            matches: { node in
                node.id.scheme == "file" && node.id.uri.lowercased().hasSuffix(".typ")
            },
            children: { id in
                guard let url = URL(string: id.uri) else { return [] }
                let items = TypstProvider.outline(ofFileAt: url)
                return TypstStructure.directChildren(ofSectionAt: nil, in: items).map {
                    TypstProvider.node(for: $0, file: url, items: items)
                }
            }
        ))

        // Opening a section or task opens its document at the right line.
        registry.register(canvas: CanvasContribution(
            priority: 150,
            matches: { $0.type == TypeID("typst.section") || $0.type == TypeID("typst.task") },
            make: { id, host in
                let node = host.node(id)
                var file: URL? = TypstRef(uri: id.uri).map(\.fileURL)
                if case .string(let path)? = node?.attributes["file"] {
                    file = URL(string: path) ?? file
                }
                var line: Int?
                if case .int(let l)? = node?.attributes["line"] { line = l }
                return AnyView(TypstCanvas(nodeID: id, fileURLOverride: file,
                                           initialLine: line).environment(host))
            }
        ))
        registry.register(canvas: CanvasContribution(
            priority: 150,
            matches: { $0.type == TypeID("typst.agenda") },
            make: { id, host in AnyView(AgendaCanvas(nodeID: id).environment(host)) }
        ))
        registry.register(inspector: InspectorContribution(
            matches: { $0.type == TypeID("typst.task") },
            make: { id, host in AnyView(TaskInspector(nodeID: id).environment(host)) }
        ))
        // Stacks with the FileSystem plugin's file inspector — composition at work.
        registry.register(inspector: InspectorContribution(
            matches: { node in
                node.id.scheme == "file" && node.id.uri.lowercased().hasSuffix(".typ")
            },
            make: { id, host in AnyView(TypstDocumentInspector(nodeID: id).environment(host)) }
        ))

        registry.register(action: Action(
            id: "typst.notesFolder",
            title: "Use as Typst Notes Folder",
            systemImage: "calendar.badge.plus",
            appliesTo: .type(TypeID("file.directory")),
            handler: { ctx in
                guard let dir = ctx.selection.first, dir.scheme == "file",
                      let url = URL(string: dir.uri) else { return }
                // Mounts the agenda as a workspace root — the folder *is* the config.
                ctx.host.mount(TypstRef.agenda(dir: url.path).uri)
            }
        ))

        registry.register(action: Action(
            id: "typst.newNote",
            title: "New Typst Note",
            systemImage: "square.and.pencil",
            appliesTo: .type(TypeID("file.directory")),
            handler: { ctx in Self.createNote(in: ctx, daily: false) }
        ))
        registry.register(action: Action(
            id: "typst.dailyNote",
            title: "Today's Daily Note",
            systemImage: "calendar",
            appliesTo: .type(TypeID("file.directory")),
            handler: { ctx in Self.createNote(in: ctx, daily: true) }
        ))
    }

    /// Create (or, for the daily note, reuse) a templated note in the selected
    /// directory, tell the host, and open it.
    @MainActor
    private static func createNote(in ctx: ActionContext, daily: Bool) {
        guard let dir = ctx.selection.first, dir.scheme == "file",
              let dirURL = URL(string: dir.uri) else { return }
        let noteURL = daily ? TypstNotes.dailyNoteURL(in: dirURL)
                            : TypstNotes.newNoteURL(in: dirURL)
        if !FileManager.default.fileExists(atPath: noteURL.path) {
            let template = daily ? TypstNotes.dailyNoteTemplate()
                                 : TypstNotes.noteTemplate(title: "Untitled")
            do { try template.write(to: noteURL, atomically: true, encoding: .utf8) }
            catch {
                NSLog("[TypstPlugin] note creation failed: \(error.localizedDescription)")
                return
            }
            ctx.host.notify([.childrenChanged(dir)])
        }
        ctx.host.openURI(noteURL.absoluteString)
    }
}

// MARK: - Mode

enum TypstMode: String, CaseIterable, Identifiable {
    case write, typeset, read
    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: return "Write"
        case .typeset: return "Typeset"
        case .read: return "Read"
        }
    }

    /// Write and Read behave like a notes app (autosave); Typeset keeps explicit
    /// save points.
    var autosaves: Bool { self != .typeset }

    // Keyed by the *file*, not the opened node, so a document keeps its mode
    // whether opened directly or through one of its section/task nodes.
    static func stored(forFile url: URL?) -> TypstMode {
        guard let url else { return .write }
        return UserDefaults.standard.string(forKey: "typst.mode.\(url.absoluteString)")
            .flatMap(TypstMode.init(rawValue:)) ?? .write
    }

    func store(forFile url: URL?) {
        guard let url else { return }
        UserDefaults.standard.set(rawValue, forKey: "typst.mode.\(url.absoluteString)")
    }
}

// MARK: - Canvas

struct TypstCanvas: View {
    let nodeID: NodeID
    /// Set when the opened node is a section/task: the document it lives in.
    var fileURLOverride: URL? = nil
    /// Jump the cursor here after loading (section/task navigation).
    var initialLine: Int? = nil
    @Environment(HostContext.self) private var host
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    @State private var savedText = ""
    @State private var loadedNode: NodeID?
    @State private var loadError: String?
    @State private var editorState = SourceEditorState()
    @State private var highlighter = TypstHighlighter()
    @State private var editing = TypstEditingCoordinator()
    @State private var mode: TypstMode = .write

    @State private var preview: PDFDocument?
    @State private var previewData: Data?
    @State private var diagnostics: [TypstDiagnostic] = []
    @State private var compiling = false
    @State private var showPreview = true
    @State private var editorFraction: CGFloat = 0.5
    @State private var compileTask: Task<Void, Never>?
    @State private var autosaveTask: Task<Void, Never>?

    private var dirty: Bool { text != savedText }
    private var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

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
        .task(id: nodeID) {
            loadedNode = nil
            mode = TypstMode.stored(forFile: fileURL)
            load()
            loadedNode = nodeID
            if loadError == nil {
                scheduleCompile(delay: .zero)
                if let initialLine {
                    editorState.cursorPositions = [CursorPosition(line: initialLine, column: 1)]
                }
            }
        }
        .onChange(of: mode) { previous, current in
            current.store(forFile: fileURL)
            // Entering an autosave mode (or leaving Typeset with edits pending)
            // flushes, so disk always matches what Write/Read show.
            if current.autosaves && dirty { saveToDisk() }
        }
        .onDisappear {
            if mode.autosaves && dirty && loadedNode == nodeID { saveToDisk() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(host.node(nodeID)?.label ?? "")
                .font(.headline)
                .lineLimit(1)
            if mode == .typeset && dirty {
                Text("Edited").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            switch mode {
            case .write:
                if hasErrors {
                    Button {
                        mode = .typeset
                    } label: {
                        Circle().fill(.red).frame(width: 8, height: 8)
                    }
                    .buttonStyle(.plain)
                    .help("Compile errors — open Typeset mode")
                }
                Text(wordCountSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                formatMenu
            case .typeset:
                if compiling { ProgressView().controlSize(.small) }
                if let preview {
                    Text("\(preview.pageCount) page\(preview.pageCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                formatMenu
                exportMenu
                Toggle(isOn: $showPreview) {
                    Image(systemName: "sidebar.squares.trailing")
                }
                .toggleStyle(.button)
                .help("Show preview")
                Button("Save", action: saveToDisk)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty)
            case .read:
                if let preview {
                    Text("\(preview.pageCount) page\(preview.pageCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                exportMenu
            }

            Picker("Mode", selection: $mode) {
                ForEach(TypstMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .labelsHidden()
        }
        .padding(8)
    }

    /// Prose keybindings. Menu items register their key equivalents window-wide, so
    /// ⌘B/⌘I/⌘E/⇧⌘T work while typing without opening the menu.
    private var formatMenu: some View {
        Menu {
            Button("Bold") { editing.apply { TypstEdit.toggleWrap("*", in: $0, selection: $1) } }
                .keyboardShortcut("b", modifiers: .command)
            Button("Emphasis") { editing.apply { TypstEdit.toggleWrap("_", in: $0, selection: $1) } }
                .keyboardShortcut("i", modifiers: .command)
            Button("Raw") { editing.apply { TypstEdit.toggleWrap("`", in: $0, selection: $1) } }
                .keyboardShortcut("e", modifiers: .command)
            Divider()
            Button("Insert Task") { editing.apply { TypstEdit.insertTask(in: $0, selection: $1) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var exportMenu: some View {
        Menu {
            ForEach(TypstCompiler.ExportFormat.allCases, id: \.self) { format in
                Button(format.title) { export(format) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!TypstCompiler.isAvailable)
        .help("Export the document")
    }

    private var wordCountSummary: String {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let minutes = max(1, Int((Double(words) / 200).rounded()))
        return "\(words) words · ~\(minutes) min"
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
            let available = max(geo.size.width - (showPreview ? handle : 0), 1)
            let editorWidth = showPreview
                ? min(max(available * editorFraction, 200), max(available - 200, 200))
                : geo.size.width

            HStack(spacing: 0) {
                editor(fontSize: 12).frame(width: editorWidth)
                if showPreview {
                    divider(available: available)
                    previewColumn.frame(maxWidth: .infinity)
                }
            }
            .coordinateSpace(name: "typst-split")
        }
    }

    /// Write mode reads like a manuscript (system serif, roomier leading); Typeset
    /// stays a code editor (monospace).
    private var editorFont: NSFont {
        guard mode == .write else { return .monospacedSystemFont(ofSize: 12, weight: .regular) }
        let size: CGFloat = 15
        let base = NSFont.systemFont(ofSize: size)
        if let descriptor = base.fontDescriptor.withDesign(.serif),
           let serif = NSFont(descriptor: descriptor, size: size) {
            return serif
        }
        return base
    }

    private func editor(fontSize: CGFloat) -> some View {
        SourceEditor(
            $text,
            language: .default,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: colorScheme == .dark ? .typstDark : .typstLight,
                    font: editorFont,
                    lineHeightMultiple: mode == .write ? 1.5 : 1.2,
                    wrapLines: true
                ),
                behavior: .init(indentOption: .spaces(count: 2))
            ),
            state: $editorState,
            highlightProviders: [highlighter],
            coordinators: [editing]
        )
        .id(nodeID)
        .clipped()
        .onChange(of: text) {
            guard loadedNode == nodeID else { return }
            scheduleCompile(delay: .milliseconds(400))
            if mode.autosaves { scheduleAutosave() }
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
        if let fileURLOverride { return fileURLOverride }
        guard nodeID.scheme == "file" else { return nil }
        return URL(string: nodeID.uri)
    }

    /// The document's *file node* — what change notifications must target, even
    /// when this canvas was opened via a section/task node.
    private var fileNodeID: NodeID? {
        fileURL.flatMap { NodeID($0.absoluteString) }
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

    private func export(_ format: TypstCompiler.ExportFormat) {
        guard let documentURL = fileURL else { return }
        let panel = NSSavePanel()
        switch format {
        case .pdf: panel.allowedContentTypes = [.pdf]
        case .svg: panel.allowedContentTypes = [.svg]
        case .png: panel.allowedContentTypes = [.png]
        }
        let stem = (host.node(nodeID)?.label as NSString?)?.deletingPathExtension ?? "document"
        panel.nameFieldStringValue = "\(stem).\(format.rawValue)"
        if format.isPaged {
            panel.message = "Multi-page documents export one \(format.title) per page."
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let source = text
        Task {
            let exportDiagnostics = await TypstCompiler.export(
                source: source, documentURL: documentURL, format: format, to: destination)
            if exportDiagnostics.contains(where: { $0.severity == .error }) {
                diagnostics = exportDiagnostics    // surface in the Typeset strip
                mode = .typeset
            }
        }
    }
}

// MARK: - Editing coordinator

/// Bridges the Format commands to the live text view. Edits go through
/// `replaceCharacters` (undo-registered) with the selection placed afterward, so
/// ⌘B/⌘I behave like a word processor's.
final class TypstEditingCoordinator: TextViewCoordinator {
    private weak var controller: TextViewController?

    func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    func destroy() { controller = nil }

    @MainActor
    func apply(_ makeEdit: (String, NSRange) -> TypstEdit.Edit) {
        guard let textView = controller?.textView else { return }
        let selection = textView.selectionManager.textSelections.first?.range
            ?? NSRange(location: 0, length: 0)
        let edit = makeEdit(textView.string, selection)
        textView.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.selectionManager.setSelectedRange(edit.selection)
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

    var body: some View {
        Form {
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
        .task(id: nodeID) { await reload() }
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
            types: Attribute(color: NSColor(hex: "0B4F79"), bold: true),
            attributes: Attribute(color: NSColor(hex: "815F03")),
            variables: Attribute(color: NSColor(hex: "0F68A0"), italic: true),
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
            types: Attribute(color: NSColor(hex: "6BDFFF"), bold: true),
            attributes: Attribute(color: NSColor(hex: "CC9768")),
            variables: Attribute(color: NSColor(hex: "4EB0CC"), italic: true),
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
