import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted when the user toggles the "Group tabs by repository" setting.
    /// SidebarView observes this to re-read the value without polling.
    static let sidebarGroupingChanged = Notification.Name("yggdrasil.sidebarGroupingChanged")
}

/// App + terminal theme and sidebar grouping preferences, edited in
/// Settings → General. App theme and grouping persist in the `setting` table;
/// the terminal theme in UserDefaults (read via @AppStorage by the terminal).
enum AppearanceSettings {
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

    enum TerminalTheme: String, CaseIterable, Identifiable {
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
    }

    static let settingKey = "appearance"
    static let groupByRepoKey = "sidebar.groupByRepo"
    static let terminalThemeKey = "yggdrasil.terminalTheme"

    static func apply(mode: Mode, services: AppServices) {
        NSApp.appearance = mode.appearance
        try? SettingsStore(database: services.database).set(mode.rawValue, forKey: settingKey)
    }

    static func readMode(services: AppServices) -> Mode {
        (try? SettingsStore(database: services.database).get(forKey: settingKey))
            .flatMap { Mode(rawValue: $0) } ?? .auto
    }

    static var terminalTheme: TerminalTheme {
        get { UserDefaults.standard.string(forKey: terminalThemeKey).flatMap(TerminalTheme.init) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: terminalThemeKey) }
    }

    static func persistGroupByRepo(_ value: Bool, services: AppServices) {
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
