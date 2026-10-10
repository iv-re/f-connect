import Foundation

/// Plain-text support report. Built from plain values so the layout is testable without hardware or system calls.
/// Deliberately contains no serial numbers, user names or file paths; only what is needed to reproduce a problem.
public struct DiagnosticsReport {
    public struct Group {
        public var name: String
        public var fanCount: Int
        public var rpm: Int
        public var control: String
        public var hidden: Bool
        
        public init(name: String, fanCount: Int, rpm: Int, control: String, hidden: Bool) {
            self.name = name
            self.fanCount = fanCount
            self.rpm = rpm
            self.control = control
            self.hidden = hidden
        }
    }
    
    public struct Device {
        public var name: String
        public var type: String
        public var usbID: String
        public var firmware: String
        public var firmwareSignature: String
        public var status: String
        public var health: String
        public var detection: String
        public var rpmSync: Bool
        public var argbSync: Bool
        public var groups: [Group]
        
        public init(name: String, type: String, usbID: String, firmware: String, firmwareSignature: String,
                    status: String, health: String, detection: String, rpmSync: Bool, argbSync: Bool, groups: [Group]) {
            self.name = name
            self.type = type
            self.usbID = usbID
            self.firmware = firmware
            self.firmwareSignature = firmwareSignature
            self.status = status
            self.health = health
            self.detection = detection
            self.rpmSync = rpmSync
            self.argbSync = argbSync
            self.groups = groups
        }
    }
    
    public struct Sensor {
        public var name: String
        public var temperature: Double
        public var isSelected: Bool
        
        public init(name: String, temperature: Double, isSelected: Bool) {
            self.name = name
            self.temperature = temperature
            self.isSelected = isSelected
        }
    }
    
    public var appVersion: String
    public var systemVersion: String
    public var architecture: String
    public var cpu: String
    public var problem: String?
    public var devices: [Device]
    public var sensors: [Sensor]
    public var logLines: [String]
    
    public init(appVersion: String, systemVersion: String, architecture: String, cpu: String, problem: String?,
                devices: [Device], sensors: [Sensor], logLines: [String]) {
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.architecture = architecture
        self.cpu = cpu
        self.problem = problem
        self.devices = devices
        self.sensors = sensors
        self.logLines = logLines
    }
    
    public func render() -> String {
        var out: [String] = ["F-Connect diagnostics", ""]
        out.append("App: \(appVersion)")
        out.append("macOS: \(systemVersion) (\(architecture))")
        out.append("CPU: \(cpu)")
        out.append("Problem: \(problem ?? "none")")
        
        out.append("")
        out.append("Devices (\(devices.count))")
        if devices.isEmpty { out.append("  none connected") }
        for (index, device) in devices.enumerated() {
            out.append("  [\(index + 1)] \(device.name)")
            out.append("      type: \(device.type), USB ID: \(device.usbID)")
            out.append("      firmware: \(device.firmware) (signature \(device.firmwareSignature))")
            out.append("      model detection: \(device.detection)")
            out.append("      status: \(device.status); \(device.health)")
            out.append("      motherboard sync: RPM \(device.rpmSync ? "on" : "off"), ARGB \(device.argbSync ? "on" : "off")")
            for group in device.groups {
                let hidden = group.hidden ? ", hidden" : ""
                out.append("      - \(group.name): \(group.fanCount) fans, \(group.rpm) RPM, \(group.control)\(hidden)")
            }
        }
        
        out.append("")
        out.append("Temperature sensors (\(sensors.count))")
        if sensors.isEmpty { out.append("  none found") }
        for sensor in sensors {
            let mark = sensor.isSelected ? " (used for fan curves)" : ""
            out.append("  \(sensor.name): \(String(format: "%.1f", sensor.temperature)) °C\(mark)")
        }
        
        out.append("")
        out.append("Recent events (\(logLines.count))")
        if logLines.isEmpty { out.append("  empty") }
        out.append(contentsOf: logLines.map { "  \($0)" })
        return out.joined(separator: "\n") + "\n"
    }
}
