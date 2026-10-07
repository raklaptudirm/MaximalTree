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

The host resolves the focused node to whichever plugin registered a matching canvas and
inspector, and asks it to fill them. It never special-cases `file.directory` or any
other type.

Three more ideas sit above that, and together they are the whole of how the app is
driven:

- **Surfaces** — the areas the window is divided into (sidebar, each pane, inspector).
  One of them holds the keyboard, and they are all alike: commands act on whichever
  one does. A surface is found *geometrically*, not by view ancestry (see below).
- **Commands** — everything the app can do, host and plugin alike, in one registry
  under one id space. Splitting a pane and a plugin's "Export as PDF" are the same
  kind of thing. A command takes a typed argument, may answer, and may fail; an
  **action** is a command plus the title, icon and predicate a surface needs to
  offer it.
- **Modes and keys** — a modal keyboard layer over that registry. In a commanding
  mode a key names an action; in insert mode keys are text. The focused canvas gets
  first refusal on every key before the app's own keymap sees it.

---

## Repository layout

```
project.yml                     # XcodeGen project definition — THE source of truth
Sources/
  MaximalEditorKit/             # the ONE target touching the editor engine (STTextView)
    EditorKeys.swift            #   the editor's commands as actions + their keys
    EditorKit.swift             #   MaximalEditor view + style + controller + coordinator
                                #   (markup rendering, concealment, math overlays,
                                #   completion triggering, scroll anchoring)
    EditorHighlighting.swift    #   token vocabulary, palette, syntax tokenizer
    EditorLanguage.swift        #   file/tag → highlight.js language (130 languages)
    SyntaxEngine.swift          #   highlight.js in a JSContext; HTML → class runs
    MathOverlayLayout.swift     #   where equation images sit (line-exact geometry)
    ViewportAnchor.swift        #   pin the top visible line across a repaint
    EditorCompletion.swift      #   completion seam onto the engine's window
    EditorMath.swift            #   rendered-math seam (baseline-annotated images)
  MaximalTreeCore/              # the SDK's core: no UI. Compiled into the one
                                # MaximalTreeKit framework on macOS, and built
                                # alone by Package.swift (`swift build`/`test`)
    Core.swift                  #   NodeID, TypeID (+ .file/.directory), Node +
                                #   NodeAnchor (phony nodes), NodeIcon/Tint,
                                #   Attributes, Related
    Provider.swift              #   NodeProvider + NodeBroker protocols
    Mutation.swift              #   GraphMutation, NodeChange, MutatingNodeProvider
    Command.swift               #   Command (typed argument + answer), NodeTargets,
                                #   CommandValue (the data form), AnyCommand, errors
    Actions.swift               #   Action (command + presentation), ActionContext,
                                #   ChildContribution, CoreRegistry
    HostContext.swift           #   GraphState (the caches) + ShellState (selection,
                                #   focus, mode) + the HostContext façade over both,
                                #   and the GraphBackend seam
    KeyChord.swift              #   one press, in Emacs notation — a keymap's
                                #   vocabulary and an action's key equivalent alike
    KeyMode.swift               #   the app's one mode (normal/insert/visual)
    UserDataFile.swift          #   reading and writing the reader's own data:
                                #   unreadable files are set aside, never replaced
    Notice.swift                #   Notice/Notices: telling the reader what no command
                                #   failed to do (CoreRegistry.notices)
    Finder.swift                #   FinderSource/FinderItem (a searchable list)
    FeedMerge.swift             #   k-way merge over paged sources (aggregator feeds)
    ChangeStream.swift          #   ChangeStreamingProvider + FileTreeWatcher (FSEvents)
    ExternalEdit.swift          #   what a canvas is told when its bytes changed
  MaximalTreeKit/               # the SDK's SwiftUI half; with MaximalTreeCore, the
                                # plugin SDK (one dynamic framework)
    IconView.swift              #   NodeIconView + tint→Color (shared by host + plugins)
    Interface.swift             #   SurfaceKey/SurfaceKeys, Canvas/Inspector
                                #   contributions, ShellRegistry, PluginRegistry, Plugin
  MaximalTreeHost/              # the host's engine: no UI. Compiled into the Mac app;
                                # Package.swift builds it alone, which proves it
    GraphStore.swift            #   CoreContributions (the registry's core half),
                                #   GraphStore (provider routing, loads, writes)
    Workspace.swift             #   the library + placements per workspace
    Placements.swift            #   the parent→children table
    UndoHistory.swift           #   per-workspace snapshots of placements
    CommandQueue.swift          #   commands that suspend, one at a time
    HostBroker.swift            #   NodeBroker over every provider
    NavigationModel.swift       #   tabs, history, what is open
    ActionTargets.swift         #   a node as each identity it is
    ActionOrganizer.swift       #   actions grouped for menus
    Collections.swift           #   the collection:// provider
    FileOpening.swift, FinderFiles.swift
  MaximalTree/                  # the Mac app: the shell around the engine
    App.swift                   #   @main, AppModel wiring
    Host/                       #   Registry (CoreContributions + what this shell
                                #   draws with: canvases, inspectors, surface keys),
                                #   PluginHost (loads the bundles), FinderSources
    UI/                         #   Shell (window, columns, zen, prompts),
                                #   PaneTree (tabs/splits/panes — the arrangement
                                #   layer; see its header), SidebarModel (pure row
                                #   flatten + selection semantics), SidebarTree
                                #   (the rendered tree; deliberately not a List),
                                #   Commands (menus, built from actions),
                                #   Surfaces (who has the keyboard, geometrically),
                                #   Finder + Fuzzy (the picker and its matcher)
    Keys/                       #   the modal layer: Keymap (trie), KeyEngine (modes,
                                #   sequences, counts), KeyChord (this shell's half:
                                #   a chord from an NSEvent, and as a menu shortcut),
                                #   KeyRouting/KeyDispatch (who gets a key),
                                #   KeyCapture (the event monitor + which-key),
                                #   CoreActions (every operation the host owns,
                                #   and the sidebar's own keys),
                                #   DefaultKeymap (the keys it ships with)
  FileSystemPlugin/             # reference provider plugin (loadable bundle)
    FileSystem.swift            #   provider, mutations, symlink anchors, FSEvents
    FileActions.swift           #   the action vocabulary (new/duplicate/trash/…)
    FileIcons.swift             #   per-language icons (symbol = kind, tint = language)
    FileViews.swift             #   canvas (Quick Look) + inspector (editable)
  TextEditorPlugin/             # reference cross-plugin renderer (loadable bundle)
    TextEditor.swift            #   syntax-highlighted editor over filesystem files
  TypstPlugin/                  # the flagship: typst as a daily driver (loadable bundle)
    TypstCore.swift             #   diagnostics, notes pkg, TypstRef URIs,
                                #   structure/edit helpers (all tested)
    TypstEngine.swift           #   in-process compiler facade: compile, export, math
    TypstLSP.swift              #   minimal JSON-RPC client for tinymist completions
    TypstProvider.swift         #   section/task/agenda nodes (phony), agenda canvas
    TypstPlugin.swift           #   registration, actions, modes, TypstUIState
    TypstCanvas.swift           #   Write/Typeset/Read canvas + inspector + preview
    TypstServices.swift         #   editor-seam impls: tokens, completions, math
    ProseStyle.swift            #   the typefaces and sizes Write mode offers
  GitPlugin/                    # reference non-file provider (loadable bundle)
    Git.swift                   #   git:// URI model, git CLI, provider, branch anchors
    GitViews.swift              #   commit / list canvases + inspector
  WebPlugin/                    # reference AppKit-view canvas (loadable bundle)
    WebCore.swift               #   http(s)+web:// provider, bookmark store (tested)
    Web.swift                   #   WKWebView sessions (delegates, favicons), actions
    WebViews.swift              #   page/bookmarks canvases + address-bar inspector
  YouTubePlugin/                # reference placing adopter (loadable bundle)
    YouTubeCore.swift           #   youtube:// URIs, channel RSS, provider + feeds (tested)
    InnerTube.swift             #   YouTube's private JSON API, read anonymously (tested)
    YouTubeStore.swift          #   titles, thumbnails and recent searches, bounded (tested)
    YouTube.swift               #   add channel / new feed actions, video canvas
  ICloudPlugin/                 # reference identity adopter (loadable bundle)
    ICloudCore.swift            #   icloud:// addresses, app containers, download
                                #   state, provider (each item *is* its file)
    ICloud.swift                #   show/mount actions, download + evict
Vendor/typst-ffi/               # Rust staticlib: typst compiler/parser/renderers (C ABI)
Vendor/highlight-js/            # highlight.min.js (BSD-3) — ~190 grammars, run in-process
Tests/MaximalTreeTests/         # swift-testing suite, run inside the app (~970 tests)
Tests/MaximalTreeCoreTests/     # the core's own tests — run by `swift test` *and* by the
                                # app's suite; CoreBoundaryTests keeps UI out of the core
Package.swift                   # builds Sources/MaximalTreeCore alone, as MaximalTreeKit
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

# The core alone, with no UI and no Xcode project — seconds, not minutes
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

A test of core behaviour belongs in `Tests/MaximalTreeCoreTests` when it needs nothing
but core types: both runners pick it up. It imports `MaximalTreeKit` either way —
`Package.swift` gives the core that name, so under `swift test` the SDK is simply its
core, and nothing has to be conditional.

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
observe it by reference. It stores nothing itself: it stands in front of **two halves**,
and reading through it is the same as reading them, because observation tracks the
property actually touched however many objects the read went through.

- `GraphState` — the node records, child lists, cursors and roots. The same wherever
  the graph is served from.
- `ShellState` — selection, focus, key mode, zen mode, the pending rename, fragment
  jumps. What *this* window is doing with the graph, and never shared: two devices
  looking at the same nodes have their own selection.

That division is the one the modules will be cut along later, which is the whole reason
to draw it now. `HostFacadeTests` watches the façade the way SwiftUI does, because if
nested observation ever stopped working every view would quietly stop updating while
every other test still passed.

It exposes reads (`node(_:)`, `children(of:)`, `related(of:)`)
and what a canvas may do: navigate (`open`, `select`, `openURI`), run any operation by
id (`perform`), report what changed (`notify`), and keep a tab (`pin`). Its cache
dictionaries are the observable source of truth for the UI.

**Changing the graph is not on it** — see [Who may write](#who-may-write). `apply`,
`mount`, `beginRename` and the whole `_`-prefixed tier are behind `@_spi(Host)`, so
the host can reach them and a plugin cannot without asking by name.

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
(`.rename`, `.delete`, `.move`, `.create`) — that providers opt into by conforming
to `MutatingNodeProvider`. A `.move` IS a rename (identity is location): report
`.renamed(from:to:)` per item and the host remaps open state. `.create` makes an
empty child, uniquing names Finder-style; content-bearing creation stays an
Action. The sidebar's drag-and-drop drives `.move` — rows drag their selection,
container rows accept drops, `canApply` validates. `apply(_:)` **returns the `NodeChange`s it caused**
(`.renamed(from:to:)`, `.removed`, `.childrenChanged`), and the host applies those to
its caches and remaps navigation history/selection — crucial because a rename changes a
node's `NodeID`. An action triggers one with `ctx.apply(_:)` and asks `ctx.canApply(_:)`
before offering it.

`.adopt` and `.release` are the other kind of child: *placed* rather than contained.
A node that declares `accepts` takes drops, and the host — not its provider — keeps
what was dropped, per workspace, and lists it as the node's children. No provider
receives these mutations; a plugin reads its node's placed children through
`NodeBroker.placedChildren(of:)` (an aggregator builds its feed from them).

A node that is *also* a feed says so with a second identity whose `childStyle` is
`.contents`: the aggregator is its channels in the sidebar, and selecting it lists the
feed in the contents column. The feed's provider merges its members' listings with
`FeedMerge.page`, supplying the order — the host never merges. Each member pages on its
own; the merge's cursor records where each one is, and needs a member's pages to be the
same when asked twice.

*Content* editing (a file's bytes) is **not** a `GraphMutation` — that vocabulary is for
tree structure. Content is type-specific manipulation a plugin does directly via its
canvas (see `TextEditorPlugin` writing files). Keep the two distinct.

**Side effects outside the mutation path** (an action created a file, an editor saved
bytes) must be reported with `HostContext.notify(_ changes: [NodeChange])` so the host's
caches stay truthful — same funnel, plugin-initiated. `.childrenChanged` refetches a
child list, `.modified` refetches one node record in place. The FileSystem plugin's
"New Folder" action and the TextEditor's save are the reference uses.

**External changes** (another app editing files) flow through the same funnel via
`ChangeStreamingProvider`: return an `AsyncStream<[NodeChange]>` from
`changes(under:)` and the host consumes one stream per mounted root you own,
starting and stopping them as roots mount, unmount, and switch. Disk-backed
providers wrap the SDK's `FileTreeWatcher` (recursive FSEvents, latency-coalesced).
Be conservative: emit `.childrenChanged`/`.modified`, never `.removed`/`.renamed`
from external events — event APIs can't pair renames, and a wrong removal tears
down open tabs. References: the FileSystem provider (event→change mapping, hidden
dot-directory churn filtered) and the typst agenda (any `.typ` change re-scans).

### Who may write

A canvas **reads, navigates, and reports**. It does not change the graph. An operation
that exists only inside one canvas is invisible to the palette, to a key, to a script,
and to anything that would put it back — so writing is something an *action* does, and
the write vocabulary lives on `ActionContext`: `apply`, `canApply`, `mount`,
`beginRename`, `ingest`, `notify`.

`notify` is on both, deliberately. A report carries no authority: the host answers it
by re-reading from whoever owns the node, which is the same path an edit made outside
the app takes. So a canvas may say "this changed" and may not say what it changed to.
The iCloud plugin is the reference — its provider reads the live page's title from the
session, and the web canvas only reports that the record changed.

This is enforced by the compiler rather than by agreement: reaching for `host.apply`
from a canvas does not build. `@_spi` is not a wall — a plugin can write
`@_spi(Host) import MaximalTreeKit` and get everything back — but asking is then a
visible line at the top of a file instead of something that happens in the middle of a
view.

**Ask for what the body needs, not for what the node is.** A predicate that tests a
node's *type* when its body needs a *path* is how a menu offers something it then
quietly fails to do. The file actions ask whether each target has a local URL
(Reveal, Copy Path, Duplicate) or whether its owner agrees (Trash, New File) — which is
why they reach an iCloud item, as the file it also is, and why they would not reach a
file served from somewhere with no path.

### Undo: the sidebar's arrangement, and nothing else

`UndoHistory` keeps **snapshots of the placement table**, per workspace, bounded, and
`WorkspaceStore.changeActive(undoAs:)` records one before every change the reader
asked for. Snapshots rather than inverses because the host owns the whole of that
state, and because deleting a group spills its contents into every holder it had —
which is not something one `adopt` puts back.

That is also why undo stops there. An inverse can be written for anything; a snapshot
can only be taken of state you hold. Deleting a file, renaming one on disk, writing to
a server: none of it is undoable here, because putting it back is not ours to promise.
A greyed-out Undo is a truthful answer; one that appears to work and doesn't is not.

The two changes that record nothing are the two nobody asked for: the table being
healed on load, and the app following what the graph has mounted. Taking a root out of
the sidebar *is* a change you made, and goes back.

### Pagination

`children(of:page:)` may return `Page(items:, next: Cursor(...))`. The cursor is your
own opaque token (the git provider uses a log offset). The host caches it: UI shows a
"More…" affordance when `HostContext.hasMoreChildren(id)`, and
`loadMoreChildren(of:)` fetches the next page and appends it to the cached children.
Providers that vend everything at once just return `next: nil`.

### Workspaces

A **workspace** is a named arrangement of nodes — what is mounted and what was put
inside what (see [Placements](#placements-what-is-inside-what)) — host-owned and
persisted as an app-managed library (`workspaces.json` in Application Support; the
pre-workspaces single `workspace.json` migrates automatically). At least one workspace always exists, and
exactly one is active. Switching (toolbar menu, or the Workspace menu with ⌘⌥1–9)
saves nothing and restores everything: tabs, history, focus, and selection reset;
node caches are kept because `NodeID`s stay valid across workspaces. Mount/unmount
persists into the active workspace automatically, no matter who initiated it (UI or a
plugin action). Providers are entirely workspace-unaware.

Seeding is **first-launch-only**: an empty workspace the user made stays empty.

Workspaces are held in **two orders**. `workspaces` is the arranged one — what the
menu lists and what ⌘⌥1–9 number, and it never moves, because a number that meant a
different workspace after every switch would be worse than no number. `recentIDs` is
last-use order, most recent first, and it is what `workspace.next` / `previous` walk
(`SPC w n`, `g w`) and what the switcher lists. Arriving at a workspace puts it at the
head, so stepping forward lands on the one you just left and stepping forward again
comes back — alt-tab's bargain, where the two you are working between stay one
keystroke apart no matter how many others exist. Both orders are persisted; the
recency list is healed against the live workspaces on load and filtered of ephemeral
ones on save.

A file opened from the Finder that no workspace mounts gets an **ephemeral
workspace** of its own, named after the file and holding just it. It is listed and
switchable like any other but never written to the library, so it goes when the app
does — nothing deletes it. "Keep This Workspace" (`workspace.keep`) makes it real.
Files that *are* inside a mounted root open in that root's workspace instead, matched
by the directory a root names rather than by its scheme, so a repo mounted as
`git://repo?repo=…` claims its own files.

### Placements: what is inside what

A workspace records **where things were put**: one table of parent URI → ordered child
URIs (`Host/Placements.swift`), kept per workspace in the library file. The sidebar's
whole shape is a flatten of that table from the workspace's root
(`collection://<workspace-id>`), and the flat root set the graph consumes
(`context.roots`) is *derived* from it, so providers stay unaware.

**Collections come out of it for free.** A collection is simply a key in the table
whose URI carries its name (`collection://<uuid>?name=Reading`); it has no existence
of its own, no file, and no provider. Deleting one spills what it held out where it
sat. A group in the sidebar, a watch list, and an aggregator's members are all the
same mechanism.

`.adopt`/`.release` are how the table changes, and the host — never a provider —
handles them (`GraphStore.apply` intercepts both). The workspace store is the
`PlacementHost`, held weakly. `WorkspaceStore.reconcileRoots(_:placingNewInto:)` keeps
the table in step with the live root set on every mount and unmount: vanished roots
leave every collection, and a newly mounted root joins the collection holding the
current node's root, so "New X" lands beside what you were looking at.

A rename is a change of URI (the name is *in* it), so renaming a collection remaps the
table's keys and members; `restoreRoots` also re-resolves stored parents on load,
which is what heals a library written by an older build.

The legacy `RootLayout`/`RootEntry`/`RootFolder` types survive in `Workspace.swift` for
one reason only: migrating a library that predates the table. Nothing reads them
otherwise. `workspaces.pre-placements.json` is the backup taken on the way, and
`collections.json` — the global collections file that predates the table — is read once
to migrate and then left alone.

### Commands: one registry, one id space

Every operation is an `Action` — the host's own (`pane.splitRight`, `explorer.down`,
`toggle.zen`) exactly as much as a plugin's (`git.open`, `typst.newNote`). There is no
second vocabulary of things only the keyboard can reach. That means an operation is
defined once and every surface agrees about it:

- the **menu bar** takes an item's title, key equivalent and greyed-out state from the
  action (`ActionItem` in `UI/Commands.swift`);
- the **finder** lists what applies, and a node-scoped source lists what is *about*
  the node in front of you (scope `.node`/`.container`/`.document`);
- the **keymap** binds a chord to an action id — a plugin's included, the day it ships;
- a **plugin** runs any of it by name with `host.perform("pane.splitRight")`.

Applicability is one question asked in one place (`AppModel.context(for:targets:)`):
it decides whether a menu item greys out, whether the finder offers the action, and
whether a key bound to it does anything. An action that can't run right now is
uniformly absent rather than a no-op.

`ActionContext` carries a repeat `count`, because a key can ask for one (`5 j`).

**A command takes an argument.** `Command` has an `Input` and an `Output`, both
`Codable`, and defaults to `NodeTargets` — the nodes it was invoked on, and the count.
An action written as a closure gets the same argument: `ctx.acting(on:)` means invoking
`file.delete` with two ids deletes *those two*, whatever happens to be selected, which
is what makes an operation reachable from a keymap or a script and not only from a
click. Registration comes in two shapes:

```swift
// A closure over the context, for anything whose whole argument is "these nodes".
Action(id: "myscheme.doThing", title: "Do the Thing", run: { ctx in … })

// A command written as a type, for anything whose argument is more than that.
struct Rename: Command {
    struct Input: Codable, Sendable { var target: NodeID; var name: String }
    static let id = "myscheme.rename"
    func run(_ input: Input, in ctx: ActionContext) async throws -> NoAnswer { … }
}
registry.register(Rename())                     // invocable, never listed
registry.register(action: Action(Rename(), title: "Rename…"))   // listed too
```

**Two doors, and they differ in who takes the failure.** A key, a menu or the palette
goes through `perform`: nothing is handed back, and a failure is the host's to put in
front of the reader, who asked for something to happen rather than asking a question.
A caller that wants the answer uses `host.perform(Rename.self, input)`, which returns
`Output` and throws — and deliberately does *not* also raise an alert behind its back.

**An answer, never an effect.** What a command *changed* is reported on the `NodeChange`
funnel, because a change observed from outside the app has no invoker and so no answer;
behaviour built on a returned effect would work for edits we made and quietly not for
edits we noticed. `Output: Codable` is what keeps that honest — `NodeChange` is not
`Codable`, so answering with one does not compile.

**Waiting takes a turn.** A body that awaits picks the asynchronous overload and goes
through `CommandQueue`, one at a time, because two writes that interleave leave an undo
log whose order is not the order things happened in. A body that doesn't await runs
where it was invoked, as a key's action always has — queueing those would reorder a
keymap against itself.

An action's key equivalent is a `KeyChord`, the same notation a keymap is written in;
the menu bar turns one into a `KeyboardShortcut` where it draws it.

**Register it bare when its argument is the point.** `workspace.select` takes which
workspace to go to, so a menu or the palette has nothing useful to show for it: it is
registered as a command with no presentation, and the workspace switcher names it and
hands over the id (`FinderItem.Effect.run(_:with:)`). That is what a `FinderSource` in a
plugin does too — list what you have, and say which command to run with what.

### Keys: modes, sequences, and who gets first refusal

`Keys/` is a modal layer, Doom-flavoured: `SPC` is the leader, groups are mnemonic,
and bindings are written in Emacs notation (`C-w`, `SPC g s`). `Keymap` is a trie, so
the interesting question isn't only "what does `SPC g s` do" but "I have typed `SPC g`,
what now" — which is what which-key shows and what makes a leader learnable.

The routing rule is **the mode decides, not the view**. In a commanding mode a key
names an action; in insert mode every key belongs to whatever has focus. Deciding by
view instead was two bugs in a row — first the editor wasn't recognised, then every
canvas was and the leader stopped working anywhere.

**A surface declares its keys; no surface ever sees a keystroke.** A canvas declares
them on its `CanvasContribution` (`keys: [SurfaceKey]`), which is what keeps the canvas
that *draws* and the canvas whose keys apply from ever being two different things — with
a matcher of its own they could disagree, and nothing would say so. The sidebar and the
inspector have no contribution to hang keys on, so they register `SurfaceKeys(.sidebar,
…)`; those are the host's own.

Resolution order for a key press: a sequence already begun continues in the map that
began it, then the focused surface's map, then the app's. `SPC` is the app's wherever
you are — a surface that could shadow the leader could take away the way out of itself.

Which side a command belongs on follows from that: **the leader is for what works
wherever the keyboard is**, and a command that only ever has one surface to act on is
that surface's. Zooming a web page or repeating a find means nothing with a folder
selected, so those are the page's keys and the page declares them — a leader group of
them would be dead sequences most of the time, and long ones at that.

Everything follows from a key naming an action rather than a surface implementing one:
the keys are rebindable, they are listed in the finder, they are callable by name with
`host.perform(_:)`, and which-key shows the resolved answer from one source instead of
a declaration kept in step with an implementation. It was two mechanisms until recently
— a canvas handling raw keystrokes, and the sidebar (which could not) carrying a
predicate on ten actions naming the surface they applied to. The predicate is gone, and
so is `CanvasKeyHandling`.

A surface's action that starts typing says so by setting `HostContext.keyMode`: there
is one mode, and it is not a surface's to keep a copy of.

Keys arrive through one local event monitor (`KeyCapture`), not SwiftUI's
`onKeyPress` — bindings have to work wherever focus is, including where a field editor
holds first responder. `KeyDispatch.handle` is the pure decision underneath, so the
modal layer is testable without a window.

### Surfaces: found by geometry

A `SurfaceID` is `.sidebar`, `.pane(UUID)`, or `.inspector`. Movement between them
(`C-w h/j/k/l`) and "which one has the keyboard" are both answered from *where things
are on screen*, not from the view tree: SwiftUI flattens the window, so a pane's
marker is a **sibling** of its content and no ancestor distinguishes one surface from
another. Each surface reports its rectangle from an `NSView` that self-reports on
layout, and the focused one is whichever the first responder most overlaps.

Nothing about the sidebar or the inspector is special here. They were once — the
sidebar reached by a rule written into the movement, the inspector not reachable at
all — and both special cases are gone.

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

### 3. `Action`s (the primary manipulation surface)

One registry feeds the menu bar, the finder, the context menu, and the inspector's
Actions section; each surface filters by the action's `appliesTo` predicate
(`.always`, `.type(_)`, or `.custom { ctx in … }`). Pass
`shortcut: KeyChord("s", command: true)` and the menu bar registers it window-wide. The host's own operations are in the same registry, so
anything you register is bindable to a key and callable by name the day it ships.

`scope` decides where an action is offered by default *and* whether it is "about" a
node — the node-scoped finder lists `.node`, `.container` and `.document`, not
`.workspace`. `surfaces: [.palette]` keeps an operation out of the menus while leaving
it searchable, which is what the host's forty-odd motions use.

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
    // ctx.selection, ctx.selectedNodes, ctx.host — and ctx.apply/notify to change things
    // Throw to tell the reader it didn't work; await to take a turn on the queue.
}
```

See [Commands](#commands-one-registry-one-id-space) for arguments, answers and the two
doors, and [Who may write](#who-may-write) for what a body may reach.

### 4. The principal class

Your entry point **must** be Obj-C-discoverable so `NSPrincipalClass` resolves it:

```swift
@objc(MyPlugin)                       // pins the unmangled runtime name
final class MyPlugin: NSObject, Plugin {
    override init() { super.init() }
    func register(with registry: PluginRegistry) {
        registry.register(provider: MyProvider())
        registry.register(canvas: /* … */)      // and/or inspector:, children:
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

### The editor on other platforms

The editor itself is ready for iOS: the same engine behind the same seam, with a UIKit
implementation in place of the AppKit one. See [Other shells](#other-shells) for the
rest of what a second platform needs.

## Other shells

The intended shape, agreed but not built: **one core, embeddable but optional.** A
device either embeds the core and works offline, or runs thin against a home server
that hosts the user's stuff so moving between machines needs no syncing. The macOS app
embeds it and can *be* that server; the same core runs headless on Linux. Web and
Android shells then only rewrite canvases, which have to be rewritten anyway, instead
of rewriting every provider.

What that implies here:

- **Every plugin splits in two.** A *core half* (provider, commands, stores) that runs
  wherever the core runs, and a *shell half* (canvases, inspectors, and the commands
  that need a local UI — clipboard, Finder, file pickers). Type ids and command ids are
  the contract between them. Several plugins are already half-split along that line:
  `YouTubeCore`, `WebCore`, `ICloudCore`, `TypstCore` compile without any UI.
- **Node scope is about who serves a node, not its scheme.** `youtube://`, `https://`
  and `icloud://` mean the same thing on every device; `file://`, `git://` and a
  terminal are local to one machine — and become global once a server shares them,
  under a host-qualified id so one machine's `file:///x` never collides with another's.
- **A workspace shared between machines holds only global nodes.** Per-device view
  state (what is expanded, how the panes are split) stays per device even then.

The extraction is planned in phases. **Making the SDK honest in place is done**: keys
are plain data, `PluginRegistry` is now `CoreRegistry` (providers, children, actions,
commands, finder sources) plus `ShellRegistry` (canvases, inspectors, surface keys),
and `HostContext` is a façade over a graph half and a shell half. **The core also
builds on its own**: `Sources/MaximalTreeCore` holds everything with no UI, and
`Package.swift` builds and tests just that, while the Mac app keeps compiling it into
the one `MaximalTreeKit` framework. The no-UI rule is enforced by `CoreBoundaryTests`
rather than by a module boundary — a separate `MaximalTreeCore` framework was tried,
and made the app idle at 100% CPU in a window-toolbar relayout loop that was never
traced, so the Mac build stays one module. **The host's engine is out of the app
too**: `Sources/MaximalTreeHost` holds the host's model code — workspaces, placements,
undo, the graph store, command dispatch — compiled into the Mac app as before, and
built alone by `Package.swift`, where a reference to one of the app's views fails to
compile. What remains is splitting `AppModel`, whose model logic still lives in the
app, then splitting the plugins, and only then proving it off macOS
with an iOS build, `swift test` on Linux, and a headless CLI host. Three constraints
found while planning, worth knowing before starting:

- the core has to stay a **dynamic** framework on Apple platforms (see Conventions);
- `Vendor/typst-ffi` must be cross-compiled before anything typst runs on iOS, so the
  first iOS build should leave the typst core out;
- iOS only executes code shipped in the app, so core halves register from a static list
  rather than through `PluginHost`'s bundle scan.

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
- **Route through `HostContext` and `ActionContext`.** A canvas reads, navigates and
  reports; an action writes. The host's internals are behind `@_spi(Host)` — if you
  find yourself importing that from a plugin, the operation you want is missing from
  `ActionContext` and that is the thing to fix.
- **A test waits for something, never for a while.** A fixed sleep is a guess, and it
  fails on a loaded machine for no reason of the test's own. `Tests/…/Waiting.swift`
  has `waitUntil(_:)` (and `waitUntil(_:in: window)`, which lays the window out each
  time round) for things that will happen. For things that mustn't happen, ask the
  code whether it's at rest — `GraphStore.outstanding`, `AppModel.commandsRunning`,
  `FinderModel.gathering`, the editor coordinator's `isSettled` — and check after;
  often a call that should start nothing can be checked straight away
  (`#expect(store.outstanding == 0)`). Something new that works in the background
  should come with a way to tell when it's done. `mainQueueDrained()` is the last
  resort, for code with no such signal.
- **Don't set `navigationTitle` in a canvas.** The window title belongs to the host
  (workspace name, focused node as subtitle); a canvas that sets its own title
  hijacks it. Your node's name is already shown by the tab strip and subtitle.
- `MaximalTreeKit` is built with library evolution on, but **nothing depends on binary
  compatibility**: every plugin ships inside the app and is rebuilt with it, so a
  breaking SDK change is allowed as long as it is made everywhere in the same commit.
  (`Action.init(handler:)` was removed that way.)
- **The reader's data is not a cache.** Workspaces, bookmarks, a feed's name — anything
  only the reader has — is read and written through `UserDataFile`: a file that is
  there but can't be read is moved aside (`workspaces.unreadable-<date>.json`) and
  reported, never replaced, and one that can't even be moved is never saved over. A
  failed save is reported rather than discarded — once per run of failures, not once
  per change. A plugin reports through `registry.notices`, with `Notice.unreadable`
  and `Notice.notSaved` so every file says it the same way; it keeps the `Notices`,
  because a save fails long after `register(with:)`. Whatever is posted before the
  host listens is held, and the host shows notices one at a time, in order, so two
  at once don't replace each other. Everything re-fetchable can stay
  behind `try?` — but don't put the two in one file, or the cache's carelessness
  becomes the data's. (Feed names lived in YouTube's cache file until they had to
  move out for exactly that reason.) Before this, an unreadable library was
  answered by a fresh one written straight over it.
- **The SDK must stay a dynamic framework.** Plugin bundles link it "Do Not Embed" and
  share the host's one copy. Statically linking it into the app *and* each bundle would
  duplicate type metadata — `as?` casts across the boundary would start failing, and
  any SDK-level singleton would exist twice.

---

## What's not done yet

Working today: workspaces (including ephemeral ones for files opened from the
Finder), tabs + splits + history, cross-plugin rendering, phony nodes, zen mode,
structural writes (rename + delete-to-Trash), the modal keyboard layer over a single
action registry, the finder, and the full typst stack (in-process compile/preview/
export, parser-backed highlighting and outline, rendered math, tinymist completions).
Known gaps, roughly in order:

- **Dynamic plugins** — loading is launch-time from the bundled `PlugIns/`. No
  external user plugin directory, enable/disable, or revocable registrations yet.
- **Typst follow-ups** — tinymist hover/go-to-definition, snippet tab-stops, and
  a rename event doesn't yet remap a file's `typst://` section nodes in history.
- **A second shell** — the hard prerequisites are done (in-process compiler, no CLI
  dependencies, cross-platform editor engine). What remains is the core extraction and
  the platform work; see [Other shells](#other-shells).
- **Smaller**: richer inspector composition, multi-select in the directory grid.
- **The host's own views write directly** — `NodeInspector` and `SidebarTree` call
  `host.apply` for rename and drag-to-move, which [Who may write](#who-may-write)
  forbids a plugin canvas. They should be commands: it would make them scriptable, and
  a second shell needs them to be.
- **Applicability is closures** — forty `appliesTo: .custom` against sixteen `.type`.
  Correct in-process, and the obstacle for a shell that isn't Swift: a predicate can't
  cross a wire. The answer is that the core evaluates it and the shell asks what
  applies, which is what `AppModel.applicableActions` already does.
- **The terminal has no UI-free half** — sessions and the PTY are tangled with Ghostty,
  so it is the one plugin with nothing to put in a core.
- **The inspector has no keys** — every other surface declares some; it is the one
  place you still cannot reach from the keyboard alone.
- **One shell window** — there is one `AppModel`, so a second window of the main
  scene is a duplicate view of the same workspace and tabs rather than a second
  place to work.
