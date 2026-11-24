import AgentHudCore
import SwiftUI

// MARK: - Permission

struct PermissionView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let request: PendingRequest
    let tool: String
    let input: JSONValue

    @State private var denying = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    var body: some View {
        let flags = RedFlags.matches(toolName: tool, input: input)
        let ruleOptions = ruleOptions(flags)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(flags.isEmpty ? .orange : .red)
                Text("Asks for permission: \(toolTitle)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Countdown(deadline: request.deadline)
            }
            if !flags.isEmpty {
                Label(flags.map(\.title).joined(separator: " · "), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ToolDetail(tool: tool, input: input, cwd: session.cwd)
            if denying {
                TextField("Why (optional) - the agent will receive this", text: $reason)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .controlSize(.large)
                    .focused($reasonFocused)
                    .onSubmit { deny() }
                HStack(spacing: 8) {
                    BigButton(title: "Deny", symbol: "xmark", prominent: true, role: .destructive) { deny() }
                    BigButton(title: "Cancel", symbol: "arrow.uturn.backward") { denying = false }
                }
            } else {
                // Main actions - large and full width.
                HStack(spacing: 8) {
                    // A dangerous command: no highlight and no ⌘↩ - so it can't be allowed with one habitual keypress.
                    BigButton(title: "Allow", symbol: "checkmark", prominent: flags.isEmpty) { model.decide(request.id, .allow) }
                        .keyboardShortcut(flags.isEmpty ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        .help(flags.isEmpty ? "Allow once (⌘↩)" : "Allow once")
                    BigButton(title: "Deny…", symbol: "xmark", role: .destructive) { denying = true; reasonFocused = true }
                        .help("Deny; you can tell the agent why")
                }
                HStack(spacing: 6) {
                    if !ruleOptions.isEmpty {
                        AlwaysMenu(options: ruleOptions) { o in model.decide(request.id, .allowWith([o.update])) }
                    }
                    Spacer(minLength: 0)
                    Button { model.decide(request.id, .passthrough) } label: {
                        Label(session.host.passthroughTitle, systemImage: session.host.placeSymbol)
                    }
                    .help("Answer where the agent is running: the window closes and its session opens")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(flags.isEmpty ? Color.orange.opacity(0.09) : Color.red.opacity(0.14)))
    }

    private var toolTitle: String {
        if tool.hasPrefix("mcp__") { return Adapters.adapter(for: session.kind).summarize(toolName: tool, input: input, cwd: nil) }
        return tool
    }

    private func ruleOptions(_ flags: [RedFlagRule]) -> [RuleOption] {
        PermissionRules.options(toolName: tool, input: input, suggestions: request.suggestions, redFlags: flags)
    }

    private func deny() {
        model.decide(request.id, .deny(reason: reason.isEmpty ? nil : reason))
    }
}

/// A large action button: full available width, 34 pt tall.
/// A custom style rather than the system one: the system "prominent" button turns gray when the window is inactive -
/// and a window opened by a request is exactly inactive, so "Allow" looked no different from "Deny".
struct BigButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(BigButtonStyle(prominent: prominent, destructive: role == .destructive))
    }
}

struct BigButtonStyle: ButtonStyle {
    let prominent: Bool
    let destructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        BigButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }
}

private struct BigButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let tint: Color = destructive ? Brand.danger : Brand.accent
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : (destructive ? Brand.danger : Color.primary))
            .frame(maxWidth: .infinity, minHeight: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? tint.opacity(hover ? 0.88 : 1) : Color.primary.opacity(hover ? 0.1 : 0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : (destructive ? Brand.danger.opacity(0.5) : Color.primary.opacity(0.14)),
                                  lineWidth: 1)
            }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { hover = $0 }
    }
}

/// The "Always" menu: a template from the HUD (a shorter rule list) and Claude Code's own suggestions.
struct AlwaysMenu: View {
    let options: [RuleOption]
    let pick: (RuleOption) -> Void

    var body: some View {
        Menu {
            let generated = options.filter(\.generated)
            let suggested = options.filter { !$0.generated }
            if !generated.isEmpty {
                Section("Template") {
                    ForEach(generated) { o in Button("\(o.title) — \(o.scope)") { pick(o) } }
                }
            }
            if !suggested.isEmpty {
                Section("As suggested by Claude") {
                    ForEach(suggested) { o in Button("\(o.title) — \(o.scope)") { pick(o) } }
                }
            }
        } label: {
            Text("Always")
        }
        .fixedSize()
        .help("Allow and stop asking: the rule is written to Claude Code settings")
    }
}

struct Countdown: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(deadline.timeIntervalSince(ctx.date)))
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(left < 30 ? Color.red : Color.secondary)
                .help("Time left before the question goes to the terminal")
        }
    }
}

/// What exactly the agent wants to do - in readable form. Always height-limited and scrollable:
/// a huge input (a long script, a big file) must not push the buttons off the edge of the screen.
struct ToolDetail: View {
    let tool: String
    let input: JSONValue
    let cwd: String
    static let maxHeight: CGFloat = 200

    var body: some View {
        // Short input takes only the height it needs; a scroll view alone would always claim the full limit.
        ViewThatFits(in: .vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: Self.maxHeight)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch tool {
            case "Bash":
                if let d = input["description"]?.stringValue, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Code(text: input["command"]?.stringValue ?? "", maxLines: 8)
            case "Edit":
                PathLine(path: input["file_path"]?.stringValue ?? "", cwd: cwd)
                DiffBlock(old: input["old_string"]?.stringValue ?? "", new: input["new_string"]?.stringValue ?? "")
            case "MultiEdit":
                PathLine(path: input["file_path"]?.stringValue ?? "", cwd: cwd)
                let edits = input["edits"]?.arrayValue ?? []
                Text("Edits: \(edits.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                if let first = edits.first {
                    DiffBlock(old: first["old_string"]?.stringValue ?? "", new: first["new_string"]?.stringValue ?? "")
                }
            case "Write":
                PathLine(path: input["file_path"]?.stringValue ?? "", cwd: cwd)
                Code(text: input["content"]?.stringValue ?? "", maxLines: 8)
            case "WebFetch":
                Code(text: input["url"]?.stringValue ?? "", maxLines: 2)
                if let p = input["prompt"]?.stringValue { Text(p).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
            default:
                KeyValueDetail(input: input)
            }
        }
    }
}

/// An unknown tool (Workflow, MCP...): "key - value" fields, long values truncated.
/// It used to show the whole JSON, and a single line of tens of thousands of characters took up the whole screen.
struct KeyValueDetail: View {
    let input: JSONValue
    static let maxFields = 8

    var body: some View {
        if let obj = input.objectValue, !obj.entries.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(obj.entries.prefix(Self.maxFields).enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: e.key).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Code(text: e.value.stringValue ?? e.value.pretty(), maxLines: 6, maxChars: 500)
                    }
                }
                if obj.entries.count > Self.maxFields {
                    Text("… \(obj.entries.count - Self.maxFields) more fields").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        } else {
            Code(text: input.pretty(), maxLines: 10)
        }
    }
}

struct PathLine: View {
    let path: String
    let cwd: String

    var body: some View {
        let short = path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
        Label(short, systemImage: "doc")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
    }
}

/// Code without interpretation: text only, no links or markup.
/// Truncated by both lines and characters: a single line without breaks can also be huge.
struct Code: View {
    let text: String
    var maxLines: Int = 8
    var maxChars: Int = 1500
    var color: Color = .primary
    var background: Color = Color.primary.opacity(0.06)

    var body: some View {
        let (shown, moreLines, moreChars) = Self.clip(text, maxLines: maxLines, maxChars: maxChars)
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: shown)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if moreLines > 0 {
                Text("… \(moreLines) more lines").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if moreChars > 0 {
                Text("… \(moreChars) more characters").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(background))
    }

    /// The first `maxLines` lines, but no more than `maxChars` characters; how many lines and characters are left off-screen.
    static func clip(_ text: String, maxLines: Int, maxChars: Int) -> (String, Int, Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = lines.prefix(maxLines).joined(separator: "\n")
        let moreLines = max(0, lines.count - maxLines)
        var moreChars = 0
        if shown.count > maxChars {
            moreChars = text.count - maxChars
            shown = String(shown.prefix(maxChars)) + "…"
        }
        return (shown, moreLines, moreChars)
    }
}

struct DiffBlock: View {
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !old.isEmpty {
                Code(text: prefixed(old, "−"), maxLines: 5, color: .red, background: Color.red.opacity(0.08))
            }
            Code(text: prefixed(new, "+"), maxLines: 6, color: .green, background: Color.green.opacity(0.08))
        }
    }

    private func prefixed(_ s: String, _ mark: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "\(mark) \($0)" }.joined(separator: "\n")
    }
}

// MARK: - Shared by the question and the plan

/// Initial state of a request view - for the render check only.
struct RequestPreset {
    var draft = QuestionDraft()
    var sendingBack = false
    var feedback = ""
}

extension AgentSession {
    /// The state label; for a waiting session it names what exactly waits for the user.
    var stateTitle: String {
        switch activePending?.kind {
        case .question: return "Has a question"
        case .plan: return "Plan ready"
        default: return state.title
        }
    }
}

extension HostInfo {
    /// "Answer in VS Code", "Decide in terminal": the hook steps aside and the host shows its own interface.
    func elsewhereTitle(_ verb: String) -> String {
        switch place {
        case .terminal: return "\(verb) in terminal"
        case .desktopApp: return "\(verb) in app"
        case .editor: return "\(verb) in \(editorName)"
        case .hud: return "Skip"
        }
    }
}

extension View {
    /// A text field that grows with its text. The system bordered style keeps a single line on macOS.
    func requestField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
    }
}

/// The long part of a request (questions, plan text): takes only the height it needs, and when the card has less
/// than that it takes what is left and scrolls, so the buttons under it always stay inside the card.
struct RequestScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                // The bottom padding lets the last line scroll out of the fade.
                content.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 14)
            }
            // The fading edge shows that there is more below.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }
}

// MARK: - Question (AskUserQuestion)

struct QuestionView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let request: PendingRequest
    let questions: [Question]

    @State private var draft: QuestionDraft
    @FocusState private var focusedOther: Int?

    init(model: AppModel, session: AgentSession, request: PendingRequest, questions: [Question], preset: RequestPreset? = nil) {
        self.model = model
        self.session = session
        self.request = request
        self.questions = questions
        _draft = State(initialValue: preset?.draft ?? QuestionDraft())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
                Text(questions.count > 1 ? "The agent asks \(questions.count) questions" : "The agent asks")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Countdown(deadline: request.deadline)
            }
            if let hold = session.hold {
                // The tool call itself waits in the hold: an answer given now is kept by Claude Code until then.
                Text("The session is \(hold.kind == .pause ? "paused" : "stopped"): the agent gets the answer after you resume it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            RequestScroll {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in block(qi, q) }
                }
            }
            BigButton(title: "Send answers", symbol: "paperplane.fill", prominent: true) { submit() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draft.isComplete(questions))
                .help(draft.isComplete(questions) ? "Send the answers to the agent (⌘↩)" : "Answer every question first")
            HStack(spacing: 6) {
                if questions.count > 1 {
                    let done = questions.indices.filter { draft.answer($0, in: questions) != nil }.count
                    Text("Answered \(done) of \(questions.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { model.decide(request.id, .passthrough) } label: {
                    Label(session.host.elsewhereTitle("Answer"), systemImage: session.host.placeSymbol)
                }
                .help("Nothing is answered here: the question is shown where the agent is running")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.09)))
    }

    @ViewBuilder private func block(_ qi: Int, _ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let h = q.header, !h.isEmpty {
                    Text(h).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Brand.accent.opacity(0.15)))
                }
                if q.multiSelect {
                    Text("Choose any number").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(verbatim: q.question).font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(q.options.enumerated()), id: \.offset) { oi, opt in
                OptionRow(label: opt.label, detail: opt.description, multi: q.multiSelect,
                          selected: draft.isPicked(qi, oi)) {
                    draft.toggle(qi, option: oi, multi: q.multiSelect)
                }
            }
            // Claude Code always lets the user give an own answer instead of the offered options.
            OptionRow(label: "Other…", detail: nil, multi: q.multiSelect, selected: draft.otherOn.contains(qi)) {
                draft.toggleOther(qi, multi: q.multiSelect)
                focusedOther = draft.otherOn.contains(qi) ? qi : nil
            }
            if draft.otherOn.contains(qi) {
                TextField("Your answer", text: Binding(get: { draft.other[qi] ?? "" }, set: { draft.other[qi] = $0 }), axis: .vertical)
                    .lineLimit(1...3)
                    .requestField()
                    .font(.system(size: 12))
                    .focused($focusedOther, equals: qi)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
    }

    private func submit() {
        guard let answers = draft.answers(questions) else { return }
        model.decide(request.id, .answer(answers))
    }
}

/// One selectable answer: a radio mark for a single choice, a checkbox for a multiple one.
struct OptionRow: View {
    let label: String
    let detail: String?
    let multi: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square")
                                        : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Brand.accent : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: label).font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let d = detail, !d.isEmpty {
                        Text(verbatim: d).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Brand.accent.opacity(0.14) : Color.primary.opacity(hover ? 0.08 : 0.045)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Plan (ExitPlanMode)

struct PlanView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let request: PendingRequest
    let text: String

    @State private var sendingBack: Bool
    @State private var feedback: String
    @FocusState private var feedbackFocused: Bool

    init(model: AppModel, session: AgentSession, request: PendingRequest, text: String, preset: RequestPreset? = nil) {
        self.model = model
        self.session = session
        self.request = request
        self.text = text
        _sendingBack = State(initialValue: preset?.sendingBack ?? false)
        _feedback = State(initialValue: preset?.feedback ?? "")
    }

    private var trimmedFeedback: String { feedback.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(.orange)
                Text("The plan is ready").font(.system(size: 12, weight: .semibold))
                Spacer()
                Countdown(deadline: request.deadline)
            }
            RequestScroll {
                MarkdownBlocks(text: text).padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            if sendingBack {
                TextField("What to change in the plan", text: $feedback, axis: .vertical)
                    .lineLimit(1...4)
                    .requestField()
                    .font(.system(size: 13))
                    .focused($feedbackFocused)
                    // The notes keep their own height; the plan above gives up the space.
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                HStack(spacing: 8) {
                    BigButton(title: "Send back", symbol: "arrow.uturn.left", prominent: true) { sendBack() }
                        .disabled(trimmedFeedback.isEmpty)
                        .help(trimmedFeedback.isEmpty ? "Write what to change first" : "The agent stays in plan mode and gets your notes")
                    BigButton(title: "Cancel", symbol: "xmark") { sendingBack = false }
                }
            } else {
                // No keyboard shortcut on purpose: a plan is approved only by a click on the button.
                HStack(spacing: 8) {
                    BigButton(title: "Approve", symbol: "checkmark", prominent: true) { approve(.keepAsking) }
                        .help("Approve the plan; the agent keeps asking before it edits files or runs commands")
                    BigButton(title: "Send back…", symbol: "arrow.uturn.left") { sendingBack = true; feedbackFocused = true }
                        .help("Keep the agent in plan mode and tell it what to change")
                }
                HStack(spacing: 6) {
                    Button("Approve, accept edits") { approve(.acceptEdits) }
                        .help("Approve the plan and accept file edits without asking until the session ends; commands are still asked about")
                    Spacer(minLength: 0)
                    Button { model.decide(request.id, .passthrough) } label: {
                        Label(session.host.elsewhereTitle("Decide"), systemImage: session.host.placeSymbol)
                    }
                    .help("Nothing is decided here: the plan is shown where the agent is running")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.09)))
    }

    private func approve(_ mode: PlanApproval.Mode) {
        model.decide(request.id, .allowWith(PlanApproval.updates(mode)))
    }

    private func sendBack() {
        guard !trimmedFeedback.isEmpty else { return }
        model.decide(request.id, .deny(reason: trimmedFeedback))
    }
}

/// Markdown of a plan, block by block: headings, lists, code blocks and paragraphs with inline marks.
/// Links are shown as text only: nothing in a plan can be clicked.
struct MarkdownBlocks: View {
    let text: String
    static let maxLines = 400

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case item(marker: String, indent: Int, text: String)
        case code(String)
        case paragraph(String)
    }

    var body: some View {
        let (blocks, hidden) = Self.parse(text, maxLines: Self.maxLines)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let level, let t):
                    Text(Self.inline(t)).font(.system(size: level <= 1 ? 14 : (level == 2 ? 13 : 12), weight: .semibold))
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                case .item(let marker, let indent, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(verbatim: marker).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        Text(Self.inline(t)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(min(indent, 4)) * 12)
                case .code(let c):
                    Text(verbatim: c).font(.system(size: 11, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                case .paragraph(let t):
                    Text(Self.inline(t)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if hidden > 0 {
                Text("… \(hidden) more lines").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var a = try? AttributedString(markdown: s, options: opts) else { return AttributedString(s) }
        for run in a.runs where run.link != nil { a[run.range].link = nil }
        return a
    }

    /// Blocks of the first `maxLines` lines and the number of lines left out.
    static func parse(_ text: String, maxLines: Int) -> ([Block], Int) {
        let all = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for line in all.prefix(maxLines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush()
                blocks.append(.heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1))))
            } else if let f = trimmed.first, "-*+".contains(f), trimmed.dropFirst().first == " " {
                flush()
                var body = String(trimmed.dropFirst(2))
                var marker = "•"
                for (box, mark) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where body.hasPrefix(box) {
                    body = String(body.dropFirst(box.count)); marker = mark
                }
                blocks.append(.item(marker: marker, indent: indent, text: body))
            } else if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
                      dot != trimmed.startIndex, trimmed[..<dot].allSatisfy(\.isNumber), trimmed[..<dot].count <= 3,
                      trimmed[trimmed.index(after: dot)...].first == " " {
                flush()
                blocks.append(.item(marker: String(trimmed[..<dot]) + ".", indent: indent,
                                    text: String(trimmed[trimmed.index(after: dot)...].dropFirst())))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return (blocks, max(0, all.count - maxLines))
    }
}

// MARK: - Expired

struct ExpiredView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let request: PendingRequest

    var body: some View {
        let what: String = {
            switch request.kind {
            case .permission(let t, _): return "Permission request (\(t))"
            case .question: return "The question"
            case .plan: return "The plan"
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Color(red: 0.75, green: 0.5, blue: 0.25))
                Text("Expired").font(.system(size: 12, weight: .semibold))
            }
            Text("\(what) waited too long and went to \(session.host.placeTo). Answer there.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { model.open(session.id) } label: {
                    Label(session.host.openTitle, systemImage: "arrow.up.forward.app")
                }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { model.dismissExpired(session.id) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.brown.opacity(0.1)))
    }
}
