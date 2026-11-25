import Foundation

// The optional local neural voice: the Supertonic-3 model run by the sherpa-onnx command-line tool, installed by
// scripts/get-neural-voice.sh. Pure: paths, the argument list and the speaker table. Spawning the tool and
// playing the result is the app target's job.

/// Which engine reads replies aloud. The stored setting value is the raw string.
public enum VoiceEngine: String, CaseIterable, Sendable {
    case system
    case neural

    public init(stored: String?) { self = VoiceEngine(rawValue: stored ?? "") ?? .system }

    public var label: String {
        switch self {
        case .system: return "System"
        case .neural: return "Neural (on this Mac)"
        }
    }
}

public enum NeuralVoice {
    /// One of the model's ten voice styles.
    public struct Speaker: Equatable, Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let gender: SpokenStyle.Gender
    }

    /// Speaker ids 0...4 are the styles F1...F5 and 5...9 are M1...M5: the model's voice file is built from the
    /// style files in sorted file-name order, and a pitch measurement of all ten confirms it (about 160-210 Hz
    /// for ids 0-4, about 90-130 Hz for ids 5-9).
    public static let speakers: [Speaker] =
        (0..<5).map { Speaker(id: $0, name: "Female \($0 + 1)", gender: .female) }
        + (0..<5).map { Speaker(id: 5 + $0, name: "Male \($0 + 1)", gender: .male) }

    public static let defaultSpeakerEnglish = 0
    public static let defaultSpeakerRussian = 3

    /// The model's `--lang` value for a locale such as "en-US" or "ru-RU"; nil for a language it is not used for.
    public static func modelLanguage(_ language: String) -> String? {
        let base = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map { $0.lowercased() } ?? ""
        return ["en", "ru"].contains(base) ? base : nil
    }

    public static func defaultSpeaker(language: String) -> Int {
        modelLanguage(language) == "ru" ? defaultSpeakerRussian : defaultSpeakerEnglish
    }

    /// A stored id that is not one of the ten becomes the language's default.
    public static func speaker(id: Int, language: String) -> Speaker {
        speakers.first { $0.id == id } ?? speakers[defaultSpeaker(language: language)]
    }

    public static let timeout: TimeInterval = 20

    public struct Paths: Equatable, Sendable {
        public let root: URL
        public init(supportDirectory: URL) {
            root = supportDirectory.appendingPathComponent("neural-voice", isDirectory: true)
        }

        public var binary: URL { root.appendingPathComponent("runtime/bin/sherpa-onnx-offline-tts") }
        public var library: URL { root.appendingPathComponent("runtime/lib/libonnxruntime.dylib") }
        public var model: URL { root.appendingPathComponent("model", isDirectory: true) }
        var durationPredictor: URL { model.appendingPathComponent("duration_predictor.int8.onnx") }
        var textEncoder: URL { model.appendingPathComponent("text_encoder.int8.onnx") }
        var vectorEstimator: URL { model.appendingPathComponent("vector_estimator.int8.onnx") }
        var vocoder: URL { model.appendingPathComponent("vocoder.int8.onnx") }
        var ttsJSON: URL { model.appendingPathComponent("tts.json") }
        var unicodeIndexer: URL { model.appendingPathComponent("unicode_indexer.bin") }
        var voiceStyle: URL { model.appendingPathComponent("voice.bin") }

        /// Every file the tool needs.
        public var requiredFiles: [URL] {
            [binary, library, durationPredictor, textEncoder, vectorEstimator, vocoder, ttsJSON, unicodeIndexer, voiceStyle]
        }

        /// True when every required file exists.
        public func isInstalled(fileExists: (String) -> Bool) -> Bool {
            requiredFiles.allSatisfy { fileExists($0.path) }
        }
    }

    /// The text as spoken: control characters out (line breaks and tabs become spaces), cut to the same length as
    /// the spoken form. Nil when nothing is left.
    public static func cleanedText(_ text: String) -> String? {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control {
                out.append(scalar == "\n" || scalar == "\r" || scalar == "\t" ? " " : "")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        let flat = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let capped = SpokenForm.cut(flat.trimmingCharacters(in: .whitespaces), to: SpokenForm.maxCharacters)
        return capped.isEmpty ? nil : capped
    }

    /// The tool's argument list (never a shell command line). The text comes last, after `--`, which the tool's
    /// option parser treats as the end of options: a text such as "--help" is spoken, not parsed.
    /// Nil for a language the model is not used for, or when no text is left.
    public static func arguments(text: String, language: String, speaker: Int, speed: Double, output: URL, paths: Paths) -> [String]? {
        guard let lang = modelLanguage(language), let spoken = cleanedText(text) else { return nil }
        let id = speakers.contains { $0.id == speaker } ? speaker : defaultSpeaker(language: language)
        return [
            "--supertonic-duration-predictor=\(paths.durationPredictor.path)",
            "--supertonic-text-encoder=\(paths.textEncoder.path)",
            "--supertonic-vector-estimator=\(paths.vectorEstimator.path)",
            "--supertonic-vocoder=\(paths.vocoder.path)",
            "--supertonic-tts-json=\(paths.ttsJSON.path)",
            "--supertonic-unicode-indexer=\(paths.unicodeIndexer.path)",
            "--supertonic-voice-style=\(paths.voiceStyle.path)",
            "--lang=\(lang)",
            "--sid=\(id)",
            "--speed=\(String(format: "%.2f", VoiceRate.clamped(speed)))",
            "--output-filename=\(output.path)",
            "--",
            spoken,
        ]
    }
}
