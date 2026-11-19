# agent-self-awareness Specification

## Purpose
TBD - created by archiving change agent-self-awareness. Update Purpose after archive.

## Requirements

### Requirement: MCP server auto-start
GroguApp SHALL start its inbound MCP server at launch and whenever the app becomes active while the server is not running, using the saved port and remote-access setting.

#### Scenario: Cold launch
- **WHEN** the app process starts
- **THEN** the MCP server listens on the saved port without user interaction

#### Scenario: Return to foreground after listener died
- **WHEN** the scene becomes active and the server is not running
- **THEN** the server is started again

### Requirement: Identity and runtime context in the system prompt
The agent system prompt SHALL state that the agent is GroguApp hosting its own MCP server, and SHALL include the server state, port, reachable URLs per network interface, auth scheme, runner state, permission states, configured external MCP servers and detected sibling apps. It SHALL NOT contain the bearer token.

#### Scenario: Prompt without secrets
- **WHEN** the system prompt is built
- **THEN** it contains "GroguApp" and the MCP port and does not contain the bearer token string

### Requirement: Self-management tools
The local agent SHALL be offered `grogu_self_info`, `mcp_server_manage`, `mcp_client_manage`, `permissions_status`, `runner_wake` and `app_scheme_probe`. Tool results SHALL NOT contain the inbound bearer token or stored outbound tokens.

#### Scenario: Copy own MCP config
- **WHEN** the agent calls `mcp_server_manage` with `action=copy_config`
- **THEN** the full client config including the token is placed on the clipboard and the returned text has the token redacted

#### Scenario: Remote client calls a local-only tool
- **WHEN** an inbound MCP client calls `mcp_server_manage` or `mcp_client_manage`
- **THEN** the call is rejected with an error and no state changes

### Requirement: Runner tools always offered
The local agent SHALL be offered the `ios_*` tools regardless of runner state, and a call made while the runner is unreachable SHALL return an error that names `runner_wake`.

#### Scenario: Runner idle
- **WHEN** the runner is not running and the agent lists tools
- **THEN** the `ios_*` tools and `runner_wake` are present

### Requirement: Sibling app detection
GroguApp SHALL declare the URL schemes it probes in `LSApplicationQueriesSchemes`, including `grokbot` and `sand-mobile`.

#### Scenario: Probe declared scheme
- **WHEN** `app_scheme_probe` is called with a declared scheme
- **THEN** it returns whether an installed app handles it
