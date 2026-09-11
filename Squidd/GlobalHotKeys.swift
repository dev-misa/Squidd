import AppKit
import Carbon

@MainActor
final class GlobalHotKeys {
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    var action: ((UInt32) -> Void)?

    func register() -> [String] {
        stop()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            let id = key.id
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue().action?(id)
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return ["Cannot install shortcuts (\(status))."] }
        let bindings: [(UInt32, UInt32, String)] = [
            (UInt32(kVK_ANSI_Slash), UInt32(cmdKey), "⌘/"),
            (UInt32(kVK_ANSI_W), UInt32(cmdKey | controlKey), "⌘⌃W"),
            (UInt32(kVK_ANSI_A), UInt32(cmdKey | controlKey), "⌘⌃A"),
            (UInt32(kVK_ANSI_S), UInt32(cmdKey | controlKey), "⌘⌃S"),
            (UInt32(kVK_ANSI_D), UInt32(cmdKey | controlKey), "⌘⌃D")
        ]
        var errors: [String] = []
        for (index, binding) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.0, binding.1,
                EventHotKeyID(signature: 0x4D495341, id: UInt32(index)), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { keys.append(ref) }
            else { errors.append("\(binding.2) unavailable (\(result)); another app may be using it.") }
        }
        return errors
    }

    func stop() {
        for key in keys { UnregisterEventHotKey(key) }
        keys = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
