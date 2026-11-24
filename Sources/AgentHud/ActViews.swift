import AgentHudCore
import AppKit
import SwiftUI

// An agent asks to act in another app: the request card, the hand on the session's icon, and the settings.
// Nothing is pressed, clicked or typed before one of the "Allow" buttons is clicked.

// MARK: - Request card

struct ActRequestView: View {
    @ObservedObject var model: AppModel
    let act: ActPending

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left.fill").foregroundStyle(act.risky ? Color.red : Color.orange)
                Text(act.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                LookCountdown(deadline: act.deadline)
            }
            target
            if let text = act.typedText, let note = act.typeNote { typed(text, note: note) }
            if act.risky {
                Label(ActLabels.riskyNote, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No keyboard shortcut on purpose: an action is allowed only by a click on the button.
            HStack(spacing: 8) {
                BigButton(title: "Allow once", symbol: "checkmark", prominent: !act.risky) { model.decideAct(act.id, .once) }
                    .help("Allow this one action")
                BigButton(title: "Deny", symbol: "xmark", role: .destructive) { model.decideAct(act.id, .deny) }
                    .help("The agent is told that you did not allow this")
            }
            if act.offersApp {
                BigButton(title: ActLabels.allowInApp(act.subject.app), symbol: "checkmark.circle") { model.decideAct(act.id, .app) }
                    .help("This session may act in \(act.subject.app) without asking again until it ends. Risky key combinations still ask.")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(act.risky ? Color.red.opacity(0.14) : Color.orange.opacity(0.09)))
    }

    /// Where and what: the app and window, then the element, the point, the keys or the scroll.
    private var target: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                Text(verbatim: act.targetLine)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let detail = act.detail {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: ActLabels.symbol(act.call.kind)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                    Text(verbatim: detail)
                        .font(act.call.kind == .pressKeys ? .system(size: 17, weight: .semibold, design: .rounded)
                                                          : .system(size: 12, weight: .semibold))
                        .lineLimit(3).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }

    /// The whole text, never cut: a long one scrolls inside the box.
    private func typed(_ text: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: Self.boxHeight(text))
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            Label(note, systemImage: "keyboard").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// As tall as the text needs, up to a limit that leaves the buttons on the card.
    static func boxHeight(_ text: String) -> CGFloat {
        let perLine = 46
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
        return min(CGFloat(lines) * 14 + 18, 132)
    }
}

// MARK: - Icon badge and notices

/// On a session's icon while an action is being decided or carried out.
struct ActBadge: View {
    var body: some View {
        Image(systemName: "hand.point.up.left.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.orange))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .help("An agent wants to act in an app, or is acting right now")
    }
}

/// An action was refused because the Accessibility permission is missing. Nothing is requested from here.
struct ActBlockedNotice: View {
    @ObservedObject var model: AppModel
    let sessionKey: String

    var body: some View {
        Notice(icon: "hand.raised.slash", color: .orange,
               text: "The agent tried to act in an app, but Agent HUD has no \(Permissions.info(.accessibility).title) permission. It was refused.",
               actions: [("Set up…", { model.openSetup(.accessibility) }), ("Dismiss", { model.dismissActBlocked(sessionKey) })])
    }
}

// MARK: - Settings (control panel)

/// "Agents may act": the mode, the stop switch and the apps that are never acted in.
/// Values come in as plain values and bindings, so the render check can show any state.
struct HandsAccessSection: View {
    let index: Int
    @Binding var mode: HandsAccessMode
    /// Set while agent actions are off because the stop switch was used.
    var stoppedAt: Date?
    var alwaysExcluded: [String] = ActExclusions.always(ownBundleId: AppModel.ownBundleId)
    /// App name for a bundle id; nil when no such app is installed.
    var appName: (String) -> String? = ScreenAccessSection.installedName
    var stop: () -> Void = {}

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Names for the entries that are not apps one would find in the Applications folder.
    private static let builtInNames = ["com.apple.loginwindow": "the login window", "com.apple.securityagent": "system password prompts"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: index, title: "Agent actions")
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    if let stoppedAt, mode == .off {
                        Label(ActLabels.stoppedNotice(at: Self.time.string(from: stoppedAt)), systemImage: "hand.raised.fill")
                            .font(Brand.body(12, .medium)).foregroundStyle(Brand.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(Brand.dangerSoft))
                            .padding(.top, 10)
                    }
                    FieldLabel(title: "Agents may act").padding(.top, stoppedAt != nil && mode == .off ? 4 : 10)
                    BrandSegmented(options: HandsAccessMode.allCases.map { ($0, $0.title) }, selection: $mode)
                    ForEach(HandsAccessMode.allCases, id: \.self) { m in
                        Text(m.hint).font(Brand.body(11)).foregroundStyle(m == mode ? Brand.ink : Brand.inkSubtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Press, click, type, press keys, scroll, bring a window forward, open an app. Never in a password field.")
                        .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(Brand.line).padding(.vertical, 4)
                    HStack(alignment: .center, spacing: 8) {
                        GhostButton(title: ActLabels.stopTitle, symbol: "hand.raised.fill", tone: Brand.danger, action: stop)
                            .fixedSize()
                            .disabled(mode == .off)
                            .opacity(mode == .off ? 0.4 : 1)
                            .help("Turns agent actions off, refuses everything that waits and forgets every \"allow in this app\" answer")
                            .padding(.leading, -10)
                        Spacer(minLength: 4)
                        // The same switch from the keyboard, whatever app is in front.
                        Text("\(ActLabels.stopHotKey) anywhere").font(Brand.body(11)).foregroundStyle(Brand.inkSubtle).lineLimit(1)
                    }
                    Divider().overlay(Brand.line).padding(.vertical, 4)
                    FieldLabel(title: "Never acted in", hint: "cannot be changed")
                    Text(verbatim: excludedLine)
                        .font(Brand.body(11)).foregroundStyle(Brand.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var excludedLine: String {
        let own = AppModel.ownBundleId.lowercased()
        // An app that is not installed is listed by its id: the entry is in force all the same.
        let names = alwaysExcluded.map { id -> String in
            if id.lowercased() == own { return HostInfo.agentHudName }
            return Self.builtInNames[id.lowercased()] ?? appName(id) ?? id
        }
        return names.joined(separator: ", ") + ", and every app in \"Never shown to agents\" above."
    }
}
