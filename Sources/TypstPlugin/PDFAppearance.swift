import AppKit
import CoreImage
import PDFKit

/// Dark mode for the typeset preview.
///
/// A compiled document is white paper, which in a dark room is a lamp pointed
/// at the reader. The page itself can't be recoloured — it's the PDF the user
/// exports, and it has to stay what it is — so the *view* is filtered instead,
/// the way a PDF reader's night mode is.
///
/// Inverting alone would darken the page but rotate every hue halfway round
/// the wheel: blue links coming out orange, photographs as negatives. The
/// standard treatment pairs the inversion with a 180° hue rotation, which puts
/// the hues back where they started and leaves only the lightness flipped —
/// dark page, light text, and colours that still look like themselves.
enum PDFAppearance {
    /// What the area around the pages should look like once the filters have
    /// had their way with it — near enough to the editor column's background
    /// that the two halves of the split agree.
    ///
    /// Deliberately neutral. A hue rotation leaves an unsaturated colour
    /// exactly where it found it, so the colour we have to assign is precisely
    /// the inversion of this one; give it a tint and the assigned value becomes
    /// an approximation, because CIHueAdjust doesn't rotate hues the way HSB
    /// does.
    static let darkGutter = NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255,
                                    blue: 0x2A / 255, alpha: 1)

    /// Apply (or remove) the inversion. `defaultBackground` is whatever PDFKit
    /// started with, restored in light mode so nothing changes there.
    static func apply(dark: Bool, to view: PDFView, defaultBackground: NSColor?) {
        // Core Image filters on a layer are opt-in on macOS. Without this the
        // filter is accepted and then silently ignored, which looks exactly
        // like the feature not being wired up at all.
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true

        guard dark else {
            view.layer?.filters = []
            if let defaultBackground { view.backgroundColor = defaultBackground }
            return
        }
        view.layer?.filters = filters()
        // The gutter is inside the view, so it goes through the same treatment:
        // assign the colour that *comes out* as the one we want.
        view.backgroundColor = preTreated(darkGutter)
    }

    /// The night-mode chain, in the order the layer applies it.
    static func filters() -> [CIFilter] {
        [CIFilter(name: "CIColorInvert"),
         CIFilter(name: "CIHueAdjust", parameters: ["inputAngle": Float.pi])]
            .compactMap { $0 }
    }

    /// The colour that comes out of `filters()` as `color`. Both steps are
    /// their own inverse — inversion obviously, and a 180° rotation because
    /// turning twice more comes back round — so undoing the chain is the same
    /// chain, applied in reverse order.
    static func preTreated(_ color: NSColor) -> NSColor {
        inverted(hueRotated(color))
    }

    /// `color` with its hue turned half a revolution.
    static func hueRotated(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return NSColor(hue: (rgb.hueComponent + 0.5).truncatingRemainder(dividingBy: 1),
                       saturation: rgb.saturationComponent,
                       brightness: rgb.brightnessComponent,
                       alpha: rgb.alphaComponent)
    }

    /// The colour that, once inverted, reads as `color`.
    static func inverted(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return NSColor(srgbRed: 1 - rgb.redComponent,
                       green: 1 - rgb.greenComponent,
                       blue: 1 - rgb.blueComponent,
                       alpha: rgb.alphaComponent)
    }
}
