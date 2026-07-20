import SwiftUI
import AppKit

public extension NodeTint {
    /// The SwiftUI color for this tint. Lives in the SDK so the host and every
    /// plugin resolve tints identically.
    var color: Color {
        switch self {
        case .accent:    return .accentColor
        case .secondary: return .secondary
        case .blue:      return .blue
        case .green:     return .green
        case .orange:    return .orange
        case .red:       return .red
        case .purple:    return .purple
        case .yellow:    return .yellow
        case .gray:      return .gray
        case .rgb(let r, let g, let b): return Color(red: r, green: g, blue: b)
        }
    }
}

/// Renders a node's plugin-provided icon, with a neutral fallback when a provider
/// hasn't supplied one. Use this everywhere a node is listed.
public struct NodeIconView: View {
    private let icon: NodeIcon?
    private let overrideTint: Color?

    /// - Parameter tint: Overrides the icon's own tint. Pass this for states where
    ///   the provider's color wouldn't read — e.g. white on a selected row's fill.
    public init(_ icon: NodeIcon?, tint overrideTint: Color? = nil) {
        self.icon = icon
        self.overrideTint = overrideTint
    }

    public var body: some View {
        if let data = icon?.imageData, let image = NSImage(data: data) {
            // Raster icon (a favicon, say) — sized to sit like a symbol glyph.
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: icon?.systemName ?? "circle")
                .foregroundStyle(overrideTint ?? icon?.tint?.color ?? Color.secondary)
        }
    }
}
