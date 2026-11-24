import AgentHudCore
import SwiftUI

// MARK: - Loading

/// Reads the conversation of the open session from its transcript file, always off the main thread.
/// A re-read happens on a session event and, while the card is open, every 2 s if the file changed.
@MainActor
final class ChatLoader: ObservableObject {
    @Published private(set) var items: [ChatItem] = []

    private struct Stamp: Equatable, Sendable { var size: Int64; var modified: Date? }

    private let fixed: Bool
    private var key: String?
    private var url: URL?
    private var generation = 0          // bumped on every bind: results of an older session are dropped
    private var requestSeq = 0
    private var appliedSeq = 0
    private var stamp: Stamp?
    private var poll: Task<Void, Never>?
    private nonisolated static let queue = DispatchQueue(label: "agenthud.chat", qos: .userInitiated)

    /// `preset` is for the offscreen render check: fixed items, no file access.
    init(preset: [ChatItem]? = nil) {
        fixed = preset != nil
        items = preset ?? []
    }

    func bind(key: String, path: String?) {
        guard !fixed else { return }
        let newURL = path.map { URL(fileURLWithPath: $0) }
        if key == self.key, newURL == url, poll != nil { return }
        self.key = key
        url = newURL
        generation += 1
        stamp = nil
        items = []
        poll?.cancel()
        poll = nil
        guard newURL != nil else { return }
        reload(force: true)
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.reload(force: false)
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        key = nil
        generation += 1
    }

    func reload(force: Bool) {
        guard !fixed, let url else { return }
        requestSeq += 1
        let seq = requestSeq, gen = generation, last = stamp
        Self.queue.async { [weak self] in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let now = Stamp(size: (attrs?[.size] as? NSNumber)?.int64Value ?? -1, modified: attrs?[.modificationDate] as? Date)
            if !force, now == last { return }
            let read = Transcript.read(url, limit: 200, maxBytes: 4_000_000)
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, seq > self.appliedSeq else { return }
                self.appliedSeq = seq
                self.stamp = now
                if read != self.items { self.items = read }
            }
        }
    }
}

// MARK: - Chat

struct ChatView: View {
    let items: [ChatItem]
    /// Text of a reply that is still being written (a session run by the app); shown as the last row.
    var streaming = ""
    @State private var atBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        ChatRow(item: item).padding(.top, i == 0 ? 0 : gap(items[i - 1], item))
                    }
                    if !streaming.isEmpty {
                        StreamingText(text: streaming).padding(.top, items.isEmpty ? 0 : 10)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24
            } action: { _, near in atBottom = near }
            .onChange(of: items.last?.id) { _, _ in
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: streaming.count) { _, _ in
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// Tool rows sit tight together; everything else gets air.
    private func gap(_ a: ChatItem, _ b: ChatItem) -> CGFloat {
        if case .tool = a.kind, case .tool = b.kind { return 2 }
        return 10
    }
}

struct ChatRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack(spacing: 0) {
                Spacer(minLength: 54)    // about 15% of the card width: a bubble is at most 85%
                Text(verbatim: text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.18)))
            }
        case .assistant(let text):
            AssistantText(text: text)
        case .tool(let name, let summary, let status):
            ToolRow(name: name, summary: summary, status: status)
        }
    }
}

struct AssistantText: View {
    let text: String
    @State private var expanded = false
    private static let collapsedLines = 14

    private var isLong: Bool {
        text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + 1 > Self.collapsedLines
    }

    private var rendered: AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rendered)
                .font(.system(size: 12))
                .lineLimit(isLong && !expanded ? Self.collapsedLines : nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLong {
                Button(expanded ? "Collapse" : "Show all") { expanded.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
    }
}

/// The reply while it is being written: plain text (half-written Markdown is not parsed) with a progress mark.
struct StreamingText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                Text("Writing…").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Conversation of a session run by the app: rows from its output stream plus the reply being written.
struct OwnedChat: View {
    @ObservedObject var owned: OwnedSession

    var body: some View {
        let items = owned.history + owned.items
        if items.isEmpty && owned.partialText.isEmpty {
            Text(owned.isLive ? "No messages yet. Write the first one below." : "No messages.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ChatView(items: items, streaming: owned.partialText)
        }
    }
}

/// What a session run by the app has to say besides the conversation: a failed start (with the end of the
/// process's error output), an error at the end of a turn, a retry or a refused tool call.
struct OwnedNotices: View {
    @ObservedObject var owned: OwnedSession
    let hooksSilent: Bool

    var body: some View {
        if let e = owned.lastError {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(e).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                if !owned.isLive, !tail.isEmpty {
                    Text(verbatim: tail)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(8).truncationMode(.head)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.1)))
        }
        if let n = owned.notice {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(n).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        if hooksSilent {
            Notice(icon: "exclamationmark.shield", color: .orange,
                   text: "No hook events have arrived for this session, so its permission requests cannot reach Agent HUD and are refused.")
        }
    }

    /// The last lines of the process's error output.
    private var tail: String {
        owned.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
    }
}

struct ToolRow: View {
    let name: String
    let summary: String
    let status: StepStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Fmt.icon(for: name))
                .font(.system(size: 10)).frame(width: 14)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(status == .failed ? Color.red : Color.primary)
            Spacer(minLength: 4)
            switch status {
            case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            case .ok: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green).frame(width: 12)
            case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.red).frame(width: 12)
            }
        }
        .frame(height: 18)
    }
}

// MARK: - Input

/// A transient line under the field: what happened to the last send.
struct ChatInputNote: Equatable {
    let text: String
    var isError = false
}

/// Fixed state for the offscreen render check: no key events, no file access, no permission query.
struct ChatInputPreset {
    var text = ""
    var commands: [SlashCommand] = []
    var selectedRow = 0
    var trusted = true
    var note: ChatInputNote?
}

/// Texts of the input of a session run by the app.
enum OwnedInputText {
    static let helper = "Sends directly — this session runs in Agent HUD"
    static let interruptHelp = "Interrupt: end the current turn"
    static let forceStopHelp = "The turn has not ended yet. Press again to end the session's process"
}

/// The next message for a session. Return sends it: typed into the host app when that is allowed, otherwise copied.
struct ChatInput: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    /// State of the session's process when this app runs it; nil for a session in an editor or a terminal.
    let owned: OwnedSessionLogic.State?
    private let preset: ChatInputPreset?

    @State private var text: String
    @State private var selection: TextSelection?
    @State private var nav: SuggestionNav
    @State private var commands: [SlashCommand]
    @State private var loadedCwd: String?
    @State private var note: ChatInputNote?
    @State private var noteTask: Task<Void, Never>?
    @State private var sending = false
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 24

    init(model: AppModel, session: AgentSession, owned: OwnedSessionLogic.State? = nil, preset: ChatInputPreset? = nil) {
        self.model = model
        self.session = session
        self.owned = owned
        self.preset = preset
        _text = State(initialValue: preset?.text ?? "")
        _commands = State(initialValue: preset?.commands ?? [])
        _note = State(initialValue: preset?.note)
        let count = SlashCommands.suggestions(for: preset?.text ?? "", in: preset?.commands ?? []).count
        _nav = State(initialValue: SuggestionNav(count: count, index: preset?.selectedRow ?? 0))
    }

    private var kind: SendHostKind { SendHostKind(host: session.host) }
    private var suggestions: [SlashCommand] { SlashCommands.suggestions(for: text, in: commands, limit: 8) }
    private var canSend: Bool {
        if let owned, owned != .starting, owned != .idle { return false }
        return !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// A turn is in progress in a process of this app: the button interrupts instead of sending.
    private var interruptible: Bool { owned == .running || owned == .interrupting }

    private var helperMode: SendMode {
        SendPlan.expectedMode(trusted: preset?.trusted ?? PromptSender.isTrusted,
                              typingEnabled: model.settings.sendByTyping, hostKind: kind)
    }

    var body: some View {
        if InputLogic.inputMode(owned: owned != nil, hostCanBeTyped: kind.canCompose) != .watchOnly {
            composer
        } else {
            HStack(spacing: 8) {
                Image(systemName: session.host.placeSymbol).foregroundStyle(.secondary)
                Text(InputLogic.watchLine(hostLabel: session.host.label)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Open") { model.open(session.id) }.controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.settings.quickPrompts.isEmpty { chips }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message…", text: $text, selection: $selection, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            insertNewline()
                        } else if let c = nav.selected(in: suggestions) {
                            accept(c)
                        } else {
                            send(text, fromField: true)
                        }
                        return .handled
                    }
                    .onKeyPress(.tab, phases: .down) { _ in
                        guard let c = nav.selected(in: suggestions) else { return .ignored }
                        accept(c)
                        return .handled
                    }
                    .onKeyPress(.upArrow, phases: .down) { _ in move(-1) }
                    .onKeyPress(.downArrow, phases: .down) { _ in move(1) }
                    .onKeyPress(.escape, phases: .down) { _ in
                        guard nav.isOpen else { return .ignored }
                        nav.dismiss()
                        return .handled
                    }
                if interruptible {
                    Button { model.interrupt(session.id) } label: { Image(systemName: "stop.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(owned == .interrupting ? Color.orange : Color.red)
                        .help(owned == .interrupting ? OwnedInputText.forceStopHelp : OwnedInputText.interruptHelp)
                        .accessibilityLabel("Interrupt")
                } else {
                    Button { send(text, fromField: true) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                        .disabled(!canSend)
                        .help(owned != nil ? OwnedInputText.helper
                              : helperMode == .type ? "Send to the session in \(session.host.label)"
                                                    : "Copy the text and open the session in \(session.host.label)")
                }
            }
            .overlay(alignment: .top) {
                if nav.isOpen {
                    SlashSuggestionList(items: suggestions, selected: nav.index, rowHeight: Self.rowHeight,
                                        onHover: { nav.select($0) }, onPick: accept)
                        .offset(y: -(SlashSuggestionList.height(rows: suggestions.count, rowHeight: Self.rowHeight) + 4))
                }
            }
            helperLine
        }
        // The draft outlives the card: closing it (also by a click elsewhere) must not lose typed text.
        .onAppear { if preset == nil { text = model.draft(session.id) } }
        .onChange(of: text) { _, t in
            if preset == nil { model.setDraft(session.id, t) }
            nav.reset(count: suggestions.count)
        }
        .onChange(of: commands) { _, _ in nav.reset(count: suggestions.count) }
        .task(id: session.cwd) { await loadCommands() }
        .onDisappear { noteTask?.cancel() }
    }

    @ViewBuilder private var helperLine: some View {
        if let note {
            Text(note.text)
                .font(.system(size: 10)).foregroundStyle(note.isError ? Color.orange : Color.secondary)
                .lineLimit(2)
        } else if let owned {
            Text(owned == .interrupting ? OwnedInputText.forceStopHelp
                 : owned == .running ? "The agent is working — the stop button interrupts it" : OwnedInputText.helper)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(2)
        } else {
            Text(SendPlan.helperLine(mode: helperMode, hostLabel: session.host.label))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.settings.quickPrompts, id: \.self) { p in
                    Button { send(p, fromField: false) } label: {
                        Text(p).font(.system(size: 11)).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(sending || interruptible)
                    .help("Send \"\(p)\" to the session in \(session.host.label)")
                }
            }
        }
        .frame(height: 22)
    }

    // MARK: Suggestions

    private func loadCommands() async {
        guard preset == nil, loadedCwd != session.cwd else { return }
        let cwd = session.cwd
        let list = await Task.detached(priority: .userInitiated) {
            SlashCommands.available(home: FileManager.default.homeDirectoryForCurrentUser,
                                    projectDir: cwd.isEmpty ? nil : URL(fileURLWithPath: cwd, isDirectory: true))
        }.value
        commands = list
        loadedCwd = cwd
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard nav.isOpen else { return .ignored }
        nav.move(delta)
        return .handled
    }

    private func accept(_ c: SlashCommand) {
        text = SuggestionNav.accepted(c)
        selection = TextSelection(insertionPoint: text.endIndex)
        focused = true
    }

    // MARK: Editing

    /// Shift-Return: a newline at the caret instead of at the end.
    private func insertNewline() {
        var range: Range<Int>?
        if let sel = selection, case .selection(let r) = sel.indices,
           r.lowerBound <= text.endIndex, r.upperBound <= text.endIndex {
            range = text.distance(from: text.startIndex, to: r.lowerBound)..<text.distance(from: text.startIndex, to: r.upperBound)
        }
        let edit = InputEdit.insertNewline(in: text, selection: range)
        text = edit.text
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: edit.caret))
    }

    // MARK: Sending

    private func send(_ raw: String, fromField: Bool) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preset == nil, !t.isEmpty, !sending else { return }
        sending = true
        showNote(nil)
        let key = session.id
        Task { @MainActor in
            let outcome = await model.send(key, t)
            sending = false
            switch outcome {
            case .sent:
                if fromField, text.trimmingCharacters(in: .whitespacesAndNewlines) == t { text = "" }
                showNote(ChatInputNote(text: SendPlan.sentNote), seconds: SendPlan.sentNoteSeconds)
            case .copied:
                if fromField, text.trimmingCharacters(in: .whitespacesAndNewlines) == t { text = "" }
                showNote(ChatInputNote(text: SendPlan.copiedNote), seconds: SendPlan.copiedNoteSeconds)
            case .failed(let reason):
                // The text stays in the field; a chip has no field to keep it in, so the note is shown for longer.
                showNote(ChatInputNote(text: reason, isError: true), seconds: 8)
            }
        }
    }

    private func showNote(_ n: ChatInputNote?, seconds: Double = 0) {
        noteTask?.cancel()
        note = n
        guard n != nil, seconds > 0 else { return }
        noteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            note = nil
        }
    }
}

/// Command suggestions above the field. Fixed row height; at most 8 rows.
struct SlashSuggestionList: View {
    let items: [SlashCommand]
    let selected: Int
    let rowHeight: CGFloat
    let onHover: (Int) -> Void
    let onPick: (SlashCommand) -> Void

    /// Total height of the list, so the caller can place it right above the field.
    static func height(rows: Int, rowHeight: CGFloat) -> CGFloat { CGFloat(rows) * rowHeight + 8 }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                row(c, isSelected: i == selected)
                    .onHover { if $0 { onHover(i) } }
                    .onTapGesture { onPick(c) }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    private func row(_ c: SlashCommand, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text("/" + c.name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1).layoutPriority(3)
            if let hint = c.argumentHint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).layoutPriority(2)
            }
            Text(c.description)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if c.source != .builtin {
                Text(c.source.rawValue)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .fixedSize().layoutPriority(4)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }
}
