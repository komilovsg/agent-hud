import AgentHudCore
import AppKit
import Combine
import Foundation
import os

/// Service log: only the agent type, the event and the state - no prompts or commands.
/// View with: log stream --predicate 'subsystem == "dev.agenthud"'
let hudLog = Logger(subsystem: "dev.agenthud", category: "events")

enum AvatarStyle: String, CaseIterable, Identifiable {
    case logo, blob, bot, pixel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .logo: return "Logos"
        case .blob: return "Blob"
        case .bot: return "Bot"
        case .pixel: return "Pixel"
        }
    }
}

/// Settings in UserDefaults.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var avatarStyle: AvatarStyle { didSet { d.set(avatarStyle.rawValue, forKey: "avatarStyle") } }
    @Published var hideWhenNothingWaits: Bool { didSet { d.set(hideWhenNothingWaits, forKey: "hideWhenNothingWaits") } }
    @Published var openCardOnRequest: Bool { didSet { d.set(openCardOnRequest, forKey: "openCardOnRequest") } }
    @Published var hudVisible: Bool { didSet { d.set(hudVisible, forKey: "hudVisible") } }
    @Published var autoHideDoneMinutes: Int { didSet { d.set(autoHideDoneMinutes, forKey: "autoHideDoneMinutes") } }
    @Published var hookTimeout: Int { didSet { d.set(hookTimeout, forKey: "hookTimeout") } }
    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    @Published var animations: Bool { didSet { d.set(animations, forKey: "animations") } }
    /// Activity log for the daily summary and the "Today" tab (local only).
    @Published var activityLog: Bool { didSet { d.set(activityLog, forKey: "activityLog") } }
    /// Quick prompts for VS Code sessions (inserted into the session's input field).
    @Published var quickPrompts: [String] { didSet { d.set(quickPrompts, forKey: "quickPrompts") } }
    /// Unused while `Features.typeIntoHost` is off; the stored value is kept.
    @Published var sendByTyping: Bool { didSet { d.set(sendByTyping, forKey: "sendByTyping") } }
    /// Whether agents may look at the screen, and how often they have to ask.
    @Published var screenAccess: ScreenAccessMode { didSet { d.set(screenAccess.rawValue, forKey: "screenAccess") } }
    /// Bundle ids of apps whose windows agents never see.
    @Published var screenExcludedApps: [String] { didSet { d.set(screenExcludedApps, forKey: "screenExcludedApps") } }
    /// Whether agents may act in other apps (press, click, type, keys, scroll). Off until the person turns it on.
    @Published var handsAccess: HandsAccessMode {
        didSet {
            d.set(handsAccess.rawValue, forKey: "handsAccess")
            // Turning actions back on is the person's choice and ends the "stopped" notice.
            if handsAccess != .off, handsStoppedAt != nil { handsStoppedAt = nil }
        }
    }
    /// When the stop switch turned agent actions off; nil when they were not stopped that way.
    @Published var handsStoppedAt: Date? {
        didSet {
            if let t = handsStoppedAt { d.set(t.timeIntervalSince1970, forKey: "handsStoppedAt") } else { d.removeObject(forKey: "handsStoppedAt") }
        }
    }

    /// Id of the command bar hotkey option (see `CommandBarHotKey.options`).
    @Published var commandBarHotKey: String { didSet { d.set(commandBarHotKey, forKey: "commandBarHotKey") } }
    /// Whether the command bar keeps the last commands for Up / Down.
    @Published var commandBarHistory: Bool { didSet { d.set(commandBarHistory, forKey: "commandBarHistoryEnabled") } }

    /// Push-to-talk on the command bar hotkey. Off until the person switches it on.
    @Published var voiceEnabled: Bool { didSet { d.set(voiceEnabled, forKey: "voiceEnabled") } }
    /// A code of `VoiceLanguages.all`.
    @Published var voiceLanguage: String { didSet { d.set(voiceLanguage, forKey: "voiceLanguage") } }
    /// Send the heard text by itself after a short countdown.
    @Published var voiceSendAfterSpeaking: Bool { didSet { d.set(voiceSendAfterSpeaking, forKey: "voiceSendAfterSpeaking") } }
    /// Read a short form of the Assistant's reply aloud after a spoken command.
    @Published var voiceSpeakReplies: Bool { didSet { d.set(voiceSpeakReplies, forKey: "voiceSpeakReplies") } }
    /// Allow recognition through Apple's servers when the language has no on-device model. Audio then leaves the Mac.
    @Published var voiceAllowServerRecognition: Bool { didSet { d.set(voiceAllowServerRecognition, forKey: "voiceAllowServerRecognition") } }

    static let defaultQuickPrompts = ["Continue", "Run the tests and fix what fails", "Check lint and types", "Make a commit"]

    init() {
        avatarStyle = AvatarStyle(rawValue: d.string(forKey: "avatarStyle") ?? "") ?? .logo
        // Agent logos became the default style - switch once, including users who had a character selected.
        if !d.bool(forKey: "logoStyleIntroduced") {
            d.set(true, forKey: "logoStyleIntroduced")
            avatarStyle = .logo
            d.set(AvatarStyle.logo.rawValue, forKey: "avatarStyle")
        }
        hideWhenNothingWaits = d.object(forKey: "hideWhenNothingWaits") as? Bool ?? false
        openCardOnRequest = d.object(forKey: "openCardOnRequest") as? Bool ?? true
        hudVisible = d.object(forKey: "hudVisible") as? Bool ?? true
        autoHideDoneMinutes = d.object(forKey: "autoHideDoneMinutes") as? Int ?? 30
        hookTimeout = d.object(forKey: "hookTimeout") as? Int ?? HookTiming.defaultTimeout
        notifications = d.object(forKey: "notifications") as? Bool ?? true
        animations = d.object(forKey: "animations") as? Bool ?? true
        activityLog = d.object(forKey: "activityLog") as? Bool ?? true
        sendByTyping = d.object(forKey: "sendByTyping") as? Bool ?? true
        quickPrompts = (d.stringArray(forKey: "quickPrompts") ?? Self.defaultQuickPrompts).filter { !$0.isEmpty }
        screenAccess = ScreenAccessMode(rawValue: d.string(forKey: "screenAccess") ?? "") ?? .default
        screenExcludedApps = LookExclusions.normalized(d.stringArray(forKey: "screenExcludedApps") ?? LookExclusions.defaults)
        handsAccess = HandsAccessMode(rawValue: d.string(forKey: "handsAccess") ?? "") ?? .default
        commandBarHotKey = CommandBarHotKey.option(id: d.string(forKey: "commandBarHotKey")).id
        commandBarHistory = d.object(forKey: "commandBarHistoryEnabled") as? Bool ?? true
        voiceEnabled = d.object(forKey: "voiceEnabled") as? Bool ?? false
        voiceLanguage = VoiceLanguages.info(code: d.string(forKey: "voiceLanguage")).code
        voiceSendAfterSpeaking = d.object(forKey: "voiceSendAfterSpeaking") as? Bool ?? true
        voiceSpeakReplies = d.object(forKey: "voiceSpeakReplies") as? Bool ?? true
        voiceAllowServerRecognition = d.object(forKey: "voiceAllowServerRecognition") as? Bool ?? false
        let stopped = d.double(forKey: "handsStoppedAt")
        handsStoppedAt = handsAccess == .off && stopped > 0 ? Date(timeIntervalSince1970: stopped) : nil
    }
}

/// App state: sessions, the selected card, the socket connection.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var store = SessionStore()
    @Published var selectedKey: String?
    /// The card was opened by a click (it may take keyboard focus) or opened itself on a request.
    @Published var selectedByUser = false

    let settings: Settings
    let sender: PromptSender
    private var server: SocketServer?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var notified = Set<String>()
    var onRequestNeedsAttention: ((AgentSession) -> Void)?
    /// Open the "Agent map" window (held by AppDelegate).
    var onOpenMap: (() -> Void)?
    /// Open the setup window (held by AppDelegate), optionally highlighting one permission.
    var onOpenSetup: ((PermissionKind?) -> Void)?
    /// Open the "New session" window (held by AppDelegate): preselected folder and a message to show in it.
    var onNewSession: ((String?, String?) -> Void)?
    /// Open the same window on its "Continue" tab (held by AppDelegate).
    var onContinueSession: (() -> Void)?
    /// Open the same window with the typed text of the command bar (held by AppDelegate).
    var onNewSessionWithText: ((String) -> Void)?
    /// Open the command bar (held by AppDelegate).
    var onOpenCommandBar: (() -> Void)?
    /// The Assistant answered a spoken command: the text of the answer (held by the command bar).
    var onVoiceReply: ((String) -> Void)?
    /// All project folders seen while running, plus open VS Code windows. Project labels
    /// are computed from this set rather than from the currently visible sessions - otherwise labels would change
    /// every time a session appears or goes away.
    private var knownProjects = Set<String>()
    private var editorFolders = Set<String>()
    private var editorFoldersReadAt = Date.distantPast

    init(settings: Settings) {
        self.settings = settings
        sender = PromptSender(settings: settings)
        sender.onNeedAccessibility = { [weak self] in self?.onOpenSetup?(.accessibility) }
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        settings.$handsAccess.dropFirst().sink { [weak self] mode in self?.handsModeChanged(to: mode) }.store(in: &cancellables)
        commandHistory = CommandHistory(entries: UserDefaults.standard.stringArray(forKey: "commandBarHistory") ?? [],
                                        enabled: settings.commandBarHistory)
        settings.$commandBarHistory.dropFirst().sink { [weak self] on in
            guard let self else { return }
            self.commandHistory.enabled = on
            // Switching the history off also forgets what was kept.
            if !on { self.clearCommandHistory() }
        }.store(in: &cancellables)
    }

    // MARK: - Startup

    func start(socketPath: String = AgentHUDPaths.socketPath) throws {
        let s = SocketServer(path: socketPath)
        s.onMessage = { [weak self] m in self?.handle(m) }
        s.onClosed = { [weak self] rid in self?.connectionClosed(rid) }
        s.onLook = { [weak self] request, peer in self?.handleLook(request, peerPid: peer) }
        s.onAct = { [weak self] request, peer in self?.handleAct(request, peerPid: peer) }
        try s.start()
        server = s
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        // Sessions run by the app end with it: nothing would show their permission requests afterwards.
        OwnedSession.shutDown(Array(owned.values))
        // Held tool calls go on: nothing stays paused or stopped without the app.
        release(store.releaseAll())
        // Looks that are still waiting for a click are refused: nobody can answer them any more.
        for p in looks { server?.replyLook(LookReply(requestId: p.id, outcome: .refused(LookGate.Refusal.denied.message))) }
        // The same for actions that wait for a click or for their turn.
        for id in acts.map(\.id) + actQueue.map(\.request.requestId) {
            server?.replyLook(LookReply(requestId: id, outcome: .refused(ActGate.Refusal.denied.message)))
        }
        // Release all waiting hooks - agents will ask in the terminal.
        for s in store.sessions.values {
            for p in s.pending where p.status == .open {
                server?.reply(HookReply(requestId: p.id, decision: .passthrough))
            }
        }
        server?.stop()
    }

    // MARK: - Events

    func handle(_ m: HookMessage) {
        var m = m
        let adapter = Adapters.adapter(for: m.agent)
        let now = Date()
        let hookSession = m.payload["session_id"]?.stringValue
        if let sid = hookSession, let o = owned[sid] {
            if o.isLive {
                // Whatever the hook saw around the process (the app may itself be started from a terminal),
                // this session is run by the app.
                m.host.appBundleId = HostInfo.agentHud
                m.host.appName = HostInfo.agentHudName
                hookSeen.insert(sid)
            } else if let t = o.exitedAt, now.timeIntervalSince(t) > 3, m.payload["hook_event_name"]?.stringValue != "SessionEnd" {
                // Events long after our process left: the session lives somewhere else now and is no longer ours.
                dropOwned(sid)
            }
        }
        // Apply all events of a message to a copy and publish once: every publish is a HUD redraw.
        var next = store
        var released: [String] = []
        var events = adapter.events(from: m, now: now)
        // The end of our own process may be reported after the session was already handed to an editor.
        events.removeAll { e in
            guard case .sessionEnded = e.body, let t = handedOver[e.sessionKey] else { return false }
            return now.timeIntervalSince(t) < 5
        }
        for e in events {
            released += next.apply(e, adapter: adapter)
            logActivity(e, session: next.session(e.sessionKey))
            let event = m.payload["hook_event_name"]?.stringValue ?? m.mode.rawValue
            let state = next.session(e.sessionKey)?.state.rawValue ?? "-"
            hudLog.notice("\(m.agent.rawValue, privacy: .public) \(event, privacy: .public) → \(state, privacy: .public) [\(e.sessionId.prefix(8), privacy: .public)]")
        }
        if m.mode == .gate {
            // Every gate hook gets an answer: "proceed" now, or "held" now and "proceed" on release.
            var notice: HoldNotice?
            if let e = events.first, case .toolStarted(let tool, let input, _) = e.body {
                let summary = adapter.summarize(toolName: tool, input: input, cwd: next.session(e.sessionKey)?.cwd)
                let deadline = m.deadline ?? HookTiming.deadline(now: now, hookTimeout: HookTiming.gateTimeout)
                if !next.gateArrived(sessionKey: e.sessionKey, requestId: m.requestId, summary: summary,
                                     agentId: e.agentId, deadline: deadline, now: now) {
                    notice = HoldNotice(requestId: m.requestId, until: next.session(e.sessionKey)?.hold?.until)
                }
            }
            if let notice { server?.notifyHeld(notice) } else { released.append(m.requestId) }
        }
        if next != store { store = next }
        release(released)
        rememberProjects(now: now)
        if m.mode.isSync, let s = store.session(forRequest: m.requestId) {
            requestArrived(s.id)
        }
        if let k = selectedKey, store.session(k) == nil || store.session(k)?.hidden == true { selectedKey = nil }
        updateHoldPopover()
        scheduleAutoClose()
    }

    /// A window that opened itself on a request closes once the request is resolved (in the HUD, in VS Code or in the terminal).
    /// With a delay: if the agent immediately asks the next thing, the window doesn't flicker closed and open.
    private var autoCloseTask: Task<Void, Never>?
    static let autoCloseDelay: Duration = .seconds(1)

    private func autoOpenedCardIsIdle() -> Bool {
        guard let k = selectedKey, !selectedByUser, let s = store.session(k) else { return false }
        if look(for: k) != nil || lookBlocked[k] != nil || isActing(k) || actBlocked.contains(k) { return false }
        return s.activePending == nil && s.expiredPending == nil && !s.state.needsUser
    }

    private func scheduleAutoClose() {
        guard autoOpenedCardIsIdle() else { autoCloseTask?.cancel(); autoCloseTask = nil; return }
        guard autoCloseTask == nil else { return }
        autoCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoCloseDelay)
            guard let self, !Task.isCancelled else { return }
            self.autoCloseTask = nil
            if self.autoOpenedCardIsIdle() { self.selectedKey = nil }
        }
    }

    /// A prompt and the end of a turn go to the activity log (for the daily summary and the "Today" tab).
    private func logActivity(_ e: AgentEvent, session: AgentSession?) {
        guard settings.activityLog, let s = session else { return }
        // Branches and links - also from subagent commands; everything else is recorded only for the main agent.
        if case .toolFinished(let tool, let input, _, _, let failed, _) = e.body {
            guard tool == "Bash", !failed else { return }
            let command = input["command"]?.stringValue ?? ""
            var found: [(String, String)] = GitRefs.branches(inCommand: command).map { ($0, "branch") }
            found += e.refs.flatMap { GitRefs.branches(inText: $0) }.map { ($0, "branch") }
            found += e.refs.map { ($0, "link") }
            for (text, kind) in found where loggedRefs[s.id, default: []].insert(kind + ":" + text).inserted {
                ActivityLog.append(ActivityRecord(kind: .ref, time: e.time, agent: s.kind.rawValue, session: s.sessionId,
                                                  project: s.projectName, cwd: s.cwd, text: text, detail: kind))
            }
            return
        }
        guard e.agentId == nil else { return }
        switch e.body {
        case .promptSubmitted(let text):
            guard !SessionStore.isInjectedPrompt(text) else { return }
            ActivityLog.append(ActivityRecord(kind: .prompt, time: e.time, agent: s.kind.rawValue, session: s.sessionId,
                                              project: s.projectName, cwd: s.cwd, text: String(text.prefix(600))))
        case .stopped(let msg, let failed):
            ActivityLog.append(ActivityRecord(kind: .stop, time: e.time, agent: s.kind.rawValue, session: s.sessionId,
                                              project: s.projectName, cwd: s.cwd, text: String((msg ?? "").prefix(600)),
                                              failed: failed, stats: s.turnStats(until: e.time)))
        default:
            break
        }
    }

    /// Branches and links already recorded per session - to avoid duplicate `ref` records.
    private var loggedRefs: [String: Set<String>] = [:]

    private func requestArrived(_ key: String) {
        if settings.openCardOnRequest,
           selectedKey == nil || (store.session(selectedKey!)?.activePending == nil && look(for: selectedKey!) == nil
                                  && act(for: selectedKey!) == nil) {
            autoCloseTask?.cancel()
            autoCloseTask = nil
            if selectedKey != key { selectedKey = key }
            selectedByUser = false
        }
    }

    private func release(_ ids: [String]) {
        for id in ids { server?.reply(HookReply(requestId: id, decision: .passthrough)) }
    }

    private func connectionClosed(_ rid: String) {
        store.connectionClosed(rid, now: Date())
        lookConnectionClosed(rid)
        actConnectionClosed(rid)
    }

    private func tick() {
        let now = Date()
        let minutes = settings.autoHideDoneMinutes
        // Work on a copy and publish only if something changed -
        // otherwise SwiftUI would redraw the HUD every second.
        var next = store
        // Calls held by a pause that ran out are answered here (ids of expired requests are harmless: their hooks have left).
        var released = next.tick(now: now, autoHideDoneAfter: minutes > 0 ? TimeInterval(minutes * 60) : nil)
        // The agent process died without SessionEnd (the terminal tab was closed).
        for s in next.sessions.values where s.baseState != .ended {
            if let pid = s.host.agentPid, now.timeIntervalSince(s.lastEventAt) > 5, !HostProbe.isAlive(pid) {
                released += next.markEnded(s.id, now: now)
            }
        }
        if next != store { store = next }
        release(released)
        tickLooks(now: now)
        tickActs(now: now)
        rememberProjects(now: now)
        if let k = selectedKey, store.session(k) == nil || store.session(k)?.hidden == true { selectedKey = nil }
        updateHoldPopover()
        scheduleAutoClose()
        // Notify if a request has been pending for over 10 s and the HUD is not visible.
        for s in store.sessions.values {
            guard let p = s.activePending, !notified.contains(p.id), now.timeIntervalSince(p.createdAt) > 10 else { continue }
            notified.insert(p.id)
            onRequestNeedsAttention?(s)
        }
    }

    // MARK: - User actions

    func decide(_ requestId: String, _ decision: Decision) {
        guard let s = store.session(forRequest: requestId),
              let p = s.pending.first(where: { $0.id == requestId }), p.status == .open else { return }
        // A decision that does not fit the request (a plan sent back without notes, incomplete answers) is not sent.
        guard p.kind.accepts(decision) else { return }
        let flags = RedFlags.matches(p)
        var decision = decision
        // An "always" rule for a dangerous command is not saved, even if the window managed to offer it.
        if !flags.isEmpty, case .allowWith = decision { decision = .allow }
        server?.reply(HookReply(requestId: requestId, decision: decision))
        store.markAnswered(requestId)
        DecisionLog.append(session: s, request: p, decision: decision, redFlags: flags)
        if settings.activityLog {
            ActivityLog.append(ActivityRecord(kind: .decision, time: Date(), agent: s.kind.rawValue, session: s.sessionId,
                                              project: s.projectName, cwd: s.cwd,
                                              text: DecisionLog.describe(session: s, request: p),
                                              detail: RequestLog.label(p.kind, decision)))
        }
        if case .passthrough = decision { TerminalFocus.focus(s) }
        // Someone else is waiting - show their request right away; otherwise a window opened by a request closes with a delay.
        if selectedKey == s.id, store.session(s.id)?.activePending == nil,
           let other = store.visibleSessions.first(where: { $0.id != s.id && $0.activePending != nil }) {
            selectedKey = other.id
            selectedByUser = false
        }
        scheduleAutoClose()
    }

    func select(_ key: String?) {
        selectedKey = (selectedKey == key) ? nil : key
        selectedByUser = true
        updateHoldPopover()
    }

    // MARK: - Pause and Stop

    /// Hold the session's next tool calls. A hold cannot interrupt what is already running.
    func hold(_ key: String, _ kind: Hold.Kind) {
        guard store.session(key)?.supportsHold == true, store.hold(sessionKey: key, kind: kind, now: Date()),
              let s = store.session(key) else { return }
        hudLog.notice("hold \(kind.rawValue, privacy: .public) [\(s.sessionId.prefix(8), privacy: .public)]")
        // Hooks that are already waiting learn the new end time (pause <-> stop).
        for c in s.heldCalls { server?.notifyHeld(HoldNotice(requestId: c.id, until: s.hold?.until)) }
        updateHoldPopover()
    }

    /// Resume / Play: every waiting tool call proceeds as if its hook had returned normally.
    func resume(_ key: String) {
        guard store.session(key)?.hold != nil else { return }
        release(store.release(sessionKey: key))
        hudLog.notice("hold released [\(key.suffix(8), privacy: .public)]")
        updateHoldPopover()
    }

    /// The session whose hold details are shown next to its icon (pointer over the icon or over the popover).
    @Published private(set) var holdPopoverKey: String?
    private var hoveredToken: String?
    private var popoverHovered = false
    private var popoverCloseTask: Task<Void, Never>?
    static let popoverCloseDelay: Duration = .milliseconds(350)

    func tokenHover(_ key: String, _ inside: Bool) {
        if inside { hoveredToken = key } else if hoveredToken == key { hoveredToken = nil }
        updateHoldPopover()
    }

    func popoverHover(_ inside: Bool) {
        popoverHovered = inside
        updateHoldPopover()
    }

    private func isHeld(_ key: String?) -> Bool {
        guard let key, let s = store.session(key) else { return false }
        return s.hold != nil && !s.hidden
    }

    private func updateHoldPopover() {
        // The open card shows the same details in its banner.
        var wanted: String?
        if let k = hoveredToken, isHeld(k), k != selectedKey { wanted = k }
        else if popoverHovered, let k = holdPopoverKey, isHeld(k), k != selectedKey { wanted = k }

        if let wanted {
            popoverCloseTask?.cancel()
            popoverCloseTask = nil
            if holdPopoverKey != wanted { holdPopoverKey = wanted }
            return
        }
        guard let shown = holdPopoverKey else { return }
        if !isHeld(shown) || shown == selectedKey {
            popoverCloseTask?.cancel()
            popoverCloseTask = nil
            holdPopoverKey = nil
            popoverHovered = false
            return
        }
        guard popoverCloseTask == nil else { return }
        popoverCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.popoverCloseDelay)
            guard let self, !Task.isCancelled else { return }
            self.popoverCloseTask = nil
            self.holdPopoverKey = nil
            self.popoverHovered = false
        }
    }

    // MARK: - Drafts

    /// Text typed into a card's input and not sent yet: kept while the card is closed. Not published - nothing redraws on typing.
    private var drafts: [String: String] = [:]

    func draft(_ key: String) -> String { drafts[key] ?? "" }

    func setDraft(_ key: String, _ text: String) { drafts[key] = text.isEmpty ? nil : text }

    func open(_ key: String) {
        guard let s = store.session(key) else { return }
        // A session run by the app has no other place to open: its card is the place.
        if s.host.isHud {
            if !settings.hudVisible { settings.hudVisible = true }
            selectedKey = key
            selectedByUser = true
            return
        }
        TerminalFocus.focus(s)
    }

    func hide(_ key: String) {
        if let s = store.session(key) {
            for p in s.pending where p.status == .open { release([p.id]) }
        }
        // Hiding the entry answers its look requests with "no": nothing would be left on screen to click.
        for p in looks where p.sessionKey == key { decideLook(p.id, .deny) }
        lookBlocked[key] = nil
        for p in acts where p.sessionKey == key { decideAct(p.id, .deny) }
        actBlocked.remove(key)
        guard store.session(key) != nil else { return }   // the placeholder entry went away with its request
        // A hidden session must not stay held: there would be nothing on screen to resume it with.
        release(store.release(sessionKey: key))
        // An ended session of ours is let go; a running one keeps running and comes back when it needs you.
        if let s = store.session(key), let o = owned[s.sessionId], !o.isLive { dropOwned(s.sessionId) }
        handedOver[key] = nil
        store.hide(key)
        if selectedKey == key { selectedKey = nil }
    }

    func dismissExpired(_ key: String) { store.dismissExpired(key) }

    func unhide(_ key: String) { store.unhide(key) }

    /// Sends the card's message to the session (typed into the host app, or copied as a fallback).
    func send(_ key: String, _ text: String) async -> PromptSender.Outcome {
        guard let s = store.session(key) else { return .failed("The session is gone") }
        let outcome = await sender.send(text, to: s, owned: owned[s.sessionId])
        // The card clears its field itself; this also covers a card that closed during the send.
        if case .failed = outcome { return outcome }
        if draft(key) == text { setDraft(key, "") }
        return outcome
    }

    /// Open the session in a specific editor (session link) or, for other hosts, just the project folder.
    func open(_ key: String, in editor: EditorChoice) {
        guard let s = store.session(key) else { return }
        if s.host.isEditor {
            TerminalFocus.focusEditor(s, bundleId: editor.bundleId,
                                      withLink: EditorOpenPlan.usesSessionLink(sessionEnded: s.baseState == .ended, handOver: false))
        } else {
            TerminalFocus.openProject(s, in: editor.bundleId)
        }
    }

    /// Short project labels for visible sessions ("mobile", "web"...), stable as sessions come and go.
    var projectShortLabels: [String: String] {
        let visible = store.visibleSessions.map(\.cwd)
        let universe = knownProjects.union(editorFolders).union(visible)
        let all = ProjectNames.shortLabels(for: Array(universe))
        return all.filter { visible.contains($0.key) }
    }

    /// Remember session folders and re-read VS Code windows every half minute (for project labels).
    private func rememberProjects(now: Date) {
        for s in store.sessions.values where !s.cwd.isEmpty {
            knownProjects.insert(s.cwd)
            if (projectSeenAt[s.cwd] ?? .distantPast) < s.lastEventAt { projectSeenAt[s.cwd] = s.lastEventAt }
        }
        guard now.timeIntervalSince(editorFoldersReadAt) > 30 else { return }
        editorFoldersReadAt = now
        editorFolders = EditorWorkspaces.openFolders()
    }

    /// Agent map tab: 0 - "Now", 1 - "Today".
    @Published var mapTab = 0

    func openMap() { onOpenMap?() }

    func openSetup(_ kind: PermissionKind? = nil) { onOpenSetup?(kind) }

    func openReportTab() {
        mapTab = 1
        onOpenMap?()
    }

    /// Period report in Markdown: file `reports/<from>_<to>.md` in the app folder.
    @discardableResult
    func writeReport(from: Date, to: Date) -> URL {
        let md = PeriodReport.markdown(PeriodReport.load(from: from, to: to), from: from, to: to)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HHmm"
        let url = AgentHUDPaths.supportDirectory.appendingPathComponent("reports/\(f.string(from: from))_\(f.string(from: to)).md")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(md.utf8).write(to: url)
        return url
    }

    /// Daily summary in Markdown: a file in the app folder (it can also be opened or copied).
    @discardableResult
    func writeSummary(day: Date = Date()) -> URL {
        let md = DailySummary.markdown(DailySummary.build(ActivityLog.read(day: day)), day: day)
        let url = AgentHUDPaths.supportDirectory.appendingPathComponent("summaries/\(ActivityLog.file(for: day).deletingPathExtension().lastPathComponent).md")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(md.utf8).write(to: url)
        return url
    }

    // MARK: - Sessions run by the app

    /// Sessions whose CLI process this app started, by session id. An entry stays after its process exits
    /// (the card shows what happened) until the session is hidden, handed over or continued.
    @Published private(set) var owned: [String: OwnedSession] = [:]
    /// Sessions moved to an editor (by session key) and when. Until the editor's first event arrives the card
    /// says that the move is not confirmed.
    @Published private(set) var handedOver: [String: Date] = [:]
    private var handOverTarget: [String: EditorChoice] = [:]     // by session id, while our process is leaving
    private var hookSeen = Set<String>()                          // session ids whose hook events have arrived
    private var ownedSubscriptions: [String: AnyCancellable] = [:]
    private var queueSubscriptions: [String: AnyCancellable] = [:]
    private var projectSeenAt: [String: Date] = [:]

    static let handOverWaitHint = "Wait until the agent finishes this step"
    /// Opens a session in an editor: the project folder first, then the session link.
    var openInEditor: (AgentSession, String) -> Void = { TerminalFocus.focusEditor($0, bundleId: $1, withLink: EditorOpenPlan.usesSessionLink(sessionEnded: false, handOver: true)) }

    /// Project folders for the "New session" window: most recently active first.
    var recentProjects: [String] {
        var seen = projectSeenAt.map { (cwd: $0.key, at: $0.value) }
        // Earlier today, before this launch: taken from the activity log.
        for r in ActivityLog.read(day: Date()) where !r.cwd.isEmpty && projectSeenAt[r.cwd] == nil {
            seen.append((cwd: r.cwd, at: r.time))
        }
        return OwnedSessionLogic.recentFolders(seen, limit: 8)
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    func newSession(in folder: String? = nil) { onNewSession?(folder, nil) }

    func continueSessionWindow() { onContinueSession?() }

    /// Session ids that must not be offered in the "Continue" list: shown by the store as alive, or run by this app.
    func sessionIdsInUse() -> Set<String> {
        var ids = Set(owned.keys)
        for s in store.sessions.values where s.baseState != .ended { ids.insert(s.sessionId) }
        return ids
    }

    /// Continues a session from the transcript folder in a process of this app. Returns the reason when it was not started.
    @discardableResult
    func resumePast(id: String, cwd: String) -> String? {
        if let refusal = startRefusal() { return refusal }
        guard OwnedSessionLogic.isValidSessionId(id) else { return "This is not a valid session id" }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return "The project folder no longer exists: \(cwd)"
        }
        guard !sessionIdsInUse().contains(id) else { return "This session is already open in Agent HUD" }
        let key = store.register(sessionId: id, cwd: cwd, host: .ownedByHud, now: Date())
        let o = makeOwned(id: id, cwd: cwd, resume: true)
        o.loadHistory(transcriptPath: transcriptPath(ofSession: id))
        launch(o, key: key, firstMessage: nil)
        return nil
    }

    /// Where the CLI keeps transcripts; a variable so that a check can point it elsewhere.
    var transcriptRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)

    /// `<root>/<folder>/<id>.jsonl`; the folder name is not decoded, every folder is tried.
    private func transcriptPath(ofSession id: String) -> String? {
        let root = transcriptRoot
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for f in folders {
            let p = root.appendingPathComponent(f).appendingPathComponent("\(id).jsonl").path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// Why a session cannot be started right now; nil when it can. Without the hooks every tool call of such
    /// a session would be refused with nothing shown, so it is not started at all.
    func startRefusal() -> String? {
        if !HookSetup.isInstalled(.claude) {
            return "Agent HUD is not connected to Claude Code, so the agent's permission requests could not reach you. Connect it in the setup window first."
        }
        if HookSetup.needsUpdate(.claude) {
            return "The Agent HUD hooks need an update before a session can run here. Update them in the setup window first."
        }
        return nil
    }

    /// Starts a new session in `cwd`. Returns the reason when it was not started.
    @discardableResult
    func startSession(cwd: String, firstMessage: String?) -> String? {
        if let refusal = startRefusal() { return refusal }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return "The project folder does not exist"
        }
        let id = UUID().uuidString.lowercased()
        let key = store.register(sessionId: id, cwd: cwd, host: .ownedByHud, now: Date())
        launch(makeOwned(id: id, cwd: cwd, resume: false), key: key, firstMessage: firstMessage)
        return nil
    }

    /// One owner per session: only a session that has ended (or that this app ran and saw exit, or handed over
    /// without the editor ever picking it up) may be continued here.
    func canContinueHere(_ s: AgentSession) -> Bool {
        guard OwnedSessionLogic.isValidSessionId(s.sessionId), !s.cwd.isEmpty else { return false }
        let ended = s.baseState == .ended || isHandOverUnconfirmed(s)
        return OwnedSessionLogic.canResumeHere(owned: owned[s.sessionId]?.state, sessionEnded: ended)
    }

    /// The session was moved to an editor and nothing has been heard from it since.
    func isHandOverUnconfirmed(_ s: AgentSession) -> Bool {
        guard let t = handedOver[s.id] else { return false }
        return s.lastEventAt <= t
    }

    /// The agent has answered but none of its hook events arrived: permission requests cannot reach the HUD.
    func hooksSilent(_ o: OwnedSession) -> Bool {
        o.isLive && o.turnsFinished > 0 && !hookSeen.contains(o.sessionId)
    }

    /// Continues an ended session in a process of this app. Returns the reason when it was not started.
    @discardableResult
    func continueHere(_ key: String) -> String? {
        guard let s = store.session(key) else { return "The session is gone" }
        guard canContinueHere(s) else { return "This session is still running elsewhere" }
        if let refusal = startRefusal() {
            onNewSession?(s.cwd, refusal)
            return refusal
        }
        // A session of ours that never got as far as reporting itself does not exist yet: it is started anew.
        let neverStarted = owned[s.sessionId].map { !$0.initialized } ?? false
        let transcript = s.transcriptPath
        dropOwned(s.sessionId)
        handedOver[key] = nil
        store.register(sessionId: s.sessionId, cwd: s.cwd, host: .ownedByHud, now: Date())
        let o = makeOwned(id: s.sessionId, cwd: s.cwd, resume: !neverStarted)
        if !neverStarted { o.loadHistory(transcriptPath: transcript) }
        launch(o, key: key, firstMessage: nil)
        return nil
    }

    private func launch(_ o: OwnedSession, key: String, firstMessage: String?, byVoice: Bool = false) {
        let id = o.sessionId
        owned[id] = o
        store.keep(key, true)
        hookSeen.remove(id)
        o.onInit = { [weak self, weak o] reported, model in
            guard let self, let o, self.owned[id] === o else { return }
            self.ownedInitialized(o, reported: reported, model: model)
        }
        o.onExit = { [weak self, weak o] _ in
            guard let self, let o, self.owned[id] === o else { return }
            self.ownedExited(o)
        }
        // The spoken reply is for the Assistant only.
        o.onVoiceReply = { [weak self, weak o] text in
            guard let self, let o, o.assistant else { return }
            self.onVoiceReply?(text)
        }
        // State and cost changes redraw the HUD; streamed text only redraws the open card.
        ownedSubscriptions[id] = o.$state.map { _ in () }.merge(with: o.$costUSD.map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
        // A message waiting in the command bar's queue goes out when the turn ends. Deferred: the state is
        // still being assigned while this fires.
        queueSubscriptions[id] = o.$state.filter { $0 == .idle }.sink { [weak self, weak o] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let self, let o { self.flushQueue(o) } } }
        }
        if !settings.hudVisible { settings.hudVisible = true }
        selectedKey = key
        selectedByUser = true
        o.start()
        if let text = firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { o.send(text, byVoice: byVoice) }
        hudLog.notice("owned start [\(id.prefix(8), privacy: .public)]")
    }

    private func ownedInitialized(_ o: OwnedSession, reported: String?, model: String?) {
        var key = "\(AgentKind.claude.rawValue):\(o.sessionId)"
        if let reported, reported != o.sessionId, OwnedSessionLogic.isValidSessionId(reported) {
            // The CLI runs the conversation under another id: follow it, otherwise its events would show up as a second session.
            let wasSelected = selectedKey == key
            owned[reported] = o
            owned[o.sessionId] = nil
            ownedSubscriptions[reported] = ownedSubscriptions.removeValue(forKey: o.sessionId)
            queueSubscriptions[reported] = queueSubscriptions.removeValue(forKey: o.sessionId)
            queue.move(from: o.sessionId, to: reported)
            if assistantSessionId == o.sessionId { assistantSessionId = reported }
            o.onInit = nil
            o.onExit = { [weak self, weak o] _ in
                guard let self, let o, self.owned[reported] === o else { return }
                self.ownedExited(o)
            }
            if hookSeen.remove(o.sessionId) != nil { hookSeen.insert(reported) }
            key = store.rekey(key, toSessionId: reported)
            if wasSelected { selectedKey = key }
        }
        guard let s = store.session(key) else { return }
        var next = store
        next.apply(AgentEvent(kind: .claude, sessionId: s.sessionId, cwd: s.cwd, time: Date(),
                              body: .sessionStarted(source: nil, model: model)))
        store = next
    }

    /// The registry id of a session object (it may have moved to the id the CLI reported).
    private func registryId(of o: OwnedSession) -> String? { owned.first { $0.value === o }?.key }

    private func ownedExited(_ o: OwnedSession) {
        guard let id = registryId(of: o) else { return }
        let key = "\(AgentKind.claude.rawValue):\(id)"
        hudLog.notice("owned exit [\(id.prefix(8), privacy: .public)]")
        queue.drop(id)
        var next = store
        let released = next.markEnded(key, now: Date())
        store = next
        release(released)
        if let editor = handOverTarget.removeValue(forKey: id) { completeHandOver(id, key: key, to: editor) }
    }

    private func dropOwned(_ id: String) {
        guard let o = owned.removeValue(forKey: id) else { return }
        o.onInit = nil
        o.onExit = nil
        if o.isLive { o.terminate() }
        ownedSubscriptions[id] = nil
        queueSubscriptions[id] = nil
        queue.drop(id)
        handOverTarget[id] = nil
        hookSeen.remove(id)
        store.keep("\(AgentKind.claude.rawValue):\(id)", false)
    }

    func interrupt(_ key: String) {
        guard let s = store.session(key) else { return }
        owned[s.sessionId]?.interrupt()
    }

    /// Moves a session of ours to an editor: our process leaves first, and only then the editor is asked to open
    /// the session - two processes on one session lose messages.
    func handOver(_ key: String, to editor: EditorChoice) {
        guard let s = store.session(key), let o = owned[s.sessionId], o.logic.canHandOver else { return }
        handOverTarget[s.sessionId] = editor
        o.finish()
    }

    private func completeHandOver(_ id: String, key: String, to editor: EditorChoice) {
        guard let s = store.session(key) else { return }
        dropOwned(id)
        let now = Date()
        let host = HostInfo(appBundleId: editor.bundleId, appName: editor.name, entrypoint: HostInfo.vscodeEntrypoint)
        store.register(sessionId: s.sessionId, cwd: s.cwd, host: host, now: now)
        handedOver[key] = now
        if let moved = store.session(key) { openInEditor(moved, editor.bundleId) }
    }

    /// For the offscreen render check: a session object in a fixed state, no process.
    func installPreview(_ o: OwnedSession) { owned[o.sessionId] = o }

    /// For the offscreen render check: a message waiting for the end of the turn.
    func installQueuePreview(sessionId: String, text: String) { queue.queue(text, for: sessionId) }

    // MARK: - Command bar

    /// Messages waiting for the end of a turn, one per session.
    @Published private(set) var queue = CommandBarQueue()
    /// The last commands sent from the bar (kept in UserDefaults while the history is on).
    var commandHistory = CommandHistory()
    /// The hotkey could not be registered: another app holds the combination.
    @Published var commandBarHotKeyTaken = false
    /// The last target picked in the bar; the bar falls back to the assistant when it is gone.
    var lastCommandBarTarget: CommandBarTarget?

    enum CommandBarOutcome: Equatable {
        case sent(String)       // session key
        case queued(String)
        case openedNewSession
        case refused(String)
    }

    /// The id of the assistant session; stored so that the same conversation is found again.
    var assistantSessionId: String? {
        get {
            let id = UserDefaults.standard.string(forKey: "assistantSessionId")
            return id.flatMap { OwnedSessionLogic.isValidSessionId($0) ? $0.lowercased() : nil }
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: "assistantSessionId") }
            else { UserDefaults.standard.removeObject(forKey: "assistantSessionId") }
        }
    }

    func commandBarEntries() -> [CommandBarEntry] {
        let live = owned.values.filter { $0.isLive }.sorted { a, b in
            let ta = store.session("\(AgentKind.claude.rawValue):\(a.sessionId)")?.startedAt ?? .distantPast
            let tb = store.session("\(AgentKind.claude.rawValue):\(b.sessionId)")?.startedAt ?? .distantPast
            return ta != tb ? ta < tb : a.sessionId < b.sessionId
        }.map { CommandBarLiveSession(sessionId: $0.sessionId, projectName: ProjectNames.displayName(cwd: $0.cwd), cwd: $0.cwd) }
        return CommandBarLogic.entries(live: live, assistantSessionId: assistantSessionId)
    }

    /// State of the process behind a target; nil when it has none (a new session, or no live process yet).
    func commandBarState(of target: CommandBarTarget) -> OwnedSessionLogic.State? {
        let id: String?
        switch target {
        case .assistant: id = assistantSessionId
        case .session(let s): id = s
        case .newSession: id = nil
        }
        guard let id, let o = owned[id], o.isLive else { return nil }
        return o.state
    }

    func recordCommand(_ text: String) {
        commandHistory.add(text)
        UserDefaults.standard.set(commandHistory.entries, forKey: "commandBarHistory")
    }

    func clearCommandHistory() {
        commandHistory.clear()
        UserDefaults.standard.removeObject(forKey: "commandBarHistory")
    }

    func cancelQueued(_ sessionId: String) { queue.cancel(sessionId) }

    func openCommandBar() { onOpenCommandBar?() }

    /// Sends what was typed in the bar. Nothing is sent while the hooks are not connected.
    /// `byVoice`: the text was spoken; the answer to that turn is read aloud (Assistant only). It changes nothing else.
    func submitFromBar(target: CommandBarTarget, text raw: String, interrupt: Bool, byVoice: Bool = false) -> CommandBarOutcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .refused("Type something first") }
        if target == .newSession {
            onNewSessionWithText?(text)
            return .openedNewSession
        }
        if let refusal = startRefusal() { return .refused(refusal) }
        switch target {
        case .session(let id):
            guard let o = owned[id], o.isLive else { return .refused("That session is no longer running in Agent HUD") }
            return deliver(text, to: o, interrupt: interrupt, byVoice: byVoice)
        default:
            return sendToAssistant(text, interrupt: interrupt, byVoice: byVoice)
        }
    }

    private func showCard(_ key: String) {
        if !settings.hudVisible { settings.hudVisible = true }
        selectedKey = key
        selectedByUser = true
    }

    private func deliver(_ text: String, to o: OwnedSession, interrupt: Bool, byVoice: Bool = false) -> CommandBarOutcome {
        guard let id = registryId(of: o) else { return .refused(OwnedSession.goneMessage) }
        let key = "\(AgentKind.claude.rawValue):\(id)"
        showCard(key)
        switch CommandBarLogic.sendPlan(state: o.state, interrupt: interrupt) {
        case .sendNow:
            return o.send(text, byVoice: byVoice) ? .sent(key) : .refused(OwnedSession.busyMessage)
        case .queue, .waitThenSend:
            queue.queue(text, for: id)
            o.queuedByVoice = byVoice
            return .queued(key)
        case .interruptThenSend:
            // The text waits in the slot and goes out when the interrupted turn has ended.
            queue.queue(text, for: id)
            o.queuedByVoice = byVoice
            o.interrupt()
            return .queued(key)
        case .unavailable:
            return .refused(OwnedSession.goneMessage)
        }
    }

    private func flushQueue(_ o: OwnedSession) {
        guard let id = registryId(of: o), o.logic.canSend, let text = queue.flush(id) else { return }
        if o.send(text, byVoice: o.queuedByVoice) { o.queuedByVoice = false } else { queue.queue(text, for: id) }
    }

    private func sendToAssistant(_ text: String, interrupt: Bool, byVoice: Bool) -> CommandBarOutcome {
        let stored = assistantSessionId
        let ownedAlive = stored.flatMap { owned[$0]?.isLive } ?? false
        let transcript = stored.map { transcriptPath(ofSession: $0) != nil } ?? false
        var elsewhere = false
        if let id = stored, owned[id] == nil, let s = store.session("\(AgentKind.claude.rawValue):\(id)") { elsewhere = s.baseState != .ended }
        switch CommandBarLogic.assistantAction(storedId: stored, ownedAlive: ownedAlive, transcriptExists: transcript, aliveElsewhere: elsewhere) {
        case .sendToLive:
            guard let id = stored, let o = owned[id] else { return .refused(OwnedSession.goneMessage) }
            return deliver(text, to: o, interrupt: interrupt, byVoice: byVoice)
        case .resume:
            guard let id = stored else { return .refused(OwnedSession.goneMessage) }
            return startAssistant(id: id, resume: true, text: text, byVoice: byVoice)
        case .startNew:
            // A dead entry of an earlier assistant that never got going is let go.
            if let old = stored, let o = owned[old], !o.isLive { hide("\(AgentKind.claude.rawValue):\(old)") }
            let id = UUID().uuidString.lowercased()
            assistantSessionId = id
            return startAssistant(id: id, resume: false, text: text, byVoice: byVoice)
        }
    }

    private func startAssistant(id: String, resume: Bool, text: String, byVoice: Bool) -> CommandBarOutcome {
        let dir = AssistantSession.directory
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return .refused("The assistant's folder could not be created: \(error.localizedDescription)")
        }
        if owned[id] != nil { dropOwned(id) }
        let key = store.register(sessionId: id, cwd: dir.path, host: .ownedByHud, now: Date())
        let o = makeOwned(id: id, cwd: dir.path, resume: resume)
        if resume { o.loadHistory(transcriptPath: transcriptPath(ofSession: id)) }
        launch(o, key: key, firstMessage: text, byVoice: byVoice)
        return .sent(key)
    }

    /// "New conversation": the assistant's id is forgotten and its process ends; the next command starts afresh.
    func newAssistantConversation() {
        guard let id = assistantSessionId else { return }
        assistantSessionId = nil
        let key = "\(AgentKind.claude.rawValue):\(id)"
        if owned[id] != nil { dropOwned(id) }
        hide(key)
    }

    private func makeOwned(id: String, cwd: String, resume: Bool) -> OwnedSession {
        OwnedSession(sessionId: id, cwd: cwd, resume: resume, screenTools: screenToolsPath,
                     assistant: AssistantSession.isAssistantFolder(cwd))
    }

    /// For the offscreen render check: a look request (or a finished look) in a fixed state. Nothing is looked at.
    func installLookPreview(pending: [LookPending] = [], notes: [String: [LookNote]] = [:], blocked: [String: PermissionKind] = [:]) {
        looks = pending
        lookNotes = notes
        lookBlocked = blocked
    }

    func markHandedOverForPreview(_ key: String, at date: Date) { handedOver[key] = date }

    /// For the offscreen render check: an action request (or a running action) in a fixed state. Nothing is done.
    func installActPreview(pending: [ActPending] = [], acting: Set<String> = [], blocked: Set<String> = []) {
        acts = pending
        self.acting = Dictionary(uniqueKeysWithValues: acting.map { ($0, 1) })
        actBlocked = blocked
    }

    // MARK: - For demo and preview

    func inject(_ events: [AgentEvent]) {
        var next = store
        for e in events { next.apply(e) }
        store = next
        rememberProjects(now: Date())
    }

    var visibleSessions: [AgentSession] { store.visibleSessions }

    var hasAttention: Bool {
        // A held session counts too: its icon must stay on screen, otherwise there is nothing to resume it with.
        !looks.isEmpty || !acts.isEmpty || store.visibleSessions.contains { $0.state.needsUser || $0.state == .expired || $0.hold != nil }
    }

    // MARK: - Looks (agents' read-only view of the screen)

    /// Looks waiting for the person's click, oldest first.
    @Published private(set) var looks: [LookPending] = []
    /// Sessions with a look being taken right now (after consent), with the number of looks in progress.
    @Published private(set) var looking: [String: Int] = [:]
    /// The last few looks of each session, for the "Looked at" rows of its card.
    @Published private(set) var lookNotes: [String: [LookNote]] = [:]
    /// A look was refused because a macOS permission is missing: the card offers the setup window.
    @Published private(set) var lookBlocked: [String: PermissionKind] = [:]
    private var allowances = LookAllowances()
    /// The one object that looks at the screen.
    var looker: ScreenLooking = SystemScreenLook()

    static let unknownAgentKey = "\(AgentKind.claude.rawValue):\(LookLabels.unknownSessionId)"

    func look(for key: String) -> LookPending? { looks.first { $0.sessionKey == key } }

    /// The session's icon shows the eye: a look is being decided or taken.
    func isLooking(_ key: String) -> Bool { look(for: key) != nil || (looking[key] ?? 0) > 0 }

    /// Path of the bundled screen tools server for sessions started here; nil while both looking and acting are off.
    private var screenToolsPath: String? {
        settings.screenAccess == .off && settings.handsAccess == .off ? nil : ScreenToolsSetup.bundledHelper()?.path
    }

    /// A look request from `agenthud-mcp`. It is refused, queued for a click, or - for a session the person
    /// already allowed - carried out. Holds (Pause / Stop) play no part here.
    private func handleLook(_ request: LookRequest, peerPid: Int32?) {
        let now = Date()
        let mode = settings.screenAccess
        allowances.prune(store)
        if mode == .off { allowances.removeAll() }
        let call = request.call
        // Names and sizes only, and only when the request names a target: the card must say what exactly is asked for.
        let windows = mode != .off && call.target != .none ? looker.windows() : []
        let key = callerKey(claimedSessionId: request.sessionId, peerPid: peerPid)
        var job = LookJob(request: request, sessionKey: key, window: window(of: call, in: windows))
        switch gate(job, windows: windows, consented: false) {
        case .refuse(let refusal):
            refuse(job, refusal)
            // From now on the missing permission counts as a limit: something asked for it.
            if refusal == .noAccessibility { accessibilityAskedFor = true }
            if let key, let kind = refusal.missingPermission {
                lookBlocked[key] = kind
                requestArrived(key)
            }
        case .allow:
            perform(job, detail: "allowed for session")
        case .ask(let offersSession):
            let entry = key ?? ensureUnknownEntry(now: now)
            job.sessionKey = entry
            store.unhide(entry)
            let front = call.target == .screen
                ? LookExclusions.filter(windows, excluded: settings.screenExcludedApps).first(where: \.frontmost)?.app : nil
            looks.append(LookPending(id: request.requestId, sessionKey: entry, call: call, window: job.window, frontApp: front,
                                     createdAt: now, deadline: now.addingTimeInterval(LookTiming.consentTimeout),
                                     offersSession: offersSession))
            jobs[request.requestId] = job
            lookBlocked[entry] = nil
            hudLog.notice("look \(call.tool.rawValue, privacy: .public) asks [\(entry.suffix(8), privacy: .public)]")
            requestArrived(entry)
        }
    }

    /// What a look needs besides the request itself.
    private struct LookJob {
        var request: LookRequest
        /// nil - the caller matched no session.
        var sessionKey: String?
        var window: WindowInfo?
    }

    private var jobs: [String: LookJob] = [:]

    private func window(of call: LookCall, in windows: [WindowInfo]) -> WindowInfo? {
        guard case .window(let n) = call.target else { return nil }
        return windows.first { $0.number == n }
    }

    /// The consent gate with the current settings and permissions (read-only checks; no system prompt).
    private func gate(_ job: LookJob, windows: [WindowInfo], consented: Bool) -> LookGate.Decision {
        let known = job.sessionKey != nil && job.sessionKey != Self.unknownAgentKey
        return LookGate.decide(
            mode: settings.screenAccess, tool: job.request.call.tool,
            sessionKnown: known, sessionAllowed: known && allowances.contains(job.sessionKey ?? ""),
            consented: consented,
            target: LookGate.targetState(job.request.call.target, windows: windows, excluded: settings.screenExcludedApps),
            screenRecording: PermissionProbe.state(.screenRecording).status == .granted,
            accessibility: PermissionProbe.state(.accessibility).status == .granted)
    }

    /// The session whose agent process is an ancestor of the helper. The ancestors are read here, from the
    /// connection's peer; the id the helper sends along only picks between sessions of one process.
    private func callerKey(claimedSessionId: String?, peerPid: Int32?) -> String? {
        guard let peerPid else { return nil }
        let chain = HostProbe.chain(from: peerPid).dropFirst().map(\.pid)
        let candidates = store.sessions.values.filter { !$0.isUnknownAgent }.map { s -> LookCallerResolver.Candidate in
            let ownedPid = owned[s.sessionId].flatMap { $0.isLive && $0.processId > 0 ? $0.processId : nil }
            return LookCallerResolver.Candidate(key: s.id, sessionId: s.sessionId, pid: ownedPid ?? s.host.agentPid,
                                                ended: s.baseState == .ended, lastEventAt: s.lastEventAt)
        }
        return LookCallerResolver.resolve(chain: Array(chain), claimedSessionId: claimedSessionId, candidates: candidates)
    }

    enum LookChoice { case once, session, deny }

    /// The person's click on a request card.
    func decideLook(_ id: String, _ choice: LookChoice) {
        guard let i = looks.firstIndex(where: { $0.id == id }) else { return }
        let pending = looks.remove(at: i)
        guard let job = jobs.removeValue(forKey: id) else { return }
        switch choice {
        case .deny:
            refuse(job, .denied)
        case .session where pending.offersSession:
            allowances.allow(pending.sessionKey)
            perform(job, detail: "allowed for session")
        case .once, .session:
            perform(job, detail: "allowed")
        }
        dropUnknownEntryIfIdle()
        scheduleAutoClose()
    }

    /// Carries out a look. This is the only caller of the capture and text functions, and it goes through the
    /// gate once more: the mode, the excluded apps, the permissions or the window may have changed while the card waited.
    private func perform(_ job: LookJob, detail: String) {
        let call = job.request.call
        let excluded = settings.screenExcludedApps
        let windows = looker.windows()
        let decision = gate(job, windows: windows, consented: true)
        guard decision == .allow else {
            if case .refuse(let refusal) = decision { refuse(job, refusal) }
            return
        }
        let key = job.sessionKey ?? Self.unknownAgentKey
        let eyes = looker
        let titles = PermissionProbe.state(.screenRecording).status == .granted
        looking[key, default: 0] += 1
        Task { @MainActor [weak self] in
            var outcome: LookReply.Outcome
            do {
                switch call.tool {
                case .listWindows:
                    outcome = .text(LookText.windowList(LookExclusions.filter(windows, excluded: excluded), titlesAvailable: titles))
                case .screenshot:
                    let picture = try await eyes.screenshot(of: call.target, maxSide: call.maxSide, excluded: excluded)
                    let what = LookLabels.subject(call, window: job.window)
                    outcome = .image(data: picture.data.base64EncodedString(), mimeType: picture.mimeType,
                                     caption: LookImage.caption(what: what, width: picture.width, height: picture.height,
                                                                mimeType: picture.mimeType))
                case .readWindowText:
                    guard case .window(let number) = call.target else { throw LookFailure.windowGone }
                    let tree = try await eyes.windowText(number: number, excluded: excluded)
                    let text = self?.windowText(tree, window: number) ?? LookText.render(tree.root)
                    outcome = .text(text.isEmpty ? "The window has no readable text." : LookText.cap(text))
                }
            } catch {
                outcome = .refused((error as? LookFailure)?.message ?? LookGate.Refusal.failed.message)
            }
            guard let self else { return }
            self.server?.replyLook(LookReply(requestId: job.request.requestId, outcome: outcome))
            if let n = self.looking[key], n > 1 { self.looking[key] = n - 1 } else { self.looking[key] = nil }
            if case .refused = outcome {
                self.logLook(job, result: LookGate.Refusal.failed.logLabel, looked: false)
            } else {
                self.logLook(job, result: detail, looked: true)
            }
            self.dropUnknownEntryIfIdle()
        }
    }

    private func refuse(_ job: LookJob, _ refusal: LookGate.Refusal) {
        server?.replyLook(LookReply(requestId: job.request.requestId, outcome: .refused(refusal.message)))
        logLook(job, result: refusal.logLabel, looked: false)
    }

    /// The record of a look: who, which tool, which app and window, and how it ended. Never the picture or the text.
    private func logLook(_ job: LookJob, result: String, looked: Bool) {
        let call = job.request.call
        let subject = LookLabels.subject(call, window: job.window)
        let key = job.sessionKey ?? Self.unknownAgentKey
        let s = store.session(key)
        hudLog.notice("look \(call.tool.rawValue, privacy: .public) \(result, privacy: .public) [\(key.suffix(8), privacy: .public)]")
        if settings.activityLog {
            ActivityLog.append(ActivityRecord(kind: .look, time: Date(), agent: AgentKind.claude.rawValue,
                                              session: s?.sessionId ?? LookLabels.unknownSessionId,
                                              project: s?.projectName ?? LookLabels.unknownAgent, cwd: s?.cwd ?? "",
                                              text: RequestLog.clip("\(call.tool.rawValue): \(subject)"), detail: result))
        }
        guard looked, job.sessionKey != nil, key != Self.unknownAgentKey else { return }
        var notes = lookNotes[key] ?? []
        notes.append(LookNote(time: Date(), text: "Looked at: \(subject)"))
        lookNotes[key] = Array(notes.suffix(LookNote.kept))
    }

    /// The text of a window that was just read. While agents may act, every control that can be pressed gets a
    /// reference, and the references of the window's earlier read stop working.
    private func windowText(_ tree: LookTree, window: UInt32) -> String {
        guard settings.handsAccess != .off else { return LookText.render(tree.root) }
        elementHandles[window] = tree.handles
        return elementRefs.read(window: window, tree.root)
    }

    /// The helper left before the person answered (the agent's turn was interrupted, or the helper timed out).
    private func lookConnectionClosed(_ rid: String) {
        guard let i = looks.firstIndex(where: { $0.id == rid }) else { return }
        looks.remove(at: i)
        if let job = jobs.removeValue(forKey: rid) { logLook(job, result: "cancelled", looked: false) }
        dropUnknownEntryIfIdle()
    }

    /// Once a second: a request nobody answered in time is refused; allowances of ended sessions go away.
    private func tickLooks(now: Date) {
        for p in looks where now >= p.deadline {
            looks.removeAll { $0.id == p.id }
            if let job = jobs.removeValue(forKey: p.id) { refuse(job, .expired) }
        }
        allowances.prune(store)
        for key in lookNotes.keys where store.session(key) == nil { lookNotes[key] = nil }
        for key in lookBlocked.keys where store.session(key) == nil { lookBlocked[key] = nil }
        dropUnknownEntryIfIdle()
    }

    func dismissLookBlocked(_ key: String) {
        lookBlocked[key] = nil
        scheduleAutoClose()
    }

    /// The neutral entry for requests of a caller that matched no session. It exists only while such a request waits.
    private func ensureUnknownEntry(now: Date) -> String {
        let key = Self.unknownAgentKey
        guard store.session(key) == nil else { return key }
        var next = store
        next.register(sessionId: LookLabels.unknownSessionId, cwd: "", host: HostInfo(), now: now)
        next.apply(AgentEvent(kind: .claude, sessionId: LookLabels.unknownSessionId, cwd: "", time: now,
                              body: .sessionStarted(source: nil, model: nil)))
        store = next
        return key
    }

    private func dropUnknownEntryIfIdle() {
        let key = Self.unknownAgentKey
        guard store.session(key) != nil, !isLooking(key) else { return }
        store.remove(key)
        if selectedKey == key { selectedKey = nil }
    }

    // MARK: - Hands (agents acting in other apps)

    /// Actions waiting for the person's click, oldest first.
    @Published private(set) var acts: [ActPending] = []
    /// Sessions with an action being carried out right now.
    @Published private(set) var acting: [String: Int] = [:]
    /// An action was refused because the Accessibility permission is missing: the card offers the setup window.
    @Published private(set) var actBlocked: Set<String> = []
    /// The Accessibility permission was asked for by a read of window text (it counts as a limit from then on).
    private var accessibilityAskedFor = false
    private var actJobs: [String: ActJob] = [:]
    /// Allowed actions waiting for their turn: one runs at a time, across all sessions.
    private var actQueue: [ActJob] = []
    private var actRunning: String?
    private var actAllowances = ActAllowances()
    private var actRate = ActRate()
    private var elementRefs = ElementRefs()
    /// The elements behind the references of each window's latest read.
    private var elementHandles: [UInt32: AXHandles] = [:]
    /// The one object that acts in other apps.
    var hands: ScreenActing = SystemScreenAct()

    static var ownBundleId: String { Bundle.main.bundleIdentifier ?? HostInfo.agentHud }

    func act(for key: String) -> ActPending? { acts.first { $0.sessionKey == key } }

    /// The session's icon shows the hand: an action is being decided or carried out.
    func isActing(_ key: String) -> Bool { act(for: key) != nil || (acting[key] ?? 0) > 0 }

    /// Which permissions count as a limit when missing (see `Permissions.summary`).
    var permissionsInUse: Set<PermissionKind> {
        var inUse = VoicePermissions.inUse(voiceEnabled: settings.voiceEnabled)
        if settings.handsAccess != .off || accessibilityAskedFor { inUse.insert(.accessibility) }
        return inUse
    }

    /// What an action needs besides the request itself.
    private struct ActJob {
        var request: ActRequest
        /// nil - the caller matched no session (such a call is always refused).
        var sessionKey: String?
        var subject: ActSubject
        var target = ActTarget()
        /// The person clicked "Allow" on this request's card.
        var consented = false
        var detail = "allowed"
    }

    /// Where an action goes, as the gate and the executor need it.
    private struct ActTarget {
        var state = ActGate.TargetState.available
        var bundleId: String?
        var pid: Int32?
        var element: ElementRefs.Entry?
        var app: ActApp?
    }

    /// An action request from `agenthud-mcp`: refused, queued for a click, or - for an app the person allowed
    /// for that session - put in line to be carried out.
    private func handleAct(_ request: ActRequest, peerPid: Int32?) {
        let now = Date()
        actAllowances.prune(store)
        let key = callerKey(claimedSessionId: request.sessionId, peerPid: peerPid)
        var job = ActJob(request: request, sessionKey: key, subject: ActSubject(app: "an app"))
        switch actDecision(&job, consented: false, now: now) {
        case .refuse(let refusal):
            refuseAct(job, refusal)
            if refusal == .noAccessibility, let key {
                actBlocked.insert(key)
                requestArrived(key)
            }
        case .allow:
            job.detail = "allowed in app"
            enqueueAct(job)
        case .ask(let offersApp):
            // The gate asks only for a session it knows.
            guard let key else { refuseAct(job, .unknownSession); return }
            store.unhide(key)
            var risky = false
            if case .pressKeys(let combo) = request.call.body { risky = ActRisk.isRisky(combo, targetBundleId: job.target.bundleId) }
            acts.append(ActPending(id: request.requestId, sessionKey: key, call: request.call, subject: job.subject,
                                   createdAt: now, deadline: now.addingTimeInterval(LookTiming.consentTimeout),
                                   offersApp: offersApp, risky: risky))
            actJobs[request.requestId] = job
            actBlocked.remove(key)
            hudLog.notice("act \(request.call.kind.rawValue, privacy: .public) asks [\(key.suffix(8), privacy: .public)]")
            requestArrived(key)
        }
    }

    /// The gate with the facts of this moment (read-only checks; no system prompt). Fills in the job's target.
    private func actDecision(_ job: inout ActJob, consented: Bool, now: Date) -> ActGate.Decision {
        let mode = settings.handsAccess
        actAllowances.sync(mode: mode)
        let call = job.request.call
        let key = job.sessionKey
        let held = key.flatMap { store.session($0) }?.hold != nil
        let trusted = PermissionProbe.state(.accessibility).status == .granted
        // Nothing about other apps is read for a call that the first rules refuse anyway.
        let probing = mode != .off && key != nil && !held && trusted
        if probing { (job.target, job.subject) = actTarget(of: call) }
        let target = job.target
        let excluded = ActExclusions.isExcluded(target.bundleId, screenExcluded: settings.screenExcludedApps, ownBundleId: Self.ownBundleId)
        var secure = false
        if probing, !excluded, target.state == .available, call.kind.usesKeyboard, let pid = target.pid {
            secure = hands.focusedElementIsSecure(pid: pid)
        }
        var risky = false
        if case .pressKeys(let combo) = call.body { risky = ActRisk.isRisky(combo, targetBundleId: target.bundleId) }
        return ActGate.decide(
            mode: mode, kind: call.kind, sessionKnown: key != nil, sessionHeld: held, accessibilityGranted: trusted,
            target: target.state, targetExcluded: excluded, secureField: secure, riskyKeys: risky,
            rateExceeded: key.map { actRate.exceeded($0, at: now) } ?? false,
            appAllowedForSession: key.map { actAllowances.contains(session: $0, bundleId: target.bundleId) } ?? false,
            consented: consented)
    }

    /// The app, window and element a call names, as they are right now.
    private func actTarget(of call: ActCall) -> (ActTarget, ActSubject) {
        if case .openApp(let ref) = call.body {
            guard let app = hands.installedApp(ref) else { return (ActTarget(state: .unknownApp), ActSubject(app: ref.text)) }
            return (ActTarget(bundleId: app.bundleId, app: app), ActSubject(app: app.name, bundleId: app.bundleId))
        }
        let windows = looker.windows()
        // References of windows that are gone go with them.
        let live = Set(windows.map(\.number))
        elementRefs.prune(keeping: live)
        elementHandles = elementHandles.filter { live.contains($0.key) }
        guard let number = call.window, let w = windows.first(where: { $0.number == number }) else {
            return (ActTarget(state: .unknownWindow), ActSubject(app: "a window"))
        }
        var subject = ActSubject(app: w.app, bundleId: w.bundleId, windowTitle: w.title)
        var target = ActTarget(bundleId: w.bundleId, pid: w.pid)
        // Exclusions and allowances go by bundle id: a window whose app has none is not acted in.
        guard let bundle = w.bundleId, !bundle.isEmpty else {
            target.state = .unknownApp
            return (target, subject)
        }
        if case .pressElement(let ref) = call.body {
            guard let entry = elementRefs.resolve(window: number, ref: ref),
                  elementHandles[number]?.elements.indices.contains(entry.handle) == true else {
                target.state = .staleElement
                return (target, subject)
            }
            target.element = entry
            subject.elementRole = entry.role
            subject.elementLabel = entry.label
        }
        return (target, subject)
    }

    enum ActChoice { case once, app, deny }

    /// The person's click on an action card.
    func decideAct(_ id: String, _ choice: ActChoice) {
        guard let i = acts.firstIndex(where: { $0.id == id }) else { return }
        let pending = acts.remove(at: i)
        guard var job = actJobs.removeValue(forKey: id) else { return }
        switch choice {
        case .deny:
            refuseAct(job, .denied)
        case .app where pending.offersApp:
            actAllowances.allow(session: pending.sessionKey, bundleId: pending.subject.bundleId)
            job.consented = true
            job.detail = "allowed in app"
            enqueueAct(job)
        case .once, .app:
            job.consented = true
            job.detail = "allowed"
            enqueueAct(job)
        }
        scheduleAutoClose()
    }

    private func enqueueAct(_ job: ActJob) {
        actQueue.append(job)
        runNextAct()
    }

    /// Carries out the next action in line. This is the only caller of the executor, and every action goes
    /// through the gate once more right before it: the mode, the hold, the window, the element, the focus or
    /// the permission may have changed while it waited for a click or for its turn.
    private func runNextAct() {
        while actRunning == nil, !actQueue.isEmpty {
            var job = actQueue.removeFirst()
            let now = Date()
            let decision = actDecision(&job, consented: job.consented, now: now)
            guard decision == .allow, let key = job.sessionKey, let order = actOrder(job) else {
                if case .refuse(let refusal) = decision { refuseAct(job, refusal) } else { refuseAct(job, .changed) }
                continue
            }
            if hands.isScreenLocked() {
                refuseAct(job, .screenLocked)
                continue
            }
            actRate.record(key, at: now)
            actRunning = job.request.requestId
            acting[key, default: 0] += 1
            let executor = hands
            Task { @MainActor [weak self] in
                let failure = await executor.perform(order) { [weak self] in
                    guard let self else { return ActGate.Refusal.failed.message }
                    return self.actStopReason(key)
                }
                guard let self else { return }
                let call = job.request.call
                let outcome: LookReply.Outcome = failure.map { .refused($0.message) } ?? .text(ActLabels.done(call, job.subject))
                self.server?.replyLook(LookReply(requestId: job.request.requestId, outcome: outcome))
                self.logAct(job, result: failure == nil ? job.detail : ActGate.Refusal.failed.logLabel, done: failure == nil)
                if let n = self.acting[key], n > 1 { self.acting[key] = n - 1 } else { self.acting[key] = nil }
                self.actRunning = nil
                self.scheduleAutoClose()
                self.runNextAct()
            }
        }
    }

    /// Why a running action must stop before its next event; nil while it may go on.
    private func actStopReason(_ key: String) -> String? {
        if settings.handsAccess == .off {
            return (settings.handsStoppedAt != nil ? ActGate.Refusal.stopped : ActGate.Refusal.off).message
        }
        if store.session(key)?.hold != nil { return ActGate.Refusal.sessionHeld.message }
        return nil
    }

    private func actOrder(_ job: ActJob) -> ActOrder? {
        let call = job.request.call, target = job.target
        if case .openApp = call.body { return target.app.map { .open($0) } }
        guard let window = call.window, let pid = target.pid else { return nil }
        switch call.body {
        case .pressElement:
            guard let entry = target.element, let handles = elementHandles[window] else { return nil }
            return .press(handles: handles, index: entry.handle)
        case .clickAt(let x, let y, let button, let count):
            return .click(window: window, pid: pid, x: x, y: y, button: button, count: count)
        case .typeText(let text): return .type(window: window, pid: pid, text: text)
        case .pressKeys(let combo): return .keys(window: window, pid: pid, combo: combo)
        case .scroll(let dx, let dy): return .scroll(window: window, pid: pid, dx: dx, dy: dy)
        case .focusWindow: return .focus(window: window, pid: pid)
        case .openApp: return nil
        }
    }

    private func refuseAct(_ job: ActJob, _ refusal: ActGate.Refusal) {
        server?.replyLook(LookReply(requestId: job.request.requestId, outcome: .refused(refusal.message)))
        logAct(job, result: refusal.logLabel, done: false)
    }

    /// The record of an action: who, what, in which app, and how it ended. Typed text is kept only as its
    /// first characters and its length.
    private func logAct(_ job: ActJob, result: String, done: Bool) {
        let call = job.request.call
        let summary = ActLabels.summary(call, job.subject)
        let s = job.sessionKey.flatMap { store.session($0) }
        hudLog.notice("act \(call.kind.rawValue, privacy: .public) \(result, privacy: .public) [\((job.sessionKey ?? "-").suffix(8), privacy: .public)]")
        if settings.activityLog {
            ActivityLog.append(ActivityRecord(kind: .act, time: Date(), agent: AgentKind.claude.rawValue,
                                              session: s?.sessionId ?? LookLabels.unknownSessionId,
                                              project: s?.projectName ?? LookLabels.unknownAgent, cwd: s?.cwd ?? "",
                                              text: RequestLog.clip("\(call.kind.rawValue): \(summary)"), detail: result))
        }
        guard done, let key = job.sessionKey else { return }
        var notes = lookNotes[key] ?? []
        notes.append(LookNote(time: Date(), text: ActLabels.didRow(call, job.subject), symbol: "hand.point.up.left"))
        lookNotes[key] = Array(notes.suffix(LookNote.kept))
    }

    /// The stop switch (the global hotkey, the status menu, the control panel): agent actions go off, everything
    /// that waits is refused, and every "allow in this app" answer is forgotten. An action that is running stops
    /// before its next event. Turning actions back on is done in the settings.
    func stopAgentActions() {
        guard settings.handsAccess != .off || !acts.isEmpty || !actQueue.isEmpty || actRunning != nil else { return }
        refuseWaitingActs(.stopped)
        actAllowances.removeAll()
        settings.handsAccess = .off
        settings.handsStoppedAt = Date()
        hudLog.notice("agent actions stopped")
        scheduleAutoClose()
    }

    private func refuseWaitingActs(_ refusal: ActGate.Refusal) {
        for p in acts {
            if let job = actJobs.removeValue(forKey: p.id) { refuseAct(job, refusal) }
        }
        acts.removeAll()
        for job in actQueue { refuseAct(job, refusal) }
        actQueue.removeAll()
    }

    /// The setting changed: allowances belong to the mode they were given in, and with actions off nothing waits.
    private func handsModeChanged(to mode: HandsAccessMode) {
        actAllowances.sync(mode: mode)
        if mode == .off {
            refuseWaitingActs(.off)
            elementRefs.removeAll()
            elementHandles.removeAll()
        }
    }

    /// The helper left before the action was decided or carried out.
    private func actConnectionClosed(_ rid: String) {
        if let i = acts.firstIndex(where: { $0.id == rid }) {
            acts.remove(at: i)
            if let job = actJobs.removeValue(forKey: rid) { logAct(job, result: "cancelled", done: false) }
        }
        if let i = actQueue.firstIndex(where: { $0.request.requestId == rid }) {
            logAct(actQueue.remove(at: i), result: "cancelled", done: false)
        }
    }

    /// Once a second: a card nobody answered in time is refused; allowances of ended sessions go away.
    private func tickActs(now: Date) {
        for p in acts where now >= p.deadline {
            acts.removeAll { $0.id == p.id }
            if let job = actJobs.removeValue(forKey: p.id) { refuseAct(job, .expired) }
        }
        actAllowances.prune(store)
        actAllowances.sync(mode: settings.handsAccess)
        for key in actBlocked where store.session(key) == nil { actBlocked.remove(key) }
    }

    func dismissActBlocked(_ key: String) {
        actBlocked.remove(key)
        scheduleAutoClose()
    }
}

/// One finished look, as the session's card shows it.
struct LookNote: Identifiable, Equatable {
    static let kept = 3
    let id = UUID()
    let time: Date
    let text: String
    /// "eye" for a look, a hand for something the agent did.
    var symbol = "eye"
}

/// Red flags: the rules file is read on every check (it is tiny), edits apply without a restart.
enum RedFlags {
    static func load() -> RedFlagSet { RedFlagSet.load(from: AgentHUDPaths.redFlagsFile) }

    static func matches(toolName: String, input: JSONValue) -> [RedFlagRule] {
        // Not Bash - no flags, leave the file alone.
        guard toolName == "Bash" else { return [] }
        return load().matches(toolName: toolName, input: input)
    }

    static func matches(_ request: PendingRequest) -> [RedFlagRule] {
        switch request.kind {
        case .permission(let tool, let input): return matches(toolName: tool, input: input)
        case .question, .plan: return []
        }
    }

    /// Open the rules file in the editor; if the file does not exist, the built-in rules appear first.
    static func openFile() {
        _ = load()
        NSWorkspace.shared.open(AgentHUDPaths.redFlagsFile)
    }
}

/// Decision log: what was allowed/denied/answered and when.
enum DecisionLog {
    static func describe(session: AgentSession, request: PendingRequest) -> String {
        RequestLog.title(request.kind, cwd: session.cwd, adapter: Adapters.adapter(for: session.kind))
    }

    static func append(session: AgentSession, request: PendingRequest, decision: Decision, redFlags: [RedFlagRule] = []) {
        let f = ISO8601DateFormatter()
        let what = describe(session: session, request: request)
        // A question, its answers and plan feedback are kept only as short summaries; the plan text is not kept.
        var detail = RequestLog.detail(request.kind, decision)
        if !redFlags.isEmpty { detail += " [red: \(redFlags.map(\.id).joined(separator: ","))]" }
        let line = [f.string(from: Date()), session.projectName, RequestLog.label(request.kind, decision), what, detail]
            .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\t") + "\n"
        let url = AgentHUDPaths.decisionsLog
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
