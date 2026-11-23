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
    @State private var atBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        ChatRow(item: item).padding(.top, i == 0 ? 0 : gap(items[i - 1], item))
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

/// The next message for a session. The text goes into the editor's input field; the person sends it there.
struct ChatInput: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @State private var text = ""

    var body: some View {
        if session.host.canPrefillPrompt {
            VStack(alignment: .leading, spacing: 6) {
                if !model.settings.quickPrompts.isEmpty { chips }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Message…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .lineLimit(1...4)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { text += "\n" } else { send() }
                            return .handled
                        }
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                        .disabled(!canSend)
                        .help("Open the session in \(session.host.editorName) with this text")
                }
                Text("Opens the session in \(session.host.editorName) with this text. Press Return there to send.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            // The draft outlives the card: closing it (also by a click elsewhere) must not lose typed text.
            .onAppear { text = model.draft(session.id) }
            .onChange(of: text) { _, t in model.setDraft(session.id, t) }
        } else {
            HStack(spacing: 8) {
                Image(systemName: session.host.placeSymbol).foregroundStyle(.secondary)
                Text("Reply \(session.host.placeIn)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Open") { model.open(session.id) }.controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.settings.quickPrompts, id: \.self) { p in
                    Button { model.prefillPrompt(session.id, p) } label: {
                        Text(p).font(.system(size: 11)).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Insert \"\(p)\" into the session's input field in \(session.host.editorName)")
                }
            }
        }
        .frame(height: 22)
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.prefillPrompt(session.id, t)
        text = ""
    }
}
