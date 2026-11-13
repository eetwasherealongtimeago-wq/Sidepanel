import AppKit
import Carbon.HIToolbox

/// A key combination expressed in Carbon terms (what RegisterEventHotKey wants).
struct HotKey: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// ⌥Space
    static let defaultToggle = HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = HotKey.carbonFlags(from: event.modifierFlags)
    }

    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// Hotkeys need at least one of ⌘ ⌥ ⌃, unless they're function keys.
    var isValid: Bool {
        let needsModifier = !KeyNames.isFunctionKey(UInt16(keyCode))
        let hasModifier = carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        return !needsModifier || hasModifier
    }

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(for: UInt16(keyCode))
    }
}

enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func isFunctionKey(_ code: UInt16) -> Bool {
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return fkeys.contains(Int(code))
    }

    static func name(for code: UInt16) -> String {
        if let s = special[Int(code)] { return s }
        if let s = character(for: code), !s.isEmpty { return s.uppercased() }
        return "Key \(code)"
    }

    /// Character the key produces on the current keyboard layout (so AZERTY etc. display correctly).
    private static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// Registers one system-wide hotkey through the Carbon Event Manager. Unlike an
/// NSEvent global monitor this needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var registered: HotKey?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKeyCenter.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Returns false if the combination is invalid or already taken by another app.
    @discardableResult
    func register(_ key: HotKey) -> Bool {
        unregister()
        guard key.isValid else { return false }
        let id = EventHotKeyID(signature: OSType(0x5344_504E), id: 1) // 'SDPN'
        let status = RegisterEventHotKey(key.keyCode, key.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            registered = key
            return true
        }
        hotKeyRef = nil
        return false
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        registered = nil
    }
}
