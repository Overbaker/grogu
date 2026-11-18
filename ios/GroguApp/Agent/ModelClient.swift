import Foundation

/// Zero-dependency OpenAI-compatible (`/chat/completions`) and Anthropic (`/messages`) client
/// supporting tool calls and bounded multimodal base64 JPEG attachments.
struct ModelClient: Sendable {
    enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
        case openAICompatible = "OpenAI-Compatible"
        case anthropic = "Anthropic"
        var id: String { rawValue }
    }

    struct EndpointConfig: Codable, Equatable, Sendable {
        var provider: Provider
        var baseURL: String
        var model: String
        var maxOutputTokens: Int
        var maxSteps: Int
    }

    enum ContentPart: Sendable {
        case text(String)
        case imageJPEG(base64: String)
    }

    struct ToolCall: Sendable, Identifiable {
        let id: String
        let name: String
        let arguments: [String: JSONValue]
    }

    struct ChatMessage: Sendable {
        enum Role: String, Sendable {
            case system
            case user
            case assistant
            case tool
        }
        let role: Role
        let parts: [ContentPart]
        let toolCalls: [ToolCall]
        let toolCallID: String?
        let toolName: String?

        init(
            role: Role,
            text: String,
            imageBase64: String? = nil,
            toolCalls: [ToolCall] = [],
            toolCallID: String? = nil,
            toolName: String? = nil
        ) {
            self.role = role
            var p: [ContentPart] = [.text(text)]
            if let imageBase64, !imageBase64.isEmpty {
                p.append(.imageJPEG(base64: imageBase64))
            }
            self.parts = p
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
            self.toolName = toolName
        }

        var plainText: String {
            parts.compactMap { part in
                if case .text(let s) = part { return s }
                return nil
            }.joined(separator: "\n")
        }
    }

    struct TurnOutput: Sendable {
        let assistantText: String
        let toolCalls: [ToolCall]
        let finishReason: String
    }

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    func complete(
        config: EndpointConfig,
        apiKey: String,
        messages: [ChatMessage],
        tools: [MCPToolDescriptor]
    ) async throws -> TurnOutput {
        switch config.provider {
        case .openAICompatible:
            return try await completeOpenAI(config: config, apiKey: apiKey, messages: messages, tools: tools)
        case .anthropic:
            return try await completeAnthropic(config: config, apiKey: apiKey, messages: messages, tools: tools)
        }
    }

    // MARK: - OpenAI /v1/chat/completions

    private func completeOpenAI(
        config: EndpointConfig,
        apiKey: String,
        messages: [ChatMessage],
        tools: [MCPToolDescriptor]
    ) async throws -> TurnOutput {
        let endpoint = Self.appendPath(config.baseURL, suffix: "chat/completions")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let encodedMsgs: [JSONValue] = messages.map { msg in
            var obj: [String: JSONValue] = ["role": .string(msg.role.rawValue)]
            if msg.role == .tool {
                obj["tool_call_id"] = .string(msg.toolCallID ?? "")
                obj["content"] = .string(msg.plainText)
                return .object(obj)
            }
            if !msg.toolCalls.isEmpty {
                obj["content"] = msg.plainText.isEmpty ? .null : .string(msg.plainText)
                obj["tool_calls"] = .array(msg.toolCalls.map { tc in
                    .object([
                        "id": .string(tc.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(tc.name),
                            "arguments": .string(JSONValue.object(tc.arguments).prettyJSONString()),
                        ]),
                    ])
                })
                return .object(obj)
            }
            let hasImages = msg.parts.contains { if case .imageJPEG = $0 { return true }; return false }
            if !hasImages {
                obj["content"] = .string(msg.plainText)
            } else {
                let partsJSON: [JSONValue] = msg.parts.map { part in
                    switch part {
                    case .text(let t):
                        return .object(["type": .string("text"), "text": .string(t)])
                    case .imageJPEG(let b64):
                        return .object([
                            "type": .string("image_url"),
                            "image_url": .object([
                                "url": .string("data:image/jpeg;base64,\(b64)"),
                                "detail": .string("auto"),
                            ]),
                        ])
                    }
                }
                obj["content"] = .array(partsJSON)
            }
            return .object(obj)
        }

        var bodyObj: [String: JSONValue] = [
            "model": .string(config.model),
            "messages": .array(encodedMsgs),
            "max_tokens": .int(max(256, config.maxOutputTokens)),
            "temperature": .double(0.2),
        ]
        if !tools.isEmpty {
            bodyObj["tools"] = .array(tools.map { t in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(t.name),
                        "description": .string(String(t.description.prefix(500))),
                        "parameters": t.inputSchema,
                    ]),
                ])
            })
        }

        req.httpBody = try JSONEncoder().encode(JSONValue.object(bodyObj))
        let (data, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let errText = LogRedactor.sanitize(String(data: data.prefix(600), encoding: .utf8) ?? "")
            throw NSError(domain: "GroguModel", code: code, userInfo: [NSLocalizedDescriptionKey: "LLM HTTP \(code): \(errText)"])
        }

        guard let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let firstChoice = root["choices"]?.arrayValue?.first?.objectValue,
              let messageObj = firstChoice["message"]?.objectValue else {
            throw NSError(domain: "GroguModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Malformed OpenAI response"])
        }

        let assistantText = messageObj["content"]?.stringValue ?? ""
        let finishReason = firstChoice["finish_reason"]?.stringValue ?? "stop"
        var parsedCalls: [ToolCall] = []
        if let rawCalls = messageObj["tool_calls"]?.arrayValue {
            for call in rawCalls {
                guard let cObj = call.objectValue,
                      let id = cObj["id"]?.stringValue,
                      let fn = cObj["function"]?.objectValue,
                      let name = fn["name"]?.stringValue else { continue }
                let argsString = fn["arguments"]?.stringValue ?? "{}"
                let argsObj: [String: JSONValue]
                if let argsData = argsString.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: argsData) {
                    argsObj = decoded
                } else {
                    argsObj = [:]
                }
                parsedCalls.append(ToolCall(id: id, name: name, arguments: argsObj))
            }
        }
        return TurnOutput(assistantText: assistantText, toolCalls: parsedCalls, finishReason: finishReason)
    }

    // MARK: - Anthropic /v1/messages

    private func completeAnthropic(
        config: EndpointConfig,
        apiKey: String,
        messages: [ChatMessage],
        tools: [MCPToolDescriptor]
    ) async throws -> TurnOutput {
        let endpoint = Self.appendPath(config.baseURL, suffix: "messages")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let systemPrompt = messages
            .filter { $0.role == .system }
            .map(\.plainText)
            .joined(separator: "\n\n")

        var anthropicMsgs: [JSONValue] = []
        for msg in messages where msg.role != .system {
            if msg.role == .tool {
                anthropicMsgs.append(.object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("tool_result"),
                            "tool_use_id": .string(msg.toolCallID ?? ""),
                            "content": .string(msg.plainText),
                        ]),
                    ]),
                ]))
                continue
            }
            var blocks: [JSONValue] = []
            for part in msg.parts {
                switch part {
                case .text(let s) where !s.isEmpty:
                    blocks.append(.object(["type": .string("text"), "text": .string(s)]))
                case .imageJPEG(let b64):
                    blocks.append(.object([
                        "type": .string("image"),
                        "source": .object([
                            "type": .string("base64"),
                            "media_type": .string("image/jpeg"),
                            "data": .string(b64),
                        ]),
                    ]))
                default:
                    break
                }
            }
            for tc in msg.toolCalls {
                blocks.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(tc.id),
                    "name": .string(tc.name),
                    "input": .object(tc.arguments),
                ]))
            }
            anthropicMsgs.append(.object([
                "role": .string(msg.role == .assistant ? "assistant" : "user"),
                "content": .array(blocks.isEmpty ? [.object(["type": .string("text"), "text": .string("")])] : blocks),
            ]))
        }

        var bodyObj: [String: JSONValue] = [
            "model": .string(config.model),
            "max_tokens": .int(max(256, config.maxOutputTokens)),
            "messages": .array(anthropicMsgs),
        ]
        if !systemPrompt.isEmpty {
            bodyObj["system"] = .string(systemPrompt)
        }
        if !tools.isEmpty {
            bodyObj["tools"] = .array(tools.map { t in
                .object([
                    "name": .string(t.name),
                    "description": .string(String(t.description.prefix(500))),
                    "input_schema": t.inputSchema,
                ])
            })
        }

        req.httpBody = try JSONEncoder().encode(JSONValue.object(bodyObj))
        let (data, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let errText = LogRedactor.sanitize(String(data: data.prefix(600), encoding: .utf8) ?? "")
            throw NSError(domain: "GroguModel", code: code, userInfo: [NSLocalizedDescriptionKey: "Anthropic HTTP \(code): \(errText)"])
        }

        guard let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            throw NSError(domain: "GroguModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Malformed Anthropic response"])
        }

        let contentBlocks = root["content"]?.arrayValue ?? []
        var textParts: [String] = []
        var toolCalls: [ToolCall] = []
        for b in contentBlocks {
            guard let obj = b.objectValue, let t = obj["type"]?.stringValue else { continue }
            if t == "text", let txt = obj["text"]?.stringValue {
                textParts.append(txt)
            } else if t == "tool_use",
                      let id = obj["id"]?.stringValue,
                      let name = obj["name"]?.stringValue {
                let inputObj = obj["input"]?.objectValue ?? [:]
                toolCalls.append(ToolCall(id: id, name: name, arguments: inputObj))
            }
        }
        return TurnOutput(
            assistantText: textParts.joined(separator: "\n"),
            toolCalls: toolCalls,
            finishReason: root["stop_reason"]?.stringValue ?? "end_turn"
        )
    }

    private static func appendPath(_ baseURL: String, suffix: String) -> URL {
        let cleaned = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(cleaned)/\(suffix)") ?? URL(string: "https://openrouter.ai/api/v1/\(suffix)")!
    }
}
