import Foundation

// Hand-written HID report descriptors for the M0 probe (design §6). Not shared with Packages/HIDCore.

enum Layout: String { case A, B }

enum ReportKind: String {
    case mouse, keyboard, led, consumer
}

/// One Report characteristic (2A4D) and its Report Reference (2908) = [reportID, type].
struct ReportSpec {
    let kind: ReportKind
    let reportID: UInt8          // 0 in layout B (no report IDs in the map)
    let type: UInt8              // 1 = input, 2 = output
    let length: Int
}

/// One HID service instance (1812).
struct HIDServiceSpec {
    let name: String
    let reportMap: [UInt8]
    let reports: [ReportSpec]
}

enum Descriptors {
    static let hidInformation: [UInt8] = [0x11, 0x01, 0x00, 0x02]   // bcdHID 1.11, country 0, NormallyConnectable
    /// PnP ID: vendor ID source 2 (USB-IF), vendor 0xFFFF, product 0x0001, version 0x0100 (all little-endian).
    static let pnpID: [UInt8] = [0x02, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x01]

    /// Mouse, 7 bytes: 5 buttons + 3 pad bits, X int16, Y int16, wheel int8, AC Pan int8.
    static func mouse(reportID: UInt8?) -> [UInt8] {
        var d: [UInt8] = [
            0x05, 0x01,             // Usage Page (Generic Desktop)
            0x09, 0x02,             // Usage (Mouse)
            0xA1, 0x01,             // Collection (Application)
        ]
        if let id = reportID { d += [0x85, id] }   // Report ID
        d += [
            0x09, 0x01,             //   Usage (Pointer)
            0xA1, 0x00,             //   Collection (Physical)
            0x05, 0x09,             //     Usage Page (Button)
            0x19, 0x01,             //     Usage Minimum (1)
            0x29, 0x05,             //     Usage Maximum (5)
            0x15, 0x00,             //     Logical Minimum (0)
            0x25, 0x01,             //     Logical Maximum (1)
            0x95, 0x05,             //     Report Count (5)
            0x75, 0x01,             //     Report Size (1)
            0x81, 0x02,             //     Input (Data,Var,Abs)
            0x95, 0x01,             //     Report Count (1)
            0x75, 0x03,             //     Report Size (3)
            0x81, 0x03,             //     Input (Const,Var,Abs)  padding
            0x05, 0x01,             //     Usage Page (Generic Desktop)
            0x09, 0x30,             //     Usage (X)
            0x09, 0x31,             //     Usage (Y)
            0x16, 0x01, 0x80,       //     Logical Minimum (-32767)
            0x26, 0xFF, 0x7F,       //     Logical Maximum (32767)
            0x75, 0x10,             //     Report Size (16)
            0x95, 0x02,             //     Report Count (2)
            0x81, 0x06,             //     Input (Data,Var,Rel)
            0x09, 0x38,             //     Usage (Wheel)
            0x15, 0x81,             //     Logical Minimum (-127)
            0x25, 0x7F,             //     Logical Maximum (127)
            0x75, 0x08,             //     Report Size (8)
            0x95, 0x01,             //     Report Count (1)
            0x81, 0x06,             //     Input (Data,Var,Rel)
            0x05, 0x0C,             //     Usage Page (Consumer)
            0x0A, 0x38, 0x02,       //     Usage (AC Pan)
            0x15, 0x81,             //     Logical Minimum (-127)
            0x25, 0x7F,             //     Logical Maximum (127)
            0x75, 0x08,             //     Report Size (8)
            0x95, 0x01,             //     Report Count (1)
            0x81, 0x06,             //     Input (Data,Var,Rel)
            0xC0,                   //   End Collection
            0xC0,                   // End Collection
        ]
        return d
    }

    /// Keyboard: input 8 bytes (boot layout: modifiers, reserved, 6 keys), output 1 byte (5 LEDs + 3 pad bits).
    static func keyboard(reportID: UInt8?) -> [UInt8] {
        var d: [UInt8] = [
            0x05, 0x01,             // Usage Page (Generic Desktop)
            0x09, 0x06,             // Usage (Keyboard)
            0xA1, 0x01,             // Collection (Application)
        ]
        if let id = reportID { d += [0x85, id] }   // Report ID
        d += [
            0x05, 0x07,             //   Usage Page (Keyboard/Keypad)
            0x19, 0xE0,             //   Usage Minimum (Left Control)
            0x29, 0xE7,             //   Usage Maximum (Right GUI)
            0x15, 0x00,             //   Logical Minimum (0)
            0x25, 0x01,             //   Logical Maximum (1)
            0x75, 0x01,             //   Report Size (1)
            0x95, 0x08,             //   Report Count (8)
            0x81, 0x02,             //   Input (Data,Var,Abs)  modifiers
            0x95, 0x01,             //   Report Count (1)
            0x75, 0x08,             //   Report Size (8)
            0x81, 0x01,             //   Input (Const,Array,Abs)  reserved
            0x05, 0x08,             //   Usage Page (LEDs)
            0x19, 0x01,             //   Usage Minimum (Num Lock)
            0x29, 0x05,             //   Usage Maximum (Kana)
            0x95, 0x05,             //   Report Count (5)
            0x75, 0x01,             //   Report Size (1)
            0x91, 0x02,             //   Output (Data,Var,Abs)  LEDs
            0x95, 0x01,             //   Report Count (1)
            0x75, 0x03,             //   Report Size (3)
            0x91, 0x01,             //   Output (Const,Array,Abs)  padding
            0x05, 0x07,             //   Usage Page (Keyboard/Keypad)
            0x19, 0x00,             //   Usage Minimum (0)
            0x29, 0xE7,             //   Usage Maximum (0xE7)
            0x15, 0x00,             //   Logical Minimum (0)
            0x26, 0xE7, 0x00,       //   Logical Maximum (0xE7)
            0x95, 0x06,             //   Report Count (6)
            0x75, 0x08,             //   Report Size (8)
            0x81, 0x00,             //   Input (Data,Array,Abs)  key codes
            0xC0,                   // End Collection
        ]
        return d
    }

    /// Consumer control: one 16-bit usage.
    static func consumer(reportID: UInt8?) -> [UInt8] {
        var d: [UInt8] = [
            0x05, 0x0C,             // Usage Page (Consumer)
            0x09, 0x01,             // Usage (Consumer Control)
            0xA1, 0x01,             // Collection (Application)
        ]
        if let id = reportID { d += [0x85, id] }   // Report ID
        d += [
            0x15, 0x00,             //   Logical Minimum (0)
            0x26, 0xFF, 0x03,       //   Logical Maximum (0x3FF)
            0x19, 0x00,             //   Usage Minimum (0)
            0x2A, 0xFF, 0x03,       //   Usage Maximum (0x3FF)
            0x75, 0x10,             //   Report Size (16)
            0x95, 0x01,             //   Report Count (1)
            0x81, 0x00,             //   Input (Data,Array,Abs)
            0xC0,                   // End Collection
        ]
        return d
    }

    static func services(for layout: Layout) -> [HIDServiceSpec] {
        switch layout {
        case .A:
            return [HIDServiceSpec(
                name: "hid(A)",
                reportMap: mouse(reportID: 1) + keyboard(reportID: 2) + consumer(reportID: 3),
                reports: [
                    ReportSpec(kind: .mouse, reportID: 1, type: 1, length: 7),
                    ReportSpec(kind: .keyboard, reportID: 2, type: 1, length: 8),
                    ReportSpec(kind: .led, reportID: 2, type: 2, length: 1),
                    ReportSpec(kind: .consumer, reportID: 3, type: 1, length: 2),
                ])]
        case .B:
            return [
                HIDServiceSpec(name: "hid(B-mouse)", reportMap: mouse(reportID: nil),
                               reports: [ReportSpec(kind: .mouse, reportID: 0, type: 1, length: 7)]),
                HIDServiceSpec(name: "hid(B-keyboard)", reportMap: keyboard(reportID: nil),
                               reports: [ReportSpec(kind: .keyboard, reportID: 0, type: 1, length: 8),
                                         ReportSpec(kind: .led, reportID: 0, type: 2, length: 1)]),
            ]
        }
    }
}

func hexString(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }
func hexString(_ b: [UInt8]) -> String { hexString(Data(b)) }
