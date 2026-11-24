import AgentHudCore
import AVFoundation
import Foundation
import Speech

/// Authorization of speech recognition, kept here so that the Speech framework is used in this file only.
enum AppleSpeechAccess {
    enum Status { case granted, notDetermined, denied }

    static func status() -> Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Shows the system prompt. Called only from a button click in the setup window.
    static func request() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }
}

enum VoiceError: LocalizedError {
    case recognizerUnavailable
    case noInput

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "the recognizer is not available"
        case .noInput: return "no microphone input"
        }
    }
}

/// Apple's recognizer fed from the microphone. This file is the only place that opens the microphone
/// (`AVAudioEngine` and its input tap) and the only place that creates a recognition request.
@MainActor
final class AppleSpeechRecognizer: SpeechRecognizing {
    private static let finalWait: Duration = .milliseconds(2500)

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var latest = ""
    private var ended = false
    private var waiter: CheckedContinuation<String, Never>?
    private var onPartial: (@MainActor (String) -> Void)?

    func support(language: String) -> SpeechSupport {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            return SpeechSupport(recognizerAvailable: false, onDevice: false)
        }
        return SpeechSupport(recognizerAvailable: r.isAvailable, onDevice: r.supportsOnDeviceRecognition)
    }

    func start(language: String, requireOnDevice: Bool,
               onPartial: @escaping @MainActor (String) -> Void,
               onLevel: @escaping @MainActor (Float) -> Void) throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw VoiceError.recognizerUnavailable
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = requireOnDevice
        req.taskHint = .dictation

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noInput }
        let sink: @Sendable (Float) -> Void = { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { onLevel(level) } }
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(request: req, level: sink))
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        generation += 1
        let gen = generation
        latest = ""
        ended = false
        self.onPartial = onPartial
        self.engine = engine
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(gen, text: text, done: done) } }
        }
    }

    func stop() async -> String {
        guard engine != nil || task != nil else { return latest }
        closeMicrophone()
        request?.endAudio()
        let gen = generation
        if !ended {
            _ = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                waiter = c
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.finalWait)
                    guard let self, self.generation == gen else { return }
                    self.resolve()
                }
            }
        }
        let text = latest
        reset()
        return text
    }

    func cancel() {
        closeMicrophone()
        task?.cancel()
        resolve()
        reset()
    }

    // MARK: - Internals

    /// Runs on the audio thread: it must not touch main-actor state.
    private nonisolated static func tap(request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            let samples = data[0]
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            level(VoiceMeter.level(rms: (sum / Float(n)).squareRoot()))
        }
    }

    private func received(_ gen: Int, text: String?, done: Bool) {
        guard gen == generation else { return }
        if let text {
            latest = text
            onPartial?(text)
        }
        if done {
            ended = true
            resolve()
        }
    }

    private func resolve() {
        guard let w = waiter else { return }
        waiter = nil
        w.resume(returning: latest)
    }

    private func closeMicrophone() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
    }

    private func reset() {
        generation += 1
        engine = nil
        request = nil
        task = nil
        onPartial = nil
        ended = false
    }
}
