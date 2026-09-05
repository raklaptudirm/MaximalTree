import SwiftUI
import AppKit
import PDFKit
import MaximalEditorKit
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
        // Before anything can compile: @preview packages are downloaded on
        // demand, and the engine can only do that through the host.
        TypstPackages.install()

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
            // First open pays the engine's system font scan (off the main
            // actor) and the highlighter's JS load (main, but behind the host's
            // loading indicator) — never inside a paint.
            prepare: { _ in
                TypstEngine.warmUp()
                await SyntaxTokenizer.warmUp()
            },
            // The editor's own keys, plus the two this canvas adds: `z` is
            // where a surface keeps how big or how it looks, here and in the
            // page and the terminal.
            keys: EditorKeys.keys + [SurfaceKey("z f", "typst.proseFont.next"),
                                     SurfaceKey("z F", "typst.proseFont.previous"),
                                     SurfaceKey("z i", "typst.proseSize.bigger"),
                                     SurfaceKey("z o", "typst.proseSize.smaller"),
                                     SurfaceKey("z 0", "typst.proseSize.reset")],
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

        // Sections and tasks are *phony* nodes (NodeAnchor): the host resolves
        // an open to the file node's one canvas and posts a "line=N" fragment —
        // no per-heading canvas, no per-heading editing buffer.
        // The document's pages, under their own name. Phase 3 puts this beside
        // the editor; today it is a pane of its own.
        registry.register(canvas: CanvasContribution(
            priority: 150,
            matches: { $0.type == TypeID("typst.preview") },
            prepare: { _ in TypstEngine.warmUp() },
            make: { id, host in AnyView(TypstPreviewCanvas(nodeID: id).environment(host)) }
        ))
        registry.register(canvas: CanvasContribution(
            priority: 150,
            matches: { $0.type == TypeID("typst.agenda") },
            prepare: { _ in TypstEngine.warmUp() },
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
            scope: .container,
            handler: { ctx in
                guard let dir = ctx.selection.first, dir.scheme == "file",
                      let url = URL(string: dir.uri) else { return }
                // Mounts the agenda as a workspace root — the folder *is* the config.
                ctx.host.mount(TypstRef.agenda(dir: url.path).uri)
            }
        ))

        // The canvas is content-only: modes, export, and agenda refresh are
        // Actions — menu bar (with shortcuts), palette, context menu — plus a
        // mode picker in the document inspector.
        let modeShortcuts: [(TypstMode, KeyEquivalent, String)] = [
            (.write, "1", "square.and.pencil"),
            (.typeset, "2", "doc.richtext"),
        ]
        for (mode, key, image) in modeShortcuts {
            registry.register(action: Action(
                id: "typst.mode.\(mode.rawValue)",
                title: "Typst: \(mode.title) Mode",
                systemImage: image,
                appliesTo: .custom { Self.typFileURL(in: $0) != nil },
                shortcut: KeyboardShortcut(key, modifiers: [.command, .option]),
                scope: .document,
                handler: { ctx in
                    guard let url = Self.typFileURL(in: ctx) else { return }
                    TypstUIState.shared.setMode(mode, for: url)
                    // Typesetting means seeing what you are typesetting: the
                    // pages go in the pane next door, reusing one that already
                    // has them. The keyboard stays in the source.
                    if mode == .typeset {
                        ctx.host.openURIBeside(TypstRef.preview(file: url.path).uri)
                    }
                }
            ))
        }

        // Trying a face means reading your own prose in it, so stepping
        // through them beats opening a picker each time. Only in Write mode:
        // anywhere else this changes nothing you can see.
        for (id, title, image, step) in [
            ("typst.proseFont.next", "Next Prose Typeface", "textformat", 1),
            ("typst.proseFont.previous", "Previous Prose Typeface", "textformat", -1),
        ] as [(String, String, String, Int)] {
            registry.register(action: Action(
                id: id, title: title, systemImage: image,
                appliesTo: .custom(Self.isWriting), scope: .document,
                handler: { _ in TypstUIState.shared.cycleProseFont(by: step) }
            ))
        }

        for (id, title, image, step) in [
            ("typst.proseSize.bigger", "Bigger Prose Text", "textformat.size.larger", 1),
            ("typst.proseSize.smaller", "Smaller Prose Text", "textformat.size.smaller", -1),
        ] as [(String, String, String, CGFloat)] {
            registry.register(action: Action(
                id: id, title: title, systemImage: image,
                appliesTo: .custom(Self.isWriting), scope: .document,
                handler: { _ in TypstUIState.shared.stepProseSize(by: step) }
            ))
        }
        registry.register(action: Action(
            id: "typst.proseSize.reset", title: "Reset Prose Text Size",
            systemImage: "textformat.size",
            appliesTo: .custom(Self.isWriting), scope: .document,
            handler: { _ in TypstUIState.shared.proseSize = ProseSize.standard }
        ))

        for format in TypstEngine.ExportFormat.allCases {
            registry.register(action: Action(
                id: "typst.export.\(format.rawValue)",
                title: "Export as \(format.title)",
                systemImage: "square.and.arrow.up",
                appliesTo: .custom { Self.typFileURL(in: $0) != nil },
                scope: .document,
                handler: { ctx in Self.export(format, in: ctx) }
            ))
        }

        registry.register(action: Action(
            id: "typst.preview",
            title: "Show Pages",
            systemImage: "book",
            appliesTo: .custom { Self.typFileURL(in: $0) != nil },
            // Where Read mode's key went: it opens the document's pages,
            // which is what reading it was.
            shortcut: KeyboardShortcut("3", modifiers: [.command, .option]),
            scope: .document,
            handler: { ctx in
                guard let url = Self.typFileURL(in: ctx) else { return }
                ctx.host.openURI(TypstRef.preview(file: url.path).uri)
            }
        ))

        registry.register(action: Action(
            id: "typst.agenda.refresh",
            title: "Refresh Agenda",
            systemImage: "arrow.clockwise",
            appliesTo: .type(TypeID("typst.agenda")),
            shortcut: KeyboardShortcut("r", modifiers: .command),
            scope: .workspace,
            handler: { ctx in
                TypstUIState.shared.agendaRefresh += 1
                for id in ctx.targets { ctx.host.notify([.childrenChanged(id)]) }
            }
        ))

        registry.register(action: Action(
            id: "typst.newNote",
            title: "New Typst Note",
            systemImage: "square.and.pencil",
            appliesTo: .type(TypeID("file.directory")),
            scope: .container,
            handler: { ctx in Self.createNote(in: ctx, daily: false) }
        ))
        registry.register(action: Action(
            id: "typst.dailyNote",
            title: "Today's Daily Note",
            systemImage: "calendar",
            appliesTo: .type(TypeID("file.directory")),
            scope: .container,
            handler: { ctx in Self.createNote(in: ctx, daily: true) }
        ))
    }

    /// The `.typ` file the action context points at (selection first, then
    /// focus — phony-node opens resolve both to the real file node).
    @MainActor
    static func typFileURL(in ctx: ActionContext) -> URL? {
        guard let id = ctx.selection.first ?? ctx.focused,
              id.scheme == "file", id.uri.lowercased().hasSuffix(".typ")
        else { return nil }
        return URL(string: id.uri)
    }

    /// Whether the context is a document currently being written — which is
    /// the only mode where the prose face and size are visible, and so the
    /// only one where changing them is an operation that does anything.
    @MainActor
    static func isWriting(_ ctx: ActionContext) -> Bool {
        guard let url = typFileURL(in: ctx) else { return false }
        return TypstUIState.shared.mode(for: url) == .write
    }

    /// Export the document *as saved on disk* (Write/Read autosave, so this is
    /// current; in Typeset, ⌘S first).
    @MainActor
    static func export(_ format: TypstEngine.ExportFormat, in ctx: ActionContext) {
        guard let url = typFileURL(in: ctx),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        // The same scope the preview compiles in. Without it the project root
        // is the document's own directory, and anything the document reaches
        // for above itself — `../notes.typ` — escapes it.
        let roots = TypstProject.mountedRoots(in: ctx.host)
        let panel = NSSavePanel()
        switch format {
        case .pdf: panel.allowedContentTypes = [.pdf]
        case .svg: panel.allowedContentTypes = [.svg]
        case .png: panel.allowedContentTypes = [.png]
        }
        panel.nameFieldStringValue =
            url.deletingPathExtension().lastPathComponent + ".\(format.rawValue)"
        if format == .png {
            panel.message = "Multi-page documents export one PNG per page."
        }
        // Off this runloop turn: the action may have come from a menu item or
        // the palette, and running a modal panel while AppKit is still
        // dismissing one of those is how a save panel fails to appear at all.
        DispatchQueue.main.async {
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                let diagnostics = await TypstEngine.export(
                    source: source, documentURL: url,
                    format: format, to: destination, mountedRoots: roots)
                // What the engine said, kept rather than dropped. The canvas
                // shows it; without this an export that could not compile and
                // one that wrote a file were the same silence.
                TypstUIState.shared.exportReport = TypstUIState.ExportReport(
                    document: url, destination: destination, diagnostics: diagnostics)
                if diagnostics.contains(where: { $0.severity == .error }) {
                    NSLog("[TypstPlugin] export to \(destination.path) failed: "
                          + diagnostics.map(\.message).joined(separator: "; "))
                }
            }
        }
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

