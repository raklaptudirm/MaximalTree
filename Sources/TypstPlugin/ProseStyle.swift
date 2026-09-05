import AppKit

/// How Write mode sets prose: which face, and how big.
///
/// Both are preferences rather than document properties, and both are stored
/// the same way — see `ProseFont` below for why.

/// A typeface offered for the prose editor.
///
/// Write mode is a manuscript rather than a source view, and which face a
/// manuscript is set in is the sort of thing you settle by looking at your own
/// prose in it for an afternoon. So the choice is a preference, not a
/// per-document property: switching it changes every document you open, which
/// is what "trying one out" means.
///
/// The candidates are a shortlist rather than the whole font book — every
/// family here is one people write long text in, and a picker with four
/// hundred entries is a picker nobody uses. Anything not installed is dropped
/// from the list instead of being offered and silently substituted.
struct ProseFont: Identifiable, Hashable {
    /// The family as the font system names it; nil is the system serif.
    let family: String?
    /// What to call it in the picker, when the family name isn't it.
    let label: String
    /// What it's for, in the few words a picker has room for.
    let note: String

    var id: String { family ?? "" }
    var name: String { label.isEmpty ? (family ?? "System Serif") : label }

    /// The system serif — New York, and what the editor used before there was
    /// anything to choose.
    static let system = ProseFont(family: nil, label: "New York (System)",
                                  note: "Apple's serif, drawn for screens")

    /// Every candidate, installed or not, in the order the picker shows them:
    /// the sturdy defaults, then the faces drawn for reading on a screen, then
    /// the ones that are really for paper, then the two with matching math.
    static let candidates: [ProseFont] = [
        system,
        ProseFont(family: "Source Serif 4", label: "",
                  note: "Sturdy, screen and print both"),
        ProseFont(family: "Charter", label: "",
                  note: "Economical, legible anywhere"),
        ProseFont(family: "XCharter", label: "",
                  note: "Charter with oldstyle figures"),
        ProseFont(family: "Gentium Plus", label: "",
                  note: "Humanist, deep diacritic coverage"),

        ProseFont(family: "Literata", label: "",
                  note: "Tuned for long stretches on a display"),
        ProseFont(family: "Spectral", label: "",
                  note: "The same brief, more elegant"),
        ProseFont(family: "iA Writer Duo S", label: "iA Writer Duo",
                  note: "Duospaced: monospace habits, prose colour"),
        ProseFont(family: "iA Writer Quattro S", label: "iA Writer Quattro",
                  note: "Duospaced, a touch narrower"),

        ProseFont(family: "EB Garamond", label: "",
                  note: "Lovely on paper, thin on screen"),
        ProseFont(family: "Alegreya", label: "",
                  note: "Drawn for literature, warm italic"),
        ProseFont(family: "Crimson Pro", label: "",
                  note: "Garamond-adjacent, sturdier"),
        ProseFont(family: "Vollkorn", label: "",
                  note: "Garamond-adjacent, heavier still"),

        ProseFont(family: "Libertinus Serif", label: "",
                  note: "Pairs with Libertinus Math"),
        ProseFont(family: "STIX Two Text", label: "",
                  note: "Times-like; pairs with STIX Two Math"),
        ProseFont(family: "NewComputerModern", label: "New Computer Modern",
                  note: "The TeX look, with real italics"),
    ]

    /// The candidates this Mac can actually set text in.
    ///
    /// Resolved once: the font list is a system-wide scan, and this is read
    /// every time the inspector draws. A font installed while the app is
    /// running therefore appears at the next launch — the same bargain the
    /// engine's own font scan makes.
    static let available: [ProseFont] = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return candidates.filter { $0.family.map(installed.contains) ?? true }
    }()

    // MARK: Stored choice

    private static let key = "typst.proseFont"

    /// The chosen face, or the system serif when nothing is chosen — or when
    /// what was chosen is no longer installed, which is a font uninstalled
    /// between launches rather than an error worth reporting.
    static var stored: ProseFont {
        let family = UserDefaults.standard.string(forKey: key)
        return available.first { $0.family == family } ?? system
    }

    func store() {
        if let family {
            UserDefaults.standard.set(family, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}

/// How big Write mode sets prose.
///
/// A companion to the face, because the two are one decision: these families
/// do not share an x-height, and EB Garamond at the size Literata reads well
/// at is noticeably smaller. Changing the face without being able to answer
/// that is half a choice.
enum ProseSize {
    /// Small enough to fit a wide margin, large enough to read at arm's
    /// length. Outside this the manuscript stops being one.
    static let range: ClosedRange<CGFloat> = 11...28
    static let standard: CGFloat = 15

    private static let key = "typst.proseSize"

    /// The chosen size, or the standard one — including when what was stored
    /// is outside the range, which is a preference file edited by hand.
    static var stored: CGFloat {
        let raw = UserDefaults.standard.object(forKey: key) as? Double
        return raw.map { clamped(CGFloat($0)) } ?? standard
    }

    static func store(_ size: CGFloat) {
        UserDefaults.standard.set(Double(clamped(size)), forKey: key)
    }

    static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size, range.lowerBound), range.upperBound)
    }
}
