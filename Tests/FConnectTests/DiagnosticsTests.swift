import Foundation
import Testing

@Suite struct DiagnosticsTests {
    private func sample(devices: [DiagnosticsReport.Device] = [], sensors: [DiagnosticsReport.Sensor] = [], log: [String] = []) -> DiagnosticsReport {
        DiagnosticsReport(appVersion: "1.0 (1)", systemVersion: "Version 15.0", architecture: "arm64", cpu: "Test CPU",
                          problem: nil, devices: devices, sensors: sensors, logLines: log)
    }
    
    @Test func emptyReportSaysSo() {
        let text = sample().render()
        #expect(text.contains("Problem: none"))
        #expect(text.contains("none connected"))
        #expect(text.contains("none found"))
        #expect(text.contains("Recent events (0)"))
    }
    
    @Test func deviceAndSensorDetailsAppear() {
        let device = DiagnosticsReport.Device(
            name: "UNI FAN", type: "SL V2 Fan", usbID: "0x0CF2:0xA103", firmware: "v0.7", firmwareSignature: "100/197",
            status: "connected", health: "failed polls in a row: 0, last IOKit error: none", detection: "firmware signature and USB ID agree", rpmSync: true, argbSync: false,
            groups: [.init(name: "Back", fanCount: 3, rpm: 510, control: "MB Sync", hidden: false),
                     .init(name: "Group 2", fanCount: 3, rpm: 0, control: "Quiet, 33%", hidden: true)]
        )
        let text = sample(devices: [device], sensors: [.init(name: "CPU", temperature: 43.64, isSelected: true)], log: ["12:00:00 hello"]).render()
        #expect(text.contains("0x0CF2:0xA103"))
        #expect(text.contains("signature 100/197"))
        #expect(text.contains("model detection: firmware signature and USB ID agree"))
        #expect(text.contains("status: connected; failed polls in a row: 0"))
        #expect(text.contains("RPM on, ARGB off"))
        #expect(text.contains("- Back: 3 fans, 510 RPM, MB Sync\n"))
        #expect(text.contains("- Group 2: 3 fans, 0 RPM, Quiet, 33%, hidden"))
        #expect(text.contains("CPU: 43.6 °C (used for fan curves)"))
        #expect(text.contains("  12:00:00 hello"))
    }
}

@Suite struct EventLogTests {
    @Test func keepsOnlyTheNewestEntries() {
        let log = EventLog(capacity: 3)
        for i in 1...5 { log.record("event \(i)") }
        #expect(log.lines.count == 3)
        #expect(log.lines.first?.hasSuffix("event 3") == true)
        #expect(log.lines.last?.hasSuffix("event 5") == true)
    }
    
    @Test func marksSeverity() {
        let log = EventLog()
        log.record("bad", level: .error)
        #expect(log.lines.last?.contains("ERROR bad") == true)
    }
}
