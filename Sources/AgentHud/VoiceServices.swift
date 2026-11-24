import AgentHudCore
import Foundation

/// What a recognizer can do for one language on this Mac.
struct SpeechSupport: Equatable {
    var recognizerAvailable: Bool
    var onDevice: Bool
}

/// Turns speech into text. The Apple implementation is the only one today; a custom engine can take its place
/// by conforming to this protocol and being returned from `VoiceServices.make()`.
@MainActor
protocol SpeechRecognizing: AnyObject {
    /// Read-only: never opens the microphone and never asks for a permission.
    func support(language: String) -> SpeechSupport
    /// Opens the microphone and starts recognising. `onPartial` gets the text heard so far, `onLevel` a 0...1 meter value.
    /// `requireOnDevice` forbids sending audio off this Mac. Called only from the hold path of the voice controller.
    func start(language: String, requireOnDevice: Bool,
               onPartial: @escaping @MainActor (String) -> Void,
               onLevel: @escaping @MainActor (Float) -> Void) throws
    /// Closes the microphone and returns the final text (the last partial if the final one does not arrive in time).
    func stop() async -> String
    /// Closes the microphone and drops what was heard.
    func cancel()
}

/// How a text is read: the chosen voice (empty - the automatic pick for the language) and the speed multiplier.
struct SpeechOptions: Equatable {
    var voiceId = ""
    var rate = VoiceRate.defaultMultiplier
}

/// Reads a short text aloud.
@MainActor
protocol SpeechSpeaking: AnyObject {
    /// The voices installed on this Mac. Read-only: nothing is spoken.
    func voices() -> [VoiceInfo]
    func speak(text: String, language: String, options: SpeechOptions)
    /// Stops at once; harmless when nothing is spoken.
    func stop()
}

/// The two services the voice feature uses.
@MainActor
struct VoiceServices {
    let recognizer: SpeechRecognizing
    let speaker: SpeechSpeaking

    /// The one place where the engines are constructed. Neither constructor touches the microphone, the
    /// recognizer or the synthesizer: they are created when first used.
    static func make() -> VoiceServices {
        VoiceServices(recognizer: AppleSpeechRecognizer(), speaker: AppleSpeechSpeaker())
    }
}
