import Testing

@Suite("Profile packets")
struct ProfilePacketTests {
    @Test func quantityEncodingDiffersBetweenModels() {
        // SL V2 packs group and count into one byte: (group << 4) | count
        #expect(Ene6K77Profile.slV2.quantityPacket(group: 2, count: 3) == [0xE0, 0x10, 0x60, 0x23, 0, 0])
        // AL V2 / SL-Infinity / AL V1 send group + 1, then the count
        #expect(Ene6K77Profile.alV2.quantityPacket(group: 2, count: 3) == [0xE0, 0x10, 0x60, 3, 3, 0])
        #expect(Ene6K77Profile.slInfinity.quantityPacket(group: 0, count: 4) == [0xE0, 0x10, 0x60, 1, 4, 0])
        #expect(Ene6K77Profile.alV1.quantityPacket(group: 1, count: 2) == [0xE0, 0x10, 0x40, 2, 2, 0])
        #expect(Ene6K77Profile.slV1.quantityPacket(group: 3, count: 6) == [0xE0, 0x10, 0x32, 0x36, 0, 0])
    }
    
    @Test func quantityIsClamped() {
        #expect(Ene6K77Profile.slV2.quantityPacket(group: 0, count: 0)[3] == 0x01)
        #expect(Ene6K77Profile.slV2.quantityPacket(group: 0, count: 99)[3] == 0x06)
        #expect(Ene6K77Profile.alV2.quantityPacket(group: 0, count: -3)[4] == 1)
    }
    
    @Test func rpmSyncMaskSetsEnableBitAndValueBit() {
        let p = Ene6K77Profile.slV2
        #expect(p.rpmSyncPacket(group: 0, sync: true) == [0xE0, 0x10, 0x62, 0x11, 0, 0])
        #expect(p.rpmSyncPacket(group: 0, sync: false) == [0xE0, 0x10, 0x62, 0x10, 0, 0])
        #expect(p.rpmSyncPacket(group: 2, sync: true) == [0xE0, 0x10, 0x62, 0x44, 0, 0])
        #expect(p.rpmSyncPacket(group: 3, sync: false) == [0xE0, 0x10, 0x62, 0x80, 0, 0])
    }
    
    @Test func syncOpcodesPerModel() {
        #expect(Ene6K77Profile.slV1.rpmSyncPacket(group: 0, sync: true)[2] == 0x31)
        #expect(Ene6K77Profile.slV1.argbSyncPacket(enabled: true) == [0xE0, 0x10, 0x30, 1, 0, 0])
        #expect(Ene6K77Profile.alV1.rpmSyncPacket(group: 0, sync: true)[2] == 0x42)
        #expect(Ene6K77Profile.alV1.argbSyncPacket(enabled: false) == [0xE0, 0x10, 0x41, 0, 0, 0])
        for p in [Ene6K77Profile.slV2, .alV2, .slInfinity] {
            #expect(p.rpmSyncPacket(group: 0, sync: true)[2] == 0x62)
            #expect(p.argbSyncPacket(enabled: true)[2] == 0x61)
        }
    }
    
    @Test func noMergePacketsPerModel() {
        #expect(Ene6K77Profile.slV2.noMergePackets() == [[0xE0, 0x10, 0x63, 0, 1, 2, 3, 0x08]])
        #expect(Ene6K77Profile.alV2.noMergePackets() == [[0xE0, 0x10, 0x63, 0, 1, 2, 3, 0x08]])
        #expect(Ene6K77Profile.slInfinity.noMergePackets() == [[0xE0, 0x10, 0x63, 0, 1, 2, 3, 0x08]])
        #expect(Ene6K77Profile.slV1.noMergePackets() == [[0xE0, 0x10, 0x34, 0, 0, 0]])     // stop merge
        #expect(Ene6K77Profile.alV1.noMergePackets() == [[0xE0, 0x10, 0x43, 0, 0, 0]])     // merge flag off
    }
    
    @Test func fanSpeedPacketClampsDuty() {
        let p = Ene6K77Profile.slV2
        #expect(p.fanSpeedPacket(group: 1, percent: 40) == [0xE0, 0x21, 0x00, 40])
        #expect(p.fanSpeedPacket(group: 0, percent: 150)[3] == 100)
        #expect(p.fanSpeedPacket(group: 0, percent: -5)[3] == 0)
        #expect(p.fanSpeedPacket(group: 3, percent: 0)[1] == 0x23)
    }
    
    @Test func effectPacketUsesPortInLowNibble() {
        let packet = Ene6K77Profile.slV2.effectPacket(port: 3, mode: 28, speed: 2, direction: 1, brightness: 0)
        #expect(packet == [0xE0, 0x13, 28, 2, 1, 0])
    }
    
    @Test func everyModelHasUniqueIdentity() {
        let all = Ene6K77Profile.all
        #expect(Set(all.map { $0.deviceType.rawValue }).count == all.count)
        #expect(Set(all.map { $0.prefsPrefix }).count == all.count, "models must not share saved settings")
        
        var signatures = Set<String>()
        for p in all {
            for minor in p.firmwareMinorIDs { signatures.insert("\(p.firmwareMajorID)/\(minor)") }
        }
        let expected = all.reduce(0) { $0 + $1.firmwareMinorIDs.count }
        #expect(signatures.count == expected, "a firmware signature must identify exactly one model")
    }
    
    @Test func profileLookupByType() {
        #expect(Ene6K77Profile.profile(for: .slV2Fan)?.deviceType == .slV2Fan)
        #expect(Ene6K77Profile.profile(for: .alV2Fan)?.deviceType == .alV2Fan)
        #expect(Ene6K77Profile.profile(for: .slInfinity)?.deviceType == .slInfinity)
        #expect(Ene6K77Profile.profile(for: .slFan)?.deviceType == .slFan)
        #expect(Ene6K77Profile.profile(for: .alFan)?.deviceType == .alFan)
        #expect(Ene6K77Profile.profile(for: .tlFan) == nil)
        #expect(Ene6K77Profile.profile(for: .strimerPlus) == nil)
    }
    
    @Test func profileLookupByFirmwareSignature() {
        #expect(Ene6K77Profile.profile(firmwareMajor: 100, minor: 197)?.deviceType == .slV2Fan)
        #expect(Ene6K77Profile.profile(firmwareMajor: 100, minor: 199)?.deviceType == .slV2Fan)
        #expect(Ene6K77Profile.profile(firmwareMajor: 128, minor: 198)?.deviceType == .alV2Fan)
        #expect(Ene6K77Profile.profile(firmwareMajor: 128, minor: 196)?.deviceType == .slInfinity)
        #expect(Ene6K77Profile.profile(firmwareMajor: 100, minor: 194)?.deviceType == .slFan)
        #expect(Ene6K77Profile.profile(firmwareMajor: 128, minor: 195)?.deviceType == .alFan)
        #expect(Ene6K77Profile.profile(firmwareMajor: 1, minor: 2) == nil)
    }
    
    @Test func knownUSBIdsMapToSupportedProfiles() {
        let supported: [UInt16] = [0xA100, 0xA101, 0xA102, 0xA103, 0xA104, 0xA105]
        for pid in supported {
            let type = KnownDevices.controllerType(for: LianLiDeviceID(vendorID: 0x0CF2, productID: pid))
            #expect(Ene6K77Profile.profile(for: type) != nil, "PID \(String(pid, radix: 16)) has no profile")
        }
    }
}
