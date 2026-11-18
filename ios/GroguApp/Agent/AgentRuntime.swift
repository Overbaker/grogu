import Foundation
import Observation

/// Pure Swift 6 on-device autonomous agent loop with Eta-style OS-first priority,
/// mid-run steering/queueing, strict bounded memory/image budgets, and bidirectional MCP wiring.
@MainActor
@Observable
final class AgentRuntime {
    static let shared = AgentRuntime()

    private static let endpointConfigKey = "grogu.agent.endpointConfig"
    private static let apiKeyAccount = "grogu-llm-api-key"

    struct TraceItem: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let kind: Kind
        let title: String
        let detail: String

        enum Kind: String, Sendable {
            case user
            case steer
            case tool
            case assistant
            case error
        }
    }

    var config: ModelClient.EndpointConfig {
        didSet { persistConfig() }
    }
    private(set) var hasAPIKey = false

    private(set) var isRunning = false
    private(set) var stepCount = 0
    private(set) var lastFinalReply = ""
    private(set) var queuedFollowUps: [String] = []
    private(set) var trace: [TraceItem] = []

    private var steeringQueue: [String] = []
    private var currentTask: Task<Void, Never>?
    private let modelClient = ModelClient()

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.endpointConfigKey),
           let decoded = try? JSONDecoder().decode(ModelClient.EndpointConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = ModelClient.EndpointConfig(
                provider: .openAICompatible,
                baseURL: "https://openrouter.ai/api/v1",
                model: "google/gemini-2.5-flash",
                maxOutputTokens: 1024,
                maxSteps: 18
            )
        }
        self.hasAPIKey = !(KeychainVault.loadString(account: Self.apiKeyAccount) ?? "").isEmpty

        JetsamGuard.shared.registerTrimHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.trace.count > 60 {
                    self.trace = Array(self.trace.suffix(60))
                }
            }
        }
    }

    func updateAPIKey(_ key: String) {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            KeychainVault.delete(account: Self.apiKeyAccount)
            hasAPIKey = false
        } else {
            KeychainVault.saveString(cleaned, account: Self.apiKeyAccount)
            hasAPIKey = true
        }
    }

    func submitOrSteer(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if isRunning {
            steeringQueue.append(cleaned)
            appendTrace(kind: .steer, title: "Steer queued", detail: cleaned)
            return
        }
        startGoal(cleaned)
    }

    func enqueue(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !isRunning {
            startGoal(cleaned)
        } else {
            queuedFollowUps.append(cleaned)
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        BackgroundKeepAlive.shared.release()
        appendTrace(kind: .error, title: "Cancelled", detail: "User stopped active run")
    }

    func clearTrace() {
        trace.removeAll()
        stepCount = 0
        lastFinalReply = ""
    }

    func runOneShotFromMCP(goal: String) async -> String {
        if isRunning {
            return "Grogu agent is currently busy (step \(stepCount)). Retry once idle or steer explicitly."
        }
        return await executeGoalLoop(goal)
    }

    // MARK: - Execution Loop

    private func startGoal(_ goal: String) {
        currentTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.executeGoalLoop(goal)
            if !Task.isCancelled, let next = self.queuedFollowUps.first {
                self.queuedFollowUps.removeFirst()
                self.startGoal(next)
            }
        }
    }

    private func executeGoalLoop(_ goal: String) async -> String {
        guard !isRunning else { return "Busy" }
        let apiKey = KeychainVault.loadString(account: Self.apiKeyAccount) ?? ""
        guard !apiKey.isEmpty else {
            let msg = "No LLM API key configured. Add an OpenAI/OpenRouter or Anthropic key in Setup."
            appendTrace(kind: .error, title: "Missing API Key", detail: msg)
            return msg
        }

        isRunning = true
        stepCount = 0
        steeringQueue.removeAll()
        BackgroundKeepAlive.shared.acquire(reason: "AgentLoop")
        defer {
            isRunning = false
            BackgroundKeepAlive.shared.release()
        }

        appendTrace(kind: .user, title: "Goal", detail: goal)

        let systemPrompt = buildSystemPrompt()
        var history: [ModelClient.ChatMessage] = [
            .init(role: .system, text: systemPrompt),
            .init(role: .user, text: goal),
        ]

        let maxSteps = max(2, min(config.maxSteps, 40))

        for step in 1...maxSteps {
            if Task.isCancelled { break }
            stepCount = step

            // Inject any pending mid-run user steering immediately
            if !steeringQueue.isEmpty {
                let steers = steeringQueue.joined(separator: "\n")
                steeringQueue.removeAll()
                history.append(.init(role: .user, text: "[USER STEERING INSTRUCTION]: \(steers)"))
            }

            // Jetsam budget check: strip older screenshots/base64 before sending
            pruneHistory(&history)
            let availableTools = collectAvailableTools()

            let output: ModelClient.TurnOutput
            do {
                output = try await modelClient.complete(
                    config: config,
                    apiKey: apiKey,
                    messages: history,
                    tools: availableTools
                )
            } catch {
                let errMsg = LogRedactor.sanitize(error.localizedDescription, maxChars: 600)
                appendTrace(kind: .error, title: "Model Error (step \(step))", detail: errMsg)
                lastFinalReply = "Error: \(errMsg)"
                return lastFinalReply
            }

            if !output.assistantText.isEmpty && output.toolCalls.isEmpty {
                let safeReply = LogRedactor.sanitize(output.assistantText, maxChars: 4000)
                lastFinalReply = safeReply
                appendTrace(kind: .assistant, title: "Final Answer", detail: safeReply)
                return safeReply
            }

            history.append(.init(role: .assistant, text: output.assistantText, toolCalls: output.toolCalls))
            if !output.assistantText.isEmpty {
                appendTrace(kind: .assistant, title: "Thought (step \(step))", detail: output.assistantText)
            }

            if output.toolCalls.isEmpty {
                lastFinalReply = "Completed step \(step)."
                return lastFinalReply
            }

            for call in output.toolCalls {
                if Task.isCancelled { break }
                appendTrace(
                    kind: .tool,
                    title: call.name,
                    detail: LogRedactor.sanitize(JSONValue.object(call.arguments).prettyJSONString(maxBytes: 400))
                )

                let toolResult = await dispatchTool(name: call.name, arguments: call.arguments)
                let summaryText = toolResult.flattenedText(maxChars: 10_000)
                appendTrace(kind: .tool, title: "Result: \(call.name)", detail: String(summaryText.prefix(500)))

                history.append(.init(
                    role: .tool,
                    text: summaryText,
                    toolCallID: call.id,
                    toolName: call.name
                ))

                // If the tool produced a fresh JPEG screenshot, attach it only in this transient user observation
                if let imgBlock = toolResult.content.first(where: { $0.type == "image" }),
                   let b64 = imgBlock.data,
                   MemorySnapshot.current().pressure != .critical {
                    history.append(.init(
                        role: .user,
                        text: "Fresh screenshot from `\(call.name)`.",
                        imageBase64: b64
                    ))
                }
            }
        }

        let timeoutMsg = "Reached maxSteps (\(maxSteps))."
        lastFinalReply = timeoutMsg
        appendTrace(kind: .assistant, title: "Paused", detail: timeoutMsg)
        return timeoutMsg
    }

    // MARK: - Tool Aggregation & Dispatch

    private func collectAvailableTools() -> [MCPToolDescriptor] {
        let localMeta: [MCPToolDescriptor] = [
            MCPToolDescriptor(
                name: "grogu_memory_read",
                description: "Read Workspace MEMORY.md.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            MCPToolDescriptor(
                name: "grogu_memory_append",
                description: "Append a durable fact or preference to Workspace MEMORY.md.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["note": .object(["type": .string("string")])]),
                    "required": .array([.string("note")]),
                ])
            ),
            MCPToolDescriptor(
                name: "skill_read",
                description: "Load instructions from a named Workspace skill file.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["name": .object(["type": .string("string")])]),
                    "required": .array([.string("name")]),
                ])
            ),
        ]
        let runnerReady = (RunnerLauncher.shared.state == .ready || RunnerLauncher.shared.sessionToken != nil)
        let runnerTools = runnerReady ? MCPServerService.runnerToolSchemas : []
        let remoteMCPTools = MCPClientHub.shared.allRemoteTools.map { t in
            MCPToolDescriptor(name: t.namespacedName, description: "[\(t.serverName)] \(t.description)", inputSchema: t.inputSchema)
        }
        return NativeSystemTools.toolSchemas + localMeta + runnerTools + remoteMCPTools
    }

    private func dispatchTool(name: String, arguments: [String: JSONValue]) async -> MCPToolCallResult {
        if name == "skill_read" {
            let sName = arguments.string("name") ?? ""
            if let doc = WorkspaceStore.shared.skills.first(where: { $0.name == sName }) {
                return .text(doc.content)
            }
            return .error("Skill '\(sName)' not found")
        }
        if name.hasPrefix("mcp__") {
            return await MCPClientHub.shared.callTool(namespacedName: name, arguments: arguments)
        }
        return await MCPServerService.shared.executeMCPTool(name: name, arguments: arguments)
    }

    // MARK: - Bounded Context & Memory Pruning

    private func pruneHistory(_ history: inout [ModelClient.ChatMessage]) {
        // Strip old screenshot base64 blobs so at most the most recent screenshot remains in context.
        var keptLatestImage = false
        for idx in history.indices.reversed() {
            let hasImage = history[idx].parts.contains {
                if case .imageJPEG = $0 { return true }
                return false
            }
            if hasImage {
                if keptLatestImage {
                    history[idx] = .init(
                        role: history[idx].role,
                        text: history[idx].plainText + " [older screenshot omitted to save RAM]"
                    )
                } else {
                    keptLatestImage = true
                }
            }
        }
        // Keep system + user goal + trailing 24 turns
        if history.count > 26 {
            let head = Array(history.prefix(2))
            let tail = Array(history.suffix(24))
            history = head + tail
        }
    }

    private func buildSystemPrompt() -> String {
        let runnerState = RunnerLauncher.shared.state == .ready ? "READY (127.0.0.1:18831)" : "NOT_RUNNING"
        return """
        \(WorkspaceStore.shared.buildSystemPromptAdditions())

        ## Runtime Context
        - Device OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - GroguRunner UI Automation: \(runnerState)
        - Connected External MCP Tools: \(MCPClientHub.shared.allRemoteTools.count)
        - Current Time (ISO8601): \(ISO8601DateFormatter().string(from: Date()))
        """
    }

    private func appendTrace(kind: TraceItem.Kind, title: String, detail: String) {
        let item = TraceItem(
            timestamp: Date(),
            kind: kind,
            title: title,
            detail: LogRedactor.sanitize(detail, maxChars: 1200)
        )
        trace.append(item)
        if trace.count > 150 {
            trace.removeFirst(trace.count - 150)
        }
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.endpointConfigKey)
        }
    }
}
