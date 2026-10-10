import Foundation
import IOKit

/// Controller for every Lian Li fan hub built on the ENE 6K77 chip (report ID 0xE0).
/// Models differ only in data (`Ene6K77Profile`): opcodes, encodings, reply layout, LED geometry.
///
/// Threading: published state (`groupStates`, flags) is touched on the main thread only. All hardware writes go through
/// `hidWriteQueue` (serial, so they reach the device in order); every request/reply exchange is atomic in the HID layer.
public final class Ene6K77Controller: BaseDeviceController {
    public let hidDevice: HIDDeviceProtocol
    public let profile: Ene6K77Profile

    private let defaults: UserDefaults
    /// All fan-speed / sync / init writes go through this serial queue so they reach the device in the order they were issued.
    private let hidWriteQueue = DispatchQueue(label: "com.lconnect.hidWrite", qos: .userInitiated)
    private static let pollAttempts = 3
    /// Consecutive failed polls (about one per second) before the hardware is declared unreachable.
    static let failureThreshold = 5
    /// While unreachable, ask the owner to rescan again every this many failed polls.
    static let recoveryRetryInterval = 30
    
    private let healthLock = NSLock()
    private var pollFailures = 0
    private var reportedLoss = false

    private var prefsKeyPrefix: String { profile.prefsPrefix }

    public init(
        device: HIDDeviceProtocol,
        rawDevice: IOHIDDevice? = nil,
        profile: Ene6K77Profile,
        capabilities: DeviceCapabilities = .standardFans,
        portCount: Int = 4,
        defaults: UserDefaults = .standard
    ) {
        self.hidDevice = device
        self.profile = profile
        self.defaults = defaults

        super.init(
            deviceType: profile.deviceType,
            deviceName: device.productName.isEmpty ? profile.defaultName : device.productName,
            rawDevice: rawDevice,
            capabilities: capabilities
        )

        // Restore saved group states; ports missing from the saved data start from defaults.
        let saved: [FanGroupState] = defaults.data(forKey: profile.prefsPrefix + "groups")
            .flatMap { try? JSONDecoder().decode([FanGroupState].self, from: $0) } ?? []
        self.groupStates = (0..<portCount).map { port in
            saved.first(where: { $0.id == port }) ?? FanGroupState(id: port, fanCount: 3)
        }

        self.isMotherboardRPMSync = defaults.bool(forKey: profile.prefsPrefix + "rpmSync")
        self.isMotherboardARGBSync = defaults.bool(forKey: profile.prefsPrefix + "argbSync")
    }

    public override func savePreferences() {
        if let data = try? JSONEncoder().encode(groupStates) {
            defaults.set(data, forKey: prefsKeyPrefix + "groups")
        }
        defaults.set(isMotherboardRPMSync, forKey: prefsKeyPrefix + "rpmSync")
        defaults.set(isMotherboardARGBSync, forKey: prefsKeyPrefix + "argbSync")
    }

    // MARK: - Lifecycle

    /// Pushes the saved configuration to the hardware. Runs on the write queue (it takes a second or more because
    /// the device needs a pause after each command), so the caller is never blocked.
    public override func initialize() {
        let groups = groupStates
        let argbSync = isMotherboardARGBSync
        hidWriteQueue.async { [weak self] in
            self?.performInitialization(groups: groups, argbSync: argbSync)
        }
    }

    public override func resetAfterWake() {
        let groups = groupStates
        let argbSync = isMotherboardARGBSync
        hidWriteQueue.async { [weak self] in
            guard let self = self else { return }
            self.hidDevice.close() // drop a possibly stale handle; the next call reopens it
            self.performInitialization(groups: groups, argbSync: argbSync)
        }
    }

    private func performInitialization(groups: [FanGroupState], argbSync: Bool) {
        _ = hidDevice.open()
        readFirmwareVersion()

        for (i, state) in groups.enumerated() {
            _ = hidDevice.sendFeatureReport(profile.quantityPacket(group: i, count: state.fanCount))
        }
        for packet in profile.noMergePackets() {
            _ = hidDevice.sendFeatureReport(packet)
        }
        // Apply the saved sync state per group; the aggregate flag is only true when ALL groups are synced.
        for (i, state) in groups.enumerated() {
            _ = hidDevice.sendFeatureReport(profile.rpmSyncPacket(group: i, sync: state.isRPMSync))
        }
        _ = hidDevice.sendFeatureReport(profile.argbSyncPacket(enabled: argbSync))

        for (i, state) in groups.enumerated() {
            writeLighting(
                groupIndex: i,
                mode: state.lightingMode,
                speedIndex: state.speedIndex,
                brightnessPercent: state.brightnessPercent,
                direction: state.direction,
                colors: state.effectiveLightingColors
            )
            if !state.isRPMSync {
                _ = hidDevice.sendFeatureReport(profile.fanSpeedPacket(group: i, percent: state.targetDuty))
            }
        }

        pollTelemetry()
    }

    /// Gives fan speed control back to the motherboard without touching saved preferences.
    public override func releaseToMotherboard() {
        let ports = groupStates.count
        hidWriteQueue.sync { [self] in
            for i in 0..<ports {
                _ = hidDevice.sendFeatureReport(profile.rpmSyncPacket(group: i, sync: true))
            }
        }
    }

    /// Blocks until every write queued so far has reached the device. For tests and for shutdown ordering.
    func flushPendingWrites() {
        hidWriteQueue.sync {}
    }
    
    // MARK: - Telemetry

    private func readFirmwareVersion() {
        let reply: [UInt8]? = hidDevice.transaction {
            _ = hidDevice.sendFeatureReport(Ene6K77Profile.firmwareRequest)
            return hidDevice.getInputReport(reportID: Ene6K77Profile.reportID, length: 16)
        }
        guard let reply = reply, let info = Ene6K77Profile.parseFirmware(reply) else { return }
        let version = profile.versionString(for: info)
        DispatchQueue.main.async { [weak self] in
            self?.firmwareVersion = version
            self?.firmwareSignature = "\(info.majorID)/\(info.minorID)"
        }
    }

    public override func pollTelemetry() {
        // Request and reply must not be interleaved with other HID traffic, otherwise we read another command's reply.
        // A reply that does not look like a fan-speed reply is stale (answer to an earlier command): re-request.
        let rpms: [Int]? = hidDevice.transaction {
            for _ in 0..<Self.pollAttempts {
                _ = hidDevice.sendFeatureReport(Ene6K77Profile.rpmRequest)
                if let reply = hidDevice.getInputReport(reportID: Ene6K77Profile.reportID, length: 16),
                   let parsed = profile.parseRPM(reply) {
                    return parsed
                }
            }
            return nil
        }
        guard let newRPMs = rpms else {
            notePollFailure()
            return
        }
        notePollSuccess()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for i in 0..<min(self.groupStates.count, newRPMs.count) {
                self.groupStates[i].rpm = newRPMs[i]
            }
        }
    }

    // MARK: - Connection health
    
    public override var healthSummary: String {
        let failures = healthLock.locked { pollFailures }
        let code = hidDevice.lastErrorCode
        let last = code == 0 ? "none" : "0x" + String(UInt32(bitPattern: code), radix: 16)
        return "failed polls in a row: \(failures), last IOKit error: \(last)"
    }
    
    private func notePollFailure() {
        let (failures, justLost) = healthLock.locked { () -> (Int, Bool) in
            pollFailures += 1
            let first = pollFailures == Self.failureThreshold
            if first { reportedLoss = true }
            return (pollFailures, first)
        }
        guard failures >= Self.failureThreshold else { return }
        let retryDue = failures > Self.failureThreshold && (failures - Self.failureThreshold) % Self.recoveryRetryInterval == 0
        guard justLost || retryDue else { return }
        
        hidDevice.close() // drop a possibly stale handle; the next operation reopens it
        let code = hidDevice.lastErrorCode
        let message = code == 0 ? "The controller is not responding." : HIDError.describe(code)
        EventLog.shared.record("\(deviceName): connection lost after \(failures) failed polls, last IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16))", level: .error)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.connectionIssue = message
            self.onConnectionLost?()
        }
    }
    
    private func notePollSuccess() {
        let wasLost = healthLock.locked { () -> Bool in
            let lost = reportedLoss
            pollFailures = 0
            reportedLoss = false
            return lost
        }
        guard wasLost else { return }
        EventLog.shared.record("\(deviceName): connection restored, re-sending settings")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.connectionIssue = nil
            // The hub probably restarted while it was away: send the saved configuration again.
            self.resetAfterWake()
        }
    }
    
    // MARK: - Cooling

    public override func setFanSpeed(groupIndex: Int, percent: Int) {
        guard groupIndex >= 0 && groupIndex < groupStates.count else { return }
        let clampedPercent = max(0, min(100, percent))
        let packet = profile.fanSpeedPacket(group: groupIndex, percent: clampedPercent)

        // Update @Published state on main thread
        if Thread.isMainThread {
            self.groupStates[groupIndex].targetDuty = clampedPercent
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, groupIndex < self.groupStates.count else { return }
                self.groupStates[groupIndex].targetDuty = clampedPercent
            }
        }

        hidWriteQueue.async { [weak self] in
            _ = self?.hidDevice.sendFeatureReport(packet)
        }
    }

    public override func setFanCount(groupIndex: Int, count: Int) {
        guard groupIndex >= 0 && groupIndex < groupStates.count else { return }
        let clamped = max(1, min(6, count))
        groupStates[groupIndex].fanCount = clamped

        let packet = profile.quantityPacket(group: groupIndex, count: clamped)
        hidWriteQueue.async { [weak self] in
            _ = self?.hidDevice.sendFeatureReport(packet)
        }
        savePreferences()
    }

    // MARK: - Lighting

    private struct PendingLighting {
        let mode: FanLightingMode
        let speedIndex: Int
        let brightnessPercent: Int
        let direction: UInt8
        let colors: [RGBColor]
    }
    
    private let lightingLock = NSLock()
    private var pendingLighting: [Int: PendingLighting] = [:]
    
    public override func setLighting(
        groupIndex: Int,
        mode: FanLightingMode,
        speedIndex: Int,
        brightnessPercent: Int,
        direction: UInt8,
        colors: [RGBColor]?
    ) {
        guard groupIndex >= 0 && groupIndex < groupStates.count else { return }
        groupStates[groupIndex].lightingMode = mode
        groupStates[groupIndex].speedIndex = speedIndex
        groupStates[groupIndex].brightnessPercent = brightnessPercent
        groupStates[groupIndex].direction = direction
        if let colors = colors, let first = colors.first {
            groupStates[groupIndex].staticColor = first
            groupStates[groupIndex].lightingColors = colors
        }
        
        let request = PendingLighting(
            mode: mode,
            speedIndex: speedIndex,
            brightnessPercent: brightnessPercent,
            direction: direction,
            colors: groupStates[groupIndex].effectiveLightingColors
        )
        // Latest wins: while the user drags a color picker the requests arrive far faster than the hub can take them
        // (each one is several commands with a pause). Only the newest request per group is ever written.
        lightingLock.locked { pendingLighting[groupIndex] = request }
        hidWriteQueue.async { [weak self] in
            guard let self = self,
                  let latest = self.lightingLock.locked({ self.pendingLighting.removeValue(forKey: groupIndex) }) else { return }
            self.writeLighting(
                groupIndex: groupIndex,
                mode: latest.mode,
                speedIndex: latest.speedIndex,
                brightnessPercent: latest.brightnessPercent,
                direction: latest.direction,
                colors: latest.colors
            )
        }
        savePreferences()
    }
    
    /// Sends the lighting commands to the hardware only; touches no published state, so it is safe from any thread.
    private func writeLighting(
        groupIndex: Int,
        mode: FanLightingMode,
        speedIndex: Int,
        brightnessPercent: Int,
        direction: UInt8,
        colors: [RGBColor]
    ) {
        sendLighting(profile.lightingCommands(
            group: groupIndex,
            mode: mode,
            colors: colors,
            speed: ENESpeedLevel.from(level: speedIndex),
            direction: direction,
            brightness: ENEBrightnessLevel.from(percent: brightnessPercent)
        ))
    }
    
    /// Colors, then effect for each lighting port involved, then one frame sync that makes everything take effect.
    private func sendLighting(_ commands: [LightingCommand]) {
        for command in commands {
            _ = hidDevice.writeOutputReport(command.colors)
            _ = hidDevice.sendFeatureReport(command.effect)
        }
        _ = hidDevice.sendFeatureReport(Ene6K77Profile.applyFramePacket)
    }
    
    // MARK: - Group metadata

    public override func setGroupName(groupIndex: Int, name: String) {
        guard groupIndex >= 0 && groupIndex < groupStates.count else { return }
        groupStates[groupIndex].customName = name
        savePreferences()
    }

    public override func setGroupHidden(groupIndex: Int, isHidden: Bool) {
        guard groupIndex >= 0 && groupIndex < groupStates.count else { return }
        groupStates[groupIndex].isHidden = isHidden
        savePreferences()
    }

    // MARK: - Motherboard sync

    public override func setMotherboardSync(rpmSync: Bool, argbSync: Bool) {
        self.isMotherboardRPMSync = rpmSync
        self.isMotherboardARGBSync = argbSync
        for i in 0..<groupStates.count {
            groupStates[i].isRPMSync = rpmSync
        }
        savePreferences()

        // Snapshot published state here (caller's thread); the write queue must not read it.
        let snapshot = groupStates
        hidWriteQueue.async { [weak self] in
            guard let self = self else { return }
            for i in 0..<snapshot.count {
                _ = self.hidDevice.sendFeatureReport(self.profile.rpmSyncPacket(group: i, sync: rpmSync))
            }
            _ = self.hidDevice.sendFeatureReport(self.profile.argbSyncPacket(enabled: argbSync))

            if !argbSync {
                self.restoreLighting(snapshot)
            }
            // Leaving motherboard RPM sync: the board no longer drives the fans, so restore our last duty.
            if !rpmSync {
                for (i, st) in snapshot.enumerated() {
                    _ = self.hidDevice.sendFeatureReport(self.profile.fanSpeedPacket(group: i, percent: st.targetDuty))
                }
            }
        }
    }

    public override func setARGBSync(_ enabled: Bool) {
        isMotherboardARGBSync = enabled
        savePreferences()

        let snapshot = groupStates
        hidWriteQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.hidDevice.sendFeatureReport(self.profile.argbSyncPacket(enabled: enabled))
            if !enabled {
                self.restoreLighting(snapshot)
            }
        }
    }

    public override func setGroupRPMSync(groupIndex: Int, isSync: Bool) {
        if groupIndex == -1 {
            setMotherboardSync(rpmSync: isSync, argbSync: isMotherboardARGBSync)
            return
        }
        guard groupIndex >= 0 && groupIndex < groupStates.count else { return }
        groupStates[groupIndex].isRPMSync = isSync
        self.isMotherboardRPMSync = groupStates.allSatisfy { $0.isRPMSync }
        savePreferences()

        let targetDuty = groupStates[groupIndex].targetDuty
        hidWriteQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.hidDevice.sendFeatureReport(self.profile.rpmSyncPacket(group: groupIndex, sync: isSync))
            if !isSync {
                _ = self.hidDevice.sendFeatureReport(self.profile.fanSpeedPacket(group: groupIndex, percent: targetDuty))
            }
        }
    }

    private func restoreLighting(_ states: [FanGroupState]) {
        for (i, st) in states.enumerated() {
            writeLighting(
                groupIndex: i,
                mode: st.lightingMode,
                speedIndex: st.speedIndex,
                brightnessPercent: st.brightnessPercent,
                direction: st.direction,
                colors: st.effectiveLightingColors
            )
        }
    }

    // MARK: - Identification

    public override func identifyCluster(groupIndex: Int) {
        guard groupIndex >= 0 && groupIndex < groupStates.count else { return }
        let argbWasSynced = isMotherboardARGBSync
        let snapshot = groupStates

        // Identify sends raw packets only, so published state is never changed and nothing needs to be rolled back
        // except what the hardware currently shows.
        hidWriteQueue.async { [weak self] in
            guard let self = self else { return }
            let profile = self.profile

            // Blank every port before sync is switched off: with sync active the hub does not show what is stored,
            // and once sync is off it would briefly show whatever effect was stored (the factory default is a rainbow).
            for i in 0..<snapshot.count {
                self.writeStaticColor(port: i, color: .off, brightness: .off)
            }
            if argbWasSynced {
                _ = self.hidDevice.sendFeatureReport(profile.argbSyncPacket(enabled: false))
            }

            for _ in 0..<3 {
                self.writeStaticColor(port: groupIndex, color: .white, brightness: .highest)
                Thread.sleep(forTimeInterval: 0.35)
                self.writeStaticColor(port: groupIndex, color: .off, brightness: .off)
                Thread.sleep(forTimeInterval: 0.25)
            }

            if argbWasSynced {
                _ = self.hidDevice.sendFeatureReport(profile.argbSyncPacket(enabled: true))
            } else {
                self.restoreLighting(snapshot)
            }
        }
    }

    private func writeStaticColor(port: Int, color: RGBColor, brightness: ENEBrightnessLevel) {
        sendLighting(profile.lightingCommands(
            group: port,
            mode: .staticColor,
            colors: [color],
            speed: 0,
            direction: 0,
            brightness: brightness.rawValue
        ))
    }
    
    public override var supportedLightingModes: [FanLightingMode] {
        profile.lighting.supportedModes
    }
    
    public override func effectiveLightingMode(_ mode: FanLightingMode) -> FanLightingMode {
        profile.effectiveMode(mode)
    }
}
