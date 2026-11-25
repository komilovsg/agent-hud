import AgentHudCore
import AppKit
import Combine

/// Push-to-talk for the command bar: one key, two gestures. A tap toggles the bar; a hold of 0.3 s or more
/// listens until the key is released.
///
/// Voice produces one thing: a user message for the bar's target, sent through the same path as a typed one.
/// Nothing here, and nothing reached from here, maps recognised words to an answer for a permission, question,
/// plan, look or act request. Those are answered only by clicks in their own views.
///
/// The microphone is opened in exactly one place, `beginListening`, which only the hold path reaches
/// (`holdTimerFired` -> `.holdReached` -> `.startListening`), and it is closed on release, on Esc, on the
/// 60 s cap and whenever the bar closes.
@MainActor
final class VoiceController {
    private let app: AppModel
    private let services: VoiceServices
    private let clock: () -> TimeInterval
    private weak var bar: CommandBarController?
    private var gesture = HoldGesture()
    private var state = VoiceState.idle
    /// Bumped for every utterance: a late result of an older one is dropped.
    private var utterance = 0
    private var holdTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(app: AppModel, services: VoiceServices, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.app = app
        self.services = services
        self.clock = clock
        // Switching voice off in the middle of an utterance ends it.
        app.settings.$voiceEnabled.dropFirst().sink { [weak self] on in
            if !on { self?.apply(.escape) }
        }.store(in: &cancellables)
        app.onVoiceReply = { [weak self] text in self?.speakReply(text) }
        app.installedVoices = { [weak self] in self?.services.speaker.voices() ?? [] }
        app.spokenGender = { [weak self] in self?.currentGender() }
        app.onPreviewVoice = { [weak self] language in self?.preview(language) }
    }

    func attach(_ bar: CommandBarController) { self.bar = bar }

    private var settings: Settings { app.settings }
    private var model: CommandBarModel? { bar?.model }

    // MARK: - Hotkey

    /// The hotkey went down. Any press stops what is being spoken.
    func keyDown() {
        services.speaker.stop()
        guard settings.voiceEnabled else {
            // Voice is off: the key is a plain toggle, as it always was.
            bar?.toggle()
            return
        }
        guard case .scheduleHold(let delay) = gesture.press(at: clock()) else { return }
        if case .missing = model?.voice { model?.voice = .none }
        apply(.pressed)
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.holdTimerFired()
        }
    }

    /// The hotkey went up.
    func keyUp() {
        holdTask?.cancel()
        switch gesture.release(at: clock()) {
        case .toggle:
            apply(.released)
            bar?.toggle()
        case .stopTalking:
            apply(.released)
        default:
            break
        }
    }

    private func holdTimerFired() {
        guard gesture.holdTimerFired(at: clock()) == .startTalking else { return }
        apply(.holdReached)
    }

    // MARK: - Bar events

    /// Esc, or the bar closing, while voice is active. True when voice took the key (the bar stays open).
    func escapePressed() -> Bool {
        services.speaker.stop()
        guard VoiceMachine.isBusy(state) else { return false }
        apply(.escape)
        return true
    }

    /// The bar went away: an utterance or a countdown in progress is dropped.
    func barHidden() {
        if VoiceMachine.isBusy(state) { apply(.escape) }
        model?.voice = .none
    }

    // MARK: - State machine

    private func apply(_ input: VoiceInput) {
        let step = VoiceMachine.reduce(state, input, sendAfterSpeaking: settings.voiceSendAfterSpeaking)
        state = step.state
        for effect in step.effects { perform(effect) }
        syncKeyMonitor()
    }

    private func perform(_ effect: VoiceEffect) {
        switch effect {
        case .stopSpeech:
            services.speaker.stop()
        case .startListening:
            beginListening()
        case .stopListening:
            endListening()
        case .cancelListening:
            dropListening()
        case .fillField(let text):
            guard let model else { return }
            model.voice = .none
            model.text = VoiceText.merged(draft: model.text, transcript: text)
        case .startCountdown:
            model?.voice = .countdown
            countdownTask?.cancel()
            countdownTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(VoiceMachine.countdown))
                guard !Task.isCancelled else { return }
                self?.apply(.countdownElapsed)
            }
        case .cancelCountdown:
            countdownTask?.cancel()
            countdownTask = nil
            model?.voice = .none
        case .send:
            countdownTask = nil
            model?.voice = .none
            bar?.submit(interrupt: false, byVoice: true)
        case .didntCatch:
            model?.voice = .none
            model?.status = CommandBarModel.Status(text: VoiceText.didntCatch)
        }
    }

    // MARK: - Listening

    /// Opens the microphone. Every failure leaves the bar with a line that says why, and nothing opened.
    private func beginListening() {
        guard let bar else { apply(.aborted); return }
        // Read-only checks: holding the key never reaches a system prompt.
        let statuses: [PermissionKind: PermissionStatus] = Dictionary(uniqueKeysWithValues:
            VoicePermissions.required.map { ($0, PermissionProbe.state($0).status) })
        let missing = VoicePermissions.missing(statuses)
        if !missing.isEmpty {
            bar.showForVoice()
            bar.model.voice = .missing(missing)
            apply(.aborted)
            return
        }
        let language = VoiceLanguages.info(code: settings.voiceLanguage)
        let support = services.recognizer.support(language: language.code)
        let decision = VoiceAvailability.decide(recognizerAvailable: support.recognizerAvailable, supportsOnDevice: support.onDevice,
                                                allowServer: settings.voiceAllowServerRecognition, languageLabel: language.label)
        if case .unavailable(let message) = decision {
            bar.showForVoice()
            bar.model.status = CommandBarModel.Status(text: message, isError: true)
            apply(.aborted)
            return
        }
        bar.showForVoice()
        bar.model.voice = .listening(level: 0, partial: "")
        utterance += 1
        let mine = utterance
        do {
            try services.recognizer.start(
                language: language.code, requireOnDevice: decision.requiresOnDevice,
                onPartial: { [weak self] text in self?.heard(text, utterance: mine) },
                onLevel: { [weak self] level in self?.measured(level, utterance: mine) })
        } catch {
            bar.model.voice = .none
            bar.model.status = CommandBarModel.Status(text: "Voice could not start: \(error.localizedDescription)", isError: true)
            apply(.aborted)
            return
        }
        capTask?.cancel()
        capTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(VoiceMachine.maxUtterance))
            guard !Task.isCancelled else { return }
            self?.apply(.capReached)
        }
    }

    /// Closes the microphone and waits for the final text.
    private func endListening() {
        capTask?.cancel()
        capTask = nil
        model?.voice = .finishing(partial: model?.voice.partial ?? "")
        let mine = utterance
        Task { @MainActor [weak self] in
            guard let self else { return }
            let text = await self.services.recognizer.stop()
            guard mine == self.utterance else { return }
            self.apply(.finalTranscript(text))
        }
    }

    private func dropListening() {
        capTask?.cancel()
        capTask = nil
        utterance += 1
        services.recognizer.cancel()
        model?.voice = .none
    }

    private func heard(_ text: String, utterance u: Int) {
        guard u == utterance, let model else { return }
        switch model.voice {
        case .listening(let level, _): model.voice = .listening(level: level, partial: text)
        case .finishing: model.voice = .finishing(partial: text)
        default: break
        }
    }

    private func measured(_ level: Float, utterance u: Int) {
        guard u == utterance, let model, case .listening(_, let partial) = model.voice else { return }
        model.voice = .listening(level: level, partial: partial)
    }

    // MARK: - Keys while voice is active

    /// While listening, finishing or counting down the bar watches the keyboard: held-key repeats must not
    /// reach the field, Esc cancels, Return sends at once, and any other key during the countdown is editing.
    private func syncKeyMonitor() {
        if VoiceMachine.isBusy(state) {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let code = event.keyCode
                return MainActor.assumeIsolated { self.handle(keyCode: code) } ? event : nil
            }
        } else if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// True when the key goes on to the field, false when it is swallowed.
    private func handle(keyCode: UInt16) -> Bool {
        let escape: UInt16 = 53, returnKey: UInt16 = 36, enter: UInt16 = 76
        switch state {
        case .listening, .finishing:
            if keyCode == escape { apply(.escape) }
            return false
        case .countdown:
            if keyCode == escape { apply(.escape); return false }
            if keyCode == returnKey || keyCode == enter { apply(.submit); return false }
            apply(.typed)
            return true
        default:
            return true
        }
    }

    // MARK: - Spoken reply

    /// A turn started by voice ended well: read a short form of its answer. Not while the person is talking.
    private func speakReply(_ text: String) {
        guard settings.voiceEnabled, settings.voiceSpeakReplies, state == .idle || state == .sent || state == .editing || state == .cancelled,
              !gesture.isDown else { return }
        let language = VoiceLanguages.info(code: settings.voiceLanguage)
        guard let spoken = SpokenForm.make(text, language: language.code) else { return }
        services.speaker.speak(text: spoken, language: language.speechLocale, options: speechOptions(for: language))
    }

    private func speechOptions(for language: VoiceLanguage) -> SpeechOptions {
        SpeechOptions(voiceId: settings.voiceId(forLanguage: language.code), engine: settings.voiceEngine,
                      neuralSpeaker: settings.neuralSpeaker(forLanguage: language.code), rate: settings.voiceRate)
    }

    /// The gender of the voice that will read the next reply, for the marker of a spoken message.
    private func currentGender() -> SpokenStyle.Gender? {
        let language = VoiceLanguages.info(code: settings.voiceLanguage)
        return services.speaker.gender(language: language.speechLocale, options: speechOptions(for: language))
    }

    /// The settings' Preview button: one fixed sentence with the voice and speed that are set now.
    private func preview(_ language: VoiceLanguage) {
        services.speaker.speak(text: language.previewSample, language: language.speechLocale, options: speechOptions(for: language))
    }
}
