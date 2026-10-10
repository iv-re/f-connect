import Foundation

public struct DeviceCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    public static let coolingControl   = DeviceCapabilities(rawValue: 1 << 0)
    public static let lightingControl  = DeviceCapabilities(rawValue: 1 << 1)
    public static let motherboardSync  = DeviceCapabilities(rawValue: 1 << 2)
    public static let clusterIdentify  = DeviceCapabilities(rawValue: 1 << 3)
    
    public static let standardFans: DeviceCapabilities = [
        .coolingControl, .lightingControl, .motherboardSync, .clusterIdentify
    ]
}
