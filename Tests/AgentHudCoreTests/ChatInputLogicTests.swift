import Testing
@testable import AgentHudCore

@Suite struct ChatInputLogicTests {
    // MARK: input mode

    @Test func inputModeFollowsOwnerAndSwitch() {
        #expect(InputLogic.inputMode(owned: true, typeIntoHost: false, hostCanBeTyped: false) == .direct)
        #expect(InputLogic.inputMode(owned: true, typeIntoHost: true, hostCanBeTyped: true) == .direct)
        #expect(InputLogic.inputMode(owned: false, typeIntoHost: true, hostCanBeTyped: true) == .typeIntoHost)
        #expect(InputLogic.inputMode(owned: false, typeIntoHost: true, hostCanBeTyped: false) == .watchOnly)
        #expect(InputLogic.inputMode(owned: false, typeIntoHost: false, hostCanBeTyped: true) == .watchOnly)
        #expect(!Features.typeIntoHost)
        #expect(InputLogic.inputMode(owned: false, hostCanBeTyped: true) == .watchOnly)
        #expect(InputLogic.watchLine(hostLabel: "Cursor") == "Watching — reply in Cursor")
    }

    @Test func sessionLinkOnlyForEndedOrHandOver() {
        #expect(!EditorOpenPlan.usesSessionLink(sessionEnded: false, handOver: false))
        #expect(EditorOpenPlan.usesSessionLink(sessionEnded: true, handOver: false))
        #expect(EditorOpenPlan.usesSessionLink(sessionEnded: false, handOver: true))
    }

    // MARK: send plan

    @Test func typesOnlyWithTrustAndSetting() {
        #expect(SendPlan.mode(trusted: true, typingEnabled: true, hostKind: .editor, focusConfirmed: false) == .type)
        #expect(SendPlan.mode(trusted: false, typingEnabled: true, hostKind: .editor, focusConfirmed: true) == .copy)
        #expect(SendPlan.mode(trusted: true, typingEnabled: false, hostKind: .editor, focusConfirmed: true) == .copy)
    }

    @Test func terminalNeedsConfirmedFocus() {
        #expect(SendPlan.mode(trusted: true, typingEnabled: true, hostKind: .terminal, focusConfirmed: true) == .type)
        #expect(SendPlan.mode(trusted: true, typingEnabled: true, hostKind: .terminal, focusConfirmed: false) == .copy)
        #expect(SendPlan.mode(trusted: true, typingEnabled: true, hostKind: .unsupported, focusConfirmed: true) == .copy)
    }

    @Test func expectedModeAssumesTerminalConfirms() {
        #expect(SendPlan.expectedMode(trusted: true, typingEnabled: true, hostKind: .terminal) == .type)
        #expect(SendPlan.expectedMode(trusted: false, typingEnabled: true, hostKind: .terminal) == .copy)
    }

    @Test func helperLines() {
        #expect(SendPlan.helperLine(mode: .type, hostLabel: "VS Code") == "Sends to the session in VS Code")
        #expect(SendPlan.helperLine(mode: .copy, hostLabel: "Cursor").hasPrefix("Copies the text and opens the session in Cursor"))
    }

    @Test func hostKinds() {
        #expect(SendHostKind(host: HostInfo(appBundleId: HostInfo.vscode, entrypoint: HostInfo.vscodeEntrypoint)) == .editor)
        #expect(SendHostKind(host: HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001")) == .terminal)
        #expect(SendHostKind(host: HostInfo(termProgram: "iTerm.app", tty: "/dev/ttys002")) == .terminal)
        #expect(SendHostKind(host: HostInfo(termProgram: "Apple_Terminal")) == .unsupported)
        #expect(SendHostKind(host: HostInfo(termProgram: "vscode", tty: "/dev/ttys003")) == .unsupported)
        #expect(SendHostKind(host: HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys004", herdrPaneId: "p1")) == .unsupported)
        #expect(SendHostKind(host: HostInfo(appBundleId: HostInfo.claudeDesktop)) == .unsupported)
        #expect(!SendHostKind.unsupported.canCompose)
    }

    // MARK: suggestion list state

    @Test func navWrapsBothWays() {
        var n = SuggestionNav(count: 3)
        n.move(-1); #expect(n.index == 2)
        n.move(1); #expect(n.index == 0)
        n.move(1); n.move(1); n.move(1); #expect(n.index == 0)
    }

    @Test func navClosedAndEmptyDoNothing() {
        var n = SuggestionNav(count: 0)
        n.move(1)
        #expect(!n.isOpen && n.index == 0)
        var d = SuggestionNav(count: 4)
        d.dismiss()
        d.move(1)
        #expect(!d.isOpen && d.index == 0)
        #expect(d.selected(in: [1, 2, 3, 4]) == nil)
    }

    @Test func navResetReopens() {
        var n = SuggestionNav(count: 5)
        n.move(1); n.dismiss()
        n.reset(count: 2)
        #expect(n.isOpen && n.index == 0)
    }

    @Test func navHoverSelectsInRangeOnly() {
        var n = SuggestionNav(count: 3)
        n.select(2); #expect(n.index == 2)
        n.select(7); #expect(n.index == 2)
        n.select(-1); #expect(n.index == 2)
    }

    @Test func navSelectsRow() {
        var n = SuggestionNav(count: 3)
        n.move(1)
        #expect(n.selected(in: ["a", "b", "c"]) == "b")
        #expect(SuggestionNav(count: 3, index: 9).index == 2)
    }

    @Test func acceptedTextHasTrailingSpace() {
        #expect(SuggestionNav.accepted(SlashCommand(name: "seo:audit", description: "", source: .plugin)) == "/seo:audit ")
    }

    // MARK: newline at the caret

    @Test func newlineAtCaret() {
        let r = InputEdit.insertNewline(in: "hello world", selection: 5..<5)
        #expect(r.text == "hello\n world" && r.caret == 6)
    }

    @Test func newlineReplacesSelection() {
        let r = InputEdit.insertNewline(in: "abcdef", selection: 1..<4)
        #expect(r.text == "a\nef" && r.caret == 2)
    }

    @Test func newlineWithoutSelectionAppends() {
        let r = InputEdit.insertNewline(in: "ab", selection: nil)
        #expect(r.text == "ab\n" && r.caret == 3)
    }

    @Test func newlineClampsOutOfRange() {
        let r = InputEdit.insertNewline(in: "ab", selection: 5..<9)
        #expect(r.text == "ab\n" && r.caret == 3)
    }
}
