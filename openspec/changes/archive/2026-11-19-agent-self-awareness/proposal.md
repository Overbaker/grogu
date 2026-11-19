## Why

On-device run "为 grokbot 加载你的 MCP" (2026-11-18) failed: the local agent did not know it is GroguApp, did not know it hosts its own MCP server (`:18832/mcp`, shown as `MCP Off`), had no device/network/permission context, lost all `ios_*` tools because GroguRunner was idle, and had no tool to fix any of it.

## What Changes

- Auto-start the inbound MCP server on app launch and when the app returns to foreground.
- Inject identity + live runtime context into the agent system prompt: own MCP server state/URLs/auth scheme, network interfaces (Wi-Fi, Tailscale), iOS permission states, runner state, external MCP servers, detected sibling apps, and the loopback-vs-cloud reachability rule.
- Add self-management tools for the local agent: `grogu_self_info`, `mcp_server_manage`, `mcp_client_manage`, `permissions_status`, `runner_wake`, `app_scheme_probe`.
- Always offer `ios_*` runner tools to the local agent; when the runner is down they fail with a hint to call `runner_wake`.
- Extend `LSApplicationQueriesSchemes` so sibling apps (Grok Bot etc.) are detectable.
- Bump GroguApp to 1.1.0.

## Capabilities

### New Capabilities
- `agent-self-awareness`: identity, runtime context and self-management tools of the on-device agent.

### Modified Capabilities

## Impact

- `ios/GroguApp/Agent/AgentRuntime.swift`, new `ios/GroguApp/Agent/SelfManagementTools.swift`, `ios/GroguApp/Agent/WorkspaceStore.swift`
- `ios/GroguApp/MCP/MCPServerService.swift`, `ios/GroguApp/UI/GroguApp.swift`, `ios/GroguApp/Info.plist`, `ios/project.yml`
- No new dependencies. UI redesign (single-page chat) is out of scope.
