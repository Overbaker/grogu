import Foundation
import XCTest

/// Synthesized HID input & app lifecycle engine bypassing XCTest quiescence waits.
/// Adapted from OpenMinis/iCTRL (Apache-2.0).
@MainActor
final class FastTouchEngine {
    func tap(x: Double, y: Double) throws {
        let record = XCSynthesizedEventRecord(name: "GroguTap")
        let path = XCPointerEventPath(forTouchAt: CGPoint(x: x, y: y), offset: 0.0)
        path.pressDown(atOffset: 0.0)
        path.liftUp(atOffset: 0.045)
        record.add(path)
        try record.synthesize()
    }

    func doubleTap(x: Double, y: Double) throws {
        let record = XCSynthesizedEventRecord(name: "GroguDoubleTap")
        let path = XCPointerEventPath(forTouchAt: CGPoint(x: x, y: y), offset: 0.0)
        path.pressDown(atOffset: 0.0)
        path.liftUp(atOffset: 0.045)
        path.pressDown(atOffset: 0.115)
        path.liftUp(atOffset: 0.16)
        record.add(path)
        try record.synthesize()
    }

    func longPress(x: Double, y: Double, duration: Double = 0.65) throws {
        let clamped = max(0.15, min(duration, 10.0))
        let point = CGPoint(x: x, y: y)
        let record = XCSynthesizedEventRecord(name: "GroguLongPress")
        let path = XCPointerEventPath(forTouchAt: point, offset: 0.0)
        path.pressDown(atOffset: 0.0)
        var t = 0.1
        while t < clamped {
            path.move(to: point, atOffset: t)
            t += 0.1
        }
        path.liftUp(atOffset: clamped)
        record.add(path)
        try record.synthesize()
    }

    func swipe(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        duration: Double = 0.28,
        hold: Double = 0.06
    ) throws {
        let clampedDur = max(0.05, min(duration, 5.0))
        let clampedHold = max(0.0, min(hold, 2.0))
        let start = CGPoint(x: fromX, y: fromY)
        let end = CGPoint(x: toX, y: toY)
        let record = XCSynthesizedEventRecord(name: "GroguSwipe")
        let path = XCPointerEventPath(forTouchAt: start, offset: 0.0)
        path.pressDown(atOffset: 0.0)
        path.move(to: end, atOffset: clampedDur)
        if clampedHold >= 0.08 {
            var t = clampedDur + 0.04
            var jitter = 0.3
            while t < clampedDur + clampedHold - 0.01 {
                path.move(to: CGPoint(x: end.x, y: end.y + jitter), atOffset: t)
                jitter = -jitter
                t += 0.04
            }
        }
        path.liftUp(atOffset: clampedDur + clampedHold)
        record.add(path)
        try record.synthesize()
    }

    func typeText(_ text: String, speedCharsPerSec: UInt = 60) throws {
        let record = XCSynthesizedEventRecord(name: "GroguTypeText")
        let path = XCPointerEventPath(forTextInput: ())
        path.typeText(text, atOffset: 0.0, typingSpeed: speedCharsPerSec, shouldRedact: false)
        record.add(path)
        try record.synthesize()
    }

    func pressHome() {
        XCUIDevice.shared.press(.home)
    }

    func lockScreen(timeout: TimeInterval = 3.0) throws {
        try LockStateMonitor.shared().lockScreen(withTimeout: timeout)
    }

    func unlockScreen(timeout: TimeInterval = 5.0) throws {
        try LockStateMonitor.shared().unlockScreen(withTimeout: timeout)
    }

    func launchOrActivate(bundleId: String) -> Bool {
        if ForegroundApp.activateOrLaunchBundleID(bundleId) {
            return true
        }
        return ForegroundApp.openBundleID(bundleId)
    }

    func terminate(bundleId: String) -> Bool {
        ForegroundApp.safeTerminateBundleID(bundleId)
    }

    func openURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return ForegroundApp.open(url)
    }
}
