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

// MARK: - Expired

struct ExpiredView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let request: PendingRequest

    var body: some View {
        let what: String = {
            switch request.kind {
            case .permission(let t, _): return "Permission request (\(t))"
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
