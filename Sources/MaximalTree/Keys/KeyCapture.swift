import SwiftUI
import AppKit
import MaximalEditorKit

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
                let destination = KeyRouting.destination(for: chord, mode: model.keys.mode)
                guard destination == .app else { return false }

                if chord.key == "ESC" {
                    KeyFocus.focusedCanvas()?.canvasModeChanged(toInsert: false)
                }

                // The focused canvas gets first refusal — its own motions, its
                // own operators — but never the leader or the rest of a
                // sequence already begun, which belong to the app wherever the
                // keyboard is.
                let reserved = chord.key == "SPC" || !model.keys.pending.isEmpty
                if !reserved, chord.key != "ESC",
                   let canvas = KeyFocus.focusedCanvas(),
                   canvas.handleNormalModeKey(chord.key, control: chord.control) {
                    // A canvas can enter insert on its own (`i`, `o`, a visual
                    // `c`, …) without the app ever seeing the key that did it.
                    // Without this the app kept thinking it was still in
                    // normal mode and went on treating letters as commands —
                    // which is why ordinary text landed on the floor.
                    if canvas.isInsertMode { model.keys.setMode(.insert) }
                    return true
                }

                switch model.keys.handle(chord, editing: false) {
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

/// The mode, in the tab strip's trailing cluster.
///
/// Not in the toolbar: an NSToolbar item wraps arbitrary content in a glass
/// container sized for a control, which neither hugged this label nor let it
/// shrink to fit — the text sat outside the pill drawn around it. The strip
/// is the app's own layout, one row lower and already there.
///
/// A dot and a label, drawing no chip of its own — chips in this row are
/// tabs, and this is not one. Color is the only variable: normal is grey,
/// because it's where the app spends nearly all of its time and a
/// permanently lit indicator stops carrying information. Insert and visual
/// are the states worth noticing, so they are the ones that take a tint.
struct KeyModeIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mode = displayedMode
        HStack(spacing: 5) {
            Circle()
                .fill(mode.tint)
                .frame(width: 6, height: 6)
            Text(mode.name)
                .font(.callout)
                .foregroundStyle(mode.tint)

            let keys = model.keys
            if !keys.pending.isEmpty {
                Text(keys.pending.map(\.description).joined(separator: " "))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !keys.prefixLabel.isEmpty {
                    Text(keys.prefixLabel)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // The tab scroller beside this will take every point it is offered;
        // this keeps its own ideal width out of that negotiation.
        .fixedSize()
        .help("Keyboard mode. Escape returns to normal.")
    }

    /// The mode actually in force, and the color that names it.
    ///
    /// When the editor has the keyboard it is the one deciding what keys mean,
    /// so its mode is the true one — an indicator that said Normal while the
    /// editor was inserting would be worse than none.
    private var displayedMode: (name: String, tint: Color) {
        if let editor = NSApp.keyWindow?.firstResponder as? MaximalEditor.EditorTextView,
           editor.vimEnabled {
            switch editor.vim.mode {
            case .normal: return ("Normal", .secondary)
            case .insert: return ("Insert", .green)
            case .visual: return ("Visual", .purple)
            }
        }
        return model.keys.mode == .insert ? ("Insert", .green) : ("Normal", .secondary)
    }
}

/// Which-key: what a half-typed sequence could still become, so a leader key
/// is fast even when you can't remember all of it. Transient, so it stays a
/// floating card over the canvas — in the app's own card style, not a HUD
/// bolted to a mode pill.
struct KeyWhichKey: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keys = model.keys
        if !keys.pending.isEmpty, !keys.continuations.isEmpty {
            // Wide enough to scan, capped so a big group can't cover the
            // thing being worked on.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 130),
                                                          alignment: .leading),
                                     count: 3),
                      alignment: .leading, spacing: 4) {
                ForEach(keys.continuations.prefix(18), id: \.chord) { item in
                    HStack(spacing: 6) {
                        Text(item.chord.description)
                            .font(.system(.caption2, design: .monospaced).weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12),
                                       in: RoundedRectangle(cornerRadius: 4))
                        Text(label(for: item.binding))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
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
