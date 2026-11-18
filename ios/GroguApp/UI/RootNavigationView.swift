import SwiftUI

struct RootNavigationView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ConsoleView()
                .tabItem {
                    Label("Console", systemImage: "terminal")
                }
                .tag(0)

            MCPCenterView()
                .tabItem {
                    Label("MCP", systemImage: "arrow.left.arrow.right.circle")
                }
                .tag(1)

            MemorySkillsView()
                .tabItem {
                    Label("Memory", systemImage: "brain")
                }
                .tag(2)

            SettingsBootstrapView()
                .tabItem {
                    Label("Bootstrap", systemImage: "slider.horizontal.3")
                }
                .tag(3)
        }
        .tint(GroguTheme.accent)
    }
}
