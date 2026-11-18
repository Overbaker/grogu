import Foundation
import Observation
import UIKit

/// Monitors live `task_vm_info` + `os_proc_available_memory()` pressure and prunes
/// non-essential caches before iOS Jetsam terminates the process.
@MainActor
@Observable
final class JetsamGuard {
    static let shared = JetsamGuard()

    private(set) var snapshot: MemorySnapshot = .current()
    private(set) var warningCount: Int = 0
    private(set) var lastTrimReason: String = "Nominal"

    let logs = BoundedRingBuffer<String>(capacity: 250)

    private var timer: Timer?
    private var memoryWarningObserver: NSObjectProtocol?
    private var trimHandlers: [() -> Void] = []

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryWarning()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sample()
            }
        }
    }

    func registerTrimHandler(_ handler: @escaping () -> Void) {
        trimHandlers.append(handler)
    }

    func log(_ message: String) {
        let safe = LogRedactor.sanitize(message, maxChars: 600)
        logs.append("[\(Self.timeFormatter.string(from: Date()))] \(safe)")
    }

    func sample() {
        let current = MemorySnapshot.current()
        snapshot = current
        if current.pressure == .critical {
            trimCaches(reason: "Critical available RAM (\(current.availableMB) MB)")
        } else if current.pressure == .elevated {
            trimCaches(reason: "Elevated memory pressure (\(current.availableMB) MB free)")
        }
    }

    private func handleMemoryWarning() {
        warningCount += 1
        trimCaches(reason: "iOS didReceiveMemoryWarningNotification (#\(warningCount))")
    }

    func trimCaches(reason: String) {
        lastTrimReason = reason
        URLCache.shared.removeAllCachedResponses()
        for handler in trimHandlers {
            handler()
        }
        snapshot = MemorySnapshot.current()
        log("JetsamGuard trimmed caches: \(reason) -> footprint \(snapshot.physFootprintMB) MB")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
