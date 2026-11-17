import Foundation

// Keyboard/Keypad page (0x07) usages, HID Usage Tables §10.

/// A usage on the Keyboard/Keypad page. Only 0x00–0xE7 is valid in this package's
/// descriptor (the key array's logical range).
public struct KeyUsage: RawRepresentable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static func < (a: KeyUsage, b: KeyUsage) -> Bool { a.rawValue < b.rawValue }
    public var description: String { String(format: "0x%02X", rawValue) }

    /// Reserved; "no key" in a key array slot.
    public static let none = KeyUsage(rawValue: 0x00)
    /// ErrorRollOver: reported in every slot when too many keys are down.
    public static let errorRollOver = KeyUsage(rawValue: 0x01)

    // Letters 0x04–0x1D
    public static let a = KeyUsage(rawValue: 0x04), b = KeyUsage(rawValue: 0x05), c = KeyUsage(rawValue: 0x06)
    public static let d = KeyUsage(rawValue: 0x07), e = KeyUsage(rawValue: 0x08), f = KeyUsage(rawValue: 0x09)
    public static let g = KeyUsage(rawValue: 0x0A), h = KeyUsage(rawValue: 0x0B), i = KeyUsage(rawValue: 0x0C)
    public static let j = KeyUsage(rawValue: 0x0D), k = KeyUsage(rawValue: 0x0E), l = KeyUsage(rawValue: 0x0F)
    public static let m = KeyUsage(rawValue: 0x10), n = KeyUsage(rawValue: 0x11), o = KeyUsage(rawValue: 0x12)
    public static let p = KeyUsage(rawValue: 0x13), q = KeyUsage(rawValue: 0x14), r = KeyUsage(rawValue: 0x15)
    public static let s = KeyUsage(rawValue: 0x16), t = KeyUsage(rawValue: 0x17), u = KeyUsage(rawValue: 0x18)
    public static let v = KeyUsage(rawValue: 0x19), w = KeyUsage(rawValue: 0x1A), x = KeyUsage(rawValue: 0x1B)
    public static let y = KeyUsage(rawValue: 0x1C), z = KeyUsage(rawValue: 0x1D)

    // Digits 0x1E–0x27 (1…9, 0)
    public static let digit1 = KeyUsage(rawValue: 0x1E), digit2 = KeyUsage(rawValue: 0x1F)
    public static let digit3 = KeyUsage(rawValue: 0x20), digit4 = KeyUsage(rawValue: 0x21)
    public static let digit5 = KeyUsage(rawValue: 0x22), digit6 = KeyUsage(rawValue: 0x23)
    public static let digit7 = KeyUsage(rawValue: 0x24), digit8 = KeyUsage(rawValue: 0x25)
    public static let digit9 = KeyUsage(rawValue: 0x26), digit0 = KeyUsage(rawValue: 0x27)

    public static let returnKey = KeyUsage(rawValue: 0x28)
    public static let escape = KeyUsage(rawValue: 0x29)
    /// "Delete (Backspace)".
    public static let backspace = KeyUsage(rawValue: 0x2A)
    public static let tab = KeyUsage(rawValue: 0x2B)
    public static let space = KeyUsage(rawValue: 0x2C)
    /// US `-_`, JIS `-=`.
    public static let minus = KeyUsage(rawValue: 0x2D)
    /// US `=+`, JIS `^~`.
    public static let equal = KeyUsage(rawValue: 0x2E)
    /// US `[{`, JIS `@``.
    public static let leftBracket = KeyUsage(rawValue: 0x2F)
    /// US `]}`, JIS `[{`.
    public static let rightBracket = KeyUsage(rawValue: 0x30)
    /// US `\|`, JIS `]}` (hosts treat it like the JIS `]` key; see KeyMap).
    public static let backslash = KeyUsage(rawValue: 0x31)
    /// Non-US `#~` (ISO key left of Return).
    public static let nonUSHash = KeyUsage(rawValue: 0x32)
    /// US `;:`, JIS `;+`.
    public static let semicolon = KeyUsage(rawValue: 0x33)
    /// US `'"`, JIS `:*`.
    public static let quote = KeyUsage(rawValue: 0x34)
    /// US `` `~ ``. On JIS this is the 半角/全角 key (toggles the IME on Windows).
    public static let grave = KeyUsage(rawValue: 0x35)
    public static let comma = KeyUsage(rawValue: 0x36)
    public static let period = KeyUsage(rawValue: 0x37)
    public static let slash = KeyUsage(rawValue: 0x38)
    public static let capsLock = KeyUsage(rawValue: 0x39)

    // F1–F12 0x3A–0x45
    public static let f1 = KeyUsage(rawValue: 0x3A), f2 = KeyUsage(rawValue: 0x3B), f3 = KeyUsage(rawValue: 0x3C)
    public static let f4 = KeyUsage(rawValue: 0x3D), f5 = KeyUsage(rawValue: 0x3E), f6 = KeyUsage(rawValue: 0x3F)
    public static let f7 = KeyUsage(rawValue: 0x40), f8 = KeyUsage(rawValue: 0x41), f9 = KeyUsage(rawValue: 0x42)
    public static let f10 = KeyUsage(rawValue: 0x43), f11 = KeyUsage(rawValue: 0x44), f12 = KeyUsage(rawValue: 0x45)

    public static let printScreen = KeyUsage(rawValue: 0x46)
    public static let scrollLock = KeyUsage(rawValue: 0x47)
    public static let pause = KeyUsage(rawValue: 0x48)
    public static let insert = KeyUsage(rawValue: 0x49)
    public static let home = KeyUsage(rawValue: 0x4A)
    public static let pageUp = KeyUsage(rawValue: 0x4B)
    /// "Delete Forward".
    public static let deleteForward = KeyUsage(rawValue: 0x4C)
    public static let end = KeyUsage(rawValue: 0x4D)
    public static let pageDown = KeyUsage(rawValue: 0x4E)
    public static let rightArrow = KeyUsage(rawValue: 0x4F)
    public static let leftArrow = KeyUsage(rawValue: 0x50)
    public static let downArrow = KeyUsage(rawValue: 0x51)
    public static let upArrow = KeyUsage(rawValue: 0x52)
    public static let numLock = KeyUsage(rawValue: 0x53)
    /// ISO key between left Shift and Z.
    public static let nonUSBackslash = KeyUsage(rawValue: 0x64)
    public static let application = KeyUsage(rawValue: 0x65)

    // F13–F24 0x68–0x73
    public static let f13 = KeyUsage(rawValue: 0x68), f14 = KeyUsage(rawValue: 0x69), f15 = KeyUsage(rawValue: 0x6A)
    public static let f16 = KeyUsage(rawValue: 0x6B), f17 = KeyUsage(rawValue: 0x6C), f18 = KeyUsage(rawValue: 0x6D)
    public static let f19 = KeyUsage(rawValue: 0x6E), f20 = KeyUsage(rawValue: 0x6F), f21 = KeyUsage(rawValue: 0x70)
    public static let f22 = KeyUsage(rawValue: 0x71), f23 = KeyUsage(rawValue: 0x72), f24 = KeyUsage(rawValue: 0x73)

    /// International1: JIS `ろ` key (`\_` on Windows, `_` on macOS).
    public static let international1 = KeyUsage(rawValue: 0x87)
    /// International2: JIS カタカナ/ひらがな key.
    public static let international2 = KeyUsage(rawValue: 0x88)
    /// International3: JIS `¥` key (`\|` on Windows, `¥|` on macOS, Option gives `\`).
    public static let international3 = KeyUsage(rawValue: 0x89)
    /// International4: JIS 変換 key.
    public static let international4 = KeyUsage(rawValue: 0x8A)
    /// International5: JIS 無変換 key.
    public static let international5 = KeyUsage(rawValue: 0x8B)
    /// LANG1: かな key (Mac JIS), Hangul/English toggle on Korean keyboards.
    public static let lang1 = KeyUsage(rawValue: 0x90)
    /// LANG2: 英数 key (Mac JIS), Hanja on Korean keyboards.
    public static let lang2 = KeyUsage(rawValue: 0x91)

    // Modifiers 0xE0–0xE7 (sent as bits of the modifier byte, never in the key array)
    public static let leftControl = KeyUsage(rawValue: 0xE0)
    public static let leftShift = KeyUsage(rawValue: 0xE1)
    /// Left Alt / Option.
    public static let leftAlt = KeyUsage(rawValue: 0xE2)
    /// Left GUI / Command / Windows.
    public static let leftGUI = KeyUsage(rawValue: 0xE3)
    public static let rightControl = KeyUsage(rawValue: 0xE4)
    public static let rightShift = KeyUsage(rawValue: 0xE5)
    public static let rightAlt = KeyUsage(rawValue: 0xE6)
    public static let rightGUI = KeyUsage(rawValue: 0xE7)

    /// The highest usage the key array can carry (descriptor logical maximum).
    public static let maximum = KeyUsage(rawValue: 0xE7)

    /// F1–F24 by number; nil outside 1...24.
    public static func function(_ n: Int) -> KeyUsage? {
        switch n {
        case 1...12: return KeyUsage(rawValue: UInt8(0x3A + n - 1))
        case 13...24: return KeyUsage(rawValue: UInt8(0x68 + n - 13))
        default: return nil
        }
    }

    /// True for 0xE0–0xE7.
    public var isModifier: Bool { (0xE0...0xE7).contains(rawValue) }

    /// The modifier-byte bit for a modifier usage; nil for other keys.
    public var modifierFlag: KeyModifiers? {
        isModifier ? KeyModifiers(rawValue: 1 << (rawValue - 0xE0)) : nil
    }
}
