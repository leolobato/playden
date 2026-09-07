import Carbon

/// A registered shortcut works while a game is frontmost without a global keyboard event tap.
@MainActor
final class GameExitShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    func start() -> Bool {
        guard hotKey == nil else { return true }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<GameExitShortcut>.fromOpaque(data).takeUnretainedValue().action?() }
            return noErr
        }, 1, &event, context, &handler)
        guard status == noErr else { return false }
        let id = EventHotKeyID(signature: 0x42475343, id: 1)
        guard RegisterEventHotKey(UInt32(kVK_Home), UInt32(shiftKey), id, GetApplicationEventTarget(), 0, &hotKey) == noErr else { stop(); return false }
        return true
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
