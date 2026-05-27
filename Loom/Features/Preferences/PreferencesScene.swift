import SwiftUI

/// `Settings` scene installed by `LoomApp`. Renders the standard macOS
/// Preferences window with four tabs: Repos, Agents, Intervals, Appearance.
struct PreferencesScene: Scene {
    var body: some Scene {
        Settings {
            PreferencesRoot()
                .frame(minWidth: 560, minHeight: 360)
        }
    }
}

struct PreferencesRoot: View {
    private var services: AppServices? {
        (NSApplication.shared.delegate as? AppDelegate)?.services
    }

    var body: some View {
        Group {
            if let services {
                TabView {
                    RepoPrefsPane(services: services)
                        .tabItem { Label("Repos", systemImage: "folder.badge.gearshape") }
                    AgentPrefsPane(services: services)
                        .tabItem { Label("Agents", systemImage: "cpu") }
                    IntervalsPrefsPane(services: services)
                        .tabItem { Label("Intervals", systemImage: "clock") }
                    AppearancePrefsPane(services: services)
                        .tabItem { Label("Appearance", systemImage: "paintbrush") }
                }
                .padding(20)
            } else {
                Text("Preferences load after first launch.")
                    .padding()
            }
        }
    }
}
