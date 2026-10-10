import Foundation
import Testing

@Suite("Curve interpolation")
struct CurveInterpolationTests {
    private func curve(_ pairs: [(Double, Double)]) -> [CurvePoint] {
        pairs.map { CurvePoint(temp: $0.0, speed: $0.1) }
    }
    
    @Test func clampsOutsideTheCurve() {
        let c = curve([(20, 30), (80, 90)])
        #expect(c.interpolatedSpeed(for: -10) == 30)
        #expect(c.interpolatedSpeed(for: 20) == 30)
        #expect(c.interpolatedSpeed(for: 80) == 90)
        #expect(c.interpolatedSpeed(for: 200) == 90)
    }
    
    @Test func interpolatesLinearlyBetweenPoints() {
        let c = curve([(20, 30), (80, 90)])
        #expect(c.interpolatedSpeed(for: 50) == 60)
        #expect(c.interpolatedSpeed(for: 35) == 45)
    }
    
    @Test func handlesUnsortedPoints() {
        let c = curve([(80, 90), (20, 30), (50, 60)])
        #expect(c.interpolatedSpeed(for: 35) == 45)
    }
    
    @Test func picksTheRightSegment() {
        let c = curve([(20, 20), (40, 30), (60, 50), (80, 80)])
        #expect(c.interpolatedSpeed(for: 50) == 40)
        #expect(c.interpolatedSpeed(for: 70) == 65)
    }
    
    @Test func emptyCurveFallsBackToFiftyPercent() {
        #expect([CurvePoint]().interpolatedSpeed(for: 40) == 50)
    }
    
    @Test func duplicateTemperaturesDoNotDivideByZero() {
        let c = curve([(40, 30), (40, 70), (80, 100)])
        let speed = c.interpolatedSpeed(for: 40)
        #expect(speed.isFinite)
        #expect(speed >= 30 && speed <= 70)
    }
    
    @Test func everyPresetIsMonotonicAndInRange() {
        for preset in FanSpeedProfilePreset.allCases {
            let points = preset.defaultPoints.sorted { $0.temp < $1.temp }
            #expect(points.count >= 2, "\(preset.rawValue)")
            for point in points { #expect((0...100).contains(point.speed) && (0...100).contains(point.temp)) }
            if preset != .manual {
                #expect(zip(points, points.dropFirst()).allSatisfy { $0.speed <= $1.speed }, "\(preset.rawValue) must not get slower when hotter")
            }
        }
    }
}

@Suite("Fan curve engine")
struct FanCurveEngineTests {
    private func group(_ id: Int, duty: Int, sync: Bool = false, curve: [(Double, Double)] = [(20, 20), (80, 80)]) -> FanGroupState {
        var g = FanGroupState(id: id)
        g.targetDuty = duty
        g.isRPMSync = sync
        g.curvePoints = curve.map { CurvePoint(temp: $0.0, speed: $0.1) }
        return g
    }
    
    @Test func followsTheCurve() {
        // At 50 degrees the curve gives 50%
        let result = FanCurveEngine.commands(for: [group(0, duty: 30)], temperature: 50)
        #expect(result == [.init(group: 0, percent: 50)])
    }
    
    @Test func skipsGroupsDrivenByTheMotherboard() {
        let result = FanCurveEngine.commands(for: [group(0, duty: 30, sync: true), group(1, duty: 30)], temperature: 50)
        #expect(result == [.init(group: 1, percent: 50)])
    }
    
    @Test func deadbandSuppressesSmallChanges() {
        #expect(FanCurveEngine.commands(for: [group(0, duty: 49)], temperature: 50).isEmpty)
        #expect(FanCurveEngine.commands(for: [group(0, duty: 51)], temperature: 50).isEmpty)
        #expect(FanCurveEngine.commands(for: [group(0, duty: 48)], temperature: 50).count == 1)
        #expect(FanCurveEngine.commands(for: [group(0, duty: 52)], temperature: 50).count == 1)
    }
    
    @Test func alwaysReachesTheEndsOfTheRange() {
        // 1% away from the target, but the target is 0% / 100%: must still be written
        #expect(FanCurveEngine.commands(for: [group(0, duty: 99, curve: [(20, 100), (80, 100)])], temperature: 50) == [.init(group: 0, percent: 100)])
        #expect(FanCurveEngine.commands(for: [group(0, duty: 1, curve: [(20, 0), (80, 0)])], temperature: 50) == [.init(group: 0, percent: 0)])
        #expect(FanCurveEngine.commands(for: [group(0, duty: 100, curve: [(20, 100), (80, 100)])], temperature: 50).isEmpty)
    }
    
    @Test func roundsToNearestPercent() {
        // 20..80 -> 20..80 gives 33.33 at 33.33 degrees
        let result = FanCurveEngine.commands(for: [group(0, duty: 0)], temperature: 33.4)
        #expect(result == [.init(group: 0, percent: 33)])
    }
    
    @Test func identicalTemperatureProducesNoRepeatedWrites() {
        let first = FanCurveEngine.commands(for: [group(0, duty: 30)], temperature: 50)
        let applied = group(0, duty: first[0].percent)
        #expect(FanCurveEngine.commands(for: [applied], temperature: 50).isEmpty)
    }
    
    // MARK: Sensor loss failsafe
    
    @Test func failsafeWaitsForTheTimeout() {
        let groups = [group(0, duty: 30)]
        #expect(FanCurveEngine.failsafeCommands(for: groups, secondsWithoutReading: 5).isEmpty)
        #expect(FanCurveEngine.failsafeCommands(for: groups, secondsWithoutReading: FanCurveEngine.sensorLossTimeout).isEmpty)
        #expect(FanCurveEngine.failsafeCommands(for: groups, secondsWithoutReading: FanCurveEngine.sensorLossTimeout + 0.1).count == 1)
    }
    
    @Test func failsafeRaisesSlowFansToTheFloor() {
        let groups = [group(0, duty: 30), group(1, duty: 90), group(2, duty: 70), group(3, duty: 20, sync: true)]
        let result = FanCurveEngine.failsafeCommands(for: groups, secondsWithoutReading: 60)
        #expect(result == [.init(group: 0, percent: FanCurveEngine.failsafeDuty)])
    }
    
    @Test func failsafeDoesNotRepeatOnceApplied() {
        let groups = [group(0, duty: FanCurveEngine.failsafeDuty)]
        #expect(FanCurveEngine.failsafeCommands(for: groups, secondsWithoutReading: 60).isEmpty)
    }
}

@Suite("Thermal reading validity")
struct ThermalReadingTests {
    private let sensors = [
        ThermalSensorItem(id: "cpu_package", name: "CPU", temperature: 44.5),
        ThermalSensorItem(id: "gpu_0", name: "GPU", temperature: 51)
    ]
    private let now = Date(timeIntervalSince1970: 1_000_000)
    
    @Test func returnsTheSelectedSensor() {
        #expect(SystemThermalMonitor.temperature(of: "cpu_package", in: sensors, sampledAt: now, now: now) == 44.5)
        #expect(SystemThermalMonitor.temperature(of: "gpu_0", in: sensors, sampledAt: now, now: now) == 51)
    }
    
    @Test func staleReadingIsNoReading() {
        let old = now.addingTimeInterval(-(SystemThermalMonitor.maxReadingAge + 1))
        #expect(SystemThermalMonitor.temperature(of: "cpu_package", in: sensors, sampledAt: old, now: now) == nil)
        let fresh = now.addingTimeInterval(-(SystemThermalMonitor.maxReadingAge - 1))
        #expect(SystemThermalMonitor.temperature(of: "cpu_package", in: sensors, sampledAt: fresh, now: now) == 44.5)
    }
    
    @Test func missingSensorIsNoReading() {
        #expect(SystemThermalMonitor.temperature(of: "gpu_9", in: sensors, sampledAt: now, now: now) == nil)
        #expect(SystemThermalMonitor.temperature(of: "", in: sensors, sampledAt: now, now: now) == nil)
        #expect(SystemThermalMonitor.temperature(of: "cpu_package", in: [], sampledAt: now, now: now) == nil)
    }
    
    @Test func neverSampledIsNoReading() {
        #expect(SystemThermalMonitor.temperature(of: "cpu_package", in: sensors, sampledAt: .distantPast, now: now) == nil)
    }
}
