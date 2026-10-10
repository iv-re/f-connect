import Foundation
import Testing

/// In-memory SMC. Counts calls so efficiency can be asserted.
private final class FakeSMC: SMCTransport {
    private(set) var order: [String] = []
    private var values: [String: SMCValue] = [:]
    private(set) var keyCountCalls = 0
    private(set) var keyAtCalls = 0
    var reportedCount: Int?
    
    init(_ entries: [(String, String, [UInt8])]) {
        for (key, type, bytes) in entries { set(key, type, bytes) }
    }
    
    func set(_ key: String, _ type: String, _ bytes: [UInt8]) {
        if values[key] == nil { order.append(key) }
        values[key] = SMCValue(key: key, type: type, bytes: bytes)
    }
    
    func remove(_ key: String) { values[key] = nil }
    
    func keyCount() -> Int? { keyCountCalls += 1; return reportedCount ?? order.count }
    func key(at index: Int) -> String? { keyAtCalls += 1; return index < order.count ? order[index] : nil }
    func read(_ key: String) -> SMCValue? { values[key] }
}

private func sp78(_ degrees: Double) -> [UInt8] {
    let raw = UInt16(bitPattern: Int16((degrees * 256).rounded()))
    return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
}

private func floatLE(_ v: Float) -> [UInt8] {
    let b = v.bitPattern
    return [UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF), UInt8((b >> 16) & 0xFF), UInt8(b >> 24)]
}

@Suite("SMC value decoding")
struct SMCDecodeTests {
    private func temp(_ type: String, _ bytes: [UInt8]) -> Double? {
        SMCDecode.temperature(SMCValue(key: "TC0D", type: type, bytes: bytes))
    }
    
    @Test func decodesFixedPointSp78() {
        #expect(temp("sp78", [0x2D, 0x80]) == 45.5)
        #expect(temp("sp78", [0x1E, 0x00]) == 30)
        #expect(temp("sp78", [0x00, 0x80]) == nil, "0.5 degrees is below the plausible range")
        #expect(temp("sp78", [0xF6, 0x00]) == nil, "negative")
    }
    
    @Test func decodesFpe2() {
        #expect(temp("fpe2", [0x00, 0xB6]) == 45.5)
    }
    
    @Test func decodesFloats() {
        #expect(temp("flt ", floatLE(45.5)) == 45.5)
        #expect(temp("flt ", floatLE(45.5).reversed()) == 45.5, "big endian emulations")
    }
    
    @Test func rejectsImplausibleValues() {
        #expect(temp("sp78", sp78(125)) == nil)
        #expect(temp("sp78", sp78(124)) == 124)
        #expect(temp("flt ", floatLE(.nan)) == nil)
        #expect(temp("flt ", floatLE(.infinity)) == nil)
        #expect(temp("flt ", floatLE(500)) == nil)
        #expect(temp("flt ", floatLE(0)) == nil)
    }
    
    @Test func rejectsUnknownTypesAndShortData() {
        #expect(temp("ui32", [0, 0, 0, 40]) == nil)
        #expect(temp("ch8*", [0x34, 0x30]) == nil)
        #expect(temp("sp78", [0x2D]) == nil)
        #expect(temp("flt ", [1, 2, 3]) == nil)
        #expect(temp("sp78", []) == nil)
    }
}

@Suite("SMC sensor discovery")
struct SMCSensorProviderTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    
    private func provider(_ smc: FakeSMC?, created: (() -> Void)? = nil) -> SMCSensorProvider {
        SMCSensorProvider(makeTransport: { created?(); return smc })
    }
    
    @Test func bestSensorComesFirstRegardlessOfEnumerationOrder() {
        let smc = FakeSMC([
            ("TC0H", "sp78", sp78(40)), ("TC0P", "sp78", sp78(42)), ("TC0D", "sp78", sp78(55)), ("TCXC", "sp78", sp78(60))
        ])
        let items = provider(smc).sample(now: t0)
        #expect(items.map(\.id) == ["smc_TCXC", "smc_TC0D", "smc_TC0P", "smc_TC0H"])
        #expect(items.map(\.temperature) == [60, 55, 42, 40])
    }
    
    @Test func namesTellTheUserWhichSensorIsWhich() {
        let items = provider(FakeSMC([("TC0D", "sp78", sp78(50))])).sample(now: t0)
        #expect(items.first?.name == "CPU Die (TC0D)")
    }
    
    @Test func ignoresKeysThatAreNotCPUSensors() {
        let smc = FakeSMC([
            ("#KEY", "ui32", [0, 0, 0, 5]), ("TG0D", "sp78", sp78(70)), ("TCGC", "sp78", sp78(65)),
            ("TA0P", "sp78", sp78(30)), ("TC0D", "sp78", sp78(50))
        ])
        #expect(provider(smc).sample(now: t0).map(\.id) == ["smc_TC0D"])
    }
    
    @Test func skipsAnImplausibleReadingButKeepsTheOthers() {
        let smc = FakeSMC([("TC0D", "sp78", sp78(0)), ("TC0P", "sp78", sp78(41))])
        #expect(provider(smc).sample(now: t0).map(\.id) == ["smc_TC0P"])
    }
    
    @Test func addsTheHottestCoreWhenSeveralAreAvailable() {
        let smc = FakeSMC([("TC0C", "sp78", sp78(48)), ("TC1C", "sp78", sp78(63)), ("TC2C", "sp78", sp78(51))])
        let items = provider(smc).sample(now: t0)
        #expect(items.map(\.id) == [SMCSensorProvider.hottestCoreID])
        #expect(items.first?.temperature == 63)
    }
    
    @Test func aSingleCoreKeyIsNotWorthAnAggregate() {
        #expect(provider(FakeSMC([("TC0C", "sp78", sp78(48))])).sample(now: t0).isEmpty)
    }
    
    @Test func worksWithFloatSensorsFromAMDPlugins() {
        let items = provider(FakeSMC([("TC0D", "flt ", floatLE(61.25))])).sample(now: t0)
        #expect(items.first?.temperature == 61.25)
    }
    
    @Test func noSMCMeansNoSensors() {
        #expect(provider(nil).sample(now: t0).isEmpty)
    }
    
    @Test func anSMCWithoutTemperatureKeysMeansNoSensors() {
        let smc = FakeSMC([("#KEY", "ui32", [0, 0, 0, 2]), ("FNum", "ui8 ", [0])])
        #expect(provider(smc).sample(now: t0).isEmpty)
    }
    
    @Test func nonsenseKeyCountsAreRejected() {
        for count in [0, -3, 5_000_000] {
            let smc = FakeSMC([("TC0D", "sp78", sp78(50))])
            smc.reportedCount = count
            #expect(provider(smc).sample(now: t0).isEmpty, "count \(count)")
        }
    }
    
    // MARK: Efficiency and recovery
    
    @Test func keysAreEnumeratedOnceNotOnEverySample() {
        let smc = FakeSMC([("TC0D", "sp78", sp78(50)), ("TC0P", "sp78", sp78(40))])
        let p = provider(smc)
        _ = p.sample(now: t0)
        let enumerated = smc.keyAtCalls
        for i in 1...5 { _ = p.sample(now: t0.addingTimeInterval(Double(i))) }
        #expect(smc.keyAtCalls == enumerated)
        #expect(smc.keyCountCalls == 1)
    }
    
    @Test func readingsFollowTheHardwareBetweenSamples() {
        let smc = FakeSMC([("TC0D", "sp78", sp78(50))])
        let p = provider(smc)
        #expect(p.sample(now: t0).first?.temperature == 50)
        smc.set("TC0D", "sp78", sp78(72))
        #expect(p.sample(now: t0.addingTimeInterval(1)).first?.temperature == 72)
    }
    
    @Test func lateAppearingSensorsAreFoundByRediscovery() {
        let smc = FakeSMC([("FNum", "ui8 ", [0])])
        let p = provider(smc)
        #expect(p.sample(now: t0).isEmpty)
        smc.set("TC0D", "sp78", sp78(50))
        #expect(p.sample(now: t0.addingTimeInterval(SMCSensorProvider.rediscoveryInterval - 1)).isEmpty, "not before the interval")
        #expect(p.sample(now: t0.addingTimeInterval(SMCSensorProvider.rediscoveryInterval + 1)).map(\.id) == ["smc_TC0D"])
    }
    
    @Test func vanishedSensorsTriggerRediscoveryOnlyAfterTheInterval() {
        let smc = FakeSMC([("TC0D", "sp78", sp78(50)), ("TC0P", "sp78", sp78(40))])
        let p = provider(smc)
        #expect(p.sample(now: t0).count == 2)
        smc.remove("TC0D"); smc.remove("TC0P")
        #expect(p.sample(now: t0.addingTimeInterval(5)).isEmpty)
        let callsBefore = smc.keyCountCalls
        _ = p.sample(now: t0.addingTimeInterval(6))
        #expect(smc.keyCountCalls == callsBefore, "no hammering while nothing is readable")
        _ = p.sample(now: t0.addingTimeInterval(SMCSensorProvider.rediscoveryInterval + 1))
        #expect(smc.keyCountCalls == callsBefore + 1)
    }
    
    @Test func theConnectionIsRetriedOnlyOncePerInterval() {
        var attempts = 0
        let p = provider(nil, created: { attempts += 1 })
        _ = p.sample(now: t0)
        _ = p.sample(now: t0.addingTimeInterval(3))
        _ = p.sample(now: t0.addingTimeInterval(SMCSensorProvider.rediscoveryInterval - 1))
        #expect(attempts == 1)
        _ = p.sample(now: t0.addingTimeInterval(SMCSensorProvider.rediscoveryInterval))
        #expect(attempts == 2)
    }
}
