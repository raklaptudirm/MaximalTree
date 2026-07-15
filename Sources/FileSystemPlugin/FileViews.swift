import SwiftUI
import MaximalTreeKit

/// Canvas for a directory: an icon grid of its children. Clicking focuses a child,
/// which re-drives the whole shell through the renderer lookup.
struct DirectoryCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(host.children(of: nodeID), id: \.self) { cid in
                    let node = host.node(cid)
                    Button {
                        host.open(cid)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: node?.type == TypeID("file.directory") ? "folder.fill" : "doc")
                                .font(.system(size: 34))
                                .foregroundStyle(.tint)
                            Text(node?.displayName ?? cid.uri)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(host.node(nodeID)?.displayName ?? "")
    }
}

/// Canvas for a leaf file. A real preview renderer would live here; v0 shows a stub.
struct FileCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(host.node(nodeID)?.displayName ?? nodeID.uri)
                .font(.title3)
            Text(nodeID.uri)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .navigationTitle(host.node(nodeID)?.displayName ?? "")
    }
}

/// Inspector shared by files and directories: node metadata, file stats, and any
/// forward references (empty for the filesystem provider today).
struct FileInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        let node = host.node(nodeID)
        Form {
            Section("Node") {
                LabeledContent("Name", value: node?.displayName ?? "—")
                LabeledContent("Type", value: node?.type.raw ?? "—")
            }
            if let size = sizeString(node) {
                Section("File") {
                    LabeledContent("Size", value: size)
                    if let modified = modifiedString(node) {
                        LabeledContent("Modified", value: modified)
                    }
                }
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

    private func sizeString(_ node: Node?) -> String? {
        guard case .int(let bytes)? = node?.attributes["size"] else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func modifiedString(_ node: Node?) -> String? {
        guard case .date(let date)? = node?.attributes["modified"] else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
