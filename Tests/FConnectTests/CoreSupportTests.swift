import Foundation
import IOKit
import Testing

@Suite("HID error messages")
struct HIDErrorTests {
    @Test func explainsTheCausesAUserCanFix() {
        #expect(HIDError.describe(kIOReturnNotPermitted).contains("Input Monitoring"))
        #expect(HIDError.describe(kIOReturnExclusiveAccess).contains("exclusive access"))
        #expect(HIDError.describe(kIOReturnNoDevice).contains("disconnected"))
        #expect(HIDError.describe(kIOReturnNotAttached).contains("disconnected"))
        #expect(HIDError.describe(kIOReturnTimeout).contains("not responding"))
        #expect(HIDError.describe(kIOReturnNotOpen).contains("closed"))
    }
    
    @Test func unknownCodesAreShownInHexForBugReports() {
        let text = HIDError.describe(0x1234)
        #expect(text.contains("0x1234"))
    }
}

@Suite("Interface grouping")
struct InterfaceGroupingTests {
    private func iface(_ vid: Int, _ pid: Int, loc: Int, page: Int = 0xFF00, usage: Int = 1, id: UInt64) -> HIDInterfaceInfo {
        HIDInterfaceInfo(key: PhysicalDeviceKey(vendorID: vid, productID: pid, locationID: loc), usagePage: page, usage: usage, registryID: id)
    }
    
    @Test func interfacesOfOnePhysicalDeviceShareAGroup() {
        let items = [iface(0xCF2, 0xA105, loc: 5, page: 1, usage: 6, id: 20), iface(0xCF2, 0xA105, loc: 5, page: 0xFF00, usage: 1, id: 10)]
        let groups = InterfaceGrouping.groups(items) { $0 }
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }
    
    @Test func twoIdenticalHubsOnDifferentPortsStayApart() {
        let items = [iface(0xCF2, 0xA105, loc: 5, id: 1), iface(0xCF2, 0xA105, loc: 9, id: 2)]
        #expect(InterfaceGrouping.groups(items) { $0 }.count == 2)
    }
    
    @Test func differentProductsOnTheSamePortStayApart() {
        let items = [iface(0xCF2, 0xA105, loc: 5, id: 1), iface(0xCF2, 0xA104, loc: 5, id: 2)]
        #expect(InterfaceGrouping.groups(items) { $0 }.count == 2)
    }
    
    @Test func orderingIsDeterministicRegardlessOfInputOrder() {
        let a = iface(0xCF2, 0xA105, loc: 5, page: 1, usage: 6, id: 30)
        let b = iface(0xCF2, 0xA105, loc: 5, page: 0xFF00, usage: 1, id: 10)
        let c = iface(0xCF2, 0xA105, loc: 5, page: 0xFF00, usage: 1, id: 20)
        let forward = InterfaceGrouping.groups([a, b, c]) { $0 }[0].map(\.registryID)
        let backward = InterfaceGrouping.groups([c, b, a]) { $0 }[0].map(\.registryID)
        #expect(forward == backward)
        #expect(forward == [30, 10, 20], "lowest usage page first, then usage, then registry ID")
    }
    
    @Test func emptyInputGivesNoGroups() {
        #expect(InterfaceGrouping.groups([HIDInterfaceInfo]()) { $0 }.isEmpty)
    }
}

@Suite("Sensor selection")
struct SensorSelectionTests {
    private let cpu = ThermalSensorItem(id: "cpu_package", name: "CPU", temperature: 44)
    private let gpu = ThermalSensorItem(id: "gpu_abc", name: "GPU", temperature: 50)
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    
    private func resolve(_ current: String, _ missing: Date? = nil, _ sensors: [ThermalSensorItem], at offset: TimeInterval = 0) -> (id: String, missingSince: Date?) {
        SystemThermalMonitor.resolveSelection(current: current, missingSince: missing, sensors: sensors, now: t0.addingTimeInterval(offset))
    }
    
    @Test func keepsAnAvailableChoice() {
        let r = resolve("gpu_abc", Date(), [cpu, gpu])
        #expect(r.id == "gpu_abc" && r.missingSince == nil)
    }
    
    @Test func picksTheFirstSensorWhenNothingIsChosenYet() {
        #expect(resolve("", nil, [cpu, gpu]).id == "cpu_package")
    }
    
    @Test func keepsAMissingChoiceThroughAShortOutage() {
        let first = resolve("gpu_abc", nil, [cpu])
        #expect(first.id == "gpu_abc")
        #expect(first.missingSince == t0)
        let later = resolve("gpu_abc", first.missingSince, [cpu], at: SystemThermalMonitor.selectionFallbackDelay - 1)
        #expect(later.id == "gpu_abc")
    }
    
    @Test func fallsBackWhenTheChoiceStaysGone() {
        let r = resolve("gpu_abc", t0, [cpu], at: SystemThermalMonitor.selectionFallbackDelay)
        #expect(r.id == "cpu_package" && r.missingSince == nil)
    }
    
    @Test func recoveryResetsTheOutageClock() {
        #expect(resolve("gpu_abc", t0, [cpu, gpu], at: 10).missingSince == nil)
    }
    
    @Test func positionalIdsFromOlderBuildsAreReplacedImmediately() {
        #expect(resolve("gpu_0", nil, [cpu, gpu]).id == "cpu_package")
        #expect(resolve("gpu_12", nil, [cpu, gpu]).id == "cpu_package")
        #expect(resolve("gpu_abc", nil, [cpu]).id == "gpu_abc", "hex registry ids are not legacy")
    }
    
    @Test func withoutAnySensorNothingChanges() {
        let r = resolve("cpu_package", t0, [], at: 500)
        #expect(r.id == "cpu_package" && r.missingSince == t0)
    }
}

@Suite("CPU name")
struct CPUNameTests {
    @Test func stripsCoreCountAndProcessorSuffix() {
        let cases = [
            ("AMD Ryzen 9 5950X 16-Core Processor", "AMD Ryzen 9 5950X"),
            ("AMD Ryzen 5 3600 6-Core Processor", "AMD Ryzen 5 3600"),
            ("AMD Ryzen Threadripper 3990X 64-Core Processor", "AMD Ryzen Threadripper 3990X"),
            ("AMD Ryzen 9 7950X3D 16-Core Processor", "AMD Ryzen 9 7950X3D"),
            ("Intel(R) Core(TM) i9-9900K CPU @ 3.60GHz", "Intel(R) Core(TM) i9-9900K CPU @ 3.60GHz"),
            ("Apple M2 Max", "Apple M2 Max"),
            ("Some Processor", "Some")
        ]
        for (raw, expected) in cases { #expect(SystemThermalMonitor.simplifiedBrand(raw) == expected, "\(raw)") }
    }
    
    @Test func emptyNameGetsAPlaceholder() {
        #expect(SystemThermalMonitor.simplifiedBrand("") == "CPU (Processor)")
    }
}

@Suite("Status bar menu text")
struct StatusMenuFormatterTests {
    private func group(sync: Bool = false, preset: FanSpeedProfilePreset = .standard, duty: Int = 40, rpm: Int = 700, name: String? = nil) -> FanGroupState {
        var g = FanGroupState(id: 0)
        g.isRPMSync = sync; g.profilePreset = preset; g.targetDuty = duty; g.rpm = rpm; g.customName = name
        return g
    }
    
    @Test func syncedGroupSaysMBSync() {
        #expect(StatusMenuFormatter.groupLine(group(sync: true, rpm: 525)) == "Group 1: 525 RPM (MB Sync)")
    }
    
    @Test func presetGroupShowsPresetAndDuty() {
        #expect(StatusMenuFormatter.groupLine(group(preset: .quiet, duty: 33, rpm: 720)) == "Group 1: 720 RPM (Quiet, 33%)")
        #expect(StatusMenuFormatter.groupLine(group(preset: .highSpeed, duty: 85)).contains("(High Speed, 85%)"))
    }
    
    @Test func manualCurveIsCalledCustom() {
        #expect(StatusMenuFormatter.controlDescription(for: group(preset: .manual, duty: 61)) == "Custom, 61%")
    }
    
    @Test func syncWinsOverAPresetThatIsStillSaved() {
        #expect(StatusMenuFormatter.controlDescription(for: group(sync: true, preset: .quiet)) == "MB Sync")
    }
    
    @Test func usesTheGroupsCustomName() {
        #expect(StatusMenuFormatter.groupLine(group(sync: true, name: "Front")).hasPrefix("Front: "))
    }
    
    @Test func everyPresetHasADescription() {
        for preset in FanSpeedProfilePreset.allCases {
            #expect(!StatusMenuFormatter.controlDescription(for: group(preset: preset)).isEmpty)
        }
    }
    
    @Test func theSectionIsTitledFanSpeeds() {
        #expect(StatusMenuFormatter.sectionTitle == "Fan Speeds")
    }
}
