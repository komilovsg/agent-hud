import Foundation
import ServiceManagement

/// Launch at login via SMAppService (the item in "Login Items" of System Settings).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "disabled"
        case .requiresApproval: return "waiting for approval in System Settings → General → Login Items"
        case .notFound: return "app not found (run it from ~/Applications)"
        @unknown default: return "unknown"
        }
    }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
