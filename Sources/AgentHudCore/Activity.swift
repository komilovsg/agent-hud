import Foundation

/// Activity log entry: a prompt, the end of a turn, a decision in the HUD.
/// The log is one file per day: `~/Library/Application Support/AgentHUD/activity/YYYY-MM-DD.jsonl`.
/// Local only; the daily summary (for standups) and the "Today" tab of the agent map are built from it.
public struct ActivityRecord: Equatable, Sendable {
    public enum Kind: String, Sendable { case prompt, stop, decision, ref }

    public var kind: Kind
    public var time: Date
    public var agent: String
    public var session: String
    public var project: String
    public var cwd: String
    /// A prompt, the agent's final message, the gist of a decision, or a branch/link (for `ref`).
    public var text: String
    /// For a decision - what was decided ("allowed", "denied"...); for `ref` - "branch" or "link".
    public var detail: String?
    public var failed = false
    public var stats: TurnStats?

    public init(kind: Kind, time: Date, agent: String, session: String, project: String, cwd: String,
                text: String, detail: String? = nil, failed: Bool = false, stats: TurnStats? = nil) {
        self.kind = kind
        self.time = time
        self.agent = agent
        self.session = session
        self.project = project
        self.cwd = cwd
        self.text = text
        self.detail = detail
        self.failed = failed
        self.stats = stats
    }

    public func toJSON() -> JSONValue {
        var o = JSONObject()
        o["kind"] = .string(kind.rawValue)
        o["t"] = .double(time.timeIntervalSince1970)
        o["agent"] = .string(agent)
        o["session"] = .string(session)
        o["project"] = .string(project)
        o["cwd"] = .string(cwd)
        o["text"] = .string(text)
        if let detail { o["detail"] = .string(detail) }
        if failed { o["failed"] = true }
        if let s = stats {
            var tools = JSONObject()
            for k in s.tools.keys.sorted() { tools[k] = .int(s.tools[k]!) }
            o["tools"] = .object(tools)
            if !s.files.isEmpty { o["files"] = .array(s.files.map { .string($0) }) }
            if s.subagents > 0 { o["subagents"] = .int(s.subagents) }
            if let d = s.durationSec { o["dur"] = .int(d) }
        }
        return .object(o)
    }

    public init?(json v: JSONValue) {
        guard let kind = v["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let t = v["t"]?.doubleValue else { return nil }
        self.kind = kind
        time = Date(timeIntervalSince1970: t)
        agent = v["agent"]?.stringValue ?? ""
        session = v["session"]?.stringValue ?? ""
        project = v["project"]?.stringValue ?? ""
        cwd = v["cwd"]?.stringValue ?? ""
        text = v["text"]?.stringValue ?? ""
        detail = v["detail"]?.stringValue
        failed = v["failed"]?.boolValue ?? false
        if let tools = v["tools"]?.objectValue {
            var d: [String: Int] = [:]
            for e in tools.entries { if let n = e.value.intValue { d[e.key] = n } }
            stats = TurnStats(tools: d, files: v["files"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                              subagents: v["subagents"]?.intValue ?? 0, durationSec: v["dur"]?.intValue)
        }
    }
}

public enum ActivityLog {
    public static var directory: URL { AgentHUDPaths.supportDirectory.appendingPathComponent("activity", isDirectory: true) }

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func file(for day: Date) -> URL { directory.appendingPathComponent(dayString(day) + ".jsonl") }

    public static func append(_ r: ActivityRecord) {
        let url = file(for: r.time)
        let line = r.toJSON().compact() + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    public static func read(day: Date) -> [ActivityRecord] {
        guard let text = try? String(contentsOf: file(for: day), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONValue.parse(String(line))).flatMap(ActivityRecord.init(json:))
        }
    }

    /// Entries of all days that intersect the interval, with `from <= time <= to`, by time.
    public static func read(from: Date, to: Date) -> [ActivityRecord] {
        guard from <= to else { return [] }
        let cal = Calendar.current
        var day = cal.startOfDay(for: from)
        var out: [ActivityRecord] = []
        var guardDays = 0
        while day <= to, guardDays < 400 {
            out += read(day: day).filter { $0.time >= from && $0.time <= to }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardDays += 1
        }
        return out.sorted { $0.time < $1.time }
    }
}

// MARK: - Daily summary

public struct DayTurn: Equatable, Sendable {
    public var session: String
    public var start: Date
    public var prompt: String
    public var end: Date?
    public var failed = false
    public var stats = TurnStats()
    public var message: String?
}

public struct DayProject: Equatable, Sendable {
    public var name: String
    public var cwd: String
    public var turns: [DayTurn] = []
    public var decisions: [String: Int] = [:]

    public var workedSec: Int { turns.reduce(0) { $0 + ($1.stats.durationSec ?? 0) } }
    public var edits: Int { turns.reduce(0) { $0 + $1.stats.edits } }
    public var commands: Int { turns.reduce(0) { $0 + $1.stats.commands } }
}

public enum DailySummary {
    /// Entries of a day -> projects with turns (prompt -> result), in order of first activity.
    public static func build(_ records: [ActivityRecord]) -> [DayProject] {
        var projects: [String: DayProject] = [:]
        var order: [String] = []
        var open: [String: (project: String, index: Int)] = [:]   // session -> unfinished turn

        func project(_ r: ActivityRecord) -> String {
            let key = r.cwd.isEmpty ? r.project : r.cwd
            if projects[key] == nil {
                projects[key] = DayProject(name: r.project, cwd: r.cwd)
                order.append(key)
            }
            return key
        }

        for r in records.sorted(by: { $0.time < $1.time }) {
            let key = project(r)
            switch r.kind {
            case .prompt:
                projects[key]!.turns.append(DayTurn(session: r.session, start: r.time, prompt: r.text))
                open[r.session] = (key, projects[key]!.turns.count - 1)
            case .stop:
                if let o = open[r.session] {
                    projects[o.project]!.turns[o.index].end = r.time
                    projects[o.project]!.turns[o.index].failed = r.failed
                    projects[o.project]!.turns[o.index].stats = r.stats ?? TurnStats()
                    projects[o.project]!.turns[o.index].message = r.text.isEmpty ? nil : r.text
                    open[r.session] = nil
                }
            case .decision:
                projects[key]!.decisions[r.detail ?? "decision", default: 0] += 1
            case .ref:
                break   // branches and links are collected by PeriodReport
            }
        }
        return order.compactMap { projects[$0] }.filter { !$0.turns.isEmpty || !$0.decisions.isEmpty }
    }

    public static func markdown(_ projects: [DayProject], day: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d, yyyy"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "HH:mm"

        var out = "# Daily summary · \(df.string(from: day))\n\n"
        guard !projects.isEmpty else { return out + "No agent activity on this day.\n" }

        let turns = projects.reduce(0) { $0 + $1.turns.count }
        let worked = projects.reduce(0) { $0 + $1.workedSec }
        let edits = projects.reduce(0) { $0 + $1.edits }
        let commands = projects.reduce(0) { $0 + $1.commands }
        let decisions = projects.reduce(0) { $0 + $1.decisions.values.reduce(0, +) }
        var total = "**Total:** \(turns) \(plural(turns, "task", "tasks")) in \(projects.count) \(plural(projects.count, "project", "projects"))"
        if worked > 0 { total += " · agents worked \(duration(worked))" }
        total += " · file edits: \(edits) · commands: \(commands)"
        if decisions > 0 { total += " · HUD decisions: \(decisions)" }
        out += total + "\n"

        for p in projects {
            out += "\n## \(p.name)\n\n"
            var line = "\(p.turns.count) \(plural(p.turns.count, "task", "tasks"))"
            if p.workedSec > 0 { line += " · \(duration(p.workedSec))" }
            line += " · edits: \(p.edits) · commands: \(p.commands)"
            out += line + "\n\n"
            for t in p.turns {
                let prompt = oneLine(t.prompt, 120)
                var status: String
                if t.end == nil { status = "not finished" }
                else if t.failed { status = "failed" }
                else { status = "done" + (t.stats.durationSec.map { " in \(duration($0))" } ?? "") }
                var counters: [String] = []
                if t.stats.edits > 0 { counters.append("edits \(t.stats.edits)") }
                if t.stats.commands > 0 { counters.append("commands \(t.stats.commands)") }
                if t.stats.subagents > 0 { counters.append("subagents \(t.stats.subagents)") }
                if !counters.isEmpty { status += " · " + counters.joined(separator: " · ") }
                out += "- **\(tf.string(from: t.start))** \(prompt.isEmpty ? "(no text)" : prompt) — \(status)\n"
                if let m = t.message, !m.isEmpty { out += "  - Result: \(oneLine(m, 200))\n" }
                if !t.stats.files.isEmpty {
                    let names = t.stats.files.prefix(4).map { ($0 as NSString).lastPathComponent }
                    out += "  - Files: \(names.joined(separator: ", "))" + (t.stats.files.count > 4 ? " +\(t.stats.files.count - 4)" : "") + "\n"
                }
            }
            if !p.decisions.isEmpty {
                let d = p.decisions.keys.sorted().map { "\($0) \(p.decisions[$0]!)" }.joined(separator: " · ")
                out += "\nHUD decisions: \(d)\n"
            }
        }
        return out
    }

    public static func duration(_ sec: Int) -> String {
        if sec < 60 { return "\(sec) s" }
        if sec < 3600 { return "\(sec / 60) min" }
        return "\(sec / 3600) h \(String(format: "%02d", sec % 3600 / 60)) min"
    }

    public static func plural(_ n: Int, _ one: String, _ other: String) -> String {
        n == 1 ? one : other
    }

    static func oneLine(_ s: String, _ max: Int) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }
}

// MARK: - Period report

public struct PeriodProject: Equatable, Sendable {
    public var project: DayProject
    public var branches: [String] = []
    public var links: [String] = []
}

/// Interval presets; `now` and the calendar are passed in from outside.
public enum ReportPreset: CaseIterable, Sendable {
    case since15Yesterday, today, yesterday, week

    public var title: String {
        switch self {
        case .since15Yesterday: return "Since 15:00 yesterday"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "Last 7 days"
        }
    }

    public func range(now: Date, calendar cal: Calendar) -> (from: Date, to: Date) {
        let today = cal.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today) ?? today }
        switch self {
        case .since15Yesterday:
            return (cal.date(bySettingHour: 15, minute: 0, second: 0, of: daysAgo(1)) ?? daysAgo(1), now)
        case .today: return (today, now)
        case .yesterday: return (daysAgo(1), today.addingTimeInterval(-1))
        case .week: return (daysAgo(6), now)
        }
    }
}

public enum PeriodReport {
    /// Entries -> projects over the interval. Entries must include the prompts of turns started before `from`
    /// (see `load`): a turn started earlier but finished inside the interval makes it into the report.
    public static func build(_ records: [ActivityRecord], from: Date? = nil, to: Date? = nil) -> [PeriodProject] {
        func inRange(_ d: Date) -> Bool { (from.map { d >= $0 } ?? true) && (to.map { d <= $0 } ?? true) }
    // Decisions and links are counted only inside the interval; prompts and stops are needed to match turns.
        let recs = records.filter { $0.kind == .prompt || $0.kind == .stop || inRange($0.time) }
        var result: [PeriodProject] = []
        for var p in DailySummary.build(recs) {
            p.turns = p.turns.filter { inRange($0.start) || ($0.end.map(inRange) ?? false) }
            let key = p.cwd.isEmpty ? p.name : p.cwd
            var item = PeriodProject(project: p)
            for r in recs where r.kind == .ref && (r.cwd.isEmpty ? r.project : r.cwd) == key {
                if r.detail == "link" { if !item.links.contains(r.text) { item.links.append(r.text) } }
                else if !item.branches.contains(r.text) { item.branches.append(r.text) }
            }
            if !p.turns.isEmpty { result.append(item) }
        }
        return result
    }

    /// Reads the log with a margin backwards (prompts of turns started before `from`) and builds the report.
    public static func load(from: Date, to: Date) -> [PeriodProject] {
        let lookback = from.addingTimeInterval(-24 * 3600)
        return build(ActivityLog.read(from: lookback, to: to), from: from, to: to)
    }

    public static func markdown(_ projects: [PeriodProject], from: Date, to: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d, HH:mm"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "HH:mm"
        let multiDay = !Calendar.current.isDate(from, inSameDayAs: to)

        var out = "# Agent report · \(df.string(from: from)) — \(df.string(from: to))\n\n"
        guard !projects.isEmpty else { return out + "No agent activity in this period.\n" }

        let turns = projects.reduce(0) { $0 + $1.project.turns.count }
        let worked = projects.reduce(0) { $0 + $1.project.workedSec }
        var total = "**Total:** \(turns) \(DailySummary.plural(turns, "task", "tasks")) in \(projects.count) \(DailySummary.plural(projects.count, "project", "projects"))"
        if worked > 0 { total += " · agents worked \(DailySummary.duration(worked))" }
        out += total + "\n"

        for item in projects {
            let p = item.project
            out += "\n## \(p.name)\n\n"
            var line = "\(p.turns.count) \(DailySummary.plural(p.turns.count, "task", "tasks"))"
            if p.workedSec > 0 { line += " · \(DailySummary.duration(p.workedSec))" }
            out += line + "\n"
            if !item.branches.isEmpty { out += "\nBranches: " + item.branches.map { "`\($0)`" }.joined(separator: ", ") + "\n" }
            if !item.links.isEmpty { out += "\nLinks:\n" + item.links.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            out += "\n"
            for t in p.turns {
                let prompt = DailySummary.oneLine(t.prompt, 120)
                var status: String
                if t.end == nil { status = "not finished" }
                else if t.failed { status = "failed" }
                else { status = "done" + (t.stats.durationSec.map { " in \(DailySummary.duration($0))" } ?? "") }
                let when = multiDay ? df.string(from: t.start) : tf.string(from: t.start)
                out += "- **\(when)** \(prompt.isEmpty ? "(no text)" : prompt) — \(status)\n"
            }
        }
        return out
    }
}
