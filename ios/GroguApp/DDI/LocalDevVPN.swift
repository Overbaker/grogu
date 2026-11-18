import Foundation
import Network
import UIKit

/// Probes and launches LocalDevVPN / StosVPN loopback tunnel (`10.7.0.1:49152`).
/// Adapted from OpenMinis/iCTRL (Apache-2.0).
enum LocalDevVPN {
    static let probeURL = URL(string: "localdevvpn://")!
    static let enableURL = URL(string: "localdevvpn://enable?scheme=grogu")!
    static let appStoreURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    @MainActor
    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(probeURL)
    }

    enum TunnelProbe: Equatable, Sendable {
        case reachable
        case localNetworkDenied
        case unreachable(String)
    }

    static func probeTunnel(timeout: TimeInterval = 1.5) async -> TunnelProbe {
        let host = NWEndpoint.Host(DDIMounter.tunnelAddress)
        guard let port = NWEndpoint.Port(rawValue: DDIMounter.tunnelPort) else {
            return .unreachable("Invalid port")
        }
        let conn = NWConnection(host: host, port: port, using: .tcp)
        let queue = DispatchQueue(label: "dev.grogu.ddi.tunnel.probe")
        return await withCheckedContinuation { cont in
            let done = LockedBox(false)
            func finish(_ probe: TunnelProbe) {
                let shouldResume = done.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                guard shouldResume else { return }
                conn.cancel()
                cont.resume(returning: probe)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.reachable)
                case .waiting(let err), .failed(let err):
                    if conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        finish(.localNetworkDenied)
                    } else if case .failed = state {
                        finish(.unreachable(err.localizedDescription))
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    finish(.localNetworkDenied)
                } else {
                    finish(.unreachable("No response within \(timeout)s"))
                }
            }
        }
    }
}
