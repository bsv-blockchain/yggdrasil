import SwiftUI

/// `Settings` scene installed by `YggdrasilApp`. Renders the standard macOS
/// Preferences window with four tabs: Repos, Agents, Intervals, Appearance.
struct PreferencesScene: Scene {
    @ObservedObject var appDelegate: AppDelegate

    var body: some Scene {
        Settings {
            PreferencesRoot(appDelegate: appDelegate)
                .frame(minWidth: 560, minHeight: 360)
        }
    }
}

/// Observed wrapper so the Settings window rebinds the moment
/// `AppServices` is wired (the build is async w.r.t. SwiftUI's first
/// body evaluation, so a plain computed property left the window
/// stuck on the "Preferences load after first launch" stub).
struct PreferencesRoot: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        Group {
            if let services = appDelegate.services {
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
