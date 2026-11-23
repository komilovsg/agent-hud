import Foundation

/// Where a typed message can go from the card.
public enum SendHostKind: Equatable, Sendable {
    /// The Claude Code panel of an editor.
    case editor
    /// A terminal whose tab or window can be selected and the selection confirmed (Terminal, iTerm).
    case terminal
    /// No safe way to land in the right input: the card shows "reply there" instead of a field.
    case unsupported

    public init(host: HostInfo) {
        if host.isEditor {
            self = .editor
        } else if !host.isEditorTerminal, !host.isDesktopApp, host.tty != nil, host.herdrPaneId == nil,
                  host.termProgram == "Apple_Terminal" || host.termProgram == "iTerm.app" {
            self = .terminal
        } else {
            self = .unsupported
        }
    }

    public var canCompose: Bool { self != .unsupported }
}

public enum SendMode: Equatable, Sendable {
    /// Paste into the target app and press Return.
    case type
    /// Put the text on the pasteboard and open the session.
    case copy
}

/// Decides how a message leaves the card and what the card says about it.
public enum SendPlan {
    /// `focusConfirmed`: the session's tab or window was really selected (only terminals need it; editors are
    /// protected by the frontmost-app check while typing).
    public static func mode(trusted: Bool, typingEnabled: Bool, hostKind: SendHostKind, focusConfirmed: Bool) -> SendMode {
        guard trusted, typingEnabled else { return .copy }
        switch hostKind {
        case .editor: return .type
        case .terminal: return focusConfirmed ? .type : .copy
        case .unsupported: return .copy
        }
    }

    /// The mode shown before sending: a terminal is assumed to confirm its focus.
    public static func expectedMode(trusted: Bool, typingEnabled: Bool, hostKind: SendHostKind) -> SendMode {
        mode(trusted: trusted, typingEnabled: typingEnabled, hostKind: hostKind, focusConfirmed: true)
    }

    public static func helperLine(mode: SendMode, hostLabel: String) -> String {
        switch mode {
        case .type: return "Sends to the session in \(hostLabel)"
        case .copy: return "Copies the text and opens the session in \(hostLabel) — paste with ⌘V"
        }
    }

    public static let sentNote = "Sent"
    public static let copiedNote = "Copied — press ⌘V in the session"
    public static let sentNoteSeconds: Double = 2
    public static let copiedNoteSeconds: Double = 6
}

/// Keyboard state of the slash-command suggestion list.
public struct SuggestionNav: Equatable, Sendable {
    public private(set) var count: Int
    public private(set) var index: Int
    public private(set) var dismissed: Bool

    public init(count: Int = 0, index: Int = 0, dismissed: Bool = false) {
        self.count = max(0, count)
        self.index = self.count == 0 ? 0 : min(max(0, index), self.count - 1)
        self.dismissed = dismissed
    }

    public var isOpen: Bool { count > 0 && !dismissed }

    /// The text or the command list changed: the list reopens with the first row selected.
    public mutating func reset(count: Int) {
        self = SuggestionNav(count: count)
    }

    /// Up / Down; wraps around at both ends.
    public mutating func move(_ delta: Int) {
        guard isOpen else { return }
        index = ((index + delta) % count + count) % count
    }

    /// Pointer hover: the row under the pointer becomes the selected one.
    public mutating func select(_ row: Int) {
        guard isOpen, (0..<count).contains(row) else { return }
        index = row
    }

    /// Esc: closes the list, the text stays.
    public mutating func dismiss() { dismissed = true }

    /// Tab / Return / click: the chosen row, or nil when the list is closed.
    public func selected<T>(in items: [T]) -> T? {
        guard isOpen, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// The text that replaces the field when a command is accepted.
    public static func accepted(_ command: SlashCommand) -> String { "/\(command.name) " }
}

/// Plain text edits for the message field.
public enum InputEdit {
    /// Shift-Return: a newline at the caret (or in place of the selection). Offsets count characters.
    /// Returns the new text and the caret offset right after the newline.
    public static func insertNewline(in text: String, selection: Range<Int>?) -> (text: String, caret: Int) {
        let chars = Array(text)
        let lo = min(max(0, selection?.lowerBound ?? chars.count), chars.count)
        let hi = min(max(lo, selection?.upperBound ?? chars.count), chars.count)
        let out = String(chars[..<lo]) + "\n" + String(chars[hi...])
        return (out, lo + 1)
    }
}
