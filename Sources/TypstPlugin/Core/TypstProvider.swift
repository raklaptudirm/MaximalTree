import Foundation
import MaximalTreeKit

/// Vends Typst document *structure* as nodes: sections and tasks (contributed as
/// children of `.typ` file nodes), and the mountable agenda that collects tasks
/// across a folder. This is the org-mode half of the plugin — the document stays
/// the single source of truth, and toggling a task rewrites its source.
struct TypstProvider: NodeProvider {
    let schemes: Set<String> = ["typst"]

    /// Told when a watched agenda's files change, beyond the listing — a shell
    /// with the agenda on screen redraws it. With no shell, nothing more to do.
    private let onAgendaChanged: @Sendable () -> Void

    init(onAgendaChanged: @escaping @Sendable () -> Void = {}) {
        self.onAgendaChanged = onAgendaChanged
    }

    func resolve(_ uri: String) -> NodeID? {
        guard let ref = TypstRef(uri: uri) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ref.path, isDirectory: &isDirectory)
        else { return nil }
        switch ref.kind {
        case .agenda: guard isDirectory.boolValue else { return nil }
        case .section, .task, .preview: guard !isDirectory.boolValue else { return nil }
        }
        return NodeID(ref.uri)
    }

    func node(for id: NodeID) async -> Node? {
        guard let ref = TypstRef(uri: id.uri) else { return nil }
        switch ref.kind {
        case .preview:
            return Self.previewNode(file: ref.fileURL)
        case .agenda:
            return Self.agendaNode(dir: ref.fileURL)
        case .section, .task:
            let items = Self.outline(ofFileAt: ref.fileURL)
            if ref.kind == .section {
                guard case .section(let section)? = items.first(where: {
                    if case .section(let s) = $0 { return s.line == ref.line }
                    return false
                }) else { return nil }
                return Self.sectionNode(section, file: ref.fileURL, items: items)
            } else {
                guard case .task(let task)? = items.first(where: {
                    if case .task(let t) = $0 { return t.index == ref.index }
                    return false
                }) else { return nil }
                return Self.taskNode(task, file: ref.fileURL)
            }
        }
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard let ref = TypstRef(uri: id.uri) else { return Page(items: []) }
        switch ref.kind {
        case .task, .preview:
            return Page(items: [])
        case .section:
            let items = Self.outline(ofFileAt: ref.fileURL)
            let children = TypstStructure.directChildren(ofSectionAt: ref.line, in: items)
            return Page(items: children.map { Self.node(for: $0, file: ref.fileURL, items: items) })
        case .agenda:
            return await Task.detached(priority: .userInitiated) {
                Page(items: Self.agendaTasks(under: ref.fileURL).map { file, task in
                    Self.taskNode(task, file: file)
                })
            }.value
        }
    }

    // MARK: Node builders (shared with the child contribution)

    static func outline(ofFileAt url: URL) -> [TypstStructure.Item] {
        TypstStructure.outline(ofFileAt: url)
    }

    static func node(for item: TypstStructure.Item, file: URL,
                     items: [TypstStructure.Item]) -> Node {
        switch item {
        case .section(let section): return sectionNode(section, file: file, items: items)
        case .task(let task): return taskNode(task, file: file)
        }
    }

    static func sectionNode(_ section: TypstStructure.Section, file: URL,
                            items: [TypstStructure.Item]) -> Node {
        let ref = TypstRef.section(file: file.path, line: section.line)
        var attrs = Attributes()
        attrs["line"] = .int(section.line)
        attrs["file"] = .string(file.absoluteString)
        let hasChildren = !TypstStructure.directChildren(ofSectionAt: section.line, in: items).isEmpty
        return Node(id: NodeID(canonical: ref.uri),
                    type: TypeID("typst.section"),
                    label: section.title,
                    icon: NodeIcon("number", tint: .purple),
                    attributes: attrs,
                    hasChildren: hasChildren,
                    // Phony: a pointer into the document, not a document. Opening
                    // it opens the file's one canvas at this heading's line.
                    anchor: fileAnchor(file: file, line: section.line))
    }

    /// The anchor that makes outline nodes phony: the file node (same identity
    /// the FileSystem provider uses) plus the line to jump to.
    static func fileAnchor(file: URL, line: Int) -> NodeAnchor? {
        NodeID(file.absoluteString).map { NodeAnchor(node: $0, fragment: "line=\(line)") }
    }

    static func taskNode(_ task: TypstStructure.TaskItem, file: URL) -> Node {
        let ref = TypstRef.task(file: file.path, index: task.index)
        var attrs = Attributes()
        attrs["line"] = .int(task.line)
        attrs["index"] = .int(task.index)
        attrs["file"] = .string(file.absoluteString)
        attrs["done"] = .bool(task.done)
        if let due = task.due { attrs["due"] = .string(due) }
        if !task.tags.isEmpty { attrs["tags"] = .string(task.tags.joined(separator: " ")) }
        return Node(id: NodeID(canonical: ref.uri),
                    type: TypeID("typst.task"),
                    label: task.body,
                    icon: task.done ? NodeIcon("checkmark.circle.fill", tint: .green)
                                    : NodeIcon("circle", tint: .secondary),
                    attributes: attrs,
                    anchor: fileAnchor(file: file, line: task.line))
    }

    /// The document's rendered pages.
    ///
    /// Declares the file as its identity, the way the agenda declares its
    /// folder: these are one document under two names, so everything the file
    /// can do — save, rename, reveal, export — works from a pane showing the
    /// pages, run against the identity that understands it. It also means a
    /// list of *things* shows this once, under the document's own name, rather
    /// than as a second entry pretending to be a second file.
    static func previewNode(file: URL) -> Node {
        Node(id: NodeID(canonical: TypstRef.preview(file: file.path).uri),
             type: TypeID("typst.preview"),
             label: file.deletingPathExtension().lastPathComponent,
             icon: NodeIcon("doc.richtext", tint: .accent),
             hasChildren: false,
             identities: [NodeID(file.standardizedFileURL.absoluteString)].compactMap { $0 })
    }

    static func agendaNode(dir: URL) -> Node {
        Node(id: NodeID(canonical: TypstRef.agenda(dir: dir.path).uri),
             type: TypeID("typst.agenda"),
             label: "Agenda — \(dir.lastPathComponent)",
             icon: NodeIcon("calendar", tint: .orange),
             hasChildren: true,
             // An agenda is a reading of a folder, not a separate thing: the
             // same directory, with everything a directory can do.
             identities: [NodeID(dir.standardizedFileURL.absoluteString)].compactMap { $0 })
    }

    static func agendaTasks(under dir: URL) -> [(file: URL, task: TypstStructure.TaskItem)] {
        TypstStructure.agendaTasks(under: dir)
    }

    /// Flip a task's done state in its source file and tell the host. The file is
    /// the single source of truth — this is a structural edit, not app state.
    @MainActor
    static func toggleTask(file: URL, index: Int, host: HostContext,
                           alsoInvalidate extra: [NodeID] = []) {
        guard let source = try? String(contentsOf: file, encoding: .utf8),
              let toggled = TypstStructure.togglingTask(at: index, in: source) else { return }
        do {
            try toggled.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[TypstPlugin] task toggle failed: \(error.localizedDescription)")
            return
        }
        var changes: [NodeChange] = []
        if let fileID = NodeID(file.absoluteString) {
            changes += [.modified(fileID), .childrenChanged(fileID)]
        }
        changes += extra.map { .childrenChanged($0) }
        host.notify(changes)
    }
}

// MARK: - External change stream (agenda auto-refresh)

/// Watch a mounted agenda's folder: any `.typ` change re-scans the agenda —
/// the sidebar's task list through the host's funnel, and whatever a shell
/// shows of it through `onAgendaChanged`. The manual action stays as a
/// force-refresh.
extension TypstProvider: ChangeStreamingProvider {
    func changes(under root: NodeID) -> AsyncStream<[NodeChange]>? {
        guard let ref = TypstRef(uri: root.uri), ref.kind == .agenda else { return nil }
        return AsyncStream { continuation in
            let watcher = FileTreeWatcher(path: ref.fileURL.path) { events in
                let relevant = events.contains {
                    $0.mustRescanSubtree || $0.path.lowercased().hasSuffix(".typ")
                }
                guard relevant else { return }
                continuation.yield([.childrenChanged(root)])
                onAgendaChanged()
            }
            guard let watcher else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}
