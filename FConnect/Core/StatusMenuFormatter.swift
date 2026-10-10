import Foundation

/// Text of the status bar menu. Pure so it can be tested; the menu only decides when to refresh it.
public enum StatusMenuFormatter {
    public static let sectionTitle = "Fan Speeds"
    
    /// Short note on how the group's speed is decided: "MB Sync", "Quiet, 33%" or "Custom, 61%".
    public static func controlDescription(for group: FanGroupState) -> String {
        if group.isRPMSync { return "MB Sync" }
        switch group.profilePreset {
        case .manual: return "Custom, \(group.targetDuty)%"
        default: return "\(group.profilePreset.rawValue), \(group.targetDuty)%"
        }
    }
    
    /// e.g. "Group 1: 720 RPM (Quiet, 33%)" or "Group 2: 525 RPM (MB Sync)"
    public static func groupLine(_ group: FanGroupState) -> String {
        "\(group.name): \(group.rpm) RPM (\(controlDescription(for: group)))"
    }
}
