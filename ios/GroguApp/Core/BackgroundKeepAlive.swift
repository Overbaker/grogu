import AVFoundation
import Foundation
import UIKit

/// Keeps GroguApp alive ONLY while an active multi-step agent loop or MCP job is running,
/// releasing audio/background assertions immediately once idle so standby drain stays zero.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private(set) var isActive = false
    private var player: AVAudioPlayer?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func acquire(reason: String) {
        if bgTaskId == .invalid {
            bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "GroguAgentTask") { [weak self] in
                Task { @MainActor in
                    self?.endBackgroundTaskOnly()
                }
            }
        }
        guard !isActive else { return }
        isActive = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let wavData = Self.makeSilentWAVData(durationSeconds: 1.0, sampleRate: 8000)
            let audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer.numberOfLoops = -1
            audioPlayer.volume = 0.0
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            self.player = audioPlayer
            JetsamGuard.shared.log("Background keep-alive acquired (\(reason))")
        } catch {
            JetsamGuard.shared.log("Background keep-alive degraded to BGTask only: \(error.localizedDescription)")
        }
    }

    func release() {
        isActive = false
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBackgroundTaskOnly()
        JetsamGuard.shared.log("Background keep-alive released")
    }

    private func endBackgroundTaskOnly() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }

    /// Generates a tiny 1-second 8kHz mono 16-bit PCM silent WAV purely in memory (~16 KB).
    private static func makeSilentWAVData(durationSeconds: Double, sampleRate: UInt32) -> Data {
        let numSamples = UInt32(Double(sampleRate) * durationSeconds)
        let dataSize = numSamples * 2
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(Int(fileSize + 8))

        func appendASCII(_ str: String) { data.append(contentsOf: str.utf8) }
        func appendLE32(_ val: UInt32) {
            var le = val.littleEndian
            data.append(Data(bytes: &le, count: 4))
        }
        func appendLE16(_ val: UInt16) {
            var le = val.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }

        appendASCII("RIFF")
        appendLE32(fileSize)
        appendASCII("WAVEfmt ")
        appendLE32(16)
        appendLE16(1) // PCM
        appendLE16(1) // Mono
        appendLE32(sampleRate)
        appendLE32(sampleRate * 2)
        appendLE16(2)
        appendLE16(16)
        appendASCII("data")
        appendLE32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
