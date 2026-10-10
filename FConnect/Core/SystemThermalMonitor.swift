import Foundation
import IOKit

public struct ThermalSensorItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public var temperature: Double
    
    public init(id: String, name: String, temperature: Double) {
        self.id = id
        self.name = name
        self.temperature = temperature
    }
}

/// Reads the CPU package temperature from the AMDRyzenCPUPowerManagement kext (same source as AMD Power Gadget).
/// Selector 4 returns [packagePower, packageTemp, pstate, per-core clocks...] as floats; no privileges needed for reads.
private final class RyzenPMClient {
    private static let readSelector: UInt32 = 4
    private var connection: io_connect_t = 0
    
    deinit { disconnect() }
    
    private func disconnect() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }
    
    private func connect() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AMDRyzenCPUPowerManagement"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return false }
        connection = conn
        return true
    }
    
    /// Package temperature in °C, or nil if the kext is absent or returns an implausible value.
    func packageTemperature() -> Double? {
        guard connect() else { return nil }
        var scalars = [UInt64](repeating: 0, count: 4)
        var scalarCount: UInt32 = 4
        var output = [Float](repeating: 0, count: 128)
        var outputSize = output.count * MemoryLayout<Float>.size
        let ret = IOConnectCallMethod(connection, Self.readSelector, nil, 0, nil, 0, &scalars, &scalarCount, &output, &outputSize)
        guard ret == KERN_SUCCESS else {
            disconnect() // kext reloaded or connection went stale; reconnect on next sample
            return nil
        }
        guard outputSize >= 2 * MemoryLayout<Float>.size else { return nil }
        let temp = Double(output[1])
        return (temp > 0 && temp < 125) ? temp : nil
    }
}

public final class SystemThermalMonitor: ObservableObject {
    public static let shared = SystemThermalMonitor()
    private static let selectedSensorKey = "FConnect_selectedSensorID"
    
    @Published public var availableSensors: [ThermalSensorItem] = []
    @Published public var selectedSensorID: String = UserDefaults.standard.string(forKey: SystemThermalMonitor.selectedSensorKey) ?? "" {
        didSet { UserDefaults.standard.set(selectedSensorID, forKey: Self.selectedSensorKey) }
    }
    
    /// Temperature of the selected sensor, or nil when there is no valid reading.
    /// Callers must not drive fans from a made-up value, so there is deliberately no default here.
    public var currentTemperature: Double? {
        Self.temperature(of: selectedSensorID, in: availableSensors, sampledAt: lastSampleDate, now: Date())
    }
    
    /// A reading older than `maxReadingAge` means sampling has stalled (hung IOKit call, stopped timer): treat it as no reading.
    static func temperature(of sensorID: String, in sensors: [ThermalSensorItem], sampledAt: Date, now: Date) -> Double? {
        guard now.timeIntervalSince(sampledAt) <= maxReadingAge else { return nil }
        return sensors.first(where: { $0.id == sensorID })?.temperature
    }
    
    static let maxReadingAge: TimeInterval = 10
    private var lastSampleDate = Date.distantPast
    
    /// How long a chosen sensor may be missing before another one is selected (e.g. the GPU was swapped).
    static let selectionFallbackDelay: TimeInterval = 30
    private var selectedMissingSince: Date?
    
    /// Decides which sensor is selected after a sample. A saved choice is kept through short outages; if it stays gone
    /// the first available sensor takes over, so the fans are never tied to a sensor that no longer exists.
    static func resolveSelection(
        current: String,
        missingSince: Date?,
        sensors: [ThermalSensorItem],
        now: Date
    ) -> (id: String, missingSince: Date?) {
        guard let first = sensors.first else { return (current, missingSince) }
        if sensors.contains(where: { $0.id == current }) { return (current, nil) }
        if current.isEmpty { return (first.id, nil) }
        // Ids from older builds ("gpu_0") were positional and can never match again.
        if current.range(of: #"^gpu_\d+$"#, options: .regularExpression) != nil { return (first.id, nil) }
        let since = missingSince ?? now
        return now.timeIntervalSince(since) >= selectionFallbackDelay ? (first.id, nil) : (current, since)
    }
    
    private var timer: DispatchSourceTimer?
    private var gpuNames: [UInt64: String] = [:]     // monitorQueue only
    private let monitorQueue = DispatchQueue(label: "com.lconnect.thermalMonitor", qos: .utility)
    private let ryzen = RyzenPMClient()
    private let smc = SMCSensorProvider(makeTransport: { AppleSMCConnection() })
    private let cpuName: String
    
    private init() {
        cpuName = Self.cpuBrandString()
        startMonitoring()
    }
    
    public func startMonitoring() {
        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            // Runs on its own queue: sampling does not depend on the main run loop (menus, drags, busy layout).
            let source = DispatchSource.makeTimerSource(queue: self.monitorQueue)
            source.schedule(deadline: .now(), repeating: 1.5, leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in self?.sampleTemperatures() }
            source.resume()
            self.timer = source
        }
    }
    
    private func sampleTemperatures() {
        var sensors: [ThermalSensorItem] = []
        
        if let cpuTemp = ryzen.packageTemperature() {
            sensors.append(ThermalSensorItem(id: "cpu_package", name: cpuName, temperature: cpuTemp))
        }
        // Intel (and AMD with the SMC plugin): whatever CPU sensors the SMC publishes, best default first.
        sensors.append(contentsOf: smc.sample())
        sensors.append(contentsOf: discoverGPUs())
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastSampleDate = Date()
            if self.availableSensors != sensors {
                self.availableSensors = sensors
            }
            let resolved = Self.resolveSelection(
                current: self.selectedSensorID,
                missingSince: self.selectedMissingSince,
                sensors: sensors,
                now: self.lastSampleDate
            )
            self.selectedMissingSince = resolved.missingSince
            if resolved.id != self.selectedSensorID { self.selectedSensorID = resolved.id }
        }
    }
    
    /// Reads the temperature of every GPU that reports one. Names are looked up once per GPU, and only the single
    /// property that is needed is fetched (copying the whole registry entry every sample is wasteful).
    private func discoverGPUs() -> [ThermalSensorItem] {
        var results: [ThermalSensorItem] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return results
        }
        defer { IOObjectRelease(iterator) }
        
        var seen = Set<UInt64>()
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            guard seen.insert(registryID).inserted else { continue }
            
            guard let perf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let temp = (perf["Temperature(C)"] as? NSNumber)?.intValue,
                  temp > 0 && temp < 125 else { continue }
            
            if gpuNames[registryID] == nil {
                gpuNames[registryID] = Self.gpuName(of: service) ?? "GPU \(results.count + 1)"
            }
            results.append(ThermalSensorItem(
                id: "gpu_" + String(registryID, radix: 16),
                name: gpuNames[registryID] ?? "GPU",
                temperature: Double(temp)
            ))
        }
        return results
    }
    
    /// Clean hardware model (e.g. "AMD Radeon RX 6800 XT") from the accelerator's PCI parent.
    private static func gpuName(of service: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        guard let data = IORegistryEntryCreateCFProperty(parent, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
              let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(["\0", " "]))
        else { return nil }
        return name.isEmpty ? nil : name
    }
    
    /// "AMD Ryzen 9 5950X 16-Core Processor" -> "AMD Ryzen 9 5950X"
    static func simplifiedBrand(_ full: String) -> String {
        if full.isEmpty { return "CPU (Processor)" }
        let simplified = full.replacingOccurrences(of: #"\s+\d+-Core.*$|\s+Processor$"#, with: "", options: .regularExpression)
        return simplified.isEmpty ? full : simplified
    }
    
    private static func cpuBrandString() -> String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return simplifiedBrand(String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
