//
//  HotkeyConfig.swift
//  Persisted hotkey definition + human-readable rendering.
//
//  The hotkey is stored as (keyCode, modifierFlags) in UserDefaults.
//  Default is Ctrl+Q (keyCode 12, .control).  matches(event:) is the
//  single source of truth consulted by AppDelegate's key monitor.
//

import AppKit

struct Hotkey: Equatable {
    /// macOS virtual keyCode — layout-independent.  Using keyCode not
    /// character means the user can record e.g. "Ctrl+Q" on a Dvorak
    /// keyboard and have it fire reliably.
    let keyCode: UInt16
    /// Device-independent modifier mask (.command / .option / .control / .shift).
    let modifiers: NSEvent.ModifierFlags

    static let `default` = Hotkey(
        keyCode: 12,           // "q" on ANSI; we store the code, not the char
        modifiers: [.control]
    )

    func matches(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == keyCode && mods == modifiers
    }

    /// Human display:  "⌃Q", "⌘⇧P", "⌥F1", etc.
    var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option)  { out += "⌥" }
        if modifiers.contains(.shift)   { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        out += Hotkey.keyCodeDisplayName(keyCode)
        return out
    }

    /// Short name for the key portion — letters come out uppercase,
    /// function keys as "F1" etc., arrows / enter / etc. with glyphs.
    static func keyCodeDisplayName(_ code: UInt16) -> String {
        // Special keys that don't map to a printable character.
        switch code {
        case 36:  return "↩"   // return
        case 48:  return "⇥"   // tab
        case 49:  return "Space"
        case 51:  return "⌫"   // delete
        case 53:  return "⎋"   // escape
        case 76:  return "⌤"   // enter (keypad)
        case 117: return "⌦"   // forward delete
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:  break
        }

        // Fall back to the character produced by the key with no modifiers
        // applied — uppercase for clean display.
        if let str = characterForKeyCode(code) {
            return str.uppercased()
        }
        return "Key\(code)"
    }

    /// Produce the bare character for a virtual keyCode by asking a
    /// fake NSEvent for its `charactersIgnoringModifiers`.  This works
    /// across keyboard layouts (Dvorak's keyCode 12 → "'", not "q").
    private static func characterForKeyCode(_ code: UInt16) -> String? {
        // We can't easily synthesize a stray NSEvent — use the TIS
        // (text-input source) APIs via a small trampoline.  Simpler:
        // use a hardcoded ANSI-US map for the common letters/digits.
        // The user can still record any key; it just renders to the
        // ANSI-US name in the UI.
        let ansi: [UInt16: String] = [
            0: "A",  1: "S",  2: "D",  3: "F",  4: "H",  5: "G",  6: "Z",
            7: "X",  8: "C",  9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
           15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
           22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
           29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
           37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
           43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        ]
        return ansi[code]
    }
}

enum HotkeyConfig {

    private static let keyCodeKey = "qm.hotkey.keyCode"
    private static let modifiersKey = "qm.hotkey.modifiers"

    /// Posted on `DistributedNotificationCenter.default()` after a successful save.
    /// Local-only; subscribers update the UI / matcher.
    static let didChangeNotification = Notification.Name("qm.hotkey.didChange")

    static var current: Hotkey {
        let d = UserDefaults.standard
        if d.object(forKey: keyCodeKey) != nil {
            let code = UInt16(d.integer(forKey: keyCodeKey))
            let mods = NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: modifiersKey)))
            return Hotkey(keyCode: code, modifiers: mods)
        }
        return .default
    }

    static func save(_ hk: Hotkey) {
        let d = UserDefaults.standard
        d.set(Int(hk.keyCode), forKey: keyCodeKey)
        d.set(Int(hk.modifiers.rawValue), forKey: modifiersKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        QMLog.info("hotkey saved: \(hk.display) (keyCode=\(hk.keyCode) mods=\(hk.modifiers.rawValue))")
    }

    static func resetToDefault() {
        save(.default)
    }
}
