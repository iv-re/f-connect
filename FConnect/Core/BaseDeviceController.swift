import Foundation
import IOKit

/// Root base controller for any Lian Li hardware (ENE 6K77, Nuvoton, Sunplus).
/// UI views bind directly to this class, ensuring complete decoupling from specific hardware buses.
///
/// Threading contract: published state (`groupStates`, the sync flags, `connectionIssue`) is read and written on the main
/// thread only. Hardware I/O happens on private queues and must work from snapshots, never from published state.
open class BaseDeviceController: ObservableObject {
    public let deviceType: ControllerType
    public let deviceName: String
    public let rawDevice: IOHIDDevice?
    public let capabilities: DeviceCapabilities
    
    @Published public var firmwareVersion: String = "Unknown"
    /// Raw firmware identification as "major/minor", for support reports; nil until the hardware has answered.
    public var firmwareSignature: String?
    /// How the model was identified (firmware signature vs USB ID), for support reports.
    public var detectionNote: String?
    @Published public var groupStates: [FanGroupState] = []
    @Published public var isMotherboardRPMSync: Bool = false
    @Published public var isMotherboardARGBSync: Bool = false
    /// User-facing description of why the hardware cannot be reached right now; nil while it is healthy.
    @Published public var connectionIssue: String?
    /// Called on the main thread when the controller concludes the hardware is unreachable, so its owner can rescan.
    public var onConnectionLost: (() -> Void)?
    
    public init(
        deviceType: ControllerType,
        deviceName: String,
        rawDevice: IOHIDDevice? = nil,
        capabilities: DeviceCapabilities = .standardFans
    ) {
        self.deviceType = deviceType
        self.deviceName = deviceName
        self.rawDevice = rawDevice
        self.capabilities = capabilities
    }
    
    public var visibleGroups: [(index: Int, state: FanGroupState)] {
        groupStates.enumerated()
            .filter { !$0.element.isHidden }
            .map { (index: $0.offset, state: $0.element) }
    }
    
    // MARK: - Lifecycle & Hardware Interop (Override in subclasses)
    
    open func initialize() {}
    /// One line about the health of the link (poll failures, last error), for support reports.
    open var healthSummary: String { "n/a" }
    open func pollTelemetry() {}
    open func savePreferences() {}
    /// Re-sends all settings after the system woke up (the hardware may have been power-cycled).
    open func resetAfterWake() {}
    /// Gives fan speed control back to the motherboard without touching saved preferences.
    open func releaseToMotherboard() {}
    
    // MARK: - Cooling
    
    open func setFanSpeed(groupIndex: Int, percent: Int) {}
    open func setFanCount(groupIndex: Int, count: Int) {}
    
    // MARK: - Lighting
    
    /// Lighting modes this hardware can display; the UI offers only these.
    open var supportedLightingModes: [FanLightingMode] { FanLightingMode.allCases }
    /// The mode that is actually shown for a requested one (hardware without that effect falls back to a static color).
    open func effectiveLightingMode(_ mode: FanLightingMode) -> FanLightingMode { mode }
    
    open func setLighting(
        groupIndex: Int,
        mode: FanLightingMode,
        speedIndex: Int,
        brightnessPercent: Int,
        direction: UInt8,
        colors: [RGBColor]?
    ) {}
    
    // MARK: - Motherboard Sync
    
    open func setMotherboardSync(rpmSync: Bool, argbSync: Bool) {}
    /// Changes only the ARGB sync; per-group RPM sync stays untouched.
    open func setARGBSync(_ enabled: Bool) {}
    open func setGroupRPMSync(groupIndex: Int, isSync: Bool) {}
    
    // MARK: - Identification & Configuration
    
    open func identifyCluster(groupIndex: Int) {}
    open func setGroupName(groupIndex: Int, name: String) {}
    open func setGroupHidden(groupIndex: Int, isHidden: Bool) {}
}
