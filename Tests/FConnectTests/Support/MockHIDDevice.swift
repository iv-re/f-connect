import Foundation

/// In-memory stand-in for a Lian Li hub: records everything sent and answers requests through `replyProvider`.
final class MockHIDDevice: HIDDeviceProtocol {
    let vendorID: UInt16 = 0x0CF2
    var productID: UInt16 = 0xA105
    let serialNumber = "TEST"
    let productName: String
    
    private let lock = NSRecursiveLock()
    private var _features: [[UInt8]] = []
    private var _outputs: [[UInt8]] = []
    private var lastFeature: [UInt8] = []
    private var _inputReads = 0
    
    /// Called with the last feature report whenever the code reads an input report. Return nil for "no reply".
    var replyProvider: (([UInt8]) -> [UInt8]?)?
    var openResult = true
    /// Runs before each feature report is recorded (outside the lock); tests use it to hold the write queue.
    var beforeFeature: (([UInt8]) -> Void)?
    var consecutiveFailures = 0
    var lastErrorCode: Int32 = 0
    
    init(productName: String = "LianLi-UNI FAN-SL V2-v0.7") {
        self.productName = productName
    }
    
    var features: [[UInt8]] { lock.locked { _features } }
    var outputs: [[UInt8]] { lock.locked { _outputs } }
    var inputReads: Int { lock.locked { _inputReads } }
    
    func clearRecording() {
        lock.locked {
            _features.removeAll()
            _outputs.removeAll()
            _inputReads = 0
        }
    }
    
    func open() -> Bool { openResult }
    func close() {}
    
    func sendFeatureReport(_ data: [UInt8]) -> Bool {
        beforeFeature?(data)
        lock.locked {
            _features.append(data)
            lastFeature = data
        }
        return true
    }
    
    func getInputReport(reportID: UInt8, length: Int) -> [UInt8]? {
        let request = lock.locked { () -> [UInt8] in
            _inputReads += 1
            return lastFeature
        }
        return replyProvider?(request)
    }
    
    func writeOutputReport(_ data: [UInt8]) -> Bool {
        lock.locked { _outputs.append(data) }
        return true
    }
    
    func transaction<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Canned replies as the real hub produces them (report ID first).
enum Replies {
    /// `E0 F0 <4 x 16-bit big endian>` - SL V2 / AL V2 layout.
    static func rpmWithHeader(_ rpms: [Int]) -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: 65)
        reply[0] = 0xE0
        reply[1] = 0xF0
        for (i, rpm) in rpms.enumerated() {
            reply[2 + i * 2] = UInt8(rpm >> 8)
            reply[3 + i * 2] = UInt8(rpm & 0xFF)
        }
        return reply
    }
    
    /// `E0 <4 x 16-bit big endian>` - SL V1 / AL V1 / SL-Infinity layout.
    static func rpmWithoutHeader(_ rpms: [Int]) -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: 65)
        reply[0] = 0xE0
        for (i, rpm) in rpms.enumerated() {
            reply[1 + i * 2] = UInt8(rpm >> 8)
            reply[2 + i * 2] = UInt8(rpm & 0xFF)
        }
        return reply
    }
    
    /// `E0 E0 50 <major> <minor> <fine>`. The default is the real reply of the SL V2 used during development.
    static func firmware(major: UInt8 = 100, minor: UInt8 = 199, fine: UInt8 = 7) -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: 65)
        reply[0] = 0xE0; reply[1] = 0xE0; reply[2] = 0x50
        reply[3] = major; reply[4] = minor; reply[5] = fine
        return reply
    }
    
    /// A device that answers both requests the way a healthy SL V2 does.
    static func healthyHub(rpms: [Int] = [525, 0, 540, 525]) -> (([UInt8]) -> [UInt8]?) {
        return { request in
            switch request {
            case Ene6K77Profile.firmwareRequest: return firmware()
            case Ene6K77Profile.rpmRequest: return rpmWithHeader(rpms)
            default: return nil
            }
        }
    }
}

/// Lets main-queue work scheduled by the code under test (published state updates) run.
@MainActor
func drainMainQueue() async {
    try? await Task.sleep(nanoseconds: 50_000_000)
}
