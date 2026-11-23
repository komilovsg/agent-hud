import Foundation
import Testing
@testable import AgentHudCore

@Suite struct SlashCommandTests {
    // MARK: helpers

    func tempHome() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("slash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func cmd(_ name: String) -> SlashCommand {
        SlashCommand(name: name, description: "", argumentHint: nil, source: .user)
    }

    // MARK: builtin

    @Test func builtinHasCore() {
        let names = Set(SlashCommands.builtin.map(\.name))
        #expect(!names.isEmpty)
        for n in ["compact", "clear", "help"] { #expect(names.contains(n)) }
        #expect(names.count == SlashCommands.builtin.count)
    }

    // MARK: frontmatter

    @Test func frontmatterBasics() {
        let fm = SlashCommands.frontmatter("---\nname: demo\ndescription: \"Quoted: value\"\nargument-hint: '[a] [b]'\n---\nbody")
        #expect(fm["name"] == "demo")
        #expect(fm["description"] == "Quoted: value")
        #expect(fm["argument-hint"] == "[a] [b]")
    }

    @Test func frontmatterMultiLineTakesFirstLine() {
        let block = SlashCommands.frontmatter("---\ndescription: |\n  First line\n  second line\nname: x\n---\n")
        #expect(block["description"] == "First line")
        #expect(block["name"] == "x")
        let plain = SlashCommands.frontmatter("---\ndescription: Start of text\n  continued here\n---\n")
        #expect(plain["description"] == "Start of text")
    }

    @Test func frontmatterAbsentOrOdd() {
        #expect(SlashCommands.frontmatter("just text\n---\nname: x\n---").isEmpty)
        #expect(SlashCommands.frontmatter("").isEmpty)
        // Unterminated block (file cut at the read limit) still yields what was seen.
        #expect(SlashCommands.frontmatter("---\nname: cut\n")["name"] == "cut")
    }

    @Test func frontmatterCRLF() {
        let fm = SlashCommands.frontmatter("---\r\nname: win\r\ndescription: Line one\r\n---\r\nbody")
        #expect(fm["name"] == "win")
        #expect(fm["description"] == "Line one")
    }

    // MARK: scanning

    @Test func scansUserProjectSkillsAndPlugins() throws {
        let home = try tempHome(), proj = try tempHome()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: proj) }
        let uc = home.appendingPathComponent(".claude")
        let pc = proj.appendingPathComponent(".claude")

        try write("---\ndescription: Deploy it\nargument-hint: [env]\n---\nbody", to: uc.appendingPathComponent("commands/deploy.md"))
        try write("---\ndescription: User version\n---\n", to: uc.appendingPathComponent("commands/shared.md"))
        try write("no frontmatter here", to: uc.appendingPathComponent("commands/team/review/quick.md"))
        try write("x", to: uc.appendingPathComponent("commands/notes.txt"))
        try write("---\ndescription: Project version\n---\n", to: pc.appendingPathComponent("commands/shared.md"))
        try write("---\nname: pretty\ndescription: A skill\n---\n", to: uc.appendingPathComponent("skills/folder-name/SKILL.md"))
        try write("---\ndescription: Plain skill\n---\n", to: pc.appendingPathComponent("skills/local/SKILL.md"))
        try write("---\nuser-invocable: false\n---\n", to: uc.appendingPathComponent("skills/hidden/SKILL.md"))
        try write("---\ndisable-model-invocation: true\ndescription: Manual only\n---\n", to: uc.appendingPathComponent("skills/manual/SKILL.md"))

        // Plugin layout: installed_plugins.json -> installPath with commands/ and skills/.
        let plug = home.appendingPathComponent("store/acme")
        try write("---\ndescription: Audit things\n---\n", to: plug.appendingPathComponent("commands/audit.md"))
        try write("---\ndescription: Nested\n---\n", to: plug.appendingPathComponent("commands/sub/deep.md"))
        try write("---\ndescription: Plugin skill\n---\n", to: plug.appendingPathComponent("skills/scan/SKILL.md"))
        let off = home.appendingPathComponent("store/off")
        try write("---\ndescription: Off\n---\n", to: off.appendingPathComponent("commands/nope.md"))
        let installed = """
        {"version":2,"plugins":{
          "acme@market":[{"scope":"user","installPath":"\(plug.path)"}],
          "off@market":[{"scope":"user","installPath":"\(off.path)"}]
        }}
        """
        try write(installed, to: uc.appendingPathComponent("plugins/installed_plugins.json"))
        try write("{\"enabledPlugins\":{\"off@market\":false,\"acme@market\":true}}", to: uc.appendingPathComponent("settings.json"))

        let all = SlashCommands.available(home: home, projectDir: proj)
        let by = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

        #expect(by["deploy"]?.source == .user)
        #expect(by["deploy"]?.description == "Deploy it")
        #expect(by["deploy"]?.argumentHint == "[env]")
        #expect(by["team:review:quick"]?.description == "")
        #expect(by["notes"] == nil)
        #expect(by["shared"]?.source == .project)
        #expect(by["shared"]?.description == "Project version")
        #expect(by["pretty"]?.source == .user)
        #expect(by["folder-name"] == nil)
        #expect(by["local"]?.source == .project)
        #expect(by["hidden"] == nil)
        #expect(by["manual"]?.description == "Manual only")
        #expect(by["acme:audit"]?.source == .plugin)
        #expect(by["acme:sub:deep"] != nil)
        #expect(by["acme:scan"]?.description == "Plugin skill")
        #expect(by["off:nope"] == nil)
        #expect(by["compact"]?.source == .builtin)
        // Sorted, no duplicate names.
        #expect(all.map(\.name) == all.map(\.name).sorted())
        #expect(Set(all.map(\.name)).count == all.count)
    }

    @Test func projectIsOptionalAndHomeMayBeEmpty() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let all = SlashCommands.available(home: home, projectDir: nil)
        #expect(all.map(\.name) == SlashCommands.builtin.map(\.name).sorted())
        let missing = home.appendingPathComponent("does-not-exist")
        #expect(!SlashCommands.available(home: missing, projectDir: missing).isEmpty)
    }

    @Test func followsSymlinkedSkillFolder() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("elsewhere/real-skill")
        try write("---\ndescription: Linked\n---\n", to: real.appendingPathComponent("SKILL.md"))
        let skills = home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("linked"), withDestinationURL: real)
        let c = SlashCommands.available(home: home, projectDir: nil).first { $0.name == "linked" }
        #expect(c?.description == "Linked")
    }

    @Test func toleratesGarbageAndLimits() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cmds = home.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: cmds, withIntermediateDirectories: true)
        // Binary garbage with an .md name.
        try Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 200) }).write(to: cmds.appendingPathComponent("binary.md"))
        // Unreadable file.
        let locked = cmds.appendingPathComponent("locked.md")
        try write("---\ndescription: hidden text\n---\n", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        // Directory named like a command file, and a dangling symlink.
        try FileManager.default.createDirectory(at: cmds.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: cmds.appendingPathComponent("dangling.md"),
                                                    withDestinationURL: home.appendingPathComponent("nowhere"))
        // Long description is cut to 120 characters; a huge file is read only at its start.
        let long = String(repeating: "word ", count: 100)
        try write("---\ndescription: \(long)\n---\n" + String(repeating: "x", count: 200_000), to: cmds.appendingPathComponent("long.md"))
        // Too deep: depth limit is 4 sub-folders.
        try write("", to: cmds.appendingPathComponent("a/b/c/d/ok.md"))
        try write("", to: cmds.appendingPathComponent("a/b/c/d/e/too-deep.md"))

        let by = Dictionary(uniqueKeysWithValues: SlashCommands.available(home: home, projectDir: nil).map { ($0.name, $0) })
        #expect(by["binary"]?.description == "")
        #expect(by["long"]?.description.count == 120)
        #expect(by["long"]?.description.hasSuffix("…") == true)
        #expect(by["a:b:c:d:ok"] != nil)
        #expect(by["a:b:c:d:e:too-deep"] == nil)
        #expect(by["folder"] == nil)
    }

    // MARK: suggestions

    @Test func suggestionsRanking() {
        let cs = ["compact", "config", "context", "clear", "seo:audit", "seo:page", "my-audit", "audit", "xaudity", "cost"].map(cmd)
        func names(_ s: String, limit: Int = 8) -> [String] {
            SlashCommands.suggestions(for: s, in: cs, limit: limit).map(\.name)
        }
        #expect(names("/co") == ["compact", "config", "context", "cost"])
        #expect(names("/CO") == ["compact", "config", "context", "cost"])
        #expect(names("/compact") == ["compact"])
        #expect(names("/seo:a") == ["seo:audit"])
        // exact, then prefix, then segment after ':' or '-', then substring.
        #expect(names("/audit") == ["audit", "my-audit", "seo:audit", "xaudity"])
        #expect(names("/zzz") == [])
        #expect(names("/") == ["audit", "clear", "compact", "config", "context", "cost", "my-audit", "seo:audit"])
        #expect(names("/", limit: 3) == ["audit", "clear", "compact"])
        #expect(names("/co", limit: 2) == ["compact", "config"])
    }

    @Test func suggestionsRejectNonCommandText() {
        let cs = ["compact", "clear"].map(cmd)
        #expect(SlashCommands.suggestions(for: "/compact now", in: cs).isEmpty)
        #expect(SlashCommands.suggestions(for: "/co ", in: cs).isEmpty)
        #expect(SlashCommands.suggestions(for: "/co\nmore", in: cs).isEmpty)
        #expect(SlashCommands.suggestions(for: "compact", in: cs).isEmpty)
        #expect(SlashCommands.suggestions(for: " /co", in: cs).isEmpty)
        #expect(SlashCommands.suggestions(for: "", in: cs).isEmpty)
        #expect(SlashCommands.suggestions(for: "/co", in: cs, limit: 0).isEmpty)
    }
}
