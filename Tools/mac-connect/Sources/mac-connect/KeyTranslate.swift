import Foundation
import Carbon
import HIDCore

/// What macOS would type for a HID keyboard usage plus modifiers: HID usage → macOS virtual
/// key code → `UCKeyTranslate` over the current keyboard layout with a given keyboard type.
///
/// The usage → virtual key table is the standard one (as macOS maps a USB/BLE keyboard);
/// for ISO keyboard types macOS swaps the keys of usages 0x35 (`) and 0x64 (ISO §), which
/// this applies too (inferred from documented macOS behaviour, not measured here).
enum KeyTranslate {
    /// Keyboard types used by macOS for generic keyboards (as written by Keyboard Setup Assistant).
    static let ansi = 40, iso = 41, jis = 42

    static func typeName(_ type: Int) -> String {
        switch KBGetLayoutType(Int16(type)) {
        case PhysicalKeyboardLayoutType(kKeyboardJIS): return "JIS"
        case PhysicalKeyboardLayoutType(kKeyboardISO): return "ISO"
        case PhysicalKeyboardLayoutType(kKeyboardANSI): return "ANSI"
        default: return "unknown"
        }
    }

    static let usageToVirtualKey: [UInt8: UInt16] = {
        var t: [UInt8: UInt16] = [:]
        let letters: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                 0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        for (i, vk) in letters.enumerated() { t[UInt8(0x04 + i)] = vk }
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]   // 1…9, 0
        for (i, vk) in digits.enumerated() { t[UInt8(0x1E + i)] = vk }
        let rest: [(UInt8, UInt16)] = [
            (0x28, 0x24), (0x29, 0x35), (0x2A, 0x33), (0x2B, 0x30), (0x2C, 0x31), (0x2D, 0x1B), (0x2E, 0x18),
            (0x2F, 0x21), (0x30, 0x1E), (0x31, 0x2A), (0x32, 0x2A), (0x33, 0x29), (0x34, 0x27), (0x35, 0x32),
            (0x36, 0x2B), (0x37, 0x2F), (0x38, 0x2C), (0x39, 0x39),
            (0x3A, 0x7A), (0x3B, 0x78), (0x3C, 0x63), (0x3D, 0x76), (0x3E, 0x60), (0x3F, 0x61),
            (0x40, 0x62), (0x41, 0x64), (0x42, 0x65), (0x43, 0x6D), (0x44, 0x67), (0x45, 0x6F),
            (0x4A, 0x73), (0x4B, 0x74), (0x4C, 0x75), (0x4D, 0x77), (0x4E, 0x79),
            (0x4F, 0x7C), (0x50, 0x7B), (0x51, 0x7D), (0x52, 0x7E),
            (0x64, 0x0A),
            (0x68, 0x69), (0x69, 0x6B), (0x6A, 0x71), (0x6B, 0x6A), (0x6C, 0x40), (0x6D, 0x4F), (0x6E, 0x50), (0x6F, 0x5A),
            (0x87, 0x5E), (0x89, 0x5D), (0x90, 0x68), (0x91, 0x66),
        ]
        for (u, vk) in rest { t[u] = vk }
        return t
    }()

    static func virtualKey(usage: UInt8, keyboardType: Int) -> UInt16? {
        if typeName(keyboardType) == "ISO" {
            if usage == 0x35 { return 0x0A }
            if usage == 0x64 { return 0x32 }
        }
        return usageToVirtualKey[usage]
    }

    /// The current keyboard layout (the one an input method types through).
    struct Layout {
        let id: String
        let data: Data
    }

    static func currentLayout() -> Layout? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID),
              let dataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        return Layout(id: id, data: data)
    }

    /// Characters for one key down (dead keys disabled, so a dead key gives its own char).
    static func characters(layout: Layout, usage: UInt8, modifiers: KeyModifiers, capsLock: Bool = false, keyboardType: Int) -> String? {
        guard let vk = virtualKey(usage: usage, keyboardType: keyboardType) else { return nil }
        var carbon: UInt32 = 0
        if modifiers.contains(.leftShift) || modifiers.contains(.rightShift) { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.leftAlt) || modifiers.contains(.rightAlt) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.leftControl) || modifiers.contains(.rightControl) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.leftGUI) || modifiers.contains(.rightGUI) { carbon |= UInt32(cmdKey) }
        if capsLock { carbon |= UInt32(alphaLock) }
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = layout.data.withUnsafeBytes { raw -> OSStatus in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(ptr, vk, UInt16(kUCKeyActionDown), (carbon >> 8) & 0xFF, UInt32(keyboardType),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
        }
        guard status == noErr else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// Readable form of typed characters.
    static func show(_ s: String?) -> String {
        guard let s else { return "(none)" }
        if s.isEmpty { return "\"\"" }
        return s.unicodeScalars.map { u -> String in
            switch u.value {
            case 0x20: return "␠"
            case 0x00..<0x20, 0x7F: return String(format: "\\u{%02X}", u.value)
            default: return String(u)
            }
        }.joined()
    }
}

/// The keyboard type macOS assigned to a keyboard: `/Library/Preferences/com.apple.keyboardtype.plist`
/// maps "productID-vendorID-countryCode" to a type (loginwindow logs the lookup as
/// `copykeyboardtype, productID:…, vendorID:…, countryCode:…`).
enum KeyboardTypeStore {
    static let path = "/Library/Preferences/com.apple.keyboardtype.plist"

    static func all() -> [String: Int] {
        guard let d = NSDictionary(contentsOfFile: path) as? [String: Any],
              let t = d["keyboardtype"] as? [String: Any] else { return [:] }
        return t.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    static func key(productID: Int, vendorID: Int, countryCode: Int) -> String {
        "\(productID)-\(vendorID)-\(countryCode)"
    }
}
