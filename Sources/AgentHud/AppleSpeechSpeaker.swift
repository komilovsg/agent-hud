import AVFoundation
import Foundation

/// Reads replies aloud. This file is the only place that creates the synthesizer, and it does so on first use.
@MainActor
final class AppleSpeechSpeaker: SpeechSpeaking {
    private var synthesizer: AVSpeechSynthesizer?

    func speak(text: String, language: String) {
        let s = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = s
        s.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        s.speak(utterance)
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
    }
}
