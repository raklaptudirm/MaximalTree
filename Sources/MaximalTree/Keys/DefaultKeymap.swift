import Foundation

/// The keys the app ships with.
///
/// Doom-flavoured: `SPC` is the leader and the groups are the app's own nouns
/// — `s` surface, `t` tab, `w` workspace, `f` file, `n` new, `g` git,
/// `T` terminal. Motions belong to the surface holding the keyboard: `j` walks
/// the tree in the sidebar and moves the caret in an editor, and the binding
/// is the same one.
///
/// They used to be Doom's nouns instead — `w` for window, `b` for buffer, `p`
/// for project — and the comments spent their time translating: "windows —
/// surfaces, in this app's vocabulary". There is one window here, so a group
/// called window could only ever have meant something else. Now `w` is the
/// workspace it reads as, and the surfaces are under `s`.
///
/// Two rules hold the rest together. Lowercase goes somewhere, uppercase shows
/// or hides it: `SPC s i` puts the keyboard in the inspector, `SPC s I` makes
/// it come and go. And a thing you *create* that ends up in the tree lives
/// under `SPC n`, while a container to put things in — a tab, a workspace —
/// is created inside its own group.
///
/// Bindings name commands by id, and a plugin's actions are ids too
/// (`file.newFile`, `git.open`), so binding a key to a plugin command needs
/// nothing from the plugin.
enum DefaultKeymap {
    static func make() -> Keymap {
        var map = Keymap()

        // Groups, named so which-key reads as words rather than keys.
        map.describe("SPC f", as: "file")
        map.describe("SPC s", as: "surface")
        map.describe("SPC t", as: "tab")
        map.describe("SPC w", as: "workspace")
        map.describe("SPC n", as: "new")
        map.describe("SPC g", as: "git")
        map.describe("SPC T", as: "terminal")
        map.describe("g", as: "goto")

        // Moving in the sidebar is not here: those keys are the sidebar's own
        // and it declares them, the same way a canvas declares its. What is
        // here is what works wherever the keyboard happens to be.

        map.bind("i", to: "mode.insert")
        // The finder. `SPC SPC` is the one you reach for without thinking, so
        // it goes to the tree you are looking at rather than to everything the
        // app knows — the wider search is a deliberate act and gets a key that
        // says so.
        map.bind("SPC SPC", to: "finder.nodes")
        map.bind("SPC /", to: "finder.all")
        map.bind("/", to: "finder.all")
        map.bind("M-x", to: "finder.actions")
        map.bind(":", to: "finder.actions")
        // What can be done to the thing you are pointing at — the context
        // menu without the mouse. Vim's "repeat" key is not bound here, so the
        // full stop is free and reads as "do something to this".
        map.bind(".", to: "finder.nodeActions")
        map.bind("SPC .", to: "finder.nodeActions")

        // History, the way a browser does it.
        map.bind("C-o", to: "nav.back")
        map.bind("C-i", to: "nav.forward")
        map.bind("[", to: "nav.back")
        map.bind("]", to: "nav.forward")

        // MARK: Surfaces — the areas this one window is divided into.
        //
        // Movement mirrors `C-w` below, which is the vim spelling and stays.
        map.bind("SPC s h", to: "surface.left")
        map.bind("SPC s j", to: "surface.down")
        map.bind("SPC s k", to: "surface.up")
        map.bind("SPC s l", to: "surface.right")
        map.bind("SPC s n", to: "surface.next")
        map.bind("SPC s p", to: "surface.previous")
        map.bind("SPC s v", to: "pane.splitRight")
        map.bind("SPC s s", to: "pane.splitDown")
        map.bind("SPC s d", to: "pane.close")
        // Going to one, and showing or hiding it.
        map.bind("SPC s e", to: "explorer.focus")
        map.bind("SPC s i", to: "inspector.focus")
        map.bind("SPC s c", to: "editor.focus")
        map.bind("SPC s E", to: "toggle.sidebar")
        map.bind("SPC s I", to: "toggle.inspector")
        map.bind("SPC s z", to: "toggle.zen")

        // Between surfaces, the way Vim moves between windows. `h` off the
        // leftmost one carries on into the sidebar, which is where further
        // left actually is, so these keys mean one thing everywhere rather
        // than "move" in the canvas and "focus the explorer" at the edge.
        map.bind("C-w h", to: "surface.left")
        map.bind("C-w j", to: "surface.down")
        map.bind("C-w k", to: "surface.up")
        map.bind("C-w l", to: "surface.right")
        map.bind("C-w w", to: "surface.next")
        map.bind("C-w W", to: "surface.previous")
        map.bind("C-w v", to: "pane.splitRight")
        map.bind("C-w s", to: "pane.splitDown")
        map.bind("C-w c", to: "pane.close")

        // MARK: Tabs.
        map.bind("SPC t t", to: "finder.buffers")
        map.bind("SPC t n", to: "tab.next")
        map.bind("SPC t p", to: "tab.previous")
        map.bind("SPC t h", to: "tab.first")
        map.bind("SPC t l", to: "tab.last")
        map.bind("SPC t d", to: "tab.close")
        map.bind("SPC t N", to: "tab.new")
        map.bind("g t", to: "tab.next")
        map.bind("g T", to: "tab.previous")

        // MARK: Workspaces.
        map.bind("SPC w w", to: "finder.workspaces")
        map.bind("SPC w n", to: "workspace.next")
        map.bind("SPC w p", to: "workspace.previous")
        map.bind("SPC w N", to: "workspace.create")
        map.bind("SPC w r", to: "workspace.rename")
        map.bind("SPC w d", to: "workspace.delete")
        // The way out of an ephemeral workspace, which is where a file opened
        // from the Finder lands.
        map.bind("SPC w k", to: "workspace.keep")
        // The sidebar's own folders, which organise roots without being nodes.
        map.bind("SPC w f", to: "workspace.newFolder")
        map.bind("g w", to: "workspace.next")
        map.bind("g W", to: "workspace.previous")

        // MARK: Files — what you do to one, not how you make one.
        map.bind("SPC f f", to: "finder.files")
        map.bind("SPC f s", to: "file.save")
        map.bind("SPC f r", to: "core.rename")
        map.bind("SPC f y", to: "file.copyPath")
        map.bind("SPC f R", to: "file.reveal")
        map.bind("SPC f o", to: "file.openDefault")
        map.bind("SPC f D", to: "file.duplicate")
        // Capital, like git's discard: the ones that throw something away are
        // never a key you can hit by accident reaching for its neighbour.
        map.bind("SPC f X", to: "file.trash")

        // MARK: New — things that end up in the tree.
        //
        // A tab and a workspace are containers to put things in rather than
        // things, so those are made inside their own groups above.
        map.bind("SPC n f", to: "file.newFile")
        map.bind("SPC n F", to: "file.newFolder")
        map.bind("SPC n r", to: "workspace.addFolder")
        map.bind("SPC n t", to: "terminal.new")
        map.bind("SPC n n", to: "typst.newNote")
        map.bind("SPC n d", to: "typst.dailyNote")
        map.bind("SPC n w", to: "web.newPage")

        // MARK: Git.
        map.bind("SPC g o", to: "git.open")
        map.bind("SPC g s", to: "git.stage")
        map.bind("SPC g u", to: "git.unstage")
        map.bind("SPC g a", to: "git.stageAll")
        map.bind("SPC g c", to: "git.commit")
        map.bind("SPC g X", to: "git.discard")
        map.bind("SPC g f", to: "git.fetch")
        map.bind("SPC g l", to: "git.pull")
        map.bind("SPC g p", to: "git.push")
        map.bind("SPC g b", to: "git.checkout")
        map.bind("SPC g z", to: "git.stash")
        map.bind("SPC g Z", to: "git.stashPop")

        // MARK: The terminal. Capital T, because lowercase `t` is tabs.
        map.bind("SPC T c", to: "terminal.clear")
        map.bind("SPC T r", to: "terminal.restart")
        map.bind("SPC T R", to: "terminal.reset")
        map.bind("SPC T d", to: "terminal.openDirectory")
        map.bind("SPC T y", to: "terminal.copyDirectory")
        map.bind("SPC T f", to: "terminal.revealDirectory")
        map.bind("SPC T a", to: "terminal.showAll")
        map.bind("SPC T x", to: "terminal.close")
        map.bind("SPC T +", to: "terminal.fontBigger")
        map.bind("SPC T -", to: "terminal.fontSmaller")
        map.bind("SPC T 0", to: "terminal.fontReset")

        return map
    }
}
