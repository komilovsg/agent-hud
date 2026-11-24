import Testing
@testable import AgentHudCore

@Suite struct PermissionsTests {
    func all(_ s: PermissionStatus) -> [PermissionKind: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, s) })
    }

    @Test func everyKindHasOneEntry() {
        #expect(Permissions.all.count == PermissionKind.allCases.count)
        for k in PermissionKind.allCases {
            #expect(Permissions.all.filter { $0.kind == k }.count == 1)
            #expect(Permissions.info(k).kind == k)
        }
        #expect(Permissions.all.filter { $0.stage == .now }.count == 5)
        #expect(Permissions.info(.accessibility).stage == .now)
        #expect(Permissions.info(.screenRecording).stage == .now)
        #expect(Permissions.info(.fullDiskAccess).stage == .coming)
        // Agents can look at the screen only when asked: the texts say so.
        #expect(Permissions.info(.screenRecording).usedFor == "Lets agents take screenshots when you allow it.")
        #expect(Permissions.info(.accessibility).usedFor == "Lets agents read window text and act in apps when you allow it")
        #expect(Permissions.info(.accessibility).limitedWithout == "Agents cannot read window text or act")
        #expect(Permissions.neededOnlyInUse == [.accessibility])
    }

    @Test func missingAccessibilityLimitsOnlyWhenItIsInUse() {
        var st = all(.granted)
        st[.accessibility] = .notGranted
        // Agent actions are off and nothing asked for window text: the app is not limited.
        let idle = Permissions.summary(st)
        #expect(!idle.isLimited && idle.missingNow.isEmpty && idle.grantedCount == 5)
        #expect(idle.headline == "5 of 6 allowed · the rest is not used yet")
        #expect(Permissions.summary(st, inUse: []) == idle)
        // Agent actions are on, or a read of window text was refused for it.
        let used = Permissions.summary(st, inUse: [.accessibility])
        #expect(used.isLimited && used.missingNow.map(\.kind) == [.accessibility])
        #expect(used.headline == "5 of 6 allowed · limited: agents cannot read window text or act")
        // Granted: being in use changes nothing.
        #expect(Permissions.summary(all(.granted), inUse: [.accessibility]).headline == "All 6 allowed")
        #expect(!Permissions.summary(all(.granted), inUse: [.accessibility]).isLimited)
        // Unknown is not "missing", in use or not.
        st[.accessibility] = .unknown
        #expect(!Permissions.summary(st, inUse: [.accessibility]).isLimited)
    }

    @Test func inUseDoesNotChangeTheOtherPermissions() {
        // The other permissions limit the app whether or not anything is passed as in use.
        var st = all(.granted)
        st[.screenRecording] = .notGranted
        #expect(Permissions.summary(st, inUse: []).missingNow.map(\.kind) == [.screenRecording])
        #expect(Permissions.summary(st, inUse: [.accessibility]).missingNow.map(\.kind) == [.screenRecording])
        // Passing a kind that is always needed is harmless.
        #expect(Permissions.summary(st, inUse: [.screenRecording, .hooks]).missingNow.map(\.kind) == [.screenRecording])
        // In the order of the list: Accessibility comes before Automation.
        let nothing = Permissions.summary(all(.notGranted), inUse: [.accessibility])
        #expect(nothing.missingNow.map(\.kind) == [.hooks, .accessibility, .automation, .notifications, .screenRecording])
        #expect(nothing.headline == "Nothing allowed yet · limited: Agent HUD sees nothing")
    }

    @Test func allGranted() {
        let s = Permissions.summary(all(.granted))
        #expect(s.grantedCount == 6 && s.total == 6 && s.unknownCount == 0)
        #expect(s.missingNow.isEmpty && !s.isLimited)
        #expect(s.headline == "All 6 allowed")
    }

    @Test func missingNowLimits() {
        var st = all(.granted)
        st[.automation] = .notGranted
        st[.fullDiskAccess] = .notGranted
        let s = Permissions.summary(st)
        #expect(s.grantedCount == 4)
        #expect(s.missingNow.map(\.kind) == [.automation])
        #expect(s.isLimited)
        #expect(s.headline == "4 of 6 allowed · limited: terminal sessions cannot be opened or answered from the HUD")
        st[.accessibility] = .notGranted
        #expect(Permissions.summary(st).missingNow.map(\.kind) == [.automation])
    }

    @Test func missingComingDoesNotLimit() {
        var st = all(.granted)
        st[.fullDiskAccess] = .notGranted
        let s = Permissions.summary(st)
        #expect(!s.isLimited && s.missingNow.isEmpty)
        #expect(s.headline == "5 of 6 allowed · the rest is not used yet")
    }

    @Test func missingScreenRecordingLimitsScreenshots() {
        var st = all(.granted)
        st[.screenRecording] = .notGranted
        let s = Permissions.summary(st)
        #expect(s.isLimited && s.missingNow.map(\.kind) == [.screenRecording])
        #expect(s.headline == "5 of 6 allowed · limited: agents cannot take screenshots")
    }

    @Test func unknownIsNotGrantedAndNotMissing() {
        var st = all(.granted)
        st[.automation] = .unknown
        let s = Permissions.summary(st)
        #expect(s.grantedCount == 5 && s.unknownCount == 1)
        #expect(s.missingNow.isEmpty && !s.isLimited)
        #expect(s.headline == "5 of 6 allowed · check the rest")
        // A kind that is absent counts as unknown too.
        #expect(Permissions.summary([:]).unknownCount == 6)
        #expect(!Permissions.summary([:]).isLimited)
    }

    @Test func nothingGranted() {
        let s = Permissions.summary(all(.notGranted))
        #expect(s.grantedCount == 0)
        #expect(s.missingNow.map(\.kind) == [.hooks, .automation, .notifications, .screenRecording])
        #expect(s.headline == "Nothing allowed yet · limited: Agent HUD sees nothing")
    }
}
