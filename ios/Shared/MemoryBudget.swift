import Darwin
import Foundation
import os

/// Bounded generic ring buffer — prevents unbounded log/screenshot/trace memory growth.
public final class BoundedRingBuffer<Element>: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Element] = []
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage.reserveCapacity(min(self.capacity, 64))
    }

    public func append(_ item: Element) {
        lock.lock()
        defer { lock.unlock() }
        if storage.count >= capacity {
            storage.removeFirst(storage.count - capacity + 1)
        }
        storage.append(item)
    }

    public func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func tail(_ limit: Int) -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else { return [] }
        return Array(storage.suffix(limit))
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: false)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

/// Thread-safe lock box so mutable state remains Swift 6 Sendable cleanly on iOS 17+.
public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ initialValue: Value) {
        self.value = initialValue
    }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

/// Process memory telemetry using Mach `task_vm_info` + `os_proc_available_memory()`.
public struct MemorySnapshot: Sendable, Codable, Equatable {
    public let physFootprintMB: Double
    public let availableMB: Double
    public let pressure: Pressure

    public enum Pressure: String, Sendable, Codable {
        case nominal
        case elevated
        case critical
    }

    public static func current() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        let footprintBytes = (kr == KERN_SUCCESS) ? info.phys_footprint : 0
        let footprintMB = Double(footprintBytes) / (1024.0 * 1024.0)
        let availBytes = os_proc_available_memory()
        let availMB = Double(availBytes) / (1024.0 * 1024.0)

        let pressure: Pressure
        if availMB > 0 && availMB < 64 {
            pressure = .critical
        } else if availMB > 0 && availMB < 140 {
            pressure = .elevated
        } else {
            pressure = .nominal
        }

        return MemorySnapshot(
            physFootprintMB: (footprintMB * 10).rounded() / 10,
            availableMB: (availMB * 10).rounded() / 10,
            pressure: pressure
        )
    }
}

/// Sanitizes secrets, bearer tokens, API keys, and oversize outputs before logging or persistence.
public enum LogRedactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"(?i)(authorization:\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[REDACTED]"),
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1[REDACTED]"),
            (#"\b(sk-[A-Za-z0-9_-]{10,})\b"#, "sk-[REDACTED]"),
            (#"\b(AIza[0-9A-Za-z_-]{20,})\b"#, "AIza[REDACTED]"),
            (#"\b(gh[pousr]_[A-Za-z0-9]{16,})\b"#, "$1_REDACTED"),
            (#"(?i)("?(?:api_?key|token|secret|password|authorization)"?\s*[:=]\s*"?)[^"\s,&}{]{6,}"#, "$1[REDACTED]"),
        ]
        return specs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    public static func sanitize(_ text: String, maxChars: Int = 2000) -> String {
        var current = text
        for (regex, replacement) in patterns {
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            current = regex.stringByReplacingMatches(in: current, options: [], range: range, withTemplate: replacement)
        }
        if current.count > maxChars {
            return String(current.prefix(maxChars)) + "...[truncated]"
        }
        return current
    }
}
