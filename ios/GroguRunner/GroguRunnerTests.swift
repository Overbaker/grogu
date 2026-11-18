import Foundation
import UIKit
import XCTest

@MainActor
final class GroguRunnerTests: XCTestCase {
    private var server: RunnerServer?
    private var touchEngine: FastTouchEngine?
    private var observer: BoundedScreenObserver?
    private var keepRunning = true
    private var urlObserver: NSObjectProtocol?

    override func setUpWithError() throws {
        EarlyURLHook.markSetUpEntered()
        continueAfterFailure = true

        if responds(to: Selector(("setShouldSetShouldHaltWhenReceivesControl:"))) {
            setValue(false, forKey: "shouldSetShouldHaltWhenReceivesControl")
        }
        if responds(to: Selector(("setShouldHaltWhenReceivesControl:"))) {
            setValue(false, forKey: "shouldHaltWhenReceivesControl")
        }

        // Hold lazy reference only; never activate() during setUp (avoids passcode/lock hangs).
        _ = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    func testStartServer() throws {
        EarlyURLHook.markTestStarted()
        QuiescenceDisabler.applyInteractionStateTimeout()
        _ = ForegroundApp.setAXTimeout(5.0)

        let engine = FastTouchEngine()
        let screenObserver = BoundedScreenObserver()
        self.touchEngine = engine
        self.observer = screenObserver

        let runnerServer = RunnerServer(
            port: 18831,
            rpcHandler: { [weak self] method, params in
                await MainActor.run {
                    guard let self else {
                        return .failure(.init(status: 500, code: "teardown", message: "Runner shutting down"))
                    }
                    return self.dispatchRPC(method: method, params: params)
                }
            },
            healthProvider: { [weak self] in
                await MainActor.run {
                    let mem = MemorySnapshot.current()
                    return [
                        "ok": .bool(true),
                        "service": .string("GroguRunner"),
                        "port": .int(18831),
                        "locked": .bool(LockStateMonitor.shared().isLocked),
                        "foreground_bundle": .string(ForegroundApp.currentBundleID() ?? ""),
                        "phys_footprint_mb": .double(mem.physFootprintMB),
                        "available_mb": .double(mem.availableMB),
                        "pressure": .string(mem.pressure.rawValue),
                        "uptime_s": .int(Int(ProcessInfo.processInfo.systemUptime)),
                        "running": .bool(self?.server?.isRunning ?? false),
                    ]
                }
            }
        )
        self.server = runnerServer
        try runnerServer.start()

        urlObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("GroguRunnerReceivedURL"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.drainIncomingURLs()
            }
        }
        drainIncomingURLs()

        while keepRunning {
            autoreleasepool {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
            }
        }
        if let urlObserver {
            NotificationCenter.default.removeObserver(urlObserver)
        }
        runnerServer.stop()
    }

    // MARK: - Incoming URL Wake Handling

    private func drainIncomingURLs() {
        for url in EarlyURLHook.drainURLs() {
            handleRunnerURL(url)
        }
    }

    private func handleRunnerURL(_ url: URL) {
        let host = (url.host ?? "").lowercased()
        if host == "stop" {
            keepRunning = false
            return
        }
        guard host == "start" || host == "token" || host.isEmpty else { return }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let callbackRaw = comps?.queryItems?.first(where: { $0.name == "callback" })?.value ?? "grogu://runner-ready"
        guard let cbURL = URL(string: callbackRaw),
              cbURL.scheme?.lowercased() == "grogu" else {
            return
        }

        let deadline = Date().addingTimeInterval(5.0)
        while !(server?.isRunning ?? false) && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        var out = URLComponents(url: cbURL, resolvingAgainstBaseURL: false)
        var query = out?.queryItems ?? []
        query.append(URLQueryItem(name: "port", value: "18831"))
        if let token = server?.sessionToken {
            query.append(URLQueryItem(name: "token", value: token))
        }
        query.append(URLQueryItem(name: "status", value: (server?.isRunning ?? false) ? "ready" : "failed"))
        out?.queryItems = query
        if let finalURL = out?.url {
            _ = ForegroundApp.open(finalURL)
        }
    }

    // MARK: - Loopback RPC Dispatcher

    private func dispatchRPC(
        method: String,
        params: [String: JSONValue]
    ) -> Result<[String: JSONValue], RunnerServer.RunnerRPCError> {
        guard let engine = touchEngine, let screen = observer else {
            return .failure(.init(status: 500, code: "uninitialized", message: "Runner engine not ready"))
        }

        do {
            switch method {
            case "tap":
                guard let x = params.double("x"), let y = params.double("y") else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "tap requires x, y"))
                }
                try engine.tap(x: x, y: y)
                return .success(["action": .string("tap"), "x": .double(x), "y": .double(y)])

            case "double_tap":
                guard let x = params.double("x"), let y = params.double("y") else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "double_tap requires x, y"))
                }
                try engine.doubleTap(x: x, y: y)
                return .success(["action": .string("double_tap"), "x": .double(x), "y": .double(y)])

            case "long_press":
                guard let x = params.double("x"), let y = params.double("y") else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "long_press requires x, y"))
                }
                let duration = params.double("duration") ?? 0.65
                try engine.longPress(x: x, y: y, duration: duration)
                return .success(["action": .string("long_press"), "duration": .double(duration)])

            case "swipe":
                guard let fx = params.double("from_x"),
                      let fy = params.double("from_y"),
                      let tx = params.double("to_x"),
                      let ty = params.double("to_y") else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "swipe requires from_x, from_y, to_x, to_y"))
                }
                let duration = params.double("duration") ?? 0.28
                let hold = params.double("hold") ?? 0.06
                try engine.swipe(fromX: fx, fromY: fy, toX: tx, toY: ty, duration: duration, hold: hold)
                return .success(["action": .string("swipe")])

            case "type_text":
                guard let text = params.string("text") else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "type_text requires text"))
                }
                let speed = UInt(max(10, min(params.int("speed") ?? 60, 200)))
                try engine.typeText(text, speedCharsPerSec: speed)
                return .success(["action": .string("type_text"), "chars": .int(text.count)])

            case "press_home":
                engine.pressHome()
                return .success(["action": .string("press_home")])

            case "lock_screen":
                try engine.lockScreen(timeout: params.double("timeout") ?? 3.0)
                return .success(["action": .string("lock_screen"), "locked": .bool(true)])

            case "unlock_screen":
                try engine.unlockScreen(timeout: params.double("timeout") ?? 5.0)
                return .success(["action": .string("unlock_screen"), "locked": .bool(LockStateMonitor.shared().isLocked)])

            case "launch_app":
                guard let bundleId = params.string("bundle_id"), !bundleId.isEmpty else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "launch_app requires bundle_id"))
                }
                let ok = engine.launchOrActivate(bundleId: bundleId)
                return .success(["bundle_id": .string(bundleId), "launched": .bool(ok)])

            case "terminate_app":
                guard let bundleId = params.string("bundle_id"), !bundleId.isEmpty else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "terminate_app requires bundle_id"))
                }
                let ok = engine.terminate(bundleId: bundleId)
                return .success(["bundle_id": .string(bundleId), "terminated": .bool(ok)])

            case "open_url":
                guard let urlStr = params.string("url"), !urlStr.isEmpty else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "open_url requires url"))
                }
                let ok = engine.openURL(urlStr)
                return .success(["url": .string(urlStr), "opened": .bool(ok)])

            case "foreground_app":
                return .success([
                    "bundle_id": .string(ForegroundApp.currentBundleID() ?? ""),
                    "pid": .int(Int(ForegroundApp.frontmostPID())),
                    "has_system_alert": .bool(ForegroundApp.hasSystemAlert()),
                ])

            case "screenshot":
                let quality = min(max(params.double("quality") ?? 0.45, 0.1), 0.95)
                let maxLongEdge = CGFloat(min(max(params.int("max_long_edge") ?? 1120, 480), 2200))
                let includeBase64 = params.bool("include_base64") ?? true
                guard let payload = screen.captureJPEG(quality: quality, maxLongEdge: maxLongEdge) else {
                    return .failure(.init(status: 500, code: "capture_failed", message: "Failed to capture screenshot"))
                }
                var out: [String: JSONValue] = [
                    "width": .int(payload.widthPoints),
                    "height": .int(payload.heightPoints),
                    "bytes": .int(payload.jpegData.count),
                    "capture_path": .string(payload.capturePath),
                ]
                if includeBase64 {
                    out["jpeg_base64"] = .string(payload.jpegData.base64EncodedString())
                }
                return .success(out)

            case "ui_tree":
                return .success(screen.captureScreenTextTree(
                    bundleId: params.string("bundle_id"),
                    maxDepth: min(max(params.int("max_depth") ?? 20, 4), 40),
                    maxChildren: min(max(params.int("max_children") ?? 24, 4), 80),
                    maxElements: min(max(params.int("max_elements") ?? 260, 20), 600)
                ))

            case "find_element":
                guard let query = params.string("query"), !query.isEmpty else {
                    return .failure(.init(status: 400, code: "invalid_params", message: "find_element requires query"))
                }
                return .success(screen.findElement(
                    query: query,
                    bundleId: params.string("bundle_id"),
                    contains: params.bool("contains") ?? true,
                    maxDepth: min(max(params.int("max_depth") ?? 24, 4), 40)
                ))

            case "ocr":
                let minConf = Float(params.double("min_confidence") ?? 0.3)
                return .success(screen.recognizeTextOCR(minConfidence: minConf))

            case "wait_stable":
                let timeout = min(max(params.double("timeout") ?? 2.0, 0.3), 8.0)
                return .success(screen.waitForScreenStable(timeout: timeout))

            case "device_status":
                let mem = MemorySnapshot.current()
                return .success([
                    "locked": .bool(LockStateMonitor.shared().isLocked),
                    "foreground_bundle": .string(ForegroundApp.currentBundleID() ?? ""),
                    "has_system_alert": .bool(ForegroundApp.hasSystemAlert()),
                    "phys_footprint_mb": .double(mem.physFootprintMB),
                    "available_mb": .double(mem.availableMB),
                    "pressure": .string(mem.pressure.rawValue),
                ])

            case "shutdown":
                keepRunning = false
                return .success(["stopping": .bool(true)])

            default:
                return .failure(.init(status: 404, code: "unknown_method", message: "Unknown RPC method: \(method)"))
            }
        } catch {
            return .failure(.init(status: 500, code: "action_error", message: error.localizedDescription))
        }
    }
}
