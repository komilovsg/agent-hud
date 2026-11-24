import Foundation

// Choosing the synthesizer voice that reads replies aloud. Pure: the app target maps the installed voices
// to `VoiceInfo` and asks here which one to use.

public enum VoiceQuality: Int, Comparable, Equatable, Sendable {
    case standard = 0
    case enhanced = 1
    case premium = 2

    public static func < (a: VoiceQuality, b: VoiceQuality) -> Bool { a.rawValue < b.rawValue }

    /// The word shown after a voice name; nothing for a standard voice.
    var suffix: String? {
        switch self {
        case .standard: return nil
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        }
    }
}

/// One installed synthesizer voice, as far as the choice needs to know.
public struct VoiceInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// BCP-47 style code of the voice, e.g. "en-US".
    public let language: String
    public let quality: VoiceQuality
    /// A novelty voice, or one of the old synthesizers: never chosen automatically and not offered in the picker.
    public let isNovelty: Bool

    public init(id: String, name: String, language: String, quality: VoiceQuality, isNovelty: Bool = false) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
    }

    /// "Ava — Premium", "Milena — Enhanced", "Samantha".
    public var label: String {
        guard let q = quality.suffix else { return name }
        return "\(name) \u{2014} \(q)"
    }
}

public enum VoiceChoice {
    /// Voices of the two older synthesizers (the novelty set, Fred, Junior...) and the Eloquence set sound robotic
    /// even when the system flags no trait on them, so the identifier prefix counts as well.
    public static let legacyIdentifierPrefixes = ["com.apple.speech.synthesis.voice.", "com.apple.eloquence."]

    public static func isLegacyIdentifier(_ identifier: String) -> Bool {
        legacyIdentifierPrefixes.contains { identifier.hasPrefix($0) }
    }

    /// "en_US" and "en-us" both become "en-US"; a bare "en" stays.
    static func normalized(_ language: String) -> String {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return "" }
        let rest = parts.dropFirst().map { $0.count == 2 ? $0.uppercased() : $0.capitalized }
        return ([first.lowercased()] + rest).joined(separator: "-")
    }

    /// "en" for "en-US".
    static func baseLanguage(_ language: String) -> String {
        normalized(language).split(separator: "-").first.map(String.init) ?? ""
    }

    /// Best first: quality, then name, then id, so the order never depends on the order the system lists voices in.
    private static func better(_ a: VoiceInfo, _ b: VoiceInfo) -> Bool {
        if a.quality != b.quality { return a.quality > b.quality }
        if a.name != b.name { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        return a.id < b.id
    }

    /// The voice to speak with. The person's own pick wins while it is installed and speaks the language; otherwise
    /// the best installed voice of exactly that language, then of the same base language (en-GB for en-US).
    /// Novelty and legacy voices are only ever used when the person picked them. Nil when nothing fits.
    public static func pick(from voices: [VoiceInfo], language: String, preferredId: String?) -> VoiceInfo? {
        let want = normalized(language)
        let base = baseLanguage(language)
        guard !base.isEmpty else { return nil }
        if let id = preferredId, !id.isEmpty,
           let chosen = voices.first(where: { $0.id == id && baseLanguage($0.language) == base }) {
            return chosen
        }
        let usable = voices.filter { !$0.isNovelty }
        if let exact = usable.filter({ normalized($0.language) == want }).min(by: better) { return exact }
        return usable.filter { baseLanguage($0.language) == base }.min(by: better)
    }

    /// The voices the picker offers for a language: no novelty voices, every voice of the base language, best first.
    public static func list(from voices: [VoiceInfo], language: String) -> [VoiceInfo] {
        let base = baseLanguage(language)
        guard !base.isEmpty else { return [] }
        // The system lists some voices twice (a compact and a smaller build); the picker shows each once.
        var seen = Set<String>()
        return voices.filter { !$0.isNovelty && baseLanguage($0.language) == base }.sorted(by: better)
            .filter { seen.insert("\($0.name)|\(normalized($0.language))|\($0.quality.rawValue)").inserted }
    }
}

// MARK: - Speaking rate

public enum VoiceRate {
    public static let minMultiplier = 0.8
    public static let maxMultiplier = 1.3
    public static let defaultMultiplier = 1.0

    /// A stored or dragged value brought into range; garbage becomes the default.
    public static func clamped(_ multiplier: Double) -> Double {
        guard multiplier.isFinite else { return defaultMultiplier }
        return min(maxMultiplier, max(minMultiplier, multiplier))
    }

    /// The utterance rate: the platform's default rate scaled by the multiplier, kept inside the platform's range.
    public static func utteranceRate(multiplier: Double, platformDefault: Float, platformMin: Float, platformMax: Float) -> Float {
        let scaled = platformDefault * Float(clamped(multiplier))
        return min(platformMax, max(platformMin, scaled))
    }
}
