import Foundation

public struct LianLiDeviceID: Hashable, CustomStringConvertible {
    public let vendorID: UInt16
    public let productID: UInt16
    
    public init(vendorID: UInt16, productID: UInt16) {
        self.vendorID = vendorID
        self.productID = productID
    }
    
    public var description: String {
        return String(format: "0x%04X:0x%04X", vendorID, productID)
    }
}

public enum ControllerType: String, CaseIterable, Identifiable {
    case none = "None"
    case slFan = "SL Fan"
    case alFan = "AL Fan"
    case slInfinity = "SL-Infinity"
    case slV2Fan = "SL V2 Fan"
    case alV2Fan = "AL V2 Fan"
    case strimerPlus = "Strimer Plus"
    case galahad2TrinityP = "Galahad II Trinity P"
    case galahad2TrinityR = "Galahad II Trinity R"
    case galahad2LCD = "Galahad II LCD"
    case tlFan = "TL Fan"
    case tlLCD = "TL LCD"
    
    public var id: String { rawValue }
}

public enum KnownDevices {
    public static let mapping: [LianLiDeviceID: ControllerType] = [
        LianLiDeviceID(vendorID: 0x0CF2, productID: 0xA100): .slFan,
        LianLiDeviceID(vendorID: 0x0CF2, productID: 0xA101): .alFan,
        LianLiDeviceID(vendorID: 0x0CF2, productID: 0xA102): .slInfinity,
        LianLiDeviceID(vendorID: 0x0CF2, productID: 0xA103): .slV2Fan,
        LianLiDeviceID(vendorID: 0x0CF2, productID: 0xA104): .alV2Fan,
        LianLiDeviceID(vendorID: 0x0CF2, productID: 0xA105): .slV2Fan, // SL V2 alternative PID
        LianLiDeviceID(vendorID: 0x0CF2, productID: 0xA200): .strimerPlus,
        LianLiDeviceID(vendorID: 0x0416, productID: 0x7371): .galahad2TrinityP,
        LianLiDeviceID(vendorID: 0x0416, productID: 0x7373): .galahad2TrinityR,
        LianLiDeviceID(vendorID: 0x0416, productID: 0x7391): .galahad2LCD,
        LianLiDeviceID(vendorID: 0x0416, productID: 0x7372): .tlFan,
        LianLiDeviceID(vendorID: 0x04FC, productID: 0x7393): .tlLCD
    ]
    
    public static func controllerType(for id: LianLiDeviceID) -> ControllerType {
        return mapping[id] ?? .none
    }
}
