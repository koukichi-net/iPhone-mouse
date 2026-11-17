import Foundation

// GATT structure as plain values (design §5). The app translates this into
// CoreBluetooth objects; this file must not import CoreBluetooth.

/// A Bluetooth UUID in the 128-bit string form iOS accepts for HID
/// (`0000XXXX-0000-1000-8000-00805F9B34FB`, upper case).
public struct BluetoothUUID: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }

    /// Expands a 16-bit SIG-assigned number to the 128-bit base UUID form.
    public init(_ short: UInt16) {
        self.rawValue = String(format: "0000%04X-0000-1000-8000-00805F9B34FB", short)
    }

    /// The 16-bit number if this is a SIG base UUID.
    public var shortValue: UInt16? {
        let parts = rawValue.split(separator: "-")
        guard parts.count == 5, parts[0].count == 8, parts[0].hasPrefix("0000"),
              parts[1...].joined(separator: "-") == "0000-1000-8000-00805F9B34FB" else { return nil }
        return UInt16(parts[0].dropFirst(4), radix: 16)
    }

    public var description: String { rawValue }

    // Services
    public static let hidService = BluetoothUUID(0x1812)
    public static let deviceInformationService = BluetoothUUID(0x180A)
    public static let batteryService = BluetoothUUID(0x180F)
    // Characteristics
    public static let hidInformation = BluetoothUUID(0x2A4A)
    public static let reportMap = BluetoothUUID(0x2A4B)
    public static let hidControlPoint = BluetoothUUID(0x2A4C)
    public static let report = BluetoothUUID(0x2A4D)
    public static let protocolMode = BluetoothUUID(0x2A4E)
    public static let manufacturerName = BluetoothUUID(0x2A29)
    public static let pnpID = BluetoothUUID(0x2A50)
    public static let batteryLevel = BluetoothUUID(0x2A19)
    // Descriptors
    public static let reportReference = BluetoothUUID(0x2908)
}

/// Characteristic properties. Raw values equal `CBCharacteristicProperties` (and the GATT
/// properties byte), so `CBCharacteristicProperties(rawValue: UInt(p.rawValue))` works.
public struct CharacteristicProperties: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let read = CharacteristicProperties(rawValue: 0x02)
    public static let writeWithoutResponse = CharacteristicProperties(rawValue: 0x04)
    public static let write = CharacteristicProperties(rawValue: 0x08)
    public static let notify = CharacteristicProperties(rawValue: 0x10)
}

/// Attribute permissions. Raw values equal `CBAttributePermissions`.
public struct AttributePermissions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let readable = AttributePermissions(rawValue: 1 << 0)
    public static let writeable = AttributePermissions(rawValue: 1 << 1)
    public static let readEncryptionRequired = AttributePermissions(rawValue: 1 << 2)
    public static let writeEncryptionRequired = AttributePermissions(rawValue: 1 << 3)
}

/// Report type in a Report Reference descriptor.
public enum HIDReportType: UInt8, Sendable, Hashable {
    case input = 1
    case output = 2
    case feature = 3
}

/// Which HID service a characteristic belongs to.
public enum HIDServiceRole: Sendable, Hashable {
    /// Plan A: the single service with report IDs.
    case composite
    /// Plan B: one service per report kind.
    case single(ReportKind)
}

public enum ServiceRole: Sendable, Hashable {
    case hid(HIDServiceRole)
    case deviceInformation
    case battery
}

/// Stable identity of a characteristic (0x2A4D repeats, so UUIDs are not enough).
public enum CharacteristicRole: Sendable, Hashable {
    case hidInformation(HIDServiceRole)
    case reportMap(HIDServiceRole)
    case hidControlPoint(HIDServiceRole)
    case protocolMode(HIDServiceRole)
    /// Input Report for a kind (notify).
    case inputReport(ReportKind)
    /// Output Report for a kind (only `.keyboard`: the LEDs).
    case outputReport(ReportKind)
    case manufacturerName
    case pnpID
    case batteryLevel
}

public struct DescriptorDefinition: Sendable, Hashable {
    public var uuid: BluetoothUUID
    public var value: [UInt8]
}

public struct CharacteristicDefinition: Sendable, Hashable {
    public var role: CharacteristicRole
    public var uuid: BluetoothUUID
    public var properties: CharacteristicProperties
    public var permissions: AttributePermissions
    /// The value to answer read requests with, when it is constant. nil means the app
    /// supplies it (reports, battery level) or the characteristic is write-only.
    /// Per design §5 the app still answers reads itself rather than giving CoreBluetooth
    /// a static value.
    public var value: [UInt8]?
    public var descriptors: [DescriptorDefinition]

    /// For Report characteristics: (report ID, type) from the Report Reference descriptor.
    public var reportReference: (id: UInt8, type: HIDReportType)? {
        guard let d = descriptors.first(where: { $0.uuid == .reportReference }), d.value.count == 2,
              let type = HIDReportType(rawValue: d.value[1]) else { return nil }
        return (d.value[0], type)
    }
}

public struct ServiceDefinition: Sendable, Hashable {
    public var role: ServiceRole
    public var uuid: BluetoothUUID
    public var isPrimary: Bool
    public var characteristics: [CharacteristicDefinition]
}

/// The full GATT database for one plan.
public struct GATTLayout: Sendable, Hashable {
    public enum Plan: Sendable, Hashable {
        /// One HID service, report IDs 1–3.
        case a
        /// One HID service per report kind, no report IDs.
        case b
    }

    public struct Configuration: Sendable, Hashable {
        /// Manufacturer Name String (UTF-8).
        public var manufacturerName: String = "HIDPad"
        /// PnP ID vendor ID source (1 = Bluetooth SIG, 2 = USB-IF).
        public var vendorIDSource: UInt8 = 0x02
        public var vendorID: UInt16 = 0xFFFF
        public var productID: UInt16 = 0x0001
        public var productVersion: UInt16 = 0x0100
        /// Plan B only: include a third HID service for consumer control (media keys).
        public var includeConsumerService: Bool = true

        public init() {}
    }

    public let plan: Plan
    public let services: [ServiceDefinition]

    /// Services to put in the advertisement.
    public var advertisedServiceUUIDs: [BluetoothUUID] { [.hidService] }

    /// Report kinds that have an input report characteristic in this layout.
    public var reportKinds: [ReportKind] {
        services.flatMap(\.characteristics).compactMap {
            if case .inputReport(let kind) = $0.role { kind } else { nil }
        }
    }

    public init(plan: Plan, configuration: Configuration = Configuration()) {
        self.plan = plan
        var services: [ServiceDefinition] = []
        switch plan {
        case .a:
            services.append(Self.hidService(role: .composite, descriptor: .composite, reports: [
                (.inputReport(.mouse), ReportID.mouse, .input),
                (.inputReport(.keyboard), ReportID.keyboard, .input),
                (.outputReport(.keyboard), ReportID.keyboard, .output),
                (.inputReport(.consumer), ReportID.consumer, .input),
            ]))
        case .b:
            services.append(Self.hidService(role: .single(.mouse), descriptor: .standalone(.mouse), reports: [
                (.inputReport(.mouse), 0, .input),
            ]))
            services.append(Self.hidService(role: .single(.keyboard), descriptor: .standalone(.keyboard), reports: [
                (.inputReport(.keyboard), 0, .input),
                (.outputReport(.keyboard), 0, .output),
            ]))
            if configuration.includeConsumerService {
                services.append(Self.hidService(role: .single(.consumer), descriptor: .standalone(.consumer), reports: [
                    (.inputReport(.consumer), 0, .input),
                ]))
            }
        }
        services.append(Self.deviceInformationService(configuration))
        services.append(Self.batteryService())
        self.services = services
    }

    public static let planA = GATTLayout(plan: .a)
    public static let planB = GATTLayout(plan: .b)

    /// The characteristic with this role, if the layout has it.
    public func characteristic(_ role: CharacteristicRole) -> CharacteristicDefinition? {
        for s in services { if let c = s.characteristics.first(where: { $0.role == role }) { return c } }
        return nil
    }

    /// The service containing the characteristic with this role.
    public func service(containing role: CharacteristicRole) -> ServiceDefinition? {
        services.first { $0.characteristics.contains { $0.role == role } }
    }

    // MARK: - Builders

    private static let hidRead: AttributePermissions = [.readEncryptionRequired]
    private static let hidReadWrite: AttributePermissions = [.readEncryptionRequired, .writeEncryptionRequired]

    private static func hidService(
        role: HIDServiceRole, descriptor: ReportDescriptor,
        reports: [(CharacteristicRole, UInt8, HIDReportType)]
    ) -> ServiceDefinition {
        var chars: [CharacteristicDefinition] = [
            CharacteristicDefinition(
                role: .hidInformation(role), uuid: .hidInformation, properties: [.read], permissions: hidRead,
                // bcdHID 1.11 (0x0111 LE), country code 0, flags 0x02 (NormallyConnectable)
                value: [0x11, 0x01, 0x00, 0x02], descriptors: []),
            CharacteristicDefinition(
                role: .reportMap(role), uuid: .reportMap, properties: [.read], permissions: hidRead,
                value: descriptor.bytes, descriptors: []),
            CharacteristicDefinition(
                role: .hidControlPoint(role), uuid: .hidControlPoint, properties: [.writeWithoutResponse],
                permissions: [.writeEncryptionRequired], value: nil, descriptors: []),
            CharacteristicDefinition(
                role: .protocolMode(role), uuid: .protocolMode, properties: [.read, .writeWithoutResponse],
                permissions: hidReadWrite,
                value: [0x01],   // Report Protocol
                descriptors: []),
        ]
        for (charRole, id, type) in reports {
            let isOutput = type == .output
            chars.append(CharacteristicDefinition(
                role: charRole, uuid: .report,
                properties: isOutput ? [.read, .write, .writeWithoutResponse] : [.read, .notify],
                permissions: isOutput ? hidReadWrite : hidRead,
                value: nil,
                descriptors: [DescriptorDefinition(uuid: .reportReference, value: [id, type.rawValue])]))
        }
        return ServiceDefinition(role: .hid(role), uuid: .hidService, isPrimary: true, characteristics: chars)
    }

    private static func deviceInformationService(_ c: Configuration) -> ServiceDefinition {
        func le(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let pnp = [c.vendorIDSource] + le(c.vendorID) + le(c.productID) + le(c.productVersion)
        return ServiceDefinition(role: .deviceInformation, uuid: .deviceInformationService, isPrimary: true, characteristics: [
            CharacteristicDefinition(role: .manufacturerName, uuid: .manufacturerName, properties: [.read],
                                     permissions: [.readable], value: Array(c.manufacturerName.utf8), descriptors: []),
            CharacteristicDefinition(role: .pnpID, uuid: .pnpID, properties: [.read],
                                     permissions: [.readable], value: pnp, descriptors: []),
        ])
    }

    private static func batteryService() -> ServiceDefinition {
        ServiceDefinition(role: .battery, uuid: .batteryService, isPrimary: true, characteristics: [
            CharacteristicDefinition(role: .batteryLevel, uuid: .batteryLevel, properties: [.read, .notify],
                                     permissions: [.readable], value: nil, descriptors: []),
        ])
    }
}
