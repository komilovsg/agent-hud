import AgentHudCore
import AppKit
import Combine
import Foundation

/// One line of the Routines tab.
struct RoutineRow: Identifiable, Equatable {
    enum Tone { case neutral, accent, success, warning, danger }
    var id: String
    var name: String
    var schedule: String
    /// "Today 18:30", "Paused", "Off"; nil for a manual routine.
    var next: String?
    var last: String
    var lastTone: Tone
    var enabled: Bool
    var running: Bool
    var queued: Bool
    var manual: Bool
}

/// Runs routines: reads the file, decides when something is due, starts sessions through the app's usual start path
/// and writes the log. The clock and the calendar are injected; nothing here waits on its own except the one timer
/// that is armed for the next fire time.
@MainActor
final class RoutineController: ObservableObject {
    /// One run in flight: from the start of its session to the end of its first turn.
    private final class Run {
        let routineId: String
        let name: String
        let notify: Bool
        let startedAt: Date
        let sessionId: String
        weak var session: OwnedSession?
        var sub: AnyCancellable?
        var ended = false
        var needsLogged = false
        var announced = Set<String>()
        init(routineId: String, name: String, notify: Bool, startedAt: Date, sessionId: String, session: OwnedSession) {
            self.routineId = routineId
            self.name = name
            self.notify = notify
            self.startedAt = startedAt
            self.sessionId = sessionId
            self.session = session
        }
    }

    private weak var app: AppModel?
    private let defaults: UserDefaults
    private static let sinceKey = "routineEnabledSince"

    var now: () -> Date = { Date() }
    var calendar: () -> Calendar = { Calendar.autoupdatingCurrent }
    /// Off in the developer checks: no timer, no system observers.
    var autoSchedule = true
    /// A notification for the person: title, body, identifier. Set by the app delegate.
    var postNotice: ((String, String, String) -> Void)?

    @Published private(set) var current = RoutineSet()
    @Published private(set) var history: [String: RoutineHistory] = [:]
    @Published private(set) var activeIds: Set<String> = []
    @Published private(set) var queued: [String] = []
    /// A short answer to the last "Run now" (why nothing started), shown in the tab.
    @Published var message: String?

    private var queue = RoutineQueue()
    private var runs: [Run] = []
    private var enabledSince: [String: Date] = [:]
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var fileStamp: String?
    private var started = false

    init(app: AppModel, defaults: UserDefaults = .standard) {
        self.app = app
        self.defaults = defaults
    }

    var file: URL { AgentHUDPaths.routinesFile }
    var logFile: URL { AgentHUDPaths.routinesLog }
    var problems: [String] { current.problems }
    var routines: [Routine] { current.routines }

    // MARK: - Life cycle

    func begin() {
        guard !started else { return }
        started = true
        reload()
        guard autoSchedule else { return }
        let wake = NSWorkspace.shared.notificationCenter
        observers.append(wake.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers = []
        started = false
    }

    /// Once a second from the app's timer: picks up edits of the file and looks at the waiting runs.
    func tick() {
        guard started else { return }
        if stamp() != fileStamp { reload() }
        watchRuns()
    }

    private func stamp() -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard let a else { return "none" }
        return "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((a[.size] as? Int) ?? 0)"
    }

    // MARK: - File

    func reload() {
        fileStamp = stamp()
        current = RoutineSet.load(from: file)
        history = RoutineLog.history(RoutineLog.read(from: logFile))
        loadSince()
        syncSince()
        if let app, !current.routines.isEmpty, app.settings.routinesSwitchIsUnset { app.settings.routinesEnabled = true }
        // A routine that no longer exists leaves the queue.
        for id in queue.ids where current.routine(id) == nil { queue.remove(id) }
        queued = queue.ids
        evaluate()
    }

    /// Opens the file in the person's editor. Only here a missing file is created, as an empty skeleton to edit.
    func openFile() {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? RoutineSet().save(to: file)
            fileStamp = stamp()
        }
        NSWorkspace.shared.open(file)
    }

    enum EditError: Error, Equatable { case fileUnreadable, duplicate }

    /// Adds a routine or replaces the one with the same id, and saves the file.
    func save(_ routine: Routine) throws {
        var next = current
        if let i = next.routines.firstIndex(where: { $0.id == routine.id }) {
            let was = next.routines[i]
            // Fields of the file that this version does not know stay where the person put them.
            var r = routine
            if r.extra.isEmpty { r.extra = was.extra }
            next.routines[i] = r
            if r.enabled, !was.enabled { enabledSince[r.id] = now() }
        } else {
            next.routines.append(routine)
            enabledSince[routine.id] = now()
        }
        try write(next)
        if let app, app.settings.routinesSwitchIsUnset { app.settings.routinesEnabled = true }
        evaluate()
    }

    func delete(_ id: String) throws {
        var next = current
        next.routines.removeAll { $0.id == id }
        try write(next)
        enabledSince[id] = nil
        queue.remove(id)
        queued = queue.ids
        persistSince()
        evaluate()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard var r = current.routine(id), r.enabled != on else { return }
        r.enabled = on
        do { try save(r) } catch { message = "routines.json cannot be changed: fix the file first" }
    }

    private func write(_ next: RoutineSet) throws {
        guard !next.unreadable else { throw EditError.fileUnreadable }
        try next.save(to: file)
        current = next
        fileStamp = stamp()
        syncSince()
    }

    // MARK: - "Enabled since"

    private func loadSince() {
        let raw = defaults.dictionary(forKey: Self.sinceKey) as? [String: Double] ?? [:]
        enabledSince = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Every enabled routine has a start of counting; a disabled one has none, so enabling it starts afresh.
    private func syncSince() {
        let t = now()
        for r in current.routines {
            if r.enabled { if enabledSince[r.id] == nil { enabledSince[r.id] = t } } else { enabledSince[r.id] = nil }
        }
        persistSince()
    }

    private func persistSince() {
        defaults.set(enabledSince.mapValues { $0.timeIntervalSince1970 }, forKey: Self.sinceKey)
    }

    // MARK: - Scheduling

    /// Looks at every enabled routine, starts what is due, fills free slots from the queue and arms the timer.
    func evaluate() {
        let t = now()
        let cal = calendar()
        let active = app?.settings.routinesEnabled ?? false
        for r in current.routines where r.enabled {
            let due = RoutineClock.due(for: r, now: t, lastRun: history[r.id]?.lastAttempt, enabledSince: enabledSince[r.id], calendar: cal)
            switch due {
            case .none:
                continue
            case .missed:
                // Too old to catch up: written down so that the schedule moves on from here.
                record(.skipped(RoutineSkipReason.missed.rawValue), r.id)
            case .run:
                if !active { record(.skipped(RoutineSkipReason.paused.rawValue), r.id) } else { _ = attempt(r, manual: false) }
            }
        }
        drain()
        arm()
    }

    private func arm() {
        timer?.cancel()
        timer = nil
        guard autoSchedule, started else { return }
        let t = now()
        let waiting = current.routines.filter { !queue.contains($0.id) }
        var wake = RoutineClock.nextWake(routines: waiting, now: t, lastRuns: history.compactMapValues(\.lastAttempt),
                                         enabledSince: enabledSince, calendar: calendar())
        // Never a busy loop, and never a long blind sleep (a clock that was changed while asleep is handled by the observers).
        if let w = wake, w <= t { wake = t.addingTimeInterval(15) }
        let delay = min(max((wake ?? t.addingTimeInterval(900)).timeIntervalSince(t), 0.5), 900)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    // MARK: - Starting

    /// "Run now". Returns a line for the person when nothing started.
    @discardableResult
    func runNow(_ id: String) -> String? {
        guard let r = current.routine(id) else { return "That routine no longer exists" }
        let text = attempt(r, manual: true)
        message = text
        return text
    }

    private func isFolderUsable(_ r: Routine) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: workingFolder(r), isDirectory: &isDir) && isDir.boolValue
    }

    /// The routine's folder, or the Assistant's own one (created on demand) when none is set.
    private func workingFolder(_ r: Routine) -> String {
        if r.folder.isEmpty {
            try? FileManager.default.createDirectory(at: AssistantSession.directory, withIntermediateDirectories: true)
            return AssistantSession.directory.path
        }
        return r.folder
    }

    private func facts(for r: Routine) -> RoutineFacts {
        RoutineFacts(runningOfRoutine: runs.filter { $0.routineId == r.id }.count,
                     runningTotal: runs.count,
                     queueLength: queue.count,
                     folderExists: isFolderUsable(r),
                     hooksConnected: app?.startRefusal() == nil)
    }

    /// Applies the start rules to one due (or pressed) routine. Returns text for the person when it did not start.
    private func attempt(_ r: Routine, manual: Bool) -> String? {
        if queue.contains(r.id) { return "\(r.name) is already waiting for a free slot" }
        switch RoutineRules.decide(facts(for: r)) {
        case .skip(let why):
            record(.skipped(why.rawValue), r.id)
            if why == .hooksNotConnected {
                postNotice?("Routine \(r.name) was skipped", app?.startRefusal() ?? "Agent HUD is not connected to Claude Code.",
                            "routine-hooks-\(r.id)")
            }
            return "Skipped: \(why.rawValue)"
        case .queue:
            if let dropped = queue.enqueue(r.id) { record(.skipped(RoutineSkipReason.queueOverflow.rawValue), dropped) }
            queued = queue.ids
            return "Waiting for a free slot (\(RoutineRules.maxConcurrent) routines run at a time)"
        case .start:
            return launch(r, reveal: manual)
        }
    }

    /// Fills free slots from the queue, oldest first, with the facts of that moment.
    private func drain() {
        while runs.count < RoutineRules.maxConcurrent, let id = queue.next() {
            queued = queue.ids
            guard let r = current.routine(id) else { continue }
            switch RoutineRules.decide(facts(for: r)) {
            case .skip(let why): record(.skipped(why.rawValue), r.id)
            case .queue: _ = queue.enqueue(r.id); queued = queue.ids; return
            case .start: _ = launch(r, reveal: false)
            }
        }
        queued = queue.ids
    }

    private func launch(_ r: Routine, reveal: Bool) -> String? {
        guard let app else { return "The app is shutting down" }
        let prompt = r.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = app.startSession(cwd: workingFolder(r), firstMessage: prompt, label: r.name, reveal: reveal)
        guard let o = result.session else {
            record(.skipped("could not start"), r.id)
            return result.refusal ?? "Could not start"
        }
        let run = Run(routineId: r.id, name: r.name, notify: r.notify, startedAt: now(), sessionId: o.sessionId, session: o)
        runs.append(run)
        activeIds.insert(r.id)
        record(.started, r.id, session: run.sessionId)
        // The state is published before it changes; read it on the next turn of the run loop.
        run.sub = o.$state.sink { [weak self, weak run] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let self, let run { self.sessionChanged(run) } } }
        }
        // A start that failed on the spot has already reached its final state.
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.sessionChanged(run) } }
        return nil
    }

    // MARK: - Runs

    /// The run's first turn is over, or its process is gone: the run ends here. A routine is one turn,
    /// so the session is let go (its card keeps what happened and the conversation can be continued from it).
    private func sessionChanged(_ run: Run) {
        guard !run.ended, let o = run.session else { if !run.ended { end(run, failed: true, cost: nil) }; return }
        switch o.state {
        case .exited:
            end(run, failed: o.turnsFinished == 0 || o.lastError != nil, cost: o.costUSD)
        case .idle where o.turnsFinished >= 1:
            let failed = o.lastError != nil
            end(run, failed: failed, cost: o.costUSD)
            o.finish()
        default:
            break
        }
    }

    private func end(_ run: Run, failed: Bool, cost: Double?) {
        guard !run.ended else { return }
        run.ended = true
        run.sub = nil
        runs.removeAll { $0 === run }
        if !runs.contains(where: { $0.routineId == run.routineId }) { activeIds.remove(run.routineId) }
        let seconds = max(0, Int(now().timeIntervalSince(run.startedAt)))
        record(failed ? .failed : .finished, run.routineId, session: run.sessionId, duration: seconds, cost: cost)
        if run.notify, !cardIsOpen(run) {
            postNotice?("Routine \(run.name) \(failed ? "failed" : "finished")", "", "routine-end-\(run.sessionId)")
        }
        evaluate()
    }

    private func cardIsOpen(_ run: Run) -> Bool {
        guard let app, let o = run.session, let key = app.sessionKey(of: o) else { return false }
        return app.selectedKey == key
    }

    /// A request of a run's session that has started to wait: logged once per run, announced once per request.
    private func watchRuns() {
        guard let app else { return }
        for run in runs where !run.ended {
            guard let o = run.session, let key = app.sessionKey(of: o) else { continue }
            var ids: [String] = []
            if let s = app.store.session(key), let p = s.activePending { ids.append(p.id) }
            if let l = app.look(for: key) { ids.append("look-\(l.id)") }
            if let a = app.act(for: key) { ids.append("act-\(a.id)") }
            for id in ids where run.announced.insert(id).inserted {
                if !run.needsLogged {
                    run.needsLogged = true
                    record(.needsYou, run.routineId, session: run.sessionId)
                }
                if run.notify, app.selectedKey != key {
                    postNotice?("Routine \(run.name) needs you", "The agent is waiting for your answer", "routine-needs-\(id)")
                }
            }
        }
    }

    // MARK: - Log

    private func record(_ outcome: RoutineLogRecord.Outcome, _ id: String, session: String? = nil, duration: Int? = nil, cost: Double? = nil) {
        let r = RoutineLogRecord(time: now(), routine: id, outcome: outcome, session: session, durationSec: duration, costUSD: cost)
        RoutineLog.append(r, to: logFile)
        var h = history[id] ?? RoutineHistory()
        h.last = r
        switch outcome {
        case .started: h.lastRun = r.time; h.lastAttempt = r.time
        case .skipped: h.lastAttempt = r.time
        default: break
        }
        history[id] = h
    }

    // MARK: - For the tab

    var isRunning: Bool { !runs.isEmpty }

    func rows() -> [RoutineRow] {
        let t = now()
        let cal = calendar()
        let on = app?.settings.routinesEnabled ?? false
        return current.routines.map { r in
            var next: String?
            if case .manual = r.schedule {
                next = nil
            } else if !r.enabled {
                next = "Off"
            } else if !on {
                next = "Paused"
            } else if let f = RoutineClock.nextFire(for: r, after: t, lastRun: history[r.id]?.lastAttempt, enabledSince: enabledSince[r.id], calendar: cal) {
                next = RoutineText.nextRun(f, now: t, calendar: cal)
            }
            let running = activeIds.contains(r.id)
            let waiting = queue.contains(r.id)
            let rec = history[r.id]?.last
            let tone: RoutineRow.Tone
            if waiting { tone = .warning } else if running { tone = .accent } else {
                switch rec?.outcome {
                case .finished: tone = .success
                case .failed: tone = .danger
                case .skipped, .needsYou: tone = .warning
                case .started: tone = .accent
                case nil: tone = .neutral
                }
            }
            return RoutineRow(id: r.id, name: r.name, schedule: RoutineText.describe(r.schedule), next: next,
                              last: waiting ? "Waiting for a free slot" : RoutineText.lastOutcome(rec, running: running, now: t, calendar: cal),
                              lastTone: tone, enabled: r.enabled, running: running, queued: waiting, manual: r.schedule == .manual)
        }
    }

    /// For the offscreen render check: fixed state, nothing is read from or written to disk.
    func installPreview(set: RoutineSet, history: [String: RoutineHistory], running: Set<String> = [], queued: [String] = []) {
        self.current = set
        self.history = history
        activeIds = running
        for id in queued { _ = queue.enqueue(id) }
        self.queued = queue.ids
        enabledSince = Dictionary(uniqueKeysWithValues: current.routines.map { ($0.id, now().addingTimeInterval(-86400)) })
    }
}
