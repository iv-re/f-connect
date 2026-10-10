import Testing

@Suite("Lighting commands")
struct LightingTests {
    private let fourColors: [RGBColor] = [.red, .green, .blue, .yellow]
    
    private func commands(_ p: Ene6K77Profile, _ mode: FanLightingMode, group: Int = 1, colors: [RGBColor]? = nil) -> [LightingCommand] {
        p.lightingCommands(group: group, mode: mode, colors: colors ?? fourColors, speed: 2, direction: 0, brightness: 0)
    }
    
    private func colorCount(_ c: LightingCommand) -> Int { (c.colors.count - 2) / 3 }
    
    // MARK: Payload sizes (from the original software)
    
    @Test func singleRingPayloadSizes() {
        #expect(colorCount(commands(.slV2, .staticColor)[0]) == 96)
        #expect(colorCount(commands(.slV2, .rainbow)[0]) == 24)
        #expect(colorCount(commands(.slV1, .staticColor)[0]) == 64)
        #expect(colorCount(commands(.slV1, .rainbow)[0]) == 16)
    }
    
    @Test func dualRingPayloadSizes() {
        // static / breathing: inner ring, then outer ring
        for (p, inner, outer) in [(Ene6K77Profile.slInfinity, 32, 48), (.alV1, 32, 48), (.alV2, 48, 72)] {
            let c = commands(p, .staticColor)
            #expect(c.count == 2)
            #expect(colorCount(c[0]) == inner)
            #expect(colorCount(c[1]) == outer)
        }
        // zone effects use fan-group colors
        #expect(colorCount(commands(.slInfinity, .runway)[0]) == 16)
        #expect(colorCount(commands(.alV2, .runway)[0]) == 36)
    }
    
    // MARK: Port addressing
    
    @Test func singleRingUsesOnePortPerGroup() {
        #expect(commands(.slV2, .staticColor, group: 3).map(\.port) == [3])
    }
    
    @Test func dualRingUsesInnerAndOuterPorts() {
        #expect(commands(.slInfinity, .staticColor, group: 0).map(\.port) == [0, 1])
        #expect(commands(.slInfinity, .staticColor, group: 3).map(\.port) == [6, 7])
        #expect(commands(.alV2, .breathing, group: 2).map(\.port) == [4, 5])
    }
    
    @Test func combinedEffectGoesToInnerPortOnly() {
        #expect(commands(.slInfinity, .rainbow, group: 2).map(\.port) == [4])
        #expect(commands(.alV2, .tide, group: 1).map(\.port) == [2])
    }
    
    @Test func reportsCarryTheirPort() {
        for c in commands(.alV2, .staticColor, group: 2) {
            #expect(c.colors[0] == 0xE0)
            #expect(c.colors[1] == UInt8(0x30 | c.port))
            #expect(c.effect[0] == 0xE0)
            #expect(c.effect[1] == UInt8(0x10 | c.port))
        }
    }
    
    // MARK: Effect bytes (match the mode lists in the original UI)
    
    @Test func singleRingEffectBytesMatchOriginalUI() {
        let expected: [(FanLightingMode, UInt8)] = [
            (.rainbow, 5), (.rainbowMorph, 4), (.staticColor, 1), (.breathing, 2), (.colorCycle, 35), (.runway, 28),
            (.staggered, 24), (.tide, 26), (.meteor, 36), (.mixing, 30), (.stack, 32), (.stackMulti, 33),
            (.neon, 34), (.render, 40), (.tunnel, 41)
        ]
        for (mode, byte) in expected {
            #expect(commands(.slV2, mode)[0].effect[2] == byte, "SL V2 \(mode.title)")
        }
    }
    
    @Test func alV2EffectBytesMatchOriginalUI() {
        let combined: [(FanLightingMode, UInt8)] = [
            (.rainbow, 43), (.rainbowMorph, 4), (.colorCycle, 46), (.staggered, 64), (.tide, 51),
            (.mixing, 50), (.stack, 67), (.render, 57)
        ]
        for (mode, byte) in combined {
            #expect(commands(.alV2, mode)[0].effect[2] == byte, "AL V2 \(mode.title)")
        }
        let perRing: [(FanLightingMode, UInt8)] = [(.staticColor, 1), (.breathing, 2), (.runway, 26), (.meteor, 25)]
        for (mode, byte) in perRing {
            let c = commands(.alV2, mode)
            #expect(c.map { $0.effect[2] } == [byte, byte], "AL V2 \(mode.title)")
        }
    }
    
    @Test func slInfinityEffectBytesMatchOriginalUI() {
        let combined: [(FanLightingMode, UInt8)] = [
            (.rainbow, 50), (.rainbowMorph, 63), (.tide, 58), (.mixing, 56), (.stack, 57)
        ]
        for (mode, byte) in combined {
            #expect(commands(.slInfinity, mode)[0].effect[2] == byte, "SL-Infinity \(mode.title)")
        }
        #expect(commands(.slInfinity, .colorCycle).map { $0.effect[2] } == [24, 24])
        #expect(commands(.slInfinity, .runway).map { $0.effect[2] } == [26, 26])
        #expect(commands(.slInfinity, .meteor).map { $0.effect[2] } == [25, 25])
    }
    
    // MARK: Mode support
    
    @Test func supportedModesPerModel() {
        #expect(Ene6K77Profile.slV2.lighting.supportedModes.count == FanLightingMode.allCases.count)
        #expect(!Ene6K77Profile.slV1.lighting.supportedModes.contains(.render))
        #expect(!Ene6K77Profile.slV1.lighting.supportedModes.contains(.tunnel))
        #expect(Ene6K77Profile.slV1.lighting.supportedModes.contains(.neon))
        for p in [Ene6K77Profile.slInfinity, .alV1, .alV2] {
            #expect(!p.lighting.supportedModes.contains(.neon))
            #expect(!p.lighting.supportedModes.contains(.tunnel))
            #expect(p.lighting.isDualRing)
        }
    }
    
    @Test func everyModelSupportsTheFallbackAndDefaultModes() {
        for p in Ene6K77Profile.all {
            for mode in [FanLightingMode.staticColor, .breathing, .rainbow] {
                #expect(p.lighting.modes[mode] != nil, "\(p.defaultName) lacks \(mode.title)")
            }
        }
    }
    
    @Test func unsupportedModeFallsBackToStaticColor() {
        let fallback = commands(.slInfinity, .neon)
        let reference = commands(.slInfinity, .staticColor)
        #expect(fallback == reference)
        #expect(Ene6K77Profile.slInfinity.effectiveMode(.neon) == .staticColor)
        #expect(Ene6K77Profile.slV2.effectiveMode(.neon) == .neon)
    }
    
    // MARK: Colors
    
    @Test func colorsAreSentInRBGOrder() {
        let color = RGBColor(red: 10, green: 20, blue: 30)
        let payload = commands(.slV2, .staticColor, colors: [color])[0].colors
        #expect(Array(payload[2..<5]) == [10, 30, 20])
    }
    
    @Test func perFanColorsFallBackToTheFirstColor() {
        // SL V2 has 6 fans (16 LEDs each); only 4 colors are given -> fans 5 and 6 reuse color 0.
        let payload = commands(.slV2, .staticColor)[0].colors
        func fanColor(_ fan: Int) -> [UInt8] { Array(payload[(2 + fan * 16 * 3)..<(2 + fan * 16 * 3 + 3)]) }
        #expect(fanColor(0) == [255, 0, 0])      // red
        #expect(fanColor(1) == [0, 0, 255])      // green  (R, B, G)
        #expect(fanColor(3) == [255, 0, 255])    // yellow (R, B, G)
        #expect(fanColor(4) == [255, 0, 0])
        #expect(fanColor(5) == [255, 0, 0])
    }
    
    @Test func zoneColorsFillMissingSlotsWithBlack() {
        let payload = commands(.slV2, .rainbow, colors: [.red])[0].colors
        #expect(Array(payload[2..<5]) == [255, 0, 0])      // slot 0
        #expect(Array(payload[5..<8]) == [0, 0, 0])        // slot 1 -> off
    }
    
    @Test func emptyColorListDefaultsToCyan() {
        let payload = commands(.slV2, .staticColor, colors: [])[0].colors
        #expect(Array(payload[2..<5]) == [0, 255, 255])    // cyan in R, B, G
    }
    
    @Test func speedDirectionAndBrightnessAreForwarded() {
        let c = Ene6K77Profile.slV2.lightingCommands(group: 0, mode: .rainbow, colors: [.red], speed: 255, direction: 1, brightness: 8)
        #expect(Array(c[0].effect[3...]) == [255, 1, 8])
    }
}
