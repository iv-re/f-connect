import Foundation
import IOKit

/// Gathers the live state for `DiagnosticsReport`. Main thread only (reads published controller state).
@MainActor
public enum DiagnosticsCollector {
    static let maxLogLines = 80
    
    public static func collect() -> DiagnosticsReport {
        let manager = DeviceManager.shared
        let monitor = SystemThermalMonitor.shared
        
        let devices = manager.connectedControllers.map { controller in
            DiagnosticsReport.Device(
                name: controller.deviceName,
                type: controller.deviceType.rawValue,
                usbID: usbID(of: controller.rawDevice),
                firmware: controller.firmwareVersion,
                firmwareSignature: controller.firmwareSignature ?? "unknown",
                status: controller.connectionIssue ?? "connected",
                health: controller.healthSummary,
                detection: controller.detectionNote ?? "unknown",
                rpmSync: controller.isMotherboardRPMSync,
                argbSync: controller.isMotherboardARGBSync,
                groups: controller.groupStates.map {
                    DiagnosticsReport.Group(
                        name: $0.name,
                        fanCount: $0.fanCount,
                        rpm: $0.rpm,
                        control: StatusMenuFormatter.controlDescription(for: $0),
                        hidden: $0.isHidden
                    )
                }
            )
        }
        let sensors = monitor.availableSensors.map {
            DiagnosticsReport.Sensor(name: $0.name, temperature: $0.temperature, isSelected: $0.id == monitor.selectedSensorID)
        }
        
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return DiagnosticsReport(
            appVersion: "\(version) (\(build))",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture(),
            cpu: (sysctlString("machdep.cpu.brand_string") ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines),
            problem: manager.problem,
            devices: devices,
            sensors: sensors,
            logLines: Array(EventLog.shared.lines.suffix(maxLogLines))
        )
    }
    
    private static func usbID(of device: IOHIDDevice?) -> String {
        guard let device = device else { return "unknown" }
        func value(_ key: String) -> Int? {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
        }
        guard let vid = value(kIOHIDVendorIDKey), let pid = value(kIOHIDProductIDKey) else { return "unknown" }
        return String(format: "0x%04X:0x%04X", vid, pid)
    }
    
    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
