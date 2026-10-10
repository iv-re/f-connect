import Foundation

/// How a model encodes "number of fans on a port" in its quantity command.
public enum QuantityEncoding {
    /// `[op, (group << 4) | count, 0]`
    case groupAndCountNibbles
    /// `[op, group + 1, count]`
    case groupPlusOneThenCount
}

/// How a model controls port merging. We never merge ports, so only the "no merge" form is needed.
public enum MergeControl {
    /// `[op, order0, order1, order2, order3, 0x08]` - identity order means "not merged".
    case orderList(opcode: UInt8)
    /// Separate start / stop commands; stop means "not merged".
    case startStop(start: UInt8, stop: UInt8)
    /// `[op, enabled]`; 0 means "not merged".
    case enableFlag(opcode: UInt8)
}

/// Layout of the reply to the fan-speed request (`E0 50 00`). `reply[0]` is always the report ID.
public enum RPMReplyLayout {
    /// `E0 <header> rpm0.hi rpm0.lo ...` (SL V2, AL V2)
    case headerThenValues(header: UInt8)
    /// `E0 rpm0.hi rpm0.lo ...` (SL V1, AL V1, SL-Infinity)
    case valuesDirectly

    var valuesOffset: Int {
        switch self {
        case .headerThenValues: return 2
        case .valuesDirectly: return 1
        }
    }
}

/// LED geometry of one lighting port. Colors are sent as one output report per port.
public struct LightingLayout {
    /// Groups of per-LED colors used by static / breathing modes (one group per fan).
    public let ledGroups: Int
    public let ledsPerGroup: Int
    /// Blocks of zone colors used by all other modes.
    public let zoneBlocks: Int
    public let colorsPerZoneBlock: Int
}

/// How one UI lighting mode is expressed on the wire.
public enum LightingModeSpec: Equatable {
    /// Single-ring models: one lighting port per fan group; the value is the effect byte.
    case single(UInt8)
    /// Dual-ring models: one effect spanning both rings, sent to the group's inner-ring port.
    case combined(UInt8)
    /// Dual-ring models: the same effect configured separately on the inner and the outer ring.
    case perRing(inner: UInt8, outer: UInt8)
}

/// Lighting capabilities of a model. Dual-ring hubs (SL-Infinity, AL V1, AL V2) expose two lighting ports per fan group:
/// inner ring = port `2 * group`, outer ring = port `2 * group + 1`.
public struct LightingModel {
    /// Layout of the only ring (single-ring models) or of the outer ring (dual-ring models).
    public let layout: LightingLayout
    /// LEDs per fan on the inner ring; nil for single-ring models.
    public let innerRingLEDsPerFan: Int?
    public let modes: [FanLightingMode: LightingModeSpec]
    
    public var isDualRing: Bool { innerRingLEDsPerFan != nil }
    
    /// Modes this model can actually display, in UI order.
    public var supportedModes: [FanLightingMode] {
        FanLightingMode.allCases.filter { modes[$0] != nil }
    }
    
    /// Single-ring models use the shared effect table (the effect byte is the mode's raw value).
    static func singleRing(layout: LightingLayout, excluding: Set<FanLightingMode> = []) -> LightingModel {
        var table = [FanLightingMode: LightingModeSpec]()
        for mode in FanLightingMode.allCases where !excluding.contains(mode) {
            table[mode] = .single(mode.protocolByte)
        }
        return LightingModel(layout: layout, innerRingLEDsPerFan: nil, modes: table)
    }
}

/// Output + feature report pair that configures one lighting port.
public struct LightingCommand: Equatable {
    public let port: Int
    public let colors: [UInt8]
    public let effect: [UInt8]
}

/// Decodes the firmware "fine tune" byte into a version. Each model family has its own quirks (from the original software).
public enum FirmwareScheme {
    case slV1, alV1, slInfinity, slV2, alV2

    /// - Returns: (major, minor); (0, 0) for values the original software treats as invalid.
    public func version(fineTune: UInt8, minorID: UInt8) -> (major: Int, minor: Int) {
        let hi = Int((fineTune >> 4) & 0xF)
        let lo = Int(fineTune & 0xF)
        let fine = Int(fineTune)

        func split(_ value: Int) -> (major: Int, minor: Int) { (value / 10, value % 10) }

        switch self {
        case .slV1, .alV2:
            return lo > 9 ? (0, 0) : split(hi * 10 + lo)
        case .alV1:
            if lo > 9 { return (0, 0) }
            return split(fine < 8 ? 10 : hi * 10 + lo + 2)
        case .slV2:
            if lo > 9 { return (0, 0) }
            if minorID == 199 {
                if fine == 0 { return (0, 5) }
                if (1...5).contains(fine) { return (0, 0) }
            }
            return split(hi * 10 + lo)
        case .slInfinity:
            if fine <= 3 || (15...31).contains(fine) { return (0, 0) }
            if fine >= 32 && lo > 9 { return (0, 0) }
            let low = (fine == 13 || fine == 14) ? lo + 1 : lo
            return split(hi * 10 + low)
        }
    }
}

/// Everything that differs between ENE 6K77 based Lian Li controllers. Values follow the behavior of the vendor's own
/// software. Only the SL V2 profile has been verified on real hardware.
public struct Ene6K77Profile {
    public static let reportID: UInt8 = 0xE0
    /// Fans never exceed a few thousand RPM; larger numbers mean a foreign / garbled report.
    public static let maxPlausibleRPM = 10_000

    public let deviceType: ControllerType
    public let defaultName: String
    public let prefsPrefix: String

    /// Firmware signature: report bytes (major, minor) identify the model independently of the USB product ID.
    public let firmwareMajorID: UInt8
    public let firmwareMinorIDs: Set<UInt8>
    public let firmwareScheme: FirmwareScheme

    public let quantityOpcode: UInt8
    public let quantityEncoding: QuantityEncoding
    public let argbSyncOpcode: UInt8
    public let rpmSyncOpcode: UInt8
    public let merge: MergeControl
    public let rpmReply: RPMReplyLayout
    public let lighting: LightingModel

    // MARK: - Known models

    public static let slV1 = Ene6K77Profile(
        deviceType: .slFan, defaultName: "LianLi UNI FAN SL", prefsPrefix: "FConnect_SL_",
        firmwareMajorID: 100, firmwareMinorIDs: [194], firmwareScheme: .slV1,
        quantityOpcode: 0x32, quantityEncoding: .groupAndCountNibbles,
        argbSyncOpcode: 0x30, rpmSyncOpcode: 0x31,
        merge: .startStop(start: 0x33, stop: 0x34),
        rpmReply: .valuesDirectly,
        lighting: .singleRing(
            layout: LightingLayout(ledGroups: 4, ledsPerGroup: 16, zoneBlocks: 4, colorsPerZoneBlock: 4),
            excluding: [.render, .tunnel]
        )
    )

    public static let alV1 = Ene6K77Profile(
        deviceType: .alFan, defaultName: "LianLi UNI FAN AL", prefsPrefix: "FConnect_AL_",
        firmwareMajorID: 128, firmwareMinorIDs: [195], firmwareScheme: .alV1,
        quantityOpcode: 0x40, quantityEncoding: .groupPlusOneThenCount,
        argbSyncOpcode: 0x41, rpmSyncOpcode: 0x42,
        merge: .enableFlag(opcode: 0x43),
        rpmReply: .valuesDirectly,
        lighting: LightingModel(
            layout: LightingLayout(ledGroups: 4, ledsPerGroup: 12, zoneBlocks: 4, colorsPerZoneBlock: 4),
            innerRingLEDsPerFan: 8,
            modes: [
                .rainbow: .combined(40), .rainbowMorph: .combined(53),
                .staticColor: .perRing(inner: 1, outer: 1), .breathing: .perRing(inner: 2, outer: 2),
                .colorCycle: .combined(43),
                .runway: .perRing(inner: 26, outer: 26), .meteor: .perRing(inner: 25, outer: 25),
                .staggered: .combined(55), .tide: .combined(49), .mixing: .combined(47), .stack: .combined(48)
            ]
        )
    )

    public static let slInfinity = Ene6K77Profile(
        deviceType: .slInfinity, defaultName: "LianLi UNI FAN SL-Infinity", prefsPrefix: "FConnect_SLInf_",
        firmwareMajorID: 128, firmwareMinorIDs: [196], firmwareScheme: .slInfinity,
        quantityOpcode: 0x60, quantityEncoding: .groupPlusOneThenCount,
        argbSyncOpcode: 0x61, rpmSyncOpcode: 0x62,
        merge: .orderList(opcode: 0x63),
        rpmReply: .valuesDirectly,
        lighting: LightingModel(
            layout: LightingLayout(ledGroups: 4, ledsPerGroup: 12, zoneBlocks: 4, colorsPerZoneBlock: 4),
            innerRingLEDsPerFan: 8,
            modes: [
                .rainbow: .combined(50), .rainbowMorph: .combined(63),
                .staticColor: .perRing(inner: 1, outer: 1), .breathing: .perRing(inner: 2, outer: 2),
                .colorCycle: .perRing(inner: 24, outer: 24),
                .runway: .perRing(inner: 26, outer: 26), .meteor: .perRing(inner: 25, outer: 25),
                .tide: .combined(58), .mixing: .combined(56), .stack: .combined(57)
            ]
        )
    )

    public static let slV2 = Ene6K77Profile(
        deviceType: .slV2Fan, defaultName: "LianLi UNI FAN SL V2", prefsPrefix: "FConnect_SLV2_",
        firmwareMajorID: 100, firmwareMinorIDs: [197, 199], firmwareScheme: .slV2,
        quantityOpcode: 0x60, quantityEncoding: .groupAndCountNibbles,
        argbSyncOpcode: 0x61, rpmSyncOpcode: 0x62,
        merge: .orderList(opcode: 0x63),
        rpmReply: .headerThenValues(header: 0xF0),
        lighting: .singleRing(
            layout: LightingLayout(ledGroups: 6, ledsPerGroup: 16, zoneBlocks: 6, colorsPerZoneBlock: 4)
        )
    )

    public static let alV2 = Ene6K77Profile(
        deviceType: .alV2Fan, defaultName: "LianLi UNI FAN AL V2", prefsPrefix: "FConnect_ALV2_",
        firmwareMajorID: 128, firmwareMinorIDs: [198], firmwareScheme: .alV2,
        quantityOpcode: 0x60, quantityEncoding: .groupPlusOneThenCount,
        argbSyncOpcode: 0x61, rpmSyncOpcode: 0x62,
        merge: .orderList(opcode: 0x63),
        rpmReply: .headerThenValues(header: 0xF0),
        lighting: LightingModel(
            layout: LightingLayout(ledGroups: 6, ledsPerGroup: 12, zoneBlocks: 6, colorsPerZoneBlock: 6),
            innerRingLEDsPerFan: 8,
            modes: [
                .rainbow: .combined(43), .rainbowMorph: .combined(4),
                .staticColor: .perRing(inner: 1, outer: 1), .breathing: .perRing(inner: 2, outer: 2),
                .colorCycle: .combined(46),
                .runway: .perRing(inner: 26, outer: 26), .meteor: .perRing(inner: 25, outer: 25),
                .staggered: .combined(64), .tide: .combined(51), .mixing: .combined(50), .stack: .combined(67),
                .render: .combined(57)
            ]
        )
    )

    public static let all: [Ene6K77Profile] = [.slV1, .alV1, .slInfinity, .slV2, .alV2]

    public static func profile(for type: ControllerType) -> Ene6K77Profile? {
        all.first { $0.deviceType == type }
    }

    public static func profile(firmwareMajor: UInt8, minor: UInt8) -> Ene6K77Profile? {
        all.first { $0.firmwareMajorID == firmwareMajor && $0.firmwareMinorIDs.contains(minor) }
    }

    // MARK: - Packet builders (pure, no I/O)

    private var report: UInt8 { Self.reportID }

    public static let firmwareRequest: [UInt8] = [reportID, 0x50, 0x01]
    public static let rpmRequest: [UInt8] = [reportID, 0x50, 0x00]
    public static let applyFramePacket: [UInt8] = [reportID, 0x60, 0x00, 0x01]

    public func fanSpeedPacket(group: Int, percent: Int) -> [UInt8] {
        [report, UInt8(0x20 | (group & 0x0F)), 0x00, UInt8(max(0, min(100, percent)))]
    }

    public func quantityPacket(group: Int, count: Int) -> [UInt8] {
        let clamped = max(1, min(6, count))
        switch quantityEncoding {
        case .groupAndCountNibbles:
            return [report, 0x10, quantityOpcode, UInt8(((group & 0x0F) << 4) | (clamped & 0x0F)), 0x00, 0x00]
        case .groupPlusOneThenCount:
            return [report, 0x10, quantityOpcode, UInt8(group + 1), UInt8(clamped), 0x00]
        }
    }

    public func rpmSyncPacket(group: Int, sync: Bool) -> [UInt8] {
        let mask = UInt8((1 << (group + 4)) | ((sync ? 1 : 0) << group))
        return [report, 0x10, rpmSyncOpcode, mask, 0x00, 0x00]
    }

    public func argbSyncPacket(enabled: Bool) -> [UInt8] {
        [report, 0x10, argbSyncOpcode, enabled ? 0x01 : 0x00, 0x00, 0x00]
    }

    /// Packets that leave the ports un-merged.
    public func noMergePackets() -> [[UInt8]] {
        switch merge {
        case .orderList(let opcode):
            return [[report, 0x10, opcode, 0, 1, 2, 3, 0x08]]
        case .startStop(_, let stop):
            return [[report, 0x10, stop, 0, 0, 0]]
        case .enableFlag(let opcode):
            return [[report, 0x10, opcode, 0, 0, 0]]
        }
    }

    public func effectPacket(port: Int, mode: UInt8, speed: UInt8, direction: UInt8, brightness: UInt8) -> [UInt8] {
        [report, UInt8(0x10 | (port & 0x0F)), mode, speed, direction, brightness]
    }
    
    /// Falls back to a mode every model supports when the requested one is not available on this hardware.
    public func effectiveMode(_ mode: FanLightingMode) -> FanLightingMode {
        lighting.modes[mode] != nil ? mode : .staticColor
    }
    
    /// Everything needed to display `mode` on one fan group: one command per lighting port involved.
    /// Wire order of colors is R, B, G. Static / breathing use per-LED colors, every other effect uses zone colors.
    public func lightingCommands(
        group: Int,
        mode requestedMode: FanLightingMode,
        colors: [RGBColor],
        speed: UInt8,
        direction: UInt8,
        brightness: UInt8
    ) -> [LightingCommand] {
        let mode = effectiveMode(requestedMode)
        guard let spec = lighting.modes[mode] else { return [] }
        let active = colors.isEmpty ? [RGBColor.cyan] : colors
        let perLED = (mode == .breathing || mode == .staticColor)
        
        func command(port: Int, ledsPerFan: Int, effect: UInt8, zoneColors: Bool) -> LightingCommand {
            LightingCommand(
                port: port,
                colors: colorPayload(port: port, ledsPerFan: ledsPerFan, perLED: perLED && !zoneColors, colors: active),
                effect: effectPacket(port: port, mode: effect, speed: speed, direction: direction, brightness: brightness)
            )
        }
        
        switch spec {
        case .single(let effect):
            return [command(port: group, ledsPerFan: lighting.layout.ledsPerGroup, effect: effect, zoneColors: false)]
        case .combined(let effect):
            return [command(port: 2 * group, ledsPerFan: lighting.layout.ledsPerGroup, effect: effect, zoneColors: true)]
        case .perRing(let inner, let outer):
            return [
                command(port: 2 * group, ledsPerFan: lighting.innerRingLEDsPerFan ?? lighting.layout.ledsPerGroup, effect: inner, zoneColors: false),
                command(port: 2 * group + 1, ledsPerFan: lighting.layout.ledsPerGroup, effect: outer, zoneColors: false)
            ]
        }
    }
    
    /// Output report with the colors for one lighting port.
    func colorPayload(port: Int, ledsPerFan: Int, perLED: Bool, colors active: [RGBColor]) -> [UInt8] {
        var packet = [UInt8]()
        packet.append(report)
        packet.append(UInt8(0x30 | (port & 0x0F)))
        
        func append(_ color: RGBColor) {
            packet.append(color.red)
            packet.append(color.blue)
            packet.append(color.green)
        }
        
        if perLED {
            for fan in 0..<lighting.layout.ledGroups {
                let color = fan < active.count ? active[fan] : active[0]
                for _ in 0..<ledsPerFan { append(color) }
            }
        } else {
            for _ in 0..<lighting.layout.zoneBlocks {
                for slot in 0..<lighting.layout.colorsPerZoneBlock {
                    append(slot < active.count ? active[slot] : .off)
                }
            }
        }
        return packet
    }
    
    // MARK: - Reply parsers (pure)

    /// Parses the reply to `rpmRequest`.
    /// - Returns: RPM per port, or nil if this is not a valid fan-speed reply (e.g. a stale reply to another command).
    public func parseRPM(_ reply: [UInt8], ports: Int = 4) -> [Int]? {
        let offset = rpmReply.valuesOffset
        guard reply.count >= offset + ports * 2 else { return nil }
        if case .headerThenValues(let header) = rpmReply, reply[1] != header { return nil }

        var rpms = [Int]()
        for i in 0..<ports {
            rpms.append((Int(reply[offset + i * 2]) << 8) | Int(reply[offset + i * 2 + 1]))
        }
        return rpms.allSatisfy({ $0 <= Self.maxPlausibleRPM }) ? rpms : nil
    }

    public struct FirmwareInfo: Equatable {
        public let majorID: UInt8
        public let minorID: UInt8
        public let fineTune: UInt8
    }

    /// Parses the reply to `firmwareRequest`: `E0 E0 50 <major> <minor> <fine>`.
    public static func parseFirmware(_ reply: [UInt8]) -> FirmwareInfo? {
        guard reply.count >= 6, reply[1] == reportID, reply[2] == 0x50 else { return nil }
        return FirmwareInfo(majorID: reply[3], minorID: reply[4], fineTune: reply[5])
    }

    /// Version string for display, e.g. "v0.7".
    public func versionString(for info: FirmwareInfo) -> String {
        let v = firmwareScheme.version(fineTune: info.fineTune, minorID: info.minorID)
        return "v\(v.major).\(v.minor)"
    }
}
