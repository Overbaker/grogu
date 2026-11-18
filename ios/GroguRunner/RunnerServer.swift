import Foundation
import Network
import Security

/// Strict loopback HTTP automation server for GroguRunner (`127.0.0.1:18831`).
/// Only local processes (`GroguApp`) can reach loopback, and every `/rpc` call requires
/// the per-session bearer token issued on wake-up callback (`grogu://runner-ready`).
final class RunnerServer: @unchecked Sendable {
    typealias RPCHandler = @Sendable (String, [String: JSONValue]) async -> Result<[String: JSONValue], RunnerRPCError>
    typealias HealthProvider = @Sendable () async -> [String: JSONValue]

    struct RunnerRPCError: Error, Sendable {
        let status: Int
        let code: String
        let message: String
    }

    let port: UInt16
    let sessionToken: String

    private let queue = DispatchQueue(label: "dev.grogu.runner.http", qos: .userInitiated)
    private let maxBodyBytes = 1_048_576
    private var listener: NWListener?
    private let stateLock = NSLock()
    private var _isRunning = false

    private let rpcHandler: RPCHandler
    private let healthProvider: HealthProvider

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    init(
        port: UInt16 = 18831,
        rpcHandler: @escaping RPCHandler,
        healthProvider: @escaping HealthProvider
    ) {
        self.port = port
        self.sessionToken = Self.generateTokenHex(byteCount: 32)
        self.rpcHandler = rpcHandler
        self.healthProvider = healthProvider
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "GroguRunnerServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.stateLock.lock()
            switch state {
            case .ready:
                self._isRunning = true
            case .failed, .cancelled:
                self._isRunning = false
            default:
                break
            }
            self.stateLock.unlock()
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stateLock.lock()
        _isRunning = false
        stateLock.unlock()
    }

    // MARK: - HTTP Connection Lifecycle

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTP(on: connection, buffer: Data())
    }

    private func receiveHTTP(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }
            if accumulated.count > self.maxBodyBytes + 32_768 {
                self.sendJSON(
                    status: 413,
                    payload: .object(["ok": .bool(false), "error": .string("Payload too large")]),
                    on: connection
                )
                return
            }

            if let parsed = Self.tryParseHTTPRequest(from: accumulated) {
                self.dispatchHTTP(parsed, on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveHTTP(on: connection, buffer: accumulated)
        }
    }

    private func dispatchHTTP(_ request: ParsedHTTPRequest, on connection: NWConnection) {
        if request.method == "GET" && request.path == "/health" {
            Task { [weak self] in
                guard let self else { return }
                let health = await self.healthProvider()
                self.sendJSON(status: 200, payload: .object(health), on: connection)
            }
            return
        }

        guard request.method == "POST" && request.path == "/rpc" else {
            sendJSON(
                status: 404,
                payload: .object(["ok": .bool(false), "error": .string("Not found")]),
                on: connection
            )
            return
        }

        guard Self.isAuthorized(headers: request.headers, expectedToken: sessionToken) else {
            sendJSON(
                status: 401,
                payload: .object(["ok": .bool(false), "error": .string("Unauthorized")]),
                on: connection
            )
            return
        }

        struct RPCEnvelope: Decodable {
            let method: String
            let params: [String: JSONValue]?
        }

        guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: request.body) else {
            sendJSON(
                status: 400,
                payload: .object(["ok": .bool(false), "error": .string("Invalid JSON-RPC payload")]),
                on: connection
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await self.rpcHandler(envelope.method, envelope.params ?? [:])
            switch result {
            case .success(let value):
                self.sendJSON(
                    status: 200,
                    payload: .object(["ok": .bool(true), "result": .object(value)]),
                    on: connection
                )
            case .failure(let err):
                self.sendJSON(
                    status: err.status,
                    payload: .object([
                        "ok": .bool(false),
                        "code": .string(err.code),
                        "error": .string(err.message),
                    ]),
                    on: connection
                )
            }
        }
    }

    private func sendJSON(status: Int, payload: JSONValue, on connection: NWConnection) {
        let bodyData = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 500: reason = "Internal Server Error"
        default: reason = "Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Helpers

    private struct ParsedHTTPRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func tryParseHTTPRequest(from data: Data) -> ParsedHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter) else { return nil }
        guard let headString = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        let available = data.count - bodyStart
        guard available >= contentLength else { return nil }
        let body = data[bodyStart..<(bodyStart + contentLength)]
        return ParsedHTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }

    private static func isAuthorized(headers: [String: String], expectedToken: String) -> Bool {
        guard let auth = headers["authorization"] else { return false }
        let prefix = "Bearer "
        guard auth.count > prefix.count,
              auth.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else {
            return false
        }
        let supplied = String(auth.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return constantTimeEqual(supplied, expectedToken)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    private static func generateTokenHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
