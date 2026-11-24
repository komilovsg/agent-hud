import AgentHudCore
import AppKit
import SwiftUI

// An agent asks to look at the screen: the request card, the eye on the session's icon, the "Looked at" rows,
// and the settings. Looking is read-only, and nothing is looked at before one of the "Allow" buttons is clicked.

// MARK: - Request card

struct LookRequestView: View {
    @ObservedObject var model: AppModel
    let look: LookPending

    /// "Per session" mode puts the lasting answer first; otherwise the one-time answer leads.
    private var sessionFirst: Bool { look.offersSession && model.settings.screenAccess == .session }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill").foregroundStyle(.orange)
                Text(look.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                LookCountdown(deadline: look.deadline)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: LookLabels.symbol(look.call.tool))
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                Text(verbatim: look.targetLine)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(3).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            if look.sendsPicture {
                Label(LookLabels.pictureNote, systemImage: "arrow.up.forward.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Only for a caller the app could not match to a session; in "ask every time" mode the lasting answer is absent by choice.
            if look.sessionKey == AppModel.unknownAgentKey {
                Text(LookLabels.unknownNote)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // No keyboard shortcut on purpose: a look is allowed only by a click on the button.
            HStack(spacing: 8) {
                BigButton(title: "Allow once", symbol: "checkmark", prominent: !sessionFirst) { model.decideLook(look.id, .once) }
                    .help("Allow this one look")
                BigButton(title: "Deny", symbol: "xmark", role: .destructive) { model.decideLook(look.id, .deny) }
                    .help("The agent is told that you did not allow this")
            }
            if look.offersSession {
                BigButton(title: "Allow for this session", symbol: "checkmark.circle", prominent: sessionFirst) {
                    model.decideLook(look.id, .session)
                }
                .help("This session may look without asking again until it ends. Excluded apps stay hidden.")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.09)))
    }
}

struct LookCountdown: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(deadline.timeIntervalSince(ctx.date).rounded(.up)))
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(left < 30 ? Color.red : Color.secondary)
                .help("Refused when the time runs out")
        }
    }
}

// MARK: - Icon badge and card rows

/// On a session's icon while a look is being decided or taken.
struct LookBadge: View {
    var body: some View {
        Image(systemName: "eye.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.orange))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .help("An agent wants to look at the screen")
    }
}

/// "Looked at: …" - the session's latest looks, newest last. Only the target is named.
struct LookNotes: View {
    let notes: [LookNote]

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(notes.suffix(2)) { n in
                HStack(spacing: 6) {
                    Image(systemName: "eye").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Text(verbatim: n.text).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Self.time.string(from: n.time)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                }
                .frame(height: 16)
            }
        }
    }
}

/// A look was refused because a macOS permission is missing. Nothing is requested from here: the button opens the setup window.
struct LookBlockedNotice: View {
    @ObservedObject var model: AppModel
    let sessionKey: String
    let kind: PermissionKind

    var body: some View {
        let what = kind == .accessibility ? "to read a window's text" : "for a screenshot"
        Notice(icon: "eye.slash", color: .orange,
               text: "The agent asked \(what), but Agent HUD has no \(Permissions.info(kind).title) permission. It was refused.",
               actions: [("Set up…", { model.openSetup(kind) }), ("Dismiss", { model.dismissLookBlocked(sessionKey) })])
    }
}

/// The body of the placeholder entry's card: there is no conversation to show.
struct UnknownAgentNote: View {
    var body: some View {
        Text("Something on this Mac called Agent HUD's screen tools, and it is not one of the sessions listed here. It may be a script, or a session Agent HUD has not seen yet.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings (control panel)

/// The mode and the excluded apps. Values come in as bindings, so the render check can show any state.
struct ScreenAccessSection: View {
    let index: Int
    @Binding var mode: ScreenAccessMode
    @Binding var excluded: [String]
    /// App name for a bundle id; nil when no such app is installed.
    var appName: (String) -> String? = ScreenAccessSection.installedName
    @State private var newId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: index, title: "Screen access")
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(title: "Agents may look at the screen").padding(.top, 10)
                    BrandSegmented(options: ScreenAccessMode.allCases.map { ($0, $0.title) }, selection: $mode)
                    Text(mode.hint).font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Read-only: windows, screenshots, window text. Nothing is clicked or typed.")
                        .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(Brand.line).padding(.vertical, 4)
                    FieldLabel(title: "Never shown to agents", hint: "apps by bundle id")
                    ForEach(excluded, id: \.self) { id in
                        ExcludedAppRow(id: id, name: appName(id)) { excluded.removeAll { $0 == id } }
                    }
                    HStack(spacing: 6) {
                        TextField("com.example.app", text: $newId)
                            .textFieldStyle(.roundedBorder)
                            .font(Brand.mono(11))
                            .onSubmit(add)
                        GhostButton(title: "Add", symbol: "plus", action: add)
                            .disabled(!LookExclusions.isBundleId(newId.trimmingCharacters(in: .whitespaces)))
                    }
                    .padding(.top, 2).padding(.bottom, 10)
                }
            }
        }
    }

    private func add() {
        let next = LookExclusions.normalized(excluded + [newId])
        guard next != excluded else { return }
        excluded = next
        newId = ""
    }

    static func installedName(_ bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

struct ExcludedAppRow: View {
    let id: String
    let name: String?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(name ?? "Not installed").font(Brand.body(12)).foregroundStyle(name == nil ? Brand.inkSubtle : Brand.ink)
                .lineLimit(1).layoutPriority(1)
            // The id takes all the room that is left; a spacer next to it would get half and cut the id short.
            Text(verbatim: id).font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.inkMuted)
            .help("Stop excluding this app")
        }
        .frame(height: 24)
    }
}

// MARK: - Setup window row

/// "Screen tools for agents": whether Claude Code sessions outside Agent HUD have the tools, and the button that
/// registers or removes them through Claude Code's own command.
struct ScreenToolsRow: View {
    let state: ScreenToolsState
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 14))
                .foregroundStyle(Brand.accentText)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(Brand.accentSoft))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Screen tools for agents").font(Brand.body(13, .medium)).foregroundStyle(Brand.ink)
                    BrandTag(text: pillText, tone: pillTone)
                }
                Text("Gives Claude Code sessions in a terminal or an editor the read-only screen tools that sessions started here already have. Every look still asks you in the HUD.")
                    .font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = state.detail {
                    Text(detail).font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Group {
                if state.status == .registered {
                    SetupButton(title: "Disconnect", primary: false, action: disconnect)
                } else {
                    SetupButton(title: "Connect…", primary: true, action: connect)
                }
            }
            .disabled(state.busy)
            .opacity(state.busy ? 0.5 : 1)
        }
        .padding(.vertical, 12)
    }

    private var pillText: String {
        if state.busy { return "Working…" }
        switch state.status {
        case .registered: return "Connected"
        case .notRegistered: return "Not connected"
        case .unknown: return "Check"
        }
    }

    private var pillTone: BrandTag.Tone {
        switch state.status {
        case .registered: return state.busy ? .neutral : .success
        case .notRegistered, .unknown: return .neutral
        }
    }
}
