import AgentHudCore
import AVFoundation
import Foundation

/// Reads replies aloud. This file is the only place that creates the synthesizer, and it does so on first use.
@MainActor
final class AppleSpeechSpeaker: SpeechSpeaking {
    private var synthesizer: AVSpeechSynthesizer?

    /// Listing voices does not create the synthesizer and does not make a sound.
    func voices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map(Self.info)
    }

    /// Quality comes from the voice itself. Novelty voices carry a trait; the older synthesizers' voices (Fred, Junior...)
    /// carry none, so they are told apart by their identifier. Personal Voice is never used automatically either.
    static func info(_ v: AVSpeechSynthesisVoice) -> VoiceInfo {
        let quality: VoiceQuality
        switch v.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        let novelty = v.voiceTraits.contains(.isNoveltyVoice) || v.voiceTraits.contains(.isPersonalVoice)
            || VoiceChoice.isLegacyIdentifier(v.identifier)
        return VoiceInfo(id: v.identifier, name: v.name, language: v.language, quality: quality, isNovelty: novelty)
    }

    func speak(text: String, language: String, options: SpeechOptions) {
        let s = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = s
        s.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice(language: language, preferredId: options.voiceId)
        utterance.rate = VoiceRate.utteranceRate(multiplier: options.rate, platformDefault: AVSpeechUtteranceDefaultSpeechRate,
                                                 platformMin: AVSpeechUtteranceMinimumSpeechRate,
                                                 platformMax: AVSpeechUtteranceMaximumSpeechRate)
        s.speak(utterance)
    }

    /// The chosen voice; when it cannot be created any more, the automatic pick; when there is none, the system default.
    private func resolveVoice(language: String, preferredId: String) -> AVSpeechSynthesisVoice? {
        let installed = voices()
        if let chosen = VoiceChoice.pick(from: installed, language: language, preferredId: preferredId),
           let voice = AVSpeechSynthesisVoice(identifier: chosen.id) {
            return voice
        }
        if !preferredId.isEmpty, let auto = VoiceChoice.pick(from: installed, language: language, preferredId: nil),
           let voice = AVSpeechSynthesisVoice(identifier: auto.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
    }
}
