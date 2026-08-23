import SwiftUI
import MaximalTreeKit

/// What the host knows about any node, whoever provides it.
///
/// This used to live inside the FileSystem plugin, so a file had a name, a
/// kind and an identity in the inspector while a git commit, a web page or a
/// terminal had whatever its own plugin happened to write — often nothing at
/// all. None of it was ever file-specific: every node has an identity, a type,
/// a label, the other things it is, and what it points at. A plugin's sections
/// describe what makes its nodes *different*; this describes what they have in
/// common, and it shows for all of them.
struct NodeInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    @State private var draftName = ""
    @State private var editing: NodeID?

    var body: some View {
        let node = host.node(nodeID)
        Form {
            Section("Node") {
                // Editable wherever the owning provider supports renaming —
                // the inspector doubles as the manipulation surface, and which
                // providers can rename is not the inspector's business to know.
                if host.canApply(.rename(nodeID, to: draftName)) {
                    TextField("Name", text: $draftName)
                        .onSubmit(commitRename)
                } else {
                    LabeledContent("Name", value: node?.label ?? "—")
                }
                LabeledContent("Kind", value: node?.type.raw ?? "—")
                LabeledContent("Identity") {
                    HStack(spacing: 4) {
                        Text(nodeID.uri)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(nodeID.uri, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy identity")
                    }
                }
            }

            // The other things this node *is* — a repository that is also a
            // directory. Openable, since each is a way of looking at it.
            if let identities = node?.identities, !identities.isEmpty {
                Section("Also") {
                    ForEach(identities, id: \.self) { identity in
                        Button {
                            host.open(identity)
                        } label: {
                            HStack(spacing: 8) {
                                NodeIconView(host.node(identity)?.icon).frame(width: 16)
                                Text(host.node(identity)?.label ?? identity.uri)
                                    .lineLimit(1)
                                Spacer()
                                Text(host.node(identity)?.type.raw ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Where it points. Every provider can contribute these, so showing
            // them here means no plugin has to write the same section again.
            let related = host.related(of: nodeID)
            if !related.isEmpty {
                Section("References") {
                    ForEach(related) { reference in
                        Button(reference.label) { host.openURI(reference.target) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: nodeID) {
            // Only when the subject changes: rebinding on every update would
            // overwrite what is being typed.
            draftName = host.node(nodeID)?.label ?? ""
            editing = nodeID
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != host.node(nodeID)?.label else { return }
        host.apply(.rename(nodeID, to: trimmed))
    }
}
