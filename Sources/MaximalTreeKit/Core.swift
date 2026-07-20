import Foundation

// MARK: - NodeID

/// A node's stable identity, encoded as a canonicalized URI.
///
/// The scheme routes to the owning provider (`file`, `git`, …). Everything after
/// the scheme is opaque to the host and to other plugins — only the owning
/// provider interprets it. Always construct through the failable `init(_:)` (or a
/// provider-specific helper) so the value is canonical before it is ever used as a
/// key; two spellings of the same node must collapse to one `NodeID`.
public struct NodeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uri: String

    /// Trusted initializer for an already-canonical string. Prefer `init(_:)`.
    public init(canonical uri: String) { self.uri = uri }

    /// Canonicalizing initializer. Returns nil for input that isn't a usable URI.
    public init?(_ raw: String) {
        guard let c = NodeID.canonicalize(raw) else { return nil }
        self.uri = c
    }

    /// The lowercased scheme, used by the host purely for provider routing.
    public var scheme: String? {
        if let r = uri.range(of: "://") {
            return String(uri[uri.startIndex..<r.lowerBound]).lowercased()
        }
        if let c = uri.firstIndex(of: ":") {
            return String(uri[uri.startIndex..<c]).lowercased()
        }
        return nil
    }

    public var description: String { uri }

    static func canonicalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // File URLs get path standardization (resolves `.`/`..`, collapses `//`).
        // Symlinks are intentionally NOT resolved — the mounted path is identity.
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return trimStroke(url.standardizedFileURL.absoluteString)
        }
        guard var comps = URLComponents(string: trimmed) else { return nil }
        comps.scheme = comps.scheme?.lowercased()
        return trimStroke(comps.string ?? trimmed)
    }

    /// Drop a single trailing slash so `…/foo` and `…/foo/` are one identity,
    /// but never collapse an authority root like `scheme://`.
    private static func trimStroke(_ s: String) -> String {
        guard s.count > 1, s.hasSuffix("/"), !s.hasSuffix("://") else { return s }
        let dropped = String(s.dropLast())
        return dropped.hasSuffix(":") ? s : dropped
    }
}

// MARK: - TypeID

/// Identifies a node's type, e.g. `"file.directory"`. Owns which `TypeRenderer`
/// and which actions apply. Reverse-DNS-ish by convention, opaque in practice.
public struct TypeID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.raw = value }
    public var description: String { raw }
}

// MARK: - Attributes

/// Small, queryable per-node metadata. NOT the node's content — content is loaded
/// lazily through the provider/renderer. Keep this cheap; it rides in the sidebar.
public struct Attributes: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case date(Date)
    }

    private var storage: [String: Value]
    public init(_ storage: [String: Value] = [:]) { self.storage = storage }

    public subscript(_ key: String) -> Value? {
        get { storage[key] }
        set { storage[key] = newValue }
    }
}

// MARK: - Presentation

/// A node's icon, supplied by the plugin that owns it. The host never guesses an
/// icon from a node's type — presentation is the provider's business.
public struct NodeIcon: Hashable, Sendable {
    /// An SF Symbol name — the fallback when `imageData` is absent or invalid.
    public let systemName: String
    public let tint: NodeTint?
    /// A raster icon (favicons, thumbnails). Keep it tiny — it rides in the
    /// node record through the sidebar. Rendered in place of the symbol.
    public let imageData: Data?

    public init(_ systemName: String, tint: NodeTint? = nil, imageData: Data? = nil) {
        self.systemName = systemName
        self.tint = tint
        self.imageData = imageData
    }
}

/// Icon colors. Named cases cover the common palette; `.rgb` is the escape hatch.
public enum NodeTint: Hashable, Sendable {
    case accent, secondary, blue, green, orange, red, purple, yellow, gray
    case rgb(red: Double, green: Double, blue: Double)
}

// MARK: - Node

/// A single entry in the forest. Identity + type + cheap metadata. No payload.
/// Marks a node as *phony*: not a document of its own, but a pointer into a
/// specific part of its nearest real ancestor. Opening a phony node opens the
/// anchor's `node` instead — one shared canvas and editing buffer — and hands
/// that canvas the `fragment` so it can jump to the right place. The fragment
/// format is a contract between the provider and the canvas plugin (the typst
/// plugin uses `"line=N"`); the host just delivers it.
///
/// This is what makes org-style outlines work properly: a document's headings
/// appear as sidebar nodes, but they all edit the same buffer.
public struct NodeAnchor: Hashable, Sendable {
    public let node: NodeID
    public let fragment: String?

    public init(node: NodeID, fragment: String? = nil) {
        self.node = node
        self.fragment = fragment
    }
}

public struct Node: Identifiable, Hashable, Sendable {
    public let id: NodeID
    public let type: TypeID
    /// Display label, supplied by the owning plugin. Defaults to the last URI segment.
    public var label: String
    /// Display icon, supplied by the owning plugin.
    public var icon: NodeIcon?
    public var attributes: Attributes
    /// Cheap hint so the sidebar can show a disclosure triangle without loading
    /// children. Providers may set this from metadata (e.g. directory bit).
    public var hasChildren: Bool
    /// Non-nil makes this a phony node — see `NodeAnchor`.
    public var anchor: NodeAnchor?

    public init(
        id: NodeID,
        type: TypeID,
        label: String? = nil,
        icon: NodeIcon? = nil,
        attributes: Attributes = .init(),
        hasChildren: Bool = false,
        anchor: NodeAnchor? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label ?? Node.lastSegment(of: id)
        self.icon = icon
        self.attributes = attributes
        self.hasChildren = hasChildren
        self.anchor = anchor
    }

    private static func lastSegment(of id: NodeID) -> String {
        let s = id.uri
        if let slash = s.lastIndex(of: "/"), slash != s.index(before: s.endIndex) {
            return String(s[s.index(after: slash)...])
        }
        return s
    }

    /// The content-type identifier (UTI string) a provider attached, if any.
    /// Renderers match on this to target content types (e.g. plain text) without an
    /// explosion of `TypeID`s. The structural `type` stays coarse for the tree.
    public var uti: String? {
        if case .string(let value)? = attributes["uti"] { return value }
        return nil
    }
}

// MARK: - Pagination

public struct Cursor: Hashable, Sendable, Codable {
    public let token: String
    public init(_ token: String) { self.token = token }
}

public struct Page<Element: Sendable>: Sendable {
    public let items: [Element]
    public let next: Cursor?
    public init(items: [Element], next: Cursor? = nil) {
        self.items = items
        self.next = next
    }
}

// MARK: - Related

/// A named forward link to another node (commit → parent, table → FK target).
/// Surfaced in the inspector; navigated by resolving `target` and calling `open`.
/// This is how "graph-ness" is expressed without the host storing edges.
public struct Related: Hashable, Sendable, Identifiable {
    public var id: String { label + "\u{1}" + target }
    public let label: String
    public let target: String   // a URI, resolved on demand by its owning provider
    public init(label: String, target: String) {
        self.label = label
        self.target = target
    }
}
