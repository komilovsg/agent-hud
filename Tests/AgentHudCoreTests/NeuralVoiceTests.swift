import Foundation
import Testing
@testable import AgentHudCore

@Suite struct NeuralVoiceTests {
    static let paths = NeuralVoice.Paths(supportDirectory: URL(fileURLWithPath: "/tmp/support dir"))
    static let out = URL(fileURLWithPath: "/tmp/support dir/speech-tmp/a.wav")

    @Test func pathsSitUnderTheSupportDirectory() {
        let p = Self.paths
        #expect(p.root.path == "/tmp/support dir/neural-voice")
        #expect(p.binary.path == "/tmp/support dir/neural-voice/runtime/bin/sherpa-onnx-offline-tts")
        #expect(p.requiredFiles.count == 9)
    }

    @Test func installedNeedsEveryFile() {
        let all = Set(Self.paths.requiredFiles.map(\.path))
        #expect(Self.paths.isInstalled(fileExists: { all.contains($0) }))
        #expect(!Self.paths.isInstalled(fileExists: { _ in false }))
        for missing in all {
            #expect(!Self.paths.isInstalled(fileExists: { $0 != missing && all.contains($0) }), "\(missing)")
        }
    }

    @Test func speakerTableHasTenStylesWithGender() {
        #expect(NeuralVoice.speakers.map(\.id) == Array(0..<10))
        #expect(NeuralVoice.speakers[0].name == "Female 1" && NeuralVoice.speakers[0].gender == .female)
        #expect(NeuralVoice.speakers[4].name == "Female 5")
        #expect(NeuralVoice.speakers[5].name == "Male 1" && NeuralVoice.speakers[5].gender == .male)
        #expect(NeuralVoice.speakers[9].name == "Male 5")
        #expect(NeuralVoice.defaultSpeaker(language: "en-US") == 0)
        #expect(NeuralVoice.defaultSpeaker(language: "ru-RU") == 3)
        #expect(NeuralVoice.speaker(id: 42, language: "ru-RU").id == 3)
        #expect(NeuralVoice.speaker(id: -1, language: "en-US").id == 0)
    }

    @Test func languageMapping() {
        #expect(NeuralVoice.modelLanguage("en-US") == "en")
        #expect(NeuralVoice.modelLanguage("ru_RU") == "ru")
        #expect(NeuralVoice.modelLanguage("fr-FR") == nil)
        #expect(NeuralVoice.modelLanguage("") == nil)
        #expect(NeuralVoice.arguments(text: "bonjour", language: "fr-FR", speaker: 0, speed: 1, output: Self.out, paths: Self.paths) == nil)
    }

    @Test func textIsLastAfterTheEndOfOptions() {
        for text in ["hello there", "--help", "-h me", "--sid=9 and more", "--output-filename=/etc/x"] {
            let args = NeuralVoice.arguments(text: text, language: "en-US", speaker: 0, speed: 1, output: Self.out, paths: Self.paths)!
            #expect(args.last == text)
            #expect(args[args.count - 2] == "--")
            // Nothing after the "--" can be taken for an option, and before it only fixed option=value pairs.
            #expect(args.dropLast(2).allSatisfy { $0.hasPrefix("--") && $0.contains("=") })
            #expect(args.filter { $0 == "--" }.count == 1)
        }
    }

    @Test func argumentsCarryLanguageSpeakerSpeedAndOutput() {
        let args = NeuralVoice.arguments(text: "hi", language: "ru-RU", speaker: 3, speed: 1.3, output: Self.out, paths: Self.paths)!
        #expect(args.contains("--lang=ru") && args.contains("--sid=3") && args.contains("--speed=1.30"))
        #expect(args.contains("--output-filename=/tmp/support dir/speech-tmp/a.wav"))
        let slow = NeuralVoice.arguments(text: "hi", language: "en-US", speaker: 0, speed: 0.1, output: Self.out, paths: Self.paths)!
        #expect(slow.contains("--speed=0.80"))
        let nan = NeuralVoice.arguments(text: "hi", language: "en-US", speaker: 0, speed: .nan, output: Self.out, paths: Self.paths)!
        #expect(nan.contains("--speed=1.00"))
        let bad = NeuralVoice.arguments(text: "hi", language: "en-US", speaker: 77, speed: 1, output: Self.out, paths: Self.paths)!
        #expect(bad.contains("--sid=0"))
    }

    @Test func textIsCleanedAndCapped() {
        #expect(NeuralVoice.cleanedText("a\u{0}b\u{7}c\nd\te") == "abc d e")
        #expect(NeuralVoice.cleanedText("  \n\u{1B}[0m ") == "[0m")
        #expect(NeuralVoice.cleanedText("\u{0}\u{1}  ") == nil)
        #expect(NeuralVoice.cleanedText("") == nil)
        let long = String(repeating: "word ", count: 200)
        #expect(NeuralVoice.cleanedText(long)!.count <= SpokenForm.maxCharacters)
        // Russian text survives (escapes: "privet mir").
        let ru = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"
        #expect(NeuralVoice.cleanedText(ru) == ru)
        #expect(NeuralVoice.arguments(text: "\u{0}", language: "en-US", speaker: 0, speed: 1, output: Self.out, paths: Self.paths) == nil)
    }

    @Test func engineSettingFallsBackToSystem() {
        #expect(VoiceEngine(stored: nil) == .system)
        #expect(VoiceEngine(stored: "garbage") == .system)
        #expect(VoiceEngine(stored: "neural") == .neural)
    }
}
