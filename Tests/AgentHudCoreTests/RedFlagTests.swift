import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Red flags

@Suite struct RedFlagTests {
    let set = RedFlagSet(rules: RedFlagSet.defaults)

    func ids(_ cmd: String) -> [String] {
        set.matches(toolName: "Bash", input: ["command": .string(cmd)]).map(\.id)
    }

    /// Rule -> commands it catches, and commands it must not catch.
    static let table: [(id: String, hit: [String], miss: [String])] = [
        ("push-protected", [
            "git push origin main",
            "git push origin master",
            "git push origin dev",
            "git push -u origin develop",
            "git push origin HEAD:main",
            "git push origin feature:dev",
            "git push origin HEAD:refs/heads/main",
            "git push --force origin main",
            "cd x && git push origin main",
            "git -C repo push origin main",
            "/usr/bin/git push origin main; echo ok",
            "git push origin \"main\"",
            "GIT PUSH ORIGIN MAIN",
        ], [
            "git push origin feature/dev-tools",
            "git push origin develop-2",
            "git push origin remaster-fix",
            "git push -u origin feature/x",
            "git push origin feature/dev",
            "git push origin main:feature",
            "git push origin feat && git checkout main",
            "git checkout main",
            "git pull origin main",
            "git push",
            "legit push origin main",
        ]),
        ("force", [
            "git push --force-with-lease origin feat",
            "git push --force origin feat",
            "git push -f origin feat",
            "git push origin feat -f",
            "git push -uf origin feat",
            "git push origin +feat",
            "git push origin +HEAD:feat",
            "npm run build --force",
            "git push --force-with-lease=feat:abc origin feat",
            "cd x && git checkout --force y",
        ], [
            "git push origin feat",
            "git push -u origin feature/x",
            "git push --follow-tags origin feat",
            "git push origin my-feature",
            "git commit -m \"enforce limits\"",
            "ls -f",
            "echo a+b",
            "docker compose up --force-recreate",
        ]),
        ("mr-create", [
            "git push -o merge_request.create origin feat",
            "git push -o merge_request.target=dev origin feat",
            "git push --push-option=merge_request.merge_when_pipeline_succeeds origin feat",
            "glab mr create --fill",
            "glab mr merge 12",
            "glab mr approve 12",
            "gh pr create --title x",
            "gh pr merge 5 --squash",
            "cd repo && gh pr create",
            "gh -R owner/repo pr merge 5",
        ], [
            "gh pr view 12",
            "gh pr list",
            "gh pr checkout 5",
            "glab issue list",
            "glab mr list",
            "glab mr view 12",
            "git push -u origin feature/x",
            "cat docs/merge_request.md",
            "echo glab mrx",
        ]),
        ("rm-rf", [
            "rm -rf dist",
            "rm -fr dist",
            "rm -Rf dist",
            "rm -r -f dist",
            "rm -f -r dist",
            "rm --recursive --force dist",
            "rm -r dist --force",
            "rm -rfv dist",
            "sudo rm -rf /var/x",
            "cd build && rm -rf out",
            "/bin/rm -rf out",
            "find . -name x | xargs rm -rf",
        ], [
            "rm -r dir",
            "rm file -f",
            "rm -f file",
            "rm file",
            "rm -r dir; ls -f",
            "echo performance -rf",
            "npm run perform -- -rf",
            "ls -rf",
        ]),
        ("db-migrate", [
            "alembic upgrade head",
            "alembic downgrade -1",
            "alembic -c prod.ini upgrade head",
            "npx prisma migrate deploy",
            "prisma migrate reset --force",
            "php artisan migrate",
            "php artisan migrate:fresh --seed",
            "python manage.py migrate",
            "cd api && ./manage.py migrate app 0003",
            "psql -h db.example.com -U app app",
            "psql --host=10.0.0.5 app",
            "psql -p 5433 app",
            "psql postgres://u@db.example.com/app -c 'select 1'",
            "psql \"postgresql://u@db/app\"",
            "pg_restore -h db.example.com -d app dump.bin",
            "pg_restore --port 5433 -d app dump.bin",
        ], [
            "alembic history",
            "alembic current",
            "prisma migrate status",
            "prisma generate",
            "php artisan make:migration add_users",
            "php artisan route:list",
            "python manage.py makemigrations",
            "python manage.py runserver",
            "psql app -c 'select 1'",
            "psql -P pager=off -H app",
            "pg_restore -d app dump.bin",
            "echo upgrade",
        ]),
    ]

    @Test func defaultRulesMatchTable() {
        #expect(Self.table.map(\.id) == RedFlagSet.defaults.map(\.id))
        for row in Self.table {
            #expect(row.hit.count >= 3 && row.miss.count >= 3)
            for cmd in row.hit { #expect(ids(cmd).contains(row.id), "\(row.id) must catch: \(cmd)") }
            for cmd in row.miss { #expect(!ids(cmd).contains(row.id), "\(row.id) must not catch: \(cmd)") }
        }
    }

    @Test func harmlessCommandsHaveNoFlags() {
        for cmd in ["git status", "git push -u origin feature/x", "npm run build", "rm -r dir", "rm file -f",
                    "echo performance", "git push origin remaster-fix", "ls -la", "swift build"] {
            #expect(ids(cmd).isEmpty, "\(cmd): \(ids(cmd))")
        }
    }

    @Test func everyMatchingRuleIsReturned() {
        #expect(ids("git push --force origin main") == ["push-protected", "force"])
        #expect(ids("git push -f -o merge_request.create origin HEAD:main") == ["push-protected", "force", "mr-create"])
        #expect(ids("sudo rm -rf / && alembic upgrade head") == ["rm-rf", "db-migrate"])
        // A mention in quotes inside a real command counts too: we do not parse quotes.
        #expect(ids("git commit -m \"then git push origin main\"") == ["push-protected"])
    }

    @Test func onlyBashIsFlagged() {
        let input: JSONValue = ["command": "rm -rf /", "content": "git push --force origin main"]
        for tool in ["Write", "Edit", "Read", "WebFetch", "mcp__x__run", "bash", ""] {
            #expect(set.matches(toolName: tool, input: input).isEmpty, "\(tool)")
        }
        #expect(set.matches(toolName: "Bash", input: ["description": "rm -rf /"]).isEmpty)   // no command
        #expect(set.matches(toolName: "Bash", input: input).map(\.id) == ["rm-rf"])
    }

    @Test func defaultPatternsCompile() {
        for r in RedFlagSet.defaults { #expect(RedFlagSet.regex(r.pattern) != nil, "\(r.id)") }
        #expect(Set(RedFlagSet.defaults.map(\.id)) == ["push-protected", "force", "mr-create", "rm-rf", "db-migrate"])
    }

    // MARK: File

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-redflags-\(UUID().uuidString)")
    }

    @Test func missingFileCreatesDefaults() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/red-flags.json")
        let loaded = RedFlagSet.load(from: file)
        #expect(loaded.rules == RedFlagSet.defaults && loaded.problems.isEmpty)
        let json = try JSONValue.parse(Data(contentsOf: file))
        #expect(json["version"] == 1)
        #expect(json["rules"]?.arrayValue?.count == RedFlagSet.defaults.count)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\n  \"rules\": ["))   // readable JSON
        // The written file reads back with the same rules (regex escaping is not lost).
        let again = RedFlagSet.load(from: file)
        #expect(again.rules == RedFlagSet.defaults && again.problems.isEmpty)
    }

    @Test func invalidFileFallsBackToDefaultsAndIsNotOverwritten() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("red-flags.json")
        for broken in ["{\"rules\": [", "", "{\"version\": 1}", "{\"rules\": \"none\"}", "[]"] {
            try broken.write(to: file, atomically: true, encoding: .utf8)
            let loaded = RedFlagSet.load(from: file)
            #expect(loaded.rules == RedFlagSet.defaults, "\(broken)")
            #expect(loaded.problems.count == 1, "\(broken)")
            #expect(try String(contentsOf: file, encoding: .utf8) == broken)
        }
        // A folder instead of a file: cannot be read, built-in rules apply.
        let unreadable = dir.appendingPathComponent("as-dir.json")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        let loaded = RedFlagSet.load(from: unreadable)
        #expect(loaded.rules == RedFlagSet.defaults && loaded.problems.count == 1)
    }

    @Test func badRulesAreSkippedWithProblems() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("red-flags.json")
        let text = """
        {"version": 1, "rules": [
          {"id": "ok", "title": "Deploy", "pattern": "\\\\bdeploy\\\\b"},
          {"id": "bad-regex", "title": "Broken", "pattern": "(unclosed"},
          {"id": "no-pattern", "title": "No pattern"},
          {"title": "No id", "pattern": "x"},
          {"id": "empty", "title": "Empty", "pattern": ""},
          "junk"
        ]}
        """
        try text.write(to: file, atomically: true, encoding: .utf8)
        let loaded = RedFlagSet.load(from: file)
        #expect(loaded.rules == [RedFlagRule(id: "ok", title: "Deploy", pattern: "\\bdeploy\\b")])
        #expect(loaded.problems.count == 5)
        #expect(loaded.problems[0].contains("bad-regex"))
        #expect(loaded.problems[1].contains("no-pattern"))
        #expect(loaded.problems[3].contains("empty"))
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        #expect(loaded.matches(toolName: "Bash", input: ["command": "make DEPLOY"]).map(\.id) == ["ok"])
        #expect(loaded.matches(toolName: "Bash", input: ["command": "rm -rf /"]).isEmpty)
    }

    @Test func emptyRulesMeanNoRules() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("red-flags.json")
        try "{\"version\": 1, \"rules\": []}".write(to: file, atomically: true, encoding: .utf8)
        let loaded = RedFlagSet.load(from: file)
        #expect(loaded.rules.isEmpty && loaded.problems.isEmpty)
        #expect(loaded.matches(toolName: "Bash", input: ["command": "rm -rf /"]).isEmpty)
    }

    // MARK: "Allow always"

    @Test func flaggedRequestHasNoAlwaysOptions() throws {
        let suggestions = try fixture("permission-PermissionRequest")["permission_suggestions"]?.arrayValue ?? []
        #expect(!suggestions.isEmpty)
        let input: JSONValue = ["command": "git push origin main"]
        let flags = set.matches(toolName: "Bash", input: input)
        #expect(!flags.isEmpty)
        // Without a flag: the HUD pattern and the agent suggestion are in place, as before.
        let plain = PermissionRules.options(toolName: "Bash", input: input, suggestions: suggestions)
        #expect(plain.count == 3)
        #expect(PermissionRules.options(toolName: "Bash", input: input, suggestions: suggestions, redFlags: []) == plain)
        // With a flag everything disappears.
        #expect(PermissionRules.options(toolName: "Bash", input: input, suggestions: suggestions, redFlags: flags).isEmpty)
        #expect(PermissionRules.options(toolName: "Bash", input: input, suggestions: [], redFlags: flags).isEmpty)
    }
}
