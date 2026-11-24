import Foundation

/// The macOS permissions (and the hook connection) Agent HUD can use. Pure data: the checks live in the app target.
public enum PermissionKind: String, CaseIterable, Sendable {
    case hooks, accessibility, automation, notifications, screenRecording, microphone, speechRecognition, fullDiskAccess
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
                       usedFor: "Lets agents read window text and act in apps when you allow it",
                       stage: .now, limitedWithout: "Agents cannot read window text or act"),
        PermissionInfo(kind: .automation, title: "Automation",
                       usedFor: "Brings the right Terminal or iTerm tab to the front.",
                       stage: .now, limitedWithout: "Terminal sessions cannot be opened or answered from the HUD"),
        PermissionInfo(kind: .notifications, title: "Notifications",
                       usedFor: "Tells you when an agent needs you while the HUD is hidden.",
                       stage: .now, limitedWithout: "No notifications"),
        PermissionInfo(kind: .screenRecording, title: "Screen Recording",
                       usedFor: "Lets agents take screenshots when you allow it.",
                       stage: .now, limitedWithout: "Agents cannot take screenshots"),
        PermissionInfo(kind: .microphone, title: "Microphone",
                       usedFor: "Hears you only while you hold the talk key",
                       stage: .now, limitedWithout: "Voice cannot hear you"),
        PermissionInfo(kind: .speechRecognition, title: "Speech Recognition",
                       usedFor: "Turns what you said into text, on this Mac",
                       stage: .now, limitedWithout: "Voice cannot turn speech into text"),
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

    /// Permissions that limit the app only once the feature behind them is in use. Accessibility serves agents
    /// acting in apps (off by default) and reading window text (asked for by few sessions). The microphone and
    /// speech recognition serve voice, which is off until the person switches it on.
    public static let neededOnlyInUse: Set<PermissionKind> = [.accessibility, .microphone, .speechRecognition]

    /// A kind missing from `statuses` counts as unknown.
    /// `inUse`: which of the `neededOnlyInUse` permissions are wanted right now - agent actions are switched on,
    /// a read of window text was refused for the missing permission, or voice is switched on. The others do not count as a limit.
    public static func summary(_ statuses: [PermissionKind: PermissionStatus], inUse: Set<PermissionKind> = []) -> Summary {
        func status(_ i: PermissionInfo) -> PermissionStatus { statuses[i.kind] ?? .unknown }
        let granted = all.filter { status($0) == .granted }.count
        let unknown = all.filter { status($0) == .unknown }.count
        let missing = all.filter {
            $0.stage == .now && status($0) == .notGranted && (!neededOnlyInUse.contains($0.kind) || inUse.contains($0.kind))
        }
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
        guard let first = s.first, !s.hasPrefix("Agent HUD") else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
