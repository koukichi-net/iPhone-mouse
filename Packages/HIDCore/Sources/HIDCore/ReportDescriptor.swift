// Report Map (HID report descriptor) for the Report Map characteristic 0x2A4B (design §6).

/// A report descriptor built from typed items.
///
/// - Plan A (`composite`): one descriptor with report IDs 1 (mouse), 2 (keyboard input +
///   LED output) and 3 (consumer control).
/// - Plan B (`mouse(reportID: nil)` etc.): one descriptor per HID service, without report
///   IDs. A descriptor without report IDs can hold only one input report, so plan B needs
///   a separate HID service for consumer control.
public struct ReportDescriptor: Sendable, Hashable {
    public let items: [HIDItem]

    public init(items: [HIDItem]) { self.items = items }

    /// The Report Map characteristic value.
    public var bytes: [UInt8] { items.flatMap(\.bytes) }

    /// Plan A: mouse (ID 1) + keyboard (ID 2) + consumer (ID 3) in one descriptor.
    public static let composite = ReportDescriptor(items:
        mouseItems(reportID: ReportID.mouse)
        + keyboardItems(reportID: ReportID.keyboard)
        + consumerItems(reportID: ReportID.consumer))

    /// Mouse descriptor; `reportID: nil` for plan B.
    public static func mouse(reportID: UInt8?) -> ReportDescriptor {
        ReportDescriptor(items: mouseItems(reportID: reportID))
    }

    /// Keyboard (input + LED output) descriptor; `reportID: nil` for plan B.
    public static func keyboard(reportID: UInt8?) -> ReportDescriptor {
        ReportDescriptor(items: keyboardItems(reportID: reportID))
    }

    /// Consumer control descriptor; `reportID: nil` for plan B.
    public static func consumer(reportID: UInt8?) -> ReportDescriptor {
        ReportDescriptor(items: consumerItems(reportID: reportID))
    }

    /// Descriptor for one report kind, as used by a plan B HID service.
    public static func standalone(_ kind: ReportKind) -> ReportDescriptor {
        switch kind {
        case .mouse: mouse(reportID: nil)
        case .keyboard: keyboard(reportID: nil)
        case .consumer: consumer(reportID: nil)
        }
    }

    // MARK: - Collections

    /// Mouse: 5 buttons + 3 bits padding, X/Y int16 relative, wheel int8, AC Pan int8.
    /// Input report = 56 bits = 7 bytes (`MouseReport`).
    static func mouseItems(reportID: UInt8?) -> [HIDItem] {
        var items: [HIDItem] = [
            .usagePage(HIDUsagePage.genericDesktop),             // Usage Page (Generic Desktop)
            .usage(0x02),                                         // Usage (Mouse)
            .collection(.application),                            // Collection (Application)
        ]
        if let reportID { items.append(.reportID(reportID)) }    //   Report ID
        items += [
            .usage(0x01),                                         //   Usage (Pointer)
            .collection(.physical),                               //   Collection (Physical)
            // Buttons 1–5: 5 × 1 bit
            .usagePage(HIDUsagePage.button),                      //     Usage Page (Button)
            .usageMinimum(0x01),                                  //     Usage Minimum (Button 1)
            .usageMaximum(0x05),                                  //     Usage Maximum (Button 5)
            .logicalMinimum(0),                                   //     Logical Minimum (0)
            .logicalMaximum(1),                                   //     Logical Maximum (1)
            .reportSize(1),                                       //     Report Size (1)
            .reportCount(5),                                      //     Report Count (5)
            .input(.dataVariableAbsolute),                        //     Input (Data, Var, Abs)
            // Padding: 1 × 3 bits
            .reportSize(3),                                       //     Report Size (3)
            .reportCount(1),                                      //     Report Count (1)
            .input(.constantPadding),                             //     Input (Const)
            // X, Y: 2 × 16 bits, relative
            .usagePage(HIDUsagePage.genericDesktop),              //     Usage Page (Generic Desktop)
            .usage(0x30),                                         //     Usage (X)
            .usage(0x31),                                         //     Usage (Y)
            .logicalMinimum(Int32(MouseReport.axisRange.lowerBound)), // Logical Minimum (-32767)
            .logicalMaximum(Int32(MouseReport.axisRange.upperBound)), // Logical Maximum (32767)
            .reportSize(16),                                      //     Report Size (16)
            .reportCount(2),                                      //     Report Count (2)
            .input(.dataVariableRelative),                        //     Input (Data, Var, Rel)
            // Vertical wheel: 1 × 8 bits, relative
            .usage(0x38),                                         //     Usage (Wheel)
            .logicalMinimum(Int32(MouseReport.scrollRange.lowerBound)), // Logical Minimum (-127)
            .logicalMaximum(Int32(MouseReport.scrollRange.upperBound)), // Logical Maximum (127)
            .reportSize(8),                                       //     Report Size (8)
            .reportCount(1),                                      //     Report Count (1)
            .input(.dataVariableRelative),                        //     Input (Data, Var, Rel)
            // Horizontal scroll: AC Pan, 1 × 8 bits, relative (size/count/range carried over)
            .usagePage(HIDUsagePage.consumer),                    //     Usage Page (Consumer)
            .usage(0x0238),                                       //     Usage (AC Pan)
            .input(.dataVariableRelative),                        //     Input (Data, Var, Rel)
            .endCollection,                                       //   End Collection
            .endCollection,                                       // End Collection
        ]
        return items
    }

    /// Keyboard: modifier byte, reserved byte, 6 key codes (0x00–0xE7) = 8 bytes in;
    /// LEDs 5 bits + 3 bits padding = 1 byte out. Boot keyboard field order.
    static func keyboardItems(reportID: UInt8?) -> [HIDItem] {
        var items: [HIDItem] = [
            .usagePage(HIDUsagePage.genericDesktop),             // Usage Page (Generic Desktop)
            .usage(0x06),                                         // Usage (Keyboard)
            .collection(.application),                            // Collection (Application)
        ]
        if let reportID { items.append(.reportID(reportID)) }    //   Report ID
        items += [
            // Modifier byte: usages 0xE0–0xE7 as 8 × 1 bit
            .usagePage(HIDUsagePage.keyboard),                    //   Usage Page (Keyboard/Keypad)
            .usageMinimum(0xE0),                                  //   Usage Minimum (Left Control)
            .usageMaximum(0xE7),                                  //   Usage Maximum (Right GUI)
            .logicalMinimum(0),                                   //   Logical Minimum (0)
            .logicalMaximum(1),                                   //   Logical Maximum (1)
            .reportSize(1),                                       //   Report Size (1)
            .reportCount(8),                                      //   Report Count (8)
            .input(.dataVariableAbsolute),                        //   Input (Data, Var, Abs)
            // Reserved byte
            .reportSize(8),                                       //   Report Size (8)
            .reportCount(1),                                      //   Report Count (1)
            .input(.constantPadding),                             //   Input (Const)
            // LED output: 5 × 1 bit
            .usagePage(HIDUsagePage.led),                         //   Usage Page (LEDs)
            .usageMinimum(0x01),                                  //   Usage Minimum (Num Lock)
            .usageMaximum(0x05),                                  //   Usage Maximum (Kana)
            .reportSize(1),                                       //   Report Size (1)
            .reportCount(5),                                      //   Report Count (5)
            .output(.dataVariableAbsolute),                       //   Output (Data, Var, Abs)
            // LED padding: 1 × 3 bits
            .reportSize(3),                                       //   Report Size (3)
            .reportCount(1),                                      //   Report Count (1)
            .output(.constantPadding),                            //   Output (Const)
            // Key array: 6 × 8 bits, usages 0x00–0xE7
            .usagePage(HIDUsagePage.keyboard),                    //   Usage Page (Keyboard/Keypad)
            .usageMinimum(0x00),                                  //   Usage Minimum (0)
            .usageMaximum(UInt16(KeyUsage.maximum.rawValue)),     //   Usage Maximum (0xE7)
            .logicalMinimum(0),                                   //   Logical Minimum (0)
            .logicalMaximum(Int32(KeyUsage.maximum.rawValue)),    //   Logical Maximum (0xE7)
            .reportSize(8),                                       //   Report Size (8)
            .reportCount(UInt32(KeyboardReport.maxKeys)),         //   Report Count (6)
            .input(.dataArrayAbsolute),                           //   Input (Data, Array, Abs)
            .endCollection,                                       // End Collection
        ]
        return items
    }

    /// Consumer control: one 16-bit array field, usages 0x000–0x3FF. Input = 2 bytes.
    static func consumerItems(reportID: UInt8?) -> [HIDItem] {
        var items: [HIDItem] = [
            .usagePage(HIDUsagePage.consumer),                    // Usage Page (Consumer)
            .usage(0x01),                                         // Usage (Consumer Control)
            .collection(.application),                            // Collection (Application)
        ]
        if let reportID { items.append(.reportID(reportID)) }    //   Report ID
        items += [
            .usageMinimum(0x000),                                 //   Usage Minimum (0)
            .usageMaximum(ConsumerUsage.maximumRawValue),         //   Usage Maximum (0x3FF)
            .logicalMinimum(0),                                   //   Logical Minimum (0)
            .logicalMaximum(Int32(ConsumerUsage.maximumRawValue)),//   Logical Maximum (0x3FF)
            .reportSize(16),                                      //   Report Size (16)
            .reportCount(1),                                      //   Report Count (1)
            .input(.dataArrayAbsolute),                           //   Input (Data, Array, Abs)
            .endCollection,                                       // End Collection
        ]
        return items
    }
}
