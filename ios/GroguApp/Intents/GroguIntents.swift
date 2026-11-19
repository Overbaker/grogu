import AppIntents
import Foundation

struct AskGroguIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Grogu"
    static let description = IntentDescription("Run an autonomous goal on this iPhone or iPad via Grogu.")

    @Parameter(title: "Goal")
    var goal: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = await AgentRuntime.shared.runOneShotLocal(goal: goal)
        return .result(value: reply, dialog: IntentDialog(stringLiteral: String(reply.prefix(240))))
    }
}

struct StartGroguMCPServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Grogu MCP Server"
    static let description = IntentDescription("Start the on-device Streamable HTTP MCP server.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MCPServerService.shared.start()
        return .result(dialog: "Grogu MCP Server starting on port \(MCPServerService.shared.port).")
    }
}

struct GroguShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskGroguIntent(),
            phrases: ["Ask \(.applicationName)", "Run \(.applicationName)"],
            shortTitle: "Ask Grogu",
            systemImageName: "cpu"
        )
        AppShortcut(
            intent: StartGroguMCPServerIntent(),
            phrases: ["Start \(.applicationName) MCP"],
            shortTitle: "Start MCP Server",
            systemImageName: "network"
        )
    }
}
