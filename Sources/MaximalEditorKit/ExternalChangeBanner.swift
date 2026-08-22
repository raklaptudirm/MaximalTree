import SwiftUI

/// Shown when a document changed on disk while the reader had unsaved edits.
///
/// Deliberately not a modal: the file has already changed and nothing is lost
/// either way, so interrupting the reader mid-sentence to demand an answer
/// would be worse than letting them finish and decide. It sits above the text
/// until one of the two things is chosen.
public struct ExternalChangeBanner: View {
    let reload: () -> Void
    let keep: () -> Void

    public init(reload: @escaping () -> Void, keep: @escaping () -> Void) {
        self.reload = reload
        self.keep = keep
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Changed on disk").font(.callout.weight(.semibold))
                Text("This file was edited outside the app. You have unsaved changes here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Keep Mine", action: keep)
            Button("Reload", action: reload)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
