import Foundation
import IDevice
import UniformTypeIdentifiers

/// RemotePairing file storage validated directly against `idevice` FFI.
/// Adapted from OpenMinis/iCTRL (Apache-2.0).
enum PairingFileStore {
    static let didImport = Notification.Name("GroguPairingFileDidImport")

    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [.propertyList, .xml]
        for ext in ["mobiledevicepairing", "mobiledevicepair", "plist"] {
            if let t = UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .propertyList) {
                types.append(t)
            }
        }
        types.append(.data)
        return types
    }()

    static var storedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pairing/pairingFile.plist")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: storedURL.path)
    }

    static var importedAt: Date? {
        try? FileManager.default.attributesOfItem(atPath: storedURL.path)[.modificationDate] as? Date
    }

    static func importFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        try validate(data)

        let dest = storedURL
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        NotificationCenter.default.post(name: didImport, object: nil)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: storedURL)
    }

    static func validate(_ data: Data) throws {
        if parsesAsRemotePairing(data) { return }
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw DDIError.invalidPairingFile("Not a valid property list. Expected a RemotePairing plist.")
        }
        if dict["HostID"] != nil || dict["HostCertificate"] != nil {
            throw DDIError.invalidPairingFile(
                "This is a lockdown pairing record; DDI mounting requires a RemotePairing record (e.g. StikDebug pairingFile.plist)."
            )
        }
        throw DDIError.invalidPairingFile("Missing RemotePairing keys (public_key, private_key, identifier).")
    }

    private static func parsesAsRemotePairing(_ data: Data) -> Bool {
        var handle: OpaquePointer?
        let err = data.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return rp_pairing_file_from_bytes(base, UInt(raw.count), &handle)
        }
        if let err { idevice_error_free(err) }
        if let handle { rp_pairing_file_free(handle) }
        return err == nil && handle != nil
    }
}
