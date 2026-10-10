import Foundation
import IOKit
import IOKit.hid
import AppKit
import os

public final class DeviceManager: ObservableObject {
    public static let shared = DeviceManager()
    
    @Published public var connectedControllers: [BaseDeviceController] = []
    @Published public var selectedController: BaseDeviceController?
    @Published public var isScanning = false
    /// Why no hardware is available, when macOS or another program is in the way; nil otherwise.
    @Published public private(set) var problem: String?
    
    
    private var hidManager: IOHIDManager?
    private var pollTimer: Timer?
    private let pollQueue = DispatchQueue(label: "com.lconnect.telemetryPoll", qos: .utility)
    
    /// Private: the HID callbacks hold an unretained pointer to this object, so it must live as long as the process.
    private init() {
        setupHIDManager()
    }
    
    private func setupHIDManager() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else {
            problem = "Could not create the HID manager."
            EventLog.shared.record("Could not create the HID manager", level: .error)
            return
        }
        
        let matchingCriteria: [[String: Any]] = [
            [kIOHIDVendorIDKey as String: 0x0CF2], // Lian Li / ENE
            [kIOHIDVendorIDKey as String: 0x0416], // Lian Li NuvoTon
            [kIOHIDVendorIDKey as String: 0x04FC]  // Sunplus / TL LCD
        ]
        
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingCriteria as CFArray)
        
        // Hot-plug: controller (re)appears or goes away (USB replug, power cycle on sleep/wake).
        let context = Unmanaged.passUnretained(self).toOpaque()
        let onChange: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context = context else { return }
            Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue().scheduleRescan()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, onChange, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, onChange, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            EventLog.shared.record("IOHIDManagerOpen failed: 0x\(String(UInt32(bitPattern: result), radix: 16))", level: .error)
            problem = HIDError.describe(result)
        }
    }
    
    private var rescanWorkItem: DispatchWorkItem?
    
    /// Coalesces bursts of attach/detach callbacks (one device exposes several HID interfaces) into a single rescan.
    private func scheduleRescan() {
        guard hasStarted else { return }
        rescanWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanDevices() }
        rescanWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
    
    private var wakeObserver: NSObjectProtocol?
    
    /// After sleep the controller may have lost its state (or been power-cycled): rescan, then re-send settings.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            EventLog.shared.record("System woke up")
            // Give USB a moment to re-enumerate before talking to the hardware.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard let self = self else { return }
                let before = self.connectedControllers.map { ObjectIdentifier($0) }
                self.scanDevices()
                // Controllers created by the rescan were initialized on creation; only refresh the surviving ones.
                for controller in self.connectedControllers where before.contains(ObjectIdentifier(controller)) {
                    controller.resetAfterWake()
                }
            }
        }
    }
    
    private var hasStarted = false
    
    public func start() {
        // Called from both AppDelegate and ContentView.onAppear (every window show) - must run only once.
        guard !hasStarted else { return }
        hasStarted = true
        scanDevices()
        startTelemetryPolling()
        observeWake()
    }
    
    // MARK: - Scanning
    
    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0
    }
    
    private static func interfaceInfo(of device: IOHIDDevice) -> HIDInterfaceInfo {
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        return HIDInterfaceInfo(
            key: PhysicalDeviceKey(
                vendorID: intProperty(device, kIOHIDVendorIDKey),
                productID: intProperty(device, kIOHIDProductIDKey),
                locationID: intProperty(device, kIOHIDLocationIDKey)
            ),
            usagePage: intProperty(device, kIOHIDPrimaryUsagePageKey),
            usage: intProperty(device, kIOHIDPrimaryUsageKey),
            registryID: registryID
        )
    }
    
    public func scanDevices() {
        // connectedControllers is read below to avoid creating a second controller for the same device, so scans must not overlap.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scanDevices() }
            return
        }
        guard let manager = hidManager else { return }
        isScanning = true
        defer { isScanning = false }
        
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            connectedControllers.removeAll()
            selectedController = nil
            return
        }
        
        var newControllers: [BaseDeviceController] = []
        
        for interfaces in InterfaceGrouping.groups(Array(devices), info: Self.interfaceInfo(of:)) {
            // One controller per physical device, however many HID interfaces it exposes.
            if let existing = connectedControllers.first(where: { controller in interfaces.contains { $0 === controller.rawDevice } }) {
                newControllers.append(existing)
                continue
            }
            if let controller = makeController(from: interfaces) {
                controller.onConnectionLost = { [weak self] in self?.scheduleRescan() }
                controller.initialize()
                newControllers.append(controller)
            }
        }
        
        if newControllers.map({ ObjectIdentifier($0) }) != connectedControllers.map({ ObjectIdentifier($0) }) {
            let names = newControllers.map { $0.deviceName }.joined(separator: ", ")
            EventLog.shared.record("Devices: \(names.isEmpty ? "none" : names)")
        }
        connectedControllers = newControllers
        if selectedController == nil || !newControllers.contains(where: { $0 === selectedController }) {
            selectedController = newControllers.first
        }
    }
    
    /// Picks the interface that actually speaks the controller protocol (a lone interface is used as is).
    private func makeController(from interfaces: [IOHIDDevice]) -> BaseDeviceController? {
        let info = Self.interfaceInfo(of: interfaces[0])
        let type = KnownDevices.controllerType(for: LianLiDeviceID(vendorID: UInt16(info.key.vendorID), productID: UInt16(info.key.productID)))
        guard type != .none else { return nil }
        
        if interfaces.count > 1 {
            for device in interfaces {
                let wrapper = IOHIDDeviceWrapper(device: device)
                if let profile = DeviceControllerFactory.detectProfile(device: wrapper) {
                    return DeviceControllerFactory.create(type: type, device: wrapper, rawDevice: device, detectedProfile: profile)
                }
            }
            EventLog.shared.record("No interface of \(type.rawValue) answered; falling back to the first one", level: .warning)
        }
        return DeviceControllerFactory.create(type: type, device: IOHIDDeviceWrapper(device: interfaces[0]), rawDevice: interfaces[0])
    }
    
    // MARK: - Periodic work
    
    private func startTelemetryPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let controllers = self.connectedControllers
            self.applyFanCurves(to: controllers)
            // Serial queue: a slow poll can never overlap the next one. Controllers publish their own RPM changes.
            self.pollQueue.async {
                for controller in controllers {
                    controller.pollTelemetry()
                }
            }
        }
        // .common: keep running while a menu is open, a slider is dragged or the window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
    
    /// Drives every non-synced fan group from its temperature curve. Runs on the main thread (published state lives there);
    /// the actual HID write is queued by the controller.
    private func applyFanCurves(to controllers: [BaseDeviceController]) {
        let temperature = SystemThermalMonitor.shared.currentTemperature
        if temperature != nil { lastValidTemperatureDate = Date() }
        
        for controller in controllers where controller.capabilities.contains(.coolingControl) {
            let commands: [FanCurveEngine.Command]
            if let temperature = temperature {
                commands = FanCurveEngine.commands(for: controller.groupStates, temperature: temperature)
            } else {
                commands = FanCurveEngine.failsafeCommands(
                    for: controller.groupStates,
                    secondsWithoutReading: Date().timeIntervalSince(lastValidTemperatureDate)
                )
            }
            for command in commands {
                controller.setFanSpeed(groupIndex: command.group, percent: command.percent)
            }
        }
    }
    
    private var lastValidTemperatureDate = Date()
    
    /// Hands fan control back to the motherboard (without changing saved settings). Call on quit: nobody will follow the curve afterwards.
    public func releaseAllToMotherboard() {
        for controller in connectedControllers {
            controller.releaseToMotherboard()
        }
    }
}
