import SwiftUI

/// `Settings` scene installed by `YggdrasilApp`. Renders the standard macOS
/// `Settings` scene installed by `YggdrasilApp`: the standard macOS settings
/// window with toolbar tabs. Each pane sizes itself; the window follows.
struct PreferencesScene: Scene {
    @ObservedObject var appDelegate: AppDelegate

    var body: some Scene {
        Settings {
            PreferencesRoot(appDelegate: appDelegate)
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
        if let services = appDelegate.services {
            TabView {
                GeneralPrefsPane(services: services)
                    .tabItem { Label("General", systemImage: "gearshape") }
                RepoPrefsPane(services: services)
                    .tabItem { Label("Repositories", systemImage: "shippingbox") }
                AgentPrefsPane(services: services)
                    .tabItem { Label("Agents", systemImage: "terminal") }
                HostPrefsPane(services: services)
                    .tabItem { Label("Hosts", systemImage: "server.rack") }
            }
        } else {
            Text("Settings are available once Yggdrasil has finished launching.")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}
