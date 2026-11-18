import SwiftUI
import UIKit

struct MCPCenterView: View {
    @State private var server = MCPServerService.shared
    @State private var clientHub = MCPClientHub.shared
    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newToken = ""
    @State private var revealToken = false
    @State private var copiedNotice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    inboundServerCard
                    outboundClientsCard
                }
                .padding(14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MCP Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                addServerSheet
            }
        }
    }

    private var inboundServerCard: some View {
        SectionCard("Inbound MCP Server (Exposes this iPhone/iPad)") {
            HStack {
                Label(
                    server.isRunning ? "Listening on :\(server.port) (/mcp)" : "Server Stopped",
                    systemImage: server.isRunning ? "checkmark.circle.fill" : "pause.circle"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(server.isRunning ? GroguTheme.accent : .secondary)

                Spacer()

                Button(server.isRunning ? "Stop" : "Start") {
                    if server.isRunning {
                        server.stop()
                    } else {
                        server.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(server.isRunning ? GroguTheme.critical : GroguTheme.accent)
                .controlSize(.small)
            }

            Toggle("Allow Tailscale / LAN Access (0.0.0.0)", isOn: $server.allowRemoteAccess)
                .font(.subheadline)
                .disabled(server.isRunning)

            HStack {
                Text("Port")
                    .font(.subheadline)
                Spacer()
                TextField("18832", value: $server.port, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .disabled(server.isRunning)
            }

            HStack {
                Text("Bearer Token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(revealToken ? server.bearerToken : "••••••••••••••••")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(revealToken ? "Hide" : "Show") {
                    revealToken.toggle()
                }
                .font(.caption)
            }

            HStack(spacing: 10) {
                Button {
                    let snippet = """
                    {
                      "grogu-ios": {
                        "type": "http",
                        "url": "http://127.0.0.1:\(server.port)/mcp",
                        "headers": {
                          "Authorization": "Bearer \(server.bearerToken)"
                        }
                      }
                    }
                    """
                    UIPasteboard.general.string = snippet
                    copiedNotice = true
                } label: {
                    Label(copiedNotice ? "Copied Config" : "Copy MCP JSON", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Rotate Token") {
                    server.rotateBearerToken()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("\(server.requestCount) reqs")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let err = server.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(GroguTheme.critical)
            }
        }
    }

    private var outboundClientsCard: some View {
        SectionCard("Outbound MCP Clients (Tools Grogu Can Call)") {
            HStack {
                Text("\(clientHub.allRemoteTools.count) remote tools ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await clientHub.refreshAllEnabled() }
                } label: {
                    if clientHub.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync All", systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption)
                .disabled(clientHub.isRefreshing)
            }

            if clientHub.servers.isEmpty {
                Text("Tap + to connect any Streamable HTTP MCP server (e.g. Tailscale/LAN host tools, Finance Ledger, GitNexus).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(clientHub.servers) { cfg in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle(isOn: Binding(
                                get: { cfg.isEnabled },
                                set: { clientHub.toggleServer(id: cfg.id, enabled: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cfg.name)
                                        .font(.subheadline.weight(.medium))
                                    Text(cfg.endpointURL)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }

                        HStack {
                            Text("Tools: \(cfg.lastToolCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let err = cfg.lastError {
                                Text("• \(err)")
                                    .font(.caption2)
                                    .foregroundStyle(GroguTheme.critical)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Sync") {
                                Task { await clientHub.connectAndSync(serverID: cfg.id) }
                            }
                            .font(.caption)
                            Button("Remove", role: .destructive) {
                                clientHub.removeServer(id: cfg.id)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private var addServerSheet: some View {
        NavigationStack {
            Form {
                Section("Streamable HTTP MCP Endpoint") {
                    TextField("Name (e.g. Home Mac MCP)", text: $newName)
                    TextField("https://host.example/mcp or http://100.x.x.x:8080/mcp", text: $newURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Bearer Token (optional, stored in Keychain)", text: $newToken)
                }
            }
            .navigationTitle("Add MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        clientHub.addServer(name: newName, endpointURL: newURL, bearerToken: newToken)
                        newName = ""
                        newURL = ""
                        newToken = ""
                        showAddSheet = false
                        Task { await clientHub.refreshAllEnabled() }
                    }
                    .disabled(newName.isEmpty || newURL.isEmpty)
                }
            }
        }
    }
}
