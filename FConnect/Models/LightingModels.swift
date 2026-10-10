import Foundation

public struct RGBColor: Codable, Equatable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
    
    public static let off = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 255, green: 255, blue: 255)
    public static let red = RGBColor(red: 255, green: 0, blue: 0)
    public static let green = RGBColor(red: 0, green: 255, blue: 0)
    public static let blue = RGBColor(red: 0, green: 0, blue: 255)
    public static let cyan = RGBColor(red: 0, green: 255, blue: 255)
    public static let magenta = RGBColor(red: 255, green: 0, blue: 255)
    public static let yellow = RGBColor(red: 255, green: 255, blue: 0)
    public static let orange = RGBColor(red: 255, green: 128, blue: 0)
}

public enum FanLightingMode: Int, CaseIterable, Identifiable, Codable {
    case rainbow = 5
    case rainbowMorph = 4
    case staticColor = 1
    case breathing = 2
    case colorCycle = 35
    case runway = 28
    case staggered = 24
    case tide = 26
    case meteor = 36
    case mixing = 30
    case stack = 32
    case stackMulti = 33
    case neon = 34
    case render = 40
    case tunnel = 41
    
    public var id: Int { rawValue }
    
    public var protocolByte: UInt8 {
        UInt8(rawValue)
    }
    
    public var title: String {
        switch self {
        case .staticColor: return "Static Color"
        case .breathing: return "Breathing"
        case .rainbow: return "Rainbow"
        case .rainbowMorph: return "Rainbow Morph"
        case .staggered: return "Staggered"
        case .tide: return "Tide"
        case .runway: return "Runway"
        case .mixing: return "Mixing"
        case .stack: return "Stack"
        case .stackMulti: return "Stack Multi"
        case .neon: return "Neon"
        case .colorCycle: return "Color Cycle"
        case .meteor: return "Meteor"
        case .render: return "Render"
        case .tunnel: return "Tunnel"
        }
    }
    
    public var maxColors: Int {
        switch self {
        case .staticColor, .breathing:
            return 4 // Up to 4 custom color slots
        case .colorCycle:
            return 3 // Exactly 3 colors
        case .runway, .staggered, .tide, .meteor, .mixing:
            return 2 // 2 colors (foreground & background / wave)
        case .stack:
            return 1 // Single color
        case .render, .tunnel:
            return 4 // 4 quadrant/ring colors
        case .rainbow, .rainbowMorph, .neon, .stackMulti:
            return 0 // Full spectrum / dynamic (no user color slots)
        }
    }
}
