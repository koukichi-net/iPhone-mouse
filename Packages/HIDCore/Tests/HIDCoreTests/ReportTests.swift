import Testing
@testable import HIDCore

@Suite("Reports")
struct ReportTests {
    // MARK: Mouse

    @Test func mouseEncodingLittleEndianAndSigned() {
        let r = MouseReport(buttons: [.left, .forward], x: 0x1234, y: -2, wheel: -1, pan: 5)
        #expect(r.bytes == [0x11, 0x34, 0x12, 0xFE, 0xFF, 0xFF, 0x05])
        #expect(r.bytes.count == MouseReport.byteCount)
        #expect(MouseReport.idle.bytes == [0, 0, 0, 0, 0, 0, 0])
    }

    @Test func mouseClampsToDescriptorRanges() {
        let r = MouseReport(x: 100_000, y: -100_000, wheel: 500, pan: -500)
        #expect(r.x == 32767 && r.y == -32767 && r.wheel == 127 && r.pan == -127)
        #expect(r.bytes == [0x00, 0xFF, 0x7F, 0x01, 0x80, 0x7F, 0x81])
        let edge = MouseReport(x: -32768, wheel: -128)
        #expect(edge.x == -32767 && edge.wheel == -127)
        var m = MouseReport()
        m.x = 40000
        m.pan = -200
        #expect(m.x == 32767 && m.pan == -127)
    }

    @Test func mouseButtonsMaskToFiveBits() {
        #expect(MouseButtons(rawValue: 0xFF).rawValue == 0x1F)
        #expect(MouseReport(buttons: [.right, .middle, .back]).bytes[0] == 0x0E)
    }

    // MARK: Keyboard

    @Test func keyboardEncoding() {
        let r = KeyboardReport(modifiers: [.leftShift, .rightGUI], keys: [.a, .digit1])
        #expect(r.bytes == [0x82, 0x00, 0x04, 0x1E, 0x00, 0x00, 0x00, 0x00])
        #expect(KeyboardReport.empty.bytes == [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(KeyboardReport(.f13).bytes == [0, 0, 0x68, 0, 0, 0, 0, 0])
    }

    @Test func keyboardFoldsModifierUsagesAndDropsDuplicates() {
        let r = KeyboardReport(keys: [.leftControl, .b, .none, .b, .rightAlt, .c])
        #expect(r.modifiers == [.leftControl, .rightAlt])
        #expect(r.keys == [.b, .c])
        #expect(r.bytes == [0x41, 0x00, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00])
    }

    @Test func keyboardSixKeysFitSevenRollOver() {
        let six: [KeyUsage] = [.a, .b, .c, .d, .e, .f]
        let ok = KeyboardReport(modifiers: .shift, keys: six)
        #expect(!ok.isRollOver)
        #expect(ok.bytes == [0x02, 0x00, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])

        let over = KeyboardReport(modifiers: .shift, keys: six + [.g])
        #expect(over.isRollOver)
        #expect(over.keys.isEmpty)
        #expect(over.bytes == [0x02, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01])

        // Seven entries but one is a modifier: still fits.
        #expect(!KeyboardReport(keys: six + [.leftShift]).isRollOver)
    }

    @Test func keyUsageHelpers() {
        #expect(KeyUsage.function(1) == .f1)
        #expect(KeyUsage.function(12) == .f12)
        #expect(KeyUsage.function(13) == .f13)
        #expect(KeyUsage.function(20) == .f20)
        #expect(KeyUsage.function(24) == .f24)
        #expect(KeyUsage.function(0) == nil && KeyUsage.function(25) == nil)
        #expect(KeyUsage.f20.rawValue == 0x6F)
        #expect(KeyUsage.international1.rawValue == 0x87 && KeyUsage.international3.rawValue == 0x89)
        #expect(KeyUsage.lang1.rawValue == 0x90 && KeyUsage.lang2.rawValue == 0x91)
        #expect(KeyUsage.capsLock.rawValue == 0x39)
        #expect(KeyUsage.rightGUI.modifierFlag == .rightGUI)
        #expect(KeyUsage.a.modifierFlag == nil)
        #expect(KeyModifiers([.leftAlt, .rightShift]).usages == [.leftAlt, .rightShift])
    }

    @Test func ledDecoding() {
        #expect(KeyboardLEDs(outputReportValue: [0x02]) == .capsLock)
        #expect(KeyboardLEDs(outputReportValue: [0xFF]) == [.numLock, .capsLock, .scrollLock, .compose, .kana])
        #expect(KeyboardLEDs(outputReportValue: [0x13])?.contains(.kana) == true)
        #expect(KeyboardLEDs(outputReportValue: [UInt8]()) == nil)
        #expect(KeyboardLEDs(outputReportValue: [0x00]) == [])
    }

    // MARK: Consumer

    @Test func consumerEncoding() {
        #expect(ConsumerReport(.playPause).bytes == [0xCD, 0x00])
        #expect(ConsumerReport(.acHome).bytes == [0x23, 0x02])
        #expect(ConsumerReport.released.bytes == [0x00, 0x00])
        #expect(ConsumerUsage(rawValue: 0x3FF) != nil)
        #expect(ConsumerUsage(rawValue: 0x400) == nil)
    }
}
