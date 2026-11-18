import Foundation

/// Loopback client communicating with `GroguRunner` on `http://127.0.0.1:18831`.
actor RunnerClient {
    static let shared = RunnerClient()

    enum RunnerClientError: LocalizedError {
        case missingToken
        case invalidURL
        case unauthorized
        case unreachable(String)
        case rpcFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingToken:
                return "Runner session token missing. Tap 'Wake Runner' to launch GroguRunner and sync token."
            case .invalidURL:
                return "Invalid runner URL."
            case .unauthorized:
                return "Runner rejected loopback bearer token. Tap 'Sync Token' or 'Wake Runner'."
            case .unreachable(let msg):
                return "GroguRunner unreachable on 127.0.0.1:18831 (\(msg)). Ensure DDI is mounted and Runner is active."
            case .rpcFailed(let msg):
                return "Runner RPC failed: \(msg)"
            }
        }
    }

    private let baseURL = URL(string: "http://127.0.0.1:18831")!
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    func health() async throws -> [String: JSONValue] {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.httpMethod = "GET"
        req.timeoutInterval = 2.0
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw RunnerClientError.unreachable("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
        } catch let e as RunnerClientError {
            throw e
        } catch {
            throw RunnerClientError.unreachable(error.localizedDescription)
        }
    }

    @discardableResult
    func call(_ method: String, params: [String: JSONValue] = [:], timeout: TimeInterval = 18) async throws -> [String: JSONValue] {
        guard let token = await MainActor.run(body: { RunnerLauncher.shared.sessionToken }), !token.isEmpty else {
            throw RunnerClientError.missingToken
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("rpc"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let payload = JSONValue.object([
            "method": .string(method),
            "params": .object(params),
        ])
        req.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw RunnerClientError.unreachable(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw RunnerClientError.unreachable("No HTTP response")
        }
        if http.statusCode == 401 {
            throw RunnerClientError.unauthorized
        }

        struct RPCResponse: Decodable {
            let ok: Bool
            let result: [String: JSONValue]?
            let error: String?
        }

        guard let decoded = try? JSONDecoder().decode(RPCResponse.self, from: data) else {
            throw RunnerClientError.rpcFailed("HTTP \(http.statusCode)")
        }
        if !decoded.ok {
            throw RunnerClientError.rpcFailed(decoded.error ?? "HTTP \(http.statusCode)")
        }
        return decoded.result ?? [:]
    }
}
