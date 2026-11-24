import AgentHudCore
import AppKit
import ApplicationServices
import AVFoundation
import CoreServices
import Foundation
@preconcurrency import UserNotifications

/// A permission status with an optional short note ("needs an update", "Open Terminal to check").
struct PermissionState: Equatable {
    var status: PermissionStatus
    var detail: String? = nil
}

/// Status checks and requests for the permissions in `Permissions.all`.
/// `state` / `states` only read: they never show a system prompt. `request` is the only place that asks,
/// and it runs only from a button click.
@MainActor
enum PermissionProbe {
    // MARK: - Read-only checks

    static func states() async -> [PermissionKind: PermissionState] {
        var out: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases where kind != .notifications { out[kind] = state(kind) }
        out[.notifications] = await notificationState()
        return out
    }

    /// Every kind except notifications, which are read asynchronously.
    static func state(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .hooks: return hooksState()
        case .accessibility: return PermissionState(status: AXIsProcessTrusted() ? .granted : .notGranted)
        case .automation: return automationState()
        case .notifications: return PermissionState(status: .unknown)
        case .screenRecording: return PermissionState(status: CGPreflightScreenCaptureAccess() ? .granted : .notGranted)
        case .fullDiskAccess: return fullDiskState()
        // Read-only status checks: neither shows a system prompt.
        case .microphone: return PermissionState(status: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .notGranted)
        case .speechRecognition: return PermissionState(status: AppleSpeechAccess.status() == .granted ? .granted : .notGranted)
        }
    }

    private static func hooksState() -> PermissionState {
        let kind = AgentKind.claude
        guard HookSetup.isInstalled(kind) else {
            return PermissionState(status: .notGranted, detail: HookSetup.agentPresent(kind) ? nil : "Claude Code not found")
        }
        return HookSetup.needsUpdate(kind) ? PermissionState(status: .notGranted, detail: "Needs an update")
                                           : PermissionState(status: .granted)
    }

    private static let terminalApps = ["com.apple.Terminal", "com.googlecode.iterm2"]

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Automation is per target app. Only running targets can be asked, so with no terminal open the answer is unknown.
    private static func automationState() -> PermissionState {
        let terminals = terminalApps.filter(isRunning)
        // macOS lists this app under Automation only after it has asked once, and it can only ask a running app.
        let hint = "Only for sessions in Terminal or iTerm. Allow… opens Terminal and asks."
        guard !terminals.isEmpty else { return PermissionState(status: .unknown, detail: hint) }
        let results = terminals.map { automationStatus(of: $0, ask: false) }
        if results.contains(.notGranted) { return PermissionState(status: .notGranted) }
        if results.allSatisfy({ $0 == .granted }) { return PermissionState(status: .granted) }
        return PermissionState(status: .unknown, detail: hint)
    }

    /// `AEDeterminePermissionToAutomateTarget`: with `ask` false it never shows the system prompt.
    private static func automationStatus(of bundleId: String, ask: Bool) -> PermissionStatus {
        var addr = AEAddressDesc()
        let id = Array(bundleId.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &addr) == noErr else { return .unknown }
        defer { AEDisposeDesc(&addr) }
        let r = AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, ask)
        switch Int(r) {
        case Int(noErr): return .granted
        case errAEEventNotPermitted, errAEEventWouldRequireUserConsent: return .notGranted
        default: return .unknown          // target not running (procNotFound) or another error
        }
    }

    /// The TCC databases are readable only with Full Disk Access. The first one that exists decides.
    private static func fullDiskState() -> PermissionState {
        let paths = [NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                     "/Library/Application Support/com.apple.TCC/TCC.db"]
        for path in paths {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return PermissionState(status: .granted) }
            if errno == EPERM || errno == EACCES { return PermissionState(status: .notGranted) }
        }
        return PermissionState(status: .unknown)
    }

    private static func notificationState() async -> PermissionState {
        guard Bundle.main.bundleIdentifier != nil else { return PermissionState(status: .unknown, detail: "Needs the installed app") }
        let status = await withCheckedContinuation { (c: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { c.resume(returning: $0.authorizationStatus) }
        }
        switch status {
        case .authorized, .provisional, .ephemeral: return PermissionState(status: .granted)
        case .denied, .notDetermined: return PermissionState(status: .notGranted)
        @unknown default: return PermissionState(status: .unknown)
        }
    }

    // MARK: - Requests (button clicks only)

    static func request(_ kind: PermissionKind, hookTimeout: Int) {
        switch kind {
        case .hooks:
            let agent = AgentKind.claude
            guard HookSetup.agentPresent(agent) else {
                HookSetup.info("Claude Code not found", "Install Claude Code first, then connect Agent HUD.")
                return
            }
            HookSetup.install(agent, timeout: hookTimeout)
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .automation:
            // Ask for each running target; a target that already said no never prompts again, so send the user to the pane.
            // The scripts only talk to terminals. With none running, start Terminal in the background first:
            // the system prompt (and the entry in the Automation list) exists only for a running target.
            var targets = terminalApps.filter(isRunning)
            if targets.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalApps[0]) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                cfg.hides = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if automationStatus(of: terminalApps[0], ask: true) != .granted { openSettingsPane(.automation) }
                    }
                }
                return
            }
            var needsPane = targets.isEmpty
            targets = targets.filter { automationStatus(of: $0, ask: true) != .granted }
            if !targets.isEmpty { needsPane = true }
            if needsPane { openSettingsPane(.automation) }
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { openSettingsPane(.notifications); return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .fullDiskAccess:
            openSettingsPane(.fullDiskAccess)       // macOS has no prompt for it
        case .microphone:
            // The system asks once; after a refusal only the Settings pane can change the answer.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSettingsPane(.microphone)
            }
        case .speechRecognition:
            if AppleSpeechAccess.status() == .notDetermined { AppleSpeechAccess.request() } else { openSettingsPane(.speechRecognition) }
        }
    }

    static func openSettingsPane(_ kind: PermissionKind) {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?"
        let link: String
        switch kind {
        case .accessibility: link = privacy + "Privacy_Accessibility"
        case .automation: link = privacy + "Privacy_Automation"
        case .screenRecording: link = privacy + "Privacy_ScreenCapture"
        case .fullDiskAccess: link = privacy + "Privacy_AllFiles"
        case .microphone: link = privacy + "Privacy_Microphone"
        case .speechRecognition: link = privacy + "Privacy_SpeechRecognition"
        case .notifications: link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .hooks: return
        }
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Build signature

    /// A build without a Team ID (ad-hoc signed or unsigned, e.g. built from source): macOS ties permissions
    /// to the code signature, so they are forgotten after each rebuild.
    static var isAdHocBuild: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String) == nil
    }
}
