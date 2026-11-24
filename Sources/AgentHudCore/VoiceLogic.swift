import Foundation

// Push-to-talk voice for the command bar. Pure logic only: the microphone, the recognizer and the synthesizer
// live in the app target behind two small protocols. Nothing in here maps words to an approval: voice produces
// a user message and nothing else.

// MARK: - Languages

public struct VoiceLanguage: Equatable, Sendable, Identifiable {
    /// The stored setting value and the recognizer locale, e.g. "en-US".
    public let code: String
    public let label: String
    /// Locale of the synthesizer voice that reads replies in this language.
    public let speechLocale: String
    /// What is spoken in place of a code block and in place of a link.
    public let codeOmitted: String
    public let linkWord: String
    /// The fixed sentence the settings' Preview button speaks.
    public let previewSample: String
    public var id: String { code }
}

public enum VoiceLanguages {
    public static let defaultCode = "en-US"

    public static let all: [VoiceLanguage] = [
        VoiceLanguage(code: "en-US", label: "English (US)", speechLocale: "en-US", codeOmitted: "code omitted", linkWord: "link",
                      previewSample: "Done. The report is saved in your Documents folder."),
        // "kod propushchen" and "ssylka" in Russian, written as escapes.
        VoiceLanguage(code: "ru-RU", label: "Russian", speechLocale: "ru-RU",
                      codeOmitted: "\u{043A}\u{043E}\u{0434} \u{043F}\u{0440}\u{043E}\u{043F}\u{0443}\u{0449}\u{0435}\u{043D}",
                      linkWord: "\u{0441}\u{0441}\u{044B}\u{043B}\u{043A}\u{0430}",
                      // "Gotovo. Otchyot sokhranyon v papke Dokumenty." in Russian.
                      previewSample: "\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}. "
                          + "\u{041E}\u{0442}\u{0447}\u{0451}\u{0442} \u{0441}\u{043E}\u{0445}\u{0440}\u{0430}\u{043D}\u{0451}\u{043D} "
                          + "\u{0432} \u{043F}\u{0430}\u{043F}\u{043A}\u{0435} \u{00AB}\u{0414}\u{043E}\u{043A}\u{0443}\u{043C}\u{0435}\u{043D}\u{0442}\u{044B}\u{00BB}."),
    ]

    /// An unknown or missing stored value falls back to English.
    public static func info(code: String?) -> VoiceLanguage {
        all.first { $0.code == code } ?? all[0]
    }
}

// MARK: - Tap or hold

/// Tells a tap (toggle the bar) from a hold (talk) for one key, from timestamps in seconds on a monotonic clock.
/// The caller schedules a timer for `holdThreshold` after a press and feeds the result back in.
public struct HoldGesture: Equatable, Sendable {
    public static let holdThreshold: TimeInterval = 0.3
    /// Clock jitter allowed when a timer set for the threshold reports back.
    static let tolerance: TimeInterval = 0.005

    public enum Action: Equatable, Sendable {
        case none
        /// First press: start the timer.
        case scheduleHold(after: TimeInterval)
        /// Pressed and released before the threshold.
        case toggle
        /// The key has been down for the threshold: open the microphone now.
        case startTalking
        /// Released after talking started: close the microphone.
        case stopTalking
    }

    public private(set) var pressedAt: TimeInterval?
    public private(set) var talking = false

    public init() {}

    public var isDown: Bool { pressedAt != nil }

    /// Auto-repeat while the key is down is ignored.
    public mutating func press(at t: TimeInterval) -> Action {
        guard pressedAt == nil else { return .none }
        pressedAt = t
        talking = false
        return .scheduleHold(after: Self.holdThreshold)
    }

    /// The timer fired. A timer that fires early (or after a release) does nothing.
    public mutating func holdTimerFired(at t: TimeInterval) -> Action {
        guard let p = pressedAt, !talking, t - p >= Self.holdThreshold - Self.tolerance else { return .none }
        talking = true
        return .startTalking
    }

    /// A release without a press is ignored. A release past the threshold whose timer never ran (a stalled main
    /// queue) counts as a tap: the microphone was never opened, so nothing is closed.
    public mutating func release(at t: TimeInterval) -> Action {
        guard pressedAt != nil else { return .none }
        let wasTalking = talking
        pressedAt = nil
        talking = false
        return wasTalking ? .stopTalking : .toggle
    }

    /// Forgets a half-seen gesture (for example when the hotkey is re-registered).
    public mutating func reset() {
        pressedAt = nil
        talking = false
    }
}

// MARK: - Listening state machine

public enum VoiceState: Equatable, Sendable {
    case idle
    /// Key down, under the hold threshold: the microphone is closed.
    case armed
    case listening
    /// Key released, microphone closed, waiting for the final text.
    case finishing
    case countdown
    // End states. The next press starts from here exactly as from idle.
    case sent
    case cancelled
    case editing
}

public enum VoiceInput: Equatable, Sendable {
    case pressed
    case holdReached
    case released
    /// Recognition could not start (permission, availability, engine error): back to idle.
    case aborted
    case capReached
    case finalTranscript(String)
    case countdownElapsed
    case escape
    /// A key typed while the countdown runs.
    case typed
    /// Return while the countdown runs: send now.
    case submit
}

public enum VoiceEffect: Equatable, Sendable {
    case stopSpeech
    case startListening
    /// Close the microphone and wait for the final text.
    case stopListening
    /// Close the microphone and drop what was heard.
    case cancelListening
    case fillField(String)
    case startCountdown
    case cancelCountdown
    case send
    case didntCatch
}

public enum VoiceMachine {
    public static let maxUtterance: TimeInterval = 60
    public static let countdown: TimeInterval = 1.5

    public struct Step: Equatable, Sendable {
        public var state: VoiceState
        public var effects: [VoiceEffect]
    }

    /// `sendAfterSpeaking`: the setting that decides whether a heard text counts down and goes out by itself.
    public static func reduce(_ state: VoiceState, _ input: VoiceInput, sendAfterSpeaking: Bool) -> Step {
        func stay() -> Step { Step(state: state, effects: []) }
        func go(_ s: VoiceState, _ e: [VoiceEffect] = []) -> Step { Step(state: s, effects: e) }

        switch state {
        case .idle, .sent, .cancelled, .editing:
            return input == .pressed ? go(.armed, [.stopSpeech]) : stay()

        case .armed:
            switch input {
            case .holdReached: return go(.listening, [.startListening])
            case .released, .aborted: return go(.idle)
            default: return stay()
            }

        case .listening:
            switch input {
            case .released, .capReached: return go(.finishing, [.stopListening])
            case .escape: return go(.cancelled, [.cancelListening])
            case .aborted: return go(.idle)
            default: return stay()
            }

        case .finishing:
            switch input {
            case .finalTranscript(let raw):
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { return go(.idle, [.didntCatch]) }
                return sendAfterSpeaking ? go(.countdown, [.fillField(text), .startCountdown]) : go(.editing, [.fillField(text)])
            case .aborted: return go(.idle)
            case .escape: return go(.cancelled, [.cancelListening])
            // A new utterance replaces the one still being finished.
            case .pressed: return go(.armed, [.cancelListening, .stopSpeech])
            default: return stay()
            }

        case .countdown:
            switch input {
            case .countdownElapsed: return go(.sent, [.send])
            case .submit: return go(.sent, [.cancelCountdown, .send])
            case .escape: return go(.cancelled, [.cancelCountdown])
            case .typed: return go(.editing, [.cancelCountdown])
            case .pressed: return go(.armed, [.cancelCountdown, .stopSpeech])
            default: return stay()
            }
        }
    }

    /// States in which the bar owns the keyboard for voice (Esc and typing mean something special).
    public static func isBusy(_ state: VoiceState) -> Bool {
        switch state {
        case .listening, .finishing, .countdown: return true
        default: return false
        }
    }
}

// MARK: - Texts

public enum VoiceText {
    public static let countdownLine = "Sending\u{2026} Esc to cancel, any key to edit"
    public static let listeningLine = "Listening \u{2014} release the key to finish, Esc cancels"
    public static let finishingLine = "Finishing\u{2026}"
    public static let didntCatch = "Didn't catch that"
    public static let listeningPlaceholder = "Speak now"
    public static let serverNote = "Audio then leaves this Mac and goes to Apple for recognition."
    public static let microphoneStatement = "The microphone is on only while you hold the key"

    /// The heard text goes into the field: an empty field gets it as is, a draft keeps its text in front.
    public static func merged(draft: String, transcript: String) -> String {
        let d = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty { return t }
        if t.isEmpty { return draft }
        return draft.trimmingCharacters(in: .whitespaces) + " " + t
    }
}

// MARK: - Recognition availability

public enum VoiceAvailability: Equatable, Sendable {
    case onDevice
    /// On-device is missing for the language and the person allowed Apple's servers.
    case server
    case unavailable(String)

    public var requiresOnDevice: Bool { self == .onDevice }

    /// No silent fall back to the servers: that needs the setting.
    public static func decide(recognizerAvailable: Bool, supportsOnDevice: Bool, allowServer: Bool, languageLabel: String) -> VoiceAvailability {
        guard recognizerAvailable else {
            return .unavailable("Speech recognition is not available for \(languageLabel) right now")
        }
        if supportsOnDevice { return .onDevice }
        if allowServer { return .server }
        // macOS downloads a language's on-device model when the language is added to Dictation.
        return .unavailable("On-device recognition is not available for \(languageLabel). "
                            + "Add \(languageLabel) under System Settings > Keyboard > Dictation to download it, "
                            + "or turn on \"Allow recognition through Apple's servers\" in the Voice settings.")
    }
}

// MARK: - Permissions

public enum VoicePermissions {
    public static let required: [PermissionKind] = [.microphone, .speechRecognition]

    /// The two permissions limit the app only while voice is switched on.
    public static func inUse(voiceEnabled: Bool) -> Set<PermissionKind> {
        voiceEnabled ? Set(required) : []
    }

    /// Anything not granted counts as missing: holding the key must never reach the system prompt.
    public static func missing(_ statuses: [PermissionKind: PermissionStatus]) -> [PermissionKind] {
        required.filter { statuses[$0] != .granted }
    }

    public static func message(missing: [PermissionKind]) -> String? {
        let mic = missing.contains(.microphone), speech = missing.contains(.speechRecognition)
        switch (mic, speech) {
        case (true, true): return "Microphone and Speech Recognition access are missing"
        case (true, false): return "Microphone access is missing"
        case (false, true): return "Speech Recognition access is missing"
        case (false, false): return nil
        }
    }
}

// MARK: - Level meter

public enum VoiceMeter {
    /// Linear RMS of a buffer (0...1) to a 0...1 meter position: -50 dB is empty, 0 dB is full.
    public static func level(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 50))
    }
}

// MARK: - The reply to speak

public enum VoiceReply {
    /// The text of the last assistant row after the last user row: the answer to the turn that just ended.
    public static func finalText(in items: [ChatItem]) -> String? {
        var text: String?
        for item in items {
            switch item.kind {
            case .user: text = nil
            case .assistant(let t): text = t
            case .tool: break
            }
        }
        guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }
}

// MARK: - Spoken form

/// A short, speakable version of a reply: no Markdown, no code, links as one word, the first two sentences
/// and at most 300 characters. The full text stays in the card.
public enum SpokenForm {
    public static let maxSentences = 2
    public static let maxCharacters = 300

    private static let sentenceEnd: Set<Character> = [".", "!", "?", "\u{2026}"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", "\u{00BB}"]
    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "vs.", "mr.", "mrs.", "dr."]

    /// Nil when there is nothing to say.
    public static func make(_ markdown: String, language: String) -> String? {
        let lang = VoiceLanguages.info(code: language)
        let flat = flatten(markdown, lang)
        let sentences = split(flat)
        guard !sentences.isEmpty else { return nil }
        let joined = sentences.prefix(maxSentences).joined(separator: " ")
        let capped = cut(joined, to: maxCharacters)
        return capped.isEmpty ? nil : capped
    }

    // MARK: Markdown to plain sentences

    static func flatten(_ markdown: String, _ lang: VoiceLanguage) -> String {
        var out: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                if !inFence {
                    inFence = true
                    let marker = lang.codeOmitted + "."
                    if out.last != marker { out.append(marker) }
                } else {
                    inFence = false
                }
                continue
            }
            if inFence { continue }
            let line = cleanLine(t, lang)
            if !line.isEmpty { out.append(line) }
        }
        return out.joined(separator: " ")
    }

    private static func cleanLine(_ input: String, _ lang: VoiceLanguage) -> String {
        var s = input
        if s.isEmpty { return "" }
        // Rules and table separators carry no words.
        if s.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { return "" }
        if s.contains("-"), s.range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil { return "" }
        // Block markers: heading, quote, bullet, number.
        s = s.replacingOccurrences(of: #"^(#{1,6}\s+|>+\s*|[-*+\x{2022}]\s+|\d+[.)]\s+)+"#, with: "", options: .regularExpression)
        // Images and links keep their text; inline code is dropped; URLs become one word.
        s = s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://[^\s)>\]]+"#, with: lang.linkWord, options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>\s][^>]*>"#, with: "", options: .regularExpression)
        // Emphasis marks; underscores inside a word (snake_case) stay.
        s = s.replacingOccurrences(of: #"\*+|~~"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\p{L}\p{N}])_+|_+(?![\p{L}\p{N}])"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "|", with: ", ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" +([.,!?;:])"#, with: "$1", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
        guard !s.isEmpty else { return "" }
        // A list item or a heading reads as a sentence of its own.
        var tail = s
        while let c = tail.last, closers.contains(c) { tail.removeLast() }
        if let c = tail.last, !sentenceEnd.contains(c) { s += "." }
        return s
    }

    // MARK: Sentences

    static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var sentences: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            i += 1
            guard sentenceEnd.contains(c) else { continue }
            // Run of punctuation ("?!", "...").
            while i < chars.count, sentenceEnd.contains(chars[i]) { current.append(chars[i]); i += 1 }
            while i < chars.count, closers.contains(chars[i]) { current.append(chars[i]); i += 1 }
            let atEnd = i >= chars.count || chars[i].isWhitespace
            guard atEnd, !endsWithAbbreviation(current) else { continue }
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { sentences.append(t) }
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    private static func endsWithAbbreviation(_ s: String) -> Bool {
        guard let last = s.split(whereSeparator: \.isWhitespace).last else { return false }
        return abbreviations.contains(last.lowercased())
    }

    // MARK: Length

    /// At most `limit` characters, cut at a word boundary (a hard cut only when the first word is longer).
    static func cut(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit))
        let nextIsSpace = s[s.index(s.startIndex, offsetBy: limit)].isWhitespace
        var out = head
        if !nextIsSpace, let space = head.lastIndex(where: { $0.isWhitespace }), space > head.startIndex {
            out = String(head[..<space])
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-").union(.whitespacesAndNewlines))
    }
}
