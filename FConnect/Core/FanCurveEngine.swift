import Foundation

/// Decides which duty to write to each fan group. Pure: no I/O, no clock, no singletons.
public enum FanCurveEngine {
    /// Ignore changes smaller than this (in % duty) so sensor jitter does not make the fans hunt.
    public static let deadband = 2
    /// How long a missing temperature reading is tolerated before the fans are forced to a safe speed.
    public static let sensorLossTimeout: TimeInterval = 15
    /// Floor applied when there is no temperature reading.
    public static let failsafeDuty = 70
    
    public struct Command: Equatable {
        public let group: Int
        public let percent: Int
    }
    
    /// Writes needed to follow each non-synced group's curve at `temperature`.
    public static func commands(for groups: [FanGroupState], temperature: Double) -> [Command] {
        var result = [Command]()
        for (i, group) in groups.enumerated() where !group.isRPMSync {
            let speed = Int(group.curvePoints.interpolatedSpeed(for: temperature).rounded())
            // Deadband against sensor jitter, but always allow reaching the exact ends of the range.
            let reachesEnd = (speed == 0 || speed == 100) && speed != group.targetDuty
            if abs(speed - group.targetDuty) >= deadband || reachesEnd {
                result.append(Command(group: i, percent: speed))
            }
        }
        return result
    }
    
    /// Without a temperature we cannot tell whether the CPU is heating up: hold the last speed briefly, then never stay below the floor.
    public static func failsafeCommands(for groups: [FanGroupState], secondsWithoutReading: TimeInterval) -> [Command] {
        guard secondsWithoutReading > sensorLossTimeout else { return [] }
        var result = [Command]()
        for (i, group) in groups.enumerated() where !group.isRPMSync && group.targetDuty < failsafeDuty {
            result.append(Command(group: i, percent: failsafeDuty))
        }
        return result
    }
}
