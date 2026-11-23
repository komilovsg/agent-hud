import Foundation
import Testing
@testable import AgentHudCore

/// `AGENTHUD_SUPPORT_DIR` — переменная процесса: тесты с файлами журнала берут общий замок,
/// чтобы не пересекаться (в том числе с `ActivityTests.fileAppendAndRead`).
let supportDirLock = NSLock()

func withSupportDir<T>(_ body: () throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahud-rep-\(UUID().uuidString)")
    supportDirLock.lock()
    setenv("AGENTHUD_SUPPORT_DIR", dir.path, 1)
    defer { unsetenv("AGENTHUD_SUPPORT_DIR"); try? FileManager.default.removeItem(at: dir); supportDirLock.unlock() }
    return try body()
}

@Suite struct RefsTests {
    @Test func branchForms() {
        #expect(GitRefs.branches(inCommand: "git checkout -b feat/a") == ["feat/a"])
        #expect(GitRefs.branches(inCommand: "git switch -c fix-b origin/main") == ["fix-b"])
        #expect(GitRefs.branches(inCommand: "git checkout feat/c") == ["feat/c"])
        #expect(GitRefs.branches(inCommand: "git switch develop") == ["develop"])
        #expect(GitRefs.branches(inCommand: "git push -u origin feat/d") == ["feat/d"])
        #expect(GitRefs.branches(inCommand: "git push --set-upstream origin feat/e") == ["feat/e"])
        #expect(GitRefs.branches(inCommand: "git push origin HEAD:refs/heads/feat/f") == ["feat/f"])
        #expect(GitRefs.branches(inCommand: "git push origin local:remote-g") == ["remote-g"])
        #expect(GitRefs.branches(inCommand: "git branch feat/h") == ["feat/h"])
        #expect(GitRefs.branches(inCommand: "git -C /d/app checkout -b feat/i") == ["feat/i"])
    }

    @Test func compoundCommands() {
        let cmd = "cd /d/app && git checkout -b feat/a ; git add . && git commit -m x || true; git push -u origin feat/a"
        #expect(GitRefs.branches(inCommand: cmd) == ["feat/a"])
        #expect(GitRefs.branches(inCommand: "git switch a\ngit push origin b") == ["a", "b"])
    }

    @Test func branchNonMatches() {
        for c in ["git checkout -- file.txt", "git checkout .", "git push", "git push origin HEAD", "git status",
                  "git checkout -", "git checkout ./src", "git checkout main -- a.txt", "git branch -d old", "git branch",
                  "git push origin --delete old", "git log --oneline"] {
            #expect(GitRefs.branches(inCommand: c).isEmpty, "\(c)")
        }
        // `echo git checkout -b x` — не git-команда, ветка не извлекается.
        #expect(GitRefs.branches(inCommand: "echo git checkout -b x").isEmpty)
    }

    @Test func links() {
        let gl = "remote: View merge request: https://gitlab.example.com/acme/app/-/merge_requests/42"
        #expect(GitRefs.links(inText: gl) == ["https://gitlab.example.com/acme/app/-/merge_requests/42"])
        let new = "remote:   https://gitlab.example.com/acme/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat%2Fa&x=1"
        #expect(GitRefs.links(inText: new) == ["https://gitlab.example.com/acme/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat%2Fa"])
        #expect(GitRefs.branches(inText: new) == ["feat/a"])
        #expect(GitRefs.links(inText: "https://github.com/acme/app/pull/7") == ["https://github.com/acme/app/pull/7"])
        #expect(GitRefs.links(inText: "see (https://github.com/acme/app/pull/7).") == ["https://github.com/acme/app/pull/7"])
        #expect(GitRefs.links(inText: "https://github.com/acme/app/pull/7. and https://github.com/acme/app/pull/7 and https://gitlab.example.com/acme/app/-/merge_requests/1,")
                == ["https://github.com/acme/app/pull/7", "https://gitlab.example.com/acme/app/-/merge_requests/1"])
        #expect(GitRefs.links(inText: "https://github.com/acme/app and https://gitlab.example.com/acme/app/-/issues/3").isEmpty)
    }
}

@Suite(.serialized) struct ReportTests {
    func rec(_ k: ActivityRecord.Kind, _ dt: TimeInterval, _ sid: String, _ cwd: String, _ text: String,
             detail: String? = nil, stats: TurnStats? = nil) -> ActivityRecord {
        ActivityRecord(kind: k, time: t0.addingTimeInterval(dt), agent: "claude", session: sid,
                       project: ProjectNames.displayName(cwd: cwd), cwd: cwd, text: text, detail: detail, stats: stats)
    }

    @Test func readAcrossDays() {
        withSupportDir {
            let day: TimeInterval = 86_400
            let a = rec(.prompt, -day, "s", "/p", "вчера")
            let b = rec(.prompt, 0, "s", "/p", "граница от")
            let c = rec(.stop, 60, "s", "/p", "середина")
            let d = rec(.prompt, day, "s", "/p", "граница до")
            let e = rec(.prompt, 2 * day, "s", "/p", "после")
            let early = rec(.prompt, -1, "s", "/p", "до границы")
            for r in [a, early, b, c, d, e] { ActivityLog.append(r) }
            let got = ActivityLog.read(from: t0, to: t0.addingTimeInterval(day))
            #expect(got == [b, c, d])
            #expect(ActivityLog.read(from: t0.addingTimeInterval(day), to: t0).isEmpty)
            #expect(ActivityLog.read(from: t0.addingTimeInterval(-3 * day), to: t0.addingTimeInterval(3 * day)).count == 6)
        }
    }

    @Test func oldAndUnknownKindsLoad() throws {
        try withSupportDir {
            let old = #"{"kind":"prompt","t":1800000000,"agent":"claude","session":"s","project":"p","cwd":"/p","text":"старая"}"#
            let unknown = #"{"kind":"future","t":1800000001,"text":"?"}"#
            let ref = #"{"kind":"ref","t":1800000002,"session":"s","project":"p","cwd":"/p","text":"feat/a","detail":"branch"}"#
            let url = ActivityLog.file(for: t0)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((old + "\n" + unknown + "\nмусор\n" + ref + "\n").utf8).write(to: url)
            let got = ActivityLog.read(day: t0)
            #expect(got.map(\.kind) == [.prompt, .ref])
            #expect(got[1].detail == "branch")
        }
    }

    @Test func refRoundTrip() {
        let r = rec(.ref, 1, "s", "/p", "https://gitlab.example.com/acme/app/-/merge_requests/5", detail: "link")
        #expect(ActivityRecord(json: r.toJSON()) == r)
    }

    func twoProjects() -> [ActivityRecord] {
        [
            rec(.prompt, -600, "s1", "/d/app", "Начатая до границы"),
            rec(.stop, 300, "s1", "/d/app", "ok", stats: TurnStats(tools: [:], files: [], subagents: 0, durationSec: 900)),
            rec(.prompt, 100, "s2", "/d/site", "Сайт\nвторая строка"),
            rec(.stop, 400, "s2", "/d/site", "ok", stats: TurnStats(tools: [:], files: [], subagents: 0, durationSec: 300)),
            rec(.ref, 200, "s1", "/d/app", "feat/a", detail: "branch"),
            rec(.ref, 210, "s1", "/d/app", "https://gitlab.example.com/acme/app/-/merge_requests/9", detail: "link"),
            rec(.ref, 220, "s1", "/d/app", "feat/a", detail: "branch"),
            rec(.ref, 230, "s2", "/d/site", "site-fix", detail: "branch"),
            rec(.ref, -900, "s1", "/d/app", "old-branch", detail: "branch"),
        ]
    }

    @Test func buildAndMarkdown() {
        let from = t0, to = t0.addingTimeInterval(3600)
        let ps = PeriodReport.build(twoProjects(), from: from, to: to)
        #expect(ps.map(\.project.name) == ["d/app", "d/site"])
        #expect(ps[0].project.turns.count == 1)   // ход начат до from, закончен внутри
        #expect(ps[0].branches == ["feat/a"])
        #expect(ps[0].links == ["https://gitlab.example.com/acme/app/-/merge_requests/9"])
        #expect(ps[1].branches == ["site-fix"] && ps[1].links.isEmpty)
        let md = PeriodReport.markdown(ps, from: from, to: to)
        #expect(md.hasPrefix("# Отчёт агентов · "))
        #expect(md.contains("**Итого:** 2 задачи в 2 проектах · агенты работали 20 мин"))
        #expect(md.contains("## d/app") && md.contains("Ветки: `feat/a`"))
        #expect(md.contains("- https://gitlab.example.com/acme/app/-/merge_requests/9"))
        #expect(md.contains("Начатая до границы — готово за 15 мин"))
        #expect(!md.contains("old-branch") && !md.contains("вторая строка"))
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        #expect(md.contains("- **\(tf.string(from: t0.addingTimeInterval(-600)))** Начатая"))
    }

    @Test func multiDayShowsDates() {
        let from = t0.addingTimeInterval(-3 * 86_400), to = t0.addingTimeInterval(3600)
        let md = PeriodReport.markdown(PeriodReport.build(twoProjects(), from: from, to: to), from: from, to: to)
        let df = DateFormatter(); df.locale = Locale(identifier: "ru_RU"); df.dateFormat = "d MMM HH:mm"
        #expect(md.contains("- **\(df.string(from: t0.addingTimeInterval(100)))** Сайт"))
    }

    @Test func emptyRange() {
        let md = PeriodReport.markdown(PeriodReport.build([], from: t0, to: t0.addingTimeInterval(60)), from: t0, to: t0.addingTimeInterval(60))
        #expect(md.hasPrefix("# Отчёт агентов · ") && md.contains("ничего не делали"))
        // Записи есть, но вне отрезка.
        let far = PeriodReport.build(twoProjects(), from: t0.addingTimeInterval(86_400), to: t0.addingTimeInterval(2 * 86_400))
        #expect(far.isEmpty)
    }

    @Test func loadReadsLookback() {
        withSupportDir {
            for r in twoProjects() { ActivityLog.append(r) }
            let ps = PeriodReport.load(from: t0, to: t0.addingTimeInterval(3600))
            #expect(ps.map(\.project.name) == ["d/app", "d/site"] && ps[0].project.turns.count == 1)
        }
    }

    func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }
    func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    @Test func presets() {
        let c = cal("Europe/Moscow")
        let now = date(c, 2026, 11, 23, 18, 30)
        let a = ReportPreset.since15Yesterday.range(now: now, calendar: c)
        #expect(a.from == date(c, 2026, 11, 22, 15) && a.to == now)
        // До 15:00 правило то же: вчера 15:00.
        let early = date(c, 2026, 11, 23, 9)
        #expect(ReportPreset.since15Yesterday.range(now: early, calendar: c).from == date(c, 2026, 11, 22, 15))
        let t = ReportPreset.today.range(now: now, calendar: c)
        #expect(t.from == date(c, 2026, 11, 23, 0) && t.to == now)
        let y = ReportPreset.yesterday.range(now: now, calendar: c)
        #expect(y.from == date(c, 2026, 11, 22, 0) && y.to == date(c, 2026, 11, 23, 0).addingTimeInterval(-1))
        let w = ReportPreset.week.range(now: now, calendar: c)
        #expect(w.from == date(c, 2026, 11, 17, 0) && w.to == now)
    }

    @Test func presetsAcrossDST() {
        let c = cal("Europe/Berlin")   // 2026-03-29: часы переводят вперёд, в сутках 23 часа
        let now = date(c, 2026, 3, 29, 12)
        #expect(ReportPreset.since15Yesterday.range(now: now, calendar: c).from == date(c, 2026, 3, 28, 15))
        let after = date(c, 2026, 3, 30, 10)
        let y = ReportPreset.yesterday.range(now: after, calendar: c)
        #expect(y.from == date(c, 2026, 3, 29, 0) && y.to == date(c, 2026, 3, 30, 0).addingTimeInterval(-1))
        #expect(y.to.timeIntervalSince(y.from) == 23 * 3600 - 1)
        let w = ReportPreset.week.range(now: after, calendar: c)
        #expect(w.from == date(c, 2026, 3, 24, 0))
        // Осенний перевод: 2026-10-25, в сутках 25 часов.
        let fall = ReportPreset.yesterday.range(now: date(c, 2026, 10, 26, 10), calendar: c)
        #expect(fall.to.timeIntervalSince(fall.from) == 25 * 3600 - 1)
    }
}
