import SwiftUI
import MaximalTreeKit

/// Rich canvas for a commit: message, author/date, sha, and clickable changed files.
struct CommitCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        let node = host.node(nodeID)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(gitString(node, "subject") ?? node?.displayName ?? "Commit")
                    .font(.title2).bold()
                    .textSelection(.enabled)

                HStack(spacing: 14) {
                    if let author = gitString(node, "author") {
                        Label(author, systemImage: "person")
                    }
                    if let date = gitDate(node) {
                        Label(date, systemImage: "clock")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let sha = gitString(node, "sha") {
                    Text(sha)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                let files = host.children(of: nodeID)
                if files.isEmpty {
                    Text("No file changes").foregroundStyle(.secondary)
                } else {
                    Text("Changed Files").font(.headline)
                    ForEach(files, id: \.self) { fid in
                        Button {
                            host.open(fid)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: statusIcon(host.node(fid)))
                                    .foregroundStyle(.tint)
                                    .frame(width: 16)
                                Text(host.node(fid)?.displayName ?? fid.uri).lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(node?.displayName ?? "Commit")
    }

    private func statusIcon(_ node: Node?) -> String {
        switch gitString(node, "status") {
        case "A": return "plus.circle"
        case "D": return "minus.circle"
        case "M": return "pencil.circle"
        case "R": return "arrow.right.circle"
        default:  return "doc.text"
        }
    }
}

/// Generic canvas for git containers and leaves: lists children (Branches, Commits,
/// commit list, …) and any forward references.
struct GitListCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        let children = host.children(of: nodeID)
        let related = host.related(of: nodeID)
        Group {
            if children.isEmpty && related.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "arrow.triangle.branch")
            } else {
                List {
                    if !children.isEmpty {
                        Section(host.node(nodeID)?.displayName ?? "") {
                            ForEach(children, id: \.self) { cid in
                                Button {
                                    host.open(cid)
                                } label: {
                                    HStack {
                                        Text(host.node(cid)?.displayName ?? cid.uri).lineLimit(1)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !related.isEmpty {
                        Section("References") {
                            ForEach(related) { r in
                                Button(r.label) { host.openURI(r.target) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(host.node(nodeID)?.displayName ?? "")
    }
}

/// Inspector section for any git node: attributes + clickable references.
struct GitInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        let node = host.node(nodeID)
        Form {
            Section("Git") {
                LabeledContent("Name", value: node?.displayName ?? "—")
                if let sha = gitString(node, "sha") { LabeledContent("SHA", value: sha) }
                if let author = gitString(node, "author") { LabeledContent("Author", value: author) }
                if let date = gitDate(node) { LabeledContent("Date", value: date) }
                if let status = gitString(node, "status") { LabeledContent("Status", value: status) }
            }
            let related = host.related(of: nodeID)
            if !related.isEmpty {
                Section("References") {
                    ForEach(related) { r in
                        Button(r.label) { host.openURI(r.target) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - attribute helpers

private func gitString(_ node: Node?, _ key: String) -> String? {
    if case .string(let value)? = node?.attributes[key] { return value }
    return nil
}

private func gitDate(_ node: Node?) -> String? {
    if case .date(let date)? = node?.attributes["date"] {
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    return nil
}
