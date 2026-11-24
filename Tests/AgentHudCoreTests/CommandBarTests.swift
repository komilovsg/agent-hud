import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Command bar: targets, assistant decision, queue, history, hotkey table, frame

@Suite struct CommandBarTests {
    typealias L = CommandBarLogic
    let a = "0f8fad5b-d9cb-469f-a165-708677289501"
    let b = "0f8fad5b-d9cb-469f-a165-708677289502"

    func live(_ id: String, _ name: String) -> CommandBarLiveSession { CommandBarLiveSession(sessionId: id, projectName: name, cwd: "/p/\(name)") }

    // MARK: Targets

    @Test func entriesAssistantFirstNewSessionLast() {
        // The support folder comes from an environment variable that file-based tests change for a moment.
        supportDirLock.lock(); defer { supportDirLock.unlock() }
        let e = L.entries(live: [live(a, "acme-web"), live(b, "acme-api")], assistantSessionId: nil)
        #expect(e.map(\.target) == [.assistant, .session(a), .session(b), .newSession])
        #expect(e.map(\.title) == ["Assistant", "acme-web", "acme-api", "New session in…"])
        #expect(e[0].cwd == AssistantSession.directory.path)
        #expect(e.last?.cwd == nil)
    }

    @Test func assistantIsNotListedTwice() {
        let e = L.entries(live: [live(a, "Assistant"), live(b, "acme-api")], assistantSessionId: a)
        #expect(e.map(\.target) == [.assistant, .session(b), .newSession])
    }

    @Test func entriesWithoutSessions() {
        #expect(L.entries(live: [], assistantSessionId: nil).map(\.target) == [.assistant, .newSession])
        #expect(L.entries(live: [live(a, "")], assistantSessionId: nil)[1].title == "Session")
    }

    @Test func rememberedTargetFallsBackToAssistant() {
        let e = L.entries(live: [live(a, "acme-web")], assistantSessionId: nil)
        #expect(L.resolve(remembered: .session(a), in: e) == .session(a))
        #expect(L.resolve(remembered: .session(b), in: e) == .assistant)   // that session is gone
        #expect(L.resolve(remembered: nil, in: e) == .assistant)
        #expect(L.resolve(remembered: .newSession, in: e) == .newSession)
        #expect(L.resolve(remembered: .session(a), in: L.entries(live: [], assistantSessionId: nil)) == .assistant)
    }

    @Test func shortcutDigits() {
        #expect(L.entryIndex(forShortcut: 1, count: 3) == 0)
        #expect(L.entryIndex(forShortcut: 3, count: 3) == 2)
        #expect(L.entryIndex(forShortcut: 4, count: 3) == nil)
        #expect(L.entryIndex(forShortcut: 0, count: 3) == nil)
        #expect(L.entryIndex(forShortcut: 9, count: 20) == 8)
        #expect(L.entryIndex(forShortcut: 10, count: 20) == nil)
        #expect(L.shortcutDigit(forIndex: 0) == 1)
        #expect(L.shortcutDigit(forIndex: 8) == 9)
        #expect(L.shortcutDigit(forIndex: 9) == nil)
    }

    // MARK: Assistant decision

    @Test func assistantDecisionTable() {
        func d(_ id: String?, owned: Bool, transcript: Bool, elsewhere: Bool) -> L.AssistantAction {
            L.assistantAction(storedId: id, ownedAlive: owned, transcriptExists: transcript, aliveElsewhere: elsewhere)
        }
        #expect(d(nil, owned: false, transcript: false, elsewhere: false) == .startNew)
        #expect(d("junk", owned: true, transcript: true, elsewhere: false) == .startNew)      // not a session id
        #expect(d(a, owned: true, transcript: true, elsewhere: false) == .sendToLive)
        #expect(d(a, owned: true, transcript: false, elsewhere: false) == .sendToLive)         // just started: no file yet
        #expect(d(a, owned: false, transcript: true, elsewhere: false) == .resume)
        #expect(d(a, owned: false, transcript: true, elsewhere: true) == .startNew)            // held by another app
        #expect(d(a, owned: false, transcript: false, elsewhere: false) == .startNew)          // never reached the CLI
        #expect(d(a, owned: false, transcript: false, elsewhere: true) == .startNew)
    }

    // MARK: Send plan

    @Test func sendPlanPerState() {
        typealias S = OwnedSessionLogic.State
        #expect(L.sendPlan(state: .idle, interrupt: false) == .sendNow)
        #expect(L.sendPlan(state: .idle, interrupt: true) == .sendNow)
        #expect(L.sendPlan(state: .starting, interrupt: false) == .sendNow)
        #expect(L.sendPlan(state: .running, interrupt: false) == .queue)
        #expect(L.sendPlan(state: .running, interrupt: true) == .interruptThenSend)
        #expect(L.sendPlan(state: .interrupting, interrupt: true) == .waitThenSend)   // never a second interrupt
        #expect(L.sendPlan(state: .interrupting, interrupt: false) == .queue)
        #expect(L.sendPlan(state: .handingOver, interrupt: false) == .unavailable)
        #expect(L.sendPlan(state: .exited(0), interrupt: true) == .unavailable)
        #expect(L.isBusy(.running) && L.isBusy(.interrupting))
        #expect(!L.isBusy(.idle) && !L.isBusy(nil))
    }

    @Test func statusLinePriority() {
        #expect(L.statusLine(error: "Not connected", busyTitle: "Assistant", newSession: false) == "Not connected")
        #expect(L.statusLine(error: nil, busyTitle: "Assistant", newSession: false)
                == "Assistant is still working — Return queues this, ⌘Return interrupts and sends")
        #expect(L.statusLine(error: "", busyTitle: nil, newSession: false) == L.idleHint)
        #expect(L.statusLine(error: nil, busyTitle: nil, newSession: true) == L.newSessionHint)
    }

    // MARK: Queue

    @Test func queueHoldsOneMessagePerSession() {
        var q = CommandBarQueue()
        #expect(q.queue("one", for: a) == false)
        #expect(q.queue("two", for: a) == true)            // replaced
        #expect(q.queue("other", for: b) == false)
        #expect(q.text(for: a) == "two")
        #expect(q.text(for: b) == "other")
    }

    @Test func queueFlushHandsOutOnce() {
        var q = CommandBarQueue()
        q.queue("one", for: a)
        #expect(q.flush(a) == "one")
        #expect(q.flush(a) == nil)
        #expect(q.text(for: a) == nil)
        #expect(q.flush(b) == nil)
    }

    @Test func queueCancelAndDrop() {
        var q = CommandBarQueue()
        q.queue("one", for: a)
        q.queue("two", for: b)
        q.cancel(a)
        #expect(q.text(for: a) == nil && q.text(for: b) == "two")
        q.drop(b)                                           // the session exited
        #expect(q.slots.isEmpty)
        q.cancel(a)                                         // harmless on an empty slot
        #expect(q.slots.isEmpty)
    }

    @Test func queueFollowsARekeyedSession() {
        var q = CommandBarQueue()
        q.queue("one", for: a)
        q.move(from: a, to: b)
        #expect(q.text(for: a) == nil && q.text(for: b) == "one")
        q.move(from: a, to: b)                              // nothing to move
        #expect(q.text(for: b) == "one")
    }

    // MARK: History

    @Test func historyAddsDeduplicatesAndCaps() {
        var h = CommandHistory()
        h.add("  open mail ")
        h.add("open mail")                                  // repeat of the latest
        h.add("")
        h.add("   ")
        #expect(h.entries == ["open mail"])
        h.add("a"); h.add("open mail")                      // not consecutive: kept
        #expect(h.entries == ["open mail", "a", "open mail"])
        for i in 0..<30 { h.add("cmd \(i)") }
        #expect(h.entries.count == 20)
        #expect(h.entries.last == "cmd 29" && h.entries.first == "cmd 10")
    }

    @Test func historyWalk() {
        var h = CommandHistory(entries: ["one", "two", "three"])
        #expect(h.canWalk(fieldIsEmpty: true))
        #expect(!h.canWalk(fieldIsEmpty: false))
        #expect(h.down() == nil)                             // not walking: Down does nothing
        #expect(h.up() == "three")
        #expect(h.canWalk(fieldIsEmpty: false))              // walking: the field holds a history entry
        #expect(h.up() == "two")
        #expect(h.up() == "one")
        #expect(h.up() == "one")                             // stays on the oldest
        #expect(h.down() == "two")
        #expect(h.down() == "three")
        #expect(h.down() == "")                              // past the newest: empty field
        #expect(!h.isWalking)
        #expect(h.up() == "three")                           // starts again from the newest
        h.add("four")
        #expect(!h.isWalking)                                // sending ends the walk
        #expect(h.up() == "four")
    }

    @Test func historySwitchedOff() {
        var h = CommandHistory(entries: ["one"], enabled: false)
        h.add("two")
        #expect(h.entries == ["one"])                        // nothing is recorded
        #expect(!h.canWalk(fieldIsEmpty: true))
        #expect(h.up() == nil && h.down() == nil)
        h.enabled = true
        h.add("two")
        #expect(h.entries == ["one", "two"])
        h.clear()
        #expect(h.entries.isEmpty && h.up() == nil && !h.canWalk(fieldIsEmpty: true))
    }

    @Test func historyLoadedFromStorageIsCapped() {
        let stored = (0..<50).map { "c\($0)" } + [""]
        let h = CommandHistory(entries: stored)
        #expect(h.entries.count == 20 && h.entries.first == "c30" && h.entries.last == "c49")
    }

    // MARK: Hotkey table

    @Test func hotKeyOptions() {
        let o = CommandBarHotKey.options
        #expect(o.map(\.label) == ["⌃⌥Space", "⌥Space", "⌃⌥⌘Space", "⌃⌥J", "Off"])
        #expect(Set(o.map(\.id)).count == 5)
        #expect(o[0].id == CommandBarHotKey.defaultId)
        #expect(o[0].keyCode == 49 && o[0].modifiers == UInt32(0x1800))
        #expect(o[1].keyCode == 49 && o[1].modifiers == UInt32(0x0800))
        #expect(o[2].modifiers == UInt32(0x1900))   // control + option + command
        #expect(o[3].keyCode == 38 && o[3].modifiers == UInt32(0x1800))
        #expect(o[4].isOff && o[4].keyCode == nil && o[4].modifiers == nil)
        #expect(o.dropLast().allSatisfy { !$0.isOff })
        // No two options register the same combination.
        let combos = o.compactMap { x in x.keyCode.map { "\($0)/\(x.modifiers ?? 0)" } }
        #expect(Set(combos).count == combos.count)
    }

    @Test func hotKeyLookupAndTitle() {
        #expect(CommandBarHotKey.option(id: "ctrlOptJ").label == "⌃⌥J")
        #expect(CommandBarHotKey.option(id: "nonsense").id == CommandBarHotKey.defaultId)
        #expect(CommandBarHotKey.option(id: nil).id == CommandBarHotKey.defaultId)
        #expect(CommandBarHotKey.menuTitle(id: "optSpace") == "Command bar  ⌥Space")
        #expect(CommandBarHotKey.menuTitle(id: "off") == "Command bar")
    }

    // MARK: Frame

    @Test func barFrameCentredAt22Percent() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let f = L.barFrame(in: screen, height: 60)
        #expect(f.width == 640 && f.height == 60)
        #expect(f.midX == 720)
        #expect(abs((screen.maxY - f.maxY) - 900 * 0.22) < 0.001)       // top edge 22% down
        // Growing keeps the top edge where it was.
        let g = L.barFrame(in: screen, height: 200)
        #expect(g.maxY == f.maxY)
    }

    @Test func barFrameOnAnOffsetScreen() {
        let screen = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let f = L.barFrame(in: screen, height: 80)
        #expect(f.midX == screen.midX)
        #expect(abs((screen.maxY - f.maxY) - 1080 * 0.22) < 0.001)
        #expect(screen.contains(f))
    }

    @Test func barFrameClampedOnSmallScreens() {
        let narrow = CGRect(x: 0, y: 0, width: 500, height: 700)
        let f = L.barFrame(in: narrow, height: 80)
        #expect(f.width == 468)                                          // 500 - 2 x 16
        #expect(narrow.contains(f))
        let short = CGRect(x: 0, y: 0, width: 1000, height: 300)
        let tall = L.barFrame(in: short, height: 400)                    // taller than the screen allows
        #expect(short.contains(tall) && tall.height <= 300 - 32)
        let near = L.barFrame(in: short, height: 150)                    // would run off the bottom edge
        #expect(near.minY >= short.minY + 16 && near.maxY <= short.maxY - 16)
    }

    // MARK: Assistant folder

    @Test func assistantFolderIsLabelled() {
        // The support folder comes from an environment variable that file-based tests change for a moment.
        supportDirLock.lock(); defer { supportDirLock.unlock() }
        let dir = AssistantSession.directory.path
        #expect(dir.hasSuffix("/assistant"))
        #expect(ProjectNames.displayName(cwd: dir) == "Assistant")
        #expect(ProjectNames.displayName(cwd: "/Users/dev/assistant") == "assistant")   // another folder with that name
        #expect(AssistantSession.isAssistantFolder(dir + "/"))
        #expect(!AssistantSession.isAssistantFolder("/Users/dev/acme-web"))
    }

    @Test func assistantPromptIsPlainText() {
        let p = AssistantSession.systemPrompt
        #expect(!p.isEmpty && !p.contains("\n") && p.count < 500)
        #expect(!p.hasPrefix("-"))
    }
}
