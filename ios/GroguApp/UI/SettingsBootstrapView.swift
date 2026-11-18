import SwiftUI

struct SettingsBootstrapView: View {
    @State private var runtime = AgentRuntime.shared
    @State private var ddiMounter = DDIMounter.shared
    @State private var ddiStore = DeveloperDiskImageStore.shared
    @State private var runner = RunnerLauncher.shared
    @State private var jetsam = JetsamGuard.shared

    @State private var apiKeyInput = ""
    @State private var showingPairingPicker = false
    @State private var pairingAlert: String?

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                ddiBootstrapSection
                runnerControlSection
                memoryGovernanceSection
            }
            .navigationTitle("Bootstrap & Model")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showingPairingPicker,
                allowedContentTypes: PairingFileStore.supportedContentTypes
            ) { result in
                switch result {
                case .success(let url):
                    do {
                        try PairingFileStore.importFile(from: url)
                        pairingAlert = "RemotePairing file imported cleanly."
                    } catch {
                        pairingAlert = error.localizedDescription
                    }
                case .failure(let err):
                    pairingAlert = err.localizedDescription
                }
            }
            .alert("Pairing Record", isPresented: Binding(
                get: { pairingAlert != nil },
                set: { if !$0 { pairingAlert = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(pairingAlert ?? "")
            }
        }
    }

    private var modelSection: some View {
        Section("Agent Model Endpoint") {
            Picker("Provider", selection: $runtime.config.provider) {
                ForEach(ModelClient.Provider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            TextField("Base URL (e.g. https://openrouter.ai/api/v1)", text: $runtime.config.baseURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Model ID", text: $runtime.config.model)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Stepper("Max Steps: \(runtime.config.maxSteps)", value: $runtime.config.maxSteps, in: 2...40)

            HStack {
                SecureField(runtime.hasAPIKey ? "API Key saved in Keychain (paste to update)" : "Enter API Key", text: $apiKeyInput)
                Button("Save") {
                    runtime.updateAPIKey(apiKeyInput)
                    apiKeyInput = ""
                }
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var ddiBootstrapSection: some View {
        Section("On-Device Developer Disk Image (\(DeveloperDiskImageStore.mountMethod.rawValue))") {
            HStack {
                Label(
                    PairingFileStore.exists ? "RemotePairing File Ready" : "No Pairing File",
                    systemImage: PairingFileStore.exists ? "checkmark.seal.fill" : "exclamationmark.triangle"
                )
                .foregroundStyle(PairingFileStore.exists ? GroguTheme.accent : GroguTheme.warning)
                Spacer()
                Button("Import") { showingPairingPicker = true }
            }

            HStack {
                Text("LocalDevVPN Tunnel (10.7.0.1)")
                Spacer()
                Button(LocalDevVPN.isInstalled ? "Connect VPN" : "Get LocalDevVPN") {
                    let target = LocalDevVPN.isInstalled ? LocalDevVPN.enableURL : LocalDevVPN.appStoreURL
                    UIApplication.shared.open(target)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(DeveloperDiskImageStore.isComplete ? "DDI Cached on Disk" : "DDI Files Required")
                    Spacer()
                    if ddiStore.isDownloading {
                        ProgressView(value: ddiStore.progress)
                            .frame(width: 90)
                    } else {
                        Button(DeveloperDiskImageStore.isComplete ? "Re-check" : "Download") {
                            Task { try? await ddiStore.downloadAll() }
                        }
                    }
                }
                if let msg = ddiStore.statusMessage {
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(ddiMounter.phase.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Mount DDI") {
                    Task { await ddiMounter.mount() }
                }
                .disabled(ddiMounter.isRunning)
            }
        }
    }

    private var runnerControlSection: some View {
        Section("GroguRunner XCUITest Engine (127.0.0.1:18831)") {
            HStack {
                Label(
                    runner.state == .ready ? "Runner Active" : "Runner Inactive",
                    systemImage: runner.state == .ready ? "bolt.fill" : "bolt.slash"
                )
                .foregroundStyle(runner.state == .ready ? GroguTheme.accent : .secondary)
                Spacer()
                Button("Check Health") {
                    Task { await runner.refreshHealth() }
                }
            }

            HStack {
                Button("Wake Runner") {
                    runner.launchRunner()
                }
                .buttonStyle(.borderedProminent)
                .tint(GroguTheme.accent)

                Button("Sync Token") {
                    runner.syncTokenOnly()
                }
                .buttonStyle(.bordered)

                Button("Stop", role: .destructive) {
                    runner.stopRunner()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var memoryGovernanceSection: some View {
        Section("Jetsam Memory Governance") {
            LabeledContent("Physical Footprint", value: String(format: "%.1f MB", jetsam.snapshot.physFootprintMB))
            LabeledContent("Available Before Jetsam", value: String(format: "%.0f MB", jetsam.snapshot.availableMB))
            LabeledContent("Pressure", value: jetsam.snapshot.pressure.rawValue.capitalized)
            Button("Trim Caches Now") {
                jetsam.trimCaches(reason: "User manual trim")
            }
        }
    }
}
