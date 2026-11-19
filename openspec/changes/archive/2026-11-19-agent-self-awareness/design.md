## Context

GroguApp (SwiftUI, iOS 17+, Swift 5 mode, `@MainActor @Observable` singletons). No Swift toolchain on the dev host; compile verification runs in GitHub Actions (`ios-build.yml`, macOS 15).

## Goals / Non-Goals

**Goals:** fix the five root causes of the failed local run with the smallest code change.
**Non-Goals:** UI redesign; changing the MCP wire protocol; changing GroguRunner.

## Decisions

- **Identity lives in code, not SOUL.md.** Existing installs already have SOUL.md on disk, so the default text is never re-applied. `AgentRuntime.buildSystemPrompt()` prepends a fixed identity block and a live context block built by `SelfManagementTools.runtimeContext()`.
- **One new file `SelfManagementTools.swift`** (`@MainActor enum`) holds schemas, execution, network-interface and permission probes. `AgentRuntime` and `MCPServerService` only wire it in.
- **Bearer token never reaches the model.** `mcp_server_manage copy_config` writes the client JSON (with token) to the clipboard and returns the JSON with the token replaced by `<copied-to-clipboard>`. The system prompt and `grogu_self_info` state only "Bearer token required".
- **Remote exposure of the new tools.** Inbound MCP clients get `grogu_self_info`, `permissions_status`, `runner_wake`, `app_scheme_probe`. `mcp_server_manage` and `mcp_client_manage` are local-agent-only: `MCPServerService.executeMCPTool` rejects them; `AgentRuntime.dispatchTool` routes them directly. Runs started via `grogu_agent_run` do not get the local-only tools.
- **`allowRemoteAccess` stays a user setting.** Auto-start honours the saved value. `mcp_server_manage set_remote_access` may change it (server restarts); every request still needs the bearer token.
- **Runner tools are always listed.** A failed `ios_*` call with the runner down returns the existing error plus "call `runner_wake`". `runner_wake` opens `grogu-runner://start?...` and polls `refreshHealth()` for up to 10 s.
- **Permission probe is read-only by default.** `permissions_status` returns states; optional `request: [..]` triggers the system prompt only for `not_determined` entries.
- **Network probe** uses `getifaddrs`: IPv4 on `en*` = LAN, IPv4 in 100.64.0.0/10 on `utun*` = Tailscale.

## Risks / Trade-offs

- Cannot compile locally → CI build is the gate; device behaviour needs a manual run on the iPad.
- `UIApplication.open` only works while GroguApp is foreground; `runner_wake` from a backgrounded app reports failure instead of hanging.
