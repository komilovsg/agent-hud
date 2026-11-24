import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Push-to-talk voice: gesture, state machine, spoken form, availability, permissions

@Suite struct VoiceLogicTests {
    // MARK: Tap or hold

    @Test func quickReleaseIsATap() {
        var g = HoldGesture()
        #expect(g.press(at: 10) == .scheduleHold(after: 0.3))
        #expect(g.release(at: 10.1) == .toggle)
        #expect(!g.isDown && !g.talking)
    }

    @Test func holdStartsTalkingAtTheThresholdAndStopsOnRelease() {
        var g = HoldGesture()
        _ = g.press(at: 10)
        #expect(g.holdTimerFired(at: 10.3) == .startTalking)
        #expect(g.talking)
        #expect(g.release(at: 14) == .stopTalking)
        #expect(!g.isDown && !g.talking)
    }

    @Test func timerBeforeTheThresholdDoesNothing() {
        var g = HoldGesture()
        _ = g.press(at: 5)
        #expect(g.holdTimerFired(at: 5.29) == .none)
        #expect(!g.talking)
        #expect(g.holdTimerFired(at: 5.3) == .startTalking)
        // A second timer after talking began is ignored.
        #expect(g.holdTimerFired(at: 5.5) == .none)
    }

    @Test func repeatedPressesAreIgnored() {
        var g = HoldGesture()
        #expect(g.press(at: 1) == .scheduleHold(after: 0.3))
        #expect(g.press(at: 1.05) == .none)
        #expect(g.press(at: 1.1) == .none)
        // The original press time still counts.
        #expect(g.holdTimerFired(at: 1.3) == .startTalking)
    }

    @Test func releaseWithoutPressIsIgnored() {
        var g = HoldGesture()
        #expect(g.release(at: 3) == .none)
        _ = g.press(at: 4)
        _ = g.release(at: 4.1)
        #expect(g.release(at: 4.2) == .none)
        // A timer after the release does nothing.
        #expect(g.holdTimerFired(at: 4.3) == .none)
    }

    @Test func lateReleaseWithoutTimerIsATapAndNeverOpensTheMicrophone() {
        var g = HoldGesture()
        _ = g.press(at: 0)
        #expect(g.release(at: 2) == .toggle)
    }

    @Test func resetForgetsAHalfSeenGesture() {
        var g = HoldGesture()
        _ = g.press(at: 0)
        g.reset()
        #expect(!g.isDown)
        #expect(g.release(at: 1) == .none)
    }

    // MARK: State machine

    func run(_ from: VoiceState, _ input: VoiceInput, send: Bool = true) -> VoiceMachine.Step {
        VoiceMachine.reduce(from, input, sendAfterSpeaking: send)
    }

    @Test func pressFromAnyRestingStateArmsAndStopsSpeech() {
        for s in [VoiceState.idle, .sent, .cancelled, .editing] {
            let step = run(s, .pressed)
            #expect(step.state == .armed && step.effects == [.stopSpeech], "from \(s)")
        }
    }

    @Test func restingStatesIgnoreEverythingElse() {
        let others: [VoiceInput] = [.holdReached, .released, .aborted, .capReached, .finalTranscript("hello"), .countdownElapsed,
                                    .escape, .typed, .submit]
        for s in [VoiceState.idle, .sent, .cancelled, .editing] {
            for i in others {
                let step = run(s, i)
                #expect(step.state == s && step.effects.isEmpty, "\(s) + \(i)")
            }
        }
    }

    @Test func armedStateTable() {
        #expect(run(.armed, .holdReached) == VoiceMachine.Step(state: .listening, effects: [.startListening]))
        #expect(run(.armed, .released) == VoiceMachine.Step(state: .idle, effects: []))
        #expect(run(.armed, .aborted) == VoiceMachine.Step(state: .idle, effects: []))
        for i in [VoiceInput.pressed, .capReached, .finalTranscript("x"), .countdownElapsed, .escape, .typed, .submit] {
            #expect(run(.armed, i) == VoiceMachine.Step(state: .armed, effects: []), "armed + \(i)")
        }
    }

    @Test func listeningStateTable() {
        #expect(run(.listening, .released) == VoiceMachine.Step(state: .finishing, effects: [.stopListening]))
        #expect(run(.listening, .capReached) == VoiceMachine.Step(state: .finishing, effects: [.stopListening]))
        #expect(run(.listening, .escape) == VoiceMachine.Step(state: .cancelled, effects: [.cancelListening]))
        #expect(run(.listening, .aborted) == VoiceMachine.Step(state: .idle, effects: []))
        for i in [VoiceInput.pressed, .holdReached, .finalTranscript("x"), .countdownElapsed, .typed, .submit] {
            #expect(run(.listening, i) == VoiceMachine.Step(state: .listening, effects: []), "listening + \(i)")
        }
    }

    @Test func finishingWithTextCountsDownWhenSendingAfterSpeaking() {
        let step = run(.finishing, .finalTranscript("  open the report \n"), send: true)
        #expect(step == VoiceMachine.Step(state: .countdown, effects: [.fillField("open the report"), .startCountdown]))
    }

    @Test func finishingWithTextStopsAtTheFieldWhenSendingIsOff() {
        let step = run(.finishing, .finalTranscript("open the report"), send: false)
        #expect(step == VoiceMachine.Step(state: .editing, effects: [.fillField("open the report")]))
    }

    @Test func emptyOrBlankResultSendsNothing() {
        for text in ["", " ", "\n\t  "] {
            for send in [true, false] {
                let step = run(.finishing, .finalTranscript(text), send: send)
                #expect(step == VoiceMachine.Step(state: .idle, effects: [.didntCatch]), "\(text.debugDescription) \(send)")
            }
        }
    }

    @Test func finishingOtherInputs() {
        #expect(run(.finishing, .aborted) == VoiceMachine.Step(state: .idle, effects: []))
        #expect(run(.finishing, .escape) == VoiceMachine.Step(state: .cancelled, effects: [.cancelListening]))
        // A new utterance replaces the one being finished.
        #expect(run(.finishing, .pressed) == VoiceMachine.Step(state: .armed, effects: [.cancelListening, .stopSpeech]))
        for i in [VoiceInput.holdReached, .released, .capReached, .countdownElapsed, .typed, .submit] {
            #expect(run(.finishing, i) == VoiceMachine.Step(state: .finishing, effects: []), "finishing + \(i)")
        }
    }

    @Test func countdownStateTable() {
        #expect(run(.countdown, .countdownElapsed) == VoiceMachine.Step(state: .sent, effects: [.send]))
        #expect(run(.countdown, .submit) == VoiceMachine.Step(state: .sent, effects: [.cancelCountdown, .send]))
        #expect(run(.countdown, .escape) == VoiceMachine.Step(state: .cancelled, effects: [.cancelCountdown]))
        #expect(run(.countdown, .typed) == VoiceMachine.Step(state: .editing, effects: [.cancelCountdown]))
        #expect(run(.countdown, .pressed) == VoiceMachine.Step(state: .armed, effects: [.cancelCountdown, .stopSpeech]))
        for i in [VoiceInput.holdReached, .released, .aborted, .capReached, .finalTranscript("x")] {
            #expect(run(.countdown, i) == VoiceMachine.Step(state: .countdown, effects: []), "countdown + \(i)")
        }
    }

    @Test func fullUtteranceWalkThrough() {
        var s = VoiceState.idle
        var effects: [VoiceEffect] = []
        func feed(_ i: VoiceInput, send: Bool = true) {
            let step = VoiceMachine.reduce(s, i, sendAfterSpeaking: send)
            s = step.state
            effects += step.effects
        }
        feed(.pressed); feed(.holdReached); feed(.released); feed(.finalTranscript("hello there")); feed(.countdownElapsed)
        #expect(s == .sent)
        #expect(effects == [.stopSpeech, .startListening, .stopListening, .fillField("hello there"), .startCountdown, .send])
        // The cap ends the utterance exactly like a release.
        s = .idle; effects = []
        feed(.pressed); feed(.holdReached); feed(.capReached); feed(.released)
        #expect(s == .finishing && effects == [.stopSpeech, .startListening, .stopListening])
    }

    @Test func constantsAndBusyStates() {
        #expect(VoiceMachine.maxUtterance == 60 && VoiceMachine.countdown == 1.5 && HoldGesture.holdThreshold == 0.3)
        #expect(VoiceMachine.isBusy(.listening) && VoiceMachine.isBusy(.finishing) && VoiceMachine.isBusy(.countdown))
        for s in [VoiceState.idle, .armed, .sent, .cancelled, .editing] { #expect(!VoiceMachine.isBusy(s)) }
    }

    @Test func noInputCarriesAnApproval() {
        // Voice has no way to answer a request: every effect is about listening, the field, the countdown,
        // sending a user message or speech.
        let allStates: [VoiceState] = [.idle, .armed, .listening, .finishing, .countdown, .sent, .cancelled, .editing]
        let inputs: [VoiceInput] = [.pressed, .holdReached, .released, .aborted, .capReached, .finalTranscript("allow"),
                                    .finalTranscript("yes approve it"), .countdownElapsed, .escape, .typed, .submit]
        let known: Set<String> = ["stopSpeech", "startListening", "stopListening", "cancelListening", "fillField", "startCountdown",
                                  "cancelCountdown", "send", "didntCatch"]
        for s in allStates {
            for i in inputs {
                for e in VoiceMachine.reduce(s, i, sendAfterSpeaking: true).effects {
                    #expect(known.contains(String(describing: e).split(separator: "(").first.map(String.init) ?? ""))
                }
            }
        }
    }

    // MARK: Texts

    @Test func mergedPutsTheTranscriptIntoTheField() {
        #expect(VoiceText.merged(draft: "", transcript: " open mail ") == "open mail")
        #expect(VoiceText.merged(draft: "  ", transcript: "open mail") == "open mail")
        #expect(VoiceText.merged(draft: "first ", transcript: "second") == "first second")
        #expect(VoiceText.merged(draft: "keep", transcript: " ") == "keep")
        #expect(VoiceText.countdownLine == "Sending\u{2026} Esc to cancel, any key to edit")
        #expect(VoiceText.didntCatch == "Didn't catch that")
    }

    // MARK: Languages

    @Test func languageTable() {
        #expect(VoiceLanguages.all.map(\.code) == ["en-US", "ru-RU"])
        #expect(VoiceLanguages.all.map(\.label) == ["English (US)", "Russian"])
        #expect(VoiceLanguages.all.map(\.speechLocale) == ["en-US", "ru-RU"])
        #expect(VoiceLanguages.defaultCode == "en-US")
        #expect(VoiceLanguages.info(code: "ru-RU").label == "Russian")
        // Unknown and missing values fall back to English.
        #expect(VoiceLanguages.info(code: "de-DE").code == "en-US")
        #expect(VoiceLanguages.info(code: nil).code == "en-US")
        #expect(VoiceLanguages.info(code: "en-US").codeOmitted == "code omitted" && VoiceLanguages.info(code: "en-US").linkWord == "link")
        #expect(!VoiceLanguages.info(code: "ru-RU").codeOmitted.isEmpty && !VoiceLanguages.info(code: "ru-RU").linkWord.isEmpty)
    }

    // MARK: Availability

    @Test func mayRecogniseTable() {
        typealias A = VoiceAvailability
        let ru = "Russian"
        // (recognizer available, on-device, server allowed) -> decision
        #expect(A.decide(recognizerAvailable: true, supportsOnDevice: true, allowServer: false, languageLabel: ru) == .onDevice)
        // On-device is preferred even when the servers are allowed.
        #expect(A.decide(recognizerAvailable: true, supportsOnDevice: true, allowServer: true, languageLabel: ru) == .onDevice)
        #expect(A.decide(recognizerAvailable: true, supportsOnDevice: false, allowServer: true, languageLabel: ru) == .server)
        let no = A.decide(recognizerAvailable: true, supportsOnDevice: false, allowServer: false, languageLabel: ru)
        guard case .unavailable(let message) = no else { Issue.record("expected unavailable"); return }
        #expect(message.hasPrefix("On-device recognition is not available for Russian"))
        #expect(message.contains("Allow recognition through Apple's servers"))
        let gone = A.decide(recognizerAvailable: false, supportsOnDevice: true, allowServer: true, languageLabel: "English (US)")
        #expect(gone == .unavailable("Speech recognition is not available for English (US) right now"))
        #expect(A.onDevice.requiresOnDevice && !A.server.requiresOnDevice && !no.requiresOnDevice)
    }

    // MARK: Permissions

    @Test func voicePermissionHelpers() {
        #expect(VoicePermissions.inUse(voiceEnabled: true) == [.microphone, .speechRecognition])
        #expect(VoicePermissions.inUse(voiceEnabled: false).isEmpty)
        let granted: [PermissionKind: PermissionStatus] = [.microphone: .granted, .speechRecognition: .granted]
        #expect(VoicePermissions.missing(granted).isEmpty && VoicePermissions.message(missing: []) == nil)
        #expect(VoicePermissions.missing([.microphone: .notGranted, .speechRecognition: .granted]) == [.microphone])
        #expect(VoicePermissions.missing([.microphone: .granted, .speechRecognition: .notGranted]) == [.speechRecognition])
        // Unknown or absent is not enough to listen.
        #expect(VoicePermissions.missing([:]) == [.microphone, .speechRecognition])
        #expect(VoicePermissions.missing([.microphone: .unknown, .speechRecognition: .granted]) == [.microphone])
        #expect(VoicePermissions.message(missing: [.microphone]) == "Microphone access is missing")
        #expect(VoicePermissions.message(missing: [.speechRecognition]) == "Speech Recognition access is missing")
        #expect(VoicePermissions.message(missing: [.microphone, .speechRecognition]) == "Microphone and Speech Recognition access are missing")
    }

    // MARK: Meter

    @Test func meterScalesDecibels() {
        #expect(VoiceMeter.level(rms: 0) == 0)
        #expect(VoiceMeter.level(rms: -1) == 0)
        #expect(VoiceMeter.level(rms: .nan) == 0)
        #expect(VoiceMeter.level(rms: 1) == 1)
        #expect(VoiceMeter.level(rms: 4) == 1)
        #expect(VoiceMeter.level(rms: 0.001) == 0)        // -60 dB is below the floor
        #expect(abs(VoiceMeter.level(rms: 0.01) - 0.2) < 0.001)   // -40 dB
        #expect(abs(VoiceMeter.level(rms: 0.1) - 0.6) < 0.001)    // -20 dB
        #expect(VoiceMeter.level(rms: 0.00001) == 0)
    }

    // MARK: The reply to speak

    func item(_ id: String, _ kind: ChatItem.Kind) -> ChatItem { ChatItem(id: id, time: nil, kind: kind) }

    @Test func finalTextIsTheLastAssistantRowOfTheTurn() {
        let items = [
            item("1", .user("first")), item("2", .assistant("old answer")),
            item("3", .user("second")), item("4", .assistant("Checking.")),
            item("5", .tool(name: "Bash", summary: "ls", status: .ok)), item("6", .assistant("Done. Two files.")),
        ]
        #expect(VoiceReply.finalText(in: items) == "Done. Two files.")
        // A turn that produced no text yet has no reply, whatever came before.
        #expect(VoiceReply.finalText(in: items + [item("7", .user("third"))]) == nil)
        #expect(VoiceReply.finalText(in: items + [item("7", .user("third")), item("8", .tool(name: "Bash", summary: "x", status: .ok))]) == nil)
        #expect(VoiceReply.finalText(in: []) == nil)
        #expect(VoiceReply.finalText(in: [item("1", .assistant("  \n"))]) == nil)
    }

    // MARK: Spoken form

    func say(_ s: String, _ lang: String = "en-US") -> String? { SpokenForm.make(s, language: lang) }

    @Test func spokenFormTable() {
        let table: [(String, String?)] = [
            // Plain text, at most two sentences.
            ("Done. I created the file. Then I ran the tests.", "Done. I created the file."),
            ("Done.", "Done."),
            ("Is it ready? Yes! It is.", "Is it ready? Yes!"),
            ("Wait... it finished. Good.", "Wait... it finished."),
            ("Version 3.5 is out. Please update.", "Version 3.5 is out. Please update."),
            ("Use e.g. a list. Or a table. Or both.", "Use e.g. a list. Or a table."),
            ("He said \"stop.\" Then he left. Later.", "He said \"stop.\" Then he left."),
            ("No final punctuation", "No final punctuation."),
            // Markdown.
            ("# Title\n\nSome **bold** and *italic* text.", "Title. Some bold and italic text."),
            ("> quoted words here\nand more", "quoted words here. and more."),
            ("- one\n- two\n- three", "one. two."),
            ("1. first step\n2) second step\n3. third", "first step. second step."),
            ("Items:\n- apples\n- pears", "Items. apples."),
            ("See [the docs](https://example.com/a?b=c) now.", "See the docs now."),
            ("![diagram](img.png) is attached.", "diagram is attached."),
            ("Use __this__ and ~~that~~ here.", "Use this and that here."),
            ("keep snake_case names", "keep snake_case names."),
            ("a | b | c\n--- | --- | ---\n1 | 2 | 3", "a, b, c. 1, 2, 3."),
            ("Text\n\n---\n\nMore text", "Text. More text."),
            // Code and links.
            ("Run `npm test` now.", "Run now."),
            ("Here:\n```swift\nlet x = 1\nprint(x)\n```\nThat is it.", "Here. code omitted."),
            ("```\nlet x = 1\n```\nThat is it.", "code omitted. That is it."),
            ("```\ncode only\n```", "code omitted."),
            ("```\na\n```\n```\nb\n```\nDone.", "code omitted. Done."),
            ("Open https://example.com/path?x=1 for details.", "Open link for details."),
            ("Visit (https://example.com/x) or http://a.b/c today.", "Visit (link) or link today."),
            // Empty.
            ("", nil), ("   \n\t", nil), ("`only code`", nil), ("---", nil), ("**", nil), ("![](x.png)", nil),
        ]
        for (input, expected) in table {
            #expect(say(input) == expected, "input: \(input.debugDescription)")
        }
    }

    @Test func russianPunctuationAndWords() {
        // Russian sentences, written with escapes: "Privet. Eto test! Kak dela? Eshche odno predlozhenie."
        let text = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}. \u{042D}\u{0442}\u{043E} \u{0442}\u{0435}\u{0441}\u{0442}! "
            + "\u{041A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}? \u{0415}\u{0449}\u{0435} \u{043E}\u{0434}\u{043D}\u{043E}."
        let first2 = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}. \u{042D}\u{0442}\u{043E} \u{0442}\u{0435}\u{0441}\u{0442}!"
        #expect(say(text, "ru-RU") == first2)
        // "Kak dela? Horosho\u{2026} Vse." - question mark and an ellipsis split sentences.
        let q = "\u{041A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}? \u{0425}\u{043E}\u{0440}\u{043E}\u{0448}\u{043E}\u{2026} \u{0412}\u{0441}\u{0435}."
        #expect(say(q, "ru-RU") == "\u{041A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}? \u{0425}\u{043E}\u{0440}\u{043E}\u{0448}\u{043E}\u{2026}")
        // Words that replace code and links come from the language table.
        let ru = VoiceLanguages.info(code: "ru-RU")
        #expect(say("```\nx\n```", "ru-RU") == ru.codeOmitted + ".")
        #expect(say("See https://example.com now.", "ru-RU") == "See \(ru.linkWord) now.")
        // An unknown language reads like English.
        #expect(say("```\nx\n```", "fr-FR") == "code omitted.")
    }

    @Test func lengthCapCutsAtAWordBoundary() {
        let word = "alpha"
        let long = Array(repeating: word, count: 100).joined(separator: " ")   // 599 characters, one sentence
        let out = say(long)!
        #expect(out.count <= 300)
        #expect(out.hasSuffix(word) && !out.hasSuffix(" "))
        // Every word is whole: the cut lands between words.
        #expect(out.split(separator: " ").allSatisfy { $0 == word })
        // Exactly at the limit nothing is cut.
        let exact = String(repeating: "a", count: 299) + "."
        #expect(say(exact) == exact)
        // One over the limit: the word is dropped whole, not split.
        let over = String(repeating: "a", count: 150) + " " + String(repeating: "b", count: 150)
        #expect(say(over) == String(repeating: "a", count: 150))
        // A single word longer than the limit is cut hard.
        let giant = String(repeating: "z", count: 400)
        #expect(say(giant)!.count == 300)
        // The second sentence is dropped when it does not fit, never half spoken after a word break.
        let first = String(repeating: "w", count: 10) + "."
        let second = Array(repeating: "ten-chars!", count: 40).joined(separator: " ") + "."
        let cap = say(first + " " + second)!
        #expect(cap.count <= 300 && cap.hasPrefix(first + " "))
    }

    @Test func cutHelper() {
        #expect(SpokenForm.cut("short", to: 300) == "short")
        #expect(SpokenForm.cut("one two three", to: 7) == "one two")       // next char is a space: keep the whole word
        #expect(SpokenForm.cut("one two three", to: 9) == "one two")       // "one two t" would split a word
        #expect(SpokenForm.cut("one, two", to: 4) == "one")                // trailing comma is dropped
    }
}
