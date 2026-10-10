import Foundation
import IOKit
import IOKit.hid

public protocol HIDDeviceProtocol: AnyObject {
    var vendorID: UInt16 { get }
    var productID: UInt16 { get }
    var serialNumber: String { get }
    var productName: String { get }
    
    /// Failed operations in a row since the last success; 0 while the device is healthy.
    var consecutiveFailures: Int { get }
    /// IOKit code of the most recent failure (0 if none yet).
    var lastErrorCode: Int32 { get }
    
    func open() -> Bool
    func close()
    func sendFeatureReport(_ data: [UInt8]) -> Bool
    func getInputReport(reportID: UInt8, length: Int) -> [UInt8]?
    func writeOutputReport(_ data: [UInt8]) -> Bool
    /// Runs a multi-step exchange (e.g. request -> response) without other threads touching the device in between.
    func transaction<T>(_ body: () -> T) -> T
}

// All mutable state is guarded by `ioLock`.
public final class IOHIDDeviceWrapper: HIDDeviceProtocol, @unchecked Sendable {
    private let device: IOHIDDevice
    public let vendorID: UInt16
    public let productID: UInt16
    public let serialNumber: String
    public let productName: String
    private var isOpen = false
    private let ioLock = NSRecursiveLock()
    private var _consecutiveFailures = 0
    private var _lastErrorCode: Int32 = 0
    /// The controller needs a pause after each command (the original software sleeps 20 ms); bursts confuse its reply buffer.
    private let writeDelay: TimeInterval
    
    public init(device: IOHIDDevice, writeDelay: TimeInterval = 0.02) {
        self.device = device
        self.writeDelay = writeDelay
        self.vendorID = UInt16(IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0)
        self.productID = UInt16(IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0)
        self.productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown LianLi Device"
        self.serialNumber = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""
    }
    
    public var consecutiveFailures: Int { ioLock.locked { _consecutiveFailures } }
    public var lastErrorCode: Int32 { ioLock.locked { _lastErrorCode } }
    
    /// Records the outcome of one operation (caller holds `ioLock`).
    private func record(_ code: Int32) {
        if code == kIOReturnSuccess {
            _consecutiveFailures = 0
        } else {
            _consecutiveFailures += 1
            _lastErrorCode = code
        }
    }
    
    public func transaction<T>(_ body: () -> T) -> T {
        ioLock.lock()
        defer { ioLock.unlock() }
        return body()
    }
    
    public func open() -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        if isOpen { return true }
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = (ret == kIOReturnSuccess)
        record(ret)
        return isOpen
    }
    
    public func close() {
        ioLock.lock()
        defer { ioLock.unlock() }
        if isOpen {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            isOpen = false
        }
    }
    
    public func sendFeatureReport(_ data: [UInt8]) -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !data.isEmpty else { return false }
        if !isOpen && !open() { return false }
        var ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(data[0]), data, data.count)
        if ret == kIOReturnNotOpen {
            isOpen = false
            if open() { ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(data[0]), data, data.count) }
        }
        record(ret)
        Thread.sleep(forTimeInterval: writeDelay)
        return ret == kIOReturnSuccess
    }
    
    public func getInputReport(reportID: UInt8, length: Int) -> [UInt8]? {
        ioLock.lock()
        defer { ioLock.unlock() }
        if !isOpen && !open() { return nil }
        var buffer = [UInt8](repeating: 0, count: max(length, 65))
        buffer[0] = reportID
        var actualLength: CFIndex = buffer.count
        var ret = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(reportID), &buffer, &actualLength)
        if ret == kIOReturnNotOpen {
            isOpen = false
            if open() {
                actualLength = buffer.count
                ret = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(reportID), &buffer, &actualLength)
            }
        }
        record(ret)
        guard ret == kIOReturnSuccess, actualLength > 0 else { return nil }
        return Array(buffer.prefix(actualLength))
    }
    
    public func writeOutputReport(_ data: [UInt8]) -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !data.isEmpty else { return false }
        if !isOpen && !open() { return false }
        var ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(data[0]), data, data.count)
        if ret == kIOReturnNotOpen {
            isOpen = false
            if open() { ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(data[0]), data, data.count) }
        }
        record(ret)
        Thread.sleep(forTimeInterval: writeDelay)
        return ret == kIOReturnSuccess
    }
    
}

extension NSLocking {
    /// Runs `body` while holding the lock.
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
