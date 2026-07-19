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
  MaximalEditorKit/             # the ONE target touching the editor engine (STTextView)
    EditorKit.swift             #   MaximalEditor view + style + controller + coordinator
                                #   (markup rendering, concealment, math overlays,
                                #   completion triggering, scroll anchoring)
    EditorHighlighting.swift    #   token vocabulary, palette, Highlightr tokenizer
    EditorCompletion.swift      #   completion seam onto the engine's window
    EditorMath.swift            #   rendered-math seam (baseline-annotated images)
  MaximalTreeKit/               # the plugin SDK (dynamic framework)
    Core.swift                  #   NodeID, TypeID, Node + NodeAnchor (phony nodes),
                                #   NodeIcon/Tint, Attributes, Related
    Provider.swift              #   NodeProvider + NodeBroker protocols
    IconView.swift              #   NodeIconView + tint→Color (shared by host + plugins)
    Mutation.swift              #   GraphMutation, NodeChange, MutatingNodeProvider
    HostContext.swift           #   @Observable HostContext + GraphBackend seam
    Interface.swift             #   Action (+shortcut), Canvas/Inspector/Child
                                #   contributions, Plugin, Registry
  MaximalTree/                  # the host app
    App.swift                   #   @main, AppModel wiring
    Host/                       #   Registry, GraphStore, HostBroker, NavigationModel, Workspace, PluginHost
    UI/                         #   Shell (3 panes + tabs + zen) + Commands (menu/palette)
  FileSystemPlugin/             # reference provider plugin (loadable bundle)
    FileSystem.swift            #   provider, mutations, symlink anchors, actions
    FileViews.swift             #   canvas (Quick Look) + inspector (editable)
  TextEditorPlugin/             # reference cross-plugin renderer (loadable bundle)
    TextEditor.swift            #   Highlightr-highlighted editor over filesystem files
  TypstPlugin/                  # the flagship: typst as a daily driver (loadable bundle)
    TypstCore.swift             #   diagnostics, notes pkg, TypstRef URIs,
                                #   structure/edit helpers (all tested)
    TypstEngine.swift           #   in-process compiler facade: compile, export, math
    TypstLSP.swift              #   minimal JSON-RPC client for tinymist completions
    TypstProvider.swift         #   section/task/agenda nodes (phony), agenda canvas
    TypstPlugin.swift           #   registration, actions, modes, TypstUIState
    TypstCanvas.swift           #   Write/Typeset/Read canvas + inspector + preview
    TypstServices.swift         #   editor-seam impls: tokens, completions, math
  GitPlugin/                    # reference non-file provider (loadable bundle)
    Git.swift                   #   git:// URI model, git CLI, provider, branch anchors
    GitViews.swift              #   commit / list canvases + inspector
Vendor/typst-ffi/               # Rust staticlib: typst compiler/parser/renderers (C ABI)
Tests/MaximalTreeTests/         # swift-testing suite (131 tests)
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

### When the app launches but does nothing

If the window appears but the sidebar is empty and the console shows no
`[MaximalTree] scanning for plugins…` line, SwiftUI **state restoration** is wedged.
The restoration identifier is derived from the *full generic type* of the view tree, so
changing that tree (adding an `.environment`/`.task` modifier, say) can leave AppKit
restoring a window without ever mounting a live `ContentView` — so `.task` never fires
and no plugin ever loads. Symptom: a visible window, an idle main thread, a tiny memory
footprint, and total log silence. Fix:

```sh
rm -rf ~/Library/Saved\ Application\ State/com.maximaltree.app.savedState
```

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
changes; the provider's `apply(.rename)` returns `.renamed(from:to:)` and the host
remaps open tabs, history, and selection (see `GraphStore.process`).

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

### Contributing children to another plugin's nodes

`ChildContribution` (matcher + async children, same pattern as renderers) lets a
plugin hang nodes *under* nodes another provider owns. The host appends contributed
children after the owner's and flips `hasChildren` on matching leaves so the sidebar
offers a disclosure. Reference: the Typst plugin contributes a document's sections
and tasks as children of `.typ` file nodes — the sidebar becomes an org-style
outline, and the contributed nodes are ordinary nodes (their own provider, canvases,
inspector) from there on.

### Phony nodes: pointers into a real node

A node whose `anchor` is set is **phony**: not a document of its own, but a pointer
into a specific part of its nearest real ancestor (`NodeAnchor.node` + an opaque
`fragment`). Opening one opens the *target's* canvas — one shared editing buffer —
with focus, selection, and the inspector all resolving to the real node, and the
fragment posted on `HostContext.activeFragment` for the target's canvas to consume
(`.onChange`, match `target` to your node, honour the one-shot `nonce`). The fragment
format is a private contract between the provider and the canvas plugin; the typst
plugin uses `"line=N"`. This is what makes org-style outlines work properly: every
heading and task in a document is a sidebar node, but they all edit the same buffer.
Any plain navigation clears the pending fragment, so stale jumps never replay.

Reference uses: typst sections/tasks (fragment jumps into the document), git
branches (a branch *is* a pointer to its head commit), filesystem symlinks (opening
one opens the destination's node — one identity per real file).

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

**Side effects outside the mutation path** (an action created a file, an editor saved
bytes) must be reported with `HostContext.notify(_ changes: [NodeChange])` so the host's
caches stay truthful — same funnel, plugin-initiated. `.childrenChanged` refetches a
child list, `.modified` refetches one node record in place. The FileSystem plugin's
"New Folder" action and the TextEditor's save are the reference uses.

### Pagination

`children(of:page:)` may return `Page(items:, next: Cursor(...))`. The cursor is your
own opaque token (the git provider uses a log offset). The host caches it: UI shows a
"More…" affordance when `HostContext.hasMoreChildren(id)`, and
`loadMoreChildren(of:)` fetches the next page and appends it to the cached children.
Providers that vend everything at once just return `next: nil`.

### Workspaces

A **workspace** is a named set of root URIs — host-owned, persisted as an app-managed
library (`workspaces.json` in Application Support; the pre-workspaces single
`workspace.json` migrates automatically). At least one workspace always exists, and
exactly one is active. Switching (toolbar menu, or the Workspace menu with ⌘⌥1–9)
saves nothing and restores everything: tabs, history, focus, and selection reset;
node caches are kept because `NodeID`s stay valid across workspaces. Mount/unmount
persists into the active workspace automatically, no matter who initiated it (UI or a
plugin action). Providers are entirely workspace-unaware.

Seeding is **first-launch-only**: an empty workspace the user made stays empty.

### Canvas splits

Each tab holds a **binary split tree of panes** (`SplitNode` in
`Host/NavigationModel.swift`); arbitrary layouts come from nesting. Every pane has its
own back/forward history, and one pane per tab is *active* — it's what the sidebar
opens into, what the inspector and window subtitle follow, and what actions target.
Split Right (⌘D) / Split Down (⇧⌘D) duplicate the active pane's node into a new active
pane with fresh history; Close Pane (⌃⌘W) collapses the split (the last pane can't
close — that's Close Tab). Renames/deletes remap or drop nodes across every pane of
every tab. None of this touches the plugin API: the host simply instantiates canvases
per pane, so the same node can be open in two panes at once.

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
your views can observe it.

**Zen mode**: `HostContext.isZenMode` is true while the host shows the canvas alone
(no sidebar, inspector, tab strip, or toolbar — toggled from the View menu, ⌃⌘Z).
Canvases should observe it and shed their own chrome too: headers, status rows,
anything that isn't the content. If a hidden control carried a keyboard shortcut,
keep the shortcut alive with a zero-sized stand-in (see the typst canvas's ⌘S).

**`make` must be cheap.** It runs on the main actor during view updates — construct
views, never do I/O or heavy computation there. Slow, movable work (engine warmup,
first-use caches, big file reads) goes in the contribution's optional `prepare`
closure: the host awaits it **off the main actor** before calling `make`, and shows a
loading indicator if it takes more than a beat. `prepare` reruns on every node switch,
so make it idempotent and near-instant once warm (`TypstPlugin` uses it to pay the
engine's one-time system font scan). Work that only your view can do (loading its own
document) should still happen in an async `.task` with a placeholder — never
synchronously on the main actor (`TextEditorPlugin.load()` is the reference). Providers should attach a UTI via `attributes["uti"]` so
content-type matchers work (`TextEditorPlugin` is the reference for cross-plugin
rendering; `TypstPlugin` is the reference for a compiler-backed canvas — it compiles
the unsaved buffer through the bundled in-process engine (Vendor/typst-ffi) on a
debounce and composes an editor, a PDFKit preview, and a diagnostics strip in one
canvas — no external tools involved).

### 3. `Action`s (optional — but the *primary* manipulation surface)

One registry feeds the menu bar, the command palette, the context menu, and the
inspector's Actions section; each surface filters by the action's `appliesTo`
predicate (`.always`, `.type(_)`, or `.custom { ctx in … }`). Pass `shortcut:` and
the menu bar registers it window-wide.

**Design rule: canvases are content.** Don't put headers, toolbars, or control
strips on a canvas — the node's label is already in the window subtitle, tab, and
sidebar, and controls belong here (actions) or in the inspector. What a canvas may
keep: interactions *on* the content (checkboxes in a list, clickable rows), buffer
keybindings registered invisibly (zero-sized buttons — see the typst canvas's ⌘S
and format shortcuts), and at most a corner status dot. The typst plugin is the
reference: mode switching is three actions (⌥⌘1/2/3) plus an inspector picker,
export is actions, word count lives in the inspector.

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

## The editor seam

Plugins that need a text editor use **MaximalEditorKit** (`MaximalEditor` view +
`EditorStyle` + `EditorTokenizer` + `EditorController`) and never import the engine
directly. The framework is embedded once by the app and linked (not embedded) by
plugins. The engine is **[STTextView](https://github.com/krzyzanowskim/STTextView)**
(TextKit 2) — one package with AppKit and UIKit implementations behind the same
import, which is the mobile path. The seam has already survived one full engine
swap (from CodeEditSourceEditor) with zero plugin-code changes; keep it that way.
The framework is split by concern (view/coordinator, highlighting, completion,
math), but only EditorKit.swift touches engine types beyond protocol adapters.

The text binding is live in both directions — external changes push into the view —
but still give each document a per-document `.id(...)` so undo and scroll state
reset. Highlighting is painted as *rendering attributes*: display-only, never
touching the text storage or the undo stack.

Completions ride the engine's built-in window (Escape/F5): pass an
`EditorCompletionProvider` and return `EditorCompletion`s (label, detail, insert
text, optional UTF-16 replace range — otherwise the identifier being typed is
replaced). The typst plugin's provider speaks LSP to
**[tinymist](https://github.com/Myriad-Dreamin/tinymist)** via a small JSON-RPC
stdio client (`TypstLSP.swift`): the server is discovered on well-known install
paths (Homebrew/cargo/nix), documents are synced lazily right before each request,
and everything degrades to "no completions" when the binary is absent. Install
tinymist (`brew install tinymist` / `nix profile install nixpkgs#tinymist`) and
completions — plus the gated live tests — light up with no configuration.

### The mobile plan

An iOS version is intended eventually. The editor is ready for it (same engine,
UIKit implementation, behind this seam). Remaining blockers, in order: the Typst
compile path on iOS uses `Vendor/typst-ffi` (already built — cross-compile the
crate for iOS targets); iOS only executes code shipped in the app, so `PluginHost`
needs the compiled-in registration path there; and routine AppKit swaps (panels,
pasteboard, Quick Look, sidebar material).

## Vendored code

`Vendor/typst-ffi` is our Rust crate binding the typst compiler in-process (see the
Typst plugin sources). It's built by a cargo pre-build phase on the Typst plugin
target; `Cargo.lock` is committed, `target/` is ignored.

Note that Swift dependency versions are pinned only by `project.yml` constraints —
`Package.resolved` lives inside the generated (gitignored) `.xcodeproj`, so it isn't
committed and builds aren't byte-for-byte reproducible across machines.

## Conventions

- **Swift 6 language mode** is on (`SWIFT_VERSION: "6.0"`) with complete data-race
  checking. Keep providers `Sendable` and do UI/host work on `@MainActor`.
- **The host stays type-agnostic.** If you find yourself writing `if type == "file.…"`
  in `Sources/MaximalTree/`, that's a smell — the knowledge belongs in a plugin.
- **Route through `HostContext`.** Plugins must never reach into host internals; the
  context is the whole contract.
- **Don't set `navigationTitle` in a canvas.** The window title belongs to the host
  (workspace name, focused node as subtitle); a canvas that sets its own title
  hijacks it. Your node's name is already shown by the tab strip and subtitle.
- `MaximalTreeKit` is built with library evolution on. Keep its public API additive so
  plugins compiled against an older SDK keep loading.

---

## What's not done yet

Working today: workspaces, tabs + splits + history, cross-plugin rendering, phony
nodes, zen mode, structural writes (rename + delete-to-Trash), and the full typst
stack (in-process compile/preview/export, parser-backed highlighting and outline,
rendered math, tinymist completions). Known gaps, roughly in order:

- **External change feed** — plugins report their *own* side effects via `notify`,
  but nothing watches for edits by other apps yet. A provider change-stream
  (FSEvents/`DispatchSource`) would feed the same `NodeChange` funnel — the typst
  agenda's manual Refresh action is the visible symptom.
- **More mutations** — `.move` (needs tree drag-and-drop) and `.create` as
  first-class vocabulary (creation currently works via actions + `notify`).
- **Dynamic plugins** — loading is launch-time from the bundled `PlugIns/`. No
  external user plugin directory, enable/disable, or revocable registrations yet.
- **Typst follow-ups** — tinymist hover/go-to-definition, snippet tab-stops, and
  a rename event doesn't yet remap a file's `typst://` section nodes in history.
- **The iOS spike** — the hard prerequisites are done (in-process compiler, no
  CLI dependencies, cross-platform editor engine); what remains is target setup,
  compiled-in plugin registration, and AppKit→UIKit view swaps.
- **Smaller**: richer inspector composition, undo for structural mutations,
  multi-select in the directory grid.
