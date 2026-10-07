import SwiftUI
import AppKit
import MaximalTreeKit

/// The finder: one way in to everything the app knows about.
///
/// Telescope's shape rather than a command palette's. A palette lists the
/// commands you can run; a finder searches *things* — files, open tabs, notes,
/// pages, workspaces — and commands are simply one more kind of thing, which
/// is what they are in an editor that calls them `:w` and `:q`. So the same
/// window, the same fuzzy matching, and the same keys reach all of it, with
/// each list also having a key of its own for when you know what you are after.
@MainActor
@Observable
final class FinderModel {
    /// Which list is being searched. Nil searches every list that opted in.
    private(set) var scope: String?
    /// Each item with the list it came from: its name for the row, and its
    /// weight for the ranking.
    private(set) var items: [(item: FinderItem, source: String, weight: Int)] = []
    private(set) var loading = false
    /// What has been typed.
    var query: String {
        get { typed }
        set {
            guard newValue != typed else { return }
            typed = newValue
            // A row picked out of the old list means nothing against the new
            // one, so start at the top again.
            index = 0
        }
    }
    private var typed = ""

    /// Which row is picked out.
    var index = 0

    private var loadID = 0
    /// The latest gathering, so a test can wait for one to finish — even one
    /// a later open overtook, whose results must then go nowhere.
    @ObservationIgnored private(set) var gathering: Task<Void, Never>?

    /// What the query matches, best first.
    ///
    /// Ranked across every source together, so searching everything doesn't
    /// mean reading four separate lists — the best match is the first row
    /// whichever list it came from.
    func results(limit: Int = 200) -> [Row] {
        guard !query.isEmpty else {
            return items
                .sorted { $0.weight > $1.weight }
                .prefix(limit)
                .map { Row(item: $0.item, source: $0.source, matched: []) }
        }
        return items
            .compactMap { entry -> (row: Row, score: Int)? in
                let row = { (matched: [Int]) in
                    Row(item: entry.item, source: entry.source, matched: matched)
                }
                if let hit = Fuzzy.match(query, entry.item.title) {
                    return (row(hit.matched), hit.score + entry.weight)
                }
                // A subtitle match still counts — a path, a host — but ranks
                // below a title match, and highlights nothing in the title.
                guard let subtitle = entry.item.subtitle,
                      let hit = Fuzzy.match(query, subtitle) else { return nil }
                return (row([]), hit.score / 2 + entry.weight)
            }
            .sorted { $0.score > $1.score }
            .uniqued()
            .prefix(limit)
            .map(\.row)
    }

    /// One line of the list: what it is, which list it came from, and why it
    /// matched. Identified by the item, since that is what the list is of.
    struct Row: Identifiable {
        let item: FinderItem
        let source: String
        let matched: [Int]
        var id: String { item.id }
    }

    var selected: FinderItem? {
        let rows = results()
        guard rows.indices.contains(index) else { return nil }
        return rows[index].item
    }

    func move(_ delta: Int) {
        let count = results().count
        guard count > 0 else { return }
        index = (index + delta).wrapped(around: count)
    }

    /// Open the finder over `sources`, gathering their items.
    func open(scope: String?, sources: [FinderSource]) {
        self.scope = scope
        typed = ""
        index = 0
        items = []
        loading = true
        loadID += 1
        let id = loadID
        let wanted = sources.filter { scope == nil ? $0.searchedByDefault : $0.id == scope }

        gathering = Task { @MainActor in
            var gathered: [(item: FinderItem, source: String, weight: Int)] = []
            for source in wanted {
                let found = await source.items()
                guard id == loadID else { return }   // a later open won
                gathered += found.map { ($0, source.title, source.weight) }
                // Shown as they arrive: a disk walk shouldn't hold up the
                // list of open tabs.
                items = gathered
            }
            if id == loadID { loading = false }
        }
    }

    func close() {
        loadID += 1
        items = []
        typed = ""
        index = 0
        loading = false
    }

    /// What the prompt says, from whichever source was asked for.
    func prompt(from sources: [FinderSource]) -> String {
        guard let scope, let source = sources.first(where: { $0.id == scope })
        else { return "Search everything…" }
        return source.prompt
    }
}

/// The picker itself.
struct Finder: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private var sources: [FinderSource] { model.store?.finders ?? [] }

    var body: some View {
        @Bindable var finder = model.finder
        let rows = finder.results()

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(finder.prompt(from: sources), text: $finder.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { model.acceptFinderSelection() }
                if finder.loading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if rows.isEmpty {
                Text(finder.loading ? "Looking…" : "Nothing matches")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            // Identified by the row, never by its position.
                            // `.id(i)` here — added so the scroller had
                            // something to aim at — overrode each row's
                            // identity with its index, so SwiftUI saw the same
                            // identities 0, 1, 2… however the query changed and
                            // reused the views it had already drawn: the list
                            // shed rows from the bottom while the ones on
                            // screen never updated, even though the model
                            // underneath was right the whole time.
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                FinderRow(row: row, picked: i == finder.index)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        finder.index = i
                                        model.acceptFinderSelection()
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: finder.index) { _, new in
                        guard rows.indices.contains(new) else { return }
                        withAnimation(.linear(duration: 0.08)) {
                            scroller.scrollTo(rows[new].id)
                        }
                    }
                }
            }
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(radius: 30, y: 10)
        .onAppear { focused = true }
    }
}

/// One row: what it is, where it is, and why it matched.
private struct FinderRow: View {
    let row: FinderModel.Row
    let picked: Bool

    private var item: FinderItem { row.item }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage ?? "doc")
                .frame(width: 18)
                .foregroundStyle(picked ? Color.white : .secondary)
            highlighted
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(picked ? AnyShapeStyle(Color.white.opacity(0.75))
                                            : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            // Which list this came from. With files, actions and tabs in one
            // ranked list, a row is hard to read without it.
            Text(row.source)
                .font(.caption2)
                .foregroundStyle(picked ? AnyShapeStyle(Color.white.opacity(0.75))
                                        : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Filled, not tinted: with scores of near-identical filenames on
        // screen, a faint background made moving the selection look like
        // nothing had happened.
        .background(picked ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(picked ? Color.white : .primary)
    }

    /// The matched characters, emphasised. Showing *why* a row is in the list
    /// is most of what makes a fuzzy finder feel predictable rather than
    /// magical — you can see which letters your query landed on, and correct.
    private var highlighted: Text {
        let hits = Set(row.matched)
        return item.title.enumerated().reduce(Text("")) { text, pair in
            let character = Text(String(pair.element))
            return text + (hits.contains(pair.offset)
                           ? character.bold().foregroundColor(picked ? .white : .accentColor)
                           : character)
        }
    }
}


private extension Array {
    /// Drops repeats by row id, keeping the best-scoring of each.
    ///
    /// Two mounted roots can reach the same file, and SwiftUI draws one row
    /// for a repeated identity — a silent way for a list to come up short.
    func uniqued<T>() -> [Element] where Element == (row: FinderModel.Row, score: T) {
        var seen = Set<String>()
        return filter { seen.insert($0.row.id).inserted }
    }
}


/// The finder over whichever window has the keyboard.
///
/// Applied per window rather than owned by the shell. `finderVisible` is one
/// app-wide flag — there is one finder, opened by one keymap — so every window
/// carrying this would show it at once; the gate picks the window the keys are
/// actually being typed in. It used to live in the shell alone, which meant
/// opening the finder from a loose file's window drew it in the main window,
/// behind the one you were looking at.
private struct FinderOverlay: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.overlay {
            if model.finderVisible, activeState == .key {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture { model.closeFinder() }
                    Finder()
                        .padding(.top, 90)
                }
            }
        }
    }
}

extension View {
    /// Show the finder here when this window holds the keyboard.
    func finderOverlay() -> some View { modifier(FinderOverlay()) }
}
