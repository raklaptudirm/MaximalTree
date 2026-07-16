import SwiftUI

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

    public init(_ icon: NodeIcon?) { self.icon = icon }

    public var body: some View {
        Image(systemName: icon?.systemName ?? "circle")
            .foregroundStyle(icon?.tint?.color ?? Color.secondary)
    }
}
