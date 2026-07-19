import AppKit

// The rendered-math seam: a renderer (the typst plugin's compiler) turns
// equation source into baseline-annotated images the editor floats over
// reserved space. See the coordinator's renderMath/layoutMathOverlays.

public struct RenderedEquation {
    public let image: NSImage
    public let baseline: CGFloat

    public init(image: NSImage, baseline: CGFloat) {
        self.image = image
        self.baseline = baseline
    }
}

/// Renders equations for the inline math preview. Return a cached result
/// immediately, or nil while producing one asynchronously — then call
/// `completion` (once, on success only) and the editor repaints with it. On
/// failure return nil and never complete; the editor keeps the monospace
/// source. `block` distinguishes display equations: they render as standalone
/// blocks (tight, no surrounding-line machinery) and the editor centers them
/// in their line instead of baseline-aligning.
@MainActor
public protocol EditorMathRenderer: AnyObject {
    func renderedMath(for equation: String, fontSize: CGFloat, dark: Bool,
                      block: Bool,
                      completion: @escaping @MainActor () -> Void) -> RenderedEquation?
}

/// Token colors, resolved per appearance. Values carried over from the previous
/// Xcode-like themes so highlighting looks unchanged across the engine swap.
/// Presentation kinds map onto semantic colors for code styles; in markup-rendering
/// styles most of them are drawn as *formatting* instead (see the coordinator).
