import Foundation

/// One physical USB device can show up as several HID interfaces. Only one of them talks the controller protocol.
struct PhysicalDeviceKey: Hashable {
    let vendorID: Int
    let productID: Int
    let locationID: Int
}

struct HIDInterfaceInfo {
    let key: PhysicalDeviceKey
    let usagePage: Int
    let usage: Int
    let registryID: UInt64
}

enum InterfaceGrouping {
    /// Groups interfaces of the same physical device. Inside a group interfaces are ordered deterministically
    /// (usage page, usage, registry ID); groups themselves are ordered the same way by their first interface.
    static func groups<T>(_ items: [T], info: (T) -> HIDInterfaceInfo) -> [[T]] {
        func order(_ i: HIDInterfaceInfo) -> [UInt64] { [UInt64(max(0, i.usagePage)), UInt64(max(0, i.usage)), i.registryID] }
        func less(_ a: HIDInterfaceInfo, _ b: HIDInterfaceInfo) -> Bool { order(a).lexicographicallyPrecedes(order(b)) }
        
        let grouped = Dictionary(grouping: items) { info($0).key }
        return grouped.values
            .map { $0.sorted { less(info($0), info($1)) } }
            .sorted { less(info($0[0]), info($1[0])) }
    }
}
