import Foundation

// Routines: saved prompts that the app starts by itself on a schedule or on "Run now".
// Everything here is pure: the clock, the calendar and the facts about the world are passed in.

// MARK: - Model

/// Why one entry of the file cannot be used.
public struct RoutineFailure: Error, Equatable, Sendable, ExpressibleByStringInterpolation, CustomStringConvertible {
    public let description: String
    public init(stringLiteral value: String) { description = value }
    public init(stringInterpolation: DefaultStringInterpolation) { description = String(stringInterpolation: stringInterpolation) }
}

public enum RoutineSchedule: Equatable, Sendable {
    /// Every day (or on the given weekdays, Monday = 1 ... Sunday = 7; empty = every day) at a local time.
    case daily(hour: Int, minute: Int, weekdays: Set<Int>)
    /// Every N hours, counted from the last run (or from the moment the routine was enabled).
    case every(hours: Int)
    /// Only "Run now".
    case manual

    public static let dailyDefault = RoutineSchedule.daily(hour: 9, minute: 0, weekdays: [])
}

public struct Routine: Equatable, Sendable, Identifiable {
    public static let maxPromptLength = 4000
    public static let maxNameLength = 80

    public var id: String
    public var name: String
    public var prompt: String
    /// Absolute path of the working directory; empty = the Assistant's folder.
    public var folder: String
    public var enabled: Bool
    public var schedule: RoutineSchedule
    public var catchUp: Bool
    public var notify: Bool
    /// Fields of the file this version does not know; written back unchanged.
    public var extra: [JSONObject.Entry]

    public init(id: String, name: String, prompt: String, folder: String = "", enabled: Bool = true,
                schedule: RoutineSchedule = .manual, catchUp: Bool = true, notify: Bool = true,
                extra: [JSONObject.Entry] = []) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.folder = folder
        self.enabled = enabled
        self.schedule = schedule
        self.catchUp = catchUp
        self.notify = notify
        self.extra = extra
    }

    static let knownKeys: Set<String> = ["id", "name", "prompt", "folder", "enabled", "schedule", "catchUp", "notify"]

    /// Ids are file-safe slugs.
    public static func isValidId(_ id: String) -> Bool {
        guard (1...64).contains(id.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        return id.unicodeScalars.allSatisfy(allowed.contains) && id.first != "-" && id.first != "_"
    }

    /// A free id made from a name: "Morning report" -> "morning-report", "morning-report-2" when taken.
    public static func makeId(from name: String, taken: Set<String>) -> String {
        var slug = ""
        var lastDash = true
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { slug.append(ch); lastDash = false }
            else if !lastDash { slug.append("-"); lastDash = true }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "routine" }
        guard taken.contains(slug) else { return slug }
        var n = 2
        while taken.contains("\(slug)-\(n)") { n += 1 }
        return "\(slug)-\(n)"
    }

    /// What is wrong with the values, as text for the editor. Empty = can be saved.
    public func problems() -> [String] {
        var out: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { out.append("Give the routine a name.") }
        else if trimmedName.count > Self.maxNameLength { out.append("The name is longer than \(Self.maxNameLength) characters.") }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("Write what the agent should do.") }
        else if prompt.count > Self.maxPromptLength {
            out.append("The prompt is \(prompt.count - Self.maxPromptLength) characters over the \(Self.maxPromptLength) limit.")
        }
        if !folder.isEmpty, !folder.hasPrefix("/") { out.append("The folder must be an absolute path.") }
        switch schedule {
        case .daily(let h, let m, let days):
            if !(0...23).contains(h) || !(0...59).contains(m) { out.append("The time must be between 00:00 and 23:59.") }
            if days.contains(where: { !(1...7).contains($0) }) { out.append("Weekdays are 1 (Monday) to 7 (Sunday).") }
        case .every(let hours):
            if !(1...24).contains(hours) { out.append("Hours must be between 1 and 24.") }
        case .manual:
            break
        }
        return out
    }

    // MARK: JSON

    public func toJSON() -> JSONValue {
        var o = JSONObject()
        o["id"] = .string(id)
        o["name"] = .string(name)
        o["prompt"] = .string(prompt)
        o["folder"] = .string(folder)
        o["enabled"] = .bool(enabled)
        o["schedule"] = schedule.toJSON()
        o["catchUp"] = .bool(catchUp)
        o["notify"] = .bool(notify)
        for e in extra where !Self.knownKeys.contains(e.key) { o[e.key] = e.value }
        return .object(o)
    }

    /// A routine from one entry of the file, or the reason it cannot be used.
    static func parse(_ v: JSONValue, index: Int) -> Result<Routine, RoutineFailure> {
        guard let obj = v.objectValue else { return .failure("Routine #\(index + 1): not an object - skipped") }
        let id = obj["id"]?.stringValue ?? ""
        let label = id.isEmpty ? "#\(index + 1)" : id
        func bad(_ why: RoutineFailure) -> Result<Routine, RoutineFailure> { .failure("Routine \(label): \(why) - skipped") }

        guard isValidId(id) else { return bad("the id must be 1-64 characters: a-z, 0-9, - and _") }
        guard let name = obj["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return bad("a name is required")
        }
        guard let prompt = obj["prompt"]?.stringValue, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return bad("a prompt is required")
        }
        guard prompt.count <= maxPromptLength else { return bad("the prompt is longer than \(maxPromptLength) characters") }
        var folder = ""
        if let f = obj["folder"] {
            guard let s = f.stringValue else { return bad("folder must be text") }
            guard s.isEmpty || s.hasPrefix("/") else { return bad("folder must be an absolute path") }
            folder = s
        }
        func flag(_ key: String) -> Result<Bool, RoutineFailure> {
            guard let v = obj[key] else { return .success(true) }
            guard let b = v.boolValue else { return .failure("\(key) must be true or false") }
            return .success(b)
        }
        var flags: [Bool] = []
        for key in ["enabled", "catchUp", "notify"] {
            switch flag(key) {
            case .success(let b): flags.append(b)
            case .failure(let why): return bad(why)
            }
        }
        guard let sched = obj["schedule"], sched.objectValue != nil else { return bad("a schedule is required") }
        let schedule: RoutineSchedule
        switch RoutineSchedule.parse(sched) {
        case .success(let s): schedule = s
        case .failure(let why): return bad(why)
        }
        let extra = obj.entries.filter { !knownKeys.contains($0.key) }
        return .success(Routine(id: id, name: name, prompt: prompt, folder: folder, enabled: flags[0], schedule: schedule,
                                catchUp: flags[1], notify: flags[2], extra: extra))
    }
}

extension RoutineSchedule {
    /// Unknown fields inside a schedule object are not kept (those of the routine and of the file are).
    public func toJSON() -> JSONValue {
        var o = JSONObject()
        switch self {
        case .daily(let h, let m, let days):
            o["kind"] = "daily"
            o["time"] = .string(String(format: "%02d:%02d", h, m))
            o["weekdays"] = .array(days.sorted().map { .int($0) })
        case .every(let hours):
            o["kind"] = "every"
            o["hours"] = .int(hours)
        case .manual:
            o["kind"] = "manual"
        }
        return .object(o)
    }

    static func parse(_ v: JSONValue) -> Result<RoutineSchedule, RoutineFailure> {
        switch v["kind"]?.stringValue {
        case "daily":
            guard let t = v["time"]?.stringValue, let (h, m) = parseTime(t) else {
                return .failure("daily schedule needs a time as HH:mm (00:00-23:59)")
            }
            var days = Set<Int>()
            if let list = v["weekdays"] {
                guard let a = list.arrayValue else { return .failure("weekdays must be a list of numbers 1-7") }
                for d in a {
                    guard let n = d.intValue, d.doubleValue == Double(n), (1...7).contains(n) else {
                        return .failure("weekdays must be numbers 1 (Monday) to 7 (Sunday)")
                    }
                    days.insert(n)
                }
            }
            return .success(.daily(hour: h, minute: m, weekdays: days))
        case "every":
            guard let n = v["hours"]?.intValue, v["hours"]?.doubleValue == Double(n), (1...24).contains(n) else {
                return .failure("an \"every\" schedule needs hours from 1 to 24")
            }
            return .success(.every(hours: n))
        case "manual":
            return .success(.manual)
        case let other?:
            return .failure("unknown schedule kind \"\(other.prefix(30))\"")
        case nil:
            return .failure("the schedule has no kind")
        }
    }

    /// "09:00" / "18:30" exactly.
    static func parseTime(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count == 2, p[1].count == 2, p[0].allSatisfy(\.isASCII), p[1].allSatisfy(\.isASCII),
              let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }
}

// MARK: - The file

public struct RoutineSet: Equatable, Sendable {
    public var routines: [Routine]
    /// What is wrong with the file, as text for the person.
    public var problems: [String]
    /// The file exists but cannot be used as a whole (syntax error, wrong shape): saving would destroy it, so it is refused.
    public var unreadable: Bool
    /// Entries that were skipped; written back after the valid routines so that an edit in the app never deletes them.
    var rawSkipped: [JSONValue]
    /// Other top-level fields.
    var topExtra: [JSONObject.Entry]

    public init(routines: [Routine] = [], problems: [String] = [], unreadable: Bool = false) {
        self.routines = routines
        self.problems = problems
        self.unreadable = unreadable
        rawSkipped = []
        topExtra = []
    }

    public static let version = 1

    /// A missing file means no routines and is not created. Trouble with the file means no routines plus a description;
    /// the file itself is never touched here.
    public static func load(from url: URL) -> RoutineSet {
        guard FileManager.default.fileExists(atPath: url.path) else { return RoutineSet() }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return RoutineSet(problems: ["\(name) cannot be read"], unreadable: true)
        }
        return decode(data, name: name)
    }

    public static func decode(_ data: Data, name: String = "routines.json") -> RoutineSet {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch {
            return RoutineSet(problems: ["\(name): \(error) - no routines are loaded"], unreadable: true)
        }
        guard let obj = json.objectValue, let list = obj["routines"]?.arrayValue else {
            return RoutineSet(problems: ["\(name): no routines array - no routines are loaded"], unreadable: true)
        }
        if let v = obj["version"], v.intValue != Self.version {
            return RoutineSet(problems: ["\(name): version \(v.compact().prefix(10)) is not supported - no routines are loaded"], unreadable: true)
        }
        var set = RoutineSet()
        set.topExtra = obj.entries.filter { $0.key != "version" && $0.key != "routines" }
        var seen = Set<String>()
        for (i, entry) in list.enumerated() {
            switch Routine.parse(entry, index: i) {
            case .failure(let why):
                set.problems.append(why.description)
                set.rawSkipped.append(entry)
            case .success(let r):
                if !seen.insert(r.id).inserted {
                    set.problems.append("Routine \(r.id): the id is used twice - skipped")
                    set.rawSkipped.append(entry)
                } else {
                    set.routines.append(r)
                }
            }
        }
        return set
    }

    public func encode() -> JSONValue {
        var o = JSONObject()
        o["version"] = .int(Self.version)
        o["routines"] = .array(routines.map { $0.toJSON() } + rawSkipped)
        for e in topExtra { o[e.key] = e.value }
        return .object(o)
    }

    public enum SaveError: Error, Equatable { case unreadableFile }

    /// Writes the file atomically. Refused while the file on disk is unreadable (the person is fixing it).
    public func save(to url: URL) throws {
        guard !unreadable else { throw SaveError.unreadableFile }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((encode().pretty() + "\n").utf8).write(to: url, options: .atomic)
    }

    public func routine(_ id: String) -> Routine? { routines.first { $0.id == id } }
}

public extension AgentHUDPaths {
    static var routinesFile: URL { supportDirectory.appendingPathComponent("routines.json") }
    static var routinesLog: URL { supportDirectory.appendingPathComponent("routines-log.jsonl") }
}

// MARK: - Time

public enum RoutineClock {
    /// A missed fire older than this is skipped, not caught up.
    public static let catchUpWindow: TimeInterval = 12 * 3600
    /// A fire that is only this late (timer slack) is on time, whatever `catchUp` says.
    public static let onTimeGrace: TimeInterval = 90

    /// Monday = 1 ... Sunday = 7.
    public static func isoWeekday(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// The moment from which the schedule is counted: the later of the last attempt and the time of enabling,
    /// never in the future (a clock set back must not freeze the routine).
    public static func reference(lastRun: Date?, enabledSince: Date?, now: Date) -> Date? {
        let r = [lastRun, enabledSince].compactMap { $0 }.max()
        return r.map { min($0, now) }
    }

    /// The first fire strictly after `after`. For `daily`, once per matching local day: a time that does not exist
    /// (spring forward) fires at the first moment after the gap, a time that occurs twice (fall back) fires at its first occurrence.
    /// For `every`, base + N hours (base = later of `lastRun` and `enabledSince`, else `after`); an overdue value rolls
    /// forward by whole periods. Nil for `manual`.
    public static func nextFire(for routine: Routine, after: Date, lastRun: Date?, enabledSince: Date? = nil,
                                calendar: Calendar) -> Date? {
        switch routine.schedule {
        case .manual:
            return nil
        case .every(let hours):
            let step = TimeInterval(max(1, hours)) * 3600
            let base = reference(lastRun: lastRun, enabledSince: enabledSince, now: after) ?? after
            var fire = base.addingTimeInterval(step)
            if fire <= after {
                let k = ((after.timeIntervalSince(fire)) / step).rounded(.down) + 1
                fire = fire.addingTimeInterval(k * step)
            }
            return fire
        case .daily(let h, let m, let days):
            let firstDay = calendar.startOfDay(for: after)
            for i in 0..<15 {
                guard let day = calendar.date(byAdding: .day, value: i, to: firstDay) else { return nil }
                if !days.isEmpty, !days.contains(isoWeekday(day, calendar: calendar)) { continue }
                guard let fire = calendar.date(bySettingHour: h, minute: m, second: 0, of: day, matchingPolicy: .nextTime,
                                               repeatedTimePolicy: .first, direction: .forward) else { continue }
                // Must still be the same local day (a gap can never push 02:30 past midnight, but be safe).
                guard calendar.isDate(fire, inSameDayAs: day), fire > after else { continue }
                return fire
            }
            return nil
        }
    }

    /// The latest scheduled fire that is not in the future and is later than the reference; nil when there is none.
    /// Several missed fires collapse into this one.
    public static func missedFire(for routine: Routine, now: Date, lastRun: Date?, enabledSince: Date? = nil,
                                  calendar: Calendar) -> Date? {
        guard let ref = reference(lastRun: lastRun, enabledSince: enabledSince, now: now) else { return nil }
        switch routine.schedule {
        case .manual:
            return nil
        case .every(let hours):
            let fire = ref.addingTimeInterval(TimeInterval(max(1, hours)) * 3600)
            return fire <= now ? fire : nil
        case .daily:
            var start = max(ref, now.addingTimeInterval(-9 * 86400))
            var last: Date?
            for _ in 0..<20 {
                guard let f = nextFire(for: routine, after: start, lastRun: nil, calendar: calendar), f <= now else { break }
                last = f
                start = f
            }
            return last
        }
    }

    public enum Due: Equatable, Sendable {
        case none
        /// Start now. `catchUp`: the fire time had already passed beyond timer slack.
        case run(fire: Date, catchUp: Bool)
        /// A fire that must not run (too old, or catch-up is off): record the skip so the schedule moves on.
        case missed(fire: Date)
    }

    /// The catch-up decision. Disabled and manual routines are never due.
    public static func due(for routine: Routine, now: Date, lastRun: Date?, enabledSince: Date? = nil,
                           calendar: Calendar) -> Due {
        guard routine.enabled, let fire = missedFire(for: routine, now: now, lastRun: lastRun, enabledSince: enabledSince,
                                                     calendar: calendar) else { return .none }
        let age = now.timeIntervalSince(fire)
        if age <= onTimeGrace { return .run(fire: fire, catchUp: false) }
        if routine.catchUp, age < catchUpWindow { return .run(fire: fire, catchUp: true) }
        return .missed(fire: fire)
    }

    /// When the scheduler has to look again: now when something is due, otherwise the earliest next fire of any
    /// enabled routine. Nil when nothing is scheduled.
    public static func nextWake(routines: [Routine], now: Date, lastRuns: [String: Date], enabledSince: [String: Date],
                                calendar: Calendar) -> Date? {
        var best: Date?
        for r in routines where r.enabled {
            if case .manual = r.schedule { continue }
            if due(for: r, now: now, lastRun: lastRuns[r.id], enabledSince: enabledSince[r.id], calendar: calendar) != .none { return now }
            if let f = nextFire(for: r, after: now, lastRun: lastRuns[r.id], enabledSince: enabledSince[r.id], calendar: calendar),
               best == nil || f < best! { best = f }
        }
        return best
    }
}

// MARK: - Start decision and queue

public enum RoutineSkipReason: String, Equatable, Sendable {
    case stillRunning = "still running"
    case folderMissing = "folder missing"
    case hooksNotConnected = "hooks not connected"
    case queueOverflow = "queue overflow"
    case paused = "paused"
    /// The fire was too old to catch up (or catch-up is off).
    case missed = "missed"
}

public struct RoutineFacts: Equatable, Sendable {
    /// Runs of this very routine that are still working (a queued one counts too).
    public var runningOfRoutine: Int
    public var runningTotal: Int
    public var queueLength: Int
    public var folderExists: Bool
    public var hooksConnected: Bool

    public init(runningOfRoutine: Int = 0, runningTotal: Int = 0, queueLength: Int = 0, folderExists: Bool = true,
                hooksConnected: Bool = true) {
        self.runningOfRoutine = runningOfRoutine
        self.runningTotal = runningTotal
        self.queueLength = queueLength
        self.folderExists = folderExists
        self.hooksConnected = hooksConnected
    }
}

public enum RoutineDecision: Equatable, Sendable {
    case start
    /// Waits for a free slot; with a full queue the oldest waiting run is dropped.
    case queue(dropsOldest: Bool)
    case skip(RoutineSkipReason)
}

public enum RoutineRules {
    public static let maxConcurrent = 2
    public static let maxQueued = 5
    /// A run that waits this long for the person without a break is closed.
    public static let waitLimit: TimeInterval = 3600

    public static func decide(_ f: RoutineFacts) -> RoutineDecision {
        if f.runningOfRoutine > 0 { return .skip(.stillRunning) }
        if !f.folderExists { return .skip(.folderMissing) }
        if !f.hooksConnected { return .skip(.hooksNotConnected) }
        if f.runningTotal >= maxConcurrent { return .queue(dropsOldest: f.queueLength >= maxQueued) }
        return .start
    }
}

public enum RoutineWaitVerdict: Equatable, Sendable {
    case keep, expire
}

extension RoutineRules {
    /// Only a session started by a routine run is ever closed for waiting. Dates are compared, not ticks,
    /// so a sleeping Mac or a late timer gives the same answer.
    public static func waitVerdict(routineRun: Bool, waitingSince: Date?, now: Date, pending: Int) -> RoutineWaitVerdict {
        guard routineRun, pending > 0, let since = waitingSince else { return .keep }
        return now.timeIntervalSince(since) >= waitLimit ? .expire : .keep
    }
}

/// The continuous wait of one routine run: it starts when something is pending and resets when nothing is.
public struct RoutineWait: Equatable, Sendable {
    public private(set) var since: Date?

    public init() {}

    public mutating func update(pending: Int, now: Date) -> RoutineWaitVerdict {
        if pending == 0 { since = nil } else if since == nil { since = now }
        return RoutineRules.waitVerdict(routineRun: true, waitingSince: since, now: now, pending: pending)
    }
}

/// Routine ids waiting for a free slot, oldest first.
public struct RoutineQueue: Equatable, Sendable {
    public private(set) var ids: [String] = []

    public init() {}

    public var count: Int { ids.count }
    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Adds a run; with `maxQueued` already waiting the oldest is dropped and returned.
    @discardableResult
    public mutating func enqueue(_ id: String) -> String? {
        guard !ids.contains(id) else { return nil }
        ids.append(id)
        guard ids.count > RoutineRules.maxQueued else { return nil }
        return ids.removeFirst()
    }

    public mutating func next() -> String? { ids.isEmpty ? nil : ids.removeFirst() }

    public mutating func remove(_ id: String) { ids.removeAll { $0 == id } }
}

// MARK: - Log

public struct RoutineLogRecord: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case started, finished, failed, needsYou, expired
        case skipped(String)

        public var text: String {
            switch self {
            case .started: return "started"
            case .finished: return "finished"
            case .failed: return "failed"
            case .needsYou: return "needs you"
            case .expired: return "expired"
            case .skipped(let r): return "skipped:\(r)"
            }
        }

        public init?(text: String) {
            switch text {
            case "started": self = .started
            case "finished": self = .finished
            case "failed": self = .failed
            case "needs you": self = .needsYou
            case "expired": self = .expired
            default:
                guard text.hasPrefix("skipped:") else { return nil }
                self = .skipped(String(text.dropFirst("skipped:".count)))
            }
        }
    }

    public var time: Date
    public var routine: String
    public var outcome: Outcome
    public var session: String?
    public var durationSec: Int?
    public var costUSD: Double?

    public init(time: Date, routine: String, outcome: Outcome, session: String? = nil, durationSec: Int? = nil, costUSD: Double? = nil) {
        self.time = time
        self.routine = routine
        self.outcome = outcome
        self.session = session
        self.durationSec = durationSec
        self.costUSD = costUSD
    }

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// Only ids, times and numbers: no prompt or reply text.
    public func line() -> String {
        var o = JSONObject()
        o["time"] = .string(Self.formatter().string(from: time))
        o["routine"] = .string(routine)
        o["outcome"] = .string(outcome.text)
        if let s = session { o["session"] = .string(s) }
        if let d = durationSec { o["durationSec"] = .int(d) }
        if let c = costUSD { o["costUSD"] = .double(c) }
        return JSONValue.object(o).compact()
    }

    public init?(line: String) {
        guard let v = try? JSONValue.parse(line), v.objectValue != nil,
              let t = v["time"]?.stringValue, let date = Self.formatter().date(from: t),
              let r = v["routine"]?.stringValue, !r.isEmpty,
              let o = v["outcome"]?.stringValue, let outcome = Outcome(text: o) else { return nil }
        self.init(time: date, routine: r, outcome: outcome, session: v["session"]?.stringValue,
                  durationSec: v["durationSec"]?.intValue, costUSD: v["costUSD"]?.doubleValue)
    }
}

/// What the log says about one routine.
public struct RoutineHistory: Equatable, Sendable {
    /// When it last started.
    public var lastRun: Date?
    /// The last start or skip: the moment the schedule counts from.
    public var lastAttempt: Date?
    /// The newest record of any kind.
    public var last: RoutineLogRecord?

    public init(lastRun: Date? = nil, lastAttempt: Date? = nil, last: RoutineLogRecord? = nil) {
        self.lastRun = lastRun
        self.lastAttempt = lastAttempt
        self.last = last
    }
}

public enum RoutineLog {
    public static let maxLines = 500

    public static func parse(_ text: String) -> [RoutineLogRecord] {
        text.split(whereSeparator: \.isNewline).compactMap { RoutineLogRecord(line: String($0)) }
    }

    /// The newest `maxLines` non-empty lines.
    public static func trimmed(_ lines: [String]) -> [String] {
        Array(lines.filter { !$0.isEmpty }.suffix(maxLines))
    }

    /// File order is the order of events; it stays right when the clock was set back.
    public static func history(_ records: [RoutineLogRecord]) -> [String: RoutineHistory] {
        var out: [String: RoutineHistory] = [:]
        for r in records {
            var h = out[r.routine] ?? RoutineHistory()
            h.last = r
            switch r.outcome {
            case .started: h.lastRun = r.time; h.lastAttempt = r.time
            case .skipped: h.lastAttempt = r.time
            default: break
            }
            out[r.routine] = h
        }
        return out
    }

    public static func read(from url: URL) -> [RoutineLogRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Appends one line and keeps the file at its last `maxLines` lines.
    public static func append(_ record: RoutineLogRecord, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines: [String] = []
        if let data = try? Data(contentsOf: url) {
            lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        }
        lines.append(record.line())
        let kept = trimmed(lines)
        try? Data((kept.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }
}

// MARK: - Words

public enum RoutineText {
    public static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Every day at 09:00", "Mon–Fri at 18:30", "Every 4 hours", "Manual".
    public static func describe(_ s: RoutineSchedule) -> String {
        switch s {
        case .manual: return "Manual"
        case .every(let h): return h == 1 ? "Every hour" : "Every \(h) hours"
        case .daily(let h, let m, let days):
            let time = String(format: "%02d:%02d", h, m)
            let valid = days.filter { (1...7).contains($0) }
            if valid.isEmpty || valid.count == 7 { return "Every day at \(time)" }
            return "\(weekdays(valid)) at \(time)"
        }
    }

    /// Runs of three or more days become a range: "Mon–Fri", "Mon–Wed, Sat".
    static func weekdays(_ days: Set<Int>) -> String {
        let sorted = days.sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            if j - i >= 2 { parts.append("\(dayNames[sorted[i] - 1])–\(dayNames[sorted[j] - 1])") }
            else { for k in i...j { parts.append(dayNames[sorted[k] - 1]) } }
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    /// "Today 18:30", "Tomorrow 09:00", "Wed 09:00" within a week, "Dec 3, 09:00" beyond.
    public static func nextRun(_ date: Date, now: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<1: return "Today \(time)"
        case 1: return "Tomorrow \(time)"
        case 2..<7: return "\(dayNames[isoIndex(date, calendar)]) \(time)"
        default:
            let m = calendar.component(.month, from: date), d = calendar.component(.day, from: date)
            return "\(monthNames[m - 1]) \(d), \(time)"
        }
    }

    private static func isoIndex(_ date: Date, _ calendar: Calendar) -> Int { RoutineClock.isoWeekday(date, calendar: calendar) - 1 }

    /// The last outcome line of the list: "Finished 2 h ago", "Skipped: still running", "Never run".
    public static func lastOutcome(_ record: RoutineLogRecord?, running: Bool, now: Date, calendar: Calendar) -> String {
        if running { return "Running" }
        guard let r = record else { return "Never run" }
        let ago = SessionHistory.relativeTime(r.time, now: now, calendar: calendar)
        switch r.outcome {
        case .started: return "Started \(ago)"
        case .finished: return "Finished \(ago)"
        case .failed: return "Failed \(ago)"
        case .needsYou: return "Needed you \(ago)"
        case .expired: return "Closed: no answer"
        case .skipped(let why): return "Skipped: \(why)"
        }
    }
}
