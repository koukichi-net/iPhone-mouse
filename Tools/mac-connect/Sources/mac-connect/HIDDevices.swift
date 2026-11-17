import Foundation
import IOKit
import IOKit.hid

/// Value of the IOHIDDevice `Transport` property for HID over GATT devices.
let bleTransport = "Bluetooth Low Energy"

func bleMatching() -> CFDictionary {
    [kIOHIDTransportKey: bleTransport] as CFDictionary
}

/// Snapshot of the HID devices whose Transport is Bluetooth Low Energy.
/// Uses a fresh IOHIDManager that is never opened, so it needs no privacy permission.
func copyBLEDevices() -> [IOHIDDevice] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, bleMatching())
    guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
    let devices = (set as NSSet).allObjects.map { $0 as! IOHIDDevice }
    return devices.sorted { registryID($0) < registryID($1) }
}

func registryID(_ device: IOHIDDevice) -> UInt64 {
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
    return id
}

func property(_ device: IOHIDDevice, _ key: String) -> Any? {
    IOHIDDeviceGetProperty(device, key as CFString)
}

func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
    (property(device, key) as? NSNumber)?.intValue
}

func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
    property(device, key) as? String
}

func usagePageName(_ page: Int) -> String {
    switch page {
    case 0x01: return "GenericDesktop"
    case 0x06: return "GenericDevice"
    case 0x07: return "Keyboard"
    case 0x08: return "LED"
    case 0x09: return "Button"
    case 0x0C: return "Consumer"
    case 0xFF00...0xFFFF: return "Vendor"
    default: return String(format: "Page0x%02X", page)
    }
}

func usageName(page: Int, usage: Int) -> String {
    switch (page, usage) {
    case (0x01, 0x01): return "Pointer"
    case (0x01, 0x02): return "Mouse"
    case (0x01, 0x06): return "Keyboard"
    case (0x01, 0x30): return "X"
    case (0x01, 0x31): return "Y"
    case (0x01, 0x38): return "Wheel"
    case (0x0C, 0x01): return "ConsumerControl"
    case (0x0C, 0x238): return "ACPan"
    case (0x07, 0x39): return "CapsLock"
    case (0x07, 0x68...0x6F): return "F\(usage - 0x68 + 13)"
    case (0x07, 0xE0): return "LeftCtrl"
    case (0x07, 0xE1): return "LeftShift"
    case (0x07, 0xE2): return "LeftAlt"
    case (0x07, 0xE3): return "LeftGUI"
    case (0x07, 0xE4): return "RightCtrl"
    case (0x07, 0xE5): return "RightShift"
    case (0x07, 0xE6): return "RightAlt"
    case (0x07, 0xE7): return "RightGUI"
    case (0x08, 0x01): return "NumLockLED"
    case (0x08, 0x02): return "CapsLockLED"
    case (0x08, 0x03): return "ScrollLockLED"
    case (0x08, 0x04): return "ComposeLED"
    case (0x08, 0x05): return "KanaLED"
    case (0x09, _): return "Button\(usage)"
    default: return ""
    }
}

func pageUsage(_ page: Int, _ usage: Int) -> String {
    let name = usageName(page: page, usage: usage)
    return String(format: "page=0x%02X usage=0x%02X", page, usage) + (name.isEmpty ? "" : " (\(name))")
}

/// One-line identity of a device: registry ID, product, IDs and primary usage.
func deviceHeadline(_ device: IOHIDDevice) -> String {
    let product = stringProperty(device, kIOHIDProductKey) ?? "-"
    let id4 = { (key: String) in intProperty(device, key).map { String(format: "0x%04X", $0) } ?? "absent" }
    let page = intProperty(device, kIOHIDPrimaryUsagePageKey) ?? -1
    let usage = intProperty(device, kIOHIDPrimaryUsageKey) ?? -1
    return String(format: "device 0x%llx product=\"%@\" VendorID=%@ ProductID=%@ Primary %@",
                  registryID(device), product, id4(kIOHIDVendorIDKey), id4(kIOHIDProductIDKey), pageUsage(page, usage))
}

/// Full description used by `status` and `connect`.
func describe(_ device: IOHIDDevice) -> [String] {
    var lines = [deviceHeadline(device)]
    lines.append("  Transport=\"\(stringProperty(device, kIOHIDTransportKey) ?? "-")\" Manufacturer=\"\(stringProperty(device, kIOHIDManufacturerKey) ?? "-")\" SerialNumber=\"\(stringProperty(device, kIOHIDSerialNumberKey) ?? "-")\" VersionNumber=\(intProperty(device, kIOHIDVersionNumberKey).map { String(format: "0x%04X", $0) } ?? "-")")

    if let pairs = property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] {
        let text = pairs.map { pair -> String in
            let p = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue ?? -1
            let u = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue ?? -1
            let n = usageName(page: p, usage: u)
            return String(format: "0x%02X/0x%02X", p, u) + (n.isEmpty ? "" : "(\(n))")
        }
        lines.append("  DeviceUsagePairs: " + text.joined(separator: ", "))
    }
    let maxIn = intProperty(device, kIOHIDMaxInputReportSizeKey).map(String.init) ?? "-"
    let maxOut = intProperty(device, kIOHIDMaxOutputReportSizeKey).map(String.init) ?? "-"
    lines.append("  MaxInputReportSize=\(maxIn) MaxOutputReportSize=\(maxOut)")
    if let descriptor = property(device, kIOHIDReportDescriptorKey) as? Data {
        lines.append("  ReportDescriptor (\(descriptor.count) bytes): \(hex(descriptor))")
    }
    lines.append(contentsOf: elementSummary(device))
    return lines
}

/// Application collections plus, per usage page, the input/output/feature elements macOS enumerated.
func elementSummary(_ device: IOHIDDevice) -> [String] {
    guard let raw = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
        return ["  elements: (none returned)"]
    }
    var lines: [String] = []
    struct PageStats { var input = 0, output = 0, feature = 0; var usages = Set<Int>(); var reportIDs = Set<Int>() }
    var pages: [Int: PageStats] = [:]
    for element in raw {
        let type = IOHIDElementGetType(element)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let reportID = Int(IOHIDElementGetReportID(element))
        if type == kIOHIDElementTypeCollection {
            if IOHIDElementGetCollectionType(element) == kIOHIDElementCollectionTypeApplication {
                lines.append("  application collection: \(pageUsage(page, usage)) reportID=\(reportID)")
            }
            continue
        }
        // Constant padding fields show up as elements with usage page 0 / usage 0 or 0xFFFFFFFF.
        var stats = pages[page, default: PageStats()]
        switch type {
        case kIOHIDElementTypeOutput: stats.output += 1
        case kIOHIDElementTypeFeature: stats.feature += 1
        default: stats.input += 1
        }
        stats.usages.insert(usage)
        stats.reportIDs.insert(reportID)
        pages[page] = stats
    }
    for page in pages.keys.sorted() {
        let s = pages[page]!
        lines.append(String(format: "  page 0x%02X %@: input=%d output=%d feature=%d reportIDs=%@ usages=%@",
                            page, usagePageName(page), s.input, s.output, s.feature,
                            s.reportIDs.sorted().map(String.init).joined(separator: ","),
                            compactUsages(s.usages)))
    }
    return lines
}

/// Formats a usage set as hex ranges, e.g. "0x00-0xE7".
private func compactUsages(_ usages: Set<Int>) -> String {
    let sorted = usages.sorted()
    var parts: [String] = []
    var i = 0
    while i < sorted.count {
        var j = i
        while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
        parts.append(i == j ? String(format: "0x%02X", sorted[i]) : String(format: "0x%02X-0x%02X", sorted[i], sorted[j]))
        i = j + 1
    }
    return parts.joined(separator: ",")
}

/// `mac-connect status`
func runStatus() -> Int32 {
    let devices = copyBLEDevices()
    emit("STATUS \(devices.count) HID device(s) with Transport=\"\(bleTransport)\"")
    for device in devices {
        for line in describe(device) { emit(line) }
    }
    emit("STATUS input-monitoring(ListenEvent)=\(listenAccessName())")
    return 0
}

func listenAccessName() -> String {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return "granted"
    case kIOHIDAccessTypeDenied: return "denied"
    case kIOHIDAccessTypeUnknown: return "unknown(not yet asked)"
    default: return "other"
    }
}

func ioReturnName(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess: return "success"
    case kIOReturnNotPermitted: return "kIOReturnNotPermitted"
    case kIOReturnNotPrivileged: return "kIOReturnNotPrivileged"
    case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess"
    default: return String(format: "0x%08X", UInt32(bitPattern: r))
    }
}
