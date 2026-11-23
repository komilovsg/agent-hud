import Foundation

/// The macOS permissions (and the hook connection) Agent HUD can use. Pure data: the checks live in the app target.
public enum PermissionKind: String, CaseIterable, Sendable {
    case hooks, accessibility, automation, notifications, screenRecording, fullDiskAccess
}

public enum PermissionStatus: String, Sendable {
    case granted, notGranted, unknown
}

public struct PermissionInfo: Equatable, Sendable {
    /// `now`: a shipped feature needs it. `coming`: for features that are being built.
    public enum Stage: String, Sendable { case now, coming }

    public let kind: PermissionKind
    public let title: String
    public let usedFor: String
    public let stage: Stage
    public let limitedWithout: String

    public init(kind: PermissionKind, title: String, usedFor: String, stage: Stage, limitedWithout: String) {
        self.kind = kind
        self.title = title
        self.usedFor = usedFor
        self.stage = stage
        self.limitedWithout = limitedWithout
    }
}

public enum Permissions {
    public static let all: [PermissionInfo] = [
        PermissionInfo(kind: .hooks, title: "Connection to Claude Code",
                       usedFor: "Sees your sessions, lets you answer permission requests, and powers Pause and Stop.",
                       stage: .now, limitedWithout: "Agent HUD sees nothing"),
        PermissionInfo(kind: .accessibility, title: "Accessibility",
                       usedFor: "Types your message into the editor or terminal when you send from the card.",
                       stage: .now, limitedWithout: "Messages are copied instead of sent"),
        PermissionInfo(kind: .automation, title: "Automation",
                       usedFor: "Brings the right Terminal or iTerm tab to the front.",
                       stage: .now, limitedWithout: "Terminal sessions cannot be opened or answered from the HUD"),
        PermissionInfo(kind: .notifications, title: "Notifications",
                       usedFor: "Tells you when an agent needs you while the HUD is hidden.",
                       stage: .now, limitedWithout: "No notifications"),
        PermissionInfo(kind: .screenRecording, title: "Screen Recording",
                       usedFor: "Lets agents see the screen.",
                       stage: .coming, limitedWithout: "Agents cannot see the screen"),
        PermissionInfo(kind: .fullDiskAccess, title: "Full Disk Access",
                       usedFor: "Lets sessions started by Agent HUD read files outside your projects.",
                       stage: .coming, limitedWithout: "Sessions cannot read files outside your projects"),
    ]

    public static func info(_ kind: PermissionKind) -> PermissionInfo {
        all.first { $0.kind == kind }!
    }

    public struct Summary: Equatable, Sendable {
        public let grantedCount: Int
        public let total: Int
        public let unknownCount: Int
        /// Needed now and not granted. Unknown is not listed: it may still be fine.
        public let missingNow: [PermissionInfo]
        public var isLimited: Bool { !missingNow.isEmpty }
        public let headline: String
    }

    /// A kind missing from `statuses` counts as unknown.
    public static func summary(_ statuses: [PermissionKind: PermissionStatus]) -> Summary {
        func status(_ i: PermissionInfo) -> PermissionStatus { statuses[i.kind] ?? .unknown }
        let granted = all.filter { status($0) == .granted }.count
        let unknown = all.filter { status($0) == .unknown }.count
        let missing = all.filter { $0.stage == .now && status($0) == .notGranted }
        let total = all.count

        let headline: String
        if granted == total {
            headline = "All \(total) allowed"
        } else if let first = missing.first {
            let lead = granted == 0 ? "Nothing allowed yet" : "\(granted) of \(total) allowed"
            headline = "\(lead) · limited: \(lowerFirst(first.limitedWithout))"
        } else if unknown > 0 {
            headline = "\(granted) of \(total) allowed · check the rest"
        } else {
            headline = "\(granted) of \(total) allowed · the rest is not used yet"
        }
        return Summary(grantedCount: granted, total: total, unknownCount: unknown, missingNow: missing, headline: headline)
    }

    /// "Messages are copied" -> "messages are copied"; a name such as "Agent HUD sees nothing" keeps its capital.
    private static func lowerFirst(_ s: String) -> String {
        guard let first = s.first, !s.hasPrefix("Agent") else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
