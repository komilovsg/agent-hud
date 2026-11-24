import AgentHudCore
import SwiftUI

/// State of the command bar. The real bar reads sessions and settings from the app model; the render check
/// builds one with fixed values and no app model.
@MainActor
final class CommandBarModel: ObservableObject {
    struct Status: Equatable {
        var text: String
        var isError = false
    }

    let app: AppModel?
    /// The typed text: kept when the bar closes (a draft) and cleared after a send.
    @Published var text = ""
    @Published var entries: [CommandBarEntry]
    @Published var target: CommandBarTarget
    @Published var status: Status?
    @Published var menuOpen = false
    @Published var commands: [SlashCommand] = []
    /// Bumped whenever the field should take the keyboard.
    @Published var focusTick = 0
    /// Fixed state of the target for the render check; nil - read from the app.
    private let previewBusy: Bool?
    let previewRow: Int

    var onSubmit: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onPicked: (CommandBarTarget) -> Void = { _ in }
    var onNewConversation: () -> Void = {}
    var onHeight: (CGFloat) -> Void = { _ in }

    init(app: AppModel) {
        self.app = app
        entries = CommandBarLogic.entries(live: [], assistantSessionId: nil)
        target = .assistant
        previewBusy = nil
        previewRow = 0
    }

    /// Fixed state for the offscreen render check.
    init(previewText: String, entries: [CommandBarEntry], target: CommandBarTarget = .assistant, busy: Bool = false,
         status: Status? = nil, menuOpen: Bool = false, commands: [SlashCommand] = [], row: Int = 0) {
        app = nil
        text = previewText
        self.entries = entries
        self.target = target
        self.status = status
        self.menuOpen = menuOpen
        self.commands = commands
        previewBusy = busy
        previewRow = row
    }

    var targetEntry: CommandBarEntry? { entries.first { $0.target == target } }
    var targetTitle: String { targetEntry?.title ?? AssistantSession.label }

    var busy: Bool {
        if let previewBusy { return previewBusy }
        return CommandBarLogic.isBusy(app?.commandBarState(of: target))
    }

    var statusText: Status {
        if let status { return status }
        let line = CommandBarLogic.statusLine(error: nil, busyTitle: busy ? targetTitle : nil, newSession: target == .newSession)
        return Status(text: line, isError: false)
    }

    var placeholder: String {
        switch target {
        case .assistant: return "Ask the Assistant, or tell it what to do"
        case .session: return "Message \(targetTitle)"
        case .newSession: return "Describe the task for a new session"
        }
    }

    func pick(_ t: CommandBarTarget) {
        target = t
        menuOpen = false
        status = nil
        focusTick += 1
        onPicked(t)
    }
}

enum CommandBarSymbol {
    static func name(for target: CommandBarTarget) -> String {
        switch target {
        case .assistant: return "sparkles"
        case .session: return "terminal"
        case .newSession: return "plus.bubble"
        }
    }
}

// MARK: - Bar

struct CommandBarView: View {
    @ObservedObject var model: CommandBarModel
    @State private var selection: TextSelection?
    @State private var nav: SuggestionNav
    /// The last text put into the field by the history keys; any other change ends the walk.
    @State private var walked: String?
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 24

    init(model: CommandBarModel) {
        self.model = model
        let count = SlashCommands.suggestions(for: model.text, in: model.commands).count
        _nav = State(initialValue: SuggestionNav(count: model.menuOpen ? 0 : count, index: model.previewRow))
    }

    private var suggestions: [SlashCommand] {
        model.menuOpen ? [] : SlashCommands.suggestions(for: model.text, in: model.commands, limit: 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    chip
                    field
                }
                statusLine
                if model.menuOpen {
                    TargetMenuList(entries: model.entries, selected: model.target, onPick: { model.pick($0) },
                                   onNewConversation: model.onNewConversation)
                } else if nav.isOpen {
                    SlashSuggestionList(items: suggestions, selected: nav.index, rowHeight: Self.rowHeight,
                                        onHover: { nav.select($0) }, onPick: accept)
                        .padding(.top, 2).padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(width: CommandBarLogic.barWidth, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Brand.radiusXl, style: .continuous).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusXl, style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Brand.radiusXl, style: .continuous))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { model.onHeight($0) }
            .background(shortcuts)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.text) { _, t in
            if t != walked { model.app?.commandHistory.stopWalking(); walked = nil }
            if model.status?.isError == true { model.status = nil }
            nav.reset(count: suggestions.count)
        }
        .onChange(of: model.commands) { _, _ in nav.reset(count: suggestions.count) }
        .onChange(of: model.menuOpen) { _, _ in nav.reset(count: suggestions.count) }
        .onChange(of: model.focusTick) { _, _ in takeKeyboard() }
        .onAppear { takeKeyboard() }
    }

    // MARK: Parts

    private var chip: some View {
        Button { model.menuOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: CommandBarSymbol.name(for: model.target)).font(.system(size: 11, weight: .medium))
                Text(model.targetTitle).font(Brand.body(12, .medium)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(Brand.accentText)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .frame(maxWidth: 170)
            .fixedSize(horizontal: true, vertical: false)
            .background(Capsule().fill(Brand.accentSoft))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Where this goes (⌘1–⌘9)")
        .accessibilityLabel("Target: \(model.targetTitle)")
    }

    private var field: some View {
        TextField(model.placeholder, text: $model.text, selection: $selection, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Brand.body(16))
            .foregroundStyle(Brand.ink)
            .lineLimit(1...4)
            .focused($focused)
            .frame(minHeight: 26, alignment: .topLeading)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    insertNewline()
                } else if press.modifiers.contains(.command) {
                    model.onSubmit(true)
                } else if let c = nav.selected(in: suggestions) {
                    accept(c)
                } else {
                    model.onSubmit(false)
                }
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { _ in
                guard let c = nav.selected(in: suggestions) else { return .ignored }
                accept(c)
                return .handled
            }
            .onKeyPress(.upArrow, phases: .down) { _ in arrow(-1) }
            .onKeyPress(.downArrow, phases: .down) { _ in arrow(1) }
            .onKeyPress(.escape, phases: .down) { _ in
                if model.menuOpen { model.menuOpen = false; return .handled }
                if nav.isOpen { nav.dismiss(); return .handled }
                model.onClose()
                return .handled
            }
    }

    private var statusLine: some View {
        let s = model.statusText
        return HStack(spacing: 5) {
            if s.isError { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)) }
            Text(s.text).font(Brand.body(11)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(s.isError ? Brand.warning : Brand.inkSubtle)
        .padding(.leading, 2)
    }

    /// Hidden buttons give ⌘1…⌘9 (a target) and ⌘N (a new conversation) while the bar has the keyboard.
    private var shortcuts: some View {
        ZStack {
            ForEach(1...CommandBarLogic.maxShortcuts, id: \.self) { d in
                Button("") {
                    if let i = CommandBarLogic.entryIndex(forShortcut: d, count: model.entries.count) { model.pick(model.entries[i].target) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(d)")), modifiers: .command)
            }
            Button("") { model.onNewConversation() }.keyboardShortcut("n", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0).frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Focus puts the caret after the draft instead of selecting all of it.
    private func takeKeyboard() {
        focused = true
        // After the field has taken the focus, which selects its whole text.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            selection = TextSelection(insertionPoint: model.text.endIndex)
        }
    }

    // MARK: Keys

    /// Up / Down: the suggestion list when it is open, otherwise the history (empty field only).
    private func arrow(_ delta: Int) -> KeyPress.Result {
        if nav.isOpen {
            nav.move(delta)
            return .handled
        }
        guard let app = model.app, app.commandHistory.canWalk(fieldIsEmpty: model.text.isEmpty) else { return .ignored }
        let next = delta < 0 ? app.commandHistory.up() : app.commandHistory.down()
        guard let next else { return .ignored }
        walked = next
        model.text = next
        selection = TextSelection(insertionPoint: model.text.endIndex)
        return .handled
    }

    private func accept(_ c: SlashCommand) {
        model.text = SuggestionNav.accepted(c)
        selection = TextSelection(insertionPoint: model.text.endIndex)
        focused = true
    }

    /// Shift-Return: a newline at the caret instead of at the end.
    private func insertNewline() {
        var range: Range<Int>?
        let text = model.text
        if let sel = selection, case .selection(let r) = sel.indices,
           r.lowerBound <= text.endIndex, r.upperBound <= text.endIndex {
            range = text.distance(from: text.startIndex, to: r.lowerBound)..<text.distance(from: text.startIndex, to: r.upperBound)
        }
        let edit = InputEdit.insertNewline(in: text, selection: range)
        model.text = edit.text
        selection = TextSelection(insertionPoint: model.text.index(model.text.startIndex, offsetBy: edit.caret))
    }
}

// MARK: - Target list

/// The target choices under the chip: every entry with its ⌘ number, then "New conversation".
struct TargetMenuList: View {
    let entries: [CommandBarEntry]
    let selected: CommandBarTarget
    var onPick: (CommandBarTarget) -> Void = { _ in }
    var onNewConversation: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                TargetRow(symbol: CommandBarSymbol.name(for: e.target), title: e.title,
                          shortcut: CommandBarLogic.shortcutDigit(forIndex: i).map { "⌘\($0)" },
                          isSelected: e.target == selected) { onPick(e.target) }
            }
            Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 3)
            TargetRow(symbol: "arrow.counterclockwise", title: "New conversation", shortcut: "⌘N", isSelected: false,
                      action: onNewConversation)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Brand.radiusLg, style: .continuous).fill(Brand.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg, style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
        .padding(.top, 2).padding(.bottom, 4)
    }
}

private struct TargetRow: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).frame(width: 16).foregroundStyle(Brand.inkMuted)
                Text(title).font(Brand.body(13, isSelected ? .medium : .regular)).foregroundStyle(Brand.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if isSelected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.accentText) }
                if let shortcut { Text(shortcut).font(Brand.mono(11)).foregroundStyle(Brand.inkSubtle) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(hover ? Brand.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Queued message row (session card)

/// A message waiting for the end of the turn, with a way to cancel it.
struct QueuedMessageRow: View {
    let text: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Queued: \(text)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", action: cancel).controlSize(.small).fixedSize()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Settings section

/// Hotkey, history switch and "Clear command history" in the control panel.
struct CommandBarSettingsSection: View {
    let index: Int
    @ObservedObject var settings: Settings
    /// The system refused the registration: another app holds the combination.
    let taken: Bool
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: index, title: "Command bar")
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("Hotkey").font(Brand.body(13)).foregroundStyle(Brand.ink)
                        Spacer(minLength: 8)
                        Picker("", selection: $settings.commandBarHotKey) {
                            ForEach(CommandBarHotKey.options) { Text($0.label).tag($0.id) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    .padding(.top, 8)
                    if taken && !CommandBarHotKey.option(id: settings.commandBarHotKey).isOff {
                        Label(CommandBarHotKey.takenMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Brand.body(11, .medium)).foregroundStyle(Brand.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Press it anywhere to type a command").font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                    }
                    Divider().overlay(Brand.line).padding(.top, 2)
                    BrandToggleRow(title: "Keep command history", hint: "Last 20, stored only on this Mac", isOn: $settings.commandBarHistory)
                    HStack {
                        Spacer()
                        GhostButton(title: "Clear command history", symbol: "trash", action: clear)
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }
}
