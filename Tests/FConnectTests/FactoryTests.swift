import Testing

@Suite("Device detection")
struct FactoryTests {
    private func hub(firmware: [UInt8]?) -> MockHIDDevice {
        let device = MockHIDDevice()
        device.replyProvider = { request in request == Ene6K77Profile.firmwareRequest ? firmware : nil }
        return device
    }
    
    @Test func detectsEachModelByItsFirmware() {
        let cases: [(UInt8, UInt8, ControllerType)] = [
            (100, 199, .slV2Fan), (100, 197, .slV2Fan), (128, 198, .alV2Fan),
            (128, 196, .slInfinity), (100, 194, .slFan), (128, 195, .alFan)
        ]
        for (major, minor, type) in cases {
            let profile = DeviceControllerFactory.detectProfile(device: hub(firmware: Replies.firmware(major: major, minor: minor)))
            #expect(profile?.deviceType == type, "firmware \(major)/\(minor)")
        }
    }
    
    @Test func unknownFirmwareIsNotGuessed() {
        #expect(DeviceControllerFactory.detectProfile(device: hub(firmware: Replies.firmware(major: 1, minor: 2))) == nil)
    }
    
    @Test func silentDeviceIsNotDetected() {
        #expect(DeviceControllerFactory.detectProfile(device: hub(firmware: nil)) == nil)
    }
    
    @Test func unopenableDeviceIsNotDetected() {
        let device = hub(firmware: Replies.firmware())
        device.openResult = false
        #expect(DeviceControllerFactory.detectProfile(device: device) == nil)
    }
    
    @Test func garbageReplyIsNotDetected() {
        #expect(DeviceControllerFactory.detectProfile(device: hub(firmware: Replies.rpmWithHeader([500, 500, 500, 500]))) == nil)
    }
    
    @Test func firmwareWinsOverTheUSBProductID() {
        // USB says SL V2, the firmware says AL V2: trust the firmware.
        let controller = DeviceControllerFactory.create(type: .slV2Fan, device: hub(firmware: Replies.firmware(major: 128, minor: 198)), rawDevice: nil)
        #expect((controller as? Ene6K77Controller)?.profile.deviceType == .alV2Fan)
    }
    
    @Test func fallsBackToTheUSBProductIDWhenTheDeviceIsSilent() {
        let controller = DeviceControllerFactory.create(type: .slInfinity, device: hub(firmware: nil), rawDevice: nil)
        #expect((controller as? Ene6K77Controller)?.profile.deviceType == .slInfinity)
    }
    
    @Test func unsupportedHardwareProducesNoController() {
        for type in [ControllerType.tlFan, .tlLCD, .strimerPlus, .galahad2LCD, .none] {
            #expect(DeviceControllerFactory.create(type: type, device: hub(firmware: nil), rawDevice: nil) == nil)
        }
    }
}
