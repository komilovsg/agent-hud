import Foundation
import Testing
@testable import AgentHudCore

// Questions (`AskUserQuestion`, answered by the `question` hook on PreToolUse) and plan approval
// (`ExitPlanMode`, answered by the permission hook).

private let sid = "11111111-2222-3333-4444-555555555555"
private let key = "claude:" + sid

private func ev(_ dt: TimeInterval, _ body: AgentEvent.Body, agent: String? = nil) -> AgentEvent {
    AgentEvent(kind: .claude, sessionId: sid, cwd: "/Users/dev/project", agentId: agent, time: t0.addingTimeInterval(dt), body: body)
}

private let color = Question(question: "Which color do you prefer?", header: "Color", options: [
    QuestionOption(label: "Red", description: "Red"), QuestionOption(label: "Green", description: "Green"),
    QuestionOption(label: "Blue", description: "Blue"),
])
private let checks = Question(question: "Which checks should run?", header: "Checks", options: [
    QuestionOption(label: "Unit tests"), QuestionOption(label: "Type check"), QuestionOption(label: "End-to-end"),
], multiSelect: true)
private let rollout = Question(question: "How should it be rolled out?", options: [QuestionOption(label: "All at once")])

private func ask(_ rid: String, _ dt: TimeInterval = 1, questions: [Question] = [color], agent: String? = nil,
                 deadline: Date = t0.addingTimeInterval(595)) -> AgentEvent {
    ev(dt, .questionAsked(requestId: rid, questions: questions, rawInput: ["questions": []], deadline: deadline), agent: agent)
}

/// Tool input with the three sample questions.
private func threeQuestionsPayload() throws -> JSONValue {
    var p = try fixture("question-PreToolUse-AskUserQuestion")
    func q(_ x: Question) -> JSONValue {
        ["question": .string(x.question), "header": .string(x.header ?? ""),
         "options": .array(x.options.map { ["label": .string($0.label), "description": .string($0.description ?? "")] }),
         "multiSelect": .bool(x.multiSelect)]
    }
    p["tool_input"] = ["questions": [q(color), q(checks), q(rollout)]]
    return p
}

// MARK: - Protocol

@Suite struct QuestionProtocolTests {
    @Test func questionModeIsSynchronous() {
        #expect(HookMode(rawValue: "question") == .question)
        #expect(HookMode.question.isSync)
    }

    @Test func answerReplyRoundTrip() throws {
        let r = HookReply(requestId: "abc", decision: .answer(["Which color?": "Red", "Checks?": "Unit tests, Type check"]))
        #expect(HookReply.decode(r.encode()) == r)
        #expect(!r.encode().contains("\n"))
        let v = try JSONValue.parse(r.encode())
        #expect(v["decision"] == "answer")
        #expect(v["answers"]?["Checks?"] == "Unit tests, Type check")
    }

    @Test func answerReplyWithoutAnswersIsRejected() {
        #expect(HookReply.decode("{\"request_id\":\"a\",\"decision\":\"answer\"}") == nil)
        #expect(HookReply.decode("{\"request_id\":\"a\",\"decision\":\"answer\",\"answers\":{}}") == nil)
        #expect(HookReply.decode("{\"request_id\":\"a\",\"decision\":\"answer\",\"answers\":{\"q\":1}}") == nil)
    }

    /// A question waits for the user as long as a permission request - not the day a Stop can hold.
    @Test func questionWaitsLikeAPermissionRequest() {
        let i = ClaudeHookInstaller(hookPath: "/x/agenthud-hook", timeout: 120)
        #expect(i.command(.question) == "/x/agenthud-hook claude question --timeout 120")
        #expect(i.syncTimeout(.question) == i.syncTimeout(.permission))
        #expect(i.syncTimeout(.question) != HookTiming.gateTimeout)
        #expect(i.hookEntry(.question)["timeout"] == 120)
        #expect(i.hookEntry(.question)["async"] == nil)
    }
}

// MARK: - Adapter

@Suite struct QuestionAdapterTests {
    @Test func permissionAndQuestionModes() throws {
        let p = try #require(events(try message("permission-PermissionRequest", mode: .permission, rid: "p1", deadline: t0)).first)
        guard case .permissionRequested("p1", "Bash", let input, t0, let suggestions) = p.body else { Issue.record("\(p.body)"); return }
        #expect(input["command"]?.stringValue?.contains("node -e") == true)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?["destination"] == "localSettings")

        let m = try message("question-PreToolUse-AskUserQuestion", mode: .question, rid: "q1", deadline: t0)
        let q = try #require(events(m).first)
        guard case .questionAsked("q1", let qs, let raw, t0) = q.body else { Issue.record("\(q.body)"); return }
        #expect(qs.count == 1)
        #expect(qs[0].options.map(\.label) == ["Red", "Green", "Blue"])
        #expect(qs[0].header == "Color")
        #expect(qs[0].multiSelect == false)
        #expect(raw == m.payload["tool_input"])
        #expect(events(m).count == 1)
    }

    @Test func questionOutputEchoesQuestionsAndAddsAnswers() throws {
        let payload = try fixture("question-PreToolUse-AskUserQuestion")
        let q = try #require(payload["tool_input"]?["questions"]?[0]?["question"]?.stringValue)
        let out = try JSONValue.parse(try #require(
            adapter.hookOutput(for: .answer([q: "Green, Blue", "extra": "x"]), mode: .question, payload: payload)))
        let hso = try #require(out["hookSpecificOutput"])
        #expect(hso["hookEventName"] == "PreToolUse")
        #expect(hso["permissionDecision"] == "allow")
        #expect(hso["updatedInput"]?["questions"] == payload["tool_input"]?["questions"])
        #expect(hso["updatedInput"]?["answers"]?.objectValue?.keys == [q])
        #expect(hso["updatedInput"]?["answers"]?[q] == "Green, Blue")
        // "allow" without an answer is meaningless - let the host ask.
        #expect(adapter.hookOutput(for: .allow, mode: .question, payload: payload) == nil)
        #expect(adapter.hookOutput(for: .passthrough, mode: .question, payload: payload) == nil)
    }

    /// The whole stdout of an answered question, as in the documentation ("Tools that require user interaction").
    @Test func answerOutputIsExactlyTheDocumentedShape() throws {
        let payload: JSONValue = ["session_id": "s", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": [
            "questions": [["question": "Which framework?", "header": "Framework",
                           "options": [["label": "React", "description": "Component library"],
                                       ["label": "Vue", "description": "Progressive framework"]],
                           "multiSelect": false]],
        ]]
        let out = adapter.hookOutput(for: .answer(["Which framework?": "React"]), mode: .question, payload: payload)
        #expect(out == """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}],"answers":{"Which framework?":"React"}}}}
        """)
    }

    /// Anything but a complete set of answers prints nothing: Claude Code shows its own question.
    @Test func questionModePrintsOnlyCompleteAnswers() throws {
        let payload = try threeQuestionsPayload()
        for d in [Decision.allow, .passthrough, .deny(reason: "no"), .deny(reason: nil),
                  .allowWith(PlanApproval.updates(.acceptEdits)), .answer([:]),
                  .answer([color.question: "Red"]),                                           // two questions unanswered
                  .answer([color.question: "Red", checks.question: "", rollout.question: "x"])] {
            #expect(adapter.hookOutput(for: d, mode: .question, payload: payload) == nil, "\(d)")
        }
        let full = Decision.answer([color.question: "Red", checks.question: "Unit tests, End-to-end", rollout.question: "Behind a flag"])
        let out = try JSONValue.parse(try #require(adapter.hookOutput(for: full, mode: .question, payload: payload)))
        let answers = try #require(out["hookSpecificOutput"]?["updatedInput"]?["answers"])
        #expect(answers.objectValue?.keys == [color.question, checks.question, rollout.question])
        #expect(answers[checks.question] == "Unit tests, End-to-end")
        #expect(answers[rollout.question] == "Behind a flag")
        #expect(out["hookSpecificOutput"]?["updatedInput"]?["questions"] == payload["tool_input"]?["questions"])
        // An answer never goes out through another mode.
        #expect(adapter.hookOutput(for: full, mode: .permission, payload: payload) == nil)
        #expect(adapter.hookOutput(for: full, mode: .gate, payload: payload) == nil)
        #expect(adapter.hookOutput(for: full, mode: .event, payload: payload) == nil)
    }

    @Test func questionIsForwardedOnlyWhenTheCardCanAnswerIt() throws {
        let payload = try fixture("question-PreToolUse-AskUserQuestion")
        #expect(adapter.shouldForward(mode: .question, payload: payload))
        #expect(adapter.shouldForward(mode: .question, payload: try threeQuestionsPayload()))
        #expect(!adapter.shouldForward(mode: .question, payload: try fixture("PreToolUse-Bash")))

        var noSession = payload
        noSession["session_id"] = nil
        #expect(!adapter.shouldForward(mode: .question, payload: noSession))

        var empty = payload
        empty["tool_input"] = ["questions": []]
        #expect(!adapter.shouldForward(mode: .question, payload: empty))
        empty["tool_input"] = [:]
        #expect(!adapter.shouldForward(mode: .question, payload: empty))

        // Answers are keyed by the question text: two equal texts cannot be answered apart.
        var twice = payload
        let q = try #require(payload["tool_input"]?["questions"]?[0])
        twice["tool_input"] = ["questions": [q, q]]
        #expect(!adapter.shouldForward(mode: .question, payload: twice))

        // An entry that is not a question would be lost from the card.
        var broken = payload
        broken["tool_input"] = ["questions": [q, ["header": "No text"]]]
        #expect(!adapter.shouldForward(mode: .question, payload: broken))

        // The permission hook still leaves the question alone; the gate sees it like any other tool.
        var perm = try fixture("permission-PermissionRequest")
        perm["tool_name"] = "AskUserQuestion"
        #expect(!adapter.shouldForward(mode: .permission, payload: perm))
        #expect(adapter.shouldForward(mode: .gate, payload: payload))
    }

    @Test func summaries() {
        #expect(adapter.summarize(toolName: "AskUserQuestion", input: ["questions": [["question": "Which color?"]]], cwd: nil)
                == "Question: Which color?")
        #expect(adapter.summarize(toolName: "ExitPlanMode", input: ["plan": "# Secret plan"], cwd: nil) == "Proposed a plan")
    }
}

// MARK: - Answers

@Suite struct QuestionDraftTests {
    let qs = [color, checks, rollout]

    @Test func nothingIsChosenByDefault() {
        let d = QuestionDraft()
        #expect(!d.isComplete(qs))
        #expect(d.answers(qs) == nil)
        #expect(d.answer(0, in: qs) == nil)
        #expect(!QuestionDraft().isComplete([]))
    }

    @Test func singleChoiceReplacesThePick() {
        var d = QuestionDraft()
        d.toggle(0, option: 0, multi: false)
        d.toggle(0, option: 2, multi: false)
        #expect(d.answer(0, in: qs) == "Blue")
        #expect(d.isPicked(0, 2) && !d.isPicked(0, 0))
    }

    @Test func multiSelectJoinsLabelsInOptionOrder() {
        var d = QuestionDraft()
        d.toggle(1, option: 2, multi: true)
        d.toggle(1, option: 0, multi: true)
        #expect(d.answer(1, in: qs) == "Unit tests, End-to-end")
        d.toggle(1, option: 2, multi: true)
        #expect(d.answer(1, in: qs) == "Unit tests")
        d.toggle(1, option: 0, multi: true)
        #expect(d.answer(1, in: qs) == nil)
    }

    @Test func otherReplacesASingleChoiceAndNeedsText() {
        var d = QuestionDraft()
        d.toggle(0, option: 1, multi: false)
        d.toggleOther(0, multi: false)
        #expect(d.answer(0, in: qs) == nil)            // "Other…" chosen, nothing typed yet
        d.other[0] = "  Teal \n"
        #expect(d.answer(0, in: qs) == "Teal")
        // Picking an option again turns "Other…" off; the typed text is not sent.
        d.toggle(0, option: 0, multi: false)
        #expect(d.answer(0, in: qs) == "Red")
        #expect(!d.otherOn.contains(0))
    }

    @Test func otherIsAddedToAMultiSelectAnswer() {
        var d = QuestionDraft()
        d.toggle(1, option: 1, multi: true)
        d.toggleOther(1, multi: true)
        #expect(d.answer(1, in: qs) == nil)            // an empty own answer blocks sending
        d.other[1] = "Lint"
        #expect(d.answer(1, in: qs) == "Type check, Lint")
        d.toggle(1, option: 1, multi: true)
        #expect(d.answer(1, in: qs) == "Lint")
        d.toggleOther(1, multi: true)
        #expect(d.answer(1, in: qs) == nil)
    }

    @Test func answersAreKeyedByQuestionTextAndNeedEveryQuestion() throws {
        var d = QuestionDraft()
        d.toggle(0, option: 0, multi: false)
        d.toggle(1, option: 0, multi: true)
        d.toggle(1, option: 1, multi: true)
        #expect(d.answers(qs) == nil)
        d.toggleOther(2, multi: false)
        d.other[2] = "Behind a flag"
        let a = try #require(d.answers(qs))
        #expect(a == [color.question: "Red", checks.question: "Unit tests, Type check", rollout.question: "Behind a flag"])
        // The draft goes to the hook output unchanged.
        let out = try JSONValue.parse(try #require(adapter.hookOutput(for: .answer(a), mode: .question, payload: try threeQuestionsPayload())))
        #expect(out["hookSpecificOutput"]?["updatedInput"]?["answers"]?[checks.question] == "Unit tests, Type check")
    }

    @Test func decisionsMustFitTheRequest() {
        let question = PendingKind.question([color, checks], rawInput: [:])
        #expect(question.accepts(.answer([color.question: "Red", checks.question: "Unit tests"])))
        #expect(!question.accepts(.answer([color.question: "Red"])))
        #expect(!question.accepts(.answer([:])))
        #expect(!question.accepts(.allow))
        #expect(!question.accepts(.deny(reason: "no")))
        #expect(question.accepts(.passthrough))

        let plan = PendingKind.plan(text: "# Plan", rawInput: [:])
        #expect(plan.accepts(.allowWith(PlanApproval.updates(.keepAsking))))
        #expect(plan.accepts(.allowWith(PlanApproval.updates(.acceptEdits))))
        #expect(!plan.accepts(.allow))
        #expect(!plan.accepts(.allowWith([["type": "setMode", "mode": "bypassPermissions", "destination": "session"]])))
        #expect(!plan.accepts(.allowWith([])))
        #expect(!plan.accepts(.deny(reason: nil)))
        #expect(!plan.accepts(.deny(reason: "  \n")))
        #expect(plan.accepts(.deny(reason: "no migrations")))
        #expect(!plan.accepts(.answer(["q": "a"])))
        #expect(plan.accepts(.passthrough))

        let permission = PendingKind.permission(toolName: "Bash", toolInput: [:])
        #expect(permission.accepts(.allow) && permission.accepts(.deny(reason: nil)) && permission.accepts(.passthrough))
        #expect(!permission.accepts(.answer(["q": "a"])))
    }
}

// MARK: - Plan

@Suite struct PlanTests {
    @Test func planBecomesPlanRequest() throws {
        var st = SessionStore()
        for e in events(try message("SessionStart")) { st.apply(e) }
        for e in events(try message("permission-ExitPlanMode", mode: .permission, rid: "plan1", deadline: t0.addingTimeInterval(500))) {
            st.apply(e)
        }
        let s = try #require(st.session(key))
        guard case .plan(let text, _) = s.activePending?.kind else { Issue.record("\(String(describing: s.activePending))"); return }
        #expect(text.contains("Add a filter"))
        #expect(s.state == .waitingPermission)
        #expect(s.state.needsUser)
        #expect(st.openRequestCount == 1)
    }

    @Test func approveEchoesInputAndSetsMode() throws {
        let payload = try fixture("permission-ExitPlanMode")
        let out = try JSONValue.parse(try #require(adapter.hookOutput(
            for: .allowWith(PlanApproval.updates(.acceptEdits)), mode: .permission, payload: payload)))
        let d = try #require(out["hookSpecificOutput"]?["decision"])
        #expect(d["behavior"] == "allow")
        #expect(d["updatedInput"] == payload["tool_input"])
        #expect(d["updatedPermissions"]?[0]?["mode"] == "acceptEdits")
        #expect(d["updatedPermissions"]?[0]?["destination"] == "session")
        // A plain allow for a plan carries updatedInput too.
        let plain = try JSONValue.parse(try #require(adapter.hookOutput(for: .allow, mode: .permission, payload: payload)))
        #expect(plain["hookSpecificOutput"]?["decision"]?["updatedInput"] == payload["tool_input"])
    }

    /// The whole stdout for each plan decision.
    @Test func planOutputsAreExactlyTheDocumentedShape() throws {
        let payload: JSONValue = ["session_id": "s", "hook_event_name": "PermissionRequest", "tool_name": "ExitPlanMode",
                                  "tool_input": ["plan": "# Plan", "planFilePath": "/p/plan.md"]]
        #expect(adapter.hookOutput(for: .allowWith(PlanApproval.updates(.keepAsking)), mode: .permission, payload: payload) == """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"plan":"# Plan","planFilePath":"/p/plan.md"},"updatedPermissions":[{"type":"setMode","mode":"default","destination":"session"}]}}}
        """)
        #expect(adapter.hookOutput(for: .allowWith(PlanApproval.updates(.acceptEdits)), mode: .permission, payload: payload) == """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"plan":"# Plan","planFilePath":"/p/plan.md"},"updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}}}
        """)
        #expect(adapter.hookOutput(for: .deny(reason: "no migrations"), mode: .permission, payload: payload) == """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user did not approve the plan. Feedback: no migrations"}}}
        """)
        #expect(adapter.hookOutput(for: .passthrough, mode: .permission, payload: payload) == nil)
    }

    /// Whatever reaches the adapter, approving a plan cannot switch the session to a mode without prompts
    /// or write rules or modes to settings files.
    @Test func planApprovalNeverCarriesAPromptSkippingMode() throws {
        let payload = try fixture("permission-ExitPlanMode")
        let bad: [JSONValue] = [
            ["type": "setMode", "mode": "bypassPermissions", "destination": "session"],
            ["type": "setMode", "mode": "auto", "destination": "session"],
            ["type": "setMode", "mode": "dontAsk", "destination": "session"],
            ["type": "setMode", "mode": "acceptEdits", "destination": "userSettings"],
            ["type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "session"],
        ]
        let out = try JSONValue.parse(try #require(adapter.hookOutput(for: .allowWith(bad), mode: .permission, payload: payload)))
        let d = try #require(out["hookSpecificOutput"]?["decision"])
        #expect(d["behavior"] == "allow")
        #expect(d["updatedPermissions"] == nil)
        #expect(PlanApproval.sanitized(bad).isEmpty)
        #expect(PlanApproval.Mode.allCases.map(\.rawValue) == ["default", "acceptEdits"])
        for m in PlanApproval.Mode.allCases { #expect(PlanApproval.sanitized(PlanApproval.updates(m)) == PlanApproval.updates(m)) }
        // Other tools keep their rules as before.
        let bash = try JSONValue.parse(try #require(adapter.hookOutput(for: .allowWith([bad[4]]), mode: .permission,
                                                                       payload: try fixture("permission-PermissionRequest"))))
        #expect(bash["hookSpecificOutput"]?["decision"]?["updatedPermissions"]?[0] == bad[4])
        #expect(bash["hookSpecificOutput"]?["decision"]?["updatedInput"] == nil)
    }

    @Test func reviseSendsFeedback() throws {
        let payload = try fixture("permission-ExitPlanMode")
        let out = try JSONValue.parse(try #require(adapter.hookOutput(for: .deny(reason: "no migrations"), mode: .permission, payload: payload)))
        let msg = out["hookSpecificOutput"]?["decision"]?["message"]?.stringValue ?? ""
        #expect(msg.contains("no migrations") && msg.contains("plan"))
        #expect(out["hookSpecificOutput"]?["decision"]?["behavior"] == "deny")
        #expect(out["hookSpecificOutput"]?["decision"]?["interrupt"] == nil)
        let empty = try JSONValue.parse(try #require(adapter.hookOutput(for: .deny(reason: nil), mode: .permission, payload: payload)))
        #expect(empty["hookSpecificOutput"]?["decision"]?["message"]?.stringValue?.contains("plan") == true)
    }

    @Test func planWithoutTextStaysInTheHost() throws {
        var payload = try fixture("permission-ExitPlanMode")
        payload["tool_input"] = ["planFilePath": "/p/plan.md"]
        #expect(!adapter.shouldForward(mode: .permission, payload: payload))
        payload["tool_input"] = ["plan": "  \n"]
        #expect(!adapter.shouldForward(mode: .permission, payload: payload))
    }

    @Test func postToolUseResolvesPlan() throws {
        var st = SessionStore()
        for e in events(try message("permission-ExitPlanMode", mode: .permission, rid: "plan1", deadline: t0.addingTimeInterval(500))) {
            st.apply(e)
        }
        let done = AgentEvent(kind: .claude, sessionId: sid, time: t0.addingTimeInterval(5),
                              body: .toolFinished(toolName: "ExitPlanMode", input: [:], toolUseId: nil, durationMs: 1, failed: false))
        #expect(st.apply(done) == ["plan1"])
        #expect(st.session(key)?.pending.isEmpty == true)
    }

    @Test func planExpiresByDeadline() throws {
        var st = SessionStore()
        for e in events(try message("permission-ExitPlanMode", mode: .permission, rid: "plan1", deadline: t0.addingTimeInterval(595))) {
            st.apply(e)
        }
        #expect(st.tick(now: t0.addingTimeInterval(100), autoHideDoneAfter: nil).isEmpty)
        #expect(st.tick(now: t0.addingTimeInterval(597), autoHideDoneAfter: nil) == ["plan1"])
        #expect(st.session(key)?.state == .expired)
        #expect(st.session(key)?.expiredPending?.kind.isPlan == true)
    }
}

// MARK: - Store

@Suite struct QuestionStoreTests {
    func store() -> SessionStore {
        var st = SessionStore()
        st.apply(ev(0, .promptSubmitted("task")))
        return st
    }

    @Test func questionArrivesAndNeedsTheUser() throws {
        var st = SessionStore()
        for name in ["SessionStart", "UserPromptSubmit"] { for e in events(try message(name)) { st.apply(e) } }
        for e in events(try message("question-PreToolUse-AskUserQuestion", mode: .question, rid: "q1", deadline: t0.addingTimeInterval(595))) {
            #expect(st.apply(e).isEmpty)
        }
        let s = try #require(st.session(key))
        guard case .question(let qs, let raw) = s.activePending?.kind else { Issue.record("\(String(describing: s.activePending))"); return }
        #expect(qs.map(\.question) == ["Which color do you prefer?"])
        #expect(raw["questions"]?.arrayValue?.count == 1)
        #expect(s.state == .waitingPermission && s.state.needsUser)
        #expect(st.openRequestCount == 1)
        #expect(st.session(forRequest: "q1")?.id == key)
        // The same message twice does not make two requests.
        for e in events(try message("question-PreToolUse-AskUserQuestion", mode: .question, rid: "q1")) { st.apply(e) }
        #expect(st.session(key)?.pending.count == 1)
    }

    @Test func toolFinishedResolvesTheQuestion() throws {
        var st = store()
        st.apply(ask("q1"))
        // The finished input carries the answers, so it differs from the asked one.
        var released: [String] = []
        for e in events(try message("PostToolUse-AskUserQuestion"), at: t0.addingTimeInterval(9)) { released += st.apply(e) }
        #expect(released == ["q1"])
        #expect(st.session(key)?.pending.isEmpty == true)
        #expect(st.session(key)?.state == .working)
    }

    @Test func anotherToolDoesNotResolveTheQuestion() throws {
        var st = store()
        st.apply(ask("q1"))
        for e in events(try message("PostToolUse-Bash"), at: t0.addingTimeInterval(9)) { #expect(st.apply(e).isEmpty) }
        #expect(st.session(key)?.activePending?.id == "q1")
    }

    @Test func answeredInTheCardIsRemoved() {
        var st = store()
        st.apply(ask("q1"))
        st.markAnswered("q1")
        #expect(st.session(key)?.pending.isEmpty == true)
        #expect(st.session(key)?.state == .working)
    }

    @Test func closedConnectionMeansAnsweredElsewhereOrExpired() {
        var st = store()
        st.apply(ask("q1"))
        st.connectionClosed("q1", now: t0.addingTimeInterval(10))
        #expect(st.session(key)?.pending.isEmpty == true)

        var late = store()
        late.apply(ask("q1"))
        late.connectionClosed("q1", now: t0.addingTimeInterval(594))
        #expect(late.session(key)?.state == .expired)
        #expect(late.session(key)?.expiredPending?.kind.isQuestion == true)
    }

    @Test func questionExpiresByDeadlineLikeAPermission() throws {
        var st = store()
        st.apply(ask("q1"))
        #expect(st.tick(now: t0.addingTimeInterval(100), autoHideDoneAfter: nil).isEmpty)
        #expect(st.session(key)?.state == .waitingPermission)
        #expect(st.tick(now: t0.addingTimeInterval(597), autoHideDoneAfter: nil) == ["q1"])
        #expect(st.session(key)?.state == .expired)
        #expect(st.session(key)?.activePending == nil)
        #expect(st.openRequestCount == 0)
        // Expired once: the next tick does not report it again.
        #expect(st.tick(now: t0.addingTimeInterval(598), autoHideDoneAfter: nil).isEmpty)
        st.dismissExpired(key)
        #expect(st.session(key)?.pending.isEmpty == true)
        // The session moved on - nothing is left of the expired question either.
        var moved = store()
        moved.apply(ask("q1"))
        _ = moved.tick(now: t0.addingTimeInterval(597), autoHideDoneAfter: nil)
        for e in events(try message("PostToolUse-AskUserQuestion"), at: t0.addingTimeInterval(600)) { #expect(moved.apply(e).isEmpty) }
        #expect(moved.session(key)?.state == .working)
    }

    @Test func newRequestOfTheSameAgentSupersedes() {
        var st = store()
        st.apply(ev(1, .permissionRequested(requestId: "p1", toolName: "Bash", input: ["command": "ls"],
                                            deadline: t0.addingTimeInterval(600), suggestions: [])))
        // The agent asks a question - so the permission was answered in the host.
        #expect(st.apply(ask("q1", 2)) == ["p1"])
        // A subagent's question lives next to the main agent's one.
        #expect(st.apply(ask("q2", 3, agent: "sub-1")).isEmpty)
        #expect(st.session(key)?.pending.map(\.id) == ["q1", "q2"])
        // The next question of the main agent replaces only its own.
        #expect(st.apply(ask("q3", 4)) == ["q1"])
        // A plan of the main agent replaces its question.
        #expect(st.apply(ev(5, .permissionRequested(requestId: "plan1", toolName: "ExitPlanMode", input: ["plan": "# P"],
                                                    deadline: t0.addingTimeInterval(600), suggestions: []))) == ["q3"])
        #expect(st.session(key)?.pending.map(\.id) == ["q2", "plan1"])
        #expect(st.session(key)?.pending.last?.kind.isPlan == true)
    }

    @Test func subagentQuestionLeavesWithItsSubagent() {
        var st = store()
        st.apply(ask("q1", 1, agent: "sub-1"))
        #expect(st.session(key)?.activePending?.agentId == "sub-1")
        #expect(st.apply(ev(2, .subagentStopped(agentId: "sub-1"))) == ["q1"])
        #expect(st.session(key)?.pending.isEmpty == true)
    }

    @Test func turnEndAndSessionEndReleaseTheQuestion() {
        var st = store()
        st.apply(ask("q1"))
        #expect(st.apply(ev(5, .stopped(lastMessage: nil, failed: false))) == ["q1"])
        st.apply(ev(6, .promptSubmitted("next")))
        st.apply(ask("q2", 7))
        #expect(st.apply(ev(8, .sessionEnded(reason: nil))) == ["q2"])
    }

    @Test func serviceSessionReleasesTheQuestionAtOnce() {
        var st = store()
        st.apply(ev(1, .internalSession))
        #expect(st.apply(ask("q1", 2)) == ["q1"])
        #expect(st.sessions.isEmpty)
    }

    @Test func questionBringsAHiddenSessionBack() {
        var st = store()
        st.hide(key)
        #expect(st.visibleSessions.isEmpty)
        st.apply(ask("q1"))
        #expect(st.visibleSessions.map(\.id) == [key])
    }
}

// MARK: - Pause / Stop and a question

/// For `AskUserQuestion` both PreToolUse hooks run: `gate` (held while the session is held) and `question`.
/// The two never answer for each other.
@Suite struct HoldQuestionTests {
    func heldStore(_ kind: Hold.Kind = .stop) throws -> SessionStore {
        var st = SessionStore()
        for name in ["SessionStart", "UserPromptSubmit"] { for e in events(try message(name)) { st.apply(e) } }
        #expect(st.hold(sessionKey: key, kind: kind, now: t0) == true)
        return st
    }

    /// The gate message of the question's tool call, the way the app applies it.
    func gate(_ st: inout SessionStore, _ rid: String) throws -> Bool {
        var answerNow = true
        for e in events(try message("PreToolUse-AskUserQuestion", mode: .gate, rid: rid)) {
            st.apply(e)
            guard case .toolStarted(let tool, let input, _) = e.body else { continue }
            answerNow = st.gateArrived(sessionKey: e.sessionKey, requestId: rid,
                                       summary: adapter.summarize(toolName: tool, input: input, cwd: nil),
                                       agentId: e.agentId, deadline: t0.addingTimeInterval(86395), now: t0)
        }
        return answerNow
    }

    func question(_ st: inout SessionStore, _ rid: String) throws -> [String] {
        var released: [String] = []
        for e in events(try message("question-PreToolUse-AskUserQuestion", mode: .question, rid: rid,
                                    deadline: t0.addingTimeInterval(595))) { released += st.apply(e) }
        return released
    }

    @Test func heldSessionShowsTheQuestionAndKeepsTheCallHeld() throws {
        for order in [true, false] {
            var st = try heldStore()
            if order {
                #expect(try gate(&st, "g1") == false)
                #expect(try question(&st, "q1").isEmpty)
            } else {
                #expect(try question(&st, "q1").isEmpty)
                #expect(try gate(&st, "g1") == false)
            }
            let s = try #require(st.session(key))
            #expect(s.hold?.kind == .stop)
            #expect(s.heldCalls.map(\.id) == ["g1"])
            #expect(s.heldCalls.first?.summary == "Question: Which color do you prefer?")
            #expect(s.activePending?.id == "q1")
            // The question is shown (it needs the user), and the hold is still there to resume.
            #expect(s.state == .waitingPermission)
        }
    }

    @Test func releaseDoesNotAnswerTheQuestion() throws {
        var st = try heldStore()
        _ = try gate(&st, "g1")
        _ = try question(&st, "q1")
        #expect(st.release(sessionKey: key) == ["g1"])
        let s = try #require(st.session(key))
        #expect(s.hold == nil && s.heldCalls.isEmpty)
        #expect(s.activePending?.id == "q1")
        #expect(s.state == .waitingPermission)
        #expect(st.releaseAll().isEmpty)
    }

    @Test func answerDoesNotReleaseTheHold() throws {
        var st = try heldStore()
        _ = try gate(&st, "g1")
        _ = try question(&st, "q1")
        st.markAnswered("q1")
        let s = try #require(st.session(key))
        #expect(s.pending.isEmpty)
        #expect(s.hold?.kind == .stop)
        #expect(s.heldCalls.map(\.id) == ["g1"])
        #expect(s.state == .stopped)
        // The call goes on only when the user resumes.
        #expect(st.release(sessionKey: key) == ["g1"])
    }

    @Test func questionLeavingByItselfKeepsTheHold() throws {
        // Expired by the deadline.
        var st = try heldStore()
        _ = try gate(&st, "g1")
        _ = try question(&st, "q1")
        #expect(st.tick(now: t0.addingTimeInterval(597), autoHideDoneAfter: nil) == ["q1"])
        #expect(st.session(key)?.heldCalls.map(\.id) == ["g1"])
        #expect(st.session(key)?.hold != nil)
        // Its hook disconnected.
        var closed = try heldStore()
        _ = try gate(&closed, "g1")
        _ = try question(&closed, "q1")
        closed.connectionClosed("q1", now: t0.addingTimeInterval(5))
        #expect(closed.session(key)?.pending.isEmpty == true)
        #expect(closed.session(key)?.heldCalls.map(\.id) == ["g1"])
        // And the other way round: the gate hook leaving does not touch the question.
        closed = try heldStore()
        _ = try gate(&closed, "g1")
        _ = try question(&closed, "q1")
        closed.connectionClosed("g1", now: t0.addingTimeInterval(5))
        #expect(closed.session(key)?.heldCalls.isEmpty == true)
        #expect(closed.session(key)?.activePending?.id == "q1")
    }

    @Test func pauseRunningOutReleasesOnlyTheGate() throws {
        var st = try heldStore(.pause)
        _ = try gate(&st, "g1")
        // A question with a deadline after the end of the pause.
        st.apply(ask("q1", 1, deadline: t0.addingTimeInterval(HookTiming.pauseLimit + 300)))
        #expect(st.tick(now: t0.addingTimeInterval(HookTiming.pauseLimit + 1), autoHideDoneAfter: nil) == ["g1"])
        #expect(st.session(key)?.hold == nil)
        #expect(st.session(key)?.activePending?.id == "q1")
    }

    @Test func questionDoesNotMakeAnUnheldGateWait() throws {
        var st = SessionStore()
        for name in ["SessionStart", "UserPromptSubmit"] { for e in events(try message(name)) { st.apply(e) } }
        #expect(try question(&st, "q1").isEmpty)
        #expect(try gate(&st, "g1") == true)
        #expect(st.session(key)?.heldCalls.isEmpty == true)
        #expect(st.session(key)?.activePending?.id == "q1")
    }
}

// MARK: - Installer

@Suite struct QuestionInstallerTests {
    let hook = "/Users/dev/.local/bin/agenthud-hook"
    var installer: ClaudeHookInstaller { ClaudeHookInstaller(hookPath: hook, timeout: 600) }

    /// An install of the previous version: the gate entry only, with foreign hooks around it.
    var previous: JSONValue {
        [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "bash ~/guard.sh", "timeout": 5]]],
                    ["matcher": "*", "hooks": [["type": "command", "command": .string("\(hook) claude gate --timeout 86400"), "timeout": 86400]]],
                    ["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": "log-question.sh"]]],
                ],
                "PermissionRequest": [
                    ["matcher": "*", "hooks": [["type": "command", "command": .string("\(hook) claude permission --timeout 600"), "timeout": 600]]],
                ],
                "Stop": [["hooks": [["type": "command", "command": "notify.sh"]]]],
            ],
            "model": "opus",
        ]
    }

    func commands(_ settings: JSONValue, _ event: String) -> [String] {
        (settings["hooks"]?[event]?.arrayValue ?? []).flatMap { $0["hooks"]?.arrayValue ?? [] }.compactMap { $0["command"]?.stringValue }
    }

    @Test func freshInstallRegistersTheQuestionHookNextToTheGate() throws {
        let after = installer.install(into: .object(JSONObject()))
        let pre = try #require(after["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(pre.count == 2)
        #expect(pre[0]["matcher"] == "*")
        #expect(pre[0]["hooks"]?[0]?["command"]?.stringValue == "\(hook) claude gate --timeout 86400")
        #expect(pre[1] == ["matcher": "AskUserQuestion", "hooks": [
            ["type": "command", "command": .string("\(hook) claude question --timeout 600"), "timeout": 600],
        ]])
        #expect(!ClaudeHookInstaller.needsUpdate(in: after))
        #expect(installer.plannedEntries()["PreToolUse"]?.arrayValue?.count == 2)
    }

    @Test func questionTimeoutFollowsTheUsersAnswerTime() {
        let short = ClaudeHookInstaller(hookPath: hook, timeout: 120)
        let after = short.install(into: .object(JSONObject()))
        #expect(commands(after, "PreToolUse") == ["\(hook) claude gate --timeout 86400", "\(hook) claude question --timeout 120"])
        #expect(after["hooks"]?["PreToolUse"]?[1]?["hooks"]?[0]?["timeout"] == 120)
        #expect(!ClaudeHookInstaller.needsUpdate(in: after))
    }

    @Test func installWithoutTheQuestionHookNeedsUpdate() {
        #expect(ClaudeHookInstaller.isInstalled(in: previous))
        #expect(ClaudeHookInstaller.needsUpdate(in: previous))

        // The entry is there but bound to every tool, or has no timeout: not the current form.
        var wrong = installer.install(into: .object(JSONObject()))
        var groups = wrong["hooks"]?["PreToolUse"]?.arrayValue ?? []
        groups[1]["matcher"] = "*"
        wrong["hooks"]?["PreToolUse"] = .array(groups)
        #expect(ClaudeHookInstaller.needsUpdate(in: wrong))
        groups[1]["matcher"] = "AskUserQuestion"
        groups[1]["hooks"] = [["type": "command", "command": .string("\(hook) claude question --timeout 600")]]
        wrong["hooks"]?["PreToolUse"] = .array(groups)
        #expect(ClaudeHookInstaller.needsUpdate(in: wrong))
        // The question entry alone, without the gate.
        let fresh = installer.install(into: .object(JSONObject()))["hooks"]?["PreToolUse"]?.arrayValue ?? []
        wrong["hooks"]?["PreToolUse"] = .array([fresh[1]])
        #expect(ClaudeHookInstaller.needsUpdate(in: wrong))
    }

    @Test func installUpgradesInPlaceKeepingForeignHooksAndOrder() {
        let after = installer.install(into: previous)
        #expect(!ClaudeHookInstaller.needsUpdate(in: after))
        #expect(after["model"] == "opus")
        #expect(commands(after, "PreToolUse") == ["bash ~/guard.sh", "log-question.sh",
                                                  "\(hook) claude gate --timeout 86400", "\(hook) claude question --timeout 600"])
        // Foreign groups are untouched - even the one on the same tool as ours.
        #expect(after["hooks"]?["PreToolUse"]?[0] == previous["hooks"]?["PreToolUse"]?[0])
        #expect(after["hooks"]?["PreToolUse"]?[1] == previous["hooks"]?["PreToolUse"]?[2])
        #expect(commands(after, "Stop").first == "notify.sh")
        #expect(commands(after, "PermissionRequest") == ["\(hook) claude permission --timeout 600"])
        // Idempotent.
        #expect(installer.install(into: after) == after)
    }

    @Test func uninstallRemovesTheQuestionHook() {
        let after = installer.install(into: previous)
        let removed = ClaudeHookInstaller.uninstall(from: after)
        #expect(!removed.compact().contains("agenthud-hook"))
        #expect(!ClaudeHookInstaller.isInstalled(in: removed))
        #expect(commands(removed, "PreToolUse") == ["bash ~/guard.sh", "log-question.sh"])
        #expect(commands(removed, "Stop") == ["notify.sh"])
        #expect(removed["hooks"]?["PermissionRequest"] == nil)
        let empty = JSONValue.object(JSONObject())
        #expect(ClaudeHookInstaller.uninstall(from: installer.install(into: empty)) == empty)
    }
}

// MARK: - Logs

@Suite struct RequestLogTests {
    @Test func questionAndAnswersAreKeptAsShortSummaries() {
        let long = Question(question: String(repeating: "Why? ", count: 60), header: "Reason", options: [])
        let kind = PendingKind.question([long, checks], rawInput: [:])
        let title = RequestLog.title(kind, cwd: nil, adapter: adapter)
        #expect(title.hasPrefix("Question: Why? Why?"))
        #expect(title.hasSuffix("… (+1 more)"))
        #expect(title.count <= RequestLog.maxSummary + " (+1 more)".count)

        let own = String(repeating: "a long own answer ", count: 30)
        let detail = RequestLog.detail(kind, .answer([long.question: own, checks.question: "Unit tests, Type check"]))
        #expect(detail.count == RequestLog.maxSummary)
        #expect(detail.hasPrefix("Reason: a long own answer"))
        #expect(RequestLog.detail(.question([checks], rawInput: [:]), .answer([checks.question: "Unit tests, Type check"]))
                == "Checks: Unit tests, Type check")
        #expect(RequestLog.label(kind, .answer([:])) == "answered")
        #expect(RequestLog.label(kind, .passthrough) == "to agent")
        #expect(RequestLog.detail(kind, .passthrough) == "")
    }

    @Test func planTextIsNotKept() {
        let secret = "SECRET-STEP"
        let text = "\n# Move the coupon to the cart store\n\n" + String(repeating: "1. \(secret) do the thing\n", count: 50)
        let kind = PendingKind.plan(text: text, rawInput: ["plan": .string(text)])
        let title = RequestLog.title(kind, cwd: nil, adapter: adapter)
        #expect(title == "Plan: Move the coupon to the cart store")
        #expect(RequestLog.title(.plan(text: String(repeating: "x", count: 500), rawInput: [:]), cwd: nil, adapter: adapter).count
                == RequestLog.maxSummary)

        let feedback = String(repeating: "keep the old endpoint\n", count: 20)
        let detail = RequestLog.detail(kind, .deny(reason: feedback))
        #expect(detail.count == RequestLog.maxSummary)
        #expect(!detail.contains("\n"))
        for d in [Decision.allowWith(PlanApproval.updates(.acceptEdits)), .deny(reason: feedback), .passthrough] {
            #expect(!RequestLog.detail(kind, d).contains(secret))
            #expect(!RequestLog.label(kind, d).contains(secret))
        }
        #expect(RequestLog.label(kind, .allowWith(PlanApproval.updates(.keepAsking))) == "plan approved")
        #expect(RequestLog.detail(kind, .allowWith(PlanApproval.updates(.keepAsking))) == "Default mode")
        #expect(RequestLog.detail(kind, .allowWith(PlanApproval.updates(.acceptEdits))) == "Accept file edits without asking")
        #expect(RequestLog.label(kind, .deny(reason: "x")) == "plan sent back")
        #expect(RequestLog.label(kind, .passthrough) == "to agent")
    }

    @Test func permissionDecisionsAreLoggedAsBefore() {
        let kind = PendingKind.permission(toolName: "Bash", toolInput: ["command": "npm test"])
        #expect(RequestLog.title(kind, cwd: nil, adapter: adapter) == "$ npm test")
        #expect(RequestLog.label(kind, .allow) == "allowed")
        #expect(RequestLog.label(kind, .deny(reason: nil)) == "denied")
        #expect(RequestLog.detail(kind, .deny(reason: "too risky")) == "too risky")
        #expect(RequestLog.detail(kind, .allow) == "")
        #expect(Decision.answer(["q": "a"]).logLabel == "answered")
        #expect(!Decision.answer(["q": "a"]).isAllow)
    }
}
