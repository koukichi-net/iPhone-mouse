import Testing
@testable import HIDCore

@Suite("GATTLayout")
struct GATTLayoutTests {
    @Test func uuidForm() {
        #expect(BluetoothUUID.hidService.rawValue == "00001812-0000-1000-8000-00805F9B34FB")
        #expect(BluetoothUUID.reportReference.rawValue == "00002908-0000-1000-8000-00805F9B34FB")
        #expect(BluetoothUUID(0x2a4d) == BluetoothUUID(rawValue: "00002a4d-0000-1000-8000-00805f9b34fb"))
        #expect(BluetoothUUID.pnpID.shortValue == 0x2A50)
        #expect(BluetoothUUID(rawValue: "12345678-0000-1000-8000-00805F9B34FB").shortValue == nil)
    }

    @Test func planAStructure() {
        let l = GATTLayout.planA
        #expect(l.services.map(\.uuid) == [.hidService, .deviceInformationService, .batteryService])
        #expect(l.services.allSatisfy { $0.isPrimary })
        #expect(l.advertisedServiceUUIDs == [.hidService])
        let hid = l.services[0]
        #expect(hid.role == .hid(.composite))
        #expect(hid.characteristics.map(\.uuid) == [.hidInformation, .reportMap, .hidControlPoint, .protocolMode,
                                                    .report, .report, .report, .report])
        #expect(l.characteristic(.hidInformation(.composite))?.value == [0x11, 0x01, 0x00, 0x02])
        #expect(l.characteristic(.reportMap(.composite))?.value == expectedComposite)
        #expect(l.characteristic(.protocolMode(.composite))?.value == [0x01])

        let refs = hid.characteristics.compactMap(\.reportReference).map { [$0.id, $0.type.rawValue] }
        #expect(refs == [[1, 1], [2, 1], [2, 2], [3, 1]])
        #expect(l.characteristic(.inputReport(.mouse))?.reportReference?.id == 1)
        #expect(l.characteristic(.outputReport(.keyboard))?.reportReference?.type == .output)
        #expect(l.reportKinds == [.mouse, .keyboard, .consumer])
    }

    @Test(arguments: [GATTLayout.planA, .planB])
    func propertiesAndPermissions(layout: GATTLayout) {
        for s in layout.services {
            for c in s.characteristics {
                switch c.role {
                case .hidInformation, .reportMap:
                    #expect(c.properties == [.read] && c.permissions == [.readEncryptionRequired])
                case .hidControlPoint:
                    #expect(c.properties == [.writeWithoutResponse] && c.permissions == [.writeEncryptionRequired])
                case .protocolMode:
                    #expect(c.properties == [.read, .writeWithoutResponse])
                    #expect(c.permissions == [.readEncryptionRequired, .writeEncryptionRequired])
                case .inputReport:
                    #expect(c.properties == [.read, .notify] && c.permissions == [.readEncryptionRequired])
                    #expect(c.value == nil)
                case .outputReport:
                    #expect(c.properties == [.read, .write, .writeWithoutResponse])
                    #expect(c.permissions == [.readEncryptionRequired, .writeEncryptionRequired])
                case .manufacturerName, .pnpID:
                    #expect(c.properties == [.read] && c.permissions == [.readable] && c.value != nil)
                case .batteryLevel:
                    #expect(c.properties == [.read, .notify] && c.permissions == [.readable])
                }
                // No app-added Extended Properties (design §5).
                #expect(!c.descriptors.contains { $0.uuid == BluetoothUUID(0x2900) })
            }
        }
    }

    @Test(arguments: [GATTLayout.planA, .planB, GATTLayout(plan: .b, configuration: {
        var c = GATTLayout.Configuration(); c.includeConsumerService = false; return c
    }())])
    func reportReferencesMatchTheServiceDescriptor(layout: GATTLayout) {
        for s in layout.services {
            guard case .hid = s.role else { continue }
            let map = try! #require(s.characteristics.first { $0.uuid == .reportMap }?.value)
            let walked = DescriptorWalker.walk(map)
            let referenced = Set(s.characteristics.compactMap(\.reportReference).map {
                "\($0.type == .input ? "input" : "output")-\($0.id)"
            })
            #expect(referenced == walked.reports, "\(s.role)")
            // Every role is unique within the layout.
        }
        let roles = layout.services.flatMap(\.characteristics).map(\.role)
        #expect(Set(roles).count == roles.count)
    }

    @Test func planBStructure() {
        let l = GATTLayout.planB
        #expect(l.services.map(\.role) == [.hid(.single(.mouse)), .hid(.single(.keyboard)), .hid(.single(.consumer)),
                                           .deviceInformation, .battery])
        #expect(l.characteristic(.reportMap(.single(.mouse)))?.value == mouseHeader + expectedMouseBody)
        #expect(l.characteristic(.reportMap(.single(.keyboard)))?.value == keyboardHeader + expectedKeyboardBody)
        #expect(l.characteristic(.inputReport(.keyboard))?.reportReference.map { [$0.id, $0.type.rawValue] } == [0, 1])
        #expect(l.characteristic(.outputReport(.keyboard))?.reportReference.map { [$0.id, $0.type.rawValue] } == [0, 2])
        #expect(l.service(containing: .inputReport(.keyboard))?.role == .hid(.single(.keyboard)))

        var c = GATTLayout.Configuration()
        c.includeConsumerService = false
        let noConsumer = GATTLayout(plan: .b, configuration: c)
        #expect(noConsumer.reportKinds == [.mouse, .keyboard])
        #expect(noConsumer.characteristic(.inputReport(.consumer)) == nil)
    }

    @Test func rawValuesMatchCoreBluetoothConstants() {
        // CBCharacteristicProperties: broadcast 0x01, read 0x02, writeWithoutResponse 0x04,
        // write 0x08, notify 0x10. CBAttributePermissions: readable 1, writeable 2,
        // readEncryptionRequired 4, writeEncryptionRequired 8.
        #expect(CharacteristicProperties.read.rawValue == 0x02)
        #expect(CharacteristicProperties.writeWithoutResponse.rawValue == 0x04)
        #expect(CharacteristicProperties.write.rawValue == 0x08)
        #expect(CharacteristicProperties.notify.rawValue == 0x10)
        #expect(AttributePermissions.readable.rawValue == 1 && AttributePermissions.writeable.rawValue == 2)
        #expect(AttributePermissions.readEncryptionRequired.rawValue == 4)
        #expect(AttributePermissions.writeEncryptionRequired.rawValue == 8)
    }

    @Test func deviceInformationValues() {
        var c = GATTLayout.Configuration()
        c.manufacturerName = "HIDPad"
        c.productID = 0x1234
        c.productVersion = 0x0102
        let l = GATTLayout(plan: .a, configuration: c)
        #expect(l.characteristic(.pnpID)?.value == [0x02, 0xFF, 0xFF, 0x34, 0x12, 0x02, 0x01])
        #expect(l.characteristic(.manufacturerName)?.value == Array("HIDPad".utf8))
        #expect(l.characteristic(.batteryLevel)?.value == nil)
    }
}
