import AgentHudCore
import SwiftUI

/// Panel actions - performed by StatusMenu (closes the popover, shows dialogs).
struct PanelActions {
    var openSession: (String) -> Void = { _ in }
    var focusSession: (String) -> Void = { _ in }
    var connect: (AgentKind) -> Void = { _ in }
    var disconnect: (AgentKind) -> Void = { _ in }
    var setTimeout: (Int) -> Void = { _ in }
    var setLoginItem: (Bool) -> Void = { _ in }
    var resetPosition: () -> Void = {}
    var openLog: () -> Void = {}
    var openMap: () -> Void = {}
    var openSetup: () -> Void = {}
    var newSession: () -> Void = {}
    var openCommandBar: () -> Void = {}
    var clearCommandHistory: () -> Void = {}
    var continueSession: () -> Void = {}
    var openSummary: () -> Void = {}
    var openReport: () -> Void = {}
    var quickReport: () -> Void = {}
    var stopActions: () -> Void = {}
    var routines = RoutinesActions()
    var quit: () -> Void = {}
}

/// Menu bar panel: sessions, agents, appearance, behavior. The palette is in Brand.swift.
struct ControlPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    var actions = PanelActions()
    /// Statuses that don't publish themselves (config files, launch at login) - read on open.
    var installed: [AgentKind: Bool] = [:]
    /// Which agents are present on the machine: the others are not shown in the panel.
    var present: [AgentKind: Bool] = [:]
    var loginItem = false
    /// Permission summary; nil until the first check finishes.
    var permissions: Permissions.Summary?
    @State var tab = 0
    @State private var quickText = ""

    static let width: CGFloat = 340
    /// Room for the "Screen" tab's sections; the default leaves the header, the tabs and the footer on a laptop screen.
    var screenTabLimit: CGFloat = max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 240)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            BrandTabs(titles: ["Sessions", "Settings", "Screen", "Routines"], selection: $tab,
                      badges: [0: model.visibleSessions.filter { $0.state.needsUser }.count])
            if tab == 0 {
                PanelButton(title: CommandBarHotKey.menuTitle(id: settings.commandBarHotKey), symbol: "command.square",
                            action: actions.openCommandBar)
                HStack(spacing: 8) {
                    PanelButton(title: "New session…", symbol: "plus.bubble", action: actions.newSession)
                    PanelButton(title: "Continue a session…", symbol: "clock.arrow.circlepath", action: actions.continueSession)
                }
                HStack(spacing: 8) {
                    PanelButton(title: "Agent map", symbol: "map", action: actions.openMap)
                    PanelButton(title: "Daily summary", symbol: "list.bullet.rectangle", action: actions.openSummary)
                }
                HStack(spacing: 8) {
                    PanelButton(title: "Period report", symbol: "calendar", action: actions.openReport)
                    PanelButton(title: "Since 15:00 yesterday", symbol: "clock.arrow.circlepath", action: actions.quickReport)
                }
                sessionsSection
                agentsSection
            } else if tab == 1 {
                // Three sections no longer fit a laptop screen: they scroll when the tab is taller than the screen allows.
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        lookSection
                        behaviorSection
                        CommandBarSettingsSection(index: 3, settings: settings, taken: model.commandBarHotKeyTaken,
                                                  clear: actions.clearCommandHistory)
                        VoiceSettingsSection(index: 4, enabled: $settings.voiceEnabled, language: $settings.voiceLanguage,
                                             sendAfterSpeaking: $settings.voiceSendAfterSpeaking, speakReplies: $settings.voiceSpeakReplies,
                                             allowServer: $settings.voiceAllowServerRecognition)
                    }
                }
                .frame(maxHeight: screenTabLimit)
                .fixedSize(horizontal: false, vertical: true)
            } else if tab == 3 {
                // Many routines do not fit a laptop screen: the list scrolls.
                ScrollView {
                    RoutinesTab(controller: model.routines, settings: settings, actions: actions.routines)
                }
                .frame(maxHeight: screenTabLimit)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                // Its own tab: with the list of excluded apps the settings would not fit a laptop screen.
                // The two sections scroll when even this tab is taller than the screen allows.
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ScreenAccessSection(index: 1, mode: $settings.screenAccess, excluded: $settings.screenExcludedApps)
                        HandsAccessSection(index: 2, mode: $settings.handsAccess, stoppedAt: settings.handsStoppedAt,
                                           stop: actions.stopActions)
                    }
                }
                .frame(maxHeight: screenTabLimit)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: Self.width)
        .background(Brand.bg)
    }

    // MARK: Header

    private var header: some View {
        let sessions = model.visibleSessions
        let waiting = sessions.filter { $0.state.needsUser }.count
        return HStack(spacing: 12) {
            if settings.avatarStyle == .logo {
                AgentIconStack(size: 34)
            } else {
                AvatarView(seed: 0x9E3779B97F4A7C15, state: waiting > 0 ? .waitingPermission : .working,
                           style: settings.avatarStyle, size: 36, animated: settings.animations)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent HUD").font(Brand.display(24)).foregroundStyle(Brand.ink)
                Text(summary(total: sessions.count, waiting: waiting))
                    .font(Brand.mono(10.5, medium: true)).tracking(0.63)
                    .foregroundStyle(waiting > 0 ? Brand.warning : Brand.inkSubtle)
            }
            Spacer()
        }
    }

    private func summary(total: Int, waiting: Int) -> String {
        if total == 0 { return "NO ACTIVE SESSIONS" }
        let s = "\(total) \(DailySummary.plural(total, "SESSION", "SESSIONS"))"
        return waiting > 0 ? s + " · \(waiting) WAITING" : s
    }

    // MARK: 01 Sessions

    private var sessionsSection: some View {
        let sessions = model.visibleSessions.sorted { a, b in
            let pa = a.state.needsUser ? 0 : 1, pb = b.state.needsUser ? 0 : 1
            return pa != pb ? pa < pb : a.lastEventAt > b.lastEventAt
        }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 1, title: "Sessions")
            Card {
                if sessions.isEmpty {
                    Text("All quiet for now. Start an agent in VS Code, the terminal or the app - it will appear here. Or start one right here with \"New session…\".")
                        .font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 12)
                } else {
                    let rows = VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                            SessionRow(session: s, style: settings.avatarStyle,
                                       open: { actions.openSession(s.id) }, focus: { actions.focusSession(s.id) })
                        }
                    }
                    if sessions.count > 5 {
                        ScrollView { rows }.frame(height: 5 * 49)
                    } else {
                        rows
                    }
                }
            }
        }
    }

    // MARK: 02 Agents

    private var agentsSection: some View {
        // An agent without its own settings folder on the machine is not installed - we don't offer to connect it.
        let kinds = AgentKind.allCases.filter { present[$0] ?? true || installed[$0] ?? false }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 2, title: "Agents")
            Card {
                ForEach(Array(kinds.enumerated()), id: \.element) { i, kind in
                    if i > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                    AgentRow(kind: kind, installed: installed[kind] ?? false,
                             toggle: { on in on ? actions.connect(kind) : actions.disconnect(kind) })
                }
            }
        }
    }

    // MARK: 03 Appearance

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 1, title: "Appearance")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(AvatarStyle.allCases) { style in
                            StyleTile(style: style, selected: settings.avatarStyle == style) { settings.avatarStyle = style }
                        }
                    }
                    .padding(.top, 12)
                    Divider().overlay(Brand.line)
                    BrandToggleRow(title: "Show HUD", isOn: $settings.hudVisible)
                    BrandToggleRow(title: "Animate characters", isOn: $settings.animations)
                    BrandToggleRow(title: "Hide when nobody is waiting",
                                   hint: "The HUD appears only on a request or a question", isOn: $settings.hideWhenNothingWaits)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: 04 Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 2, title: "Behavior")
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    BrandToggleRow(title: "Open window on request", isOn: $settings.openCardOnRequest)
                        .padding(.top, 6)
                    BrandToggleRow(title: "Notify if HUD is hidden", isOn: $settings.notifications)
                    BrandToggleRow(title: "Launch at login",
                                   isOn: Binding(get: { loginItem }, set: { actions.setLoginItem($0) }))
                    BrandToggleRow(title: "Activity log", hint: "For the daily summary; stored only on this Mac",
                                   isOn: $settings.activityLog)
                    permissionsRow
                    Divider().overlay(Brand.line).padding(.vertical, 4)
                    FieldLabel(title: "Time to answer", hint: "then it goes to the agent")
                    BrandSegmented(options: [(120, "2 MIN"), (300, "5 MIN"), (600, "10 MIN"), (1800, "30 MIN")],
                                   selection: Binding(get: { settings.hookTimeout }, set: { actions.setTimeout($0) }))
                    FieldLabel(title: "Hide finished sessions").padding(.top, 8)
                    BrandSegmented(options: [(0, "NEVER"), (5, "5 MIN"), (30, "30 MIN"), (120, "2 H")],
                                   selection: $settings.autoHideDoneMinutes)
                    FieldLabel(title: "Quick prompts", hint: "for VS Code, separated by ;").padding(.top, 8)
                    TextField("Continue; Run the tests", text: $quickText)
                        .textFieldStyle(.roundedBorder)
                        .font(Brand.body(12))
                        .onAppear { quickText = settings.quickPrompts.joined(separator: "; ") }
                        .onSubmit(commitQuickPrompts)
                        .onDisappear(perform: commitQuickPrompts)
                        .padding(.bottom, 8)
                    Divider().overlay(Brand.line)
                    redFlagsRow.padding(.bottom, 6)
                }
            }
        }
    }

    /// Permissions: the setup window button and, when something needed now is missing, what is off because of it.
    private var permissionsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            if let first = permissions?.missingNow.first {
                Text("Limited: \(first.limitedWithout)")
                    .font(Brand.body(11)).foregroundStyle(Brand.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Permissions").font(Brand.body(13)).foregroundStyle(Brand.ink)
            }
            Spacer(minLength: 4)
            GhostButton(title: "Permissions…", symbol: "checkmark.shield", action: actions.openSetup)
        }
        .padding(.bottom, 2)
    }

    /// Red flags: how many rules are active, whether the file has problems, a button to open the file.
    private var redFlagsRow: some View {
        let set = RedFlags.load()
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Red flags").font(Brand.body(13)).foregroundStyle(Brand.ink)
                Text("rules: \(set.rules.count)").font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                if !set.problems.isEmpty {
                    Label("problems: \(set.problems.count)", systemImage: "exclamationmark.triangle.fill")
                        .font(Brand.body(11, .medium)).foregroundStyle(Brand.danger)
                        .help(set.problems.joined(separator: "\n"))
                }
            }
            Spacer()
            GhostButton(title: "Open file", symbol: "doc.text", action: RedFlags.openFile)
        }
    }

    private func commitQuickPrompts() {
        let list = quickText.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if list != settings.quickPrompts { settings.quickPrompts = list }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            GhostButton(title: "Log", symbol: "doc.text", action: actions.openLog)
            GhostButton(title: "Reset HUD position", symbol: "arrow.up.right.square", action: actions.resetPosition)
            Spacer()
            GhostButton(title: "Quit", symbol: "power", action: actions.quit)
        }
        .padding(.horizontal, -10)
    }
}

// MARK: - Panel parts

/// Card: surface, line, 10px corner radius.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg).strokeBorder(Brand.line, lineWidth: 1))
    }
}

struct FieldLabel: View {
    let title: String
    var hint: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Brand.body(13)).foregroundStyle(Brand.ink)
            Spacer()
            if let hint { Text(hint).font(Brand.body(11)).foregroundStyle(Brand.inkSubtle) }
        }
    }
}

struct SessionRow: View {
    let session: AgentSession
    let style: AvatarStyle
    let open: () -> Void
    let focus: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(seed: session.avatarSeed, state: session.state, style: style, size: 28, animated: false, kind: session.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ProjectDot(cwd: session.cwd, size: 7)
                    Text(session.projectName).font(Brand.body(13, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                }
                Text(detail).font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if hover {
                Button(action: focus) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.inkMuted)
                .help(session.host.openTitle)
            }
            BrandTag(text: session.state.shortTitle, tone: session.state.tone)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(hover ? Brand.surfaceSunken : .clear))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }

    private var detail: String {
        var parts = ["\(session.kind.displayName) · \(session.host.label)"]
        if !session.title.isEmpty { parts.append(session.title) }
        return parts.joined(separator: " — ")
    }
}

struct AgentRow: View {
    let kind: AgentKind
    let installed: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            LogoAvatar(kind: kind, state: installed ? .working : .idle, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(Brand.body(13, .medium)).foregroundStyle(Brand.ink)
                Text(hint).font(Brand.body(11)).foregroundStyle(Brand.inkSubtle).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { installed }, set: toggle)).toggleStyle(BrandSwitch()).labelsHidden()
        }
        .padding(.vertical, 10)
    }

    private var hint: String {
        guard installed else { return "Not connected" }
        switch kind {
        case .claude: return "VS Code, terminal and the Claude app"
        }
    }
}

/// Panel tile button: "Agent map", "Daily summary".
struct PanelButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(Brand.body(12, .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .foregroundStyle(Brand.accentText)
            .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(hover ? Brand.accentSoft : Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusMd).strokeBorder(Brand.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct StyleTile: View {
    let style: AvatarStyle
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if style == .logo {
                    AgentIconStack(size: 30).frame(height: 34)
                } else {
                    AvatarView(seed: 0x51ED2701F3A5C7B9, state: .working, style: style, size: 34, animated: false)
                }
                Text(style.title).font(Brand.body(11, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Brand.accentText : Brand.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Brand.radiusMd)
                .fill(selected ? Brand.accentSoft : (hover ? Brand.surfaceSunken : .clear)))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusMd)
                .strokeBorder(selected ? Brand.accent : Brand.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension AgentState {
    var shortTitle: String {
        switch self {
        case .starting: return "starting"
        case .working: return "working"
        case .waitingPermission: return "needs you"
        case .expired: return "expired"
        case .idle: return "idle"
        case .done: return "done"
        case .error: return "error"
        case .ended: return "ended"
        case .paused: return "paused"
        case .stopped: return "stopped"
        }
    }

    var tone: BrandTag.Tone {
        switch self {
        case .waitingPermission, .expired, .paused, .stopped: return .warning
        case .done: return .success
        case .error: return .danger
        case .working, .starting: return .accent
        case .idle, .ended: return .neutral
        }
    }
}
