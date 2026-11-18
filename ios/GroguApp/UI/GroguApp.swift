import SwiftUI

@main
struct GroguApp: App {
    init() {
        _ = JetsamGuard.shared
        _ = WorkspaceStore.shared
        _ = MCPClientHub.shared
        _ = MCPServerService.shared
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
