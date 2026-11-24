import AppKit
import Carbon.HIToolbox

/// The global "stop agent actions" hotkey, ⌃⌥⌘. (Control-Option-Command-Period). A Carbon hot key works
/// while any app is in front and needs no permission. Registered once, from the app's normal launch.
@MainActor
final class StopHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    private static let signature: OSType = 0x4148_5354   // "AHST"

    init(action: @escaping @MainActor () -> Void) { self.action = action }

    /// Returns false when the system refused the registration (another app holds the combination).
    @discardableResult
    func register() -> Bool {
        guard hotKey == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<StopHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.action() } }
            return noErr
        }
        let installed = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_Period), modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        return status == noErr && hotKey != nil
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
