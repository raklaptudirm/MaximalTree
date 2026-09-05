import Testing
import AppKit
@testable import MaximalEditorKit
@testable import MaximalTree

/// Choosing what Write mode sets prose in, and how big.
@MainActor
@Suite struct ProseStyleTests {
    /// Restore whatever the machine actually has chosen — these tests write to
    /// the same defaults the app reads.
    private func withStoredChoice(_ body: () throws -> Void) rethrows {
        let key = "typst.proseFont"
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try body()
    }

    /// The picker offers only what the machine can set text in. Listing a font
    /// that isn't installed would look like a choice and behave like a
    /// substitution — the reader would see a different face than the one they
    /// picked, with nothing saying so.
    @Test func onlyInstalledFacesAreOffered() {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        for font in ProseFont.available {
            guard let family = font.family else { continue }
            #expect(installed.contains(family), "\(family) is offered but not installed")
        }
    }

    /// The system serif is always there: it needs no font to be installed, and
    /// it is what the editor falls back to.
    @Test func theSystemSerifIsAlwaysAvailable() {
        #expect(ProseFont.available.contains(.system))
        #expect(ProseFont.available.first == .system)
        #expect(ProseFont.system.family == nil)
    }

    /// A face chosen and then uninstalled is a face that isn't there any more,
    /// not an error: the choice falls back to the system serif.
    @Test func anUninstalledChoiceFallsBackToTheSystem() {
        withStoredChoice {
            UserDefaults.standard.set("A Font Nobody Has", forKey: "typst.proseFont")
            #expect(ProseFont.stored == .system)
        }
    }

    @Test func aChoiceSurvivesBeingWrittenDown() throws {
        try withStoredChoice {
            let font = try #require(ProseFont.available.first { $0.family != nil },
                                    "no third-party face installed to test with")
            font.store()
            #expect(ProseFont.stored == font)

            ProseFont.system.store()
            #expect(ProseFont.stored == .system)
        }
    }

    /// Stepping through the list is how you find the one you can read, so it
    /// wraps rather than stopping at the ends.
    @Test func cyclingWrapsAtBothEnds() {
        withStoredChoice {
            let state = TypstUIState.shared
            let fonts = ProseFont.available
            guard fonts.count > 1 else { return }
            let original = state.proseFont

            state.proseFont = fonts[0]
            state.cycleProseFont(by: -1)
            #expect(state.proseFont == fonts[fonts.count - 1], "backwards off the front")
            state.cycleProseFont(by: 1)
            #expect(state.proseFont == fonts[0], "and forwards again")

            state.proseFont = original
        }
    }

    /// The style names a family and leaves the weight and the italic to the
    /// variant machinery, so bold and emphasis in the manuscript stay in the
    /// face you chose.
    @Test func proseStyleUsesTheNamedFamily() throws {
        let family = try #require(ProseFont.available.first { $0.family != nil }?.family)
        let style = EditorStyle.prose(family: family)
        #expect(style.design == .family(family))
        #expect(style.font.familyName == family)
        #expect(fontVariant(of: style.font, bold: true).familyName == family)
    }

    /// A style naming a font that isn't there still draws something readable.
    @Test func anUnknownFamilyFallsBackRatherThanFailing() {
        let style = EditorStyle.prose(family: "A Font Nobody Has")
        #expect(style.font.pointSize == EditorStyle.prose().font.pointSize)
    }

    /// Write mode is the only place the choice shows, and the code editor is
    /// deliberately untouched by it.
    @Test func theCodeStyleIsStillMonospaced() {
        #expect(EditorStyle.code().design == .monospaced)
        #expect(EditorStyle.prose().design == .serif)
    }

    // MARK: The column

    /// The measure is the point: a line holds about the same number of
    /// characters at any size, because the column grows with the text rather
    /// than staying a fixed number of points.
    @Test func theColumnHoldsTheSameMeasureAtEverySize() {
        let alphabet = "abcdefghijklmnopqrstuvwxyz" as NSString
        for size in [12, 15, 20, 24] as [CGFloat] {
            let style = EditorStyle.prose(size: size)
            let one = alphabet.size(withAttributes: [.font: style.font]).width
            let alphabets = (style.idealColumnWidth - 10) / one
            #expect(abs(alphabets - 2.5) < 0.05,
                    "\(size)pt gives \(alphabets) alphabets, not the measure")
        }
    }

    @Test func aBiggerSizeGetsAWiderColumn() {
        #expect(EditorStyle.prose(size: 24).idealColumnWidth
                > EditorStyle.prose(size: 15).idealColumnWidth)
    }

    /// Measured in the face, not counted in characters: a narrow face gets a
    /// narrower column for the same measure rather than a longer line.
    @Test func aNarrowerFaceGetsANarrowerColumn() throws {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        try #require(installed.contains("EB Garamond") && installed.contains("Literata"),
                     "needs both faces installed to compare")
        let garamond = EditorStyle.prose(family: "EB Garamond").idealColumnWidth
        let literata = EditorStyle.prose(family: "Literata").idealColumnWidth
        #expect(garamond < literata)
    }

    // MARK: Size

    private func withStoredSize(_ body: () -> Void) {
        let key = "typst.proseSize"
        let previous = UserDefaults.standard.object(forKey: key) as? Double
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    /// Outside its range the manuscript stops being one, so the size is held
    /// inside it however it is set — stepper, action, or a defaults file
    /// somebody edited by hand.
    @Test func theSizeStaysInsideWhatIsStillAManuscript() {
        #expect(ProseSize.clamped(4) == ProseSize.range.lowerBound)
        #expect(ProseSize.clamped(400) == ProseSize.range.upperBound)
        #expect(ProseSize.clamped(16) == 16)
        #expect(ProseSize.range.contains(ProseSize.standard))

        withStoredSize {
            UserDefaults.standard.set(999.0, forKey: "typst.proseSize")
            #expect(ProseSize.stored == ProseSize.range.upperBound)
        }
    }

    @Test func nothingStoredIsTheStandardSize() {
        withStoredSize {
            UserDefaults.standard.removeObject(forKey: "typst.proseSize")
            #expect(ProseSize.stored == ProseSize.standard)
        }
    }

    @Test func aSizeSurvivesBeingWrittenDown() {
        withStoredSize {
            ProseSize.store(19)
            #expect(ProseSize.stored == 19)
        }
    }

    /// Stepping stops at the ends rather than wrapping — unlike the faces,
    /// where wrapping is how you get round the list. Nobody wants 11pt for
    /// pressing "bigger" once too often.
    @Test func steppingStopsAtTheEnds() {
        withStoredSize {
            let state = TypstUIState.shared
            let original = state.proseSize
            defer { state.proseSize = original }

            state.proseSize = ProseSize.range.upperBound
            state.stepProseSize(by: 1)
            #expect(state.proseSize == ProseSize.range.upperBound)

            state.proseSize = ProseSize.range.lowerBound
            state.stepProseSize(by: -1)
            #expect(state.proseSize == ProseSize.range.lowerBound)

            state.stepProseSize(by: 3)
            #expect(state.proseSize == ProseSize.range.lowerBound + 3)
        }
    }

    /// The size reaches the text: line spacing is derived from it, so a
    /// bigger face gets a roomier line rather than the same gap.
    @Test func theStyleTakesTheSizeAndSpacesForIt() {
        let small = EditorStyle.prose(size: 12)
        let large = EditorStyle.prose(size: 24)
        #expect(small.font.pointSize == 12)
        #expect(large.font.pointSize == 24)
        #expect(large.lineSpacing > small.lineSpacing)
    }
}
