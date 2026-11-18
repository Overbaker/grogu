import Darwin
import Foundation
import IDevice
import Observation

enum DDIError: LocalizedError, Sendable {
    case invalidPairingFile(String)
    case missingPairingFile
    case missingImage
    case tunnelUnavailable(String)
    case tunnelDown
    case localNetworkDenied
    case ffi(String, String)
    case downloadFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidPairingFile(let why): return "Pairing file rejected: \(why)"
        case .missingPairingFile: return "No RemotePairing file imported yet."
        case .missingImage: return "Developer Disk Image files missing — download or import them first."
        case .tunnelDown: return "LocalDevVPN is disconnected. Connect LocalDevVPN and retry."
        case .localNetworkDenied: return "Local Network permission denied for Grogu. Enable it in iOS Settings."
        case .tunnelUnavailable(let why): return "Tunnel unreachable: \(why)"
        case .ffi(let op, let msg): return "\(op) failed: \(msg)"
        case .downloadFailed(let file, let why): return "Failed downloading \(file): \(why)"
        }
    }
}

/// On-device Mac-free Developer Disk Image mounter (`idevice` MIT + iCTRL Apache-2.0 sequence).
@MainActor
@Observable
final class DDIMounter {
    static let shared = DDIMounter()

    nonisolated static let tunnelAddress = "10.7.0.1"
    nonisolated static let tunnelPort: UInt16 = 49152

    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case queryingDevice
        case uploading(Double)
        case finalizing
        case mounted
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .connecting: return "Connecting tunnel..."
            case .queryingDevice: return "Inspecting DDI state..."
            case .uploading(let p): return "Mounting DDI (\(Int((p * 100).rounded()))%)"
            case .finalizing: return "Finalizing..."
            case .mounted: return "DDI Mounted"
            case .failed(let msg): return "Failed: \(msg)"
            }
        }
    }

    private(set) var phase: Phase = .idle

    var isRunning: Bool {
        switch phase {
        case .idle, .mounted, .failed: return false
        default: return true
        }
    }

    private init() {}

    func mount() async {
        guard !isRunning else { return }
        phase = .connecting
        JetsamGuard.shared.log("DDI mount started (method: \(DeveloperDiskImageStore.mountMethod.rawValue))")

        do {
            guard PairingFileStore.exists else { throw DDIError.missingPairingFile }
            guard DeveloperDiskImageStore.isComplete else { throw DDIError.missingImage }

            switch await LocalDevVPN.probeTunnel() {
            case .reachable: break
            case .localNetworkDenied: throw DDIError.localNetworkDenied
            case .unreachable: throw DDIError.tunnelDown
            }

            let pairingPath = PairingFileStore.storedURL.path
            let method = DeveloperDiskImageStore.mountMethod
            let imageDir = DeveloperDiskImageStore.directory.path

            // Dedicated 4MB stack Thread: idevice's Rust reqwest TLS client exceeds Swift Concurrency worker stacks.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let thread = Thread {
                    do {
                        try Self.performMount(pairingPath: pairingPath, method: method, imageDir: imageDir) { nextPhase in
                            Task { @MainActor in
                                self.phase = nextPhase
                            }
                        }
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                thread.stackSize = 4 * 1024 * 1024
                thread.name = "dev.grogu.ddi.mount"
                thread.qualityOfService = .userInitiated
                thread.start()
            }

            phase = .mounted
            JetsamGuard.shared.log("DDI mounted cleanly")
        } catch {
            phase = .failed(error.localizedDescription)
            JetsamGuard.shared.log("DDI mount failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FFI Execution (Background Thread)

    nonisolated private static func performMount(
        pairingPath: String,
        method: DeveloperDiskImageStore.MountMethod,
        imageDir: String,
        report: @escaping @Sendable (Phase) -> Void
    ) throws {
        primeCryptoProvider(pairingPath: pairingPath)

        var pairing: OpaquePointer?
        try check("Reading pairing file") { rp_pairing_file_read(pairingPath, &pairing) }
        defer { if let pairing { rp_pairing_file_free(pairing) } }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = tunnelPort.bigEndian
        guard tunnelAddress.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw DDIError.tunnelUnavailable("Invalid tunnel IP")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { sa in
                try check("Connecting RemotePairing tunnel") {
                    tunnel_create_rppairing(
                        sa,
                        idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                        "Grogu",
                        pairing,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
        }
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
        guard let adapter, let handshake else {
            throw DDIError.tunnelUnavailable("Tunnel created no handles")
        }

        report(.queryingDevice)

        if cryptexDDIInstalled(adapter: adapter, handshake: handshake) {
            return
        }
        if let mounted = mountedImageCount(adapter: adapter, handshake: handshake), mounted > 0 {
            return
        }

        if method == .cryptex {
            try installCryptex(adapter: adapter, handshake: handshake, imageDir: imageDir, report: report)
            return
        }

        let dirURL = URL(fileURLWithPath: imageDir)
        let image = try Data(contentsOf: dirURL.appendingPathComponent("Image.dmg"), options: .mappedIfSafe)
        let trustCache = try Data(contentsOf: dirURL.appendingPathComponent("Image.dmg.trustcache"))
        let manifest = try Data(contentsOf: dirURL.appendingPathComponent("BuildManifest.plist"))
        let ecid = try uniqueChipID(adapter: adapter, handshake: handshake)

        var client: OpaquePointer?
        try check("Opening image mounter") { image_mounter_connect_rsd(adapter, handshake, &client) }
        defer { if let client { image_mounter_free(client) } }
        guard let client else { throw DDIError.ffi("Opening image mounter", "Nil client") }

        report(.uploading(0))

        final class ProgressBox {
            let report: @Sendable (Phase) -> Void
            init(_ report: @escaping @Sendable (Phase) -> Void) { self.report = report }
        }
        let box = Unmanaged.passRetained(ProgressBox(report))
        defer { box.release() }

        try image.withUnsafeBytes { img in
            try trustCache.withUnsafeBytes { tc in
                try manifest.withUnsafeBytes { mf in
                    try check("Mounting personalized DDI") {
                        image_mounter_mount_personalized_with_callback_rsd(
                            client,
                            adapter,
                            handshake,
                            img.bindMemory(to: UInt8.self).baseAddress,
                            image.count,
                            tc.bindMemory(to: UInt8.self).baseAddress,
                            trustCache.count,
                            mf.bindMemory(to: UInt8.self).baseAddress,
                            manifest.count,
                            nil,
                            ecid,
                            { progress, total, context in
                                guard let context, total > 0 else { return }
                                let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
                                box.report(.uploading(Double(progress) / Double(total)))
                            },
                            box.toOpaque()
                        )
                    }
                }
            }
        }
        report(.finalizing)
    }

    nonisolated private static func primeCryptoProvider(pairingPath: String) {
        var pairing: OpaquePointer?
        guard idevice_pairing_file_read(pairingPath, &pairing) == nil, let pairing else { return }
        defer { idevice_pairing_file_free(pairing) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = tunnelPort.bigEndian
        guard tunnelAddress.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return }

        var device: OpaquePointer?
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { sa in
                if let err = idevice_new_tcp_socket(
                    sa,
                    idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                    "Grogu-crypto-prime",
                    &device
                ) {
                    idevice_error_free(err)
                }
            }
        }
        guard let device else { return }
        defer { idevice_free(device) }
        if let err = idevice_start_session(device, pairing, false) {
            idevice_error_free(err)
        }
    }

    nonisolated private static func cryptexDDIInstalled(adapter: OpaquePointer, handshake: OpaquePointer) -> Bool {
        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        if let err = cryptexd_installed_ddi(adapter, handshake, &installed) {
            idevice_error_free(err)
        }
        defer { if let installed { cryptexd_free_installed_cryptex(installed) } }
        return installed != nil
    }

    nonisolated private static func mountedImageCount(adapter: OpaquePointer, handshake: OpaquePointer) -> Int? {
        var client: OpaquePointer?
        if let err = image_mounter_connect_rsd(adapter, handshake, &client) {
            idevice_error_free(err)
            return nil
        }
        guard let client else { return nil }
        defer { image_mounter_free(client) }

        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        if let err = image_mounter_copy_devices(client, &devices, &count) {
            idevice_error_free(err)
            return nil
        }
        if let devices { idevice_plist_array_free(devices, UInt(count)) }
        return count
    }

    nonisolated private static func installCryptex(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        imageDir: String,
        report: @escaping @Sendable (Phase) -> Void
    ) throws {
        var assets: OpaquePointer?
        try check("Loading cryptex DDI assets") { cryptex1_assets_load(imageDir, &assets) }
        guard let assets else { throw DDIError.ffi("Loading cryptex DDI assets", "Nothing loaded") }
        defer { cryptex1_assets_free(assets) }
        report(.uploading(0))
        try check("Installing DDI cryptex") { cryptexd_install_ddi(adapter, handshake, assets, nil) }
        report(.finalizing)
    }

    nonisolated private static func uniqueChipID(adapter: OpaquePointer, handshake: OpaquePointer) throws -> UInt64 {
        var client: OpaquePointer?
        try check("Connecting lockdownd") { lockdownd_connect_rsd(adapter, handshake, &client) }
        defer { if let client { lockdownd_client_free(client) } }
        guard let client else { throw DDIError.ffi("Connecting lockdownd", "Nil client") }

        var value: plist_t?
        try check("Reading UniqueChipID") { lockdownd_get_value(client, "UniqueChipID", nil, &value) }
        defer { if let value { plist_free(value) } }
        guard let value else { throw DDIError.ffi("Reading UniqueChipID", "No value") }

        var ecid: UInt64 = 0
        plist_get_uint_val(value, &ecid)
        guard ecid != 0 else { throw DDIError.ffi("Reading UniqueChipID", "Device returned 0") }
        return ecid
    }

    @discardableResult
    nonisolated private static func check(
        _ operation: String,
        _ call: () -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> Bool {
        guard let err = call() else { return true }
        let msg = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
        let code = err.pointee.code
        idevice_error_free(err)
        throw DDIError.ffi(operation, "\(msg) (code \(code))")
    }
}
