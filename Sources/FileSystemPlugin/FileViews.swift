import SwiftUI
import Quartz          // QLPreviewView
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

/// Canvas for a leaf file: a live Quick Look preview (text, images, PDFs, media, …).
/// This is the canvas "escape hatch" in action — a plugin dropping a raw AppKit view
/// into the center pane.
struct FileCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        Group {
            if let url = nodeID.fileURL {
                QuickLookPreview(url: url)
            } else {
                ContentUnavailableView("No Preview", systemImage: "doc")
            }
        }
        .navigationTitle(host.node(nodeID)?.displayName ?? "")
    }
}

/// Wraps `QLPreviewView` for SwiftUI. Rebinds its item when the focused file changes
/// so the same view is reused across navigation rather than recreated per node.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        }
    }
}

/// Inspector shared by files and directories: node metadata, file stats, and any
/// forward references (empty for the filesystem provider today).
struct FileInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let node = host.node(nodeID)
        Form {
            Section("Node") {
                // Editable: committing a new name applies a rename mutation. The
                // inspector doubles as the manipulation surface.
                TextField("Name", text: $draftName)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                LabeledContent("Type", value: node?.type.raw ?? "—")
                if let uti = node?.uti { LabeledContent("Content Type", value: uti) }
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
        .onAppear { draftName = host.node(nodeID)?.displayName ?? "" }
        .onChange(of: nodeID) { draftName = host.node(nodeID)?.displayName ?? "" }
        .onChange(of: host.node(nodeID)?.displayName) { _, newValue in
            if !nameFocused { draftName = newValue ?? "" }   // don't clobber while editing
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != host.node(nodeID)?.displayName else { return }
        host.apply(.rename(nodeID, to: trimmed))
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
