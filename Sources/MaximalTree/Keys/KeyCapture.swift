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
                                          surface: model.surfaceKeymap(),
                                          editing: KeyFocus.isTypingInAField())
            }

            func remove() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                if let clicks { NSEvent.removeMonitor(clicks) }
                monitor = nil
                clicks = nil
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

    /// One line of the overlay: a key, and what it does here.
    struct Row: Identifiable, Equatable {
        let id: String
        let keys: String
        let label: String
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
                            .background(Color.secondary.opacity(0.12),
                                       in: RoundedRectangle(cornerRadius: 4))
                        Text(row.label)
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
            let map = keys.isSurfaceSequence ? model.surfaceKeymap() : keys.keymap
            return live(keys.continuations, under: keys.pending, keymap: map, in: keys).map {
                Row(id: $0.chord.description, keys: $0.chord.description,
                    label: label(for: $0.binding))
            }
        }
        guard keys.isPeeking else { return [] }
        // The surface's own keys lead, then the app's. A surface's keys are no
        // longer in the app's map — that is the point of it declaring them —
        // so without this the sidebar's `j` would vanish from the peek the
        // moment it became the sidebar's rather than everyone's.
        let map = model.surfaceKeymap()
        let mine = live(topLevel(of: map), under: [], keymap: map, in: keys).map {
            (keys: $0.chord.description, label: label(for: $0.binding))
        }
        return Self.peekRows(
            surface: mine,
            app: live(keys.topLevelBindings, under: [], keymap: keys.keymap, in: keys).map {
                (keys: $0.chord.description, label: label(for: $0.binding))
            },
            mode: keys.mode)
    }

    /// The bindings that can actually fire from here.
    ///
    /// A keymap is a static trie: it knows `j` names `explorer.down`, not that
    /// the explorer's motions belong to the sidebar and the caret is in a
    /// document. The overlay listed them anyway, which made the sidebar look
    /// like it was taking part in a surface it has nothing to do with. It
    /// wasn't — `runCommand` has always checked before running one — but a
    /// list of keys that quietly do nothing is its own kind of wrong.
    ///
    /// A group survives if anything under it does, so `SPC g` stays while its
    /// contents apply and goes when none of them do.
    private func live(_ bindings: [(chord: KeyChord, binding: KeyBinding)],
                      under prefix: [KeyChord],
                      keymap: Keymap,
                      in keys: KeyEngine) -> [(chord: KeyChord, binding: KeyBinding)] {
        Self.live(bindings, under: prefix, keymap: keymap) { [model] id in
            model.action(id).map { model.canRun($0) } ?? false
        }
    }

    /// A map's bindings with nothing typed yet.
    private func topLevel(of map: Keymap) -> [(chord: KeyChord, binding: KeyBinding)] {
        guard case .prefix(_, let continuations) = map.lookup([]) else { return [] }
        return continuations
    }

    /// Separate and injectable for the same reason `KeyDispatch` is: whether a
    /// binding is live depends on which surface has the keyboard, and that
    /// question needs a key window to answer — which a test process has not
    /// got. The rule is the part worth pinning down.
    static func live(_ bindings: [(chord: KeyChord, binding: KeyBinding)],
                     under prefix: [KeyChord],
                     keymap: Keymap,
                     canRun: (String) -> Bool) -> [(chord: KeyChord, binding: KeyBinding)] {
        bindings.filter { item in
            switch item.binding {
            case .command(let id): return canRun(id)
            case .prefix: return keymap.commands(under: prefix + [item.chord]).contains(where: canRun)
            }
        }
    }

    /// The peek's contents: one row per key, saying what that key does here.
    ///
    /// A key the canvas takes appears once, as the canvas's — the app's row for
    /// it is dropped rather than dimmed. Dimming was a half-answer: `i` in the
    /// editor inserts *and* leaves the app in insert mode, so greying the app's
    /// "Insert Mode" said the opposite of what pressing it does. Whatever the
    /// canvas takes, the canvas's own row already describes.
    static func peekRows(surface: [(keys: String, label: String)] = [],
                         app: [(keys: String, label: String)],
                         mode: KeyMode) -> [Row] {
        let taken = Set(surface.map(\.keys))
        return surface.map {
            Row(id: "surface:\($0.keys)", keys: $0.keys, label: $0.label)
        } + app.filter { !taken.contains($0.keys) }.map {
            Row(id: "app:\($0.keys)", keys: $0.keys, label: $0.label)
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
