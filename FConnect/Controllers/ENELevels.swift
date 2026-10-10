import Foundation

/// Brightness / speed encodings of the ENE 6K77 chip (shared by every model that uses it).
public enum ENEBrightnessLevel: UInt8 {
    case highest = 0  // 100%
    case higher = 1   // 75%
    case normal = 2   // 50%
    case lower = 3    // 25%
    case lowest = 4   // 10% (minimum non-zero)
    case off = 8      // Completely OFF (0%)
    
    public static func from(percent: Int) -> UInt8 {
        if percent <= 0 { return ENEBrightnessLevel.off.rawValue }
        if percent >= 85 { return ENEBrightnessLevel.highest.rawValue }
        if percent >= 60 { return ENEBrightnessLevel.higher.rawValue }
        if percent >= 35 { return ENEBrightnessLevel.normal.rawValue }
        return ENEBrightnessLevel.lower.rawValue
    }
}

public enum ENESpeedLevel: UInt8 {
    case lowest = 2   // 0%
    case lower = 1    // 25%
    case normal = 0   // 50%
    case faster = 255 // 75%
    case fastest = 254// 100%
    
    public static func from(level: Int) -> UInt8 {
        switch level {
        case 0: return ENESpeedLevel.lowest.rawValue
        case 1: return ENESpeedLevel.lower.rawValue
        case 2: return ENESpeedLevel.normal.rawValue
        case 3: return ENESpeedLevel.faster.rawValue
        default: return ENESpeedLevel.fastest.rawValue
        }
    }
}
