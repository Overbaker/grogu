import Foundation
import Network
import Observation
import Security

/// On-device MCP Streamable HTTP (`2025-03-26`) Server powered by Apple's `Network.framework` (`NWListener`).
/// Exposes Native OS Tools, `GroguRunner` GUI automation, `WorkspaceStore`, and `grogu_agent_run` to external clients.
@MainActor
@Observable
final class MCPServerService {
    static let shared = MCPServerService()

    private static let tokenAccount = "mcp-server-inbound-token"
    private static let portDefaultsKey = "grogu.mcpServer.port"
    private static let remoteDefaultsKey = "grogu.mcpServer.allowRemote"

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var requestCount = 0
    private(set) var activeSessionIds: Set<String> = []
    private(set) var bearerToken: String
    private(set) var userStopped = false

    var hasListener: Bool { listener != nil }

    var port: UInt16 {
        didSet { UserDefaults.standard.set(Int(port), forKey: Self.portDefaultsKey) }
    }
    var allowRemoteAccess: Bool {
        didSet { UserDefaults.standard.set(allowRemoteAccess, forKey: Self.remoteDefaultsKey) }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.grogu.mcp.server", qos: .userInitiated)
    private let maxBodyBytes = 1_048_576

    private init() {
        let savedPort = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        self.port = (savedPort > 0 && savedPort <= 65535) ? UInt16(savedPort) : 18832
        self.allowRemoteAccess = UserDefaults.standard.bool(forKey: Self.remoteDefaultsKey)

        if let existing = KeychainVault.loadString(account: Self.tokenAccount), !existing.isEmpty {
            self.bearerToken = existing
        } else {
            let fresh = Self.generateTokenHex(byteCount: 24)
            KeychainVault.saveString(fresh, account: Self.tokenAccount)
            self.bearerToken = fresh
        }
    }

    func rotateBearerToken() {
        let fresh = Self.generateTokenHex(byteCount: 24)
        KeychainVault.saveString(fresh, account: Self.tokenAccount)
        bearerToken = fresh
        activeSessionIds.removeAll()
        JetsamGuard.shared.log("Rotated inbound MCP Server bearer token")
    }

    func start() {
        guard listener == nil else { return }
        userStopped = false
        lastError = nil
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw NSError(domain: "GroguMCPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
            }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener: NWListener
            if !allowRemoteAccess {
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
                newListener = try NWListener(using: params)
            } else {
                newListener = try NWListener(using: params, on: nwPort)
            }

            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                Task { @MainActor in
                    guard let self, let newListener, self.listener === newListener else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.lastError = nil
                        let scope = self.allowRemoteAccess ? "0.0.0.0:\(self.port)" : "127.0.0.1:\(self.port)"
                        JetsamGuard.shared.log("MCP Server ready at http://\(scope)/mcp")
                    case .failed(let err):
                        let wasReady = self.isRunning
                        newListener.cancel()
                        self.listener = nil
                        self.isRunning = false
                        self.lastError = err.localizedDescription
                        JetsamGuard.shared.log("MCP Server failed: \(err.localizedDescription)")
                        if wasReady && !self.userStopped {
                            self.start()
                        }
                    case .waiting(let err):
                        newListener.cancel()
                        self.listener = nil
                        self.isRunning = false
                        self.lastError = err.localizedDescription
                        JetsamGuard.shared.log("MCP Server waiting, cancelled: \(err.localizedDescription)")
                    case .cancelled:
                        self.listener = nil
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] conn in
                guard let self else {
                    conn.cancel()
                    return
                }
                self.acceptConnection(conn)
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        userStopped = true
        activeSessionIds.removeAll()
        JetsamGuard.shared.log("MCP Server stopped")
    }

    // MARK: - Complete Tool & Resource Catalog Exposed Over MCP

    nonisolated static var runnerToolSchemas: [MCPToolDescriptor] {
        [
            MCPToolDescriptor(
                name: "ios_screenshot",
                description: "Capture current iOS/iPadOS screen via GroguRunner and return an MCP image/jpeg block.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "quality": .object(["type": .string("number")]),
                        "max_long_edge": .object(["type": .string("integer")]),
                    ]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_ui_tree",
                description: "Read viewport-culled bounded Accessibility tree of the foreground iOS app.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "bundle_id": .object(["type": .string("string")]),
                        "max_depth": .object(["type": .string("integer")]),
                        "max_elements": .object(["type": .string("integer")]),
                    ]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_ocr",
                description: "Run on-device Apple Vision OCR on current screen returning text + center coordinates (cx, cy).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "min_confidence": .object(["type": .string("number")]),
                    ]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_find_element",
                description: "Locate matching accessibility elements ranked by visibility (in_view first).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "bundle_id": .object(["type": .string("string")]),
                        "contains": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_tap",
                description: "Fast synthesized HID tap at (x, y) point coordinates (~50ms, bypasses quiescence).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "x": .object(["type": .string("number")]),
                        "y": .object(["type": .string("number")]),
                    ]),
                    "required": .array([.string("x"), .string("y")]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_double_tap",
                description: "Synthesized double tap at (x, y) inside a single HID path.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "x": .object(["type": .string("number")]),
                        "y": .object(["type": .string("number")]),
                    ]),
                    "required": .array([.string("x"), .string("y")]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_long_press",
                description: "Synthesized press-and-hold at (x, y) for `duration` seconds.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "x": .object(["type": .string("number")]),
                        "y": .object(["type": .string("number")]),
                        "duration": .object(["type": .string("number")]),
                    ]),
                    "required": .array([.string("x"), .string("y")]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_swipe",
                description: "Synthesized drag/swipe with anti-momentum stationary hold.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "from_x": .object(["type": .string("number")]),
                        "from_y": .object(["type": .string("number")]),
                        "to_x": .object(["type": .string("number")]),
                        "to_y": .object(["type": .string("number")]),
                        "duration": .object(["type": .string("number")]),
                        "hold": .object(["type": .string("number")]),
                    ]),
                    "required": .array([.string("from_x"), .string("from_y"), .string("to_x"), .string("to_y")]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_type_text",
                description: "Type Unicode text into the currently focused field.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("text")]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_press_home",
                description: "Press hardware Home / return to iOS SpringBoard.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            MCPToolDescriptor(
                name: "ios_launch_app",
                description: "Launch or foreground an app by bundle_id.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["bundle_id": .object(["type": .string("string")])]),
                    "required": .array([.string("bundle_id")]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_open_url",
                description: "Open a deep link or universal URL via GroguRunner XCTRunnerDaemonSession.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["url": .object(["type": .string("string")])]),
                    "required": .array([.string("url")]),
                ])
            ),
            MCPToolDescriptor(
                name: "ios_wait_stable",
                description: "Wait briefly until screen pixels stop animating.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["timeout": .object(["type": .string("number")])]),
                ])
            ),
        ]
    }

    nonisolated static var agentMetaToolSchemas: [MCPToolDescriptor] {
        [
            MCPToolDescriptor(
                name: "grogu_agent_run",
                description: "Execute a natural-language goal autonomously inside Grogu's on-device native iOS agent.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "goal": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("goal")]),
                ])
            ),
            MCPToolDescriptor(
                name: "grogu_agent_status",
                description: "Read current status, running state, recent step count, and Jetsam memory metrics of Grogu.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            MCPToolDescriptor(
                name: "grogu_memory_read",
                description: "Read persistent GroguWorkspace MEMORY.md contents.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            MCPToolDescriptor(
                name: "grogu_memory_append",
                description: "Append a durable factual note to GroguWorkspace MEMORY.md.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["note": .object(["type": .string("string")])]),
                    "required": .array([.string("note")]),
                ])
            ),
            MCPToolDescriptor(
                name: "grogu_skills_list",
                description: "List markdown skill files stored in GroguWorkspace/skills.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            MCPToolDescriptor(
                name: "grogu_skill_read",
                description: "Read a named markdown skill file from GroguWorkspace/skills.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["name": .object(["type": .string("string")])]),
                    "required": .array([.string("name")]),
                ])
            ),
        ]
    }

    // MARK: - Connection Handling (Background Queue)

    nonisolated private func acceptConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveLoop(conn: conn, buffer: Data())
    }

    nonisolated private func receiveLoop(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                conn.cancel()
                return
            }
            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }
            if accumulated.count > self.maxBodyBytes + 32_768 {
                self.writeHTTP(conn: conn, status: 413, headers: [:], body: Data("{\"error\":\"Payload too large\"}".utf8))
                return
            }
            if let parsed = Self.parseHTTP(accumulated) {
                Task { @MainActor in
                    await self.routeHTTP(parsed, conn: conn)
                }
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receiveLoop(conn: conn, buffer: accumulated)
        }
    }

    private func routeHTTP(_ req: ParsedHTTP, conn: NWConnection) async {
        if req.method == "GET" && req.path == "/health" {
            let mem = MemorySnapshot.current()
            let runnerReady = RunnerLauncher.shared.state == .ready
            let payload: [String: JSONValue] = [
                "ok": .bool(true),
                "service": .string("Grogu-iOS-MCP"),
                "protocol": .string(MCPProtocol.version),
                "tools": .int(NativeSystemTools.toolSchemas.count + Self.runnerToolSchemas.count + Self.agentMetaToolSchemas.count + SelfManagementTools.remoteSafeToolSchemas.count),
                "runner_ready": .bool(runnerReady),
                "phys_footprint_mb": .double(mem.physFootprintMB),
                "available_mb": .double(mem.availableMB),
            ]
            let data = (try? JSONEncoder().encode(JSONValue.object(payload))) ?? Data("{}".utf8)
            writeHTTP(conn: conn, status: 200, headers: [:], body: data)
            return
        }

        guard req.path == "/mcp" else {
            writeHTTP(conn: conn, status: 404, headers: [:], body: Data("{\"error\":\"Use /mcp or /health\"}".utf8))
            return
        }

        guard Self.verifyBearer(req.headers, expected: bearerToken) else {
            writeHTTP(conn: conn, status: 401, headers: [:], body: Data("{\"error\":\"Unauthorized\"}".utf8))
            return
        }

        if req.method == "DELETE" {
            if let sid = req.headers["mcp-session-id"] {
                activeSessionIds.remove(sid)
            }
            writeHTTP(conn: conn, status: 204, headers: [:], body: Data())
            return
        }

        guard req.method == "POST" else {
            writeHTTP(conn: conn, status: 405, headers: ["Allow": "POST, DELETE"], body: Data("{\"error\":\"Method not allowed\"}".utf8))
            return
        }

        requestCount += 1
        guard let rpc = try? JSONDecoder().decode(MCPJSONRPCRequest.self, from: req.body) else {
            let err = MCPJSONRPCResponse(
                id: .null,
                result: nil,
                error: MCPJSONRPCErrorPayload(code: -32700, message: "Parse error", data: nil)
            )
            let data = (try? JSONEncoder().encode(err)) ?? Data("{}".utf8)
            writeHTTP(conn: conn, status: 400, headers: [:], body: data)
            return
        }

        var responseHeaders: [String: String] = ["MCP-Protocol-Version": MCPProtocol.version]
        if let incomingSID = req.headers["mcp-session-id"], !incomingSID.isEmpty {
            responseHeaders["Mcp-Session-Id"] = incomingSID
        }

        let rpcResponse: MCPJSONRPCResponse?
        switch rpc.method {
        case "initialize":
            let newSessionId = UUID().uuidString.lowercased()
            if activeSessionIds.count >= 32, let first = activeSessionIds.first {
                activeSessionIds.remove(first)
            }
            activeSessionIds.insert(newSessionId)
            responseHeaders["Mcp-Session-Id"] = newSessionId
            rpcResponse = MCPJSONRPCResponse(
                id: rpc.id ?? .int(1),
                result: .object([
                    "protocolVersion": .string(MCPProtocol.version),
                    "capabilities": .object([
                        "tools": .object(["listChanged": .bool(false)]),
                        "resources": .object(["listChanged": .bool(false)]),
                    ]),
                    "serverInfo": .object([
                        "name": .string("Grogu-iOS"),
                        "version": .string("1.0.0"),
                    ]),
                ]),
                error: nil
            )

        case "notifications/initialized":
            writeHTTP(conn: conn, status: 202, headers: responseHeaders, body: Data())
            return

        case "ping":
            rpcResponse = MCPJSONRPCResponse(id: rpc.id ?? .int(1), result: .object([:]), error: nil)

        case "tools/list":
            let allTools = NativeSystemTools.toolSchemas + Self.runnerToolSchemas + Self.agentMetaToolSchemas + SelfManagementTools.remoteSafeToolSchemas
            let encodedTools = allTools.map { t in
                JSONValue.object([
                    "name": .string(t.name),
                    "description": .string(t.description),
                    "inputSchema": t.inputSchema,
                ])
            }
            rpcResponse = MCPJSONRPCResponse(
                id: rpc.id ?? .int(1),
                result: .object(["tools": .array(encodedTools)]),
                error: nil
            )

        case "tools/call":
            let paramsObj = rpc.params?.objectValue ?? [:]
            let toolName = paramsObj["name"]?.stringValue ?? ""
            let toolArgs = paramsObj["arguments"]?.objectValue ?? [:]
            let callResult = await executeMCPTool(name: toolName, arguments: toolArgs)
            let blocksJSON: [JSONValue] = callResult.content.map { b in
                var obj: [String: JSONValue] = ["type": .string(b.type)]
                if let text = b.text { obj["text"] = .string(text) }
                if let data = b.data { obj["data"] = .string(data) }
                if let mime = b.mimeType { obj["mimeType"] = .string(mime) }
                return .object(obj)
            }
            rpcResponse = MCPJSONRPCResponse(
                id: rpc.id ?? .int(1),
                result: .object([
                    "content": .array(blocksJSON),
                    "isError": .bool(callResult.isError ?? false),
                ]),
                error: nil
            )

        case "resources/list":
            let resources: [JSONValue] = [
                .object(["uri": .string("grogu://device/status"), "name": .string("Device Status"), "mimeType": .string("application/json")]),
                .object(["uri": .string("grogu://device/memory"), "name": .string("Jetsam Memory Footprint"), "mimeType": .string("application/json")]),
                .object(["uri": .string("grogu://workspace/memory"), "name": .string("Workspace MEMORY.md"), "mimeType": .string("text/markdown")]),
                .object(["uri": .string("grogu://workspace/skills"), "name": .string("Workspace Skills Catalog"), "mimeType": .string("application/json")]),
                .object(["uri": .string("grogu://screen/tree"), "name": .string("Current UI Accessibility Tree"), "mimeType": .string("application/json")]),
                .object(["uri": .string("grogu://screen/screenshot"), "name": .string("Current Screen JPEG"), "mimeType": .string("image/jpeg")]),
            ]
            rpcResponse = MCPJSONRPCResponse(
                id: rpc.id ?? .int(1),
                result: .object(["resources": .array(resources)]),
                error: nil
            )

        case "resources/read":
            let uri = rpc.params?.objectValue?["uri"]?.stringValue ?? ""
            let contents = await readResource(uri: uri)
            rpcResponse = MCPJSONRPCResponse(
                id: rpc.id ?? .int(1),
                result: .object(["contents": .array(contents)]),
                error: nil
            )

        default:
            rpcResponse = MCPJSONRPCResponse(
                id: rpc.id ?? .null,
                result: nil,
                error: MCPJSONRPCErrorPayload(code: -32601, message: "Method not found: \(rpc.method)", data: nil)
            )
        }

        if let rpcResponse {
            let body = (try? JSONEncoder().encode(rpcResponse)) ?? Data("{}".utf8)
            writeHTTP(conn: conn, status: 200, headers: responseHeaders, body: body)
        }
    }

    // MARK: - Local Tool & Resource Execution

    func executeMCPTool(name: String, arguments: [String: JSONValue]) async -> MCPToolCallResult {
        if NativeSystemTools.toolSchemas.contains(where: { $0.name == name }) {
            return await NativeSystemTools.shared.execute(toolName: name, arguments: arguments)
        }

        if SelfManagementTools.localOnlyToolNames.contains(name) {
            return .error("\(name) is only available to the on-device agent")
        }
        if SelfManagementTools.handles(name) {
            return await SelfManagementTools.execute(toolName: name, arguments: arguments)
        }

        if let runnerMethod = Self.runnerMethodMap[name] {
            do {
                let res = try await RunnerClient.shared.call(runnerMethod, params: arguments)
                if name == "ios_screenshot", let b64 = res["jpeg_base64"]?.stringValue {
                    var summary = res
                    summary.removeValue(forKey: "jpeg_base64")
                    return MCPToolCallResult(
                        content: [
                            .text(JSONValue.object(summary).prettyJSONString()),
                            .image(base64JPEG: b64),
                        ],
                        isError: false
                    )
                }
                return .json(res)
            } catch {
                var message = error.localizedDescription
                if let runnerError = error as? RunnerClient.RunnerClientError {
                    switch runnerError {
                    case .missingToken, .unreachable, .unauthorized:
                        message += " Call `runner_wake` to launch GroguRunner."
                    default:
                        break
                    }
                }
                return .error(message)
            }
        }

        switch name {
        case "grogu_agent_run":
            let goal = arguments.string("goal") ?? ""
            guard !goal.isEmpty else { return .error("grogu_agent_run requires `goal`") }
            let summary = await AgentRuntime.shared.runOneShotFromMCP(goal: goal)
            return .text(summary)

        case "grogu_agent_status":
            let mem = MemorySnapshot.current()
            return .json([
                "is_running": .bool(AgentRuntime.shared.isRunning),
                "step_count": .int(AgentRuntime.shared.stepCount),
                "last_reply": .string(AgentRuntime.shared.lastFinalReply),
                "phys_footprint_mb": .double(mem.physFootprintMB),
                "available_mb": .double(mem.availableMB),
            ])

        case "grogu_memory_read":
            return .text(WorkspaceStore.shared.memoryText)

        case "grogu_memory_append":
            let note = (arguments.string("note") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            WorkspaceStore.shared.appendMemory(note.isEmpty ? "" : "[via remote MCP] " + note)
            return .json(["appended": .bool(true)])

        case "grogu_skills_list":
            let items = WorkspaceStore.shared.skills.map {
                JSONValue.object(["name": .string($0.name), "summary": .string($0.summary)])
            }
            return .json(["skills": .array(items)])

        case "grogu_skill_read":
            let sName = arguments.string("name") ?? ""
            if let doc = WorkspaceStore.shared.skills.first(where: { $0.name == sName }) {
                return .text(doc.content)
            }
            return .error("Skill '\(sName)' not found")

        default:
            return .error("Unknown tool: \(name)")
        }
    }

    private func readResource(uri: String) async -> [JSONValue] {
        switch uri {
        case "grogu://device/status":
            let info = await NativeSystemTools.shared.execute(toolName: "device_info", arguments: [:])
            return [.object([
                "uri": .string(uri),
                "mimeType": .string("application/json"),
                "text": .string(info.flattenedText()),
            ])]
        case "grogu://device/memory":
            let mem = MemorySnapshot.current()
            let json = JSONValue.object([
                "phys_footprint_mb": .double(mem.physFootprintMB),
                "available_mb": .double(mem.availableMB),
                "pressure": .string(mem.pressure.rawValue),
            ])
            return [.object([
                "uri": .string(uri),
                "mimeType": .string("application/json"),
                "text": .string(json.prettyJSONString()),
            ])]
        case "grogu://workspace/memory":
            return [.object([
                "uri": .string(uri),
                "mimeType": .string("text/markdown"),
                "text": .string(WorkspaceStore.shared.memoryText),
            ])]
        case "grogu://workspace/skills":
            let items = WorkspaceStore.shared.skills.map {
                JSONValue.object(["name": .string($0.name), "summary": .string($0.summary)])
            }
            return [.object([
                "uri": .string(uri),
                "mimeType": .string("application/json"),
                "text": .string(JSONValue.array(items).prettyJSONString()),
            ])]
        case "grogu://screen/tree":
            let tree = (try? await RunnerClient.shared.call("ui_tree", params: [:])) ?? [:]
            return [.object([
                "uri": .string(uri),
                "mimeType": .string("application/json"),
                "text": .string(JSONValue.object(tree).prettyJSONString()),
            ])]
        case "grogu://screen/screenshot":
            let shot = (try? await RunnerClient.shared.call("screenshot", params: ["quality": .double(0.4)])) ?? [:]
            let blob = shot["jpeg_base64"]?.stringValue ?? ""
            return [.object([
                "uri": .string(uri),
                "mimeType": .string("image/jpeg"),
                "blob": .string(blob),
            ])]
        default:
            return []
        }
    }

    private static let runnerMethodMap: [String: String] = [
        "ios_screenshot": "screenshot",
        "ios_ui_tree": "ui_tree",
        "ios_ocr": "ocr",
        "ios_find_element": "find_element",
        "ios_tap": "tap",
        "ios_double_tap": "double_tap",
        "ios_long_press": "long_press",
        "ios_swipe": "swipe",
        "ios_type_text": "type_text",
        "ios_press_home": "press_home",
        "ios_lock_screen": "lock_screen",
        "ios_unlock_screen": "unlock_screen",
        "ios_launch_app": "launch_app",
        "ios_terminate_app": "terminate_app",
        "ios_open_url": "open_url",
        "ios_wait_stable": "wait_stable",
        "ios_foreground_app": "foreground_app",
    ]

    // MARK: - HTTP Framing & Auth

    private struct ParsedHTTP {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    nonisolated private static func parseHTTP(_ data: Data) -> ParsedHTTP? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter) else { return nil }
        guard let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let line0 = lines.first else { return nil }
        let parts = line0.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard data.count - bodyStart >= len else { return nil }
        return ParsedHTTP(method: method, path: path, headers: headers, body: Data(data[bodyStart..<(bodyStart + len)]))
    }

    nonisolated private static func verifyBearer(_ headers: [String: String], expected: String) -> Bool {
        guard let auth = headers["authorization"] else { return false }
        let prefix = "Bearer "
        guard auth.count > prefix.count,
              auth.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else {
            return false
        }
        let supplied = String(auth.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        let a = Array(supplied.utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    nonisolated private func writeHTTP(conn: NWConnection, status: Int, headers: [String: String], body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var headerText = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
        for (k, v) in headers {
            headerText += "\(k): \(v)\r\n"
        }
        headerText += "Connection: close\r\n\r\n"
        var packet = Data(headerText.utf8)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    nonisolated private static func generateTokenHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
