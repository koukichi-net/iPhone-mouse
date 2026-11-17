import Testing
@testable import HIDCore

// Expected bytes typed by hand from design §6 and HID 1.11 / HUT, independently of the
// builder. Each line is one item.

let expectedMouseBody: [UInt8] = [
    0x09, 0x01,             //   Usage (Pointer)
    0xA1, 0x00,             //   Collection (Physical)
    0x05, 0x09,             //     Usage Page (Button)
    0x19, 0x01,             //     Usage Minimum (1)
    0x29, 0x05,             //     Usage Maximum (5)
    0x15, 0x00,             //     Logical Minimum (0)
    0x25, 0x01,             //     Logical Maximum (1)
    0x75, 0x01,             //     Report Size (1)
    0x95, 0x05,             //     Report Count (5)
    0x81, 0x02,             //     Input (Data, Var, Abs)      buttons
    0x75, 0x03,             //     Report Size (3)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x01,             //     Input (Const)               padding
    0x05, 0x01,             //     Usage Page (Generic Desktop)
    0x09, 0x30,             //     Usage (X)
    0x09, 0x31,             //     Usage (Y)
    0x16, 0x01, 0x80,       //     Logical Minimum (-32767)
    0x26, 0xFF, 0x7F,       //     Logical Maximum (32767)
    0x75, 0x10,             //     Report Size (16)
    0x95, 0x02,             //     Report Count (2)
    0x81, 0x06,             //     Input (Data, Var, Rel)      X, Y
    0x09, 0x38,             //     Usage (Wheel)
    0x15, 0x81,             //     Logical Minimum (-127)
    0x25, 0x7F,             //     Logical Maximum (127)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x06,             //     Input (Data, Var, Rel)      wheel
    0x05, 0x0C,             //     Usage Page (Consumer)
    0x0A, 0x38, 0x02,       //     Usage (AC Pan)
    0x81, 0x06,             //     Input (Data, Var, Rel)      pan
    0xC0,                   //   End Collection
    0xC0,                   // End Collection
]

let expectedKeyboardBody: [UInt8] = [
    0x05, 0x07,             //   Usage Page (Keyboard/Keypad)
    0x19, 0xE0,             //   Usage Minimum (Left Control)
    0x29, 0xE7,             //   Usage Maximum (Right GUI)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x01,             //   Logical Maximum (1)
    0x75, 0x01,             //   Report Size (1)
    0x95, 0x08,             //   Report Count (8)
    0x81, 0x02,             //   Input (Data, Var, Abs)        modifiers
    0x75, 0x08,             //   Report Size (8)
    0x95, 0x01,             //   Report Count (1)
    0x81, 0x01,             //   Input (Const)                 reserved
    0x05, 0x08,             //   Usage Page (LEDs)
    0x19, 0x01,             //   Usage Minimum (Num Lock)
    0x29, 0x05,             //   Usage Maximum (Kana)
    0x75, 0x01,             //   Report Size (1)
    0x95, 0x05,             //   Report Count (5)
    0x91, 0x02,             //   Output (Data, Var, Abs)       LEDs
    0x75, 0x03,             //   Report Size (3)
    0x95, 0x01,             //   Report Count (1)
    0x91, 0x01,             //   Output (Const)                LED padding
    0x05, 0x07,             //   Usage Page (Keyboard/Keypad)
    0x19, 0x00,             //   Usage Minimum (0)
    0x29, 0xE7,             //   Usage Maximum (0xE7)
    0x15, 0x00,             //   Logical Minimum (0)
    0x26, 0xE7, 0x00,       //   Logical Maximum (0xE7)        2 bytes: 1-byte E7 would be -25
    0x75, 0x08,             //   Report Size (8)
    0x95, 0x06,             //   Report Count (6)
    0x81, 0x00,             //   Input (Data, Array, Abs)      key codes
    0xC0,                   // End Collection
]

let expectedConsumerBody: [UInt8] = [
    0x19, 0x00,             //   Usage Minimum (0)
    0x2A, 0xFF, 0x03,       //   Usage Maximum (0x3FF)
    0x15, 0x00,             //   Logical Minimum (0)
    0x26, 0xFF, 0x03,       //   Logical Maximum (0x3FF)
    0x75, 0x10,             //   Report Size (16)
    0x95, 0x01,             //   Report Count (1)
    0x81, 0x00,             //   Input (Data, Array, Abs)
    0xC0,                   // End Collection
]

let mouseHeader: [UInt8] = [0x05, 0x01, 0x09, 0x02, 0xA1, 0x01]     // Generic Desktop / Mouse / Application
let keyboardHeader: [UInt8] = [0x05, 0x01, 0x09, 0x06, 0xA1, 0x01]  // Generic Desktop / Keyboard / Application
let consumerHeader: [UInt8] = [0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01]  // Consumer / Consumer Control / Application

let expectedComposite: [UInt8] =
    mouseHeader + [0x85, 0x01] + expectedMouseBody
    + keyboardHeader + [0x85, 0x02] + expectedKeyboardBody
    + consumerHeader + [0x85, 0x03] + expectedConsumerBody

@Suite("ReportDescriptor")
struct DescriptorTests {
    @Test func compositeBytesMatchSpec() {
        #expect(ReportDescriptor.composite.bytes == expectedComposite)
    }

    @Test func standaloneBytesMatchSpec() {
        #expect(ReportDescriptor.standalone(.mouse).bytes == mouseHeader + expectedMouseBody)
        #expect(ReportDescriptor.standalone(.keyboard).bytes == keyboardHeader + expectedKeyboardBody)
        #expect(ReportDescriptor.standalone(.consumer).bytes == consumerHeader + expectedConsumerBody)
    }

    @Test func compositeReportLengthsMatchStructs() {
        let w = DescriptorWalker.walk(ReportDescriptor.composite.bytes)
        #expect(w.errors.isEmpty)
        #expect(w.finalDepth == 0)
        #expect(w.usesReportIDs)
        #expect(!w.mainItemWithoutIDInIDDescriptor)
        #expect(w.bits(.input, id: ReportID.mouse) == UInt32(MouseReport.byteCount * 8))
        #expect(w.bits(.input, id: ReportID.keyboard) == UInt32(KeyboardReport.byteCount * 8))
        #expect(w.bits(.output, id: ReportID.keyboard) == UInt32(KeyboardLEDs.byteCount * 8))
        #expect(w.bits(.input, id: ReportID.consumer) == UInt32(ConsumerReport.byteCount * 8))
        #expect(w.reports == ["input-1", "input-2", "output-2", "input-3"])
        #expect(w.fields.allSatisfy { $0.kind != .feature })
    }

    @Test(arguments: ReportKind.allCases)
    func standaloneReportLengthsMatchStructs(kind: ReportKind) {
        let w = DescriptorWalker.walk(ReportDescriptor.standalone(kind).bytes)
        #expect(w.errors.isEmpty)
        #expect(w.finalDepth == 0)
        #expect(!w.usesReportIDs)
        #expect(w.bits(.input, id: 0) == UInt32(kind.inputByteCount * 8))
        #expect(w.bits(.input, id: 0) % 8 == 0)
        if kind == .keyboard {
            #expect(w.bits(.output, id: 0) == 8)
        } else {
            #expect(w.bits(.output, id: 0) == 0)
        }
    }

    @Test func mouseLogicalRangesMatchClamping() {
        let w = DescriptorWalker.walk(ReportDescriptor.standalone(.mouse).bytes)
        let data = w.fields.filter { !$0.isConstant }
        #expect(data.count == 4)
        // buttons
        #expect(data[0].usagePage == 0x09 && data[0].usageMinimum == 1 && data[0].usageMaximum == 5)
        #expect(data[0].bits == 5 && data[0].isVariable && !data[0].isRelative)
        // X, Y
        #expect(data[1].usagePage == 0x01 && data[1].usages == [0x30, 0x31] && data[1].reportSize == 16)
        #expect(data[1].isRelative)
        #expect(data[1].logicalMinimum == Int64(MouseReport.axisRange.lowerBound))
        #expect(data[1].logicalMaximum == Int64(MouseReport.axisRange.upperBound))
        // Wheel
        #expect(data[2].usagePage == 0x01 && data[2].usages == [0x38] && data[2].reportSize == 8 && data[2].isRelative)
        #expect(data[2].logicalMinimum == Int64(MouseReport.scrollRange.lowerBound))
        #expect(data[2].logicalMaximum == Int64(MouseReport.scrollRange.upperBound))
        // AC Pan
        #expect(data[3].usagePage == 0x0C && data[3].usages == [0x238] && data[3].reportSize == 8 && data[3].isRelative)
        #expect(data[3].logicalMinimum == Int64(MouseReport.scrollRange.lowerBound))
        #expect(data[3].logicalMaximum == Int64(MouseReport.scrollRange.upperBound))
    }

    @Test func keyboardAndConsumerRanges() {
        let k = DescriptorWalker.walk(ReportDescriptor.standalone(.keyboard).bytes)
        let keyArray = try! #require(k.fields.last { $0.kind == .input })
        #expect(keyArray.usagePage == 0x07 && !keyArray.isVariable)
        #expect(keyArray.reportCount == UInt32(KeyboardReport.maxKeys))
        #expect(keyArray.logicalMinimum == 0 && keyArray.logicalMaximum == Int64(KeyUsage.maximum.rawValue))
        #expect(keyArray.usageMinimum == 0 && keyArray.usageMaximum == UInt32(KeyUsage.maximum.rawValue))
        let leds = k.fields.filter { $0.kind == .output && !$0.isConstant }
        #expect(leds.count == 1 && leds[0].usagePage == 0x08 && leds[0].usageMaximum == 5 && leds[0].bits == 5)

        let c = DescriptorWalker.walk(ReportDescriptor.standalone(.consumer).bytes)
        let field = try! #require(c.fields.first)
        #expect(field.usagePage == 0x0C && !field.isVariable && field.reportSize == 16)
        #expect(field.logicalMaximum == Int64(ConsumerUsage.maximumRawValue))
        #expect(field.usageMaximum == UInt32(ConsumerUsage.maximumRawValue))
    }

    @Test func itemEncoding() {
        #expect(HIDItem.logicalMaximum(127).bytes == [0x25, 0x7F])
        #expect(HIDItem.logicalMaximum(128).bytes == [0x26, 0x80, 0x00])
        #expect(HIDItem.logicalMinimum(-1).bytes == [0x15, 0xFF])
        #expect(HIDItem.logicalMinimum(-129).bytes == [0x16, 0x7F, 0xFF])
        #expect(HIDItem.logicalMaximum(70000).bytes == [0x27, 0x70, 0x11, 0x01, 0x00])
        #expect(HIDItem.usage(0).bytes == [0x09, 0x00])
        #expect(HIDItem.usage(0x0238).bytes == [0x0A, 0x38, 0x02])
        #expect(HIDItem.usageMaximum(0xFF).bytes == [0x29, 0xFF])
        #expect(HIDItem.endCollection.bytes == [0xC0])
        #expect(HIDItem.collection(.application).bytes == [0xA1, 0x01])
        #expect(HIDItem.output(.constantPadding).bytes == [0x91, 0x01])
        #expect(HIDItem.feature(.dataVariableAbsolute).bytes == [0xB1, 0x02])
    }
}
