import Darwin
import Foundation
import Testing
@testable import AgentHudCore

// Agents looking at the screen: the consent gate, what is left out, sizes and caps, and the helper's exchange with the app.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func window(_ n: UInt32, _ app: String, _ bundle: String?, title: String = "", front: Bool = false) -> WindowInfo {
    WindowInfo(number: n, app: app, bundleId: bundle, pid: Int32(n), title: title, width: 1200, height: 800, frontmost: front)
}

private let sampleWindows = [
    window(11, "Safari", "com.apple.Safari", title: "Start Page", front: true),
    window(12, "1Password", "com.1password.1password", title: "Vault"),
    window(13, "Passwords", "com.apple.Passwords.MenuBarExtra"),
    window(14, "Notes", "com.apple.Notes", title: "Shopping"),
    window(15, "Helper", nil),
]

@Suite struct LookGateTests {
    @Test func decisionTable() {
        typealias D = LookGate.Decision
        struct Row {
            var mode: ScreenAccessMode, tool: LookTool, known: Bool, allowed: Bool
            var target = LookGate.TargetState.available, screen = true, ax = true
            var expect: D
        }
        var rows: [Row] = []
        // Off: refused whatever else is true.
        for tool in LookTool.allCases {
            for known in [false, true] {
                for allowed in [false, true] {
                    rows.append(Row(mode: .off, tool: tool, known: known, allowed: allowed, expect: .refuse(.off)))
                }
            }
        }
        rows.append(Row(mode: .off, tool: .screenshot, known: true, allowed: true, target: .excludedApp, screen: false, expect: .refuse(.off)))
        for mode in [ScreenAccessMode.ask, .session] {
            for tool in LookTool.allCases {
                // No allowance: ask; only a known session in "session" mode is offered the lasting answer.
                let lasting = mode == .session
                rows.append(Row(mode: mode, tool: tool, known: true, allowed: false, expect: .ask(offersSession: lasting)))
                rows.append(Row(mode: mode, tool: tool, known: false, allowed: false, expect: .ask(offersSession: false)))
                // The allowance lets a known session through only in "session" mode; "ask" asks again.
                rows.append(Row(mode: mode, tool: tool, known: true, allowed: true, expect: lasting ? .allow : .ask(offersSession: false)))
                rows.append(Row(mode: mode, tool: tool, known: false, allowed: true, expect: .ask(offersSession: false)))
                // A target that cannot be looked at is refused even for an allowed session.
                for allowed in [false, true] {
                    rows.append(Row(mode: mode, tool: tool, known: true, allowed: allowed, target: .excludedApp, expect: .refuse(.excludedApp)))
                    rows.append(Row(mode: mode, tool: tool, known: true, allowed: allowed, target: .unknownWindow, expect: .refuse(.unknownWindow)))
                }
            }
            // Missing permissions: only the tool that needs the permission is refused.
            for allowed in [false, true] {
                rows.append(Row(mode: mode, tool: .screenshot, known: true, allowed: allowed, screen: false, expect: .refuse(.noScreenRecording)))
                rows.append(Row(mode: mode, tool: .readWindowText, known: true, allowed: allowed, ax: false, expect: .refuse(.noAccessibility)))
            }
            rows.append(Row(mode: mode, tool: .screenshot, known: true, allowed: true, ax: false,
                            expect: mode == .session ? .allow : .ask(offersSession: false)))
            rows.append(Row(mode: mode, tool: .readWindowText, known: true, allowed: true, screen: false,
                            expect: mode == .session ? .allow : .ask(offersSession: false)))
            rows.append(Row(mode: mode, tool: .listWindows, known: false, allowed: false, screen: false, ax: false, expect: .ask(offersSession: false)))
            // The excluded target is reported before the missing permission.
            rows.append(Row(mode: mode, tool: .screenshot, known: true, allowed: true, target: .excludedApp, screen: false, expect: .refuse(.excludedApp)))
        }
        for r in rows {
            let got = LookGate.decide(mode: r.mode, tool: r.tool, sessionKnown: r.known, sessionAllowed: r.allowed,
                                      target: r.target, screenRecording: r.screen, accessibility: r.ax)
            #expect(got == r.expect, "\(r)")
        }
        #expect(rows.count > 40)
    }

    @Test func aClickAllowsOnlyWhatIsStillPossible() {
        func after(_ mode: ScreenAccessMode, _ tool: LookTool = .screenshot, known: Bool = false,
                   target: LookGate.TargetState = .available, screen: Bool = true, ax: Bool = true) -> LookGate.Decision {
            LookGate.decide(mode: mode, tool: tool, sessionKnown: known, sessionAllowed: false, consented: true,
                            target: target, screenRecording: screen, accessibility: ax)
        }
        #expect(after(.ask) == .allow)
        #expect(after(.session, known: true) == .allow)
        // What changed while the card was waiting still counts.
        #expect(after(.off) == .refuse(.off))
        #expect(after(.ask, target: .excludedApp) == .refuse(.excludedApp))
        #expect(after(.ask, target: .unknownWindow) == .refuse(.unknownWindow))
        #expect(after(.ask, screen: false) == .refuse(.noScreenRecording))
        #expect(after(.ask, .readWindowText, ax: false) == .refuse(.noAccessibility))
    }

    @Test func targetState() {
        let excluded = LookExclusions.defaults
        #expect(LookGate.targetState(.none, windows: [], excluded: excluded) == .available)
        #expect(LookGate.targetState(.screen, windows: [], excluded: excluded) == .available)
        #expect(LookGate.targetState(.window(11), windows: sampleWindows, excluded: excluded) == .available)
        #expect(LookGate.targetState(.window(12), windows: sampleWindows, excluded: excluded) == .excludedApp)
        #expect(LookGate.targetState(.window(13), windows: sampleWindows, excluded: excluded) == .excludedApp)
        #expect(LookGate.targetState(.window(99), windows: sampleWindows, excluded: excluded) == .unknownWindow)
        #expect(LookGate.targetState(.window(11), windows: sampleWindows, excluded: ["com.apple.safari"]) == .excludedApp)
        #expect(LookGate.targetState(.window(12), windows: sampleWindows, excluded: []) == .available)
    }

    @Test func refusalsSayWhatIsMissing() {
        #expect(LookGate.Refusal.denied.message == "The person did not allow this")
        #expect(LookGate.Refusal.noScreenRecording.message.contains("Screen Recording"))
        #expect(LookGate.Refusal.noAccessibility.message.contains("Accessibility"))
        #expect(LookGate.Refusal.noScreenRecording.missingPermission == .screenRecording)
        #expect(LookGate.Refusal.noAccessibility.missingPermission == .accessibility)
        #expect(LookGate.Refusal.denied.missingPermission == nil && LookGate.Refusal.off.missingPermission == nil)
        let all: [LookGate.Refusal] = [.off, .unknownWindow, .excludedApp, .noScreenRecording, .noAccessibility, .denied, .expired, .failed]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(Set(all.map(\.logLabel)).count == all.count)
    }

    @Test func modes() {
        #expect(ScreenAccessMode.default == .ask)
        #expect(ScreenAccessMode(rawValue: "off") == .off && ScreenAccessMode(rawValue: "session") == .session)
        #expect(ScreenAccessMode(rawValue: "always") == nil)
        #expect(Set(ScreenAccessMode.allCases.map(\.title)).count == 3)
    }
}

@Suite struct LookAllowanceTests {
    let id = "0f8fad5b-d9cb-469f-a165-70867728950e"

    @Test func allowanceEndsWithTheSession() {
        var store = SessionStore()
        let key = store.register(sessionId: id, cwd: "/Users/dev/acme-web", host: .ownedByHud, now: now)
        let other = store.register(sessionId: "0f8fad5b-d9cb-469f-a165-70867728950f", cwd: "/Users/dev/acme-api", host: .ownedByHud, now: now)
        var allowances = LookAllowances()
        #expect(!allowances.contains(key))
        allowances.allow(key)
        allowances.allow(other)
        allowances.prune(store)
        #expect(allowances.contains(key) && allowances.contains(other))

        // The session ends (its process died): the allowance goes, the other session keeps its own.
        _ = store.markEnded(key, now: now.addingTimeInterval(5))
        allowances.prune(store)
        #expect(!allowances.contains(key))
        #expect(allowances.contains(other))

        // Continuing the same session id later starts without an allowance.
        store.register(sessionId: id, cwd: "/Users/dev/acme-web", host: .ownedByHud, now: now.addingTimeInterval(60))
        allowances.prune(store)
        #expect(!allowances.contains(key))
    }

    @Test func allowanceEndsOnSessionEndEventAndOnRemoval() {
        var store = SessionStore()
        func event(_ body: AgentEvent.Body, _ t: TimeInterval) -> AgentEvent {
            AgentEvent(kind: .claude, sessionId: id, cwd: "/Users/dev/acme-web", time: now.addingTimeInterval(t), body: body)
        }
        store.apply(event(.sessionStarted(source: nil, model: nil), 0))
        store.apply(event(.promptSubmitted("look at the page"), 1))
        let key = "claude:\(id)"
        var allowances = LookAllowances()
        allowances.allow(key)
        allowances.prune(store)
        #expect(allowances.contains(key))
        store.apply(event(.sessionEnded(reason: nil), 10))
        allowances.prune(store)
        #expect(!allowances.contains(key))

        // A session that is no longer listed at all.
        allowances.allow(key)
        store.remove(key)
        allowances.prune(store)
        #expect(allowances.sessions.isEmpty)

        allowances.allow("claude:x")
        allowances.removeAll()
        #expect(allowances.sessions.isEmpty)
    }
}

@Suite struct LookExclusionTests {
    @Test func defaults() {
        #expect(LookExclusions.defaults == ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
                                            "com.apple.Passwords", "com.apple.systempreferences"])
        #expect(LookExclusions.defaults.allSatisfy(LookExclusions.isBundleId))
    }

    @Test func excludedWindowsAreLeftOut() {
        let left = LookExclusions.filter(sampleWindows, excluded: LookExclusions.defaults)
        #expect(left.map(\.number) == [11, 14, 15])
        #expect(LookExclusions.filter(sampleWindows, excluded: []).count == sampleWindows.count)
        #expect(LookExclusions.filter(sampleWindows, excluded: ["com.apple.notes", "COM.APPLE.SAFARI"]).map(\.number) == [12, 13, 15])
    }

    @Test func matching() {
        let ex = ["com.apple.Passwords", "com.1password.1password"]
        #expect(LookExclusions.isExcluded("com.apple.Passwords", excluded: ex))
        #expect(LookExclusions.isExcluded("com.apple.passwords", excluded: ex))
        // An app's helpers are covered by the app's id...
        #expect(LookExclusions.isExcluded("com.apple.Passwords.MenuBarExtra", excluded: ex))
        // ...but a different app whose id merely starts the same way is not.
        #expect(!LookExclusions.isExcluded("com.apple.PasswordsTool", excluded: ex))
        #expect(!LookExclusions.isExcluded("com.apple", excluded: ex))
        #expect(!LookExclusions.isExcluded(nil, excluded: ex))
        #expect(!LookExclusions.isExcluded("", excluded: ex + [""]))
        #expect(!LookExclusions.isExcluded("com.apple.Safari", excluded: [""]))
    }

    @Test func settingsList() {
        #expect(LookExclusions.normalized([" com.apple.Notes ", "com.apple.notes", "", "notabundle", "com.x.y", "a b.c", "com.x.y"])
                == ["com.apple.Notes", "com.x.y"])
        for bad in ["", "safari", ".com.x", "com.x.", "com x.y", "com.x/y", "com.x;rm", "com.\u{43F}.y"] {
            #expect(!LookExclusions.isBundleId(bad), "\(bad)")
        }
        #expect(LookExclusions.isBundleId("com.todesktop.230313mzl4w4u92") && LookExclusions.isBundleId("org.my-app.tool_2"))
    }
}

@Suite struct LookCallerTests {
    typealias C = LookCallerResolver.Candidate

    @Test func theNearestAgentProcessDecides() {
        let sessions = [
            C(key: "claude:a", sessionId: "a", pid: 500, ended: false, lastEventAt: now),
            C(key: "claude:b", sessionId: "b", pid: 700, ended: false, lastEventAt: now),
            C(key: "claude:c", sessionId: "c", pid: nil, ended: false, lastEventAt: now),
        ]
        #expect(LookCallerResolver.resolve(chain: [500, 400, 1], claimedSessionId: nil, candidates: sessions) == "claude:a")
        #expect(LookCallerResolver.resolve(chain: [650, 700, 300], claimedSessionId: nil, candidates: sessions) == "claude:b")
        // A helper started by one session's agent inside another session's terminal: the nearer process wins.
        #expect(LookCallerResolver.resolve(chain: [700, 500], claimedSessionId: nil, candidates: sessions) == "claude:b")
        #expect(LookCallerResolver.resolve(chain: [9, 8, 7], claimedSessionId: nil, candidates: sessions) == nil)
        #expect(LookCallerResolver.resolve(chain: [], claimedSessionId: nil, candidates: sessions) == nil)
    }

    @Test func aClaimedIdAloneProvesNothing() {
        let sessions = [C(key: "claude:a", sessionId: "a", pid: 500, ended: false, lastEventAt: now),
                        C(key: "claude:c", sessionId: "c", pid: nil, ended: false, lastEventAt: now)]
        #expect(LookCallerResolver.resolve(chain: [9, 8], claimedSessionId: "a", candidates: sessions) == nil)
        #expect(LookCallerResolver.resolve(chain: [9, 8], claimedSessionId: "c", candidates: sessions) == nil)
        // It cannot move the caller to another process's session either.
        let two = sessions + [C(key: "claude:b", sessionId: "b", pid: 700, ended: false, lastEventAt: now)]
        #expect(LookCallerResolver.resolve(chain: [500], claimedSessionId: "b", candidates: two) == "claude:a")
    }

    @Test func oneProcessWithSeveralConversations() {
        // The same process started a new conversation: the old one ended, or is at least older.
        let sessions = [
            C(key: "claude:old", sessionId: "old", pid: 500, ended: true, lastEventAt: now.addingTimeInterval(50)),
            C(key: "claude:mid", sessionId: "mid", pid: 500, ended: false, lastEventAt: now.addingTimeInterval(10)),
            C(key: "claude:new", sessionId: "new", pid: 500, ended: false, lastEventAt: now.addingTimeInterval(20)),
        ]
        #expect(LookCallerResolver.resolve(chain: [500], claimedSessionId: nil, candidates: sessions) == "claude:new")
        #expect(LookCallerResolver.resolve(chain: [500], claimedSessionId: "mid", candidates: sessions) == "claude:mid")
        // An ended session is never the caller, even when claimed.
        #expect(LookCallerResolver.resolve(chain: [500], claimedSessionId: "old", candidates: sessions) == "claude:new")
        #expect(LookCallerResolver.resolve(chain: [500], claimedSessionId: nil, candidates: [sessions[0]]) == nil)
    }
}

@Suite struct LookImageTests {
    @Test func requestedSideIsClamped() {
        #expect(LookImage.maxSide(nil) == 1568)
        #expect(LookImage.maxSide(800) == 800)
        #expect(LookImage.maxSide(2000) == 2000)
        #expect(LookImage.maxSide(2001) == 2000)
        #expect(LookImage.maxSide(1_000_000) == 2000)
        #expect(LookImage.maxSide(64) == 64)
        #expect(LookImage.maxSide(1) == 64)
        #expect(LookImage.maxSide(0) == 64)
        #expect(LookImage.maxSide(-9) == 64)
    }

    @Test func scalingKeepsProportionsAndNeverEnlarges() {
        func size(_ w: Int, _ h: Int, _ m: Int) -> [Int] { let s = LookImage.scaledSize(width: w, height: h, maxSide: m); return [s.width, s.height] }
        #expect(size(3456, 2234, 1568) == [1568, 1014])
        #expect(size(2234, 3456, 1568) == [1014, 1568])
        #expect(size(1440, 900, 1568) == [1440, 900])       // already small enough
        #expect(size(1568, 1568, 1568) == [1568, 1568])
        #expect(size(5120, 2880, 2000) == [2000, 1125])
        #expect(size(4000, 4000, 64) == [64, 64])
        #expect(size(10000, 10, 100) == [100, 1])           // a sliver keeps at least one pixel
        #expect(size(0, 0, 1568) == [1, 1])
        #expect(size(100, 50, 0) == [1, 1])
        for (w, h) in [(3024, 1964), (1920, 1080), (801, 600), (7, 5000)] {
            for m in [64, 800, 1568, 2000] {
                let s = LookImage.scaledSize(width: w, height: h, maxSide: m)
                #expect(max(s.width, s.height) <= max(m, 1) && s.width >= 1 && s.height >= 1)
                #expect(s.width <= w && s.height <= h)
            }
        }
    }

    @Test func formatChoice() {
        #expect(LookImage.triesPNG(width: 640, height: 480))
        #expect(!LookImage.triesPNG(width: 1568, height: 1014))
        #expect(LookImage.keepsPNG(bytes: 399_999) && !LookImage.keepsPNG(bytes: 400_001))
        #expect(LookImage.jpegQuality == 0.8)
        #expect(LookImage.caption(what: "Safari — Start Page", width: 1568, height: 1014, mimeType: "image/jpeg")
                == "Screenshot of Safari — Start Page, 1568×1014 px, JPEG")
        #expect(LookImage.caption(what: "the screen", width: 320, height: 200, mimeType: "image/png").hasSuffix("320×200 px, PNG"))
    }
}

@Suite struct LookTextTests {
    @Test func capWithANote() {
        #expect(LookText.limit == 20_000)
        let short = String(repeating: "a", count: 20_000)
        #expect(LookText.cap(short) == short)
        let long = String(repeating: "b", count: 20_001) + "tail"
        let capped = LookText.cap(long)
        #expect(capped.hasPrefix(String(repeating: "b", count: 20_000) + "\n[Truncated"))
        #expect(capped.hasSuffix("[Truncated: the first 20000 of 20005 characters are shown]"))
        #expect(!capped.contains("tail"))
        #expect(LookText.cap("abcdef", limit: 3) == "abc\n[Truncated: the first 3 of 6 characters are shown]")
        #expect(LookText.cap("", limit: 3) == "")
    }

    @Test func treeAsIndentedRolesAndValues() {
        let tree = LookNode(role: "AXWindow", title: "Checkout", children: [
            LookNode(role: "AXGroup", children: [
                LookNode(role: "AXStaticText", value: "Total: 42 USD"),
                LookNode(role: "AXTextField", title: "Coupon", value: "SPRING"),
                LookNode(role: "AXGroup", children: [LookNode(role: "AXImage"), LookNode(role: "AXGroup")]),
            ]),
            LookNode(role: "AXButton", title: "Pay"),
            LookNode(role: "AXTextArea", value: "line one\nline two"),
            LookNode(role: "AXStaticText", title: "Same", value: "Same"),
            LookNode(role: "", title: "bare"),
        ])
        #expect(LookText.render(tree) == """
        Window "Checkout"
          Group
            StaticText: Total: 42 USD
            TextField "Coupon": SPRING
          Button "Pay"
          TextArea: line one line two
          StaticText "Same"
          Element "bare"
        """)
        // Nothing with text anywhere: nothing is printed.
        #expect(LookText.render(LookNode(role: "AXWindow", children: [LookNode(role: "AXGroup")])) == "")
        // One very long value does not take the whole budget.
        let big = LookText.render(LookNode(role: "AXStaticText", value: String(repeating: "x", count: 5000)))
        #expect(big.count < 2100 && big.hasSuffix("…"))
    }

    @Test func windowList() {
        let text = LookText.windowList(LookExclusions.filter(sampleWindows, excluded: LookExclusions.defaults))
        #expect(text == """
        3 windows, front to back:
        w11  Safari — "Start Page"  1200×800  frontmost
        w14  Notes — "Shopping"  1200×800
        w15  Helper  1200×800
        """)
        #expect(!text.contains("1Password") && !text.contains("Vault") && !text.contains("Passwords"))
        #expect(LookText.windowList([]) == "No windows are on screen.")
        #expect(LookText.windowList([sampleWindows[0]]).hasPrefix("1 window, front to back:"))
        #expect(LookText.windowList([sampleWindows[4]], titlesAvailable: false).hasSuffix("Screen Recording permission."))
    }

    @Test func cardTexts() {
        let w = sampleWindows[0]
        #expect(LookLabels.title(LookCall(tool: .screenshot, target: .screen)) == "Wants to see the screen")
        #expect(LookLabels.title(LookCall(tool: .screenshot, target: .window(11))) == "Wants to see a window")
        #expect(LookLabels.title(LookCall(tool: .readWindowText, target: .window(11))) == "Wants to read a window's text")
        #expect(LookLabels.title(LookCall(tool: .listWindows)) == "Wants the list of open windows")
        #expect(LookLabels.pictureNote == "The picture is sent to the model")

        let shot = LookPending(id: "r", sessionKey: "claude:a", call: LookCall(tool: .screenshot, target: .window(11)), window: w,
                               createdAt: now, deadline: now.addingTimeInterval(LookTiming.consentTimeout), offersSession: true)
        #expect(shot.targetLine == "Safari — Start Page")
        #expect(shot.sendsPicture && shot.deadline.timeIntervalSince(shot.createdAt) == 120)
        let text = LookPending(id: "r", sessionKey: "claude:a", call: LookCall(tool: .readWindowText, target: .window(11)), window: w,
                               createdAt: now, deadline: now, offersSession: true)
        #expect(!text.sendsPicture && text.targetLine == "Safari — Start Page")
        let screen = LookCall(tool: .screenshot, target: .screen)
        #expect(LookLabels.target(screen, window: nil, frontApp: "Safari") == "The display with Safari in front")
        #expect(LookLabels.target(screen, window: nil, frontApp: nil) == "The display under the frontmost window")
        #expect(LookLabels.subject(screen, window: nil) == "the screen")
        #expect(LookLabels.subject(LookCall(tool: .readWindowText, target: .window(11)), window: w) == "text of Safari — Start Page")
        #expect(LookLabels.subject(LookCall(tool: .listWindows), window: nil) == "the list of open windows")
        #expect(window(1, "Finder", nil).label == "Finder")
    }
}

@Suite struct LookWireTests {
    @Test func windowIds() {
        #expect(LookTarget.windowId(4021) == "w4021")
        #expect(LookTarget.parseWindowId("w4021") == 4021)
        #expect(LookTarget.parseWindowId("w0") == 0)
        #expect(LookTarget.parseWindowId("w4294967295") == UInt32.max)
        for bad in ["", "w", "4021", "W1", "w-1", "w1.5", "w 1", "w4294967296", "w12345678901", "screen", "w1x"] {
            #expect(LookTarget.parseWindowId(bad) == nil, "\(bad)")
        }
    }

    @Test func requestRoundTrip() throws {
        let deadline = Date(timeIntervalSince1970: 1_800_000_140)
        let requests = [
            LookRequest(requestId: "r1", call: LookCall(tool: .listWindows), sessionId: nil, deadline: deadline),
            LookRequest(requestId: "r2", call: LookCall(tool: .screenshot, target: .screen, maxSide: 800), sessionId: "0f8fad5b", deadline: deadline),
            LookRequest(requestId: "r3", call: LookCall(tool: .screenshot, target: .window(77), maxSide: 2000), sessionId: nil, deadline: deadline),
            LookRequest(requestId: "r4", call: LookCall(tool: .readWindowText, target: .window(5)), sessionId: "s", deadline: deadline),
        ]
        for r in requests {
            let line = r.encode()
            #expect(!line.contains("\n"))
            #expect(LookRequest.decode(line) == r)
            // A look is not a hook message, and a hook message is not a look.
            #expect(HookMessage.decode(line) == nil)
        }
        let hook = HookMessage(agent: .claude, mode: .gate, requestId: "g", deadline: deadline, host: HostInfo(),
                               payload: ["session_id": "x", "look": "screenshot"]).encode()
        #expect(LookRequest.decode(hook) == nil)
    }

    @Test func requestsThatDoNotFitAreDropped() {
        func line(_ fields: String) -> String { "{\"v\":1,\"request_id\":\"r\",\"deadline\":1800000140,\(fields)}" }
        #expect(LookRequest.decode(line(#""look":"screenshot","target":"screen""#)) != nil)
        // The size is clamped again on arrival.
        #expect(LookRequest.decode(line(#""look":"screenshot","target":"screen","max_side":90000"#))?.call.maxSide == 2000)
        let bad = [
            #""look":"click","target":"screen""#, #""look":"screenshot""#, #""look":"screenshot","target":"desk""#,
            #""look":"screenshot","target":7"#, #""look":"list_windows","target":"screen""#,
            #""look":"read_window_text","target":"screen""#, #""look":"read_window_text""#, #""look":"list_windows","target":"w1""#,
        ]
        for fields in bad { #expect(LookRequest.decode(line(fields)) == nil, "\(fields)") }
        #expect(LookRequest.decode(#"{"look":"list_windows","request_id":"","deadline":1}"#) == nil)
        #expect(LookRequest.decode(#"{"look":"list_windows","request_id":"r"}"#) == nil)
        #expect(LookRequest.decode("not json") == nil)
    }

    @Test func replyRoundTrip() {
        let outcomes: [LookReply.Outcome] = [
            .text("2 windows\nw1  Safari"), .text(""),
            .image(data: "iVBORw0KGgo=", mimeType: "image/png", caption: "Screenshot of the screen, 2×2 px, PNG"),
            .image(data: "/9j/4AAQ", mimeType: "image/jpeg", caption: ""),
            .refused("The person did not allow this"),
        ]
        for o in outcomes {
            let line = LookReply(requestId: "r1", outcome: o).encode()
            #expect(!line.contains("\n"))
            #expect(LookReply.decode(line) == LookReply(requestId: "r1", outcome: o))
            #expect(HookReply.decode(line) == nil)
        }
        #expect(LookReply.decode(#"{"request_id":"r","look_reply":"image","text":"x","mime":"image/png"}"#) == nil)
        #expect(LookReply.decode(#"{"request_id":"r","look_reply":"image","text":"x","data":"QQ==","mime":"text/html"}"#) == nil)
        #expect(LookReply.decode(#"{"request_id":"r","look_reply":"video","text":"x"}"#) == nil)
        #expect(LookReply.decode(#"{"request_id":"r","decision":"allow"}"#) == nil)
    }

    @Test func helperWaitsLongerThanTheCard() {
        #expect(LookTiming.consentTimeout == 120)
        #expect(LookTiming.helperTimeout > LookTiming.consentTimeout)
    }
}

/// A stand-in for the app: listens on a socket, reads one request and answers what the test says.
private final class FakeApp: @unchecked Sendable {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [LookRequest] = []
        func add(_ r: LookRequest) { lock.lock(); list.append(r); lock.unlock() }
        var all: [LookRequest] { lock.lock(); defer { lock.unlock() }; return list }
    }

    let path: String
    private let listenFD: Int32
    private let seen = Seen()

    var requests: [LookRequest] { seen.all }

    /// `respond` returns the lines to write back; nil keeps the connection open and silent until the peer leaves.
    init(respond: @escaping @Sendable (LookRequest) -> [String]?) throws {
        path = NSTemporaryDirectory() + "ahl-\(UUID().uuidString.prefix(8)).sock"
        var addr = try #require(SocketIO.makeAddress(path))
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listenFD, 4) == 0)
        let fd = listenFD, seen = seen
        // The thread ends when the listening socket is closed (see deinit); it holds no reference to this object.
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                guard let line = SocketIO.readLine(c, until: Date().addingTimeInterval(5)), let request = LookRequest.decode(line) else {
                    close(c)
                    continue
                }
                seen.add(request)
                if let lines = respond(request) {
                    for l in lines { SocketIO.writeAll(c, l) }
                } else {
                    // Silent: wait until the helper gives up and closes.
                    _ = SocketIO.readLine(c, until: Date().addingTimeInterval(10))
                }
                close(c)
            }
        }
    }

    deinit {
        close(listenFD)
        unlink(path)
    }
}

@Suite struct LookClientTests {
    func request(_ tool: LookTool = .listWindows, target: LookTarget = .none, wait: TimeInterval = 5) -> LookRequest {
        LookRequest(requestId: UUID().uuidString.lowercased(), call: LookCall(tool: tool, target: target), sessionId: nil,
                    deadline: Date().addingTimeInterval(wait))
    }

    /// A real 1×1 PNG.
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

    @Test func appAbsent() throws {
        let missing = NSTemporaryDirectory() + "ahl-none-\(UUID().uuidString.prefix(8)).sock"
        let started = Date()
        #expect(LookClient.perform(request(), socketPath: missing) == .refused("Agent HUD is not running"))
        #expect(Date().timeIntervalSince(started) < 2)
        // A path that is not a socket, and one that is too long for a socket address.
        #expect(LookClient.perform(request(), socketPath: "/dev/null") == .refused(LookClient.notRunning))
        #expect(LookClient.perform(request(), socketPath: "/" + String(repeating: "x", count: 300)) == .refused(LookClient.notRunning))

        // The whole way through the MCP layer: a normal result marked as an error, not a protocol error.
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{"target":"screen"}}}"#
        let out = try #require(MCPServer.handle(line: line) { call in
            LookClient.perform(LookRequest(requestId: "r", call: call, sessionId: nil, deadline: Date().addingTimeInterval(2)), socketPath: missing)
        })
        let v = try JSONValue.parse(out)
        #expect(v["error"] == nil)
        #expect(v["result"]?["isError"] == .bool(true))
        #expect(v["result"]?["content"]?[0]?["text"]?.stringValue == "Agent HUD is not running")
    }

    @Test func silentAppEndsAtTheDeadline() throws {
        let app = try FakeApp { _ in nil }
        defer { withExtendedLifetime(app) {} }   // the listener closes when the fake is released
        let started = Date()
        #expect(LookClient.perform(request(wait: 0.4), socketPath: app.path) == .refused("Timed out waiting for an answer"))
        let took = Date().timeIntervalSince(started)
        #expect(took >= 0.3 && took < 3)
        #expect(app.requests.count == 1)
        // A deadline that has already passed returns at once.
        let again = Date()
        #expect(LookClient.perform(request(wait: -1), socketPath: app.path) == .refused(LookClient.timedOut))
        #expect(Date().timeIntervalSince(again) < 1)
    }

    @Test func denial() throws {
        let app = try FakeApp { r in [LookReply(requestId: r.requestId, outcome: .refused(LookGate.Refusal.denied.message)).encode()] }
        defer { withExtendedLifetime(app) {} }   // the listener closes when the fake is released
        let r = request(.screenshot, target: .window(42))
        #expect(LookClient.perform(r, socketPath: app.path) == .refused("The person did not allow this"))
        // The app got exactly this request (the deadline travels in whole seconds).
        #expect(app.requests.map(\.requestId) == [r.requestId] && app.requests.first?.call == r.call)
        #expect(abs((app.requests.first?.deadline ?? .distantPast).timeIntervalSince(r.deadline)) <= 1)
    }

    @Test func allowedText() throws {
        let text = "Window \"Checkout\"\n  Button \"Pay\""
        let app = try FakeApp { r in [LookReply(requestId: r.requestId, outcome: .text(text)).encode()] }
        defer { withExtendedLifetime(app) {} }   // the listener closes when the fake is released
        #expect(LookClient.perform(request(.readWindowText, target: .window(7)), socketPath: app.path) == .text(text))
        #expect(app.requests.first?.call == LookCall(tool: .readWindowText, target: .window(7)))
    }

    @Test func allowedImage() throws {
        let caption = LookImage.caption(what: "the screen", width: 1, height: 1, mimeType: "image/png")
        let app = try FakeApp { r in
            [LookReply(requestId: r.requestId, outcome: .image(data: LookClientTests.png, mimeType: "image/png", caption: caption)).encode()]
        }
        let outcome = LookClient.perform(request(.screenshot, target: .screen), socketPath: app.path)
        #expect(outcome == .image(data: Self.png, mimeType: "image/png", caption: caption))
        let bytes = try #require(Data(base64Encoded: Self.png))
        #expect(bytes.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        // As the MCP result the client receives.
        let result = MCPServer.callResult(id: 3, outcome: outcome, modern: false)
        #expect(result["result"]?["content"]?[0] == ["type": "image", "data": .string(Self.png), "mimeType": "image/png"])
        #expect(result["result"]?["content"]?[1]?["text"]?.stringValue == "Screenshot of the screen, 1×1 px, PNG")
        #expect(result["result"]?["isError"] == .bool(false))
    }

    @Test func oversizedReply() throws {
        let app = try FakeApp { r in [LookReply(requestId: r.requestId, outcome: .text(String(repeating: "x", count: 300_000))).encode()] }
        defer { withExtendedLifetime(app) {} }   // the listener closes when the fake is released
        #expect(LookClient.perform(request(), socketPath: app.path, maxReplyBytes: 64_000) == .refused("The answer from Agent HUD was too large"))
        // The same reply under the real limit is fine.
        if case .text(let t) = LookClient.perform(request(), socketPath: app.path) { #expect(t.count == 300_000) } else { Issue.record("expected text") }
    }

    @Test func brokenAnswers() throws {
        let closing = try FakeApp { _ in [] }
        defer { withExtendedLifetime(closing) {} }   // the listener closes when the fake is released
        #expect(LookClient.perform(request(), socketPath: closing.path) == .refused("Agent HUD closed the connection without an answer"))
        let garbage = try FakeApp { _ in ["what?"] }
        defer { withExtendedLifetime(garbage) {} }   // the listener closes when the fake is released
        #expect(LookClient.perform(request(), socketPath: garbage.path) == .refused(LookClient.unreadable))
        // An answer to some other request is not taken.
        let other = try FakeApp { _ in [LookReply(requestId: "someone-else", outcome: .text("secret")).encode()] }
        defer { withExtendedLifetime(other) {} }   // the listener closes when the fake is released
        #expect(LookClient.perform(request(), socketPath: other.path) == .refused(LookClient.unreadable))
        // A hook reply is not a look reply: "allow" for a tool permission never turns into a look.
        let hook = try FakeApp { r in [HookReply(requestId: r.requestId, decision: .allow).encode()] }
        defer { withExtendedLifetime(hook) {} }   // the listener closes when the fake is released
        #expect(LookClient.perform(request(), socketPath: hook.path) == .refused(LookClient.unreadable))
    }

    @Test func aCancelledCallStopsWaiting() throws {
        let app = try FakeApp { _ in nil }
        defer { withExtendedLifetime(app) {} }   // the listener closes when the fake is released
        let started = Date()
        let outcome = LookClient.perform(request(wait: 20), socketPath: app.path) { fd in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { shutdown(fd, SHUT_RDWR) }
        }
        #expect(outcome == .refused(LookClient.noAnswer))
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

@Suite struct ScreenToolsTests {
    let helper = "/Users/dev/Applications/AgentHUD.app/Contents/Helpers/agenthud-mcp"
    let id = "0F8FAD5B-D9CB-469F-A165-70867728950E"

    @Test func configForOneStdioServer() throws {
        let json = try #require(ScreenTools.configJSON(helperPath: helper))
        let v = try JSONValue.parse(json)
        #expect(v["mcpServers"]?.objectValue?.keys == ["agenthud"])
        #expect(v["mcpServers"]?["agenthud"]?["command"]?.stringValue == helper)
        #expect(v["mcpServers"]?["agenthud"]?["args"] == [])
        #expect(v.objectValue?.keys == ["mcpServers"])
        // A path with a space or a quote stays one JSON string.
        let odd = "/Users/dev/My \"Apps\"/agenthud-mcp"
        #expect(try JSONValue.parse(try #require(ScreenTools.configJSON(helperPath: odd)))["mcpServers"]?["agenthud"]?["command"]?.stringValue == odd)
        for bad in ["", "agenthud-mcp", "./agenthud-mcp", "~/bin/agenthud-mcp", "/x\ny", "/x\u{7}", "/" + String(repeating: "a", count: 2000)] {
            #expect(ScreenTools.configJSON(helperPath: bad) == nil, "\(bad)")
            #expect(ScreenTools.addArguments(helperPath: bad) == nil)
        }
    }

    @Test func sessionArgumentsWithTheScreenTools() throws {
        let plain = OwnedSessionLogic.arguments(sessionId: id, resume: false, model: nil)
        #expect(!plain.contains("--mcp-config"))
        #expect(OwnedSessionLogic.arguments(sessionId: id, resume: false, model: nil, screenTools: nil) == plain)
        for resume in [false, true] {
            for model in [nil, "sonnet"] as [String?] {
                let base = OwnedSessionLogic.arguments(sessionId: id, resume: resume, model: model)
                let args = OwnedSessionLogic.arguments(sessionId: id, resume: resume, model: model, screenTools: helper)
                // The flag and its one value come last; everything before is unchanged.
                #expect(Array(args.dropLast(2)) == base)
                #expect(args[args.count - 2] == "--mcp-config")
                #expect(args.filter { $0 == "--mcp-config" }.count == 1)
                let config = try JSONValue.parse(args[args.count - 1])
                #expect(config["mcpServers"]?["agenthud"]?["command"]?.stringValue == helper)
                // Still nothing that approves a tool, skips the hooks or drops other servers.
                for f in OwnedSessionLogicTests.forbidden + ["--strict-mcp-config", "allowedTools", "mcp__agenthud", "permissions"] {
                    #expect(!args.contains { $0.contains(f) }, "\(f) in \(args)")
                }
                #expect(args.filter { $0.hasPrefix("--permission-mode") } == ["--permission-mode"])
                #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "default")
            }
        }
        // An unusable path adds nothing; an invalid session id still yields nothing at all.
        #expect(OwnedSessionLogic.arguments(sessionId: id, resume: false, model: nil, screenTools: "agenthud-mcp") == plain)
        #expect(OwnedSessionLogic.arguments(sessionId: id, resume: false, model: nil, screenTools: "/x\n--bare") == plain)
        #expect(OwnedSessionLogic.arguments(sessionId: "nope", resume: false, model: nil, screenTools: helper).isEmpty)
        // A hostile path cannot become a flag of its own: it only ever sits inside the JSON value.
        let hostile = OwnedSessionLogic.arguments(sessionId: id, resume: false, model: nil, screenTools: "/x --dangerously-skip-permissions")
        #expect(hostile.count == plain.count + 2 && !hostile.contains("--dangerously-skip-permissions"))
        #expect(hostile.last?.hasPrefix("{\"mcpServers\":") == true)
    }

    @Test func registrationCommands() throws {
        #expect(ScreenTools.addArguments(helperPath: "/Users/dev/.local/bin/agenthud-mcp")
                == ["mcp", "add", "--scope", "user", "agenthud", "--", "/Users/dev/.local/bin/agenthud-mcp"])
        #expect(ScreenTools.removeArguments == ["mcp", "remove", "--scope", "user", "agenthud"])
        #expect(ScreenTools.statusArguments == ["mcp", "get", "agenthud"])
        #expect(ScreenTools.display(program: "/opt/homebrew/bin/claude", arguments: try #require(ScreenTools.addArguments(helperPath: "/Users/dev/.local/bin/agenthud-mcp")))
                == "/opt/homebrew/bin/claude mcp add --scope user agenthud -- /Users/dev/.local/bin/agenthud-mcp")
        #expect(ScreenTools.display(program: "claude", arguments: ["a b", "it's", ""]) == "claude 'a b' 'it'\\''s' ''")
    }

    @Test func statusFromTheCommandsAnswer() {
        #expect(ScreenTools.status(exitCode: 0, output: "agenthud:\n  Scope: User config\n  Status: Connected") == .registered)
        #expect(ScreenTools.status(exitCode: 1, output: "No MCP server named \"agenthud\". Configured servers: a, b") == .notRegistered)
        #expect(ScreenTools.status(exitCode: 1, output: "error: unknown command 'get'") == .unknown)
        #expect(ScreenTools.status(exitCode: 127, output: "") == .unknown)
    }
}

@Suite struct LookActivityTests {
    @Test func lookRecordKeepsOnlyTheTarget() throws {
        let r = ActivityRecord(kind: .look, time: now, agent: "claude", session: "s1", project: "acme-web", cwd: "/Users/dev/acme-web",
                               text: "screenshot: Safari — Start Page", detail: "allowed")
        let line = r.toJSON().compact()
        #expect(try JSONValue.parse(line)["kind"]?.stringValue == "look")
        #expect(ActivityRecord(json: try JSONValue.parse(line)) == r)
        #expect(Set(r.toJSON().objectValue?.keys ?? []) == ["kind", "t", "agent", "session", "project", "cwd", "text", "detail"])
    }

    @Test func looksDoNotCountAsTasksOrDecisions() {
        let prompt = ActivityRecord(kind: .prompt, time: now, agent: "claude", session: "s1", project: "acme-web", cwd: "/p", text: "Check the page")
        let look = ActivityRecord(kind: .look, time: now.addingTimeInterval(5), agent: "claude", session: "s1", project: "acme-web", cwd: "/p",
                                  text: "screenshot: the screen", detail: "denied")
        let projects = DailySummary.build([prompt, look])
        #expect(projects.count == 1 && projects[0].turns.count == 1 && projects[0].decisions.isEmpty)
        // A day with only a look has nothing to summarise.
        #expect(DailySummary.build([look]).isEmpty)
    }
}
