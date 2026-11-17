// HID report descriptor short items (HID 1.11 §6.2.2).
//
// Each case is one item. `bytes` gives the prefix byte (tag | type | size) followed by
// the little-endian data. Data uses the smallest of 1, 2 or 4 bytes that holds the value:
// Logical/Physical Minimum and Maximum are signed (so 0xE7 needs 2 bytes: `26 E7 00`),
// everything else is unsigned. Zero-size items are never produced (a value of 0 is
// written as one byte), except End Collection which has no data.

/// Usage pages used by this package (HID Usage Tables).
public enum HIDUsagePage {
    public static let genericDesktop: UInt16 = 0x01
    public static let keyboard: UInt16 = 0x07
    public static let led: UInt16 = 0x08
    public static let button: UInt16 = 0x09
    public static let consumer: UInt16 = 0x0C
}

/// Data/flags of an Input, Output or Feature main item (HID 1.11 §6.2.2.5).
public struct MainItemFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Bit 0: Constant (otherwise Data).
    public static let constant = MainItemFlags(rawValue: 1 << 0)
    /// Bit 1: Variable (otherwise Array).
    public static let variable = MainItemFlags(rawValue: 1 << 1)
    /// Bit 2: Relative (otherwise Absolute).
    public static let relative = MainItemFlags(rawValue: 1 << 2)

    /// Data, Array, Absolute (0x00): key code arrays, consumer usage.
    public static let dataArrayAbsolute: MainItemFlags = []
    /// Data, Variable, Absolute (0x02): buttons, modifier bits, LEDs.
    public static let dataVariableAbsolute: MainItemFlags = [.variable]
    /// Data, Variable, Relative (0x06): pointer deltas, wheel.
    public static let dataVariableRelative: MainItemFlags = [.variable, .relative]
    /// Constant (0x01): padding and reserved fields.
    public static let constantPadding: MainItemFlags = [.constant]
}

/// Collection types (HID 1.11 §6.2.2.6).
public enum HIDCollectionType: UInt8, Sendable, Hashable {
    case physical = 0x00
    case application = 0x01
    case logical = 0x02
}

/// One short item of a report descriptor.
public enum HIDItem: Sendable, Hashable {
    // Main items
    case input(MainItemFlags)
    case output(MainItemFlags)
    case feature(MainItemFlags)
    case collection(HIDCollectionType)
    case endCollection
    // Global items
    case usagePage(UInt16)
    case logicalMinimum(Int32)
    case logicalMaximum(Int32)
    case reportSize(UInt32)
    case reportID(UInt8)
    case reportCount(UInt32)
    // Local items
    case usage(UInt16)
    case usageMinimum(UInt16)
    case usageMaximum(UInt16)

    /// Encoded bytes: prefix followed by data.
    public var bytes: [UInt8] {
        switch self {
        case .input(let f): return Self.unsigned(tag: 0x80, UInt32(f.rawValue))
        case .output(let f): return Self.unsigned(tag: 0x90, UInt32(f.rawValue))
        case .feature(let f): return Self.unsigned(tag: 0xB0, UInt32(f.rawValue))
        case .collection(let t): return Self.unsigned(tag: 0xA0, UInt32(t.rawValue))
        case .endCollection: return [0xC0]
        case .usagePage(let v): return Self.unsigned(tag: 0x04, UInt32(v))
        case .logicalMinimum(let v): return Self.signed(tag: 0x14, v)
        case .logicalMaximum(let v): return Self.signed(tag: 0x24, v)
        case .reportSize(let v): return Self.unsigned(tag: 0x74, v)
        case .reportID(let v): return Self.unsigned(tag: 0x84, UInt32(v))
        case .reportCount(let v): return Self.unsigned(tag: 0x94, v)
        case .usage(let v): return Self.unsigned(tag: 0x08, UInt32(v))
        case .usageMinimum(let v): return Self.unsigned(tag: 0x18, UInt32(v))
        case .usageMaximum(let v): return Self.unsigned(tag: 0x28, UInt32(v))
        }
    }

    /// `tag` is the prefix byte with the size bits (bits 0–1) cleared.
    private static func unsigned(tag: UInt8, _ value: UInt32) -> [UInt8] {
        let size: Int = value <= 0xFF ? 1 : (value <= 0xFFFF ? 2 : 4)
        return encode(tag: tag, bitPattern: value, size: size)
    }

    private static func signed(tag: UInt8, _ value: Int32) -> [UInt8] {
        let size: Int = (-128...127).contains(value) ? 1 : ((-32768...32767).contains(value) ? 2 : 4)
        return encode(tag: tag, bitPattern: UInt32(bitPattern: value), size: size)
    }

    private static func encode(tag: UInt8, bitPattern: UInt32, size: Int) -> [UInt8] {
        let sizeCode: UInt8 = size == 4 ? 3 : UInt8(size)
        var out: [UInt8] = [tag | sizeCode]
        for i in 0..<size { out.append(UInt8(truncatingIfNeeded: bitPattern >> (8 * UInt32(i)))) }
        return out
    }
}
