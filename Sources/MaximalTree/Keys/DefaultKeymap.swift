import Foundation

/// The keys the app ships with.
///
/// Doom-flavoured: `SPC` is the leader and groups are mnemonic — `f` files,
/// `b` buffers (tabs), `w` windows (panes), `g` git, `t` toggles. Motions in
/// normal mode move the *explorer*, since that is the app's list of things.
///
/// Bindings name commands by id, and a plugin's actions are ids too
/// (`file.newFile`, `git.open`), so binding a key to a plugin command needs
/// nothing from the plugin.
enum DefaultKeymap {
    static func make() -> Keymap {
        var map = Keymap()

        // Groups, named so which-key reads as words rather than keys.
        map.describe("SPC f", as: "file")
        map.describe("SPC b", as: "buffer")
        map.describe("SPC w", as: "window")
        map.describe("SPC g", as: "git")
        map.describe("SPC t", as: "toggle")
        map.describe("SPC n", as: "new")
        map.describe("g", as: "goto")

        // Getting around the explorer.
        map.bind("j", to: "explorer.down")
        map.bind("k", to: "explorer.up")
        map.bind("h", to: "explorer.collapse")
        map.bind("l", to: "explorer.expand")
        map.bind("RET", to: "explorer.open")
        map.bind("o", to: "explorer.open")
        map.bind("g g", to: "explorer.first")
        map.bind("G", to: "explorer.last")

        // Modes and the palette.
        map.bind("i", to: "mode.insert")
        map.bind("SPC SPC", to: "palette.toggle")
        map.bind("M-x", to: "palette.toggle")
        map.bind("/", to: "palette.toggle")

        // History, the way a browser does it.
        map.bind("C-o", to: "nav.back")
        map.bind("C-i", to: "nav.forward")
        map.bind("[", to: "nav.back")
        map.bind("]", to: "nav.forward")

        // Buffers — tabs, in this app's vocabulary.
        map.bind("SPC b n", to: "tab.next")
        map.bind("SPC b p", to: "tab.previous")
        map.bind("SPC b d", to: "tab.close")
        map.bind("SPC b b", to: "palette.toggle")
        map.bind("g t", to: "tab.next")
        map.bind("g T", to: "tab.previous")

        // Windows — panes.
        map.bind("SPC w v", to: "pane.splitRight")
        map.bind("SPC w s", to: "pane.splitDown")
        map.bind("SPC w d", to: "pane.close")
        map.bind("SPC w c", to: "pane.close")
        map.bind("C-w v", to: "pane.splitRight")
        map.bind("C-w s", to: "pane.splitDown")
        map.bind("C-w c", to: "pane.close")

        // Files and the workspace.
        map.bind("SPC f f", to: "workspace.addFolder")
        map.bind("SPC f s", to: "file.save")
        map.bind("SPC f n", to: "file.newFile")
        map.bind("SPC f d", to: "file.newFolder")
        map.bind("SPC f r", to: "core.rename")
        map.bind("SPC f y", to: "file.copyPath")
        map.bind("SPC f R", to: "file.reveal")

        // Toggles.
        map.bind("SPC t s", to: "toggle.sidebar")
        map.bind("SPC t i", to: "toggle.inspector")
        map.bind("SPC t z", to: "toggle.zen")

        // Plugin commands worth a key of their own. Ids, nothing more.
        map.bind("SPC g o", to: "git.open")
        map.bind("SPC n t", to: "terminal.new")
        map.bind("SPC n n", to: "typst.newNote")
        map.bind("SPC n d", to: "typst.dailyNote")
        map.bind("SPC n w", to: "web.newPage")

        return map
    }
}
