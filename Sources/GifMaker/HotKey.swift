import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: a key plus modifiers.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃⌥⇧⌘.
    var modifiers: UInt
    /// What to show for the key itself, e.g. "G" or "F5".
    var keyLabel: String

    /// ⌃⌥⌘G
    static let defaultRecord = KeyCombo(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, keyLabel: "G")

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    var displayString: String {
        var result = ""
        if modifierFlags.contains(.control) { result += "⌃" }
        if modifierFlags.contains(.option) { result += "⌥" }
        if modifierFlags.contains(.shift) { result += "⇧" }
        if modifierFlags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    /// Builds a combo from a key-down event, or `nil` if it isn't usable as a
    /// global shortcut (it needs ⌘, ⌃ or ⌥ so it can't swallow ordinary typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        let isFunctionKey = Self.specialKeyLabels[Int(event.keyCode)]?.hasPrefix("F") == true
        guard !flags.intersection([.command, .control, .option]).isEmpty || isFunctionKey else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = flags.rawValue
        if let special = Self.specialKeyLabels[Int(event.keyCode)] {
            keyLabel = special
        } else if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            keyLabel = characters.uppercased()
        } else {
            return nil
        }
    }

    init(keyCode: UInt32, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
}

/// A system-wide hotkey that works while other apps are in front. Uses the
/// Carbon hotkey API, which needs no Accessibility permission.
final class GlobalHotKey {
    var handler: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4749_464D  // 'GIFM'

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Registers `combo`, replacing any previous one. Returns `false` if the
    /// system refused it (typically because another app already owns it).
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        guard let combo else { return true }
        installHandlerIfNeeded()

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.handler?() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
}
