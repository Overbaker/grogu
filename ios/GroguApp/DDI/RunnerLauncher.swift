import Foundation
import Observation
import UIKit

/// Coordinates waking `GroguRunner` via `grogu-runner://start?callback=grogu://runner-ready`
/// and captures its ephemeral loopback session token via `grogu://runner-ready?port=18831&token=...`.
@MainActor
@Observable
final class RunnerLauncher {
    static let shared = RunnerLauncher()

    private static let tokenAccount = "runner-loopback-token"

    enum RunnerState: Equatable, Sendable {
        case unknown
        case stopped
        case starting
        case ready
    }

    private(set) var state: RunnerState = .unknown
    private(set) var lastHealthJSON: [String: JSONValue] = [:]
    private(set) var sessionToken: String?

    private init() {
        sessionToken = KeychainVault.loadString(account: Self.tokenAccount)
    }

    func launchRunner() {
        guard let url = URL(string: "grogu-runner://start?callback=grogu://runner-ready") else { return }
        state = .starting
        UIApplication.shared.open(url)
        JetsamGuard.shared.log("Requested GroguRunner wake via grogu-runner://start")
    }

    func markStopped() {
        state = .stopped
    }

    func syncTokenOnly() {
        guard let url = URL(string: "grogu-runner://token?callback=grogu://runner-ready") else { return }
        UIApplication.shared.open(url)
        JetsamGuard.shared.log("Requested GroguRunner session token sync")
    }

    func stopRunner() {
        guard let url = URL(string: "grogu-runner://stop") else { return }
        UIApplication.shared.open(url)
        state = .stopped
    }

    func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "grogu",
              url.host?.lowercased() == "runner-ready" else {
            return false
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        if let tok = items.first(where: { $0.name == "token" })?.value, !tok.isEmpty {
            sessionToken = tok
            KeychainVault.saveString(tok, account: Self.tokenAccount)
            JetsamGuard.shared.log("Captured GroguRunner loopback bearer token")
        }
        Task {
            await refreshHealth()
        }
        return true
    }

    @discardableResult
    func refreshHealth() async -> Bool {
        do {
            let health = try await RunnerClient.shared.health()
            lastHealthJSON = health
            state = .ready
            return true
        } catch {
            if state != .starting {
                state = .stopped
            }
            return false
        }
    }
}
