import SwiftUI
import AppKit

/// Feeds every key press to the modal layer before AppKit sees it.
///
/// A local monitor rather than SwiftUI's `.onKeyPress`: bindings have to work
/// wherever focus happens to be — a sidebar row, a canvas, nothing at all —
/// and a view-scoped handler only fires for the view that has it.
///
/// Keys are passed through untouched while a text view has the keyboard, so
/// typing in the editor stays typing. Escape is the exception: it is how you
/// leave, so it is always ours.
struct KeyCapture: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.background(KeyMonitor(model: model))
    }

    private struct KeyMonitor: NSViewRepresentable {
        let model: AppModel

        func makeNSView(context: Context) -> NSView {
            context.coordinator.install(model: model)
            return NSView()
        }

        func updateNSView(_ view: NSView, context: Context) {}
        func makeCoordinator() -> Coordinator { Coordinator() }

        static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
            coordinator.remove()
        }

        final class Coordinator: @unchecked Sendable {
            private var monitor: Any?

            func install(model: AppModel) {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // The chord is read out here, because an NSEvent can't
                    // cross into the main actor — everything past this point
                    // is values.
                    guard let chord = KeyChord(event: event) else { return event }
                    // Menu shortcuts stay the platform's: a modal layer that
                    // ate ⌘Q or ⌘W would be a trap.
                    if event.modifierFlags.contains(.command) { return event }
                    let handled = MainActor.assumeIsolated {
                        Self.handle(chord, model: model)
                    }
                    return handled ? nil : event
                }
            }

            @MainActor
            private static func handle(_ chord: KeyChord, model: AppModel) -> Bool {
                // While a text view has the keyboard, typing is typing.
                let editing = NSApp.keyWindow?.firstResponder is NSTextView
                switch model.keys.handle(chord, editing: editing) {
                case .consumed, .pendingSequence: return true
                case .passed: return false
                }
            }

            func remove() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
        }
    }
}

extension View {
    /// Route key presses through the modal layer.
    func keyCapture(_ model: AppModel) -> some View { modifier(KeyCapture(model: model)) }
}

/// The mode, and what a half-typed sequence could still become.
///
/// Which-key, in miniature: a leader key is only fast if you can stop halfway
/// and be told what is available, rather than having to remember all of it.
struct KeyHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keys = model.keys
        HStack(alignment: .bottom, spacing: 10) {
            Text(keys.mode.label)
                .font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(keys.mode == .normal ? Color.accentColor : Color.orange,
                            in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.white)

            if !keys.pending.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(keys.pending.map(\.description).joined(separator: " "))
                            .font(.caption.monospaced().weight(.semibold))
                        if !keys.prefixLabel.isEmpty {
                            Text(keys.prefixLabel).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // Wide enough to scan, capped so a big group can't cover
                    // the thing being worked on.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 120),
                                                                 alignment: .leading),
                                             count: 3),
                              alignment: .leading, spacing: 4) {
                        ForEach(keys.continuations.prefix(18), id: \.chord) { item in
                            HStack(spacing: 5) {
                                Text(item.chord.description)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                Text(label(for: item.binding))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
    }

    private func label(for binding: KeyBinding) -> String {
        switch binding {
        case .prefix(let name): return name.isEmpty ? "…" : "+\(name)"
        case .command(let id):
            // An action's own title reads better than its id.
            return model.applicableActions().first { $0.id == id }?.title
                ?? id.split(separator: ".").last.map(String.init) ?? id
        }
    }
}
