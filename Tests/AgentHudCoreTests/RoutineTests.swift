import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Routines: model, file, schedule math, start decision, log

@Suite struct RoutineTests {
    typealias C = RoutineClock

    static func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    let berlin = RoutineTests.calendar("Europe/Berlin")
    let utc = RoutineTests.calendar("UTC")

    /// "2026-03-29 03:00" in the calendar's zone.
    func at(_ s: String, _ cal: Calendar? = nil) -> Date {
        let cal = cal ?? berlin
        let p = s.split(whereSeparator: { " -:".contains($0) }).map { Int($0)! }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4]))!
    }

    func clock(_ d: Date, _ cal: Calendar? = nil) -> String {
        let cal = cal ?? berlin
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    func daily(_ time: String, _ days: Set<Int> = [], enabled: Bool = true, catchUp: Bool = true) -> Routine {
        let (h, m) = RoutineSchedule.parseTime(time)!
        return Routine(id: "r", name: "R", prompt: "p", enabled: enabled, schedule: .daily(hour: h, minute: m, weekdays: days), catchUp: catchUp)
    }

    func every(_ hours: Int) -> Routine { Routine(id: "e", name: "E", prompt: "p", schedule: .every(hours: hours)) }

    // MARK: Daily

    @Test func laterTodayAndTomorrow() {
        let r = daily("18:30")
        #expect(clock(C.nextFire(for: r, after: at("2026-06-10 09:00"), lastRun: nil, calendar: berlin)!) == "2026-06-10 18:30")
        #expect(clock(C.nextFire(for: r, after: at("2026-06-10 18:30"), lastRun: nil, calendar: berlin)!) == "2026-06-11 18:30")
        #expect(clock(C.nextFire(for: r, after: at("2026-06-10 23:59"), lastRun: nil, calendar: berlin)!) == "2026-06-11 18:30")
    }

    @Test func weekdaySetAcrossAWeekBoundary() {
        // Mon-Fri at 18:30. 2026-06-12 is a Friday, 2026-06-14 a Sunday.
        let r = daily("18:30", [1, 2, 3, 4, 5])
        #expect(C.isoWeekday(at("2026-06-12 10:00"), calendar: berlin) == 5)
        #expect(C.isoWeekday(at("2026-06-14 10:00"), calendar: berlin) == 7)
        #expect(clock(C.nextFire(for: r, after: at("2026-06-12 19:00"), lastRun: nil, calendar: berlin)!) == "2026-06-15 18:30")
        #expect(clock(C.nextFire(for: r, after: at("2026-06-13 08:00"), lastRun: nil, calendar: berlin)!) == "2026-06-15 18:30")
        #expect(clock(C.nextFire(for: r, after: at("2026-06-14 08:00"), lastRun: nil, calendar: berlin)!) == "2026-06-15 18:30")
        // Sunday only: from Monday the next one is six days away.
        let sun = daily("07:00", [7])
        #expect(clock(C.nextFire(for: sun, after: at("2026-06-08 08:00"), lastRun: nil, calendar: berlin)!) == "2026-06-14 07:00")
        // Sunday + Monday: the week boundary in the middle of the set.
        let both = daily("07:00", [7, 1])
        #expect(clock(C.nextFire(for: both, after: at("2026-06-14 08:00"), lastRun: nil, calendar: berlin)!) == "2026-06-15 07:00")
    }

    @Test func manualHasNoFire() {
        let r = Routine(id: "m", name: "M", prompt: "p", schedule: .manual)
        #expect(C.nextFire(for: r, after: Date(), lastRun: nil, calendar: berlin) == nil)
    }

    // MARK: DST (Europe/Berlin: 2026-03-29 02:00 -> 03:00, 2026-10-25 03:00 -> 02:00)

    /// All fires of a routine between two instants, by chaining `nextFire`.
    func fires(_ r: Routine, from: Date, to: Date) -> [Date] {
        var out: [Date] = []
        var t = from
        while let f = C.nextFire(for: r, after: t, lastRun: nil, calendar: berlin), f <= to {
            out.append(f)
            t = f
            if out.count > 50 { break }
        }
        return out
    }

    @Test func springForwardDayRunsExactlyOnce() {
        let r = daily("02:30")
        let all = fires(r, from: at("2026-03-28 12:00"), to: at("2026-03-30 12:00"))
        // One fire per day, three days of the window hold two: the 29th (the time does not exist) and the 30th.
        #expect(all.count == 2)
        let day29 = all.filter { berlin.isDate($0, inSameDayAs: at("2026-03-29 12:00")) }
        #expect(day29.count == 1)
        // The first moment after the gap.
        #expect(clock(day29[0]).hasPrefix("2026-03-29 03:"))
        #expect(clock(all[1]) == "2026-03-30 02:30")
    }

    @Test func fallBackDayRunsExactlyOnce() {
        let r = daily("02:30")
        let all = fires(r, from: at("2026-10-24 12:00"), to: at("2026-10-26 12:00"))
        #expect(all.count == 2)
        let day25 = all.filter { berlin.isDate($0, inSameDayAs: at("2026-10-25 12:00")) }
        #expect(day25.count == 1)
        // The first of the two 02:30 (still summer time, +02:00), not the second one an hour later.
        #expect(day25[0] == Date(timeIntervalSince1970: ISO8601DateFormatter().date(from: "2026-10-25T00:30:00Z")!.timeIntervalSince1970))
        #expect(clock(all[1]) == "2026-10-26 02:30")
    }

    @Test func dstDayCatchUpIsOneRun() {
        let r = daily("02:30")
        // The app wakes up at 08:00 on the spring-forward day; yesterday's run was the last one.
        let last = at("2026-03-28 02:30")
        let fire = C.missedFire(for: r, now: at("2026-03-29 08:00"), lastRun: last, calendar: berlin)!
        #expect(clock(fire).hasPrefix("2026-03-29 03:"))
        // After that run nothing more is missed on that day.
        #expect(C.missedFire(for: r, now: at("2026-03-29 23:00"), lastRun: fire, calendar: berlin) == nil)
        // Same on the fall-back day, even when "now" is already in the second 02:xx hour.
        let last2 = at("2026-10-24 02:30")
        let f2 = C.missedFire(for: r, now: at("2026-10-25 08:00"), lastRun: last2, calendar: berlin)!
        #expect(C.missedFire(for: r, now: at("2026-10-25 08:00"), lastRun: f2, calendar: berlin) == nil)
        #expect(clock(C.nextFire(for: r, after: f2, lastRun: f2, calendar: berlin)!) == "2026-10-26 02:30")
    }

    @Test func timeZoneChange() {
        let r = daily("09:00")
        let now = Date(timeIntervalSince1970: 1_781_000_000)
        let tokyo = RoutineTests.calendar("Asia/Tokyo")
        let ny = RoutineTests.calendar("America/New_York")
        let a = C.nextFire(for: r, after: now, lastRun: nil, calendar: tokyo)!
        let b = C.nextFire(for: r, after: now, lastRun: nil, calendar: ny)!
        // Local 09:00 in each zone, and the instants differ.
        #expect(clock(a, tokyo).hasSuffix("09:00"))
        #expect(clock(b, ny).hasSuffix("09:00"))
        #expect(a != b)
        // Within a day of "now" in both cases.
        #expect(a.timeIntervalSince(now) > 0 && a.timeIntervalSince(now) <= 86400)
        #expect(b.timeIntervalSince(now) > 0 && b.timeIntervalSince(now) <= 86400)
    }

    // MARK: Every N hours

    @Test func everyFromLastRunAndFromEnabling() {
        let r = every(4)
        let now = at("2026-06-10 11:00")
        #expect(clock(C.nextFire(for: r, after: now, lastRun: at("2026-06-10 10:00"), calendar: berlin)!) == "2026-06-10 14:00")
        #expect(clock(C.nextFire(for: r, after: now, lastRun: nil, enabledSince: at("2026-06-10 09:30"), calendar: berlin)!) == "2026-06-10 13:30")
        // The later of the two counts: enabled again after the last run.
        #expect(clock(C.nextFire(for: r, after: now, lastRun: at("2026-06-09 08:00"), enabledSince: at("2026-06-10 10:30"), calendar: berlin)!) == "2026-06-10 14:30")
        // Neither: counted from now.
        #expect(clock(C.nextFire(for: r, after: now, lastRun: nil, calendar: berlin)!) == "2026-06-10 15:00")
        // Overdue: rolls forward by whole periods.
        #expect(clock(C.nextFire(for: r, after: at("2026-06-10 20:00"), lastRun: at("2026-06-10 10:00"), calendar: berlin)!) == "2026-06-10 22:00")
    }

    @Test func everyIsDueAfterItsPeriod() {
        let r = every(2)
        let last = at("2026-06-10 10:00")
        #expect(C.due(for: r, now: at("2026-06-10 11:59"), lastRun: last, calendar: berlin) == .none)
        #expect(C.due(for: r, now: at("2026-06-10 12:00"), lastRun: last, calendar: berlin) == .run(fire: at("2026-06-10 12:00"), catchUp: false))
    }

    // MARK: Catch-up

    @Test func catchUpBoundaryAtTwelveHours() {
        let r = daily("09:00")
        let last = at("2026-06-09 09:00")
        // Fire 2026-06-10 09:00. 11:59:59 later it is caught up, 12:00:00 later it is skipped.
        let fire = at("2026-06-10 09:00")
        #expect(C.due(for: r, now: fire.addingTimeInterval(12 * 3600 - 1), lastRun: last, calendar: berlin) == .run(fire: fire, catchUp: true))
        #expect(C.due(for: r, now: fire.addingTimeInterval(12 * 3600), lastRun: last, calendar: berlin) == .missed(fire: fire))
        #expect(C.due(for: r, now: fire.addingTimeInterval(13 * 3600), lastRun: last, calendar: berlin) == .missed(fire: fire))
    }

    @Test func slackAroundTheFireTimeIsOnTime() {
        let off = daily("09:00", catchUp: false)
        let fire = at("2026-06-10 09:00")
        let last = at("2026-06-09 09:00")
        #expect(C.due(for: off, now: fire.addingTimeInterval(-1), lastRun: last, calendar: berlin) == .none)
        #expect(C.due(for: off, now: fire, lastRun: last, calendar: berlin) == .run(fire: fire, catchUp: false))
        #expect(C.due(for: off, now: fire.addingTimeInterval(C.onTimeGrace), lastRun: last, calendar: berlin) == .run(fire: fire, catchUp: false))
        // Beyond the slack, with catch-up off, the fire is skipped.
        #expect(C.due(for: off, now: fire.addingTimeInterval(C.onTimeGrace + 1), lastRun: last, calendar: berlin) == .missed(fire: fire))
    }

    @Test func severalMissedFiresGiveOneRun() {
        let r = daily("09:00")
        // Last run five days ago; now 09:05 after the app was closed: one due fire, the latest one.
        let now = at("2026-06-10 09:05")
        let d = C.due(for: r, now: now, lastRun: at("2026-06-05 09:00"), calendar: berlin)
        #expect(d == .run(fire: at("2026-06-10 09:00"), catchUp: true))
        // Once a run is recorded at "now", nothing else is due.
        #expect(C.due(for: r, now: now, lastRun: now, calendar: berlin) == .none)
        // Every N hours: a week of missed periods is one fire too.
        let e = every(3)
        let d2 = C.due(for: e, now: at("2026-06-10 09:00"), lastRun: at("2026-06-03 09:00"), calendar: berlin)
        #expect(d2 == .missed(fire: at("2026-06-03 12:00")))
        let d3 = C.due(for: e, now: at("2026-06-03 20:00"), lastRun: at("2026-06-03 09:00"), calendar: berlin)
        #expect(d3 == .run(fire: at("2026-06-03 12:00"), catchUp: true))
    }

    @Test func newRoutineDoesNotRunForThePast() {
        let r = daily("09:00")
        // Created at 10:00: this morning's 09:00 is not missed.
        #expect(C.due(for: r, now: at("2026-06-10 10:30"), lastRun: nil, enabledSince: at("2026-06-10 10:00"), calendar: berlin) == .none)
        #expect(C.due(for: r, now: at("2026-06-11 09:00"), lastRun: nil, enabledSince: at("2026-06-10 10:00"), calendar: berlin)
                == .run(fire: at("2026-06-11 09:00"), catchUp: false))
        // No reference at all: nothing is invented.
        #expect(C.due(for: r, now: at("2026-06-10 10:30"), lastRun: nil, calendar: berlin) == .none)
    }

    @Test func clockSetBackDoesNotFreezeTheRoutine() {
        let r = every(2)
        // The last run is "in the future" after the clock was set back: counted from now, not from the future.
        let now = at("2026-06-10 10:00")
        #expect(C.nextFire(for: r, after: now, lastRun: at("2026-06-20 10:00"), calendar: berlin) == now.addingTimeInterval(2 * 3600))
    }

    @Test func disabledAndManualAreNeverDue() {
        let off = daily("09:00", enabled: false)
        #expect(C.due(for: off, now: at("2026-06-10 09:30"), lastRun: at("2026-06-01 09:00"), calendar: berlin) == .none)
        var m = Routine(id: "m", name: "M", prompt: "p", schedule: .manual)
        #expect(C.due(for: m, now: at("2026-06-10 09:30"), lastRun: at("2026-06-01 09:00"), enabledSince: at("2026-05-01 09:00"), calendar: berlin) == .none)
        m.enabled = false
        #expect(C.nextWake(routines: [off, m], now: at("2026-06-10 09:30"), lastRuns: [:], enabledSince: [:], calendar: berlin) == nil)
    }

    @Test func nextWakeIsTheEarliestFire() {
        let a = Routine(id: "a", name: "A", prompt: "p", schedule: .daily(hour: 18, minute: 0, weekdays: []))
        let b = Routine(id: "b", name: "B", prompt: "p", schedule: .daily(hour: 12, minute: 0, weekdays: []))
        let now = at("2026-06-10 10:00")
        let since = ["a": at("2026-06-10 08:00"), "b": at("2026-06-10 08:00")]
        #expect(clock(C.nextWake(routines: [a, b], now: now, lastRuns: [:], enabledSince: since, calendar: berlin)!) == "2026-06-10 12:00")
        // Something due now wakes now.
        let late = at("2026-06-10 12:00")
        #expect(C.nextWake(routines: [a, b], now: late, lastRuns: [:], enabledSince: since, calendar: berlin) == late)
    }

    // MARK: Start decision and queue

    @Test func decisionOrder() {
        let ok = RoutineFacts()
        #expect(RoutineRules.decide(ok) == .start)
        #expect(RoutineRules.decide(RoutineFacts(runningOfRoutine: 1)) == .skip(.stillRunning))
        #expect(RoutineRules.decide(RoutineFacts(folderExists: false)) == .skip(.folderMissing))
        #expect(RoutineRules.decide(RoutineFacts(hooksConnected: false)) == .skip(.hooksNotConnected))
        // Two at once are allowed, the third waits.
        #expect(RoutineRules.decide(RoutineFacts(runningTotal: 1)) == .start)
        #expect(RoutineRules.decide(RoutineFacts(runningTotal: 2)) == .queue(dropsOldest: false))
        #expect(RoutineRules.decide(RoutineFacts(runningTotal: 2, queueLength: 4)) == .queue(dropsOldest: false))
        #expect(RoutineRules.decide(RoutineFacts(runningTotal: 2, queueLength: 5)) == .queue(dropsOldest: true))
        // A skip beats the queue: a missing folder is never queued.
        #expect(RoutineRules.decide(RoutineFacts(runningTotal: 2, folderExists: false)) == .skip(.folderMissing))
        #expect(RoutineRules.decide(RoutineFacts(runningOfRoutine: 1, runningTotal: 2, queueLength: 5)) == .skip(.stillRunning))
    }

    @Test func queueKeepsFiveAndDropsTheOldest() {
        var q = RoutineQueue()
        for i in 1...5 { #expect(q.enqueue("r\(i)") == nil) }
        #expect(q.count == 5)
        #expect(q.enqueue("r5") == nil)             // already waiting
        #expect(q.enqueue("r6") == "r1")
        #expect(q.ids == ["r2", "r3", "r4", "r5", "r6"])
        #expect(q.next() == "r2")
        q.remove("r4")
        #expect(q.ids == ["r3", "r5", "r6"])
        var empty = RoutineQueue()
        #expect(empty.next() == nil)
    }

    // MARK: Words

    @Test func scheduleDescriptions() {
        typealias T = RoutineText
        #expect(T.describe(.daily(hour: 9, minute: 0, weekdays: [])) == "Every day at 09:00")
        #expect(T.describe(.daily(hour: 9, minute: 0, weekdays: Set(1...7))) == "Every day at 09:00")
        #expect(T.describe(.daily(hour: 18, minute: 30, weekdays: Set(1...5))) == "Mon–Fri at 18:30")
        #expect(T.describe(.daily(hour: 8, minute: 5, weekdays: [1, 3, 5])) == "Mon, Wed, Fri at 08:05")
        #expect(T.describe(.daily(hour: 8, minute: 5, weekdays: [6, 7])) == "Sat, Sun at 08:05")
        #expect(T.describe(.daily(hour: 8, minute: 5, weekdays: [1, 2, 3, 6])) == "Mon–Wed, Sat at 08:05")
        #expect(T.describe(.every(hours: 4)) == "Every 4 hours")
        #expect(T.describe(.every(hours: 1)) == "Every hour")
        #expect(T.describe(.manual) == "Manual")
    }

    @Test func nextRunWords() {
        let now = at("2026-06-10 10:00")   // Wednesday
        #expect(RoutineText.nextRun(at("2026-06-10 18:30"), now: now, calendar: berlin) == "Today 18:30")
        #expect(RoutineText.nextRun(at("2026-06-11 09:00"), now: now, calendar: berlin) == "Tomorrow 09:00")
        #expect(RoutineText.nextRun(at("2026-06-13 09:00"), now: now, calendar: berlin) == "Sat 09:00")
        #expect(RoutineText.nextRun(at("2026-07-03 09:00"), now: now, calendar: berlin) == "Jul 3, 09:00")
    }

    @Test func lastOutcomeWords() {
        let now = at("2026-06-10 10:00")
        func text(_ o: RoutineLogRecord.Outcome?, running: Bool = false) -> String {
            RoutineText.lastOutcome(o.map { RoutineLogRecord(time: now.addingTimeInterval(-7200), routine: "r", outcome: $0) },
                                    running: running, now: now, calendar: berlin)
        }
        #expect(text(nil) == "Never run")
        #expect(text(.finished) == "Finished 2 h ago")
        #expect(text(.failed) == "Failed 2 h ago")
        #expect(text(.skipped("still running")) == "Skipped: still running")
        #expect(text(.expired) == "Closed: no answer")
        #expect(text(.finished, running: true) == "Running")
    }

    // MARK: Waiting too long

    @Test func waitVerdictAroundTheLimit() {
        let t = at("2026-06-10 10:00")
        func v(_ after: TimeInterval, pending: Int = 1, routine: Bool = true, since: Date? = nil) -> RoutineWaitVerdict {
            RoutineRules.waitVerdict(routineRun: routine, waitingSince: since ?? t, now: t.addingTimeInterval(after), pending: pending)
        }
        #expect(RoutineRules.waitLimit == 3600)
        #expect(v(3599) == .keep)
        #expect(v(3600) == .expire)
        #expect(v(3600 * 5) == .expire)
        #expect(v(7200, pending: 0) == .keep)
        #expect(v(7200, routine: false) == .keep)
        #expect(RoutineRules.waitVerdict(routineRun: true, waitingSince: nil, now: t, pending: 1) == .keep)
    }

    @Test func waitRestartsAfterAnAnswer() {
        let t = at("2026-06-10 10:00")
        var w = RoutineWait()
        #expect(w.update(pending: 1, now: t) == .keep)
        #expect(w.update(pending: 2, now: t.addingTimeInterval(3000)) == .keep)    // a second request does not restart it
        #expect(w.update(pending: 0, now: t.addingTimeInterval(3500)) == .keep)    // answered: the clock is gone
        #expect(w.since == nil)
        #expect(w.update(pending: 1, now: t.addingTimeInterval(3600)) == .keep)    // a new wait starts here
        #expect(w.update(pending: 1, now: t.addingTimeInterval(3600 + 3599)) == .keep)
        #expect(w.update(pending: 1, now: t.addingTimeInterval(3600 + 3600)) == .expire)
    }

    @Test func waitCountsDatesAcrossASleep() {
        let t = at("2026-06-10 10:00")
        var w = RoutineWait()
        #expect(w.update(pending: 1, now: t) == .keep)
        #expect(w.update(pending: 1, now: t.addingTimeInterval(8 * 3600)) == .expire)   // the next tick after a night asleep
    }

    // MARK: File

    func decode(_ json: String) -> RoutineSet { RoutineSet.decode(Data(json.utf8)) }

    static let good = """
    {"version": 1, "routines": [
      {"id": "morning", "name": "Morning report", "prompt": "Summarise the open pull requests", "folder": "/Users/dev/acme",
       "enabled": true, "schedule": {"kind": "daily", "time": "09:00", "weekdays": [1,2,3,4,5]}, "catchUp": true, "notify": false},
      {"id": "poll", "name": "Poll", "prompt": "Check the build", "schedule": {"kind": "every", "hours": 4}},
      {"id": "once", "name": "Once", "prompt": "Do it", "schedule": {"kind": "manual"}, "color": "red"}
    ], "note": "mine"}
    """

    @Test func loadsAValidFile() {
        let s = decode(Self.good)
        #expect(s.problems.isEmpty)
        #expect(!s.unreadable)
        #expect(s.routines.map(\.id) == ["morning", "poll", "once"])
        let m = s.routines[0]
        #expect(m.schedule == .daily(hour: 9, minute: 0, weekdays: Set(1...5)))
        #expect(m.folder == "/Users/dev/acme" && m.notify == false && m.catchUp == true && m.enabled == true)
        // Defaults: folder empty, everything on.
        let p = s.routines[1]
        #expect(p.folder == "" && p.enabled && p.catchUp && p.notify)
        #expect(p.schedule == .every(hours: 4))
    }

    @Test func invalidRoutinesAreSkippedWithAProblem() {
        let s = decode("""
        {"version": 1, "routines": [
          {"id": "ok", "name": "Ok", "prompt": "p", "schedule": {"kind": "manual"}},
          {"id": "bad-time", "name": "A", "prompt": "p", "schedule": {"kind": "daily", "time": "25:00"}},
          {"id": "bad-time2", "name": "A", "prompt": "p", "schedule": {"kind": "daily", "time": "9:00"}},
          {"id": "no-prompt", "name": "A", "prompt": "   ", "schedule": {"kind": "manual"}},
          {"prompt": "p", "schedule": {"kind": "manual"}},
          {"id": "kind", "name": "A", "prompt": "p", "schedule": {"kind": "weekly"}},
          {"id": "ok", "name": "Dup", "prompt": "p", "schedule": {"kind": "manual"}},
          {"id": "hours", "name": "A", "prompt": "p", "schedule": {"kind": "every", "hours": 25}},
          {"id": "hours0", "name": "A", "prompt": "p", "schedule": {"kind": "every", "hours": 0}},
          {"id": "days", "name": "A", "prompt": "p", "schedule": {"kind": "daily", "time": "09:00", "weekdays": [0]}},
          {"id": "rel", "name": "A", "prompt": "p", "folder": "src", "schedule": {"kind": "manual"}},
          {"id": "flag", "name": "A", "prompt": "p", "enabled": "yes", "schedule": {"kind": "manual"}},
          {"id": "Bad Id", "name": "A", "prompt": "p", "schedule": {"kind": "manual"}},
          {"id": "nosched", "name": "A", "prompt": "p"},
          42
        ]}
        """)
        #expect(s.routines.map(\.id) == ["ok"])
        #expect(s.problems.count == 14)
        #expect(!s.unreadable)
        for id in ["bad-time", "bad-time2", "no-prompt", "kind", "hours", "hours0", "days", "rel", "flag", "nosched"] {
            #expect(s.problems.contains { $0.hasPrefix("Routine \(id):") }, "no problem for \(id)")
        }
        #expect(s.problems.contains { $0.hasPrefix("Routine ok:") && $0.contains("used twice") })
        #expect(s.problems.contains { $0.hasPrefix("Routine #5:") })     // no id: named by position
        #expect(s.problems.contains { $0.hasPrefix("Routine #15:") })    // not an object
    }

    @Test func promptLimit() {
        let long = String(repeating: "x", count: 4001)
        let ok = String(repeating: "x", count: 4000)
        func entry(_ p: String) -> String { "{\"version\":1,\"routines\":[{\"id\":\"a\",\"name\":\"A\",\"prompt\":\"\(p)\",\"schedule\":{\"kind\":\"manual\"}}]}" }
        #expect(decode(entry(ok)).routines.count == 1)
        #expect(decode(entry(long)).routines.isEmpty)
        #expect(Routine(id: "a", name: "A", prompt: long).problems().contains { $0.contains("1 characters over") })
        #expect(Routine(id: "a", name: "A", prompt: ok).problems().isEmpty)
    }

    @Test func brokenFilesGiveNoRoutinesAndAProblem() {
        let syntax = decode("{\"version\": 1, \"routines\": [")
        #expect(syntax.routines.isEmpty && syntax.unreadable && syntax.problems.count == 1)
        let shape = decode("[1, 2]")
        #expect(shape.routines.isEmpty && shape.unreadable && shape.problems.count == 1)
        let noArray = decode("{\"version\": 1}")
        #expect(noArray.unreadable && noArray.problems.first?.contains("no routines array") == true)
        let future = decode("{\"version\": 2, \"routines\": []}")
        #expect(future.unreadable && future.problems.first?.contains("version") == true)
        // An empty list is fine, and so is a missing version.
        let empty = decode("{\"routines\": []}")
        #expect(!empty.unreadable && empty.problems.isEmpty && empty.routines.isEmpty)
    }

    func tempFile(_ name: String = "routines.json") -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("routines-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent(name), { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func missingFileIsNotCreated() {
        let (url, cleanup) = tempFile()
        defer { cleanup() }
        let s = RoutineSet.load(from: url)
        #expect(s.routines.isEmpty && s.problems.isEmpty && !s.unreadable)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aBrokenFileIsNeverTouchedOrOverwritten() throws {
        let (url, cleanup) = tempFile()
        defer { cleanup() }
        let text = "{\"routines\": [ oops"
        try Data(text.utf8).write(to: url)
        let s = RoutineSet.load(from: url)
        #expect(s.unreadable)
        #expect((try? String(contentsOf: url, encoding: .utf8)) == text)
        #expect(throws: RoutineSet.SaveError.unreadableFile) { try s.save(to: url) }
        #expect((try? String(contentsOf: url, encoding: .utf8)) == text)
    }

    @Test func saveKeepsUnknownFieldsAndSkippedEntries() throws {
        let (url, cleanup) = tempFile()
        defer { cleanup() }
        let text = """
        {"version": 1, "routines": [
          {"id": "a", "name": "A", "prompt": "p", "schedule": {"kind": "manual"}, "color": "red", "tags": ["x"]},
          {"id": "broken", "name": "B", "prompt": "p", "schedule": {"kind": "weekly"}}
        ], "note": "mine"}
        """
        try Data(text.utf8).write(to: url)
        var s = RoutineSet.load(from: url)
        #expect(s.routines.count == 1 && s.problems.count == 1)
        s.routines[0].name = "Renamed"
        s.routines.append(Routine(id: "b", name: "New", prompt: "q", schedule: .every(hours: 2)))
        try s.save(to: url)
        let back = RoutineSet.load(from: url)
        #expect(back.routines.map(\.id) == ["a", "b"])
        #expect(back.routines[0].name == "Renamed")
        #expect(back.routines[0].extra.map(\.key) == ["color", "tags"])
        // The entry that could not be used is still in the file, as the person wrote it.
        #expect(back.problems.count == 1 && back.problems[0].hasPrefix("Routine broken:"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"note\": \"mine\"") && raw.contains("weekly"))
    }

    @Test func roundTrip() {
        let s = decode(Self.good)
        let again = RoutineSet.decode(Data(s.encode().pretty().utf8))
        #expect(again.routines == s.routines)
        #expect(again.problems.isEmpty)
    }

    // MARK: Editing helpers

    @Test func idsFromNames() {
        #expect(Routine.makeId(from: "Morning report", taken: []) == "morning-report")
        #expect(Routine.makeId(from: "  Morning -- report!  ", taken: []) == "morning-report")
        #expect(Routine.makeId(from: "Morning report", taken: ["morning-report"]) == "morning-report-2")
        #expect(Routine.makeId(from: "Morning report", taken: ["morning-report", "morning-report-2"]) == "morning-report-3")
        #expect(Routine.makeId(from: "!!!", taken: []) == "routine")
        #expect(Routine.isValidId(Routine.makeId(from: String(repeating: "a", count: 100), taken: [])))
        #expect(Routine.isValidId("a_b-1") && !Routine.isValidId("") && !Routine.isValidId("A") && !Routine.isValidId("-a"))
    }

    @Test func editorValidation() {
        var r = Routine(id: "a", name: "", prompt: "", schedule: .daily(hour: 9, minute: 0, weekdays: []))
        #expect(r.problems().count == 2)
        r.name = "A"; r.prompt = "p"
        #expect(r.problems().isEmpty)
        r.folder = "relative"
        #expect(r.problems() == ["The folder must be an absolute path."])
        r.folder = ""
        r.schedule = .every(hours: 30)
        #expect(r.problems().count == 1)
    }

    // MARK: Log

    @Test func logRecordsHoldNoText() {
        let t = at("2026-06-10 10:00", utc)
        let r = RoutineLogRecord(time: t, routine: "morning", outcome: .finished, session: "abc", durationSec: 42, costUSD: 0.12)
        let line = r.line()
        #expect(line == "{\"time\":\"2026-06-10T10:00:00Z\",\"routine\":\"morning\",\"outcome\":\"finished\",\"session\":\"abc\",\"durationSec\":42,\"costUSD\":0.12}")
        #expect(RoutineLogRecord(line: line) == r)
        for o in [RoutineLogRecord.Outcome.started, .finished, .failed, .needsYou, .expired, .skipped("still running")] {
            let rec = RoutineLogRecord(time: t, routine: "x", outcome: o)
            #expect(RoutineLogRecord(line: rec.line()) == rec)
        }
        #expect(RoutineLogRecord(line: "not json") == nil)
        #expect(RoutineLogRecord(line: "{\"time\":\"2026-06-10T10:00:00Z\",\"routine\":\"x\",\"outcome\":\"dancing\"}") == nil)
    }

    @Test func logIsTrimmedToTheLastFiveHundredLines() {
        let lines = (1...520).map { "line\($0)" }
        let kept = RoutineLog.trimmed(lines + ["", ""])
        #expect(kept.count == 500 && kept.first == "line21" && kept.last == "line520")
        #expect(RoutineLog.trimmed(["a", "b"]) == ["a", "b"])
    }

    @Test func logFileAppendTrimsAndSkipsBrokenLines() throws {
        let (url, cleanup) = tempFile("routines-log.jsonl")
        defer { cleanup() }
        let t0 = at("2026-06-10 10:00", utc)
        for i in 0..<503 {
            RoutineLog.append(RoutineLogRecord(time: t0.addingTimeInterval(Double(i)), routine: "r", outcome: .started), to: url)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 500)
        let records = RoutineLog.parse(text + "garbage\n")
        #expect(records.count == 500)
        #expect(records.first?.time == t0.addingTimeInterval(3))
        #expect(RoutineLog.read(from: url).count == 500)
    }

    @Test func historyIsDerivedFromTheLog() {
        let t = at("2026-06-10 10:00", utc)
        func rec(_ s: Double, _ id: String, _ o: RoutineLogRecord.Outcome) -> RoutineLogRecord {
            RoutineLogRecord(time: t.addingTimeInterval(s), routine: id, outcome: o)
        }
        let h = RoutineLog.history([
            rec(0, "a", .started), rec(60, "a", .needsYou), rec(120, "a", .finished),
            rec(200, "a", .skipped("still running")),
            rec(10, "b", .started), rec(30, "b", .failed),
            rec(40, "c", .skipped("folder missing")),
        ])
        #expect(h["a"]?.lastRun == t)                              // a skip is not a run
        #expect(h["a"]?.lastAttempt == t.addingTimeInterval(200))  // but it moves the schedule on
        #expect(h["a"]?.last?.outcome == .skipped("still running"))
        #expect(h["b"]?.lastRun == t.addingTimeInterval(10) && h["b"]?.last?.outcome == .failed)
        #expect(h["c"]?.lastRun == nil && h["c"]?.lastAttempt == t.addingTimeInterval(40))
        #expect(h["d"] == nil)
    }
}
