import SwiftUI
import AppKit
import MaximalEditorKit
import MaximalTreeKit

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
            /// Clicks move the keyboard too, and nothing else tells us.
            private var clicks: Any?
            /// Watches the modifiers, for the ⌘-held peek.
            private var flags: Any?
            /// Distinguishes this press of ⌘ from the next one, so a release
            /// can't cancel a peek that a later press asked for.
            private var peekGeneration = 0

            /// How long ⌘ has to be down before the peek appears.
            ///
            /// Long enough that ⌘S never flashes it, short enough that holding
            /// the key to ask a question feels like it answered.
            private static let peekDelay: TimeInterval = 0.4

            func install(model: AppModel) {
                guard monitor == nil else { return }
                flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    // ⌘ alone: with another modifier down this is someone
                    // building a shortcut, not asking what there is.
                    let held = event.modifierFlags.isDisjoint(with: [.control, .option, .shift])
                        && event.modifierFlags.contains(.command)
                    MainActor.assumeIsolated { self.setPeek(held, model: model) }
                    return event
                }
                clicks = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseUp, .rightMouseUp]) { event in
                    MainActor.assumeIsolated { model.refreshFocusedSurface() }
                    return event
                }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // The chord is read out here, because an NSEvent can't
                    // cross into the main actor — everything past this point
                    // is values.
                    guard let chord = KeyChord(event: event) else { return event }
                    // Menu shortcuts stay the platform's: a modal layer that
                    // ate ⌘Q or ⌘W would be a trap.
                    if event.modifierFlags.contains(.command) { return event }
                    let handled = MainActor.assumeIsolated {
                        let handled = Self.handle(chord, model: model)
                        model.refreshFocusedSurface()
                        return handled
                    }
                    return handled ? nil : event
                }
            }

            @MainActor
            private static func handle(_ chord: KeyChord, model: AppModel) -> Bool {
                // The finder is an overlay rather than a surface, and the
                // keyboard belongs to a field editor while it is open, so its
                // own keys have to be taken here — nothing downstream will.
                if model.handleFinderKey(chord) { return true }
                return KeyDispatch.handle(chord, keys: model.keys,
                                          canvas: KeyFocus.focusedCanvas())
            }

            /// Show the leader's menu while ⌘ is held, after a moment.
            ///
            /// Deferred rather than immediate: every ⌘ shortcut in the app
            /// passes through here, and a menu that flickered on each one
            /// would be worse than not having it. Letting go takes it away at
            /// once, because by then the question has been answered.
            @MainActor
            private func setPeek(_ held: Bool, model: AppModel) {
                peekGeneration += 1
                guard held else {
                    model.keys.isPeeking = false
                    return
                }
                let generation = peekGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDelay) { [self] in
                    guard generation == peekGeneration else { return }
                    model.keys.isPeeking = true
                }
            }

            func remove() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                if let clicks { NSEvent.removeMonitor(clicks) }
                if let flags { NSEvent.removeMonitor(flags) }
                monitor = nil
                clicks = nil
                flags = nil
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
        let mode = model.keys.mode
        HStack(spacing: 5) {
            Circle()
                .fill(color(of: mode))
                .frame(width: 6, height: 6)
            Text(mode.label)
                .font(.callout)
                .foregroundStyle(color(of: mode))

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

    /// There is one mode and this reads it. It used to have to ask the
    /// focused editor for its own idea of the mode instead, because there
    /// were two of them and the editor's was the one being typed into.
    private func color(of mode: KeyMode) -> Color {
        switch mode {
        case .normal: return .secondary
        case .insert: return .green
        case .visual: return .purple
        }
    }
}

/// Which-key: what a half-typed sequence could still become, so a leader key
/// is fast even when you can't remember all of it. Transient, so it stays a
/// floating card over the canvas — in the app's own card style, not a HUD
/// bolted to a mode pill.
struct KeyWhichKey: View {
    /// Enough for every key the app binds at the top level, with room for a
    /// keymap of one's own. Not unbounded: this is still an overlay.
    static let peekLimit = 60

    @Environment(AppModel.self) private var model
    /// Whether this is the window holding the keyboard.
    ///
    /// The pending sequence is one app-wide value — there is one mode and one
    /// keymap — so every window that draws this would draw it at the same
    /// time. Drawn only where the keys are actually being typed: pressing the
    /// leader in a loose file's window used to answer in the main window,
    /// behind it.
    @Environment(\.controlActiveState) private var activeState

    /// One line of the overlay.
    struct Row: Identifiable, Equatable {
        let id: String
        let keys: String
        let label: String
        /// An app binding the focused canvas will take before the app sees it.
        /// Shown, because it is still in the keymap and still worth knowing
        /// about, but not as though pressing it would do this.
        let intercepted: Bool
    }

    var body: some View {
        let keys = model.keys
        let rows = rows(for: keys)
        if activeState == .key, !rows.isEmpty {
            // Wide enough to scan, capped so a big group can't cover the
            // thing being worked on — but the peek is a deliberate "show me
            // what the keys do", and answering it with a silent three-quarters
            // of the list would be worse than not answering.
            // Four columns while peeking: the canvas's keys and the app's
            // together run to fifty-odd rows, and three columns of that is a
            // wall down the side of the window.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 130),
                                                          alignment: .leading),
                                     count: keys.isPeeking ? 4 : 3),
                      alignment: .leading, spacing: 4) {
                ForEach(rows.prefix(keys.isPeeking ? Self.peekLimit : 18)) { row in
                    HStack(spacing: 6) {
                        Text(row.keys)
                            .font(.system(.caption2, design: .monospaced).weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(row.intercepted ? 0.06 : 0.12),
                                       in: RoundedRectangle(cornerRadius: 4))
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(row.intercepted ? AnyShapeStyle(.tertiary)
                                                             : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                    .opacity(row.intercepted ? 0.55 : 1)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }

    /// What to show: mid-sequence, where you are; with ⌘ held and nothing
    /// typed, every key that means something from here.
    ///
    /// The peek leads with the focused canvas's own keys, because those are
    /// what the keys will actually do — in a commanding mode the canvas is
    /// offered every key before the app is. The app's own bindings follow, and
    /// the ones the canvas will take are dimmed rather than dropped: the
    /// binding is still real, it just isn't what happens here.
    private func rows(for keys: KeyEngine) -> [Row] {
        guard keys.pending.isEmpty else {
            return keys.continuations.map {
                Row(id: $0.chord.description, keys: $0.chord.description,
                    label: label(for: $0.binding), intercepted: false)
            }
        }
        guard keys.isPeeking else { return [] }
        return Self.peekRows(
            canvas: KeyFocus.focusedCanvas()?.keyBindings ?? [],
            app: keys.topLevelBindings.map {
                (keys: $0.chord.description, label: label(for: $0.binding))
            },
            mode: keys.mode)
    }

    /// The peek's contents, given what the canvas takes and what the app binds.
    ///
    /// Separate from the view because this is the part that was wrong: the
    /// overlay listed the app's bindings while a canvas quietly took them, so
    /// `j` read as "move down the sidebar" with the caret moving instead.
    static func peekRows(canvas: [CanvasKeyBinding],
                         app: [(keys: String, label: String)],
                         mode: KeyMode) -> [Row] {
        let mine = canvas.filter { $0.mode == mode }
        let taken = Set(mine.map(\.key))
        return mine.map {
            Row(id: "canvas:\($0.key)", keys: $0.key, label: $0.title, intercepted: false)
        } + app.map {
            Row(id: "app:\($0.keys)", keys: $0.keys, label: $0.label,
                intercepted: taken.contains($0.keys))
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
