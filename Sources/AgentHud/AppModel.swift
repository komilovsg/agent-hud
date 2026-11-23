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
    /// Send from the card by typing into the host app (needs the Accessibility permission); off: copy the text and open the session.
    @Published var sendByTyping: Bool { didSet { d.set(sendByTyping, forKey: "sendByTyping") } }

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
    }

    // MARK: - Startup

    func start(socketPath: String = AgentHUDPaths.socketPath) throws {
        let s = SocketServer(path: socketPath)
        s.onMessage = { [weak self] m in self?.handle(m) }
        s.onClosed = { [weak self] rid in self?.connectionClosed(rid) }
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
        if settings.openCardOnRequest, selectedKey == nil || store.session(selectedKey!)?.activePending == nil {
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
                                              text: DecisionLog.describe(session: s, request: p), detail: decision.logLabel))
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
            TerminalFocus.focusEditor(s, bundleId: editor.bundleId)
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
    private var projectSeenAt: [String: Date] = [:]

    static let handOverWaitHint = "Wait until the agent finishes this step"
    /// Opens a session in an editor: the project folder first, then the session link.
    var openInEditor: (AgentSession, String) -> Void = { TerminalFocus.focusEditor($0, bundleId: $1) }

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
        launch(OwnedSession(sessionId: id, cwd: cwd, resume: false), key: key, firstMessage: firstMessage)
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
        let o = OwnedSession(sessionId: s.sessionId, cwd: s.cwd, resume: !neverStarted)
        if !neverStarted { o.loadHistory(transcriptPath: transcript) }
        launch(o, key: key, firstMessage: nil)
        return nil
    }

    private func launch(_ o: OwnedSession, key: String, firstMessage: String?) {
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
        // State and cost changes redraw the HUD; streamed text only redraws the open card.
        ownedSubscriptions[id] = o.$state.map { _ in () }.merge(with: o.$costUSD.map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
        if !settings.hudVisible { settings.hudVisible = true }
        selectedKey = key
        selectedByUser = true
        o.start()
        if let text = firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { o.send(text) }
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

    func markHandedOverForPreview(_ key: String, at date: Date) { handedOver[key] = date }

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
        store.visibleSessions.contains { $0.state.needsUser || $0.state == .expired || $0.hold != nil }
    }
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
        switch request.kind {
        case .permission(let tool, let input):
            return Adapters.adapter(for: session.kind).summarize(toolName: tool, input: input, cwd: session.cwd)
        }
    }

    static func append(session: AgentSession, request: PendingRequest, decision: Decision, redFlags: [RedFlagRule] = []) {
        let f = ISO8601DateFormatter()
        let what = describe(session: session, request: request)
        var detail = ""
        switch decision {
        case .deny(let r): detail = r ?? ""
        case .allowWith(let updates): detail = updates.compactMap(PermissionRules.describe).joined(separator: "; ")
        default: break
        }
        if !redFlags.isEmpty { detail += " [red: \(redFlags.map(\.id).joined(separator: ","))]" }
        let line = [f.string(from: Date()), session.projectName, decision.logLabel, what, detail]
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
