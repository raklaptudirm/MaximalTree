import Foundation
import MaximalTreeKit

/// Typst's half that needs no window: the engine and its packages, documents'
/// sections and tasks as nodes, the agenda, and what can be done to notes with
/// nothing but the disk — use a folder for them, make one, make today's, open
/// a document's pages.
///
/// What a host with no window registers, and the first thing the Mac plugin
/// does. How a document is shown — prose or source, which typeface, how big —
/// and exporting it through a save panel are the shell's.
enum TypstCore {
    /// - Parameter onAgendaChanged: told when a watched agenda's files change,
    ///   so a shell showing it can redraw.
    @MainActor
    static func register(with registry: CoreRegistry,
                         onAgendaChanged: @escaping @Sendable () -> Void = {}) {
        // Structure: sections/tasks under .typ files, and the mountable agenda.
        registry.register(provider: TypstProvider(onAgendaChanged: onAgendaChanged))
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

        registry.register(action: Action(
            id: "typst.notesFolder",
            title: "Use as Typst Notes Folder",
            systemImage: "calendar.badge.plus",
            appliesTo: .type(.directory),
            scope: .container,
            run: { ctx in
                guard let dir = ctx.selection.first, dir.scheme == "file",
                      let url = URL(string: dir.uri) else { return }
                // Mounts the agenda as a workspace root — the folder *is* the config.
                ctx.mount(TypstRef.agenda(dir: url.path).uri)
            }
        ))

        registry.register(action: Action(
            id: "typst.preview",
            title: "Show Pages",
            systemImage: "book",
            appliesTo: .custom { typFileURL(in: $0) != nil },
            // Where Read mode's key went: it opens the document's pages,
            // which is what reading it was.
            shortcut: KeyChord("3", option: true, command: true),
            scope: .document,
            run: { ctx in
                guard let url = typFileURL(in: ctx) else { return }
                ctx.host.openURI(TypstRef.preview(file: url.path).uri)
            }
        ))

        registry.register(action: Action(
            id: "typst.newNote",
            title: "New Typst Note",
            systemImage: "square.and.pencil",
            appliesTo: .type(.directory),
            scope: .container,
            run: { ctx in createNote(in: ctx, daily: false) }
        ))
        registry.register(action: Action(
            id: "typst.dailyNote",
            title: "Today's Daily Note",
            systemImage: "calendar",
            appliesTo: .type(.directory),
            scope: .container,
            run: { ctx in createNote(in: ctx, daily: true) }
        ))
    }

    /// Ready the engine to compile: before anything can, @preview packages
    /// have to be fetchable — the engine downloads them on demand, and only
    /// through the host — and `@local/mtnotes` has to be installed where typst
    /// looks for it. Apart from `register`, which says what the plugin is and
    /// writes nothing anywhere.
    static func installPackages() {
        TypstPackages.install()
        Task.detached(priority: .utility) {
            do { try TypstNotes.installPackage() }
            catch { NSLog("[TypstPlugin] package install failed: \(error.localizedDescription)") }
        }
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
            ctx.notify([.childrenChanged(dir)])
        }
        ctx.host.openURI(noteURL.absoluteString)
    }
}
