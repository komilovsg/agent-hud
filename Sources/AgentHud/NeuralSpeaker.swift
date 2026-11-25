import AgentHudCore
import AVFoundation
import Foundation

/// Reads a text with the local neural voice: runs the installed command-line tool on the text, then plays the WAV
/// it wrote. Nothing runs until `speak` is called. Any failure hands that one utterance to the fallback speaker,
/// so a reply is never lost silently.
@MainActor
final class NeuralSpeaker {
    private let fallback: SpeechSpeaking
    private let paths: NeuralVoice.Paths
    private let tempDirectory: URL
    private var process: Process?
    private var player: AVAudioPlayer?
    private var timeoutTask: Task<Void, Never>?
    /// Bumped by every `speak` and `stop`: the result of an older run is dropped.
    private var generation = 0

    init(fallback: SpeechSpeaking, supportDirectory: URL = AgentHUDPaths.supportDirectory) {
        self.fallback = fallback
        paths = NeuralVoice.Paths(supportDirectory: supportDirectory)
        tempDirectory = supportDirectory.appendingPathComponent("speech-tmp", isDirectory: true)
    }

    var isInstalled: Bool { paths.isInstalled(fileExists: { FileManager.default.fileExists(atPath: $0) }) }

    func speak(text: String, language: String, options: SpeechOptions) {
        stop()
        let mine = generation
        let useFallback = { [fallback] in fallback.speak(text: text, language: language, options: options) }
        guard isInstalled, let output = makeOutputFile(),
              let args = NeuralVoice.arguments(text: text, language: language, speaker: options.neuralSpeaker,
                                               speed: options.rate, output: output, paths: paths) else {
            useFallback()
            return
        }
        let p = Process()
        p.executableURL = paths.binary
        p.arguments = args
        // The tool finds its libraries next to itself (its own rpath); no environment is needed.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] done in
            let status = done.terminationStatus
            Task { @MainActor in self?.finished(generation: mine, status: status, output: output, fallback: useFallback) }
        }
        do {
            try p.run()
        } catch {
            try? FileManager.default.removeItem(at: output)
            useFallback()
            return
        }
        process = p
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NeuralVoice.timeout))
            guard !Task.isCancelled, let self, self.generation == mine, self.process === p else { return }
            // Terminating makes the termination handler run, which then takes the fallback path.
            p.terminate()
        }
    }

    func stop() {
        generation += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        player?.stop()
        player = nil
        sweepTemp()
    }

    private func finished(generation g: Int, status: Int32, output: URL, fallback useFallback: () -> Void) {
        // The WAV is read into memory and the file removed at once: nothing is left on disk.
        let data = try? Data(contentsOf: output)
        try? FileManager.default.removeItem(at: output)
        guard g == generation else { return }
        timeoutTask?.cancel()
        process = nil
        guard status == 0, let data, !data.isEmpty, let p = try? AVAudioPlayer(data: data), p.duration > 0.05, p.play() else {
            useFallback()
            return
        }
        player = p
    }

    /// A private file name inside a folder only this user can read.
    private func makeOutputFile() -> URL? {
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        return tempDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    }

    /// Leftovers of a run that was killed with the app. Only runs while no tool is running.
    private func sweepTemp() {
        guard process == nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path) else { return }
        for n in names where n.hasSuffix(".wav") { try? FileManager.default.removeItem(at: tempDirectory.appendingPathComponent(n)) }
    }
}

/// Picks the engine for each utterance. The other engine is stopped first, so two voices never overlap.
@MainActor
final class EngineSpeaker: SpeechSpeaking {
    private let system: SpeechSpeaking
    private let neural: NeuralSpeaker

    init(system: SpeechSpeaking, neural: NeuralSpeaker) {
        self.system = system
        self.neural = neural
    }

    func voices() -> [VoiceInfo] { system.voices() }

    func speak(text: String, language: String, options: SpeechOptions) {
        if options.engine == .neural {
            system.stop()
            neural.speak(text: text, language: language, options: options)
        } else {
            neural.stop()
            system.speak(text: text, language: language, options: options)
        }
    }

    func gender(language: String, options: SpeechOptions) -> SpokenStyle.Gender? {
        if options.engine == .neural, neural.isInstalled, NeuralVoice.modelLanguage(language) != nil {
            return NeuralVoice.speaker(id: options.neuralSpeaker, language: language).gender
        }
        return system.gender(language: language, options: options)
    }

    func stop() {
        neural.stop()
        system.stop()
    }
}
