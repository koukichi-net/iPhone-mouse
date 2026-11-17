import Foundation

// Report value types (design §6). `bytes` is the HOGP Report characteristic value,
// which never includes the report ID (the ID is carried by the 0x2908 descriptor).

// MARK: - Report IDs and kinds

/// Report IDs used by the composite (plan A) descriptor. Plan B uses no IDs (Report
/// Reference ID 0).
public enum ReportID {
    public static let mouse: UInt8 = 1
    public static let keyboard: UInt8 = 2
    public static let consumer: UInt8 = 3
}

/// Which report a value belongs to. The BLE layer uses it to pick the characteristic.
public enum ReportKind: String, Sendable, Hashable, CaseIterable {
    case mouse
    case keyboard
    case consumer

    /// The plan A report ID for this kind.
    public var compositeReportID: UInt8 {
        switch self {
        case .mouse: ReportID.mouse
        case .keyboard: ReportID.keyboard
        case .consumer: ReportID.consumer
        }
    }

    /// Byte length of the input report value.
    public var inputByteCount: Int {
        switch self {
        case .mouse: MouseReport.byteCount
        case .keyboard: KeyboardReport.byteCount
        case .consumer: ConsumerReport.byteCount
        }
    }
}

// MARK: - Mouse

/// Mouse buttons 1–5 (bits 0–4 of the first mouse report byte).
public struct MouseButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x1F }

    public static let left = MouseButtons(rawValue: 1 << 0)
    public static let right = MouseButtons(rawValue: 1 << 1)
    public static let middle = MouseButtons(rawValue: 1 << 2)
    public static let back = MouseButtons(rawValue: 1 << 3)
    public static let forward = MouseButtons(rawValue: 1 << 4)
}

/// Mouse input report, 7 bytes:
/// `[buttons, xLo, xHi, yLo, yHi, wheel, pan]`.
///
/// Sign conventions (HID): +x right, +y down, +wheel = scroll up (wheel rolled away from
/// the user), +pan = scroll right. The host may invert scrolling ("natural scrolling").
///
/// Values are clamped to the descriptor's logical ranges on construction and on
/// assignment: x/y to -32767...32767, wheel/pan to -127...127 (the symmetric ranges keep
/// -32768 / -128 out of the report).
public struct MouseReport: Sendable, Hashable {
    public static let byteCount = 7
    /// Logical range of X and Y (descriptor Logical Minimum/Maximum).
    public static let axisRange: ClosedRange<Int> = -32767...32767
    /// Logical range of Wheel and AC Pan.
    public static let scrollRange: ClosedRange<Int> = -127...127

    public var buttons: MouseButtons
    public var x: Int { didSet { x = x.clamped(to: Self.axisRange) } }
    public var y: Int { didSet { y = y.clamped(to: Self.axisRange) } }
    public var wheel: Int { didSet { wheel = wheel.clamped(to: Self.scrollRange) } }
    public var pan: Int { didSet { pan = pan.clamped(to: Self.scrollRange) } }

    public init(buttons: MouseButtons = [], x: Int = 0, y: Int = 0, wheel: Int = 0, pan: Int = 0) {
        self.buttons = buttons
        self.x = x.clamped(to: Self.axisRange)
        self.y = y.clamped(to: Self.axisRange)
        self.wheel = wheel.clamped(to: Self.scrollRange)
        self.pan = pan.clamped(to: Self.scrollRange)
    }

    /// No buttons, no motion. Sent as the baseline after a subscription (design §5).
    public static let idle = MouseReport()

    /// True when the report carries no motion and no scroll.
    public var hasNoMotion: Bool { x == 0 && y == 0 && wheel == 0 && pan == 0 }

    public var bytes: [UInt8] {
        let x16 = UInt16(bitPattern: Int16(x)), y16 = UInt16(bitPattern: Int16(y))
        return [
            buttons.rawValue,
            UInt8(x16 & 0xFF), UInt8(x16 >> 8),
            UInt8(y16 & 0xFF), UInt8(y16 >> 8),
            UInt8(bitPattern: Int8(wheel)),
            UInt8(bitPattern: Int8(pan)),
        ]
    }
}

// MARK: - Keyboard

/// The modifier byte of the keyboard report (usages 0xE0–0xE7 as bits 0–7).
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftControl = KeyModifiers(rawValue: 1 << 0)
    public static let leftShift = KeyModifiers(rawValue: 1 << 1)
    /// Left Alt / Option.
    public static let leftAlt = KeyModifiers(rawValue: 1 << 2)
    /// Left GUI / Command / Windows.
    public static let leftGUI = KeyModifiers(rawValue: 1 << 3)
    public static let rightControl = KeyModifiers(rawValue: 1 << 4)
    public static let rightShift = KeyModifiers(rawValue: 1 << 5)
    public static let rightAlt = KeyModifiers(rawValue: 1 << 6)
    public static let rightGUI = KeyModifiers(rawValue: 1 << 7)

    // Convenience aliases (left-hand keys).
    public static let control: KeyModifiers = .leftControl
    public static let shift: KeyModifiers = .leftShift
    public static let option: KeyModifiers = .leftAlt
    public static let alt: KeyModifiers = .leftAlt
    public static let command: KeyModifiers = .leftGUI

    /// The modifier usages (0xE0–0xE7) for the set bits, in bit order.
    public var usages: [KeyUsage] {
        (0..<8).compactMap { bit in rawValue & (1 << bit) != 0 ? KeyUsage(rawValue: 0xE0 + UInt8(bit)) : nil }
    }
}

/// Keyboard input report, 8 bytes, boot-keyboard layout:
/// `[modifiers, reserved(0), key1, …, key6]`.
///
/// Key policy (applied by `init`):
/// - Modifier usages (0xE0–0xE7) passed in `keys` are moved into the modifier byte.
/// - `.none` (0x00) entries and duplicates are dropped; the first occurrence keeps its place.
/// - Usages above 0xE7 cannot occur (outside the descriptor range) and are dropped too.
/// - More than six distinct keys put the report in the HID "phantom state": all six slots
///   carry ErrorRollOver (0x01), the modifier byte stays valid, and `isRollOver` is true.
///   Hosts then keep their previous key state until a valid report arrives, which is the
///   behaviour HID 1.11 prescribes; silently dropping keys would make the host see a
///   release of a key that is still held.
public struct KeyboardReport: Sendable, Hashable {
    public static let byteCount = 8
    public static let maxKeys = 6

    public let modifiers: KeyModifiers
    /// Pressed non-modifier keys in slot order (at most 6). Empty when `isRollOver`.
    public let keys: [KeyUsage]
    /// True when more than six keys were requested (phantom state).
    public let isRollOver: Bool

    public init(modifiers: KeyModifiers = [], keys: [KeyUsage] = []) {
        var mods = modifiers
        var unique: [KeyUsage] = []
        for key in keys {
            if let flag = key.modifierFlag {
                mods.insert(flag)
            } else if key != .none, key <= .maximum, !unique.contains(key) {
                unique.append(key)
            }
        }
        self.modifiers = mods
        if unique.count > Self.maxKeys {
            self.keys = []
            self.isRollOver = true
        } else {
            self.keys = unique
            self.isRollOver = false
        }
    }

    /// Convenience for a single key with modifiers.
    public init(_ key: KeyUsage, modifiers: KeyModifiers = []) {
        self.init(modifiers: modifiers, keys: [key])
    }

    /// All keys released.
    public static let empty = KeyboardReport()

    public var bytes: [UInt8] {
        var out: [UInt8] = [modifiers.rawValue, 0x00]
        if isRollOver {
            out += [UInt8](repeating: KeyUsage.errorRollOver.rawValue, count: Self.maxKeys)
        } else {
            out += keys.map(\.rawValue)
            out += [UInt8](repeating: 0, count: Self.maxKeys - keys.count)
        }
        return out
    }
}

/// Keyboard LED output report (1 byte, written by the host): bits 0–4 =
/// Num Lock, Caps Lock, Scroll Lock, Compose, Kana; bits 5–7 are padding and ignored.
public struct KeyboardLEDs: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x1F }

    public static let numLock = KeyboardLEDs(rawValue: 1 << 0)
    public static let capsLock = KeyboardLEDs(rawValue: 1 << 1)
    public static let scrollLock = KeyboardLEDs(rawValue: 1 << 2)
    public static let compose = KeyboardLEDs(rawValue: 1 << 3)
    public static let kana = KeyboardLEDs(rawValue: 1 << 4)

    /// Decodes the value the host wrote to the output Report characteristic.
    /// Returns nil for an empty write. Only the first byte is used (HOGP values carry no
    /// report ID; a longer write is not expected and its extra bytes are ignored).
    public init?(outputReportValue value: some Collection<UInt8>) {
        guard let first = value.first else { return nil }
        self.init(rawValue: first)
    }

    /// Byte length of the LED output report value.
    public static let byteCount = 1
}

// MARK: - Consumer

/// A Consumer page (0x0C) usage that fits the descriptor's 0x000–0x3FF range.
public struct ConsumerUsage: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public static let maximumRawValue: UInt16 = 0x03FF

    public let rawValue: UInt16
    /// Returns nil for usages above 0x03FF (outside the descriptor's logical range).
    public init?(rawValue: UInt16) {
        guard rawValue <= Self.maximumRawValue else { return nil }
        self.rawValue = rawValue
    }
    private init(checked rawValue: UInt16) { self.rawValue = rawValue }

    public var description: String { String(format: "0x%03X", rawValue) }

    /// "Unassigned": no key pressed.
    public static let none = ConsumerUsage(checked: 0x000)
    public static let displayBrightnessIncrement = ConsumerUsage(checked: 0x06F)
    public static let displayBrightnessDecrement = ConsumerUsage(checked: 0x070)
    public static let fastForward = ConsumerUsage(checked: 0x0B3)
    public static let rewind = ConsumerUsage(checked: 0x0B4)
    public static let scanNextTrack = ConsumerUsage(checked: 0x0B5)
    public static let scanPreviousTrack = ConsumerUsage(checked: 0x0B6)
    public static let stop = ConsumerUsage(checked: 0x0B7)
    public static let eject = ConsumerUsage(checked: 0x0B8)
    public static let playPause = ConsumerUsage(checked: 0x0CD)
    public static let mute = ConsumerUsage(checked: 0x0E2)
    public static let volumeIncrement = ConsumerUsage(checked: 0x0E9)
    public static let volumeDecrement = ConsumerUsage(checked: 0x0EA)
    public static let acSearch = ConsumerUsage(checked: 0x221)
    public static let acHome = ConsumerUsage(checked: 0x223)
    public static let acBack = ConsumerUsage(checked: 0x224)
    public static let acForward = ConsumerUsage(checked: 0x225)
}

/// Consumer control input report, 2 bytes: one 16-bit usage, little-endian.
/// A press is a report with the usage; the release is `ConsumerReport.released`.
public struct ConsumerReport: Sendable, Hashable {
    public static let byteCount = 2

    public var usage: ConsumerUsage

    public init(_ usage: ConsumerUsage = .none) { self.usage = usage }

    public static let released = ConsumerReport(.none)

    public var bytes: [UInt8] { [UInt8(usage.rawValue & 0xFF), UInt8(usage.rawValue >> 8)] }
}

// MARK: - Helpers

extension Comparable {

    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
