import CoreGraphics
import Foundation
import UIKit
import Vision
import XCTest

/// Bounded screen capture, viewport-culled AX snapshot extraction, OCR fallback, and settle detection.
/// Adapted from OpenMinis/iCTRL (Apache-2.0) with strict autoreleasepool memory discipline.
@MainActor
final class BoundedScreenObserver {
    private var jpegCaptureSupported: Bool?
    private var daemonCaptureSupported: Bool?
    private var daemonFailures = 0

    struct ScreenshotPayload {
        let jpegData: Data
        let widthPoints: Int
        let heightPoints: Int
        let capturePath: String
    }

    func captureJPEG(quality: Double = 0.45, maxLongEdge: CGFloat = 1120) -> ScreenshotPayload? {
        autoreleasepool {
            let bounds = XCUIScreen.main.screenshot().image.size
            let widthPts = Int(bounds.width.rounded())
            let heightPts = Int(bounds.height.rounded())

            if let fast = captureFastJPEG(quality: quality) {
                if let resized = downscaleIfNeeded(jpegData: fast.data, maxLongEdge: maxLongEdge, quality: quality) {
                    return ScreenshotPayload(
                        jpegData: resized,
                        widthPoints: widthPts > 0 ? widthPts : Int(fast.image.size.width),
                        heightPoints: heightPts > 0 ? heightPts : Int(fast.image.size.height),
                        capturePath: fast.path
                    )
                }
                return ScreenshotPayload(
                    jpegData: fast.data,
                    widthPoints: Int(fast.image.size.width),
                    heightPoints: Int(fast.image.size.height),
                    capturePath: fast.path
                )
            }

            let image = XCUIScreen.main.screenshot().image
            let scaled = resizeImage(image, maxLongEdge: maxLongEdge)
            guard let jpeg = scaled.jpegData(compressionQuality: CGFloat(quality)) else {
                return nil
            }
            return ScreenshotPayload(
                jpegData: jpeg,
                widthPoints: Int(image.size.width),
                heightPoints: Int(image.size.height),
                capturePath: "xcuiscreen_fallback"
            )
        }
    }

    func captureScreenTextTree(
        bundleId: String? = nil,
        maxDepth: Int = 20,
        maxChildren: Int = 24,
        maxElements: Int = 280
    ) -> [String: JSONValue] {
        autoreleasepool {
            let targetBundle = (bundleId?.isEmpty == false)
                ? bundleId!
                : (ForegroundApp.currentBundleID() ?? "com.apple.springboard")
            let screenBounds = CGRect(
                origin: .zero,
                size: UIScreen.main.bounds.size
            )

            if let parts = ForegroundApp.visibleListParts(
                targetBundle,
                screen: screenBounds,
                maxElements: maxElements
            ) as? [String: Any] {
                let rootBody = parts["root_body"] as? String ?? ""
                let cellBodies = parts["cell_bodies"] as? [String] ?? []
                let combined = ([rootBody] + cellBodies).filter { !$0.isEmpty }.joined(separator: "\n")
                if !combined.isEmpty {
                    return [
                        "bundle_id": .string(targetBundle),
                        "mode": .string("visible_list"),
                        "tree": .string(combined),
                        "chars": .int(combined.count),
                    ]
                }
            }

            if let root = ForegroundApp.boundedSnapshot(
                forBundleID: targetBundle,
                maxDepth: maxDepth,
                maxChildren: maxChildren
            ) {
                var count = 0
                var truncated = ObjCBool(false)
                let rendered = ForegroundApp.renderBoundedSnapshot(
                    root,
                    maxDepth: maxDepth,
                    maxElements: maxElements,
                    visibleRect: screenBounds,
                    nodesWritten: &count,
                    truncated: &truncated
                ) ?? ""
                return [
                    "bundle_id": .string(targetBundle),
                    "mode": .string("bounded_viewport"),
                    "elements": .int(count),
                    "truncated": .bool(truncated.boolValue),
                    "tree": .string(rendered),
                ]
            }

            return [
                "bundle_id": .string(targetBundle),
                "mode": .string("unavailable"),
                "tree": .string(""),
            ]
        }
    }

    func findElement(
        query: String,
        bundleId: String? = nil,
        contains: Bool = true,
        maxDepth: Int = 24
    ) -> [String: JSONValue] {
        autoreleasepool {
            let targetBundle = (bundleId?.isEmpty == false)
                ? bundleId!
                : (ForegroundApp.currentBundleID() ?? "com.apple.springboard")
            let viewport = CGRect(origin: .zero, size: UIScreen.main.bounds.size)
            guard let root = ForegroundApp.boundedSnapshot(
                forBundleID: targetBundle,
                maxDepth: maxDepth,
                maxChildren: 32
            ),
            let located = ForegroundApp.locate(
                inBoundedSnapshot: root,
                query: query,
                contains: contains,
                types: nil,
                viewport: viewport,
                maxDepth: maxDepth
            ) as? [String: Any] else {
                return [
                    "bundle_id": .string(targetBundle),
                    "candidates": .array([]),
                    "visited": .int(0),
                ]
            }
            return [
                "bundle_id": .string(targetBundle),
                "visited": .int(located["visited"] as? Int ?? 0),
                "fingerprint": .string(located["fingerprint"] as? String ?? ""),
                "candidates": JSONValue.from(located["candidates"] ?? []),
            ]
        }
    }

    func recognizeTextOCR(minConfidence: Float = 0.3) -> [String: JSONValue] {
        autoreleasepool {
            let shot = XCUIScreen.main.screenshot().image
            guard let cgImage = shot.cgImage else {
                return ["items": .array([]), "error": .string("Missing CGImage")]
            }
            let screenSize = shot.size
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ["items": .array([]), "error": .string(error.localizedDescription)]
            }

            let observations = request.results ?? []
            var items: [JSONValue] = []
            items.reserveCapacity(min(observations.count, 120))
            for obs in observations {
                guard obs.confidence >= minConfidence,
                      let candidate = obs.topCandidates(1).first else { continue }
                let box = obs.boundingBox
                let x = box.origin.x * screenSize.width
                let y = (1.0 - box.origin.y - box.size.height) * screenSize.height
                let w = box.size.width * screenSize.width
                let h = box.size.height * screenSize.height
                let cx = (x + w * 0.5).rounded()
                let cy = (y + h * 0.5).rounded()
                items.append(.object([
                    "text": .string(candidate.string),
                    "confidence": .double(Double((obs.confidence * 100).rounded() / 100)),
                    "x": .int(Int(x.rounded())),
                    "y": .int(Int(y.rounded())),
                    "w": .int(Int(w.rounded())),
                    "h": .int(Int(h.rounded())),
                    "cx": .int(Int(cx)),
                    "cy": .int(Int(cy)),
                ]))
                if items.count >= 120 { break }
            }
            return [
                "width": .int(Int(screenSize.width)),
                "height": .int(Int(screenSize.height)),
                "items": .array(items),
            ]
        }
    }

    func waitForScreenStable(timeout: TimeInterval = 2.0) -> [String: JSONValue] {
        let start = CFAbsoluteTimeGetCurrent()
        var prev = downsampledGrid(from: XCUIScreen.main.screenshot().image)
        var samples = 1
        var stableStreak = 0
        var lastDiff = 1.0

        while CFAbsoluteTimeGetCurrent() - start < timeout {
            Thread.sleep(forTimeInterval: 0.14)
            let next = autoreleasepool { downsampledGrid(from: XCUIScreen.main.screenshot().image) }
            samples += 1
            if let a = prev, let b = next {
                let diff = diffFraction(a, b)
                lastDiff = diff
                if diff < 0.015 {
                    stableStreak += 1
                    if stableStreak >= 2 {
                        return [
                            "stable": .bool(true),
                            "samples": .int(samples),
                            "waited_ms": .int(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)),
                            "last_diff": .double((diff * 1000).rounded() / 1000),
                        ]
                    }
                } else {
                    stableStreak = 0
                }
            }
            prev = next
        }
        return [
            "stable": .bool(false),
            "samples": .int(samples),
            "waited_ms": .int(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)),
            "last_diff": .double((lastDiff * 1000).rounded() / 1000),
        ]
    }

    // MARK: - Private helpers

    private func captureFastJPEG(quality: Double) -> (image: UIImage, data: Data, path: String)? {
        if jpegCaptureSupported == false { return nil }
        let tryDaemon = (daemonCaptureSupported != false)
        let mainScreen = XCUIScreen.main
        var out: (UIImage, Data, String)?
        var daemonSucceeded: Bool?

        let exception = ObjCException.catching {
            guard let encodingClass = NSClassFromString("XCTImageEncoding") as? NSObject.Type else { return }
            var diag: NSString?
            guard let encoding = ObjCException.makeImageEncoding(
                encodingClass,
                uti: "public.jpeg",
                quality: quality,
                diagnosis: &diag
            ) else { return }

            if tryDaemon {
                var why: NSString?
                if let data = ObjCException.daemonScreenshot(withEncoding: encoding, timeout: 1.5, why: &why),
                   let img = UIImage(data: data),
                   img.cgImage != nil {
                    daemonSucceeded = true
                    out = (img, data, "daemon_direct")
                    return
                }
                daemonSucceeded = false
            }

            if let raw = ObjCException.screenshot(of: mainScreen, encoding: encoding) {
                let xctImageAny: AnyObject?
                if let shot = raw as? XCUIScreenshot, shot.responds(to: Selector(("internalImage"))) {
                    xctImageAny = shot.internalImage()
                } else {
                    xctImageAny = raw as AnyObject
                }
                if let xctImg = xctImageAny,
                   xctImg.responds(to: Selector(("data"))),
                   let data = xctImg.perform(Selector(("data")))?.takeUnretainedValue() as? Data,
                   let img = UIImage(data: data),
                   img.cgImage != nil {
                    out = (img, data, "xcuiscreen_encoded")
                }
            }
        }
        if let daemonSucceeded {
            if daemonSucceeded {
                daemonCaptureSupported = true
                daemonFailures = 0
            } else {
                daemonFailures += 1
                if daemonCaptureSupported == nil || daemonFailures >= 3 {
                    daemonCaptureSupported = false
                }
            }
        }
        if let out {
            jpegCaptureSupported = true
            return out
        }
        if exception != nil || jpegCaptureSupported == nil {
            jpegCaptureSupported = false
        }
        return nil
    }

    private func downscaleIfNeeded(jpegData: Data, maxLongEdge: CGFloat, quality: Double) -> Data? {
        guard let img = UIImage(data: jpegData) else { return nil }
        let longEdge = max(img.size.width, img.size.height)
        guard longEdge > maxLongEdge else { return jpegData }
        let resized = resizeImage(img, maxLongEdge: maxLongEdge)
        return resized.jpegData(compressionQuality: CGFloat(quality))
    }

    private func resizeImage(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return image }
        let scale = maxLongEdge / longEdge
        let target = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func downsampledGrid(from image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let w = 32, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    private func diffFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let count = min(a.count, b.count) / 4
        guard count > 0 else { return 1.0 }
        var diff = 0
        for i in 0..<count {
            let o = i * 4
            if abs(Int(a[o]) - Int(b[o])) > 14
                || abs(Int(a[o + 1]) - Int(b[o + 1])) > 14
                || abs(Int(a[o + 2]) - Int(b[o + 2])) > 14 {
                diff += 1
            }
        }
        return Double(diff) / Double(count)
    }
}
