import Foundation
import Observation

/// Bidirectional MCP Client (`2025-03-26` Streamable HTTP): connects to remote/local MCP servers,
/// handles JSON + SSE responses, cursor pagination, session IDs, and aggregates tools into AgentRuntime.
@MainActor
@Observable
final class MCPClientHub {
    static let shared = MCPClientHub()

    struct DiscoveredTool: Identifiable, Hashable, Sendable {
        var id: String { namespacedName }
        let serverID: UUID
        let serverName: String
        let serverSlug: String
        let originalName: String
        let namespacedName: String
        let description: String
        let inputSchema: JSONValue
    }

    private(set) var servers: [MCPServerConfig] = []
    private(set) var toolsByServer: [UUID: [DiscoveredTool]] = [:]
    private(set) var resourcesByServer: [UUID: [MCPResourceDescriptor]] = [:]
    private(set) var isRefreshing = false

    private var sessionIds: [UUID: String] = [:]

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private var registryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grogu/mcp_servers.json")
    }

    var allRemoteTools: [DiscoveredTool] {
        servers
            .filter(\.isEnabled)
            .flatMap { toolsByServer[$0.id] ?? [] }
    }

    private init() {
        loadRegistry()
    }

    // MARK: - Server Config CRUD

    func addServer(name: String, endpointURL: String, bearerToken: String?) {
        let trimmedURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !trimmedURL.isEmpty else { return }
        let config = MCPServerConfig(name: name, endpointURL: trimmedURL, isEnabled: true)
        servers.append(config)
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            KeychainVault.saveString(token, account: tokenAccount(for: config.id))
        }
        saveRegistry()
    }

    func removeServer(id: UUID) {
        servers.removeAll { $0.id == id }
        toolsByServer.removeValue(forKey: id)
        resourcesByServer.removeValue(forKey: id)
        sessionIds.removeValue(forKey: id)
        KeychainVault.delete(account: tokenAccount(for: id))
        saveRegistry()
    }

    func toggleServer(id: UUID, enabled: Bool) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].isEnabled = enabled
        saveRegistry()
    }

    func updateBearerToken(serverID: UUID, token: String) {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            KeychainVault.delete(account: tokenAccount(for: serverID))
        } else {
            KeychainVault.saveString(cleaned, account: tokenAccount(for: serverID))
        }
    }

    func hasToken(serverID: UUID) -> Bool {
        !(KeychainVault.loadString(account: tokenAccount(for: serverID)) ?? "").isEmpty
    }

    // MARK: - Discovery & Invocation

    func refreshAllEnabled() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for cfg in servers where cfg.isEnabled {
            await connectAndSync(serverID: cfg.id)
        }
    }

    func connectAndSync(serverID: UUID) async {
        guard let idx = servers.firstIndex(where: { $0.id == serverID }) else { return }
        let cfg = servers[idx]
        do {
            sessionIds.removeValue(forKey: serverID)
            let initParams: JSONValue = .object([
                "protocolVersion": .string(MCPProtocol.version),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Grogu-iOS"),
                    "version": .string("1.0.0"),
                ]),
            ])
            _ = try await sendRPC(config: cfg, method: "initialize", params: initParams, requestId: .int(1))
            _ = try? await sendNotification(config: cfg, method: "notifications/initialized")

            // Paginated tools/list
            var collectedTools: [DiscoveredTool] = []
            var cursor: String? = nil
            var page = 0
            repeat {
                page += 1
                let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
                let result = try await sendRPC(
                    config: cfg,
                    method: "tools/list",
                    params: params,
                    requestId: .int(10 + page)
                )
                if let rawTools = result?.objectValue?["tools"]?.arrayValue {
                    for entry in rawTools {
                        guard let obj = entry.objectValue,
                              let tName = obj["name"]?.stringValue else { continue }
                        let desc = obj["description"]?.stringValue ?? ""
                        let schema = obj["inputSchema"] ?? .object(["type": .string("object"), "properties": .object([:])])
                        let ns = "mcp__\(cfg.slug)__\(tName)"
                        collectedTools.append(DiscoveredTool(
                            serverID: cfg.id,
                            serverName: cfg.name,
                            serverSlug: cfg.slug,
                            originalName: tName,
                            namespacedName: ns,
                            description: desc,
                            inputSchema: schema
                        ))
                        if collectedTools.count >= 200 { break }
                    }
                }
                cursor = result?.objectValue?["nextCursor"]?.stringValue
            } while cursor != nil && !cursor!.isEmpty && page < 8 && collectedTools.count < 200

            toolsByServer[cfg.id] = collectedTools

            // Best-effort resources/list
            if let resOut = try? await sendRPC(config: cfg, method: "resources/list", params: nil, requestId: .int(99)),
               let rawRes = resOut.objectValue?["resources"]?.arrayValue {
                let parsed = rawRes.compactMap { item -> MCPResourceDescriptor? in
                    guard let obj = item.objectValue,
                          let uri = obj["uri"]?.stringValue,
                          let name = obj["name"]?.stringValue else { return nil }
                    return MCPResourceDescriptor(
                        uri: uri,
                        name: name,
                        description: obj["description"]?.stringValue,
                        mimeType: obj["mimeType"]?.stringValue
                    )
                }
                resourcesByServer[cfg.id] = Array(parsed.prefix(100))
            }

            servers[idx].lastConnectedAt = Date()
            servers[idx].lastToolCount = collectedTools.count
            servers[idx].lastError = nil
            saveRegistry()
            JetsamGuard.shared.log("MCP Client connected '\(cfg.name)' (\(collectedTools.count) tools)")
        } catch {
            servers[idx].lastError = error.localizedDescription
            saveRegistry()
            JetsamGuard.shared.log("MCP Client error '\(cfg.name)': \(error.localizedDescription)")
        }
    }

    func callTool(namespacedName: String, arguments: [String: JSONValue]) async -> MCPToolCallResult {
        guard let tool = allRemoteTools.first(where: { $0.namespacedName == namespacedName }),
              let cfg = servers.first(where: { $0.id == tool.serverID }) else {
            return .error("Remote MCP tool '\(namespacedName)' not found or disabled")
        }

        let params: JSONValue = .object([
            "name": .string(tool.originalName),
            "arguments": .object(arguments),
        ])

        do {
            let result = try await sendRPC(config: cfg, method: "tools/call", params: params, requestId: .string(UUID().uuidString))
            return parseToolCallResult(result)
        } catch {
            // Attempt one session refresh if server evicted session id
            await connectAndSync(serverID: cfg.id)
            do {
                let retry = try await sendRPC(config: cfg, method: "tools/call", params: params, requestId: .string(UUID().uuidString))
                return parseToolCallResult(retry)
            } catch {
                return .error("MCP tool call '\(tool.originalName)' failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Streamable HTTP Transport

    private func sendNotification(config: MCPServerConfig, method: String) async throws {
        guard let url = URL(string: config.endpointURL) else { return }
        var req = buildRequest(url: url, serverID: config.id)
        let body = MCPJSONRPCRequest(id: nil, method: method, params: nil)
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await urlSession.data(for: req)
    }

    private func sendRPC(
        config: MCPServerConfig,
        method: String,
        params: JSONValue?,
        requestId: JSONValue
    ) async throws -> JSONValue? {
        guard let url = URL(string: config.endpointURL) else {
            throw NSError(domain: "GroguMCPClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL \(config.endpointURL)"])
        }
        var req = buildRequest(url: url, serverID: config.id)
        let rpc = MCPJSONRPCRequest(id: requestId, method: method, params: params)
        req.httpBody = try JSONEncoder().encode(rpc)

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "GroguMCPClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionIds[config.id] = sid
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = LogRedactor.sanitize(String(data: data.prefix(400), encoding: .utf8) ?? "")
            throw NSError(
                domain: "GroguMCPClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet)"]
            )
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let decoded: MCPJSONRPCResponse
        if contentType.contains("text/event-stream") {
            decoded = try parseSSEJSONRPC(data: data)
        } else {
            decoded = try JSONDecoder().decode(MCPJSONRPCResponse.self, from: data)
        }
        if let err = decoded.error {
            throw NSError(
                domain: "GroguMCPClient",
                code: err.code,
                userInfo: [NSLocalizedDescriptionKey: err.message]
            )
        }
        return decoded.result
    }

    private func buildRequest(url: URL, serverID: UUID) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(MCPProtocol.version, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sid = sessionIds[serverID], !sid.isEmpty {
            req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let token = KeychainVault.loadString(account: tokenAccount(for: serverID)), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func parseSSEJSONRPC(data: Data) throws -> MCPJSONRPCResponse {
        let text = String(data: data, encoding: .utf8) ?? ""
        var candidates: [String] = []
        var buffer = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                if !buffer.isEmpty {
                    candidates.append(buffer)
                    buffer = ""
                }
            } else if line.hasPrefix("data:") {
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                buffer = buffer.isEmpty ? payload : (buffer + "\n" + payload)
            }
        }
        if !buffer.isEmpty {
            candidates.append(buffer)
        }
        for payload in candidates.reversed() {
            if let d = payload.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: d) {
                return parsed
            }
        }
        throw NSError(domain: "GroguMCPClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "No valid JSON-RPC frame in SSE stream"])
    }

    private func parseToolCallResult(_ value: JSONValue?) -> MCPToolCallResult {
        guard let obj = value?.objectValue else {
            return .text(value?.prettyJSONString() ?? "OK")
        }
        let isErr = obj["isError"]?.boolValue ?? false
        let rawBlocks = obj["content"]?.arrayValue ?? []
        let blocks: [MCPContentBlock] = rawBlocks.compactMap { item in
            guard let b = item.objectValue, let t = b["type"]?.stringValue else { return nil }
            return MCPContentBlock(
                type: t,
                text: b["text"]?.stringValue,
                data: b["data"]?.stringValue,
                mimeType: b["mimeType"]?.stringValue
            )
        }
        if blocks.isEmpty {
            return MCPToolCallResult(content: [.text(JSONValue.object(obj).prettyJSONString())], isError: isErr)
        }
        return MCPToolCallResult(content: blocks, isError: isErr)
    }

    private func tokenAccount(for id: UUID) -> String {
        "mcp-client-token-\(id.uuidString)"
    }

    private func saveRegistry() {
        let dir = registryURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(servers) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let loaded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            servers = []
            return
        }
        servers = loaded
    }
}
