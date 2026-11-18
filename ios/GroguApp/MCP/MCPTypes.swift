import Foundation

/// Clean-room Model Context Protocol (`2025-03-26`) Codable types shared by
/// both `MCPClientHub` (outbound) and `MCPServerService` (inbound).
enum MCPProtocol {
    static let version = "2025-03-26"
}

struct MCPServerConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    var slug: String
    var endpointURL: String
    var isEnabled: Bool
    var lastConnectedAt: Date?
    var lastToolCount: Int
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        endpointURL: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.slug = Self.makeSlug(name)
        self.endpointURL = endpointURL
        self.isEnabled = isEnabled
        self.lastToolCount = 0
    }

    static func makeSlug(_ text: String) -> String {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "mcp" : String(cleaned.prefix(24))
    }
}

struct MCPToolDescriptor: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let inputSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema
    }
}

struct MCPResourceDescriptor: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String { uri }
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
}

struct MCPContentBlock: Codable, Equatable, Sendable {
    let type: String
    let text: String?
    let data: String?
    let mimeType: String?

    static func text(_ value: String) -> MCPContentBlock {
        MCPContentBlock(type: "text", text: value, data: nil, mimeType: nil)
    }

    static func image(base64JPEG: String) -> MCPContentBlock {
        MCPContentBlock(type: "image", text: nil, data: base64JPEG, mimeType: "image/jpeg")
    }
}

struct MCPToolCallResult: Codable, Equatable, Sendable {
    let content: [MCPContentBlock]
    let isError: Bool?

    static func json(_ object: [String: JSONValue]) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text(JSONValue.object(object).prettyJSONString(maxBytes: 24_000))], isError: false)
    }

    static func text(_ message: String) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text(message)], isError: false)
    }

    static func error(_ message: String) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text("ERROR: \(message)")], isError: true)
    }

    func flattenedText(maxChars: Int = 12_000) -> String {
        let joined = content.compactMap { block -> String? in
            if let text = block.text { return text }
            if block.type == "image" { return "[image/jpeg base64 attached]" }
            return nil
        }.joined(separator: "\n")
        return LogRedactor.sanitize(joined, maxChars: maxChars)
    }
}

struct MCPJSONRPCRequest: Codable, Sendable {
    var jsonrpc: String = "2.0"
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

struct MCPJSONRPCErrorPayload: Codable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?
}

struct MCPJSONRPCResponse: Codable, Sendable {
    var jsonrpc: String = "2.0"
    let id: JSONValue?
    let result: JSONValue?
    let error: MCPJSONRPCErrorPayload?
}
