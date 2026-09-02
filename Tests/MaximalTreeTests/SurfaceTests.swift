import Testing
import AppKit
import SwiftUI
@testable import MaximalEditorKit
@testable import MaximalTree

/// Moving to a surface has to put the keyboard *in* it, which means finding
/// the canvas that particular pane is showing.
///
/// The tempting way — register the view containing a pane, search its subtree
/// — cannot work, and quietly did nothing when it was tried: SwiftUI flattens
/// the window into one hosting view, so a pane's marker is a sibling of its
/// canvas, not an ancestor. These check the approach that replaced it, which
/// tells panes apart by where they are.
@MainActor
@Suite struct PaneSurfaceTests {
    /// Stands in for a canvas: an AppKit view that takes the keyboard.
    private struct Canvas: NSViewRepresentable {
        let found: Box
        final class Box { var view: NSView? }

        func makeNSView(context: Context) -> KeyTaking {
            let view = KeyTaking()
            found.view = view
            return view
        }
        func updateNSView(_ view: KeyTaking, context: Context) {}
    }

    private final class KeyTaking: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Hosts two side-by-side panes and hands back what each one registered.
    private func twoPanes() async throws -> (left: (id: UUID, canvas: NSView),
                                             right: (id: UUID, canvas: NSView),
                                             window: NSWindow) {
        let leftID = UUID(), rightID = UUID()
        let leftBox = Canvas.Box(), rightBox = Canvas.Box()
        // Sized explicitly: a bare representable has no intrinsic size, and
        // SwiftUI then hands each one the whole area, so the two panes would
        // sit on top of each other and the test would prove nothing.
        let content = HStack(spacing: 0) {
            Canvas(found: leftBox).frame(width: 200, height: 200)
                .background(SurfaceAccessor(.pane(leftID)))
            Canvas(found: rightBox).frame(width: 200, height: 200)
                .background(SurfaceAccessor(.pane(rightID)))
        }

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        return ((leftID, try #require(leftBox.view)),
                (rightID, try #require(rightBox.view)), window)
    }

    /// The point of all of it: each pane resolves to its own canvas, not to
    /// whichever one happens to come first in the window.
    @Test func eachSurfaceResolvesToItsOwnCanvas() async throws {
        let (left, right, window) = try await twoPanes()
        defer { window.orderOut(nil) }

        #expect(Surfaces.focusTarget(of: .pane(left.id), in: window) === left.canvas)
        #expect(Surfaces.focusTarget(of: .pane(right.id), in: window) === right.canvas)
    }

    /// Which is only possible because the panes occupy different rectangles,
    /// and those rectangles are read fresh rather than remembered.
    @Test func surfacesKnowTheirOwnRectangles() async throws {
        let (left, right, window) = try await twoPanes()
        defer { window.orderOut(nil) }

        let leftFrame = try #require(Surfaces.frame(of: .pane(left.id), in: window))
        let rightFrame = try #require(Surfaces.frame(of: .pane(right.id), in: window))
        #expect(!leftFrame.intersects(rightFrame), "side-by-side panes overlap")
        #expect(leftFrame.minX < rightFrame.minX, "the left pane should be the left one")
    }

    /// A document taller than the pane showing it — which is most documents.
    /// Its frame runs far past the pane's, so its *centre* is nowhere near it;
    /// only the part on screen is. Judging by the centre found nothing here,
    /// and finding nothing drops the keyboard on the window, which is what
    /// made every later step a no-op until you clicked back in.
    @Test func aScrolledDocumentIsStillFoundInItsPane() async throws {
        let pane = UUID()
        let box = Canvas.Box()
        let content = ScrollView {
            Canvas(found: box).frame(width: 200, height: 4000)
        }
        .background(SurfaceAccessor(.pane(pane)))

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(50))

        let canvas = try #require(box.view)
        #expect(canvas.frame.height > 1000, "the document should overflow its pane")
        #expect(Surfaces.focusTarget(of: .pane(pane), in: window) === canvas,
                "a tall document is still the canvas in this pane")
    }

    @Test func aSurfaceThatIsNotOnScreenHasNoFrame() {
        #expect(Surfaces.frame(of: .pane(UUID()), in: nil) == nil)
        #expect(Surfaces.focusTarget(of: .pane(UUID()), in: nil) == nil)
    }
}

/// The same question against the real editor in the real pane wrapping, since
/// the synthetic canvas above passed while the app did not.
@MainActor
@Suite struct RealPaneSurfaceTests {
    /// What `PaneView` actually puts around a canvas.
    private struct PaneLike<Content: View>: View {
        let pane: UUID
        @ViewBuilder let content: () -> Content

        var body: some View {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .background(SurfaceAccessor(.pane(pane)))
        }
    }

    @Test func theRealEditorIsFoundInItsPane() async throws {
        let left = UUID(), right = UUID()
        let text = Binding.constant(String(repeating: "a line of text\n", count: 400))

        let content = HStack(spacing: 0) {
            PaneLike(pane: left) { MaximalEditor(text: text) }
            PaneLike(pane: right) { MaximalEditor(text: text) }
        }

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        let leftTarget = Surfaces.focusTarget(of: .pane(left), in: window)
        let rightTarget = Surfaces.focusTarget(of: .pane(right), in: window)

        let leftEditor = try #require(leftTarget as? MaximalEditor.EditorTextView,
                                      "no editor found for the left pane")
        let rightEditor = try #require(rightTarget as? MaximalEditor.EditorTextView,
                                       "no editor found for the right pane")
        #expect(leftEditor !== rightEditor, "both panes resolved to the same editor")

        // And the thing the app actually does with it has to take.
        #expect(window.makeFirstResponder(rightEditor), "the editor refused the keyboard")
        #expect(window.firstResponder === rightEditor)
    }
}


/// Which surface holds the keyboard, asked of a real editor.
@MainActor
@Suite struct FocusedSurfaceTests {
    private struct Region: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    /// A document is far taller than the pane it scrolls in, so the middle of
    /// the text view is nowhere near the pane — often outside the window
    /// altogether. Judged by that, the editor belonged to no surface at all
    /// and the answer fell back to the sidebar: the sidebar stayed highlighted
    /// while you typed in the editor, and movement thought it was starting
    /// from the sidebar.
    @Test func aFocusedEditorBelongsToItsPaneHoweverLongTheDocumentIs() async throws {
        let pane = UUID()
        let text = Binding.constant(String(repeating: "a line of text\n", count: 500))
        let content = HStack(spacing: 0) {
            Region().frame(width: 100).background(SurfaceAccessor(.sidebar))
            MaximalEditor(text: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .background(SurfaceAccessor(.pane(pane)))
        }

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))

        let editor = try #require(Surfaces.focusTarget(of: .pane(pane), in: window))
        #expect(window.makeFirstResponder(editor))
        #expect(Surfaces.focused(in: window) == .pane(pane),
                "the editor has the keyboard, so its pane is the focused surface")
    }
}

/// The sidebar and inspector are surfaces like any canvas, so one rule steps
/// across all of them. They used to be special cases: the sidebar reachable
/// only by a branch written into the movement, the inspector not at all.
@MainActor
@Suite struct SurfaceNeighbourTests {
    private struct Region: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    /// sidebar | left pane / right pane stacked | inspector
    private func window() async throws -> (left: UUID, right: UUID, window: NSWindow) {
        let left = UUID(), right = UUID()
        let content = HStack(spacing: 0) {
            Region().frame(width: 100).background(SurfaceAccessor(.sidebar))
            VStack(spacing: 0) {
                Region().frame(height: 150).background(SurfaceAccessor(.pane(left)))
                Region().frame(height: 150).background(SurfaceAccessor(.pane(right)))
            }
            .frame(width: 200)
            Region().frame(width: 100).background(SurfaceAccessor(.inspector))
        }

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        return (left, right, window)
    }

    @Test func theSidebarIsJustTheSurfaceOnTheLeft() async throws {
        let (left, _, window) = try await self.window()
        defer { window.orderOut(nil) }
        #expect(Surfaces.neighbour(of: .pane(left), moving: .left, in: window) == .sidebar)
        #expect(Surfaces.neighbour(of: .sidebar, moving: .left, in: window) == nil,
                "nothing is left of the leftmost surface")
    }

    @Test func theInspectorIsReachableLikeAnythingElse() async throws {
        let (left, _, window) = try await self.window()
        defer { window.orderOut(nil) }
        #expect(Surfaces.neighbour(of: .pane(left), moving: .right, in: window) == .inspector)
        #expect(Surfaces.neighbour(of: .inspector, moving: .left, in: window) != nil)
    }

    /// Stepping right out of the sidebar finds a pane, not the inspector on
    /// the far side of it: nearest edge wins.
    @Test func movementCrossesOneSurfaceAtATime() async throws {
        let (left, right, window) = try await self.window()
        defer { window.orderOut(nil) }
        let target = Surfaces.neighbour(of: .sidebar, moving: .right, in: window)
        #expect(target == .pane(left) || target == .pane(right),
                "the sidebar's right neighbour should be a pane, not the inspector")
    }

    /// And within the canvas the panes still step between themselves.
    @Test func panesStillStepBetweenThemselves() async throws {
        let (left, right, window) = try await self.window()
        defer { window.orderOut(nil) }
        // The stack puts `left` above `right`; window coordinates are flipped.
        #expect(Surfaces.neighbour(of: .pane(left), moving: .down, in: window) == .pane(right))
        #expect(Surfaces.neighbour(of: .pane(right), moving: .up, in: window) == .pane(left))
    }

    /// A hidden inspector isn't a surface, so nothing steps into it.
    @Test func aSurfaceThatIsNotShowingIsNotThere() async throws {
        let (left, _, window) = try await self.window()
        defer { window.orderOut(nil) }
        #expect(Surfaces.frame(of: .pane(UUID()), in: window) == nil)
        #expect(Surfaces.neighbour(of: .pane(left), moving: .right, in: window) == .inspector,
                "precondition: the inspector is showing in this window")
    }
}

/// A surface has to outlive the particular view that reported it.
///
/// The registry used to hold the marker weakly and read its frame on demand,
/// so a surface existed only while SwiftUI kept that exact NSView alive. It
/// doesn't: rebuilding a subtree deallocates the marker, and the pane dropped
/// out of the registry between one keystroke and the next — so the canvas was
/// not a surface, movement stepped straight past it to the inspector, and a
/// focused editor resolved to the sidebar.
@MainActor
@Suite struct SurfacePersistenceTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }

    private func marker(_ surface: SurfaceID, at frame: CGRect,
                        in window: NSWindow) -> SurfaceAccessor.Marker {
        let marker = SurfaceAccessor.Marker(frame: frame)
        marker.surface = surface
        window.contentView?.addSubview(marker)
        return marker
    }

    @Test func aSurfaceSurvivesTheViewThatReportedIt() {
        let window = window()
        defer { window.orderOut(nil) }
        let id = SurfaceID.pane(UUID())

        autoreleasepool {
            let view = marker(id, at: NSRect(x: 100, y: 0, width: 300, height: 300), in: window)
            #expect(Surfaces.frame(of: id, in: window) != nil, "reporting on its own")
            view.removeFromSuperview()
        }

        #expect(Surfaces.frame(of: id, in: window) != nil,
                "the surface vanished with the view that happened to report it")
    }

    /// But a surface that is really gone — a hidden inspector, a closed pane —
    /// stops being one.
    @Test func aDismantledSurfaceIsForgotten() {
        let window = window()
        defer { window.orderOut(nil) }
        let id = SurfaceID.pane(UUID())
        let view = marker(id, at: NSRect(x: 100, y: 0, width: 300, height: 300), in: window)

        #expect(Surfaces.frame(of: id, in: window) != nil)
        Surfaces.forget(view, for: id)
        #expect(Surfaces.frame(of: id, in: window) == nil)
    }

    /// SwiftUI often builds a replacement before tearing the original down, so
    /// teardown must not clear an entry that something else has already taken.
    @Test func teardownDoesNotClearAReplacement() {
        let window = window()
        defer { window.orderOut(nil) }
        let id = SurfaceID.pane(UUID())
        let old = marker(id, at: NSRect(x: 100, y: 0, width: 300, height: 300), in: window)
        let new = marker(id, at: NSRect(x: 100, y: 0, width: 300, height: 300), in: window)

        Surfaces.forget(old, for: id)
        #expect(Surfaces.frame(of: id, in: window) != nil,
                "the replacement's entry was dropped by the original's teardown")
        Surfaces.forget(new, for: id)
        #expect(Surfaces.frame(of: id, in: window) == nil)
    }
}
