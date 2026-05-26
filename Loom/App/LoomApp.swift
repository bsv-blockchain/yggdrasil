import SwiftUI

@main
struct LoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Loom", id: "main") {
            RootView()
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            DebugMenu()
        }
    }
}

struct RootView: View {
    var body: some View {
        ZStack {
            Color.clear
            Text("Loom")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("loom.placeholder.title")
        }
        .frame(minWidth: 800, minHeight: 600)
        .accessibilityIdentifier("loom.root")
    }
}
