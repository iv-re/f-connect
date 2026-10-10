import Foundation
import IOKit
import os

public enum DeviceControllerFactory {
    /// - Parameter detectedProfile: result of an earlier `detectProfile` on the same device, to avoid asking twice.
    public static func create(
        type: ControllerType,
        device: HIDDeviceProtocol,
        rawDevice: IOHIDDevice?,
        detectedProfile: Ene6K77Profile? = nil
    ) -> BaseDeviceController? {
        guard let usbProfile = Ene6K77Profile.profile(for: type) else { return nil }
        
        // The firmware tells the real model; the USB product ID is only the fallback (it can be shared or reassigned).
        let firmwareProfile = detectedProfile ?? detectProfile(device: device)
        let profile = firmwareProfile ?? usbProfile
        let note: String
        if let firmwareProfile = firmwareProfile {
            if firmwareProfile.deviceType != usbProfile.deviceType {
                note = "USB ID says \(usbProfile.defaultName), firmware says \(firmwareProfile.defaultName); using firmware"
                EventLog.shared.record(note, level: .warning)
            } else {
                note = "firmware signature and USB ID agree (\(profile.defaultName))"
            }
        } else {
            note = "firmware did not identify the model; using USB ID (\(usbProfile.defaultName))"
            EventLog.shared.record(note, level: .warning)
        }
        let controller = Ene6K77Controller(device: device, rawDevice: rawDevice, profile: profile)
        controller.detectionNote = note
        return controller
    }
    
    /// Asks the device for its firmware signature. Returns nil if it does not answer or the signature is unknown.
    static func detectProfile(device: HIDDeviceProtocol) -> Ene6K77Profile? {
        guard device.open() else { return nil }
        let reply: [UInt8]? = device.transaction {
            _ = device.sendFeatureReport(Ene6K77Profile.firmwareRequest)
            return device.getInputReport(reportID: Ene6K77Profile.reportID, length: 16)
        }
        guard let reply = reply, let info = Ene6K77Profile.parseFirmware(reply) else { return nil }
        let profile = Ene6K77Profile.profile(firmwareMajor: info.majorID, minor: info.minorID)
        if profile == nil {
            EventLog.shared.record("Unknown firmware signature major=\(info.majorID) minor=\(info.minorID)", level: .warning)
        }
        return profile
    }
}
