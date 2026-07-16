# Hacking on MaximalTree

MaximalTree is a plugin-extensible graph explorer for macOS — think "Finder, but
for arbitrary kinds of objects." The host provides a three-pane shell; plugins teach
it about new object types and how to view and manipulate them.

This document is for two audiences:

- **Contributors** working on the host itself — start at [Architecture](#architecture).
- **Plugin authors** — skim the architecture, then jump to [Writing a plugin](#writing-a-plugin).

---

## Mental model

Everything you navigate is a **node** in a **forest**. A node has a stable identity
(a URI), a type, and some cheap metadata. The host owns the *topology* — which nodes
exist and how they nest — but knows nothing about what any given node *is*. A plugin
owns the *content and semantics* of the types it registers: how to list children, how
to draw the node on the canvas, what actions apply to it.

The three panes are all generic and registry-driven:

```
┌───────────────┬────────────────────────────┬─────────────────┐
│  Explorer     │  Canvas                    │  Inspector      │
│  (sidebar)    │  (focused node's renderer) │  (renderer)     │
│               │                            │                 │
│  walks the    │  arbitrary SwiftUI, the    │  controls for   │
│  containment  │  plugin's "escape hatch"   │  the focused    │
│  tree         │                            │  node           │
└───────────────┴────────────────────────────┴─────────────────┘
```

The host resolves the focused node's type to a `TypeRenderer` and asks the owning
plugin to fill the canvas and inspector. It never special-cases `file.directory` or
any other type.

---

## Repository layout

```
project.yml                     # XcodeGen project definition — THE source of truth
Sources/
  MaximalTreeKit/               # the plugin SDK (dynamic framework)
    Core.swift                  #   NodeID, TypeID, Node, NodeIcon/Tint, Attributes, Related
    Provider.swift              #   NodeProvider + NodeBroker protocols
    IconView.swift              #   NodeIconView + tint→Color (shared by host + plugins)
    Mutation.swift              #   GraphMutation, NodeChange, MutatingNodeProvider
    HostContext.swift           #   @Observable HostContext + GraphBackend seam
    Interface.swift             #   Action, Canvas/InspectorContribution, Plugin, Registry
  MaximalTree/                  # the host app
    App.swift                   #   @main, AppModel wiring
    Host/                       #   Registry, GraphStore, HostBroker, NavigationModel, Workspace, PluginHost
    UI/                         #   Shell (3 panes + tabs) + Commands (menu/palette)
  FileSystemPlugin/             # reference provider plugin (loadable bundle)
    FileSystem.swift            #   provider, mutations, principal class, actions
    FileViews.swift             #   canvas (Quick Look) + inspector (editable)
  TextEditorPlugin/             # reference cross-plugin renderer (loadable bundle)
    TextEditor.swift            #   high-priority text canvas over filesystem files
  GitPlugin/                    # reference non-file provider (loadable bundle)
    Git.swift                   #   git:// URI model, git CLI, provider, mount action
    GitViews.swift              #   commit / list canvases + inspector
Tests/MaximalTreeTests/         # swift-testing suite (35 tests)
```

The generated `MaximalTree.xcodeproj` is **not** committed — regenerate it (below).

---

## Building and running

Requires a full Xcode (not just Command Line Tools) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

> **Toolchain note:** on this machine `xcode-select` points at Command Line Tools,
> which can't run `xcodebuild` and lacks the testing frameworks. Every `xcodebuild`
> command below is therefore prefixed with `DEVELOPER_DIR=…`. If your `xcode-select`
> already points at Xcode, you can drop the prefix.

```sh
# Generate the Xcode project from project.yml (run after adding/moving files)
xcodegen generate

# Build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project MaximalTree.xcodeproj -scheme MaximalTree \
  -destination 'platform=macOS' build

# Test
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project MaximalTree.xcodeproj -scheme MaximalTree \
  -destination 'platform=macOS' test
```

Or just open `MaximalTree.xcodeproj` in Xcode and ⌘R / ⌘U.

---

## Architecture

### Identity: URI-encoded `NodeID`

A node's identity **is** a canonicalized URI (`Core.swift`). The scheme routes to the
owning provider (`file://…`, `git://repo/commit/abc`); everything after it is opaque
to the host and to other plugins. Always build a `NodeID` through the failable
`init(_:)` so it's canonicalized (trailing slashes, path standardization, lowercased
scheme) before it's ever used as a key — two spellings of the same node must collapse
to one identity.

Identity is coupled to location by design. When a node is renamed/moved, its identity
changes; a provider signals this with a rename event so the host can remap open state
(rename events are part of the write path, not yet implemented — see
[What's not done](#whats-not-done-yet)).

### Structure: a forest, not a general graph

Containment is the only host-level relationship, expressed lazily through
`NodeProvider.children(of:)`. There is deliberately **no** general edge store.
Semantic references (a commit's parents, a table's foreign keys) are *provider-resolved
forward links* — `NodeProvider.related(to:)` returns `Related` values that the
inspector renders and navigates via `HostContext.openURI(_:)`. A plugin that wants to
draw a real node-link diagram holds its own edges locally on its canvas; the host
never needs to know.

### The observation boundary: `HostContext`

`HostContext` (`HostContext.swift`) is a concrete `@Observable` class in the SDK — not
a protocol — so plugin SwiftUI can hold it via `@Environment(HostContext.self)` and
observe it by reference. It exposes reads (`node(_:)`, `children(of:)`, `related(of:)`)
and commands (`open`, `select`, `mount`, `openURI`). Its cache dictionaries are the
observable source of truth for the UI.

The host's `GraphStore` implements the `GraphBackend` protocol that `HostContext`
delegates to. **Everything a plugin can trigger funnels through `GraphBackend`.** That
indirection is deliberate: it's the seam that could later be backed by XPC if a plugin
ever needs to run out of process, without changing the plugin-facing API.

### Laziness and threading

Providers are `Sendable` and their data methods are `async`, expected to run **off the
main actor** (they hit filesystems, APIs, DBs). Views are `@MainActor`. Reading
`children(of:)` in a SwiftUI body returns what's cached and kicks off an async load via
the backend; when it lands, the observable cache updates and the view re-renders. Never
block the main actor in a provider.

### Presentation is the provider's job

`Node` carries a plugin-supplied `label` and `icon` (`NodeIcon`: an SF Symbol + a
`NodeTint`). **The host never guesses an icon from a node's type** — if you find a
`type == "file.…"` check in `Sources/MaximalTree/`, that's a bug. Render nodes with
`NodeIconView(node.icon)` (in the SDK, so host and plugins resolve tints identically).

### Composing across plugins

A provider can ask the host for nodes owned by *other* providers via `NodeBroker`
(`PluginRegistry.broker`, stored on your provider at registration):

```swift
registry.register(provider: MyProvider(broker: registry.broker))
// …later, inside the provider:
let files = await broker.children(of: "file:///some/dir", page: nil)
```

The broker routes a URI to whoever owns its scheme. This is how the git plugin makes a
repo node cohesive — it lists Branches, Commits, **and** the working tree by asking
whoever owns `file://`, so the files arrive with the FileSystem plugin's labels, icons,
and metadata (and stay editable by the TextEditor plugin) instead of being re-listed
and re-implemented. Foreign children just work afterwards: the host routes each node by
its *own* scheme, so navigating into them uses their real owner.

### Writes

Structural edits go through a small, host-defined vocabulary — `GraphMutation`
(`.rename`, `.delete`; more later) — that providers opt into by conforming to
`MutatingNodeProvider`. `apply(_:)` **returns the `NodeChange`s it caused**
(`.renamed(from:to:)`, `.removed`, `.childrenChanged`), and the host applies those to
its caches and remaps navigation history/selection — crucial because a rename changes a
node's `NodeID`. Call `HostContext.apply(_:)` to trigger one, `canApply(_:)` to gate UI.

*Content* editing (a file's bytes) is **not** a `GraphMutation` — that vocabulary is for
tree structure. Content is type-specific manipulation a plugin does directly via its
canvas (see `TextEditorPlugin` writing files). Keep the two distinct.

### The plugin model (option A)

Plugins are **in-process loadable bundles** that link the shared
`MaximalTreeKit.framework` "Do Not Embed" and are `dlopen`'d at launch. This was chosen
over ExtensionKit/XPC specifically to allow **native SwiftUI with by-reference model
sharing** — a plugin observes the live `HostContext` directly. The accepted tradeoffs:
a plugin crash takes down the window, and plugins are unsandboxed. The assumed trust
model is *you + trusted contributors*, not an untrusted third-party store. (If that
changes, the `GraphBackend` seam is the migration path to out-of-process.)

### How loading works

`PluginHost.loadAll()` (`Host/PluginHost.swift`):

1. Enumerates `Bundle.main.builtInPlugInsURL` (the app's `Contents/PlugIns/`).
2. For each `.bundle`: `Bundle.load()`, then `principalClass as? Plugin.Type`.
3. `cls.init()`, then `plugin.register(with: registry)`.

Registration is **one-shot at load**: a plugin declares what it *can* handle, not what
exists. Nothing is instantiated per-node until a node of that type is focused.

---

## Writing a plugin

Two references to read alongside this section: **FileSystem** (`Sources/FileSystemPlugin/`)
for a path-backed, writable provider, and **Git** (`Sources/GitPlugin/`) for a
non-file provider — it shows how to encode a non-path scheme as canonicalizable
NodeIDs (`git://<kind>/<id>?repo=…`), model *synthetic* containment (Branches/Commits
folders), and emit cross-references, including one into *another* provider (a commit's
file → the `file://` working-tree node).

### 1. A `NodeProvider`

Vends nodes for one or more URI schemes. Only `schemes`, `resolve`, `node(for:)`, and
`children(of:page:)` are required; the rest have defaults.

Give every node a `label` and an `icon` — that's how it renders everywhere.

```swift
struct MyProvider: NodeProvider {
    let schemes: Set<String> = ["myscheme"]

    func roots() -> [NodeID] { /* default roots to seed an empty workspace */ [] }
    func resolve(_ uri: String) -> NodeID? { NodeID(uri) /* validate + canonicalize */ }
    func node(for id: NodeID) async -> Node? { /* type, attributes, hasChildren */ }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> { /* … */ }
    func related(to id: NodeID) async -> [Related] { /* forward links, optional */ [] }
}
```

Do slow work off-main (e.g. wrap it in `Task.detached`). Canonicalize any URI you
mint through `NodeID`.

### 2. Canvas / inspector contributions

Renderers are resolved by **matcher + priority**, not by exact type — so a plugin can
render node types owned by a *different* plugin, and a more specific renderer can
override a general one. The host picks the single highest-priority matching **canvas**,
and composes **all** matching **inspectors** as stacked sections.

```swift
// Match a content type and outrank the default renderer:
registry.register(canvas: CanvasContribution(
    priority: 100,
    matches: { node in node.uti == "public.plain-text" },
    make: { id, host in AnyView(MyEditor(id: id).environment(host)) }))

// Or the common "exactly this structural type" case:
registry.registerCanvas(forType: "myscheme.thing") { id, host in
    AnyView(ThingCanvas(id: id).environment(host))
}
registry.registerInspector(forType: "myscheme.thing") { id, host in
    AnyView(ThingInspector(id: id).environment(host))
}
```

`AnyView` erasure at the boundary is the cost of a heterogeneous registry; inside your
views write ordinary strongly-typed SwiftUI. Pass `HostContext` into the environment so
your views can observe it. Providers should attach a UTI via `attributes["uti"]` so
content-type matchers work (`TextEditorPlugin` is the reference for cross-plugin
rendering).

### 3. `Action`s (optional)

One registry feeds the menu bar and the command palette; each surface filters by the
action's `appliesTo` predicate (`.always`, `.type(_)`, or `.custom { ctx in … }`).

```swift
Action(id: "myscheme.doThing", title: "Do the Thing",
       systemImage: "wand.and.stars", appliesTo: .type("myscheme.thing")) { ctx in
    // ctx.selection, ctx.selectedNodes, ctx.host
}
```

### 4. The principal class

Your entry point **must** be Obj-C-discoverable so `NSPrincipalClass` resolves it:

```swift
@objc(MyPlugin)                       // pins the unmangled runtime name
final class MyPlugin: NSObject, Plugin {
    override init() { super.init() }
    func register(with registry: PluginRegistry) {
        registry.register(provider: MyProvider())
        registry.register(renderer: /* … */)
        registry.register(action: /* … */)
    }
}
```

### 5. The bundle target (in `project.yml`)

Add a `bundle` target and copy it into the app's `PlugIns`:

```yaml
  MyPlugin:
    type: bundle
    platform: macOS
    sources: [Sources/MyPlugin]
    dependencies:
      - target: MaximalTreeKit
        embed: false                          # Do Not Embed — use the host's copy
    settings:
      base:
        PRODUCT_NAME: My
        INFOPLIST_KEY_NSPrincipalClass: MyPlugin
        LD_RUNPATH_SEARCH_PATHS: ["@loader_path/../../../../Frameworks"]
```

Then, on the `MaximalTree` app target, add it as a copied dependency:

```yaml
      - target: MyPlugin
        embed: true          # NB: 'embed: true' is what enables the copy phase
        link: false          # never link a loadable bundle into the app
        copy: { destination: plugins, codeSign: true }
```

Run `xcodegen generate` and build. Watch the console for
`[MaximalTree] loaded plugin My.bundle`.

> **Gotchas that will bite you:**
> - `embed: false` on the app→plugin dependency silently produces *no* copy phase.
>   Use `embed: true` + `copy.destination: plugins`.
> - A plain Swift class won't be found by `NSPrincipalClass` — it gets mangled to
>   `Module.Class`. Use `@objc(Name)` on an `NSObject` subclass.
> - You **cannot reliably unload** a loaded bundle (dlopen limitation). Hot-swapping a
>   plugin means relaunching the host.

---

## Conventions

- **Swift 6 language mode** is on (`SWIFT_VERSION: "6.0"`) with complete data-race
  checking. Keep providers `Sendable` and do UI/host work on `@MainActor`.
- **The host stays type-agnostic.** If you find yourself writing `if type == "file.…"`
  in `Sources/MaximalTree/`, that's a smell — the knowledge belongs in a plugin.
- **Route through `HostContext`.** Plugins must never reach into host internals; the
  context is the whole contract.
- `MaximalTreeKit` is built with library evolution on. Keep its public API additive so
  plugins compiled against an older SDK keep loading.

---

## What's not done yet

Working today: navigation (tabs + history), cross-plugin rendering, and structural
writes (rename + delete-to-Trash). Known gaps, roughly in order:

- **More mutations** — `.move` (needs tree drag-and-drop) and `.create`; content-write
  isn't modelled beyond direct plugin file writes.
- **External change feed** — the host reacts to changes *it* makes, but nothing watches
  for edits by other apps yet. `NodeChange` is designed to carry these when a provider
  change-stream (FSEvents/`DispatchSource`) is added.
- **Dynamic plugins** — loading is launch-time from the bundled `PlugIns/`. No external
  user plugin directory, enable/disable, or revocable registrations yet.
- **Smaller**: context-menu action surface, richer inspector composition, undo.
