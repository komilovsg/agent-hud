import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Voice choice, speaking rate, the spoken-style marker

@Suite struct VoiceChoiceTests {
    private func v(_ name: String, _ lang: String, _ q: VoiceQuality = .standard, novelty: Bool = false, id: String? = nil) -> VoiceInfo {
        VoiceInfo(id: id ?? "id.\(lang).\(name)", name: name, language: lang, quality: q, isNovelty: novelty)
    }

    private var installed: [VoiceInfo] {
        [v("Samantha", "en-US"), v("Zoe", "en-US", .enhanced), v("Ava", "en-US", .premium), v("Daniel", "en-GB", .premium),
         v("Albert", "en-US", .premium, novelty: true), v("Milena", "ru-RU", .enhanced), v("Yuri", "ru-RU")]
    }

    // MARK: pick

    @Test func bestQualityOfTheExactLanguageWins() {
        #expect(VoiceChoice.pick(from: installed, language: "en-US", preferredId: nil)?.name == "Ava")
        #expect(VoiceChoice.pick(from: installed, language: "ru-RU", preferredId: nil)?.name == "Milena")
    }

    @Test func rankingIsPremiumThenEnhancedThenStandard() {
        let two = [v("A", "en-US"), v("B", "en-US", .enhanced)]
        #expect(VoiceChoice.pick(from: two, language: "en-US", preferredId: nil)?.name == "B")
        let three = two + [v("C", "en-US", .premium)]
        #expect(VoiceChoice.pick(from: three, language: "en-US", preferredId: nil)?.name == "C")
        #expect(VoiceChoice.pick(from: [v("A", "en-US")], language: "en-US", preferredId: nil)?.name == "A")
    }

    @Test func exactLanguageBeatsAHigherQualityOfAnotherRegion() {
        let list = [v("Daniel", "en-GB", .premium), v("Samantha", "en-US")]
        #expect(VoiceChoice.pick(from: list, language: "en-US", preferredId: nil)?.name == "Samantha")
    }

    @Test func sameBaseLanguageIsTheFallback() {
        let list = [v("Daniel", "en-GB"), v("Serena", "en-GB", .enhanced), v("Milena", "ru-RU")]
        #expect(VoiceChoice.pick(from: list, language: "en-US", preferredId: nil)?.name == "Serena")
        #expect(VoiceChoice.pick(from: list, language: "ru-RU", preferredId: nil)?.name == "Milena")
    }

    @Test func nilOnlyWhenNothingSpeaksTheLanguage() {
        #expect(VoiceChoice.pick(from: [v("Milena", "ru-RU")], language: "en-US", preferredId: nil) == nil)
        #expect(VoiceChoice.pick(from: [], language: "en-US", preferredId: nil) == nil)
        #expect(VoiceChoice.pick(from: installed, language: "", preferredId: nil) == nil)
    }

    @Test func noveltyIsNeverChosenAutomatically() {
        let onlyNovelty = [v("Albert", "en-US", .premium, novelty: true), v("Bells", "en-US", novelty: true)]
        #expect(VoiceChoice.pick(from: onlyNovelty, language: "en-US", preferredId: nil) == nil)
        let mixed = onlyNovelty + [v("Samantha", "en-GB")]
        #expect(VoiceChoice.pick(from: mixed, language: "en-US", preferredId: nil)?.name == "Samantha")
    }

    @Test func theChosenVoiceWinsWhileInstalledAndMatching() {
        let chosen = v("Samantha", "en-US")
        #expect(VoiceChoice.pick(from: installed, language: "en-US", preferredId: chosen.id)?.name == "Samantha")
        // Another region of the same language is allowed: the picker offers it.
        #expect(VoiceChoice.pick(from: installed, language: "en-US", preferredId: v("Daniel", "en-GB").id)?.name == "Daniel")
        // A voice that was picked on purpose is kept even if it is a novelty one.
        #expect(VoiceChoice.pick(from: installed, language: "en-US", preferredId: v("Albert", "en-US").id)?.name == "Albert")
    }

    @Test func aMissingOrWrongLanguageChoiceFallsBackToAutomatic() {
        #expect(VoiceChoice.pick(from: installed, language: "en-US", preferredId: "id.removed")?.name == "Ava")
        #expect(VoiceChoice.pick(from: installed, language: "en-US", preferredId: v("Milena", "ru-RU").id)?.name == "Ava")
        #expect(VoiceChoice.pick(from: installed, language: "en-US", preferredId: "")?.name == "Ava")
    }

    @Test func tiesAreBrokenByNameWhateverTheOrder() {
        let a = v("Beth", "en-US"), b = v("Alan", "en-US"), c = v("Carl", "en-US")
        for order in [[a, b, c], [c, b, a], [b, c, a], [a, c, b]] {
            #expect(VoiceChoice.pick(from: order, language: "en-US", preferredId: nil)?.name == "Alan")
        }
        // Same name and quality: the id decides.
        let x = v("Same", "en-US", id: "x.2"), y = v("Same", "en-US", id: "x.1")
        #expect(VoiceChoice.pick(from: [x, y], language: "en-US", preferredId: nil)?.id == "x.1")
        #expect(VoiceChoice.pick(from: [y, x], language: "en-US", preferredId: nil)?.id == "x.1")
    }

    @Test func languageCodesAreComparedLoosely() {
        let list = [v("Samantha", "en_US"), v("Milena", "ru-ru")]
        #expect(VoiceChoice.pick(from: list, language: "en-US", preferredId: nil)?.name == "Samantha")
        #expect(VoiceChoice.pick(from: list, language: "ru-RU", preferredId: nil)?.name == "Milena")
        #expect(VoiceChoice.pick(from: [v("Samantha", "en")], language: "en-US", preferredId: nil)?.name == "Samantha")
    }

    // MARK: list

    @Test func theListHoldsTheBaseLanguageWithoutNoveltyBestFirst() {
        let names = VoiceChoice.list(from: installed, language: "en-US").map(\.name)
        #expect(names == ["Ava", "Daniel", "Zoe", "Samantha"])
        #expect(VoiceChoice.list(from: installed, language: "ru-RU").map(\.name) == ["Milena", "Yuri"])
        #expect(VoiceChoice.list(from: installed, language: "de-DE").isEmpty)
        #expect(VoiceChoice.list(from: [], language: "en-US").isEmpty)
        let twice = [VoiceInfo(id: "b.super-compact", name: "Samantha", language: "en-US", quality: .standard),
                     VoiceInfo(id: "a.compact", name: "Samantha", language: "en-US", quality: .standard),
                     VoiceInfo(id: "c", name: "Samantha", language: "en-US", quality: .enhanced)]
        #expect(VoiceChoice.list(from: twice, language: "en-US").map(\.id) == ["c", "a.compact"])
    }

    @Test func labelsNameTheQuality() {
        #expect(v("Ava", "en-US", .premium).label == "Ava \u{2014} Premium")
        #expect(v("Milena", "ru-RU", .enhanced).label == "Milena \u{2014} Enhanced")
        #expect(v("Samantha", "en-US").label == "Samantha")
    }

    // MARK: legacy identifiers

    @Test func olderSynthesizersAreRecognisedByIdentifier() {
        #expect(VoiceChoice.isLegacyIdentifier("com.apple.speech.synthesis.voice.Fred"))
        #expect(VoiceChoice.isLegacyIdentifier("com.apple.eloquence.en-US.Rocko"))
        #expect(!VoiceChoice.isLegacyIdentifier("com.apple.voice.compact.en-US.Samantha"))
        #expect(!VoiceChoice.isLegacyIdentifier("com.apple.voice.premium.en-US.Ava"))
        #expect(!VoiceChoice.isLegacyIdentifier(""))
    }

    // MARK: rate

    @Test func rateIsClampedToTheSettingRange() {
        #expect(VoiceRate.clamped(1.0) == 1.0)
        #expect(VoiceRate.clamped(0.1) == 0.8)
        #expect(VoiceRate.clamped(5) == 1.3)
        #expect(VoiceRate.clamped(.nan) == 1.0)
        #expect(VoiceRate.clamped(.infinity) == 1.0)
    }

    @Test func utteranceRateScalesAroundThePlatformDefault() {
        #expect(VoiceRate.utteranceRate(multiplier: 1.0, platformDefault: 0.5, platformMin: 0, platformMax: 1) == 0.5)
        #expect(abs(VoiceRate.utteranceRate(multiplier: 1.3, platformDefault: 0.5, platformMin: 0, platformMax: 1) - 0.65) < 0.0001)
        #expect(abs(VoiceRate.utteranceRate(multiplier: 0.8, platformDefault: 0.5, platformMin: 0, platformMax: 1) - 0.4) < 0.0001)
        // Out of range multipliers are clamped first, then the platform's limits apply.
        #expect(abs(VoiceRate.utteranceRate(multiplier: 9, platformDefault: 0.5, platformMin: 0, platformMax: 1) - 0.65) < 0.0001)
        #expect(VoiceRate.utteranceRate(multiplier: 1.3, platformDefault: 0.5, platformMin: 0, platformMax: 0.6) == 0.6)
        #expect(VoiceRate.utteranceRate(multiplier: 0.8, platformDefault: 0.5, platformMin: 0.45, platformMax: 1) == 0.45)
    }

    // MARK: preview samples

    @Test func previewSamplesAreFixedAndRussianHasNoCyrillicInSource() {
        #expect(VoiceLanguages.info(code: "en-US").previewSample == "Done. The report is saved in your Documents folder.")
        let ru = VoiceLanguages.info(code: "ru-RU").previewSample
        #expect(ru.hasPrefix("\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}."))
        #expect(ru.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
    }
}

@Suite struct SpokenStyleTests {
    @Test func markAddsTheMarkerAndDisplayRemovesIt() {
        let marked = SpokenStyle.mark("open the report")
        #expect(marked == "[spoken] open the report")
        #expect(SpokenStyle.display(marked) == "open the report")
        #expect(SpokenStyle.isMarked(marked))
    }

    @Test func plainTextIsUntouched() {
        for t in ["open the report", "", "  indented", "a [spoken] b", "[spokenly] word", "[spoke] x"] {
            #expect(SpokenStyle.display(t) == t, "\(t)")
            #expect(!SpokenStyle.isMarked(t))
        }
    }

    @Test func oddSpacingAndShapesAreHandled() {
        #expect(SpokenStyle.display("[spoken]   two spaces") == "two spaces")
        #expect(SpokenStyle.display("  [spoken] leading space") == "leading space")
        #expect(SpokenStyle.display("[spoken]\nnext line") == "\nnext line")
        #expect(SpokenStyle.display("[spoken]") == "")
        #expect(SpokenStyle.display("[spoken] ") == "")
        #expect(SpokenStyle.display("[spoken] [spoken] twice") == "[spoken] twice")
    }

    @Test func genderFormsMarkAndDisplay() {
        #expect(SpokenStyle.mark("hi", gender: .female) == "[spoken f] hi")
        #expect(SpokenStyle.mark("hi", gender: .male) == "[spoken m] hi")
        #expect(SpokenStyle.mark("hi", gender: nil) == "[spoken] hi")
        for g in [nil, SpokenStyle.Gender.female, .male] {
            let marked = SpokenStyle.mark("open the report", gender: g)
            #expect(SpokenStyle.display(marked) == "open the report")
            #expect(SpokenStyle.isMarked(marked))
        }
        #expect(SpokenStyle.display("[spoken f]") == "")
        #expect(SpokenStyle.display("  [spoken m]   two") == "two")
        #expect(SpokenStyle.display("[spoken f]\nnext") == "\nnext")
        #expect(SpokenStyle.display("[spoken f] [spoken m] twice") == "[spoken m] twice")
    }

    @Test func genderLookAlikesAreWords() {
        for t in ["[spoken x] a", "[spoken fm] a", "[spoken f]a", "[spoken  f] a", "[spoken F] a", "[spoken ] a", "[spoken f a", "spoken f] a",
                  "[spokenf] a"] {
            #expect(SpokenStyle.display(t) == t, "\(t)")
            #expect(!SpokenStyle.isMarked(t))
        }
    }

    @Test func promptNamesAllThreeMarkers() {
        let p = AssistantSession.systemPrompt
        #expect(p.contains("\"[spoken f]\"") && p.contains("\"[spoken m]\"") && p.contains("feminine") && p.contains("masculine"))
    }

    @Test func theMarkerIsOneConstantUsedByThePrompt() {
        #expect(SpokenStyle.marker == "[spoken] ")
        #expect(AssistantSession.systemPrompt.contains("[spoken]"))
        #expect(AssistantSession.systemPrompt.contains("language the person used"))
        #expect(AssistantSession.systemPrompt.contains("read aloud"))
    }

    @Test func theTitleOfASessionStartedByVoiceHasNoMarker() {
        var store = SessionStore()
        let e = AgentEvent(kind: .claude, sessionId: "s1", cwd: "/tmp/x", time: Date(timeIntervalSince1970: 1_000),
                           body: .promptSubmitted(SpokenStyle.mark("Open the quarterly report")))
        _ = store.apply(e)
        #expect(store.session("claude:s1")?.title == "Open the quarterly report")
    }
}
