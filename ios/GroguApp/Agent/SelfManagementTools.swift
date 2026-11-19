import Contacts
import CoreLocation
import Darwin
import EventKit
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Self-awareness and self-management tools for the on-device agent: own MCP server,
/// external MCP clients, iOS permissions, GroguRunner wake-up and sibling app detection.
@MainActor
enum SelfManagementTools {
    static let localOnlyToolNames: Set<String> = ["mcp_server_manage", "mcp_client_manage"]

    static let knownAppSchemes: [(scheme: String, app: String)] = [
        (scheme: "grokbot", app: "Grok Bot"),
        (scheme: "sand-mobile", app: "Grok Bot"),
        (scheme: "tailscale", app: "Tailscale"),
        (scheme: "shortcuts", app: "Shortcuts"),
        (scheme: "grogu-runner", app: "GroguRunner"),
        (scheme: "localdevvpn", app: "LocalDevVPN"),
        (scheme: "stikdebug", app: "StikDebug"),
        (scheme: "chatgpt", app: "ChatGPT"),
        (scheme: "claude", app: "Claude"),
        (scheme: "googlechrome", app: "Google Chrome"),
        (scheme: "weixin", app: "WeChat"),
        (scheme: "alipay", app: "Alipay"),
        (scheme: "tg", app: "Telegram"),
        (scheme: "obsidian", app: "Obsidian"),
    ]

    private static let permissionNames = ["calendar", "reminders", "contacts", "location", "photos", "notifications"]
    private static var locationManager: CLLocationManager?

    // MARK: - Schemas

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            obj["required"] = .array(required.map { .string($0) })
        }
        return .object(obj)
    }

    private static func enumString(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
    }

    private static let stringArray: JSONValue = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
    ])

    static let toolSchemas: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "grogu_self_info",
            description: "Describe GroguApp itself: own MCP server state/URLs/auth scheme, network interfaces, runner state, permission states, external MCP servers and installed sibling apps. Never includes secrets.",
            inputSchema: schema([:])
        ),
        MCPToolDescriptor(
            name: "mcp_server_manage",
            description: "Manage GroguApp's own on-device MCP server. Actions: status, start, stop, restart, copy_config (puts client config incl. bearer token on the clipboard; token is redacted in the result), set_remote_access (requires `enabled`).",
            inputSchema: schema([
                "action": enumString(["status", "start", "stop", "restart", "copy_config", "set_remote_access"]),
                "enabled": .object(["type": .string("boolean")]),
            ], required: ["action"])
        ),
        MCPToolDescriptor(
            name: "mcp_client_manage",
            description: "Manage external MCP servers Grogu connects to. Actions: list, add (name, url, optional bearer_token), remove (server), toggle (server, optional enabled), refresh (optional server). `server` is a name or slug.",
            inputSchema: schema([
                "action": enumString(["list", "add", "remove", "toggle", "refresh"]),
                "name": .object(["type": .string("string")]),
                "url": .object(["type": .string("string")]),
                "bearer_token": .object(["type": .string("string")]),
                "server": .object(["type": .string("string")]),
                "enabled": .object(["type": .string("boolean")]),
            ], required: ["action"])
        ),
        MCPToolDescriptor(
            name: "permissions_status",
            description: "Read iOS permission states (calendar, reminders, contacts, location, photos, notifications). Optional `request` lists permissions to request; only not_determined ones trigger the system prompt.",
            inputSchema: schema(["request": stringArray])
        ),
        MCPToolDescriptor(
            name: "runner_wake",
            description: "Launch GroguRunner (UI automation for ios_* tools) and wait up to 10s until it is healthy.",
            inputSchema: schema([:])
        ),
        MCPToolDescriptor(
            name: "app_scheme_probe",
            description: "Check which apps are installed via URL schemes. Optional `schemes` (default: known sibling apps). Undeclared schemes always report false.",
            inputSchema: schema(["schemes": stringArray])
        ),
    ]

    static var remoteSafeToolSchemas: [MCPToolDescriptor] {
        toolSchemas.filter { !localOnlyToolNames.contains($0.name) }
    }

    static func handles(_ name: String) -> Bool {
        toolSchemas.contains { $0.name == name }
    }

    // MARK: - Execution

    static func execute(toolName: String, arguments: [String: JSONValue]) async -> MCPToolCallResult {
        switch toolName {
        case "grogu_self_info":
            return .json(await selfInfo())
        case "mcp_server_manage":
            return await manageServer(arguments)
        case "mcp_client_manage":
            return await manageClients(arguments)
        case "permissions_status":
            return await permissionsStatus(arguments)
        case "runner_wake":
            return await wakeRunner()
        case "app_scheme_probe":
            return probeSchemes(arguments)
        default:
            return .error("Unknown tool: \(toolName)")
        }
    }

    // MARK: - Own MCP Server

    private static func serverURLs() -> [(kind: String, url: String)] {
        let server = MCPServerService.shared
        var urls: [(kind: String, url: String)] = [(kind: "loopback", url: "http://127.0.0.1:\(server.port)/mcp")]
        if server.allowRemoteAccess {
            for iface in networkInterfaces() {
                urls.append((kind: "\(iface.kind) (\(iface.name))", url: "http://\(iface.ipv4):\(server.port)/mcp"))
            }
        }
        return urls
    }

    private static func bestServerURL() -> String {
        let server = MCPServerService.shared
        if server.allowRemoteAccess {
            let ifaces = networkInterfaces()
            if let ts = ifaces.first(where: { $0.kind == "tailscale" }) {
                return "http://\(ts.ipv4):\(server.port)/mcp"
            }
            if let lan = ifaces.first(where: { $0.kind == "lan" && $0.name == "en0" }) ?? ifaces.first(where: { $0.kind == "lan" }) {
                return "http://\(lan.ipv4):\(server.port)/mcp"
            }
        }
        return "http://127.0.0.1:\(server.port)/mcp"
    }

    private static func exposedToolCount() -> Int {
        NativeSystemTools.toolSchemas.count
            + MCPServerService.runnerToolSchemas.count
            + MCPServerService.agentMetaToolSchemas.count
            + remoteSafeToolSchemas.count
    }

    private static func serverStatus() -> [String: JSONValue] {
        let server = MCPServerService.shared
        var obj: [String: JSONValue] = [
            "running": .bool(server.isRunning),
            "port": .int(Int(server.port)),
            "remote_access": .bool(server.allowRemoteAccess),
            "bind_scope": .string(server.allowRemoteAccess ? "all interfaces" : "loopback only"),
            "urls": .array(serverURLs().map { .object(["kind": .string($0.kind), "url": .string($0.url)]) }),
            "auth": .string("Bearer token required (never reveal; use mcp_server_manage copy_config)"),
            "exposed_tools": .int(exposedToolCount()),
            "request_count": .int(server.requestCount),
        ]
        if let err = server.lastError {
            obj["last_error"] = .string(err)
        }
        return obj
    }

    private static func waitForServerRunning() async {
        for _ in 0..<20 {
            if MCPServerService.shared.isRunning || MCPServerService.shared.lastError != nil || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func restartServer() async {
        MCPServerService.shared.stop()
        try? await Task.sleep(for: .milliseconds(300))
        MCPServerService.shared.start()
        await waitForServerRunning()
    }

    private static func serverStatusResult(requireRunning: Bool) -> MCPToolCallResult {
        if requireRunning && !MCPServerService.shared.isRunning {
            return MCPToolCallResult(content: [.text(JSONValue.object(serverStatus()).prettyJSONString())], isError: true)
        }
        return .json(serverStatus())
    }

    private static func clientConfig(url: String, authorization: String) -> JSONValue {
        .object([
            "mcpServers": .object([
                "grogu-ios": .object([
                    "type": .string("http"),
                    "url": .string(url),
                    "headers": .object(["Authorization": .string(authorization)]),
                ]),
            ]),
        ])
    }

    private static func encodePretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func manageServer(_ args: [String: JSONValue]) async -> MCPToolCallResult {
        let server = MCPServerService.shared
        let action = (args.string("action") ?? "status").lowercased()
        switch action {
        case "status":
            return .json(serverStatus())
        case "start":
            server.start()
            await waitForServerRunning()
            return serverStatusResult(requireRunning: true)
        case "stop":
            server.stop()
            return .json(serverStatus())
        case "restart":
            await restartServer()
            return serverStatusResult(requireRunning: true)
        case "set_remote_access":
            guard let enabled = args.bool("enabled") else {
                return .error("set_remote_access requires boolean `enabled`")
            }
            let hadListener = server.hasListener
            server.allowRemoteAccess = enabled
            if hadListener {
                await restartServer()
            }
            return serverStatusResult(requireRunning: hadListener)
        case "copy_config":
            let url = bestServerURL()
            let text = encodePretty(clientConfig(url: url, authorization: "Bearer \(server.bearerToken)"))
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: text]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]
            )
            var result: [String: JSONValue] = [
                "copied_to_clipboard": .bool(true),
                "clipboard_expires_in": .string("5 minutes (local device only, not synced via Universal Clipboard)"),
                "config": clientConfig(url: url, authorization: "Bearer <copied-to-clipboard>"),
                "running": .bool(server.isRunning),
            ]
            if url.contains("127.0.0.1") {
                result["note"] = .string("Loopback URL only works for clients on this device. Enable remote access for LAN/Tailscale clients.")
            }
            return .json(result)
        default:
            return .error("Unknown mcp_server_manage action '\(action)'")
        }
    }

    // MARK: - External MCP Clients

    private static func findServer(_ key: String?) -> MCPServerConfig? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        let lowered = key.lowercased()
        return MCPClientHub.shared.servers.first {
            $0.name.lowercased() == lowered || $0.slug == lowered
        }
    }

    private static func sanitizedURL(_ text: String) -> String {
        guard var comps = URLComponents(string: text) else { return "<invalid url>" }
        comps.user = nil
        comps.password = nil
        comps.query = nil
        return comps.string ?? "<invalid url>"
    }

    private static func describeServer(_ cfg: MCPServerConfig) -> JSONValue {
        let hub = MCPClientHub.shared
        var obj: [String: JSONValue] = [
            "name": .string(cfg.name),
            "slug": .string(cfg.slug),
            "url": .string(sanitizedURL(cfg.endpointURL)),
            "enabled": .bool(cfg.isEnabled),
            "tool_count": .int(hub.toolsByServer[cfg.id]?.count ?? cfg.lastToolCount),
        ]
        if let err = cfg.lastError {
            obj["last_error"] = .string(err)
        }
        return .object(obj)
    }

    private static func listServers() -> MCPToolCallResult {
        .json(["servers": .array(MCPClientHub.shared.servers.map { describeServer($0) })])
    }

    private static func manageClients(_ args: [String: JSONValue]) async -> MCPToolCallResult {
        let hub = MCPClientHub.shared
        let action = (args.string("action") ?? "list").lowercased()
        let serverKey = args.string("server") ?? args.string("name")
        switch action {
        case "list":
            return listServers()
        case "add":
            let name = (args.string("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let urlText = (args.string("url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .error("add requires `name`") }
            guard let url = URL(string: urlText),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return .error("add requires a valid http/https `url`")
            }
            let slug = MCPServerConfig.makeSlug(name)
            if let existing = hub.servers.first(where: { $0.slug == slug || $0.endpointURL == urlText }) {
                return .error("An MCP server with the same name/slug or URL already exists ('\(existing.name)', slug '\(existing.slug)'). Remove it first or pick another name.")
            }
            hub.addServer(name: name, endpointURL: urlText, bearerToken: args.string("bearer_token"))
            guard let added = hub.servers.last else { return .error("Failed to add MCP server") }
            await hub.connectAndSync(serverID: added.id)
            if let refreshed = hub.servers.first(where: { $0.id == added.id }) {
                return .json(["added": describeServer(refreshed)])
            }
            return .json(["added": describeServer(added)])
        case "remove":
            guard let cfg = findServer(serverKey) else { return .error("MCP server '\(serverKey ?? "")' not found") }
            hub.removeServer(id: cfg.id)
            return .json(["removed": .string(cfg.name)])
        case "toggle":
            guard let cfg = findServer(serverKey) else { return .error("MCP server '\(serverKey ?? "")' not found") }
            let enabled = args.bool("enabled") ?? !cfg.isEnabled
            hub.toggleServer(id: cfg.id, enabled: enabled)
            if enabled {
                await hub.connectAndSync(serverID: cfg.id)
            }
            if let refreshed = hub.servers.first(where: { $0.id == cfg.id }) {
                return .json(["server": describeServer(refreshed)])
            }
            return listServers()
        case "refresh":
            if let key = serverKey, !key.isEmpty {
                guard let cfg = findServer(key) else { return .error("MCP server '\(key)' not found") }
                await hub.connectAndSync(serverID: cfg.id)
            } else {
                await hub.refreshAllEnabled()
            }
            return listServers()
        default:
            return .error("Unknown mcp_client_manage action '\(action)'")
        }
    }

    // MARK: - Permissions

    private static func calendarState(_ entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .writeOnly: return "write_only"
        case .fullAccess: return "authorized"
        default: return "authorized"
        }
    }

    private static func contactsState() -> String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        default: return "limited"
        }
    }

    private static func locationState() -> String {
        let mgr = locationManager ?? CLLocationManager()
        locationManager = mgr
        switch mgr.authorizationStatus {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways, .authorizedWhenInUse: return "authorized"
        @unknown default: return "not_determined"
        }
    }

    private static func photosState() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "not_determined"
        }
    }

    private static func notificationsState() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional, .ephemeral: return "limited"
        @unknown default: return "not_determined"
        }
    }

    private static func permissionStates() async -> [(name: String, state: String)] {
        [
            (name: "calendar", state: calendarState(.event)),
            (name: "reminders", state: calendarState(.reminder)),
            (name: "contacts", state: contactsState()),
            (name: "location", state: locationState()),
            (name: "photos", state: photosState()),
            (name: "notifications", state: await notificationsState()),
        ]
    }

    private static func requestPermission(_ name: String) async {
        switch name {
        case "calendar":
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case "reminders":
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case "contacts":
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case "location":
            let mgr = locationManager ?? CLLocationManager()
            locationManager = mgr
            mgr.requestWhenInUseAuthorization()
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled || mgr.authorizationStatus != .notDetermined { break }
            }
        case "photos":
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case "notifications":
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        default:
            break
        }
    }

    private static func permissionsStatus(_ args: [String: JSONValue]) async -> MCPToolCallResult {
        let requested = (args["request"]?.arrayValue ?? []).compactMap { $0.stringValue?.lowercased() }
        var requestedNow: [String] = []
        var unknown: [String] = []
        let isActive = UIApplication.shared.applicationState == .active
        if !requested.isEmpty && isActive {
            let current = await permissionStates()
            for name in requested {
                guard permissionNames.contains(name) else {
                    unknown.append(name)
                    continue
                }
                if current.first(where: { $0.name == name })?.state == "not_determined" {
                    await requestPermission(name)
                    requestedNow.append(name)
                }
            }
        }
        var states: [String: JSONValue] = [:]
        for entry in await permissionStates() {
            states[entry.name] = .string(entry.state)
        }
        var result: [String: JSONValue] = ["permissions": .object(states)]
        if !requested.isEmpty && !isActive {
            result["requested"] = .array([])
            result["note"] = .string("Permission prompts need GroguApp in the foreground. Ask the user to open GroguApp, then retry.")
        } else if !requested.isEmpty {
            result["requested"] = .array(requestedNow.map { .string($0) })
            result["note"] = .string("Only not_determined permissions trigger a system prompt; denied ones must be changed in iOS Settings > Grogu.")
        }
        if !unknown.isEmpty {
            result["unknown"] = .array(unknown.map { .string($0) })
        }
        return .json(result)
    }

    // MARK: - Runner

    private static func runnerStateName() -> String {
        switch RunnerLauncher.shared.state {
        case .unknown: return "unknown"
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .ready: return "ready"
        }
    }

    private static func probeRunner() async -> (healthy: Bool, ready: Bool, tokenProblem: Bool) {
        guard await RunnerLauncher.shared.refreshHealth() else {
            return (healthy: false, ready: false, tokenProblem: false)
        }
        do {
            _ = try await RunnerClient.shared.call("device_status", params: [:], timeout: 3)
            return (healthy: true, ready: true, tokenProblem: false)
        } catch let error as RunnerClient.RunnerClientError {
            switch error {
            case .missingToken, .unauthorized:
                return (healthy: true, ready: false, tokenProblem: true)
            default:
                return (healthy: true, ready: false, tokenProblem: false)
            }
        } catch {
            return (healthy: true, ready: false, tokenProblem: false)
        }
    }

    @MainActor
    private final class BackgroundTaskBox {
        var id: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    private static func runnerStatus() async -> String {
        let probe = await probeRunner()
        if probe.ready { return "ready" }
        if probe.healthy && probe.tokenProblem { return "running_token_invalid" }
        return runnerStateName()
    }

    private static func wakeRunner() async -> MCPToolCallResult {
        let launcher = RunnerLauncher.shared
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var probe = await probeRunner()
        if probe.ready {
            return .json([
                "state": .string("ready"),
                "session_token_present": .bool(true),
                "launched": .bool(false),
            ])
        }
        guard UIApplication.shared.applicationState == .active else {
            if probe.healthy {
                return .error("GroguRunner is running but its session token is missing or stale, and GroguApp is not in the foreground. Ask the user to open GroguApp and retry `runner_wake`.")
            }
            return .error("GroguRunner is not running and GroguApp is not in the foreground, so it cannot be launched now. Ask the user to open GroguApp and retry `runner_wake`.")
        }
        let backgroundTask = BackgroundTaskBox()
        backgroundTask.id = UIApplication.shared.beginBackgroundTask(withName: "GroguRunnerWake") {
            MainActor.assumeIsolated {
                backgroundTask.end()
            }
        }
        defer { backgroundTask.end() }
        let action: String
        if probe.healthy && probe.tokenProblem {
            launcher.syncTokenOnly()
            action = "token_sync"
        } else if probe.healthy {
            action = "wait"
        } else {
            launcher.launchRunner()
            action = "launch"
        }
        while clock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            probe = await probeRunner()
            if probe.ready { break }
        }
        if probe.ready {
            return .json([
                "state": .string("ready"),
                "session_token_present": .bool(true),
                "action": .string(action),
            ])
        }
        launcher.markStopped()
        let message: String
        if probe.healthy && probe.tokenProblem {
            message = "GroguRunner is healthy but rejected or lacks the session token after 10s. Make sure GroguRunner returned to GroguApp (grogu://runner-ready), then retry `runner_wake`."
        } else {
            message = "GroguRunner did not accept authenticated requests within 10s. Ensure LocalDevVPN is connected and the Developer Disk Image is mounted (DDI tab in GroguApp), then retry `runner_wake`."
        }
        let result: [String: JSONValue] = [
            "state": .string(runnerStateName()),
            "session_token_present": .bool(launcher.sessionToken != nil),
            "action": .string(action),
            "message": .string(message),
        ]
        return MCPToolCallResult(content: [.text(JSONValue.object(result).prettyJSONString())], isError: true)
    }

    // MARK: - Sibling Apps

    private static func isSchemeInstalled(_ scheme: String) -> Bool {
        guard let url = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private static func probeSchemes(_ args: [String: JSONValue]) -> MCPToolCallResult {
        var requested: [String] = []
        for value in args["schemes"]?.arrayValue ?? [] {
            guard let raw = value.stringValue else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let scheme = String(trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").lowercased()
            if !scheme.isEmpty && !requested.contains(scheme) {
                requested.append(scheme)
            }
        }
        let schemes = requested.isEmpty ? knownAppSchemes.map { $0.scheme } : requested
        var items: [JSONValue] = []
        for scheme in schemes {
            var obj: [String: JSONValue] = [
                "scheme": .string(scheme),
                "installed": .bool(isSchemeInstalled(scheme)),
                "declared": .bool(knownAppSchemes.contains { $0.scheme == scheme }),
            ]
            if let app = knownAppSchemes.first(where: { $0.scheme == scheme })?.app {
                obj["app"] = .string(app)
            }
            items.append(.object(obj))
        }
        return .json([
            "results": .array(items),
            "note": .string("Schemes not declared in LSApplicationQueriesSchemes always report installed=false."),
        ])
    }

    private static func installedApps() -> [String] {
        var apps: [String] = []
        for entry in knownAppSchemes where isSchemeInstalled(entry.scheme) {
            if !apps.contains(entry.app) {
                apps.append(entry.app)
            }
        }
        return apps
    }

    // MARK: - Network

    static func networkInterfaces() -> [(name: String, ipv4: String, kind: String)] {
        var result: [(name: String, ipv4: String, kind: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ptr = cursor {
            cursor = ptr.pointee.ifa_next
            let flags = Int32(truncatingIfNeeded: ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let raw = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let value = UInt32(bigEndian: raw)
            let o1 = (value >> 24) & 0xFF
            let o2 = (value >> 16) & 0xFF
            let o3 = (value >> 8) & 0xFF
            let o4 = value & 0xFF
            let ip = "\(o1).\(o2).\(o3).\(o4)"
            let name = String(cString: ptr.pointee.ifa_name)
            let kind: String
            if o1 == 169 && o2 == 254 {
                kind = "other"
            } else if name.hasPrefix("utun") && o1 == 100 && (o2 & 0xC0) == 64 {
                kind = "tailscale"
            } else if name.hasPrefix("en") {
                kind = "lan"
            } else {
                kind = "other"
            }
            result.append((name: name, ipv4: ip, kind: kind))
        }
        return result
    }

    // MARK: - Context

    private static func selfInfo() async -> [String: JSONValue] {
        let runner = await runnerStatus()
        let info = Bundle.main.infoDictionary ?? [:]
        let device = UIDevice.current
        let hub = MCPClientHub.shared
        var permissions: [String: JSONValue] = [:]
        for entry in await permissionStates() {
            permissions[entry.name] = .string(entry.state)
        }
        return [
            "app": .object([
                "name": .string("GroguApp"),
                "bundle_id": .string(Bundle.main.bundleIdentifier ?? "unknown"),
                "version": .string(info["CFBundleShortVersionString"] as? String ?? "unknown"),
                "build": .string(info["CFBundleVersion"] as? String ?? "unknown"),
            ]),
            "device": .object([
                "model_identifier": .string(NativeSystemTools.modelIdentifier()),
                "name": .string(device.name),
                "os": .string("\(device.systemName) \(device.systemVersion)"),
            ]),
            "mcp_server": .object(serverStatus()),
            "network_interfaces": .array(networkInterfaces().map {
                .object(["name": .string($0.name), "ipv4": .string($0.ipv4), "kind": .string($0.kind)])
            }),
            "runner": .object([
                "state": .string(runner),
                "session_token_present": .bool(RunnerLauncher.shared.sessionToken != nil),
            ]),
            "permissions": .object(permissions),
            "external_mcp_servers": .array(hub.servers.map { cfg in
                .object([
                    "name": .string(cfg.name),
                    "enabled": .bool(cfg.isEnabled),
                    "tool_count": .int(hub.toolsByServer[cfg.id]?.count ?? cfg.lastToolCount),
                ])
            }),
            "installed_sibling_apps": .array(installedApps().map { .string($0) }),
        ]
    }

    static func runtimeContext() async -> String {
        let runner = await runnerStatus()
        let server = MCPServerService.shared
        let hub = MCPClientHub.shared
        var lines: [String] = []
        lines.append("- Own MCP server: \(server.isRunning ? "RUNNING" : "STOPPED") on port \(server.port), bind scope: \(server.allowRemoteAccess ? "all interfaces (remote access ON)" : "loopback only (remote access OFF)")")
        for entry in serverURLs() {
            lines.append("  - Reachable URL [\(entry.kind)]: \(entry.url)")
        }
        lines.append("  - Auth: Bearer token required (never reveal; use mcp_server_manage copy_config)")
        if let err = server.lastError {
            lines.append("  - Last error: \(err)")
        }
        lines.append("  - Exposed tools: \(exposedToolCount())")
        let ifaces = networkInterfaces()
        if ifaces.isEmpty {
            lines.append("- Network interfaces: none with IPv4")
        } else {
            lines.append("- Network interfaces: " + ifaces.map { "\($0.name)=\($0.ipv4) (\($0.kind))" }.joined(separator: ", "))
        }
        let runnerNote = runner == "running_token_invalid" ? " (session token missing or stale: call `runner_wake`)" : ""
        lines.append("- GroguRunner UI automation: \(runner.uppercased())\(runnerNote), session token \(RunnerLauncher.shared.sessionToken != nil ? "present" : "missing")")
        let perms = await permissionStates().map { "\($0.name)=\($0.state)" }.joined(separator: ", ")
        lines.append("- Permissions: \(perms)")
        if hub.servers.isEmpty {
            lines.append("- External MCP servers: none configured")
        } else {
            lines.append("- External MCP servers:")
            for cfg in hub.servers {
                let count = hub.toolsByServer[cfg.id]?.count ?? cfg.lastToolCount
                lines.append("  - \(cfg.name): \(cfg.isEnabled ? "enabled" : "disabled"), \(count) tools")
            }
        }
        let apps = installedApps()
        lines.append("- Installed sibling apps: \(apps.isEmpty ? "none detected" : apps.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}
