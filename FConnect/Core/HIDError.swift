import Foundation
import IOKit

/// Turns IOKit error codes into text a user (or a bug report) can act on.
public enum HIDError {
    public static func describe(_ code: Int32) -> String {
        switch code {
        case kIOReturnNotPermitted:
            return "macOS denied access to the controller. Allow F-Connect under System Settings > Privacy & Security > Input Monitoring, then restart the app."
        case kIOReturnExclusiveAccess:
            return "Another program has exclusive access to the controller. Quit any other fan or RGB control app that may be using it."
        case kIOReturnNoDevice, kIOReturnNotAttached:
            return "The controller was disconnected."
        case kIOReturnTimeout, kIOReturnNotResponding:
            return "The controller is not responding."
        case kIOReturnNotOpen:
            return "The connection to the controller was closed."
        default:
            return "Communication with the controller failed (IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16)))."
        }
    }
}
