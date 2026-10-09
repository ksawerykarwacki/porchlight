import AppKit
import Carbon.HIToolbox
import PorchlightCore

extension Hotkey {
    /// The modifier bits the system's hot-key registration takes.
    public var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }

    /// The shortcut a key press stands for, or nil when it is only a modifier or cannot be one.
    public init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var modifiers: Modifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers, character: event.charactersIgnoringModifiers)
        guard isUsable else { return nil }
    }
}

/// One system-wide shortcut. Registered with the system's hot-key service, which needs no
/// Accessibility or Input Monitoring permission because the app is only told about its own
/// shortcut, never about other keys.
@MainActor
public final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?
    private var action: (() -> Void)?
    public private(set) var current: Hotkey?

    public init() {}

    /// Replaces the shortcut. Nil removes it. Returns false when the system refused, which is
    /// what happens when another app already holds that shortcut.
    @discardableResult
    public func set(_ hotkey: Hotkey?, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        guard let hotkey else { return true }
        guard hotkey.isUsable else { return false }
        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x504C_4854), id: 1) // "PLHT"
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), hotkey.carbonModifiers, identifier, GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        self.reference = reference
        current = hotkey
        return true
    }

    public func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        current = nil
    }

    fileprivate func fire() {
        action?()
    }

    private func installHandlerIfNeeded() {
        guard handlerReference == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The callback is a C function: it gets this object back through the user-data pointer.
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Hot-key events arrive on the main thread's event loop.
            MainActor.assumeIsolated { hotkey.fire() }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerReference)
    }
}
