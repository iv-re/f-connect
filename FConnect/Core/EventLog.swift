import Foundation
import os

/// Short in-memory history of notable events (device found, connection lost, wake, ...) for support reports.
/// Also forwards to the system log. Thread-safe; old entries fall off so it never grows.
public final class EventLog: @unchecked Sendable {
    public static let shared = EventLog()
    
    public enum Level: String { case info = "info", warning = "warn", error = "error" }
    
    private let lock = NSLock()
    private var entries: [String] = []
    private let capacity: Int
    private let now: () -> Date
    private let logger = Logger(subsystem: "software.pusk.fconnect", category: "events")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    
    public init(capacity: Int = 200, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.now = now
    }
    
    public func record(_ message: String, level: Level = .info) {
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        lock.lock()
        defer { lock.unlock() }
        entries.append("\(formatter.string(from: now())) \(level.rawValue.uppercased()) \(message)")
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
    
    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
