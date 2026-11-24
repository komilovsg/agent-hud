import AgentHudCore
import AppKit
import Foundation

/// Developer check: `AgentHud --routines-check <dir>` runs the routine scheduler against a fake CLI (a small shell
/// script standing in for `claude`) with an injected clock. No real session is started, nothing waits for a real schedule
/// time, and everything it writes goes under `<dir>`. Prints one line per check and exits non-zero when one fails.
@MainActor
enum RoutinesCheck {
    private static let fakeCLI = """
    #!/bin/bash
    # Stands in for the CLI: reports a session, answers every message, and waits while the hold file exists.
    sid=""
    while [ $# -gt 0 ]; do
      case "$1" in --session-id|--resume) sid="$2"; shift ;; esac
      shift
    done
    echo "$(pwd -P)" >> "$FAKE_LOG"
    echo '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"fake"}'
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$FAKE_MSGS"
      while [ -e "$FAKE_HOLD" ]; do sleep 0.1; done
      echo '{"type":"assistant","uuid":"u1","message":{"id":"m1","content":[{"type":"text","text":"done"}]}}'
      echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"session_id":"'"$sid"'"}'
    done
    """

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    /// Lets the run loop work (pipes, timers of the sessions) in short steps until the condition holds.
    private static func pump(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private static func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }

    static func run(dir: String) -> Int32 {
        failures = 0
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        try? fm.removeItem(at: root)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-claude.sh")
        try? Data(fakeCLI.utf8).write(to: script)
        chmod(script.path, 0o755)
        let invoked = root.appendingPathComponent("invoked.log")
        let messages = root.appendingPathComponent("messages.log")
        let hold = root.appendingPathComponent("hold")
        setenv("AGENTHUD_SUPPORT_DIR", support.path, 1)
        setenv("AGENTHUD_CLAUDE_BIN", script.path, 1)
        setenv("FAKE_LOG", invoked.path, 1)
        setenv("FAKE_MSGS", messages.path, 1)
        setenv("FAKE_HOLD", hold.path, 1)

        let model = AppModel(settings: Settings())
        var hooksConnected = true
        model.refusalOverride = { hooksConnected ? nil : "Agent HUD is not connected to Claude Code." }
        let suite = "agenthud.routines.check"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let c = RoutineController(app: model, defaults: defaults)
        c.autoSchedule = false
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var clock = utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 8, minute: 0))!
        c.now = { clock }
        c.calendar = { utc }
        var notices: [String] = []
        c.postNotice = { title, _, _ in notices.append(title) }
        model.settings.routinesEnabled = true

        // What `pwd -P` prints: the physical path (Foundation's own resolver would drop the /private prefix).
        let workPath = realpath(work.path, nil).map { String(cString: $0) } ?? work.path
        func invocations() -> Int { lines(invoked).count }
        func outcomes(_ id: String) -> [String] { RoutineLog.read(from: c.logFile).filter { $0.routine == id }.map(\.outcome.text) }
        func add(_ r: Routine) { do { try c.save(r) } catch { check(false, "save \(r.id): \(error)") } }

        c.begin()
        check(c.routines.isEmpty && !fm.fileExists(atPath: c.file.path), "no routines file is created before the first save")

        // 1. A due routine starts a session in its folder with the prompt as the first message.
        let secret = "ALPHA-PROMPT-TEXT-7731"
        add(Routine(id: "alpha", name: "Alpha", prompt: secret, folder: work.path,
                    schedule: .daily(hour: 9, minute: 0, weekdays: [])))
        check(fm.fileExists(atPath: c.file.path), "the first save creates routines.json")
        c.evaluate()
        check(invocations() == 0, "nothing runs before its time")
        clock = utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 9, minute: 0, second: 20))!
        c.evaluate()
        check(pump(10) { outcomes("alpha").contains("finished") }, "due routine started and finished")
        check(lines(invoked) == [workPath], "session started in the routine's folder")
        check(lines(messages).count == 1 && lines(messages)[0].contains(secret), "prompt was the first message")
        check(model.owned.values.contains { $0.routineLabel == "Alpha" }, "its token is labelled with the routine name")
        check(outcomes("alpha") == ["started", "finished"], "log: started, finished (\(outcomes("alpha")))")
        let finished = RoutineLog.read(from: c.logFile).first { $0.outcome == .finished }
        check(finished?.session != nil && finished?.costUSD == 0.01, "finished record has the session id and the cost")
        check(notices.contains("Routine Alpha finished"), "notification: finished")
        clock = clock.addingTimeInterval(20)
        c.evaluate()
        check(invocations() == 1, "the same fire does not run twice")
        check(pump(5) { model.owned.values.allSatisfy { !$0.isLive } }, "the session process ended after its turn")

        // 2. Overlap: a routine whose previous run is still working is skipped.
        fm.createFile(atPath: hold.path, contents: Data())
        add(Routine(id: "beta", name: "Beta", prompt: "BETA-PROMPT", folder: work.path, schedule: .every(hours: 1)))
        let before = invocations()
        clock = clock.addingTimeInterval(3600)
        c.evaluate()
        check(pump(10) { invocations() == before + 1 }, "every-hour routine started")
        clock = clock.addingTimeInterval(3600)
        c.evaluate()
        check(outcomes("beta") == ["started", "skipped:still running"], "overlap skipped and recorded (\(outcomes("beta")))")
        check(invocations() == before + 1, "no second process for the skipped run")
        try? fm.removeItem(at: hold)
        check(pump(10) { outcomes("beta").contains("finished") }, "the first run finished once released")

        // 3. At most two at a time: the third waits and starts when a slot frees up.
        fm.createFile(atPath: hold.path, contents: Data())
        for id in ["c1", "c2", "c3"] { add(Routine(id: id, name: id.uppercased(), prompt: "C-PROMPT", folder: work.path, schedule: .manual)) }
        let base = invocations()
        c.runNow("c1")
        c.runNow("c2")
        let third = c.runNow("c3")
        check(pump(10) { invocations() == base + 2 }, "two routines run at once")
        check(third?.hasPrefix("Waiting") == true && c.queued == ["c3"], "the third is queued (\(third ?? "nil"))")
        check(outcomes("c3").isEmpty, "a queued run is not logged as started")
        try? fm.removeItem(at: hold)
        check(pump(15) { outcomes("c3").contains("finished") }, "the queued run started and finished")
        check(invocations() == base + 3 && c.queued.isEmpty, "three processes in all, queue empty")

        // 4. A missing folder is skipped and recorded.
        add(Routine(id: "gone", name: "Gone", prompt: "G-PROMPT", folder: "/nonexistent-routine-folder", schedule: .manual))
        let n4 = invocations()
        c.runNow("gone")
        check(outcomes("gone") == ["skipped:folder missing"] && invocations() == n4, "missing folder skipped and recorded (\(outcomes("gone")))")

        // 5. Hooks not connected: skipped, recorded, one notification.
        hooksConnected = false
        add(Routine(id: "nohooks", name: "NoHooks", prompt: "H-PROMPT", folder: work.path, schedule: .manual))
        let n5 = invocations()
        notices = []
        c.runNow("nohooks")
        check(outcomes("nohooks") == ["skipped:hooks not connected"] && invocations() == n5, "missing hooks skipped and recorded (\(outcomes("nohooks")))")
        check(notices == ["Routine NoHooks was skipped"], "one notification for the skipped run (\(notices))")
        hooksConnected = true

        // 6. A missed fire: caught up once when under 12 hours old, skipped when older.
        func day(_ d: Int, _ h: Int, _ m: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 6, day: d, hour: h, minute: m))! }
        add(Routine(id: "old", name: "Old", prompt: "O-PROMPT", folder: work.path, schedule: .daily(hour: 3, minute: 0, weekdays: [])))
        clock = day(11, 10, 30)                       // the 03:00 fire is 7.5 h old
        c.evaluate()
        check(pump(10) { outcomes("old").contains("finished") }, "a fire 7.5 h old is caught up (\(outcomes("old")))")
        let n6 = invocations()
        clock = day(12, 15, 30)                       // the next 03:00 fire is 12.5 h old
        c.evaluate()
        check(outcomes("old").last == "skipped:missed" && invocations() == n6, "a fire 12.5 h old is skipped and recorded (\(outcomes("old")))")
        let n7 = RoutineLog.read(from: c.logFile).count
        c.evaluate()
        check(RoutineLog.read(from: c.logFile).count == n7, "the schedule moved on: nothing more is due")

        // The log: expected shape and no prompt or reply text.
        let logText = (try? String(contentsOf: c.logFile, encoding: .utf8)) ?? ""
        let all = RoutineLog.read(from: c.logFile)
        check(all.count == logText.split(whereSeparator: \.isNewline).count, "every log line parses (\(all.count) records)")
        check(!["ALPHA-PROMPT", "BETA-PROMPT", "C-PROMPT", "G-PROMPT", "H-PROMPT", "O-PROMPT", "done"].contains { logText.contains($0) },
              "the log holds no prompt or reply text")

        model.stop()
        check(pump(5) { model.owned.values.allSatisfy { !$0.isLive } }, "no session process is left alive")
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.removeObject(forKey: "routinesEnabled")
        print(failures == 0 ? "routines check: all passed" : "routines check: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
