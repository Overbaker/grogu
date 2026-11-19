## 1. Self-awareness and self-management

- [x] 1.1 Add `ios/GroguApp/Agent/SelfManagementTools.swift`: tool schemas, execution, network-interface probe, permission probe, `runtimeContext()`
- [x] 1.2 Wire into `AgentRuntime`: identity + runtime context in system prompt, new tools in `collectAvailableTools`/`dispatchTool`, runner tools always listed
- [x] 1.3 Wire into `MCPServerService`: expose the remote-safe subset in `tools/list` and `/health`, reject local-only tools, add `runner_wake` hint to runner errors
- [x] 1.4 Auto-start MCP server in `GroguApp.swift` (launch + scene active)
- [x] 1.5 Extend `LSApplicationQueriesSchemes` in `Info.plist`; refresh default SOUL/skill text in `WorkspaceStore.swift`; bump `MARKETING_VERSION` to 1.1.0 in `project.yml`
