import Foundation
import IOKit

// CPU temperatures from the SMC, as published by VirtualSMC / FakeSMC plugins (SMCProcessor on Intel, SMCAMDProcessor on
// AMD). The transport below is verified against a real SMC; which keys exist differs from build to build, so discovery is
// generic and every found sensor is offered to the user.

struct SMCValue: Equatable {
    let key: String
    let type: String
    let bytes: [UInt8]
}

protocol SMCTransport: AnyObject {
    func keyCount() -> Int?
    func key(at index: Int) -> String?
    func read(_ key: String) -> SMCValue?
}

enum SMCDecode {
    /// Plausible CPU temperature range in degrees C; anything else is treated as "no reading".
    static let validRange: ClosedRange<Double> = 1...124
    
    static func temperature(_ value: SMCValue) -> Double? {
        let b = value.bytes
        let raw: Double
        switch value.type {
        case "sp78":   // signed 8.8 fixed point, big endian
            guard b.count >= 2 else { return nil }
            raw = Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "fpe2":   // unsigned 14.2 fixed point, big endian
            guard b.count >= 2 else { return nil }
            raw = Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "flt ":   // IEEE float; native order on current SMCs, big endian on some emulations
            guard b.count >= 4 else { return nil }
            let little = Double(Float(bitPattern: UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])))
            if little.isFinite, validRange.contains(little) { return little }
            let big = Double(Float(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])))
            raw = big
        default:
            return nil
        }
        return raw.isFinite && validRange.contains(raw) ? raw : nil
    }
}

/// Finds CPU temperature sensors on an SMC and reads them.
final class SMCSensorProvider {
    /// Best default first: package/die sensors beat proximity and heatsink ones for fan control.
    static let knownKeys: [(key: String, name: String)] = [
        ("TCXC", "CPU Package (PECI)"),
        ("TCAD", "CPU Package"),
        ("TC0D", "CPU Die"),
        ("TC0P", "CPU Proximity"),
        ("TC0H", "CPU Heatsink"),
        ("TC0E", "CPU Die (virtual)"),
        ("TC0F", "CPU Die (filtered)")
    ]
    static let hottestCoreID = "smc_cores_max"
    static let rediscoveryInterval: TimeInterval = 30
    
    private let makeTransport: () -> SMCTransport?
    private var transport: SMCTransport?
    private var discovered: [(key: String, name: String)]?
    private var coreKeys: [String] = []
    private var lastDiscovery = Date.distantPast
    
    init(makeTransport: @escaping () -> SMCTransport?) {
        self.makeTransport = makeTransport
    }
    
    /// Current readings of every CPU sensor found. Call from one queue only.
    func sample(now: Date = Date()) -> [ThermalSensorItem] {
        if transport == nil, now.timeIntervalSince(lastDiscovery) >= Self.rediscoveryInterval {
            transport = makeTransport()
            lastDiscovery = now
        }
        guard let transport = transport else { return [] }
        
        if discovered == nil { discover(transport, now: now) }
        var items = readItems(transport)
        
        // Nothing readable: the key set may have changed (kext reloaded, sensors appeared late). Look again, rarely.
        if items.isEmpty, now.timeIntervalSince(lastDiscovery) >= Self.rediscoveryInterval {
            discover(transport, now: now)
            items = readItems(transport)
        }
        return items
    }
    
    private func discover(_ transport: SMCTransport, now: Date) {
        lastDiscovery = now
        guard let count = transport.keyCount(), count > 0, count < 100_000 else {
            discovered = []
            coreKeys = []
            return
        }
        var present = Set<String>()
        var cores = [String]()
        for index in 0..<count {
            guard let key = transport.key(at: index), key.count == 4, key.hasPrefix("TC") else { continue }
            present.insert(key)
            // TC0C ... TC9C: one key per core
            let chars = Array(key)
            if chars[3] == "C", chars[2].isNumber { cores.append(key) }
        }
        discovered = Self.knownKeys.filter { present.contains($0.key) }
        coreKeys = cores.sorted()
    }
    
    private func readItems(_ transport: SMCTransport) -> [ThermalSensorItem] {
        var items = [ThermalSensorItem]()
        for (key, name) in discovered ?? [] {
            if let value = transport.read(key), let temp = SMCDecode.temperature(value) {
                items.append(ThermalSensorItem(id: "smc_\(key)", name: "\(name) (\(key))", temperature: temp))
            }
        }
        let coreTemps = coreKeys.compactMap { transport.read($0).flatMap(SMCDecode.temperature) }
        if coreTemps.count >= 2, let hottest = coreTemps.max() {
            items.append(ThermalSensorItem(id: Self.hottestCoreID, name: "CPU Cores, hottest (\(coreTemps.count))", temperature: hottest))
        }
        return items
    }
}

/// The real SMC (`AppleSMC` user client). Struct offsets match the 80-byte `SMCKeyData_t` of the kernel interface.
final class AppleSMCConnection: SMCTransport {
    private var connection: io_connect_t = 0
    
    private static let handleYPCEvent: UInt32 = 2
    private enum Command: UInt8 { case readKey = 5, readIndex = 8, getKeyInfo = 9 }
    
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }
    
    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }
    
    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }, encoding: .ascii) ?? ""
    }
    
    private func call(key: UInt32, command: Command, dataSize: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes { p in
            p.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
            p.storeBytes(of: dataSize, toByteOffset: 28, as: UInt32.self)
            p.storeBytes(of: command.rawValue, toByteOffset: 42, as: UInt8.self)
            p.storeBytes(of: index, toByteOffset: 44, as: UInt32.self)
        }
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let ret = input.withUnsafeBytes { i in
            output.withUnsafeMutableBytes { o in
                IOConnectCallStructMethod(connection, Self.handleYPCEvent, i.baseAddress, 80, o.baseAddress, &outputSize)
            }
        }
        return ret == KERN_SUCCESS && output[40] == 0 ? output : nil
    }
    
    private func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
    }
    
    func keyCount() -> Int? {
        guard let value = read("#KEY"), value.bytes.count >= 4 else { return nil }
        return Int(UInt32(value.bytes[0]) << 24 | UInt32(value.bytes[1]) << 16 | UInt32(value.bytes[2]) << 8 | UInt32(value.bytes[3]))
    }
    
    func key(at index: Int) -> String? {
        guard let out = call(key: 0, command: .readIndex, index: UInt32(index)) else { return nil }
        let name = Self.string(word(out, at: 0))
        return name.isEmpty ? nil : name
    }
    
    func read(_ key: String) -> SMCValue? {
        let code = Self.fourCC(key)
        guard let info = call(key: code, command: .getKeyInfo) else { return nil }
        let size = Int(word(info, at: 28))
        guard size > 0, size <= 32 else { return nil }
        let type = Self.string(word(info, at: 32))
        guard let out = call(key: code, command: .readKey, dataSize: UInt32(size)) else { return nil }
        return SMCValue(key: key, type: type, bytes: Array(out[48..<(48 + size)]))
    }
}
