import AppKit
import SwiftUI

/// Custom toolbar strip mirroring `WindowChrome` in `app.jsx`:
/// - Yggdrasil mark + "Yggdrasil / repo / branch-chip" breadcrumb
/// - Optional ember unread pill ("N new")
/// - Right-side actions: sync, theme toggle, settings (placeholder)
///
/// Sits above the sidebar+main HSplit. The system traffic lights are macOS's
/// native ones in the title-bar area; we don't redraw them. Theme toggle here
/// also writes back to AppearancePrefsPane.
struct WindowChromeBar: View {
    let services: AppServices
    @Environment(\.colorScheme) private var scheme

    @State private var themeOverride: NSAppearance.Name?
    @State private var showingReviewPicker = false
    @Environment(\.openSettings) private var openSettings

    private var selectedTab: YggdrasilTab? {
        guard let id = services.tabs.selectedID else { return nil }
        return services.tabs.tabs.first(where: { $0.id == id })
    }

    private var selectedTask: YggdrasilTask? {
        guard let id = selectedTab?.id else { return nil }
        return services.tabs.tasksByTabID[id]
    }

    private var repo: Repo? {
        guard let task = selectedTask else { return nil }
        return try? services.database.queue.read { db in
            try Repo.fetchOne(db, key: task.repoID)
        }
    }

    private var unread: Int {
        guard let task = selectedTask,
              let status = try? services.database.queue.read({ db in
                  try GitHubStatus.fetchOne(db, key: task.id ?? 0)
              })
        else { return 0 }
        return status.unreadCommentsCount
    }

    var body: some View {
        HStack(spacing: 10) {
            YggdrasilMark()
                .frame(width: 16, height: 16)
                .padding(.leading, 6)

            Text("Yggdrasil")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(YggdrasilTheme.text(scheme))

            if let repoFullName {
                Text("/")
                    .font(.system(size: 12))
                    .foregroundStyle(YggdrasilTheme.textFaint(scheme))
                Text(repoFullName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let branch = selectedTab?.branchName {
                Text("/")
                    .font(.system(size: 12))
                    .foregroundStyle(YggdrasilTheme.textFaint(scheme))
                Text(branch)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(YggdrasilTheme.text(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(YggdrasilTheme.chipBg(scheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(YggdrasilTheme.chipBd(scheme), lineWidth: 0.5)
                            )
                    )
                    .frame(maxWidth: 220)
            }

            if unread > 0 {
                Label("\(unread) new", systemImage: "bubble.left.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(YggdrasilTheme.ember)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(YggdrasilTheme.emberSoft(scheme))
                    )
            }

            if services.tabs.pendingReviewCount > 0 {
                Button {
                    showingReviewPicker = true
                } label: {
                    Label("\(services.tabs.pendingReviewCount) to review", systemImage: "eye")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(YggdrasilTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(YggdrasilTheme.accentSoft(scheme))
                        )
                        .overlay(
                            Capsule()
                                .stroke(YggdrasilTheme.accent.opacity(0.4), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Show PRs awaiting your review")
                .accessibilityIdentifier("chrome.reviewpill")
            }

            Spacer()

            HStack(spacing: 4) {
                chromeButton(systemImage: "arrow.clockwise", help: "Sync now") {
                    Task { try? await services.syncService.fullSync() }
                }
                chromeButton(
                    systemImage: scheme == .dark ? "sun.max" : "moon",
                    help: "Toggle theme"
                ) {
                    toggleTheme()
                }
                chromeButton(systemImage: "gearshape", help: "Preferences") {
                    // macOS 14+ uses the SwiftUI OpenSettingsAction; the
                    // legacy `showPreferencesWindow:` selector silently
                    // no-ops because the Settings scene SwiftUI installs
                    // hangs off a different responder.
                    openSettings()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(YggdrasilTheme.bgWindow(scheme))
        .overlay(
            Rectangle()
                .fill(YggdrasilTheme.border(scheme))
                .frame(height: 0.5),
            alignment: .bottom
        )
        .sheet(isPresented: $showingReviewPicker) {
            AssignedTaskPicker(services: services, mode: .review)
        }
    }

    private var repoFullName: String? {
        guard let repo else { return nil }
        return "\(repo.owner)/\(repo.name)"
    }

    private func chromeButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggleTheme() {
        // Cycle dark → light → auto. Persists via AppearancePrefsPane.
        let currentRaw =
            (try? SettingsStore(database: services.database)
                .get(forKey: AppearancePrefsPane.settingKey)) ?? ""
        let next: AppearancePrefsPane.Mode = {
            switch AppearancePrefsPane.Mode(rawValue: currentRaw) ?? .auto {
            case .auto: return .light
            case .light: return .dark
            case .dark: return .auto
            }
        }()
        NSApp.appearance = next.appearance
        try? SettingsStore(database: services.database)
            .set(next.rawValue, forKey: AppearancePrefsPane.settingKey)
    }
}
