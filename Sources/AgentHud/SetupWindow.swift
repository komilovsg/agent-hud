import AgentHudCore
import AppKit
import SwiftUI

/// What the setup window shows. The real window fills it from `PermissionProbe`; the render check injects fake statuses.
@MainActor
final class SetupModel: ObservableObject {
    @Published var states: [PermissionKind: PermissionState]
    @Published var highlight: PermissionKind?
    /// Whether Claude Code has the screen tools server in its user configuration.
    @Published var screenTools: ScreenToolsState
    let showsSourceBuildNote: Bool

    init(states: [PermissionKind: PermissionState] = [:], showsSourceBuildNote: Bool = false,
         screenTools: ScreenToolsState = ScreenToolsState()) {
        self.states = states
        self.showsSourceBuildNote = showsSourceBuildNote
        self.screenTools = screenTools
    }

    func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? PermissionState(status: .unknown) }

    var summary: Permissions.Summary {
        Permissions.summary(states.mapValues(\.status))
    }
}

struct SetupActions {
    var request: (PermissionKind) -> Void = { _ in }
    var openSettings: (PermissionKind) -> Void = { _ in }
    var connectScreenTools: () -> Void = {}
    var disconnectScreenTools: () -> Void = {}
    var done: () -> Void = {}
}

/// The "Set up Agent HUD" window: a regular titled window. Nothing is requested when it opens;
/// statuses are read once a second while it is visible and when the app becomes active again.
@MainActor
final class SetupController: NSObject, NSWindowDelegate {
    private let settings: Settings
    private let model = SetupModel(showsSourceBuildNote: PermissionProbe.isAdHocBuild)
    private var window: NSWindow?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var refreshing = false

    init(settings: Settings) {
        self.settings = settings
        super.init()
    }

    var isShown: Bool { window?.isVisible ?? false }

    func show(highlight: PermissionKind? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SetupMetrics.width, height: SetupMetrics.height),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Set up Agent HUD"
            w.isReleasedWhenClosed = false
            let actions = SetupActions(
                request: { [weak self] kind in
                    guard let self else { return }
                    PermissionProbe.request(kind, hookTimeout: self.settings.hookTimeout)
                    self.refresh()
                },
                openSettings: { kind in PermissionProbe.openSettingsPane(kind) },
                connectScreenTools: { [weak self] in self?.changeScreenTools { await ScreenToolsSetup.connect() } },
                disconnectScreenTools: { [weak self] in self?.changeScreenTools { await ScreenToolsSetup.disconnect() } },
                done: { [weak self] in self?.window?.close() })
            w.contentView = NSHostingView(rootView: SetupView(model: model, actions: actions).tint(Brand.accent))
            w.delegate = self
            w.center()
            window = w
        }
        refresh()
        refreshScreenTools()
        startRefreshing()
        if let highlight {
            model.highlight = highlight
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.model.highlight == highlight { self?.model.highlight = nil }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { stopRefreshing() }

    private func startRefreshing() {
        stopRefreshing()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The user comes back from System Settings: show the new state at once.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopRefreshing() {
        timer?.invalidate()
        timer = nil
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        activeObserver = nil
    }

    /// Asks Claude Code once (when the window opens and after a change): the answer comes from a command, not a file read.
    private func refreshScreenTools() {
        guard !model.screenTools.busy else { return }
        Task { @MainActor in
            let next = await ScreenToolsSetup.status()
            if !model.screenTools.busy, next != model.screenTools { model.screenTools = next }
        }
    }

    /// Connect or disconnect: the command is shown first; while it runs the button is off.
    private func changeScreenTools(_ action: @escaping @MainActor () async -> String?) {
        guard !model.screenTools.busy else { return }
        Task { @MainActor in
            model.screenTools.busy = true
            let problem = await action()
            model.screenTools.busy = false
            if let problem { HookSetup.info("Screen tools were not changed", problem, style: .warning) }
            refreshScreenTools()
        }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            let next = await PermissionProbe.states()
            if next != model.states { model.states = next }
            refreshing = false
        }
    }
}

enum SetupMetrics {
    static let width: CGFloat = 560
    static let height: CGFloat = 750
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var actions = SetupActions()

    var body: some View {
        VStack(spacing: 0) {
            Text("Agent HUD works with whatever you allow. Anything you skip just stays off.")
                .font(Brand.body(14)).foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        group(index: 1, title: "Needed now", stage: .now)
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(index: 2, title: "Agents outside Agent HUD")
                            Card {
                                ScreenToolsRow(state: model.screenTools, connect: actions.connectScreenTools,
                                               disconnect: actions.disconnectScreenTools)
                            }
                        }
                        group(index: 3, title: "For what is coming", stage: .coming)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 16)
                }
                .onChange(of: model.highlight) { _, kind in
                    guard let kind else { return }
                    withAnimation { proxy.scrollTo(kind, anchor: .center) }
                }
            }
            Rectangle().fill(Brand.line).frame(height: 1)
            footer
        }
        .frame(width: SetupMetrics.width, height: SetupMetrics.height)
        .background(Brand.bg)
    }

    private func group(index: Int, title: String, stage: PermissionInfo.Stage) -> some View {
        let items = Permissions.all.filter { $0.stage == stage }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: index, title: title)
            Card {
                ForEach(Array(items.enumerated()), id: \.element.kind) { i, info in
                    if i > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                    PermissionRow(info: info, state: model.state(info.kind), highlighted: model.highlight == info.kind,
                                  allow: { actions.request(info.kind) }, openSettings: { actions.openSettings(info.kind) })
                        .id(info.kind)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                Text(model.summary.headline)
                    .font(Brand.body(12, .medium))
                    .foregroundStyle(model.summary.isLimited ? Brand.warning : Brand.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                SetupButton(title: "Done", primary: true, action: actions.done)
            }
            if model.showsSourceBuildNote {
                Text("Built from source: macOS forgets these permissions after each rebuild.")
                    .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }
}

struct PermissionRow: View {
    let info: PermissionInfo
    let state: PermissionState
    let highlighted: Bool
    let allow: () -> Void
    let openSettings: () -> Void

    private var quiet: Bool { info.stage == .coming }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(quiet ? Brand.inkSubtle : Brand.accentText)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(quiet ? Brand.surfaceSunken : Brand.accentSoft))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(info.title).font(Brand.body(13, .medium)).foregroundStyle(quiet ? Brand.inkMuted : Brand.ink)
                    BrandTag(text: pillText, tone: pillTone)
                    if quiet { BrandTag(text: "Not used yet", tone: .neutral) }
                }
                Text(info.usedFor).font(Brand.body(12)).foregroundStyle(quiet ? Brand.inkSubtle : Brand.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = state.detail {
                    Text(detail).font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                // Automation can be asked even while its state is unknown: asking is what makes macOS list the app.
                if state.status == .notGranted || (state.status == .unknown && info.kind == .automation) {
                    SetupButton(title: allowTitle, primary: true, action: allow)
                }
                if state.status != .granted, info.kind != .hooks { SetupButton(title: "Open Settings", primary: false, action: openSettings) }
            }
        }
        .padding(.vertical, 12)
        .background(highlighted ? RoundedRectangle(cornerRadius: Brand.radiusMd).fill(Brand.accentSoft).padding(.horizontal, -6) : nil)
    }

    private var allowTitle: String {
        guard info.kind == .hooks else { return "Allow…" }
        return state.detail == "Needs an update" ? "Update…" : "Connect…"
    }

    private var pillText: String {
        switch state.status {
        case .granted: return "Granted"
        case .notGranted: return "Not granted"
        case .unknown: return "Check"
        }
    }

    private var pillTone: BrandTag.Tone {
        switch state.status {
        case .granted: return .success
        case .notGranted: return .warning
        case .unknown: return .neutral
        }
    }

    private var symbol: String {
        switch info.kind {
        case .hooks: return "link"
        case .accessibility: return "accessibility"
        case .automation: return "terminal"
        case .notifications: return "bell"
        case .screenRecording: return "record.circle"
        case .fullDiskAccess: return "internaldrive"
        }
    }
}

/// Setup window button: filled (primary) or outlined (secondary).
struct SetupButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Brand.body(12, .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(primary ? Brand.onAccent : Brand.accentText)
                .background(RoundedRectangle(cornerRadius: Brand.radiusMd)
                    .fill(primary ? (hover ? Brand.accentHover : Brand.accent) : (hover ? Brand.accentSoft : Brand.surface)))
                .overlay(RoundedRectangle(cornerRadius: Brand.radiusMd).strokeBorder(primary ? Color.clear : Brand.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
