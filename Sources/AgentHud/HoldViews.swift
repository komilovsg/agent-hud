import AgentHudCore
import AppKit
import SwiftUI

// Pause and Stop hold the session's NEXT tool call in its hook. They cannot interrupt text generation or
// a command that is already running, and every text here says so.

extension Hold.Kind {
    var symbol: String { self == .pause ? "pause.fill" : "stop.fill" }
    /// Label of the button that ends the hold.
    var resumeTitle: String { self == .pause ? "Resume now" : "Play" }
}

extension Color {
    /// One colour for both kinds of hold: the status dot, the state capsule, the banner.
    static let holdTint = Color(red: 0.56, green: 0.45, blue: 0.95)
}

/// What a session offers right now: nothing (ended), disabled items (cannot be held yet), or hold / resume actions.
struct HoldAction: Identifiable {
    let title: String
    let symbol: String
    let enabled: Bool
    let run: @MainActor () -> Void
    var id: String { title }

    static let pauseTitle = "Pause for 15 min"

    @MainActor static func items(for session: AgentSession, model: AppModel) -> [HoldAction] {
        guard session.baseState != .ended else { return [] }
        let key = session.id
        let can = session.supportsHold
        let pause = HoldAction(title: pauseTitle, symbol: "pause.fill", enabled: can) { model.hold(key, .pause) }
        let stop = HoldAction(title: "Stop", symbol: "stop.fill", enabled: can) { model.hold(key, .stop) }
        guard let hold = session.hold else { return [pause, stop] }
        let resume = HoldAction(title: "Resume", symbol: "play.fill", enabled: true) { model.resume(key) }
        return [resume, hold.kind == .pause ? stop : pause]
    }

    /// Tooltip: the honest limit for a working action, the reason for a disabled one.
    func help(for session: AgentSession) -> String {
        if !enabled { return Hold.unsupportedHint }
        switch symbol {
        case "play.fill": return "Resume: the agent continues from where it was held"
        case "pause.fill": return "\(Self.pauseTitle). \(Hold.pendingNote); it then continues by itself"
        default: return "Stop until you press Play. \(Hold.pendingNote)"
        }
    }
}

/// Over a held session's icon: the pause countdown or the stop glyph. Fixed size - the token box never changes.
struct HoldOverlay: View {
    let hold: Hold

    var body: some View {
        Group {
            if hold.kind == .pause {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Hold.countdown(hold.remaining(at: ctx.date) ?? 0))
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                }
            } else {
                Image(systemName: "stop.fill").font(.system(size: 15, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: hold.kind == .pause ? 52 : 30, height: hold.kind == .pause ? 22 : 30)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}

/// "Paused · 12:41 left" / "Stopped · for 8 min", ticking.
struct HoldStatusText: View {
    let hold: Hold
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(hold.statusLine(at: ctx.date))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.holdTint)
                .lineLimit(1)
        }
    }
}

/// What the hold is waiting at - one line per held call.
struct HoldWaitingLines: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(session.holdWaitingLines().enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(height: HoldPopoverMetrics.lineHeight)
            }
        }
    }
}

struct ResumeButton: View {
    let kind: Hold.Kind
    var wide = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "play.fill").font(.system(size: wide ? 11 : 9))
                Text(kind.resumeTitle).font(.system(size: wide ? 13 : 11, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: wide ? .infinity : nil)
            .padding(.horizontal, 10)
            .frame(height: wide ? 30 : 24)
        }
        .buttonStyle(FilledButtonStyle())
        .fixedSize(horizontal: !wide, vertical: true)
        .help("The agent continues from where it was held")
    }
}

/// A filled button that looks the same in a window that is never key (system prominent buttons turn grey there).
struct FilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.holdTint))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Slim banner under the card header while the session is held.
struct HoldBanner: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let hold: Hold

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: hold.kind.symbol).font(.system(size: 12)).foregroundStyle(Color.holdTint).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HoldStatusText(hold: hold)
                HoldWaitingLines(session: session)
            }
            Spacer(minLength: 4)
            ResumeButton(kind: hold.kind) { model.resume(session.id) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.holdTint.opacity(0.12)))
    }
}

// MARK: - Popover next to a held session's icon

enum HoldPopoverMetrics {
    static let width: CGFloat = 312
    static let lineHeight: CGFloat = 15

    /// The popover window has a fixed size for a given number of "holding" lines.
    static func size(for session: AgentSession) -> CGSize {
        let lines = CGFloat(session.holdWaitingLines().count)
        return CGSize(width: width, height: 156 + lines * (lineHeight + 2))
    }
}

struct HoldPopoverRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let key = model.holdPopoverKey, let s = model.store.session(key), let hold = s.hold {
                HoldPopover(session: s, hold: hold) { model.resume(key) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { HoverArea { model.popoverHover($0) } }
        .tint(Brand.accent)
    }
}

struct HoldPopover: View {
    let session: AgentSession
    let hold: Hold
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProjectDot(cwd: session.cwd)
                Text(session.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }
            .frame(height: 16)
            HStack(spacing: 6) {
                Image(systemName: hold.kind.symbol).font(.system(size: 10)).foregroundStyle(Color.holdTint)
                HoldStatusText(hold: hold)
            }
            .frame(height: 16)
            HoldWaitingLines(session: session)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Hold.limits, id: \.self) { t in
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle").font(.system(size: 9))
                        Text(t).font(.system(size: 10)).lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: 13)
                }
            }
            ResumeButton(kind: hold.kind, wide: true, action: resume)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(12, shadow: false)
    }
}

/// Pointer enter / exit for a view in a window that is never key (SwiftUI's `onHover` needs an active window).
struct HoverArea: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView { HoverTrackingView() }
    func updateNSView(_ v: HoverTrackingView, context: Context) { v.onHover = onHover }
}

final class HoverTrackingView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}
