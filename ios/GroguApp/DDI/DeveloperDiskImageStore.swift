import Foundation
import Observation

/// Downloads and caches Apple Developer Disk Image components directly to disk via streaming
/// `URLSessionDownloadTask` so ~100MB `Image.dmg` never sits in RAM (Jetsam safe).
/// Adapted from OpenMinis/iCTRL (Apache-2.0).
@MainActor
@Observable
final class DeveloperDiskImageStore {
    static let shared = DeveloperDiskImageStore()

    enum MountMethod: String, Sendable {
        case personalized
        case cryptex

        var mirrorFolder: String {
            switch self {
            case .personalized: return "Xcode_iOS_DDI_Personalized"
            case .cryptex: return "Xcode_iOS_DDI_Cryptex"
            }
        }

        var components: [Component] {
            switch self {
            case .personalized: return [.buildManifest, .image, .trustCache]
            case .cryptex: return [.buildManifest, .image, .trustCache, .cryptexInfo, .rootHash]
            }
        }
    }

    enum Component: String, CaseIterable, Sendable {
        case buildManifest = "BuildManifest.plist"
        case image = "Image.dmg"
        case trustCache = "Image.dmg.trustcache"
        case cryptexInfo = "Image.dmg.cryptex_info"
        case rootHash = "Image.dmg.root_hash"

        var remoteURL: URL {
            URL(string: "\(DeveloperDiskImageStore.mirrorBase)/\(DeveloperDiskImageStore.mountMethod.mirrorFolder)/\(rawValue)")!
        }

        var weight: Double {
            switch self {
            case .image: return 0.90
            case .buildManifest: return 0.07
            default: return 0.01
            }
        }
    }

    nonisolated static var mountMethod: MountMethod {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4)) ? .cryptex : .personalized
    }

    private static let mirrorBase =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages"

    private(set) var isDownloading = false
    private(set) var progress: Double = 0
    private(set) var statusMessage: String?

    private init() {}

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DDI")
            .appendingPathComponent(mountMethod.mirrorFolder)
    }

    nonisolated static func url(for component: Component) -> URL {
        directory.appendingPathComponent(component.rawValue)
    }

    static var isComplete: Bool {
        mountMethod.components.allSatisfy {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        }
    }

    static var totalBytesOnDisk: Int64 {
        mountMethod.components.reduce(0) { sum, component in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: component).path)
            return sum + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    func downloadAll() async throws {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        defer {
            isDownloading = false
            statusMessage = nil
        }

        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let components = Self.mountMethod.components
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        var doneWeight = 0.0

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)

        for component in components {
            let dest = Self.url(for: component)
            let w = component.weight / totalWeight
            if FileManager.default.fileExists(atPath: dest.path) {
                doneWeight += w
                progress = doneWeight
                continue
            }

            statusMessage = "Downloading \(component.rawValue)..."
            try await streamToDisk(session: session, url: component.remoteURL, destination: dest) { frac in
                Task { @MainActor in
                    self.progress = doneWeight + frac * w
                }
            }
            doneWeight += w
            progress = doneWeight
        }
    }

    func importComponent(_ component: Component, from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let dest = Self.url(for: component)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
    }

    func removeAll() {
        try? FileManager.default.removeItem(
            at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DDI")
        )
    }

    private func streamToDisk(
        session: URLSession,
        url: URL,
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let (bytes, response) = try await session.bytes(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw DDIError.downloadFailed(destination.lastPathComponent, "HTTP \(code)")
                }
                let expected = response.expectedContentLength
                let tempURL = destination.appendingPathExtension("part")
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: tempURL)
                defer { try? handle.close() }

                var chunk = Data()
                chunk.reserveCapacity(65_536)
                var received: Int64 = 0
                var lastReport = 0.0

                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 65_536 {
                        try handle.write(contentsOf: chunk)
                        received += Int64(chunk.count)
                        chunk.removeAll(keepingCapacity: true)
                        if expected > 0 {
                            let frac = Double(received) / Double(expected)
                            if frac - lastReport >= 0.02 {
                                lastReport = frac
                                onProgress(frac)
                            }
                        }
                    }
                }
                if !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                onProgress(1.0)
                return
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        throw lastError ?? DDIError.downloadFailed(destination.lastPathComponent, "Download interrupted")
    }
}
