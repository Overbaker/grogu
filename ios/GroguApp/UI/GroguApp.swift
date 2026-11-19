import SwiftUI

@main
struct GroguApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = JetsamGuard.shared
        _ = WorkspaceStore.shared
        _ = MCPClientHub.shared
        _ = MCPServerService.shared
        MCPServerService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootNavigationView()
                .onOpenURL { url in
                    handleURL(url)
                }
                .task {
                    await RunnerLauncher.shared.refreshHealth()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    if !MCPServerService.shared.isRunning && !MCPServerService.shared.userStopped {
                        MCPServerService.shared.start()
                    }
                    Task {
                        await RunnerLauncher.shared.refreshHealth()
                    }
                }
        }
    }

    private func handleURL(_ url: URL) {
        if RunnerLauncher.shared.handleIncomingURL(url) {
            return
        }
        if url.isFileURL {
            do {
                try PairingFileStore.importFile(from: url)
                JetsamGuard.shared.log("Imported pairing file via share sheet")
            } catch {
                JetsamGuard.shared.log("Failed importing shared file: \(error.localizedDescription)")
            }
        }
    }
}
