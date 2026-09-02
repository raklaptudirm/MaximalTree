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
                .background(PaneSurfaceAccessor(pane: leftID))
            Canvas(found: rightBox).frame(width: 200, height: 200)
                .background(PaneSurfaceAccessor(pane: rightID))
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

        #expect(PaneSurfaces.focusTarget(of: left.id, in: window) === left.canvas)
        #expect(PaneSurfaces.focusTarget(of: right.id, in: window) === right.canvas)
    }

    /// Which is only possible because the panes occupy different rectangles,
    /// and those rectangles are read fresh rather than remembered.
    @Test func surfacesKnowTheirOwnRectangles() async throws {
        let (left, right, window) = try await twoPanes()
        defer { window.orderOut(nil) }

        let leftFrame = try #require(PaneSurfaces.frame(of: left.id))
        let rightFrame = try #require(PaneSurfaces.frame(of: right.id))
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
        .background(PaneSurfaceAccessor(pane: pane))

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
        #expect(PaneSurfaces.focusTarget(of: pane, in: window) === canvas,
                "a tall document is still the canvas in this pane")
    }

    @Test func aPaneThatIsNotOnScreenHasNoSurface() {
        #expect(PaneSurfaces.frame(of: UUID()) == nil)
        #expect(PaneSurfaces.focusTarget(of: UUID(), in: nil) == nil)
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
                .background(PaneSurfaceAccessor(pane: pane))
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

        let leftTarget = PaneSurfaces.focusTarget(of: left, in: window)
        let rightTarget = PaneSurfaces.focusTarget(of: right, in: window)

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

