import Foundation
import SwiftUI

public enum FanSpeedProfilePreset: String, CaseIterable, Identifiable, Codable {
    case quiet = "Quiet"
    case standard = "Standard"
    case highSpeed = "High Speed"
    case fullSpeed = "Full Speed"
    case manual = "Manual"
    
    public var id: String { rawValue }
    
    public var defaultPoints: [CurvePoint] {
        switch self {
        case .quiet:
            return [
                CurvePoint(temp: 20, speed: 20),
                CurvePoint(temp: 40, speed: 30),
                CurvePoint(temp: 60, speed: 50),
                CurvePoint(temp: 80, speed: 80)
            ]
        case .standard:
            return [
                CurvePoint(temp: 20, speed: 30),
                CurvePoint(temp: 45, speed: 50),
                CurvePoint(temp: 65, speed: 75),
                CurvePoint(temp: 85, speed: 100)
            ]
        case .highSpeed:
            return [
                CurvePoint(temp: 20, speed: 50),
                CurvePoint(temp: 40, speed: 70),
                CurvePoint(temp: 60, speed: 85),
                CurvePoint(temp: 80, speed: 100)
            ]
        case .fullSpeed:
            return [
                CurvePoint(temp: 20, speed: 100),
                CurvePoint(temp: 40, speed: 100),
                CurvePoint(temp: 60, speed: 100),
                CurvePoint(temp: 80, speed: 100)
            ]
        case .manual:
            return [
                CurvePoint(temp: 20, speed: 50),
                CurvePoint(temp: 50, speed: 50),
                CurvePoint(temp: 75, speed: 75),
                CurvePoint(temp: 90, speed: 100)
            ]
        }
    }
}

public struct CurvePoint: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var temp: Double // °C 0..100
    public var speed: Double // % 0..100
    
    public init(temp: Double, speed: Double) {
        self.temp = temp
        self.speed = speed
    }
    
    // `id` only identifies the point inside the UI; it is regenerated on load and never saved.
    private enum CodingKeys: String, CodingKey { case temp, speed }
}

extension Collection where Element == CurvePoint {
    public func interpolatedSpeed(for temp: Double) -> Double {
        let sorted = self.sorted { $0.temp < $1.temp }
        guard let first = sorted.first, let last = sorted.last else { return 50 }
        if temp <= first.temp { return first.speed }
        if temp >= last.temp { return last.speed }
        for i in 0..<(sorted.count - 1) {
            let p1 = sorted[i]
            let p2 = sorted[i + 1]
            if temp >= p1.temp && temp <= p2.temp {
                let diff = p2.temp - p1.temp
                guard diff > 0 else { return p1.speed }
                let ratio = (temp - p1.temp) / diff
                return p1.speed + ratio * (p2.speed - p1.speed)
            }
        }
        return 50
    }
}
