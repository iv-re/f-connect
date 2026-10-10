import Foundation
import IOKit
import Testing

/// Controller behavior against a mock hub. Every test uses its own UserDefaults suite, so the developer's real settings are never touched.
@MainActor
@Suite("Ene6K77Controller")
struct ControllerTests {
    private struct Rig {
        let controller: Ene6K77Controller
        let device: MockHIDDevice
        let defaults: UserDefaults
        let suiteName: String
    }
    
    private func makeRig(
        profile: Ene6K77Profile = .slV2,
        reply: (([UInt8]) -> [UInt8]?)? = Replies.healthyHub(),
        saved: ((inout [FanGroupState]) -> Void)? = nil
    ) -> Rig {
        let suiteName = "FConnectTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let device = MockHIDDevice()
        device.replyProvider = reply
        let controller = Ene6K77Controller(device: device, profile: profile, defaults: defaults)
        if let saved = saved {
            saved(&controller.groupStates)
        }
        return Rig(controller: controller, device: device, defaults: defaults, suiteName: suiteName)
    }
    
    private func cleanUp(_ rig: Rig) {
        rig.defaults.removePersistentDomain(forName: rig.suiteName)
    }
    
    // MARK: - Initialization
    
    @Test func initializationAppliesSavedSyncStatePerGroup() async {
        // Port 1 manual, ports 2-4 synced with the motherboard (the real-world mixed setup).
        let rig = makeRig(saved: { $0[0].isRPMSync = false; $0[1].isRPMSync = true; $0[2].isRPMSync = true; $0[3].isRPMSync = true })
        defer { cleanUp(rig) }
        
        rig.controller.initialize()
        rig.controller.flushPendingWrites()
        
        let p = Ene6K77Profile.slV2
        let sent = rig.device.features
        #expect(sent.contains(p.rpmSyncPacket(group: 0, sync: false)))
        for g in 1...3 { #expect(sent.contains(p.rpmSyncPacket(group: g, sync: true))) }
        #expect(!sent.contains(p.rpmSyncPacket(group: 0, sync: true)), "a manual port must never be handed to the motherboard")
    }
    
    @Test func initializationWritesDutyOnlyForManualPorts() async {
        let rig = makeRig(saved: { $0[0].isRPMSync = false; $0[0].targetDuty = 42; for i in 1...3 { $0[i].isRPMSync = true } })
        defer { cleanUp(rig) }
        
        rig.controller.initialize()
        rig.controller.flushPendingWrites()
        
        let dutyPackets = rig.device.features.filter { $0.count == 4 && ($0[1] & 0xF0) == 0x20 }
        #expect(dutyPackets == [Ene6K77Profile.slV2.fanSpeedPacket(group: 0, percent: 42)])
    }
    
    @Test func initializationSendsQuantityMergeAndArgbForTheModel() async {
        let rig = makeRig(profile: .alV2, saved: { for i in 0..<4 { $0[i].fanCount = 4; $0[i].isRPMSync = true } })
        defer { cleanUp(rig) }
        
        rig.controller.initialize()
        rig.controller.flushPendingWrites()
        
        let sent = rig.device.features
        for g in 0..<4 { #expect(sent.contains(Ene6K77Profile.alV2.quantityPacket(group: g, count: 4))) }
        #expect(sent.contains(Ene6K77Profile.alV2.noMergePackets()[0]))
        #expect(sent.contains(Ene6K77Profile.alV2.argbSyncPacket(enabled: false)))
    }
    
    @Test func initializationReadsFirmwareVersion() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        
        rig.controller.initialize()
        rig.controller.flushPendingWrites()
        await drainMainQueue()
        
        #expect(rig.controller.firmwareVersion == "v0.7")
    }
    
    @Test func initializationReplacesAnUnsupportedSavedModeWithStaticColor() async {
        // A mode the model cannot display must not be sent as a raw byte.
        let rig = makeRig(profile: .slInfinity, saved: { $0[0].lightingMode = .neon })
        defer { cleanUp(rig) }
        
        rig.controller.initialize()
        rig.controller.flushPendingWrites()
        
        let sent = rig.device.features
        let staticOnInnerRing = Ene6K77Profile.slInfinity.effectPacket(port: 0, mode: 1, speed: 0, direction: 0, brightness: 0)
        let rawNeon = Ene6K77Profile.slInfinity.effectPacket(port: 0, mode: FanLightingMode.neon.protocolByte, speed: 0, direction: 0, brightness: 0)
        #expect(sent.contains(staticOnInnerRing))
        #expect(!sent.contains(rawNeon), "the unsupported mode's raw byte must never reach the hardware")
    }
    
    @Test func initializationNeverBlocksTheCaller() async {
        // initialize() must return before the (slow) hardware work is done; the writes arrive on the queue.
        let rig = makeRig()
        defer { cleanUp(rig) }
        rig.controller.initialize()
        rig.controller.flushPendingWrites()
        #expect(!rig.device.features.isEmpty)
    }
    
    // MARK: - Telemetry
    
    @Test func pollPublishesRPM() async {
        let rig = makeRig(reply: Replies.healthyHub(rpms: [525, 0, 540, 531]))
        defer { cleanUp(rig) }
        
        rig.controller.pollTelemetry()
        await drainMainQueue()
        
        #expect(rig.controller.groupStates.map(\.rpm) == [525, 0, 540, 531])
    }
    
    /// Regression for the "20580 / 50951 RPM" bug: a stale firmware reply must be retried, not displayed.
    @Test func pollRetriesWhenTheReplyIsStale() async {
        var calls = 0
        let rig = makeRig(reply: { request in
            guard request == Ene6K77Profile.rpmRequest else { return nil }
            calls += 1
            return calls == 1 ? Replies.firmware() : Replies.rpmWithHeader([600, 0, 610, 620])
        })
        defer { cleanUp(rig) }
        
        rig.controller.pollTelemetry()
        await drainMainQueue()
        
        #expect(rig.controller.groupStates.map(\.rpm) == [600, 0, 610, 620])
        #expect(rig.device.features.filter { $0 == Ene6K77Profile.rpmRequest }.count == 2)
    }
    
    @Test func pollDoesNotPublishAReplyWithTheWrongHeader() async {
        var foreign = Replies.rpmWithHeader([111, 222, 333, 444])
        foreign[1] = 0x00
        let rig = makeRig(reply: { _ in foreign })
        defer { cleanUp(rig) }
        
        rig.controller.pollTelemetry()
        await drainMainQueue()
        
        #expect(rig.controller.groupStates.map(\.rpm) == [0, 0, 0, 0])
    }
    
    @Test func pollKeepsTheLastValueWhenEveryReplyIsStale() async {
        let rig = makeRig(reply: { _ in Replies.firmware() })
        defer { cleanUp(rig) }
        rig.controller.groupStates[0].rpm = 777
        
        rig.controller.pollTelemetry()
        await drainMainQueue()
        
        #expect(rig.controller.groupStates[0].rpm == 777)
        #expect(rig.device.features.filter { $0 == Ene6K77Profile.rpmRequest }.count == 3, "gives up after 3 attempts")
    }
    
    @Test func pollIgnoresAnImplausibleReply() async {
        let rig = makeRig(reply: { _ in Replies.rpmWithHeader([0x5064, 0xC7F7, 540, 525]) })
        defer { cleanUp(rig) }
        rig.controller.groupStates[0].rpm = 500
        
        rig.controller.pollTelemetry()
        await drainMainQueue()
        
        #expect(rig.controller.groupStates[0].rpm == 500)
    }
    
    @Test func pollSurvivesADeviceThatDoesNotAnswer() async {
        let rig = makeRig(reply: nil)
        defer { cleanUp(rig) }
        rig.controller.groupStates[2].rpm = 321
        
        rig.controller.pollTelemetry()
        await drainMainQueue()
        
        #expect(rig.controller.groupStates[2].rpm == 321)
    }
    
    @Test func headerlessModelParsesItsOwnLayout() async {
        let rig = makeRig(profile: .slInfinity, reply: { req in
            req == Ene6K77Profile.rpmRequest ? Replies.rpmWithoutHeader([700, 710, 0, 720]) : Replies.firmware(major: 128, minor: 196, fine: 0x24)
        })
        defer { cleanUp(rig) }
        
        rig.controller.pollTelemetry()
        await drainMainQueue()
        
        #expect(rig.controller.groupStates.map(\.rpm) == [700, 710, 0, 720])
    }
    
    // MARK: - Fan speed
    
    @Test func fanSpeedWritesKeepTheirOrder() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        
        for percent in [10, 55, 90, 35] { rig.controller.setFanSpeed(groupIndex: 0, percent: percent) }
        rig.controller.flushPendingWrites()
        
        let duties = rig.device.features.filter { $0.count == 4 && $0[1] == 0x20 }.map { Int($0[3]) }
        #expect(duties == [10, 55, 90, 35], "the device must end up with the LAST requested speed")
        #expect(rig.controller.groupStates[0].targetDuty == 35)
    }
    
    @Test func fanSpeedIsClampedAndRangeChecked() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        
        rig.controller.setFanSpeed(groupIndex: 1, percent: 250)
        rig.controller.setFanSpeed(groupIndex: 1, percent: -20)
        rig.controller.setFanSpeed(groupIndex: 9, percent: 50)
        rig.controller.setFanSpeed(groupIndex: -1, percent: 50)
        rig.controller.flushPendingWrites()
        
        let duties = rig.device.features.filter { $0.count == 4 && $0[1] == 0x21 }.map { Int($0[3]) }
        #expect(duties == [100, 0])
        #expect(rig.device.features.count == 2, "out-of-range groups must not reach the device")
    }
    
    // MARK: - Sync (the "do not flatten per-port state" bugs)
    
    @Test func argbSyncLeavesRPMSyncUntouched() async {
        let rig = makeRig(saved: { $0[0].isRPMSync = false; for i in 1...3 { $0[i].isRPMSync = true } })
        defer { cleanUp(rig) }
        let before = rig.controller.groupStates.map(\.isRPMSync)
        
        rig.controller.setARGBSync(true)
        rig.controller.flushPendingWrites()
        
        #expect(rig.controller.groupStates.map(\.isRPMSync) == before)
        #expect(rig.controller.isMotherboardARGBSync)
        let rpmSyncPackets = rig.device.features.filter { $0.count == 6 && $0[2] == 0x62 }
        #expect(rpmSyncPackets.isEmpty, "toggling ARGB sync must not rewrite RPM sync")
        #expect(rig.device.features.contains(Ene6K77Profile.slV2.argbSyncPacket(enabled: true)))
    }
    
    @Test func turningARGBSyncOffRestoresTheSavedLighting() async {
        let rig = makeRig(saved: { $0[0].lightingMode = .staticColor; $0[0].staticColor = .magenta })
        defer { cleanUp(rig) }
        
        rig.controller.setARGBSync(true)
        rig.controller.flushPendingWrites()
        rig.device.clearRecording()
        rig.controller.setARGBSync(false)
        rig.controller.flushPendingWrites()
        
        #expect(rig.device.features.first == Ene6K77Profile.slV2.argbSyncPacket(enabled: false))
        #expect(rig.device.outputs.count == 4, "one color report per port is re-sent")
        #expect(Array(rig.device.outputs[0][2..<5]) == [255, 255, 0])     // magenta in R, B, G
    }
    
    @Test func perGroupSyncChangeOnlyTouchesThatGroup() async {
        let rig = makeRig(saved: { for i in 0..<4 { $0[i].isRPMSync = true; $0[i].targetDuty = 40 } })
        defer { cleanUp(rig) }
        
        rig.controller.setGroupRPMSync(groupIndex: 1, isSync: false)
        rig.controller.flushPendingWrites()
        
        let p = Ene6K77Profile.slV2
        #expect(rig.device.features == [p.rpmSyncPacket(group: 1, sync: false), p.fanSpeedPacket(group: 1, percent: 40)])
        #expect(rig.controller.groupStates.map(\.isRPMSync) == [true, false, true, true])
        #expect(!rig.controller.isMotherboardRPMSync, "aggregate flag is true only when every group is synced")
    }
    
    @Test func enablingSyncOnAGroupDoesNotWriteDuty() async {
        let rig = makeRig(saved: { for i in 0..<4 { $0[i].isRPMSync = false } })
        defer { cleanUp(rig) }
        
        rig.controller.setGroupRPMSync(groupIndex: 2, isSync: true)
        rig.controller.flushPendingWrites()
        
        #expect(rig.device.features == [Ene6K77Profile.slV2.rpmSyncPacket(group: 2, sync: true)])
    }
    
    @Test func aggregateFlagTracksAllGroups() async {
        let rig = makeRig(saved: { for i in 0..<4 { $0[i].isRPMSync = false } })
        defer { cleanUp(rig) }
        
        for g in 0..<4 { rig.controller.setGroupRPMSync(groupIndex: g, isSync: true) }
        #expect(rig.controller.isMotherboardRPMSync)
        rig.controller.setGroupRPMSync(groupIndex: 3, isSync: false)
        #expect(!rig.controller.isMotherboardRPMSync)
        rig.controller.flushPendingWrites()
    }
    
    @Test func leavingGlobalSyncRestoresEveryPortsDuty() async {
        let rig = makeRig(saved: { for i in 0..<4 { $0[i].isRPMSync = true; $0[i].targetDuty = 20 + i * 10 } })
        defer { cleanUp(rig) }
        
        rig.controller.setMotherboardSync(rpmSync: false, argbSync: false)
        rig.controller.flushPendingWrites()
        
        let duties = rig.device.features.filter { $0.count == 4 && ($0[1] & 0xF0) == 0x20 }
        #expect(duties.map { Int($0[3]) } == [20, 30, 40, 50])
        #expect(rig.controller.groupStates.allSatisfy { !$0.isRPMSync })
    }
    
    @Test func releaseToMotherboardSyncsEveryPortWithoutChangingSavedState() async {
        let rig = makeRig(saved: { $0[0].isRPMSync = false; $0[0].targetDuty = 55 })
        defer { cleanUp(rig) }
        let before = rig.controller.groupStates
        
        rig.controller.releaseToMotherboard()
        
        let p = Ene6K77Profile.slV2
        #expect(rig.device.features == (0..<4).map { p.rpmSyncPacket(group: $0, sync: true) })
        #expect(rig.controller.groupStates == before, "quitting must not rewrite the user's configuration")
        #expect(rig.defaults.data(forKey: p.prefsPrefix + "groups") == nil)
    }
    
    // MARK: - Lighting & persistence
    
    @Test func lightingChangeIsSentAndPersisted() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        
        rig.controller.setLighting(groupIndex: 2, mode: .staticColor, speedIndex: 3, brightnessPercent: 70, direction: 1, colors: [.orange])
        rig.controller.flushPendingWrites()
        
        #expect(rig.device.outputs.count == 1)
        #expect(rig.device.outputs[0][1] == 0x32)
        let effect = rig.device.features.first { $0.count == 6 }
        #expect(effect?[1] == 0x12)
        #expect(effect?[2] == 1)
        
        let restored = Ene6K77Controller(device: MockHIDDevice(), profile: .slV2, defaults: rig.defaults)
        #expect(restored.groupStates[2].lightingMode == .staticColor)
        #expect(restored.groupStates[2].staticColor == .orange)
        #expect(restored.groupStates[2].brightnessPercent == 70)
        #expect(restored.groupStates[2].direction == 1)
    }
    
    @Test func lightingForAnInvalidGroupIsIgnored() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        
        rig.controller.setLighting(groupIndex: 7, mode: .rainbow, speedIndex: 0, brightnessPercent: 100, direction: 0, colors: nil)
        rig.controller.flushPendingWrites()
        
        #expect(rig.device.features.isEmpty && rig.device.outputs.isEmpty)
    }
    
    @Test func dualRingLightingWritesBothRings() async {
        let rig = makeRig(profile: .slInfinity)
        defer { cleanUp(rig) }
        
        rig.controller.setLighting(groupIndex: 1, mode: .staticColor, speedIndex: 2, brightnessPercent: 100, direction: 0, colors: [.green])
        rig.controller.flushPendingWrites()
        
        #expect(rig.device.outputs.map { $0[1] } == [0x32, 0x33], "inner ring is port 2, outer ring is port 3")
    }
    
    @Test func settingsOfDifferentModelsDoNotCollide() async {
        let suiteName = "FConnectTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        
        let a = Ene6K77Controller(device: MockHIDDevice(), profile: .slV2, defaults: defaults)
        a.setGroupName(groupIndex: 0, name: "Front")
        let b = Ene6K77Controller(device: MockHIDDevice(), profile: .alV2, defaults: defaults)
        
        #expect(b.groupStates[0].customName == nil)
        #expect(a.groupStates[0].customName == "Front")
    }
    
    // MARK: - Identify
    
    @Test func identifyBlinksOnlyTheChosenGroupAndRestoresARGBSync() async {
        let rig = makeRig(saved: { $0[1].lightingMode = .staticColor })
        defer { cleanUp(rig) }
        rig.controller.isMotherboardARGBSync = true
        
        rig.controller.identifyCluster(groupIndex: 1)
        rig.controller.flushPendingWrites()
        
        let p = Ene6K77Profile.slV2
        let release = rig.device.features.firstIndex(of: p.argbSyncPacket(enabled: false))
        #expect(release != nil, "sync must be released so the blink is visible")
        #expect((release ?? 0) >= 4, "every port is blanked first, or the stored effect (rainbow by default) flashes when sync is released")
        #expect(rig.device.features.last == p.argbSyncPacket(enabled: true), "and restored afterwards")
        let whiteOnGroup1 = rig.device.outputs.filter { $0[1] == 0x31 && $0[2] == 255 && $0[3] == 255 }
        #expect(whiteOnGroup1.count == 3)
    }
    
    @Test func identifyDoesNotChangePublishedState() async {
        let rig = makeRig(saved: { $0[0].isRPMSync = false; $0[0].targetDuty = 33 })
        defer { cleanUp(rig) }
        let before = rig.controller.groupStates
        
        rig.controller.identifyCluster(groupIndex: 0)
        rig.controller.flushPendingWrites()
        
        #expect(rig.controller.groupStates == before)
    }
    
    // MARK: - Connection health
    
    private func pollRepeatedly(_ rig: Rig, times: Int) async {
        for _ in 0..<times { rig.controller.pollTelemetry() }
        await drainMainQueue()
    }
    
    @Test func fewFailedPollsDoNotRaiseAnAlarm() async {
        let rig = makeRig(reply: nil)
        defer { cleanUp(rig) }
        var lostCalls = 0
        rig.controller.onConnectionLost = { lostCalls += 1 }
        
        await pollRepeatedly(rig, times: Ene6K77Controller.failureThreshold - 1)
        
        #expect(rig.controller.connectionIssue == nil)
        #expect(lostCalls == 0)
    }
    
    @Test func repeatedFailuresReportTheLossOnceWithTheIOKitReason() async {
        let rig = makeRig(reply: nil)
        defer { cleanUp(rig) }
        rig.device.lastErrorCode = kIOReturnNoDevice
        var lostCalls = 0
        rig.controller.onConnectionLost = { lostCalls += 1 }
        
        await pollRepeatedly(rig, times: Ene6K77Controller.failureThreshold)
        #expect(rig.controller.connectionIssue == HIDError.describe(kIOReturnNoDevice))
        #expect(lostCalls == 1)
        
        await pollRepeatedly(rig, times: 5)
        #expect(lostCalls == 1, "the owner is asked to rescan once, not on every failed poll")
    }
    
    @Test func withoutAnIOKitCodeTheMessageIsGeneric() async {
        let rig = makeRig(reply: nil)
        defer { cleanUp(rig) }
        
        await pollRepeatedly(rig, times: Ene6K77Controller.failureThreshold)
        
        #expect(rig.controller.connectionIssue == "The controller is not responding.")
    }
    
    @Test func theOwnerIsAskedAgainPeriodicallyWhileTheHardwareStaysGone() async {
        let rig = makeRig(reply: nil)
        defer { cleanUp(rig) }
        var lostCalls = 0
        rig.controller.onConnectionLost = { lostCalls += 1 }
        
        await pollRepeatedly(rig, times: Ene6K77Controller.failureThreshold + Ene6K77Controller.recoveryRetryInterval)
        
        #expect(lostCalls == 2)
    }
    
    @Test func aSuccessfulPollInTheMiddleResetsTheCount() async {
        var healthy = false
        let rig = makeRig(reply: { request in
            healthy ? Replies.healthyHub()(request) : nil
        })
        defer { cleanUp(rig) }
        
        await pollRepeatedly(rig, times: Ene6K77Controller.failureThreshold - 1)
        healthy = true
        await pollRepeatedly(rig, times: 1)
        healthy = false
        await pollRepeatedly(rig, times: Ene6K77Controller.failureThreshold - 1)
        
        #expect(rig.controller.connectionIssue == nil)
    }
    
    @Test func recoveryClearsTheMessageAndSendsTheConfigurationAgain() async {
        var healthy = false
        let rig = makeRig(reply: { request in healthy ? Replies.healthyHub()(request) : nil },
                          saved: { $0[0].isRPMSync = false; for i in 1...3 { $0[i].isRPMSync = true } })
        defer { cleanUp(rig) }
        var lostCalls = 0
        rig.controller.onConnectionLost = { lostCalls += 1 }
        
        await pollRepeatedly(rig, times: Ene6K77Controller.failureThreshold)
        #expect(rig.controller.connectionIssue != nil)
        rig.device.clearRecording()
        
        healthy = true
        await pollRepeatedly(rig, times: 1)
        rig.controller.flushPendingWrites()
        await drainMainQueue()
        
        #expect(rig.controller.connectionIssue == nil)
        let p = Ene6K77Profile.slV2
        #expect(rig.device.features.contains(p.rpmSyncPacket(group: 0, sync: false)), "a hub that restarted gets its saved state back")
        #expect(rig.device.features.contains(p.rpmSyncPacket(group: 1, sync: true)))
        #expect(lostCalls == 1)
    }
    
    // MARK: - Lighting colors, coalescing, fallback
    
    private func fanColor(_ output: [UInt8], fan: Int) -> [UInt8] {
        // SL V2 static / breathing: 16 LEDs per fan, 3 bytes (R, B, G) per LED, after the 2-byte header
        Array(output[(2 + fan * 16 * 3)..<(2 + fan * 16 * 3 + 3)])
    }
    
    @Test func everyZoneColorIsSavedAndRestored() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        
        rig.controller.setLighting(groupIndex: 0, mode: .staticColor, speedIndex: 2, brightnessPercent: 100, direction: 0,
                                   colors: [.red, .green, .blue, .yellow])
        rig.controller.flushPendingWrites()
        
        let restored = Ene6K77Controller(device: MockHIDDevice(), profile: .slV2, defaults: rig.defaults)
        #expect(restored.groupStates[0].lightingColors == [.red, .green, .blue, .yellow])
        #expect(restored.groupStates[0].staticColor == .red)
    }
    
    @Test func restoredZoneColorsReachTheHardwareAtStartup() async {
        let rig = makeRig(saved: { $0[0].lightingMode = .staticColor; $0[0].lightingColors = [.red, .green, .blue, .yellow] })
        defer { cleanUp(rig) }
        
        rig.controller.initialize()
        rig.controller.flushPendingWrites()
        
        let port0 = rig.device.outputs.first { $0[1] == 0x30 }!
        #expect(fanColor(port0, fan: 0) == [255, 0, 0])      // red
        #expect(fanColor(port0, fan: 1) == [0, 0, 255])      // green (R, B, G)
        #expect(fanColor(port0, fan: 2) == [0, 255, 0])      // blue
    }
    
    @Test func settingsFromBeforeZoneColorsExistedStillWork() async throws {
        let json = #"[{"id": 0, "lightingMode": 1, "staticColor": {"red": 10, "green": 20, "blue": 30}}]"#
        let suite = "FConnectTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(json.utf8), forKey: Ene6K77Profile.slV2.prefsPrefix + "groups")
        
        let c = Ene6K77Controller(device: MockHIDDevice(), profile: .slV2, defaults: defaults)
        
        #expect(c.groupStates[0].lightingColors.isEmpty)
        #expect(c.groupStates[0].effectiveLightingColors == [RGBColor(red: 10, green: 20, blue: 30)])
    }
    
    @Test func lightingWithoutNewColorsKeepsTheSavedZoneColors() async {
        let rig = makeRig(saved: { $0[0].lightingColors = [.red, .green, .blue, .yellow] })
        defer { cleanUp(rig) }
        
        rig.controller.setLighting(groupIndex: 0, mode: .staticColor, speedIndex: 3, brightnessPercent: 50, direction: 0, colors: nil)
        rig.controller.flushPendingWrites()
        
        #expect(rig.controller.groupStates[0].lightingColors == [.red, .green, .blue, .yellow])
        #expect(fanColor(rig.device.outputs[0], fan: 1) == [0, 0, 255])
    }
    
    /// Dragging a color picker produces dozens of requests; the hub must only be asked for the newest one.
    @Test func rapidLightingChangesAreCoalescedToTheNewest() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        let gate = DispatchSemaphore(value: 0)
        var held = false
        rig.device.beforeFeature = { _ in
            if !held { held = true; gate.wait() }          // keep the write queue busy while the requests pile up
        }
        
        rig.controller.setFanSpeed(groupIndex: 3, percent: 40)
        for color in [RGBColor.red, .green, .blue, .yellow, .orange] {
            rig.controller.setLighting(groupIndex: 0, mode: .staticColor, speedIndex: 2, brightnessPercent: 100, direction: 0, colors: [color])
        }
        gate.signal()
        rig.controller.flushPendingWrites()
        
        let lighting = rig.device.outputs.filter { $0[1] == 0x30 }
        #expect(lighting.count == 1, "only the newest of the five requests is written")
        #expect(fanColor(lighting[0], fan: 0) == [255, 0, 128])     // orange in R, B, G
        #expect(rig.controller.groupStates[0].staticColor == .orange, "saved state always follows the newest request")
    }
    
    @Test func coalescingNeverDropsAnotherGroupsRequest() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        let gate = DispatchSemaphore(value: 0)
        var held = false
        rig.device.beforeFeature = { _ in if !held { held = true; gate.wait() } }
        
        rig.controller.setFanSpeed(groupIndex: 3, percent: 40)
        rig.controller.setLighting(groupIndex: 0, mode: .staticColor, speedIndex: 2, brightnessPercent: 100, direction: 0, colors: [.red])
        rig.controller.setLighting(groupIndex: 1, mode: .staticColor, speedIndex: 2, brightnessPercent: 100, direction: 0, colors: [.green])
        rig.controller.setLighting(groupIndex: 0, mode: .staticColor, speedIndex: 2, brightnessPercent: 100, direction: 0, colors: [.blue])
        gate.signal()
        rig.controller.flushPendingWrites()
        
        #expect(rig.device.outputs.map { $0[1] }.sorted() == [0x30, 0x31])
        #expect(fanColor(rig.device.outputs.first { $0[1] == 0x30 }!, fan: 0) == [0, 255, 0])    // blue
        #expect(fanColor(rig.device.outputs.first { $0[1] == 0x31 }!, fan: 0) == [0, 0, 255])    // green
    }
    
    @Test func separateLightingChangesOverTimeAreAllWritten() async {
        let rig = makeRig()
        defer { cleanUp(rig) }
        
        for color in [RGBColor.red, .green, .blue] {
            rig.controller.setLighting(groupIndex: 0, mode: .staticColor, speedIndex: 2, brightnessPercent: 100, direction: 0, colors: [color])
            rig.controller.flushPendingWrites()
        }
        
        #expect(rig.device.outputs.count == 3, "coalescing only merges requests that are still waiting")
    }
    
    @Test func hardwareWithoutAnEffectShowsAStaticColorInstead() {
        let inf = makeRig(profile: .slInfinity)
        let v2 = makeRig(profile: .slV2)
        defer { cleanUp(inf); cleanUp(v2) }
        #expect(inf.controller.effectiveLightingMode(.neon) == .staticColor)
        #expect(inf.controller.effectiveLightingMode(.rainbow) == .rainbow)
        #expect(v2.controller.effectiveLightingMode(.neon) == .neon)
    }
    
    // MARK: - Capabilities
    
    @Test func controllerReportsItsModelsLightingModes() {
        let rig = makeRig(profile: .slV1)
        defer { cleanUp(rig) }
        #expect(rig.controller.supportedLightingModes == Ene6K77Profile.slV1.lighting.supportedModes)
        #expect(!rig.controller.supportedLightingModes.contains(.tunnel))
    }
}
