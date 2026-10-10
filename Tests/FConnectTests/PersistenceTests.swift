import Foundation
import Testing

/// Saved settings outlive app versions. Anything written by another version must still load.
@Suite("Settings persistence")
struct PersistenceTests {
    private func decode(_ json: String) throws -> [FanGroupState] {
        try JSONDecoder().decode([FanGroupState].self, from: Data(json.utf8))
    }
    
    @Test func roundTripKeepsEverySetting() throws {
        var g = FanGroupState(id: 2)
        g.customName = "Front"; g.isHidden = true; g.fanCount = 5; g.targetDuty = 61
        g.lightingMode = .tide; g.speedIndex = 4; g.brightnessPercent = 35; g.direction = 1
        g.staticColor = .orange; g.isRPMSync = true; g.profilePreset = .highSpeed
        g.curvePoints = [CurvePoint(temp: 10, speed: 15), CurvePoint(temp: 90, speed: 95)]
        
        let back = try JSONDecoder().decode([FanGroupState].self, from: JSONEncoder().encode([g]))[0]
        
        #expect(back.id == 2 && back.customName == "Front" && back.isHidden && back.fanCount == 5 && back.targetDuty == 61)
        #expect(back.lightingMode == .tide && back.speedIndex == 4 && back.brightnessPercent == 35 && back.direction == 1)
        #expect(back.staticColor == .orange && back.isRPMSync && back.profilePreset == .highSpeed)
        #expect(back.curvePoints.map(\.temp) == [10, 90] && back.curvePoints.map(\.speed) == [15, 95])
    }
    
    /// Regression guard: with synthesized Codable a single missing key made the whole saved blob unreadable.
    @Test func aMissingKeyFallsBackToItsDefaultInsteadOfLosingEverything() throws {
        let groups = try decode(#"[{"id": 1, "targetDuty": 77, "isRPMSync": true}]"#)
        #expect(groups.count == 1)
        #expect(groups[0].id == 1 && groups[0].targetDuty == 77 && groups[0].isRPMSync)
        #expect(groups[0].fanCount == 3)
        #expect(groups[0].lightingMode == .rainbow)
        #expect(groups[0].curvePoints.count >= 2)
    }
    
    @Test func unknownKeysFromNewerVersionsAreIgnored() throws {
        let groups = try decode(#"[{"id": 0, "targetDuty": 50, "someFutureSetting": {"a": 1}, "another": [1, 2, 3]}]"#)
        #expect(groups[0].targetDuty == 50)
    }
    
    @Test func anUnknownEnumValueFallsBackToTheDefault() throws {
        let groups = try decode(#"[{"id": 0, "lightingMode": 9999, "profilePreset": "Turbo", "targetDuty": 44}]"#)
        #expect(groups[0].lightingMode == .rainbow)
        #expect(groups[0].profilePreset == .standard)
        #expect(groups[0].targetDuty == 44, "valid fields next to a bad one must survive")
    }
    
    @Test func aWronglyTypedFieldFallsBackToTheDefault() throws {
        let groups = try decode(#"[{"id": 0, "fanCount": "three", "isHidden": 1, "targetDuty": 30}]"#)
        #expect(groups[0].fanCount == 3)
        #expect(groups[0].targetDuty == 30)
    }
    
    @Test func aDegenerateCurveIsReplacedByTheDefault() throws {
        let groups = try decode(#"[{"id": 0, "curvePoints": [{"temp": 40, "speed": 40}]}]"#)
        #expect(groups[0].curvePoints.count >= 2)
        #expect(try decode(#"[{"id": 0, "curvePoints": []}]"#)[0].curvePoints.count >= 2)
    }
    
    @Test func liveRPMIsNeverSavedButOldBlobsContainingItStillLoad() throws {
        var g = FanGroupState(id: 0)
        g.rpm = 1234
        let json = String(data: try JSONEncoder().encode([g]), encoding: .utf8)!
        #expect(!json.contains("rpm\""), "telemetry is not a setting")
        
        let legacy = try decode(#"[{"id": 0, "rpm": 999, "targetDuty": 40}]"#)
        #expect(legacy[0].rpm == 0)
        #expect(legacy[0].targetDuty == 40)
    }
    
    @Test func curvePointIdsAreNotPersisted() throws {
        let data = try JSONEncoder().encode(CurvePoint(temp: 30, speed: 40))
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("id"))
        let back = try JSONDecoder().decode(CurvePoint.self, from: data)
        #expect(back.temp == 30 && back.speed == 40)
    }
    
    // MARK: Controller restore
    
    private func controller(with blob: String?) -> (Ene6K77Controller, UserDefaults, String) {
        let name = "FConnectTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        if let blob = blob { defaults.set(Data(blob.utf8), forKey: Ene6K77Profile.slV2.prefsPrefix + "groups") }
        return (Ene6K77Controller(device: MockHIDDevice(), profile: .slV2, defaults: defaults), defaults, name)
    }
    
    @Test func controllerKeepsSavedPortsAndFillsMissingOnes() {
        let (c, d, name) = controller(with: #"[{"id": 1, "targetDuty": 88, "isRPMSync": true}, {"id": 3, "customName": "Rear"}]"#)
        defer { d.removePersistentDomain(forName: name) }
        #expect(c.groupStates.map(\.id) == [0, 1, 2, 3])
        #expect(c.groupStates[1].targetDuty == 88 && c.groupStates[1].isRPMSync)
        #expect(c.groupStates[3].customName == "Rear")
        #expect(c.groupStates[0].targetDuty == FanGroupState(id: 0).targetDuty)
    }
    
    @Test func controllerStartsFromDefaultsWhenTheBlobIsCorrupt() {
        for blob in ["not json at all", "{}", "[1, 2, 3]", ""] {
            let (c, d, name) = controller(with: blob)
            defer { d.removePersistentDomain(forName: name) }
            #expect(c.groupStates.map(\.id) == [0, 1, 2, 3], "blob: \(blob)")
        }
    }
    
    @Test func controllerStartsFromDefaultsWithoutAnySavedData() {
        let (c, d, name) = controller(with: nil)
        defer { d.removePersistentDomain(forName: name) }
        #expect(c.groupStates.count == 4)
        #expect(c.groupStates.allSatisfy { $0.fanCount == 3 })
    }
}
