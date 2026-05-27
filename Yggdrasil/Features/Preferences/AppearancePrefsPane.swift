import AppKit
import SwiftUI

/// Light/dark/auto theme preference. Persists into `setting` table under
/// "appearance" and applies via `NSApplication.shared.appearance`.
struct AppearancePrefsPane: View {
    let services: AppServices

    enum Mode: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Match system"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var appearance: NSAppearance? {
            switch self {
            case .auto: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    static let settingKey = "appearance"

    @State private var selection: Mode = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").font(.title3).bold()

            Picker("Theme", selection: $selection) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: selection) { _, newMode in
                apply(mode: newMode)
            }

            Spacer()
        }
        .onAppear(perform: load)
    }

    private func load() {
        let store = SettingsStore(database: services.database)
        if let raw = try? store.get(forKey: Self.settingKey),
           let mode = Mode(rawValue: raw) {
            selection = mode
        }
    }

    private func apply(mode: Mode) {
        NSApp.appearance = mode.appearance
        let store = SettingsStore(database: services.database)
        try? store.set(mode.rawValue, forKey: Self.settingKey)
    }

    /// Called from AppDelegate at launch to honour the persisted theme.
    static func applyPersisted(services: AppServices) {
        let store = SettingsStore(database: services.database)
        if let raw = try? store.get(forKey: settingKey),
           let mode = Mode(rawValue: raw) {
            NSApp.appearance = mode.appearance
        }
    }
}
