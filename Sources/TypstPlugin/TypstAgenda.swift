import SwiftUI
import MaximalTreeKit

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
