import AgentHudCore
import AppKit
import ApplicationServices

/// Sends the card's message to a session. The editor extension ignores the prompt of its session link when the session
/// is already open, so the text is typed through the host app instead: bring the session forward, paste, press Return.
/// Without the Accessibility permission (or with the setting off) the text is copied and the session is opened.
@MainActor
final class PromptSender {
    enum Outcome: Equatable {
        case sent
        case copied
        case failed(String)
    }

    static let lostFocusMessage = "The editor lost focus — nothing was sent"

    private let settings: Settings
    private var permissionPromptShown = false
    /// Called once when typing is on but Accessibility is missing: the app opens its setup window.
    var onNeedAccessibility: (() -> Void)?
    private var busy = false

    init(settings: Settings) { self.settings = settings }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Send

    /// `owned`: the session's process belongs to this app - the text goes straight to it, nothing is typed anywhere.
    func send(_ text: String, to session: AgentSession, owned: OwnedSession? = nil) async -> Outcome {
        if let owned {
            guard owned.isLive else { return .failed(OwnedSession.goneMessage) }
            return owned.send(text) ? .sent : .failed(OwnedSession.busyMessage)
        }
        // Switched off: no key is posted and the pasteboard is not touched.
        guard Features.typeIntoHost else { return .failed("Sending to this session is switched off") }
        guard !busy else { return .failed("Another message is still being sent") }
        busy = true
        defer { busy = false }
        let kind = SendHostKind(host: session.host)
        guard kind.canCompose else { return .failed("This session can't be reached from the card") }

        let typingOn = settings.sendByTyping
        if typingOn, !Self.isTrusted { showPermissionPromptOnce() }
        let trusted = Self.isTrusted
        let previous = NSWorkspace.shared.frontmostApplication

        let target: String
        var confirmed = false
        switch kind {
        case .editor:
            target = session.host.appBundleId ?? HostInfo.vscode
            if !SendPlan.expectedMode(trusted: trusted, typingEnabled: typingOn, hostKind: kind).isType {
                putOnPasteboard(text)
                await bringEditorForward(session)
                return .copied
            }
            await bringEditorForward(session)
        case .terminal:
            guard let bundle = TerminalFocus.terminalBundleId(session.host) else { return .failed("This session can't be reached from the card") }
            target = bundle
            confirmed = TerminalFocus.focus(session.host)
            if SendPlan.mode(trusted: trusted, typingEnabled: typingOn, hostKind: kind, focusConfirmed: confirmed) != .type {
                putOnPasteboard(text)
                return .copied
            }
        case .unsupported:
            return .failed("This session can't be reached from the card")
        }

        guard await waitUntilFrontmost(target, timeout: .milliseconds(2500)) else {
            putOnPasteboard(text)
            return .copied
        }
        // The panel needs a moment to take keyboard focus after the app comes forward.
        try? await Task.sleep(for: .milliseconds(400))

        let saved = snapshotPasteboard()
        putOnPasteboard(text, transient: true)
        guard postKeyIfFront(target, key: Key.v, flags: .maskCommand) else {
            restorePasteboard(saved)
            return .failed(Self.lostFocusMessage)
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard postKeyIfFront(target, key: Key.returnKey, flags: []) else {
            restorePasteboard(saved)
            return .failed(Self.lostFocusMessage)
        }
        try? await Task.sleep(for: .milliseconds(400))
        restorePasteboard(saved)

        if let previous, previous.bundleIdentifier != target, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let url = previous.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        return .sent
    }

    // MARK: - Focus

    private func bringEditorForward(_ session: AgentSession) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            TerminalFocus.focusEditor(session, withLink: false) { c.resume() }
        }
    }

    private func isFrontmost(_ bundleId: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
    }

    private func waitUntilFrontmost(_ bundleId: String, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if isFrontmost(bundleId) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isFrontmost(bundleId)
    }

    // MARK: - Key events (the only place that posts them)

    private enum Key {
        static let v: CGKeyCode = 9
        static let returnKey: CGKeyCode = 36
    }

    /// Posts a key press only while `bundleId` is the frontmost app, so nothing is ever typed into an unknown app.
    private func postKeyIfFront(_ bundleId: String, key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard isFrontmost(bundleId) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Pasteboard

    private typealias PasteboardSnapshot = [[(type: NSPasteboard.PasteboardType, data: Data)]]

    private func snapshotPasteboard() -> PasteboardSnapshot {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    private func restorePasteboard(_ saved: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for e in entries { item.setData(e.data, forType: e.type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// `transient`: clipboard managers skip the entry (it is put back right after the paste).
    private func putOnPasteboard(_ text: String, transient: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient { item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
        pb.writeObjects([item])
    }

    // MARK: - Permission

    private func showPermissionPromptOnce() {
        guard !permissionPromptShown else { return }
        permissionPromptShown = true
        onNeedAccessibility?()
    }
}

private extension SendMode {
    var isType: Bool { self == .type }
}
