import Carbon.HIToolbox

final class GlobalHotKeyController: @unchecked Sendable {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor @Sendable () -> Void

    init?(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in controller.action() }
                return noErr
            },
            1,
            &eventType,
            context,
            &handler
        )
        guard handlerStatus == noErr else { return nil }

        let identifier = EventHotKeyID(signature: 0x4742484B, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard hotKeyStatus == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
