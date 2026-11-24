import Foundation
import Testing
@testable import AgentHudCore

// Agents acting in other apps: the consent gate, what is never touched, key and text rules, element references,
// the rate limit, the per-app answers, and the texts of the request card.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// Everything the gate looks at, with values that lead to a plain "ask".
private struct Facts {
    var mode = HandsAccessMode.ask
    var kind = ActKind.clickAt
    var known = true
    var held = false
    var ax = true
    var target = ActGate.TargetState.available
    var excluded = false
    var secure = false
    var risky = false
    var rate = false
    var appAllowed = false
    var consented = false

    var decision: ActGate.Decision {
        ActGate.decide(mode: mode, kind: kind, sessionKnown: known, sessionHeld: held, accessibilityGranted: ax, target: target,
                       targetExcluded: excluded, secureField: secure, riskyKeys: risky, rateExceeded: rate,
                       appAllowedForSession: appAllowed, consented: consented)
    }

    /// The decision table written out a second time, rule by rule, to compare against.
    var expected: ActGate.Decision {
        if mode == .off { return .refuse(.off) }
        if !known { return .refuse(.unknownSession) }
        if held { return .refuse(.sessionHeld) }
        if !ax { return .refuse(.noAccessibility) }
        if target == .unknownWindow { return .refuse(.unknownWindow) }
        if target == .unknownApp { return .refuse(.unknownApp) }
        if target == .staleElement { return .refuse(.staleElement) }
        if excluded { return .refuse(.excludedApp) }
        if secure && (kind == .typeText || kind == .pressKeys) { return .refuse(.secureField) }
        if consented { return .allow }
        if risky { return .ask(offersApp: false) }
        if rate { return .ask(offersApp: false) }
        if mode == .perApp && appAllowed { return .allow }
        return .ask(offersApp: mode == .perApp)
    }
}

@Suite struct ActGateTests {
    private func facts(_ change: (inout Facts) -> Void) -> ActGate.Decision {
        var f = Facts()
        change(&f)
        return f.decision
    }

    @Test func rule1OffRefusesEverything() {
        for kind in ActKind.allCases {
            #expect(facts { $0.mode = .off; $0.kind = kind } == .refuse(.off))
            // Nothing else is looked at: not a click, not an allowance, not what is wrong with the rest.
            #expect(facts { $0.mode = .off; $0.kind = kind; $0.consented = true; $0.appAllowed = true } == .refuse(.off))
            #expect(facts { $0.mode = .off; $0.kind = kind; $0.known = false; $0.held = true; $0.ax = false; $0.target = .unknownWindow } == .refuse(.off))
        }
    }

    @Test func rule2AnUnknownCallerNeverActs() {
        for mode in [HandsAccessMode.ask, .perApp] {
            #expect(facts { $0.mode = mode; $0.known = false } == .refuse(.unknownSession))
            // Not even once, and not through an allowance.
            #expect(facts { $0.mode = mode; $0.known = false; $0.consented = true } == .refuse(.unknownSession))
            #expect(facts { $0.mode = mode; $0.known = false; $0.appAllowed = true } == .refuse(.unknownSession))
            // Reported before the hold, the permission and the target.
            #expect(facts { $0.mode = mode; $0.known = false; $0.held = true; $0.ax = false; $0.target = .unknownApp } == .refuse(.unknownSession))
        }
    }

    @Test func rule3AHeldSessionDoesNotAct() {
        #expect(facts { $0.held = true } == .refuse(.sessionHeld))
        #expect(facts { $0.held = true; $0.consented = true } == .refuse(.sessionHeld))
        #expect(facts { $0.mode = .perApp; $0.held = true; $0.appAllowed = true } == .refuse(.sessionHeld))
        #expect(facts { $0.held = true; $0.ax = false; $0.target = .staleElement } == .refuse(.sessionHeld))
    }

    @Test func rule4AccessibilityIsNeededForEveryKind() {
        for kind in ActKind.allCases {
            #expect(facts { $0.kind = kind; $0.ax = false } == .refuse(.noAccessibility))
            #expect(facts { $0.kind = kind; $0.ax = false; $0.consented = true } == .refuse(.noAccessibility))
        }
        #expect(facts { $0.ax = false; $0.target = .unknownWindow; $0.excluded = true } == .refuse(.noAccessibility))
    }

    @Test func rule5ATargetThatIsNotThere() {
        let states: [(ActGate.TargetState, ActGate.Refusal)] = [
            (.unknownWindow, .unknownWindow), (.unknownApp, .unknownApp), (.staleElement, .staleElement),
        ]
        for (state, refusal) in states {
            #expect(facts { $0.target = state } == .refuse(refusal))
            #expect(facts { $0.target = state; $0.consented = true } == .refuse(refusal))
            #expect(facts { $0.mode = .perApp; $0.target = state; $0.appAllowed = true } == .refuse(refusal))
            // Before the excluded app and the password field.
            #expect(facts { $0.kind = .typeText; $0.target = state; $0.excluded = true; $0.secure = true } == .refuse(refusal))
        }
    }

    @Test func rule6ExcludedApps() {
        for kind in ActKind.allCases {
            #expect(facts { $0.kind = kind; $0.excluded = true } == .refuse(.excludedApp))
            #expect(facts { $0.kind = kind; $0.excluded = true; $0.consented = true } == .refuse(.excludedApp))
            #expect(facts { $0.kind = kind; $0.mode = .perApp; $0.excluded = true; $0.appAllowed = true } == .refuse(.excludedApp))
        }
        #expect(facts { $0.kind = .pressKeys; $0.excluded = true; $0.secure = true } == .refuse(.excludedApp))
    }

    @Test func rule7PasswordFieldsStopTheKeyboardOnly() {
        for kind in ActKind.allCases {
            let keyboard = kind == .typeText || kind == .pressKeys
            #expect(kind.usesKeyboard == keyboard)
            #expect(facts { $0.kind = kind; $0.secure = true } == (keyboard ? .refuse(.secureField) : .ask(offersApp: false)))
            #expect(facts { $0.kind = kind; $0.secure = true; $0.consented = true } == (keyboard ? .refuse(.secureField) : .allow))
            #expect(facts { $0.kind = kind; $0.mode = .perApp; $0.secure = true; $0.appAllowed = true }
                    == (keyboard ? .refuse(.secureField) : .allow))
        }
    }

    @Test func rule8AClickAllows() {
        for mode in [HandsAccessMode.ask, .perApp] {
            for kind in ActKind.allCases {
                #expect(facts { $0.mode = mode; $0.kind = kind; $0.consented = true } == .allow)
            }
            // The click was on the card of a risky combination or of a call over the rate: it is the answer to that.
            #expect(facts { $0.mode = mode; $0.kind = .pressKeys; $0.consented = true; $0.risky = true } == .allow)
            #expect(facts { $0.mode = mode; $0.consented = true; $0.rate = true } == .allow)
        }
    }

    @Test func rule9RiskyKeysAlwaysAskAndOfferNothingLasting() {
        #expect(facts { $0.kind = .pressKeys; $0.risky = true } == .ask(offersApp: false))
        #expect(facts { $0.kind = .pressKeys; $0.mode = .perApp; $0.risky = true } == .ask(offersApp: false))
        // The app's allowance does not cover them (rule 9 before rule 11).
        #expect(facts { $0.kind = .pressKeys; $0.mode = .perApp; $0.risky = true; $0.appAllowed = true } == .ask(offersApp: false))
        #expect(facts { $0.kind = .pressKeys; $0.mode = .perApp; $0.risky = true; $0.rate = true; $0.appAllowed = true } == .ask(offersApp: false))
    }

    @Test func rule10OverTheRateAsksAgain() {
        #expect(facts { $0.rate = true } == .ask(offersApp: false))
        #expect(facts { $0.mode = .perApp; $0.rate = true } == .ask(offersApp: false))
        // Rule 10 before rule 11: an allowed app asks again while the session is over the rate.
        #expect(facts { $0.mode = .perApp; $0.rate = true; $0.appAllowed = true } == .ask(offersApp: false))
    }

    @Test func rule11AnAllowedAppInPerAppMode() {
        for kind in ActKind.allCases {
            #expect(facts { $0.kind = kind; $0.mode = .perApp; $0.appAllowed = true } == .allow)
            // "Ask" means every time: an allowance left from another mode is ignored.
            #expect(facts { $0.kind = kind; $0.mode = .ask; $0.appAllowed = true } == .ask(offersApp: false))
        }
    }

    @Test func rule12OtherwiseAsk() {
        for kind in ActKind.allCases {
            #expect(facts { $0.kind = kind; $0.mode = .ask } == .ask(offersApp: false))
            #expect(facts { $0.kind = kind; $0.mode = .perApp } == .ask(offersApp: true))
        }
    }

    @Test func theWholeTableInOrder() {
        // Every combination of the facts against the table written out a second time.
        var checked = 0
        let bools = [false, true]
        for mode in HandsAccessMode.allCases {
            for kind in ActKind.allCases {
                for target in [ActGate.TargetState.available, .unknownWindow, .unknownApp, .staleElement] {
                    for bits in 0..<512 {
                        var f = Facts(mode: mode, kind: kind, target: target)
                        f.known = bools[bits & 1]
                        f.held = bools[(bits >> 1) & 1]
                        f.ax = bools[(bits >> 2) & 1]
                        f.excluded = bools[(bits >> 3) & 1]
                        f.secure = bools[(bits >> 4) & 1]
                        f.risky = bools[(bits >> 5) & 1]
                        f.rate = bools[(bits >> 6) & 1]
                        f.appAllowed = bools[(bits >> 7) & 1]
                        f.consented = bools[(bits >> 8) & 1]
                        if f.decision != f.expected { Issue.record("\(f)") }
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 3 * 7 * 4 * 512)
    }

    @Test func aClickIsCheckedAgainAgainstFreshFacts() {
        // What changed while the card waited still counts: rules 1-7 with the click already given.
        func after(_ change: (inout Facts) -> Void) -> ActGate.Decision {
            var f = Facts(kind: .typeText, consented: true)
            change(&f)
            return f.decision
        }
        #expect(after { _ in } == .allow)
        #expect(after { $0.mode = .off } == .refuse(.off))
        #expect(after { $0.known = false } == .refuse(.unknownSession))
        #expect(after { $0.held = true } == .refuse(.sessionHeld))
        #expect(after { $0.ax = false } == .refuse(.noAccessibility))
        #expect(after { $0.target = .unknownWindow } == .refuse(.unknownWindow))
        #expect(after { $0.target = .unknownApp } == .refuse(.unknownApp))
        #expect(after { $0.target = .staleElement } == .refuse(.staleElement))
        #expect(after { $0.excluded = true } == .refuse(.excludedApp))
        #expect(after { $0.secure = true } == .refuse(.secureField))
    }

    @Test func modesAndRefusals() {
        #expect(HandsAccessMode.default == .off)
        #expect(HandsAccessMode(rawValue: "") == nil && HandsAccessMode(rawValue: "perApp") == .perApp)
        #expect(HandsAccessMode.allCases.map(\.title) == ["OFF", "ASK", "PER APP"])
        #expect(Set(HandsAccessMode.allCases.map(\.hint)).count == 3)
        #expect(Set(ActGate.Refusal.allCases.map(\.message)).count == ActGate.Refusal.allCases.count)
        #expect(Set(ActGate.Refusal.allCases.map(\.logLabel)).count == ActGate.Refusal.allCases.count)
        #expect(ActGate.Refusal.staleElement.message.contains("read_window_text"))
        #expect(ActGate.Refusal.noAccessibility.message.contains("Accessibility"))
        #expect(ActGate.Refusal.denied.message == LookGate.Refusal.denied.message)
    }
}

@Suite struct ActExclusionTests {
    let own = "io.github.komilovsg.agenthud"

    @Test func theAlwaysPart() {
        let always = ActExclusions.always(ownBundleId: own)
        for id in [own, "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.systempreferences",
                   "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Passwords"] {
            #expect(always.contains(id), "\(id)")
        }
        // Every password manager of the default look list is in it.
        for id in LookExclusions.defaults { #expect(always.contains(id)) }
        #expect(Set(always.map { $0.lowercased() }).count == always.count)
    }

    @Test func thePersonCannotTakeTheAlwaysPartOff() {
        // With an empty look list the always part still holds.
        for id in ActExclusions.always(ownBundleId: own) {
            #expect(ActExclusions.isExcluded(id, screenExcluded: [], ownBundleId: own), "\(id)")
        }
        #expect(ActExclusions.isExcluded("com.apple.Passwords.MenuBarExtra", screenExcluded: [], ownBundleId: own))
        #expect(ActExclusions.isExcluded("COM.APPLE.LOGINWINDOW", screenExcluded: [], ownBundleId: own))
        #expect(!ActExclusions.isExcluded("com.apple.Safari", screenExcluded: [], ownBundleId: own))
        #expect(!ActExclusions.isExcluded(nil, screenExcluded: [], ownBundleId: own))
    }

    @Test func appsHiddenFromLooksAreNotActedInEither() {
        #expect(ActExclusions.isExcluded("com.tinyspeck.slackmacgap", screenExcluded: ["com.tinyspeck.slackmacgap"], ownBundleId: own))
        let list = ActExclusions.list(screenExcluded: ["com.tinyspeck.slackmacgap", "com.apple.Passwords"], ownBundleId: own)
        #expect(list.contains("com.tinyspeck.slackmacgap"))
        #expect(list.filter { $0 == "com.apple.Passwords" }.count == 1)
    }
}

@Suite struct ActRiskTests {
    private func risky(_ keys: String, in app: String? = "com.apple.TextEdit") -> Bool {
        guard case .success(let combo) = KeyCombo.parse(keys) else { Issue.record("not a combination: \(keys)"); return false }
        return ActRisk.isRisky(combo, targetBundleId: app)
    }

    @Test func combinationsThatCloseOrDelete() {
        let dangerous = [
            "cmd+q", "cmd+shift+q", "control+cmd+q", "cmd+option+q",
            "cmd+shift+w", "cmd+option+w", "cmd+option+shift+w",
            "cmd+delete", "cmd+shift+delete", "cmd+option+delete", "cmd+option+shift+delete",
            "cmd+option+escape", "cmd+option+shift+escape",
        ]
        for keys in dangerous { #expect(risky(keys), "\(keys)") }
    }

    @Test func ordinaryCombinationsAreNotRisky() {
        let fine = [
            "cmd+s", "cmd+w", "cmd+c", "cmd+v", "cmd+z", "cmd+shift+z", "cmd+a", "cmd+f", "cmd+t", "cmd+n", "cmd+escape",
            "q", "shift+q", "control+q", "option+q", "option+shift+w", "delete", "shift+delete", "option+delete", "control+delete",
            "escape", "option+escape", "return", "tab", "shift+tab", "up", "f5", "cmd+forwarddelete",
        ]
        for keys in fine { #expect(!risky(keys), "\(keys)") }
    }

    @Test func anyCommandCombinationInATerminalOrFinder() {
        for app in ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.finder", "com.apple.Finder"] {
            for keys in ["cmd+s", "cmd+k", "cmd+c", "cmd+v", "cmd+w", "cmd+n", "cmd+shift+n", "cmd+up"] {
                #expect(risky(keys, in: app), "\(keys) in \(app)")
            }
            // Without Command nothing changes there.
            for keys in ["return", "control+c", "tab", "up", "shift+a", "option+left"] {
                #expect(!risky(keys, in: app), "\(keys) in \(app)")
            }
        }
        #expect(ActRisk.commandSensitiveApps.count == 3)
        #expect(!risky("cmd+s", in: "com.microsoft.VSCode"))
        #expect(!risky("cmd+s", in: nil))
        #expect(risky("cmd+q", in: nil))
    }
}

@Suite struct KeyComboTests {
    private func parse(_ s: String) -> KeyCombo? {
        if case .success(let c) = KeyCombo.parse(s) { return c }
        return nil
    }

    private func problem(_ s: String) -> String? {
        if case .failure(let p) = KeyCombo.parse(s) { return p.message }
        return nil
    }

    @Test func validCombinations() {
        #expect(parse("cmd+s") == KeyCombo(modifiers: .cmd, key: "s"))
        #expect(parse("shift+tab") == KeyCombo(modifiers: .shift, key: "tab"))
        #expect(parse("escape") == KeyCombo(key: "escape"))
        #expect(parse("return") == KeyCombo(key: "return"))
        #expect(parse("control+option+shift+cmd+f12") == KeyCombo(modifiers: [.control, .option, .shift, .cmd], key: "f12"))
        // Case, spaces and the order of the parts do not matter; neither do the common other spellings.
        #expect(parse("Cmd + S") == parse("cmd+s"))
        #expect(parse("s+cmd") == parse("cmd+s"))
        #expect(parse("command+shift+z") == KeyCombo(modifiers: [.cmd, .shift], key: "z"))
        #expect(parse("ctrl+alt+delete") == KeyCombo(modifiers: [.control, .option], key: "delete"))
        #expect(parse("opt+left") == KeyCombo(modifiers: .option, key: "left"))
        for key in ["up", "down", "left", "right", "home", "end", "pageup", "pagedown", "space", "forwarddelete", "a", "z", "0", "9", "f1",
                    "-", "=", "[", "]", ";", "'", ",", ".", "/", "\\", "`"] {
            #expect(parse(key)?.key == key, "\(key)")
        }
    }

    @Test func invalidCombinations() {
        for bad in ["", "cmd", "cmd+shift", "cmd+", "+s", "cmd++s", "a+b", "cmd+s+d", "cmd s", "cmd-s", "cmds",
                    "meta+s", "win+s", "fn+f1", "hyper+a", "cmd+enter", "cmd+f13", "cmd+ß", "⌘S", "ctrl+c+v",
                    String(repeating: "a", count: 61)] {
            #expect(parse(bad) == nil, "\(bad)")
            #expect(problem(bad)?.isEmpty == false)
        }
    }

    @Test func duplicatesAndUnknownKeysSayWhatIsWrong() {
        #expect(problem("cmd+cmd+s")?.contains("twice") == true)
        #expect(problem("cmd+command+s")?.contains("twice") == true)
        #expect(problem("shift+shift+tab")?.contains("twice") == true)
        #expect(problem("a+b")?.contains("exactly one key") == true)
        #expect(problem("cmd+shift")?.contains("exactly one key") == true)
        let unknown = problem("cmd+enter")
        #expect(unknown?.hasPrefix("Unknown key: \"enter\"") == true)
        // The error lists what can be pressed.
        #expect(unknown?.contains("return") == true && unknown?.contains("cmd, shift, option, control") == true)
    }

    @Test func theKeyTable() {
        // A fixed set: nothing outside it is ever pressed.
        #expect(KeyCombo.keyCodes.count == 26 + 10 + 11 + 14 + 12)
        #expect(Set(KeyCombo.keyCodes.values).count == KeyCombo.keyCodes.count)
        #expect(KeyCombo.keyCodes["a"] == 0 && KeyCombo.keyCodes["s"] == 1 && KeyCombo.keyCodes["q"] == 12 && KeyCombo.keyCodes["w"] == 13)
        #expect(KeyCombo.keyCodes["return"] == 36 && KeyCombo.keyCodes["tab"] == 48 && KeyCombo.keyCodes["space"] == 49)
        #expect(KeyCombo.keyCodes["delete"] == 51 && KeyCombo.keyCodes["escape"] == 53 && KeyCombo.keyCodes["."] == 47)
        #expect(KeyCombo.keyCodes["left"] == 123 && KeyCombo.keyCodes["right"] == 124 && KeyCombo.keyCodes["down"] == 125 && KeyCombo.keyCodes["up"] == 126)
        #expect(KeyCombo.keyCodes["f1"] == 122 && KeyCombo.keyCodes["f12"] == 111)
        #expect(KeyCombo(modifiers: .cmd, key: "s").keyCode == 1)
        // Every key name in the help text is in the table.
        for name in ["return", "tab", "space", "escape", "delete", "forwarddelete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown"] {
            #expect(KeyCombo.keyNamesHelp.contains(name) && KeyCombo.keyCodes[name] != nil)
        }
    }

    @Test func spellingAndSymbols() {
        #expect(parse("s+cmd+shift")?.canonical == "shift+cmd+s")
        #expect(parse("CMD+OPTION+CONTROL+SHIFT+Q")?.canonical == "control+option+shift+cmd+q")
        // The canonical spelling reads back to the same combination.
        for keys in ["cmd+s", "shift+tab", "escape", "control+option+shift+cmd+f12", "cmd+.", "option+\\"] {
            let combo = parse(keys)
            #expect(combo != nil && parse(combo?.canonical ?? "") == combo, "\(keys)")
        }
        #expect(parse("cmd+s")?.symbols == "⌘S")
        #expect(parse("shift+cmd+z")?.symbols == "⇧⌘Z")
        #expect(parse("control+option+cmd+.")?.symbols == "⌃⌥⌘.")
        #expect(parse("shift+tab")?.symbols == "⇧⇥")
        #expect(parse("escape")?.symbols == "⎋" && parse("return")?.symbols == "↩" && parse("cmd+delete")?.symbols == "⌘⌫")
        #expect(parse("option+left")?.symbols == "⌥←" && parse("f5")?.symbols == "F5" && parse("space")?.symbols == "Space")
    }
}

@Suite struct ActTextTests {
    private func valid(_ s: String) -> String? {
        if case .success(let t) = ActText.validate(s) { return t }
        return nil
    }

    @Test func length() {
        #expect(ActText.limit == 2000)
        #expect(valid(String(repeating: "x", count: 2000))?.count == 2000)
        #expect(valid(String(repeating: "x", count: 2001)) == nil)
        #expect(valid("") == nil)
        // Counted in characters, as the card counts them.
        #expect(valid(String(repeating: "é", count: 2000)) != nil)
        #expect(valid(String(repeating: "👍🏽", count: 2000)) != nil)
        if case .failure(let p) = ActText.validate(String(repeating: "x", count: 2500)) {
            #expect(p.message.contains("2500") && p.message.contains("2000"))
        } else {
            Issue.record("expected a problem")
        }
    }

    @Test func printableCharactersTabsAndNewlinesOnly() {
        for good in ["Hello, world!", "tab\there", "line one\nline two", "Grüße", "日本語", "naïve café", "emoji 👍🏽 👨‍👩‍👧", " ", "a\n\n\nb"] {
            #expect(valid(good) == good, "\(good)")
        }
        let bad = ["bell\u{07}", "escape\u{1B}[31m", "null\u{00}", "back\u{08}space", "del\u{7F}", "form\u{0C}feed", "vt\u{0B}",
                   "lone\rreturn", "c1\u{85}", "line\u{2028}sep", "para\u{2029}sep",
                   "rtl\u{202E}override", "isolate\u{2066}x\u{2069}", "mark\u{200F}", "bom\u{FEFF}", "private\u{E000}", "zero\u{200B}width"]
        for text in bad {
            #expect(valid(text) == nil, "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        if case .failure(let p) = ActText.validate("x\u{1B}") { #expect(p.message.contains("U+1B")) } else { Issue.record("expected a problem") }
    }

    @Test func newlines() {
        // Windows line endings become one newline each; the length is counted after that.
        #expect(valid("a\r\nb\r\nc") == "a\nb\nc")
        #expect(valid(String(repeating: "x\r\n", count: 1000))?.count == 2000)
        #expect(valid("only\n") == "only\n")
    }

    @Test func aNewlineIsTypedAsReturnAndATabAsTab() {
        #expect(ActText.chunks("ab\ncd") == [.text("ab"), .returnKey, .text("cd")])
        #expect(ActText.chunks("user\tname\n") == [.text("user"), .tab, .text("name"), .returnKey])
        #expect(ActText.chunks("\n\n") == [.returnKey, .returnKey])
        #expect(ActText.chunks("") == [])
    }

    @Test func textIsTypedInSmallChunks() {
        let long = String(repeating: "abcdefghij", count: 7)   // 70 characters
        let chunks = ActText.chunks(long)
        #expect(chunks.count == 4)
        var joined = ""
        for c in chunks {
            guard case .text(let s) = c else { Issue.record("unexpected key"); continue }
            #expect(s.utf16.count <= ActText.chunkUnits && !s.isEmpty)
            joined += s
        }
        #expect(joined == long)
        // A character is never split between two events.
        let emoji = String(repeating: "👨‍👩‍👧", count: 6)
        var back = ""
        for c in ActText.chunks(emoji) {
            if case .text(let s) = c {
                #expect(s.utf16.count <= ActText.chunkUnits)
                back += s
            }
        }
        #expect(back == emoji)
    }
}

@Suite struct ElementRefTests {
    /// A window with two buttons, a text and a control without a label.
    private func tree(_ first: String = "Send", _ second: String = "Cancel") -> LookNode {
        LookNode(role: "AXWindow", title: "Compose", children: [
            LookNode(role: "AXGroup", children: [
                LookNode(role: "AXButton", title: first, handle: 0),
                LookNode(role: "AXStaticText", value: "Draft saved"),
                LookNode(role: "AXButton", title: second, handle: 1),
            ]),
            LookNode(role: "AXGroup", children: [LookNode(role: "AXGroup")]),
            LookNode(role: "AXCheckBox", handle: 2),
        ])
    }

    @Test func referencesArePrintedInFrontOfPressableElements() {
        var refs = ElementRefs()
        let text = refs.read(window: 7, tree())
        #expect(text == """
        Window "Compose"
          Group
            [e1] Button "Send"
            StaticText: Draft saved
            [e2] Button "Cancel"
          [e3] CheckBox
        """)
        // Without references the text is what it always was; a control without any text is then left out.
        #expect(LookText.render(tree()) == """
        Window "Compose"
          Group
            Button "Send"
            StaticText: Draft saved
            Button "Cancel"
        """)
    }

    @Test func issueAndResolve() {
        var refs = ElementRefs()
        _ = refs.read(window: 7, tree())
        #expect(refs.resolve(window: 7, ref: 1) == ElementRefs.Entry(ref: 1, handle: 0, role: "AXButton", label: "Send"))
        #expect(refs.resolve(window: 7, ref: 2)?.label == "Cancel" && refs.resolve(window: 7, ref: 2)?.handle == 1)
        #expect(refs.resolve(window: 7, ref: 3) == ElementRefs.Entry(ref: 3, handle: 2, role: "AXCheckBox", label: ""))
        // Never printed.
        #expect(refs.resolve(window: 7, ref: 4) == nil && refs.resolve(window: 7, ref: 0) == nil && refs.resolve(window: 7, ref: 999) == nil)
        #expect(refs.next == 4)
    }

    @Test func aReferenceIsStaleOnceTheWindowIsReadAgain() {
        var refs = ElementRefs()
        _ = refs.read(window: 7, tree())
        let again = refs.read(window: 7, tree("Send now"))
        // New numbers: an old reference can never point at another element.
        #expect(again.contains("[e4] Button \"Send now\"") && again.contains("[e5] Button \"Cancel\"") && again.contains("[e6] CheckBox"))
        for old in 1...3 { #expect(refs.resolve(window: 7, ref: old) == nil) }
        #expect(refs.resolve(window: 7, ref: 4)?.label == "Send now")
        #expect(refs.resolve(window: 7, ref: 4)?.handle == 0)
    }

    @Test func referencesBelongToOneWindow() {
        var refs = ElementRefs()
        _ = refs.read(window: 7, tree())
        _ = refs.read(window: 8, tree("Reply"))
        #expect(refs.resolve(window: 7, ref: 1)?.label == "Send")
        #expect(refs.resolve(window: 8, ref: 4)?.label == "Reply")
        // A reference of one window does not work for another.
        #expect(refs.resolve(window: 8, ref: 1) == nil && refs.resolve(window: 7, ref: 4) == nil)
        #expect(refs.resolve(window: 9, ref: 1) == nil)
        // Reading window 8 again leaves window 7 alone.
        _ = refs.read(window: 8, tree())
        #expect(refs.resolve(window: 7, ref: 1)?.label == "Send" && refs.resolve(window: 8, ref: 4) == nil)
        #expect(refs.windowNumbers == [7, 8])
    }

    @Test func referencesGoWithTheirWindow() {
        var refs = ElementRefs()
        _ = refs.read(window: 7, tree())
        _ = refs.read(window: 8, tree())
        refs.prune(keeping: [8])
        #expect(refs.resolve(window: 7, ref: 1) == nil && refs.resolve(window: 8, ref: 4) != nil)
        refs.forget(window: 8)
        #expect(refs.resolve(window: 8, ref: 4) == nil)
        // Numbers are not reused even after everything is forgotten.
        refs.removeAll()
        #expect(refs.read(window: 7, tree()).contains("[e7] Button \"Send\""))
    }

    @Test func aWindowWithNothingToPress() {
        var refs = ElementRefs()
        let text = refs.read(window: 3, LookNode(role: "AXWindow", title: "About", children: [LookNode(role: "AXStaticText", value: "Version 2")]))
        #expect(text == "Window \"About\"\n  StaticText: Version 2")
        #expect(refs.next == 1 && refs.resolve(window: 3, ref: 1) == nil)
    }

    @Test func referenceSpelling() {
        #expect(ActCall.elementId(12) == "e12")
        #expect(ActCall.parseElementId("e12") == 12 && ActCall.parseElementId("e1") == 1)
        for bad in ["", "e", "12", "E12", "e0", "e-1", "e1.5", "e 1", "w12", "e12x", "e1234567890"] {
            #expect(ActCall.parseElementId(bad) == nil, "\(bad)")
        }
    }

    @Test func whichElementsCanBePressed() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXLink"] {
            #expect(ActElements.isPressable(role: role, enabled: true), "\(role)")
            #expect(!ActElements.isPressable(role: role, enabled: false), "\(role)")
        }
        for role in ["AXStaticText", "AXGroup", "AXWindow", "AXTextField", "AXTextArea", "AXImage", ""] {
            #expect(!ActElements.isPressable(role: role, enabled: true), "\(role)")
        }
        #expect(ActElements.roleName("AXButton") == "button" && ActElements.roleName("AXCheckBox") == "checkbox")
        #expect(ActElements.roleName("AXPopUpButton") == "pop-up button" && ActElements.roleName("AXMenuItem") == "menu item")
        #expect(ActElements.roleName("AXRadioButton") == "radio button" && ActElements.roleName("") == "element")
    }
}

@Suite struct ActRateTests {
    @Test func thirtyActionsAMinuteThenAskAgain() {
        var rate = ActRate()
        #expect(ActRate.limit == 30 && ActRate.window == 60)
        for i in 0..<30 {
            #expect(!rate.exceeded("claude:a", at: now.addingTimeInterval(Double(i))), "\(i)")
            rate.record("claude:a", at: now.addingTimeInterval(Double(i)))
        }
        // The thirty-first within the minute is over the limit.
        #expect(rate.exceeded("claude:a", at: now.addingTimeInterval(30)))
        #expect(rate.count("claude:a", at: now.addingTimeInterval(30)) == 30)
        // Another session has its own count.
        #expect(!rate.exceeded("claude:b", at: now.addingTimeInterval(30)))
    }

    @Test func theWindowSlides() {
        var rate = ActRate()
        for i in 0..<30 { rate.record("claude:a", at: now.addingTimeInterval(Double(i))) }
        #expect(rate.exceeded("claude:a", at: now.addingTimeInterval(59.9)))
        // The first action is a minute old: one place is free again.
        #expect(!rate.exceeded("claude:a", at: now.addingTimeInterval(60)))
        #expect(rate.count("claude:a", at: now.addingTimeInterval(60)) == 29)
        rate.record("claude:a", at: now.addingTimeInterval(60))
        #expect(rate.exceeded("claude:a", at: now.addingTimeInterval(60.5)))
        #expect(!rate.exceeded("claude:a", at: now.addingTimeInterval(61)))
        // After a quiet minute nothing counts any more.
        #expect(rate.count("claude:a", at: now.addingTimeInterval(200)) == 0)
    }

    @Test func aBurstIsCountedToo() {
        var rate = ActRate()
        for _ in 0..<29 { rate.record("claude:a", at: now) }
        #expect(!rate.exceeded("claude:a", at: now))
        rate.record("claude:a", at: now)
        #expect(rate.exceeded("claude:a", at: now))
        rate.removeAll()
        #expect(!rate.exceeded("claude:a", at: now))
    }
}

@Suite struct ActAllowanceTests {
    let idA = "0f8fad5b-d9cb-469f-a165-70867728950a", idB = "0f8fad5b-d9cb-469f-a165-70867728950b"

    private func store() -> (SessionStore, String, String) {
        var store = SessionStore()
        let a = store.register(sessionId: idA, cwd: "/Users/dev/acme-web", host: .ownedByHud, now: now)
        let b = store.register(sessionId: idB, cwd: "/Users/dev/acme-api", host: .ownedByHud, now: now)
        return (store, a, b)
    }

    @Test func keyedBySessionAndApp() {
        let (_, a, b) = store()
        var allowances = ActAllowances()
        allowances.sync(mode: .perApp)
        #expect(allowances.isEmpty && !allowances.contains(session: a, bundleId: "com.apple.Notes"))
        allowances.allow(session: a, bundleId: "com.apple.Notes")
        #expect(allowances.contains(session: a, bundleId: "com.apple.Notes"))
        #expect(allowances.contains(session: a, bundleId: "COM.APPLE.NOTES"))
        // Another app, another session: nothing.
        #expect(!allowances.contains(session: a, bundleId: "com.apple.Safari"))
        #expect(!allowances.contains(session: b, bundleId: "com.apple.Notes"))
        // An app that cannot be named cannot be allowed.
        allowances.allow(session: a, bundleId: nil)
        allowances.allow(session: a, bundleId: "")
        #expect(!allowances.contains(session: a, bundleId: nil) && !allowances.contains(session: a, bundleId: ""))
    }

    @Test func endsWithTheSession() {
        let (listed, a, b) = store()
        var store = listed
        var allowances = ActAllowances()
        allowances.sync(mode: .perApp)
        allowances.allow(session: a, bundleId: "com.apple.Notes")
        allowances.allow(session: a, bundleId: "com.apple.Safari")
        allowances.allow(session: b, bundleId: "com.apple.Notes")
        allowances.prune(store)
        #expect(allowances.contains(session: a, bundleId: "com.apple.Notes") && allowances.contains(session: b, bundleId: "com.apple.Notes"))
        _ = store.markEnded(a, now: now.addingTimeInterval(5))
        allowances.prune(store)
        #expect(!allowances.contains(session: a, bundleId: "com.apple.Notes") && !allowances.contains(session: a, bundleId: "com.apple.Safari"))
        #expect(allowances.contains(session: b, bundleId: "com.apple.Notes"))
        // A session that is no longer listed loses its allowances as well.
        store.remove(b)
        allowances.prune(store)
        #expect(allowances.isEmpty)
    }

    @Test func clearedWhenTheModeChanges() {
        let (_, a, _) = store()
        var allowances = ActAllowances()
        allowances.sync(mode: .perApp)
        allowances.allow(session: a, bundleId: "com.apple.Notes")
        // The same mode again changes nothing.
        allowances.sync(mode: .perApp)
        #expect(allowances.contains(session: a, bundleId: "com.apple.Notes"))
        for next in [HandsAccessMode.ask, .off] {
            var copy = allowances
            copy.sync(mode: next)
            #expect(copy.isEmpty, "\(next)")
            // Back in "per app" the old answer is not there any more.
            copy.sync(mode: .perApp)
            #expect(!copy.contains(session: a, bundleId: "com.apple.Notes"))
        }
    }

    @Test func clearedByTheStopSwitch() {
        let (_, a, b) = store()
        var allowances = ActAllowances()
        allowances.sync(mode: .perApp)
        allowances.allow(session: a, bundleId: "com.apple.Notes")
        allowances.allow(session: b, bundleId: "com.apple.Safari")
        allowances.removeAll()
        #expect(allowances.isEmpty)
        // And with the gate: after the stop the app asks again even when the mode is switched back on.
        let decision = ActGate.decide(mode: .perApp, kind: .clickAt, sessionKnown: true, sessionHeld: false, accessibilityGranted: true,
                                      target: .available, targetExcluded: false, secureField: false, riskyKeys: false, rateExceeded: false,
                                      appAllowedForSession: allowances.contains(session: a, bundleId: "com.apple.Notes"))
        #expect(decision == .ask(offersApp: true))
    }
}

@Suite struct ActGeometryTests {
    let frame = CGRect(x: 200, y: 120, width: 800, height: 600)

    @Test func windowPointsBecomeScreenPoints() {
        #expect(ActGeometry.screenPoint(x: 0, y: 0, in: frame) == CGPoint(x: 200, y: 120))
        #expect(ActGeometry.screenPoint(x: 100, y: 50, in: frame) == CGPoint(x: 300, y: 170))
        #expect(ActGeometry.screenPoint(x: 799.5, y: 599.5, in: frame) == CGPoint(x: 999.5, y: 719.5))
        // A window on a display to the left of or above the main one has a negative origin.
        #expect(ActGeometry.screenPoint(x: 10, y: 10, in: CGRect(x: -1440, y: -300, width: 500, height: 400)) == CGPoint(x: -1430, y: -290))
    }

    @Test func pointsOutsideTheWindowAreRefused() {
        for (x, y) in [(-1.0, 10.0), (10.0, -1.0), (800.0, 10.0), (10.0, 600.0), (5000.0, 5000.0), (-0.001, 0.0)] {
            #expect(ActGeometry.screenPoint(x: x, y: y, in: frame) == nil, "\(x), \(y)")
        }
        #expect(ActGeometry.screenPoint(x: .nan, y: 1, in: frame) == nil)
        #expect(ActGeometry.screenPoint(x: 1, y: .infinity, in: frame) == nil)
        #expect(ActGeometry.screenPoint(x: 0, y: 0, in: .zero) == nil)
        #expect(ActGeometry.screenPoint(x: 0, y: 0, in: CGRect(x: 0, y: 0, width: 0, height: 100)) == nil)
    }
}

@Suite struct ActLabelTests {
    let mail = ActSubject(app: "Mail", bundleId: "com.apple.mail", windowTitle: "Inbox", elementRole: "AXButton", elementLabel: "Send")
    let notes = ActSubject(app: "Notes", bundleId: "com.apple.Notes", windowTitle: "Shopping")

    private func call(_ body: ActCall.Body, window: UInt32? = 11) -> ActCall { ActCall(window: window, body: body) }

    private func pending(_ body: ActCall.Body, _ subject: ActSubject, offersApp: Bool = false, risky: Bool = false) -> ActPending {
        ActPending(id: "r", sessionKey: "claude:a", call: call(body), subject: subject, createdAt: now,
                   deadline: now.addingTimeInterval(LookTiming.consentTimeout), offersApp: offersApp, risky: risky)
    }

    @Test func titleForEveryKind() {
        let titles: [ActKind: String] = [
            .pressElement: "Wants to press a button", .clickAt: "Wants to click", .typeText: "Wants to type",
            .pressKeys: "Wants to press keys", .scroll: "Wants to scroll", .focusWindow: "Wants to bring a window forward",
            .openApp: "Wants to open an app",
        ]
        #expect(titles.count == ActKind.allCases.count)
        for kind in ActKind.allCases {
            #expect(ActLabels.title(kind) == titles[kind])
            #expect(!ActLabels.symbol(kind).isEmpty)
        }
    }

    @Test func press() {
        let p = pending(.pressElement(element: 12), mail)
        #expect(p.title == "Wants to press a button")
        #expect(p.targetLine == "Mail — Inbox")
        #expect(p.detail == "Press button \"Send\"")
        #expect(p.typedText == nil && p.typeNote == nil)
        #expect(ActLabels.done(p.call, mail) == "Pressed button \"Send\" in Mail")
        // An element without a label is named by its role alone.
        let bare = ActSubject(app: "Mail", windowTitle: "Inbox", elementRole: "AXCheckBox", elementLabel: "")
        #expect(pending(.pressElement(element: 3), bare).detail == "Press checkbox")
        #expect(ActLabels.done(call(.pressElement(element: 3)), bare) == "Pressed checkbox in Mail")
    }

    @Test func click() {
        #expect(pending(.clickAt(x: 120, y: 48, button: .left, count: 1), notes).detail == "Click at (120, 48)")
        #expect(pending(.clickAt(x: 120.4, y: 48.6, button: .left, count: 2), notes).detail == "Double-click at (120, 49)")
        #expect(pending(.clickAt(x: 5, y: 6, button: .right, count: 1), notes).detail == "Right-click at (5, 6)")
        #expect(pending(.clickAt(x: 5, y: 6, button: .right, count: 1), notes).targetLine == "Notes — Shopping")
        #expect(ActLabels.done(call(.clickAt(x: 120, y: 48, button: .left, count: 1)), notes) == "Clicked at (120, 48) in Notes — Shopping")
        #expect(ActLabels.done(call(.clickAt(x: 1, y: 2, button: .left, count: 2)), notes) == "Double-clicked at (1, 2) in Notes — Shopping")
        #expect(ActLabels.done(call(.clickAt(x: 1, y: 2, button: .right, count: 1)), notes) == "Right-clicked at (1, 2) in Notes — Shopping")
    }

    @Test func typing() {
        let text = "milk\neggs\tx2\n"
        let p = pending(.typeText(text), notes)
        #expect(p.title == "Wants to type" && p.targetLine == "Notes — Shopping" && p.detail == nil)
        // The whole text, with every newline marked and still on its own line.
        #expect(p.typedText == "milk⏎\neggs⇥x2⏎\n")
        #expect(p.typeNote == "types 13 characters")
        #expect(ActLabels.typeNote("x") == "types 1 character")
        let long = String(repeating: "line of text\n", count: 150)
        #expect(pending(.typeText(long), notes).typedText?.filter { $0 == "⏎" }.count == 150)
        #expect(pending(.typeText(long), notes).typedText?.count == long.count + 150)
        #expect(ActLabels.done(p.call, notes) == "Typed 13 characters into Notes — Shopping")
        // The answer to the agent does not repeat the text.
        #expect(!ActLabels.done(p.call, notes).contains("milk"))
    }

    @Test func keys() {
        let save = KeyCombo(modifiers: .cmd, key: "s")
        let p = pending(.pressKeys(save), notes)
        #expect(p.detail == "⌘S" && p.title == "Wants to press keys" && !p.risky)
        #expect(ActLabels.done(p.call, notes) == "Pressed ⌘S in Notes — Shopping")
        let quit = pending(.pressKeys(KeyCombo(modifiers: .cmd, key: "q")), notes, risky: true)
        #expect(quit.risky && quit.detail == "⌘Q")
        #expect(ActLabels.riskyNote == "This key combination can close or delete things")
    }

    @Test func scrollFocusAndOpen() {
        #expect(pending(.scroll(dx: 0, dy: 5), notes).detail == "Scroll down 5 lines")
        #expect(pending(.scroll(dx: 0, dy: -1), notes).detail == "Scroll up 1 line")
        #expect(pending(.scroll(dx: 3, dy: 0), notes).detail == "Scroll right 3 lines")
        #expect(pending(.scroll(dx: -2, dy: 4), notes).detail == "Scroll down 4 lines and left 2 lines")
        #expect(ActLabels.done(call(.scroll(dx: 0, dy: 5)), notes) == "Scrolled down 5 lines in Notes — Shopping")
        let focus = pending(.focusWindow, notes)
        #expect(focus.title == "Wants to bring a window forward" && focus.targetLine == "Notes — Shopping" && focus.detail == nil)
        #expect(ActLabels.done(focus.call, notes) == "Brought Notes — Shopping to the front")
        let app = ActSubject(app: "Notes", bundleId: "com.apple.Notes")
        let open = ActPending(id: "r", sessionKey: "claude:a", call: call(.openApp(.name("notes")), window: nil), subject: app,
                              createdAt: now, deadline: now, offersApp: true)
        #expect(open.title == "Wants to open an app" && open.targetLine == "Notes (com.apple.Notes)" && open.detail == nil)
        #expect(ActLabels.done(open.call, app) == "Opened Notes")
        // A window without a title is named by its app alone.
        #expect(ActSubject(app: "Finder").label == "Finder")
    }

    @Test func buttonsAndTheStopNotice() {
        #expect(ActLabels.allowInApp("Mail") == "Allow in Mail for this session")
        #expect(ActLabels.stoppedNotice(at: "14:32") == "Agent actions are off — stopped at 14:32")
        #expect(ActLabels.stopTitle == "Stop agent actions" && ActLabels.stopHotKey == "⌃⌥⌘.")
        #expect(pending(.focusWindow, notes).deadline.timeIntervalSince(now) == 120)
    }

    @Test func theLogKeepsOnlyTheStartOfTypedText() {
        let secret = "The quick brown fox jumps over the lazy dog and then keeps running for a very long time"
        let typed = call(.typeText(secret))
        let summary = ActLabels.summary(typed, notes)
        #expect(summary == "Type \"The quick brown fox jumps over the lazy …\" (\(secret.count) characters) into Notes — Shopping")
        #expect(!summary.contains("keeps running"))
        // Short text is kept whole, on one line.
        #expect(ActLabels.summary(call(.typeText("a\nb\tc")), notes) == "Type \"a b c\" (5 characters) into Notes — Shopping")
        #expect(ActLabels.summary(call(.pressElement(element: 1)), mail) == "Press button \"Send\" in Mail")
        #expect(ActLabels.summary(call(.pressKeys(KeyCombo(modifiers: .cmd, key: "s"))), notes) == "Press ⌘S in Notes — Shopping")
        #expect(ActLabels.summary(call(.openApp(.name("Notes")), window: nil), ActSubject(app: "Notes")) == "Open Notes")
        // The row on the session's card.
        #expect(ActLabels.didRow(call(.pressElement(element: 1)), mail) == "Did: pressed button \"Send\" in Mail")
        #expect(ActLabels.didRow(typed, notes).hasPrefix("Did: typed \"The quick brown fox"))
        #expect(!ActLabels.didRow(typed, notes).contains("keeps running"))
    }

    @Test func actRecordInTheActivityLog() throws {
        let text = "hunter2 and a much longer sentence that must not be kept in the log at all"
        let typed = call(.typeText(text))
        let r = ActivityRecord(kind: .act, time: now, agent: "claude", session: "s1", project: "acme-web", cwd: "/Users/dev/acme-web",
                               text: RequestLog.clip("type_text: \(ActLabels.summary(typed, notes))"), detail: "allowed in app")
        let back = try #require(ActivityRecord(json: try JSONValue.parse(r.toJSON().compact())))
        #expect(back == r && back.kind == .act)
        #expect(back.text.contains("Notes") && back.text.contains("(\(text.count) characters)") && !back.text.contains("must not be kept"))
        // Actions are a record only: they are neither tasks nor HUD decisions.
        let projects = DailySummary.build([r])
        #expect(projects.isEmpty)
    }
}
