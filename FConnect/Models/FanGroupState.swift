import Foundation

/// Settings and live state of one fan port.
///
/// Persistence is deliberately forgiving: a saved blob written by any other version of the app (missing keys, unknown
/// enum values) still loads, falling back to defaults per field. `rpm` is live telemetry and is never saved.
public struct FanGroupState: Identifiable, Equatable, Codable {
    public let id: Int // 0..3 (Ports 1..4)
    public var customName: String?
    public var isHidden: Bool = false
    public var name: String { customName?.isEmpty == false ? customName! : "Group \(id + 1)" }
    public var rpm: Int = 0
    public var targetDuty: Int = 40
    public var fanCount: Int = 3
    public var lightingMode: FanLightingMode = .rainbow
    public var speedIndex: Int = 2
    public var brightnessPercent: Int = 100
    public var direction: UInt8 = 0
    public var staticColor: RGBColor = .cyan
    /// All colors of the current effect (multi-zone). Empty means "just `staticColor`" (settings saved by older versions).
    public var lightingColors: [RGBColor] = []
    /// What to send to the hardware: the saved colors, or the single legacy color.
    public var effectiveLightingColors: [RGBColor] { lightingColors.isEmpty ? [staticColor] : lightingColors }
    public var isRPMSync: Bool = false
    public var profilePreset: FanSpeedProfilePreset = .standard
    public var curvePoints: [CurvePoint] = FanSpeedProfilePreset.standard.defaultPoints
    
    public init(id: Int, fanCount: Int = 3, customName: String? = nil, isHidden: Bool = false, isRPMSync: Bool = false) {
        self.id = id
        self.fanCount = fanCount
        self.customName = customName
        self.isHidden = isHidden
        self.isRPMSync = isRPMSync
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, customName, isHidden, fanCount, targetDuty, lightingMode, speedIndex, brightnessPercent
        case direction, staticColor, lightingColors, isRPMSync, profilePreset, curvePoints
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(Int.self, forKey: .id))
        
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        customName = value(.customName)
        isHidden = value(.isHidden) ?? isHidden
        fanCount = value(.fanCount) ?? fanCount
        targetDuty = value(.targetDuty) ?? targetDuty
        lightingMode = value(.lightingMode) ?? lightingMode
        speedIndex = value(.speedIndex) ?? speedIndex
        brightnessPercent = value(.brightnessPercent) ?? brightnessPercent
        direction = value(.direction) ?? direction
        staticColor = value(.staticColor) ?? staticColor
        lightingColors = value(.lightingColors) ?? []
        isRPMSync = value(.isRPMSync) ?? isRPMSync
        profilePreset = value(.profilePreset) ?? profilePreset
        if let points: [CurvePoint] = value(.curvePoints), points.count >= 2 {
            curvePoints = points
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(customName, forKey: .customName)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encode(fanCount, forKey: .fanCount)
        try c.encode(targetDuty, forKey: .targetDuty)
        try c.encode(lightingMode, forKey: .lightingMode)
        try c.encode(speedIndex, forKey: .speedIndex)
        try c.encode(brightnessPercent, forKey: .brightnessPercent)
        try c.encode(direction, forKey: .direction)
        try c.encode(staticColor, forKey: .staticColor)
        try c.encode(lightingColors, forKey: .lightingColors)
        try c.encode(isRPMSync, forKey: .isRPMSync)
        try c.encode(profilePreset, forKey: .profilePreset)
        try c.encode(curvePoints, forKey: .curvePoints)
    }
}
