import SwiftUI
import Foundation
import MaximalTreeKit

/// Vends Typst document *structure* as nodes: sections and tasks (contributed as
/// children of `.typ` file nodes), and the mountable agenda that collects tasks
/// across a folder. This is the org-mode half of the plugin — the document stays
/// the single source of truth, and toggling a task rewrites its source.
struct TypstProvider: NodeProvider {
    let schemes: Set<String> = ["typst"]

    func resolve(_ uri: String) -> NodeID? {
        guard let ref = TypstRef(uri: uri) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ref.path, isDirectory: &isDirectory)
        else { return nil }
        switch ref.kind {
        case .agenda: guard isDirectory.boolValue else { return nil }
        case .section, .task: guard !isDirectory.boolValue else { return nil }
        }
        return NodeID(ref.uri)
    }

    func node(for id: NodeID) async -> Node? {
        guard let ref = TypstRef(uri: id.uri) else { return nil }
        switch ref.kind {
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
        case .task:
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

    static func agendaNode(dir: URL) -> Node {
        Node(id: NodeID(canonical: TypstRef.agenda(dir: dir.path).uri),
             type: TypeID("typst.agenda"),
             label: "Agenda — \(dir.lastPathComponent)",
             icon: NodeIcon("calendar", tint: .orange),
             hasChildren: true)
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

// MARK: - Agenda canvas

/// The org-agenda view: tasks across the folder, grouped by urgency, with
/// source-rewriting checkboxes. Clicking a task opens its document at the line.
struct AgendaCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    private struct Entry: Identifiable {
        let file: URL
        let task: TypstStructure.TaskItem
        var id: String { "\(file.path)#\(task.index)" }
    }

    @State private var entries: [Entry] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "checkmark.circle",
                                       description: Text("Add #task[…] items to any .typ file in this folder."))
            } else {
                List {
                    ForEach(grouped, id: \.0) { group, groupEntries in
                        Section(group) {
                            ForEach(groupEntries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
        }
        .task(id: nodeID) { await reload() }
        // Refresh is an Action ("Refresh Agenda", \u{2318}R) — the canvas keeps
        // no chrome, it just reloads when the action bumps the nonce.
        .onChange(of: TypstUIState.shared.agendaRefresh) { _, _ in
            Task { await reload() }
        }
    }

    private var grouped: [(String, [Entry])] {
        let today = Self.isoToday()
        var buckets: [(String, [Entry])] = [("Overdue", []), ("Today", []),
                                            ("Upcoming", []), ("No Due Date", []), ("Done", [])]
        for entry in entries {
            let bucket: Int
            if entry.task.done { bucket = 4 }
            else if let due = entry.task.due {
                bucket = due < today ? 0 : (due == today ? 1 : 2)
            } else { bucket = 3 }
            buckets[bucket].1.append(entry)
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                TypstProvider.toggleTask(file: entry.file, index: entry.task.index,
                                         host: host, alsoInvalidate: [nodeID])
                Task { await reload() }
            } label: {
                Image(systemName: entry.task.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(entry.task.done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.task.body)
                    .strikethrough(entry.task.done)
                    .foregroundStyle(entry.task.done ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(entry.file.deletingPathExtension().lastPathComponent)
                    if let due = entry.task.due { Text("due \(due)") }
                    ForEach(entry.task.tags, id: \.self) { Text("#\($0)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let ref = TypstRef.task(file: entry.file.path, index: entry.task.index)
            host.openURI(ref.uri)
        }
    }

    private func reload() async {
        guard let ref = TypstRef(uri: nodeID.uri), ref.kind == .agenda else { return }
        let found = await Task.detached(priority: .userInitiated) {
            TypstProvider.agendaTasks(under: ref.fileURL)
        }.value
        entries = found.map { Entry(file: $0.0, task: $0.1) }
        loading = false
    }

    private static func isoToday() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}

// MARK: - Task inspector

struct TaskInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        let node = host.node(nodeID)
        Form {
            Section("Task") {
                Toggle("Done", isOn: Binding(
                    get: {
                        if case .bool(let done)? = node?.attributes["done"] { return done }
                        return false
                    },
                    set: { _ in
                        guard let ref = TypstRef(uri: nodeID.uri), let index = ref.index else { return }
                        TypstProvider.toggleTask(file: ref.fileURL, index: index, host: host)
                    }
                ))
                if case .string(let due)? = node?.attributes["due"] {
                    LabeledContent("Due", value: due)
                }
                if case .string(let tags)? = node?.attributes["tags"] {
                    LabeledContent("Tags", value: tags)
                }
                if let ref = TypstRef(uri: nodeID.uri) {
                    LabeledContent("File", value: ref.fileURL.lastPathComponent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - External change stream (agenda auto-refresh)

/// Watch a mounted agenda's folder: any `.typ` change re-scans the agenda —
/// the sidebar's task list through the host's funnel, and the live canvas
/// through the same nonce the Refresh action bumps. The manual action stays
/// as a force-refresh.
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
                Task { @MainActor in TypstUIState.shared.agendaRefresh += 1 }
            }
            guard let watcher else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}
