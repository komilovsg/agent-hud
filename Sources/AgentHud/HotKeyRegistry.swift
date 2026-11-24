import AppKit
import Carbon.HIToolbox

/// Global hotkeys of the app (stop agent actions, command bar). A Carbon hot key works while any app is in
/// front and needs no permission. One event handler serves every key; each key is told apart by its id.
/// Both the press and the release of a key are delivered (`kEventHotKeyPressed` and `kEventHotKeyReleased`).
/// Registered only from the app's normal launch.
@MainActor
final class HotKeyRegistry {
    private struct Entry {
        var ref: EventHotKeyRef
        var action: @MainActor () -> Void
        var onRelease: (@MainActor () -> Void)?
    }

    private static let signature: OSType = 0x4148_4B59   // "AHKY"
    private var handler: EventHandlerRef?
    private var entries: [UInt32: Entry] = [:]

    /// Registers `keyCode` + `modifiers` (Carbon mask) under `id`, replacing an earlier key with that id.
    /// `action` runs on the press, `onRelease` (when given) on the release.
    /// Returns false when the system refused (another app holds the combination).
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void,
                  onRelease: (@MainActor () -> Void)? = nil) -> Bool {
        unregister(id: id)
        guard installHandler() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        entries[id] = Entry(ref: ref, action: action, onRelease: onRelease)
        return true
    }

    func unregister(id: UInt32) {
        guard let e = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(e.ref)
    }

    func unregisterAll() {
        for id in Array(entries.keys) { unregister(id: id) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr, key.signature == HotKeyRegistry.signature else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKeyRegistry>.fromOpaque(userData).takeUnretainedValue()
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            // The main queue keeps the order: a press is always handled before its release.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let entry = me.entries[key.id] else { return }
                    if released { entry.onRelease?() } else { entry.action() }
                }
            }
            return noErr
        }
        return InstallEventHandler(GetApplicationEventTarget(), callback, specs.count, &specs,
                                   Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr
    }
}

/// Ids of the app's hotkeys in the registry.
enum HotKeyId {
    static let stopActions: UInt32 = 1
    static let commandBar: UInt32 = 2
}
