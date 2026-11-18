import SwiftUI

struct ConsoleView: View {
    @State private var runtime = AgentRuntime.shared
    @State private var jetsam = JetsamGuard.shared
    @State private var runner = RunnerLauncher.shared
    @State private var mcpServer = MCPServerService.shared
    @State private var promptText = ""

    private let quickPresets = [
        "Check battery, RAM footprint & device status natively",
        "Show my next 5 calendar events & open reminders",
        "Inspect current screen UI tree & summarize visible actions",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                telemetryStrip
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if runtime.trace.isEmpty {
                                emptyStateCard
                            } else {
                                ForEach(runtime.trace) { item in
                                    TraceBubble(item: item)
                                        .id(item.id)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: runtime.trace.count) { _, _ in
                        if let last = runtime.trace.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()
                inputBar
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Grogu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !runtime.trace.isEmpty {
                        Button("Clear") {
                            runtime.clearTrace()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var telemetryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                GlassPill(
                    icon: "memorychip",
                    label: String(format: "%.1f MB / %.0f free", jetsam.snapshot.physFootprintMB, jetsam.snapshot.availableMB),
                    tint: GroguTheme.pressureColor(jetsam.snapshot.pressure)
                )
                GlassPill(
                    icon: runner.state == .ready ? "bolt.fill" : "bolt.slash",
                    label: runner.state == .ready ? "Runner :18831" : "Runner Idle",
                    tint: runner.state == .ready ? GroguTheme.accent : .secondary
                )
                GlassPill(
                    icon: "network",
                    label: mcpServer.isRunning ? "MCP :\(mcpServer.port)" : "MCP Off",
                    tint: mcpServer.isRunning ? GroguTheme.accent : .secondary
                )
                if runtime.isRunning {
                    GlassPill(
                        icon: "sparkles",
                        label: "Step \(runtime.stepCount)",
                        tint: GroguTheme.warning
                    )
                }
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard("Native-First On-Device Agent") {
                Text("Grogu prioritizes fast native iOS APIs and connected MCP tools before falling back to synthesized XCUITest GUI actions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !runtime.hasAPIKey {
                    Label("Add your OpenRouter / OpenAI / Anthropic API key in the Bootstrap tab to begin.", systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(GroguTheme.warning)
                }
            }

            SectionCard("Quick Start") {
                ForEach(quickPresets, id: \.self) { preset in
                    Button {
                        promptText = preset
                    } label: {
                        HStack {
                            Text(preset)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 12)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !runtime.queuedFollowUps.isEmpty {
                HStack {
                    Text("Queued follow-ups: \(runtime.queuedFollowUps.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    runtime.isRunning ? "Steer active run or press Queue..." : "Ask Grogu or trigger an iOS task...",
                    text: $promptText,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if runtime.isRunning {
                    Button {
                        let txt = promptText
                        promptText = ""
                        runtime.submitOrSteer(txt)
                    } label: {
                        Image(systemName: "arrow.turn.right.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(GroguTheme.warning.opacity(0.18), in: Circle())
                            .foregroundStyle(GroguTheme.warning)
                    }
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        runtime.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(GroguTheme.critical.opacity(0.18), in: Circle())
                            .foregroundStyle(GroguTheme.critical)
                    }
                } else {
                    Button {
                        let txt = promptText
                        promptText = ""
                        runtime.submitOrSteer(txt)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(GroguTheme.accent, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

private struct TraceBubble: View {
    let item: AgentRuntime.TraceItem

    private var accentColor: Color {
        switch item.kind {
        case .user: return .primary
        case .steer: return GroguTheme.warning
        case .tool: return GroguTheme.accent
        case .assistant: return .blue
        case .error: return GroguTheme.critical
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
                Spacer()
                Text(item.timestamp, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(item.detail)
                .font(item.kind == .tool ? .caption.monospaced() : .subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentColor.opacity(0.18), lineWidth: 0.8)
        )
    }
}
