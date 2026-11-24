import Foundation

// Questions from the agent (`AskUserQuestion`) and plan approval (`ExitPlanMode`): the data the card works with.

public struct QuestionOption: Equatable, Sendable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct Question: Equatable, Sendable {
    public var question: String
    public var header: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [QuestionOption] = [], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// What the user has picked so far in a question request. Nothing is chosen by default.
public struct QuestionDraft: Equatable, Sendable {
    /// Question index -> indices of the chosen options.
    public var picked: [Int: Set<Int>] = [:]
    /// Questions where "Other…" is chosen.
    public var otherOn: Set<Int> = []
    /// Question index -> the user's own text.
    public var other: [Int: String] = [:]

    /// Labels of a multi-select answer are joined this way (and the user's own text is added last).
    public static let separator = ", "

    public init() {}

    public func isPicked(_ q: Int, _ option: Int) -> Bool { picked[q]?.contains(option) == true }

    /// Click on an option. Single choice replaces the previous pick and turns "Other…" off.
    public mutating func toggle(_ q: Int, option: Int, multi: Bool) {
        if multi {
            var set = picked[q] ?? []
            if set.contains(option) { set.remove(option) } else { set.insert(option) }
            picked[q] = set.isEmpty ? nil : set
        } else {
            picked[q] = [option]
            otherOn.remove(q)
        }
    }

    /// Click on "Other…". In a single-choice question it replaces the picked option.
    public mutating func toggleOther(_ q: Int, multi: Bool) {
        if otherOn.contains(q) {
            otherOn.remove(q)
        } else {
            otherOn.insert(q)
            if !multi { picked[q] = nil }
        }
    }

    public func otherText(_ q: Int) -> String {
        (other[q] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer to one question, or nil while there is none: nothing is picked, or "Other…" is chosen but empty.
    public func answer(_ q: Int, in questions: [Question]) -> String? {
        guard questions.indices.contains(q) else { return nil }
        let question = questions[q]
        var parts = (picked[q] ?? []).sorted().compactMap { i in
            question.options.indices.contains(i) ? question.options[i].label : nil
        }
        if !question.multiSelect, parts.count > 1 { parts = [parts[0]] }
        if otherOn.contains(q) {
            let text = otherText(q)
            guard !text.isEmpty else { return nil }
            if question.multiSelect { parts.append(text) } else { parts = [text] }
        }
        return parts.isEmpty ? nil : parts.joined(separator: Self.separator)
    }

    public func isComplete(_ questions: [Question]) -> Bool {
        !questions.isEmpty && questions.indices.allSatisfy { answer($0, in: questions) != nil }
    }

    /// Question text -> answer, or nil until every question has an answer.
    public func answers(_ questions: [Question]) -> [String: String]? {
        guard isComplete(questions) else { return nil }
        var out: [String: String] = [:]
        for (i, q) in questions.enumerated() { out[q.question] = answer(i, in: questions) }
        return out
    }
}

extension PendingKind {
    /// Whether this decision can be sent for this request. A question takes only a complete set of answers,
    /// a plan is sent back only with notes and approved only with a mode from `PlanApproval`;
    /// stepping aside (`passthrough`) is always possible.
    public func accepts(_ decision: Decision) -> Bool {
        if case .passthrough = decision { return true }
        switch (self, decision) {
        case (.permission, .answer): return false
        case (.permission, _): return true
        case (.question(let qs, _), .answer(let answers)):
            return !qs.isEmpty && qs.allSatisfy { !(answers[$0.question] ?? "").isEmpty }
        case (.question, _): return false
        case (.plan, .allowWith(let updates)): return !updates.isEmpty && PlanApproval.sanitized(updates) == updates
        case (.plan, .deny(let reason)):
            return !(reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A plain "allow" does not say in which mode the session goes on.
        case (.plan, _): return false
        }
    }
}

/// Approving a plan: in which permission mode the session goes on.
public enum PlanApproval {
    /// Only modes in which the agent still asks before running commands. Modes that skip permission prompts
    /// (`bypassPermissions`, `auto`, `dontAsk`) cannot be set from the card.
    public enum Mode: String, CaseIterable, Sendable {
        case keepAsking = "default"
        case acceptEdits
    }

    public static func updates(_ mode: Mode) -> [JSONValue] {
        [["type": "setMode", "mode": .string(mode.rawValue), "destination": "session"]]
    }

    /// The entries a plan approval may carry: a session-only switch to one of `Mode`. Everything else is dropped.
    public static func sanitized(_ updates: [JSONValue]) -> [JSONValue] {
        updates.filter { u in
            u["type"]?.stringValue == "setMode" && u["destination"]?.stringValue == "session"
                && (u["mode"]?.stringValue).flatMap(Mode.init(rawValue:)) != nil
        }
    }
}

/// What the decision log and the activity log keep about a request: short labels, never the full plan
/// and never more than `maxSummary` characters of a question, an answer or feedback.
public enum RequestLog {
    public static let maxSummary = 120

    /// One line, at most `maxSummary` characters.
    public static func clip(_ s: String) -> String {
        let line = s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > maxSummary ? String(line.prefix(maxSummary - 1)) + "…" : line
    }

    /// What the request was about.
    public static func title(_ kind: PendingKind, cwd: String?, adapter: AgentAdapter) -> String {
        switch kind {
        case .permission(let tool, let input):
            return adapter.summarize(toolName: tool, input: input, cwd: cwd)
        case .question(let qs, _):
            let more = qs.count > 1 ? " (+\(qs.count - 1) more)" : ""
            return clip("Question: " + (qs.first?.question ?? "")) + more
        case .plan(let text, _):
            return clip("Plan: " + planTitle(text))
        }
    }

    /// The first non-empty line of the plan without Markdown heading marks.
    public static func planTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    public static func label(_ kind: PendingKind, _ decision: Decision) -> String {
        switch (kind, decision) {
        case (.plan, .allow), (.plan, .allowWith): return "plan approved"
        case (.plan, .deny): return "plan sent back"
        default: return decision.logLabel
        }
    }

    /// Details of the decision: the reason, the rule or mode, a summary of the answers.
    public static func detail(_ kind: PendingKind, _ decision: Decision) -> String {
        switch (kind, decision) {
        case (.question(let qs, _), .answer(let answers)):
            let parts = qs.compactMap { q -> String? in
                guard let a = answers[q.question] else { return nil }
                if let h = q.header, !h.isEmpty { return "\(h): \(a)" }
                return a
            }
            return clip(parts.joined(separator: "; "))
        case (.plan, .deny(let reason)):
            return clip(reason ?? "")
        case (_, .deny(let reason)):
            return reason ?? ""
        case (_, .allowWith(let updates)):
            return updates.compactMap(PermissionRules.describe).joined(separator: "; ")
        default:
            return ""
        }
    }
}
