import AppKit
import SwiftUI
import MaximalTreeKit

/// What a terminal is, beside what it is showing.
///
/// The plugin had no inspector at all: a running shell's directory, age and
/// state were things only the terminal itself knew, and it draws none of them
/// — a terminal's canvas is the shell's own output and nothing else belongs
/// on it.
struct TerminalInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @State private var sessions = TerminalSessions.shared

    var body: some View {
        let session = sessions.session(for: nodeID)
        Form {
            Section("Terminal") {
                if let session {
                    LabeledContent("Directory") {
                        // The whole path, since the label only shows its last
                        // component and the point of asking is usually to see
                        // which of two similarly-named checkouts this is.
                        Text(session.directory)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    if let title = session.title, !title.isEmpty {
                        LabeledContent("Running", value: title)
                    }
                    LabeledContent("Started", value: started(session.created))
                    LabeledContent("Size", value: size(of: session))
                    LabeledContent("Shell", value: shellName)
                } else {
                    // A session node outlives its shell: the workspace
                    // remembers the node, and nothing is resurrected until it
                    // is shown. Saying so beats an empty form.
                    LabeledContent("State", value: "Not running")
                    if let directory = TerminalRef.directory(of: nodeID) {
                        LabeledContent("Directory", value: directory)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// How long it has been up, which is the useful form of a start time for
    /// something that is usually minutes old.
    private func started(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// The grid, in the terminal's own units — what a program running in it
    /// sees, rather than the pane's size in points.
    private func size(of session: TerminalSession) -> String {
        let bounds = session.view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return "—" }
        return "\(Int(bounds.width)) × \(Int(bounds.height)) pt"
    }

    private var shellName: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "—"
        return URL(fileURLWithPath: shell).lastPathComponent
    }
}
