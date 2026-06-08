import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted when the user toggles the "Group tabs by repository" setting.
    /// SidebarView observes this to re-read the value without polling.
    static let sidebarGroupingChanged = Notification.Name("yggdrasil.sidebarGroupingChanged")
}

/// Light/dark/auto theme preference. Persists into `setting` table under
/// "appearance" and applies via `NSApplication.shared.appearance`.
struct AppearancePrefsPane: View {
    let services: AppServices

    enum Mode: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String {
            rawValue
        }

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
    static let groupByRepoKey = "sidebar.groupByRepo"

    @State private var selection: Mode = .auto
    @State private var groupByRepo: Bool = false

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

            Divider()

            Toggle("Group tabs by repository", isOn: $groupByRepo)
                .onChange(of: groupByRepo) { _, newValue in
                    persistGroupByRepo(newValue)
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
        groupByRepo = Self.readGroupByRepo(services: services)
    }

    private func apply(mode: Mode) {
        NSApp.appearance = mode.appearance
        let store = SettingsStore(database: services.database)
        try? store.set(mode.rawValue, forKey: Self.settingKey)
    }

    private func persistGroupByRepo(_ value: Bool) {
        let store = SettingsStore(database: services.database)
        try? store.set(value ? "1" : "0", forKey: Self.groupByRepoKey)
        NotificationCenter.default.post(name: .sidebarGroupingChanged, object: nil)
    }

    /// Read the current value of the `sidebar.groupByRepo` setting. Exposed
    /// `static` so SidebarView can read the same source of truth without
    /// duplicating the key string.
    static func readGroupByRepo(services: AppServices) -> Bool {
        let store = SettingsStore(database: services.database)
        guard let raw = try? store.get(forKey: groupByRepoKey) else { return false }
        return raw == "1"
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
