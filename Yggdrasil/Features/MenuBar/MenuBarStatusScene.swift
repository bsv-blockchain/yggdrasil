import AppKit
import SwiftUI

/// Always-visible menu bar item. Click → popover listing every live agent
/// session, plus a "Close and kill all" footer that tears every tmux session
/// down and quits the app. The status item itself uses the Yggdrasil tree
/// mark as a template image so it adapts to the menu bar's dark/light tint.
struct MenuBarStatusScene: Scene {
    @ObservedObject var appDelegate: AppDelegate

    /// Pre-sized template NSImage for the menu bar item. Cached so we don't
    /// reload the asset every body invocation.
    private static let menuBarIcon: NSImage = {
        let image = NSImage(named: "YggdrasilMark") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            if let services = appDelegate.services {
                MenuBarStatusView(services: services)
            } else {
                // Services not yet built — render a tiny placeholder so the
                // popover isn't blank on the brief window between launch and
                // applicationDidFinishLaunching.
                Text("Yggdrasil starting…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        } label: {
            // MenuBarExtra ignores SwiftUI .frame() on its label and renders
            // Image at the asset's intrinsic size — our YggdrasilMark is
            // 128×128, so the menu bar item ends up huge. The workaround is
            // to load NSImage explicitly, mark it as a template (so macOS
            // tints it with the menu bar's foreground colour) and force its
            // `size` to the standard 18pt status-item footprint. The Image
            // view honours that size verbatim.
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Popover content. One row per live agent + the footer.
struct MenuBarStatusView: View {
    let services: AppServices
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if services.sessions.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .padding(.vertical, 8)
        .background(YggdrasilTheme.bgPane(scheme))
        .accessibilityIdentifier("menubar.popover")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            YggdrasilMark()
                .frame(width: 16, height: 16)
            Text("Yggdrasil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(YggdrasilTheme.text(scheme))
            Spacer()
            Text(sessionCountLabel)
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            Text("No running agents")
                .font(.callout)
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
            Spacer()
        }
        .padding(.vertical, 18)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(services.sessions.sessions) { session in
                    SessionRow(
                        session: session,
                        agent: agentIdentity(for: session),
                        onKill: { killSession(id: session.id) },
                        onReveal: { revealTab(id: session.id) },
                        scheme: scheme
                    )
                    Divider().opacity(0.5)
                }
            }
        }
        .frame(maxHeight: 320)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Button {
                showMainWindow()
            } label: {
                Label("Show Yggdrasil window", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                closeAndKillAll()
            } label: {
                Label("Close and kill all", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(YggdrasilTheme.statusErr(scheme))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menubar.killall")
        }
        .padding(.top, 4)
    }

    // MARK: - Data + actions

    private var sessionCountLabel: String {
        let count = services.sessions.sessions.count
        switch count {
        case 0: return "no agents"
        case 1: return "1 agent"
        default: return "\(count) agents"
        }
    }

    private func agentIdentity(for session: OpenSession) -> AgentIdentity {
        if let cached = services.tabs.agentByTabID[session.id] {
            return cached
        }
        return AgentIdentity.detect(command: session.command)
    }

    private func killSession(id: Int64) {
        services.sessions.terminate(tabID: id, tmux: services.tmux)
        services.tabs.reload()
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // The primary window has a stable id of "main" (see WindowGroup in
        // YggdrasilApp). Re-raise it via the standard URL scheme handler.
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    private func revealTab(id: Int64) {
        services.tabs.select(id)
        showMainWindow()
    }

    private func closeAndKillAll() {
        // Tear every tmux session down explicitly — the regular app-quit
        // path leaves them alive by design, so this button is the only way
        // to actually stop them.
        if services.tmux.isAvailable {
            services.tmux.killAllSessions()
        } else {
            // Fallback for the no-tmux case: SIGTERM each registered PID.
            for pid in services.sessions.snapshotLivePIDs() where pid > 0 {
                kill(pid, SIGTERM)
            }
        }
        NSApp.terminate(nil)
    }
}

/// One row in the menu bar's session list.
private struct SessionRow: View {
    let session: OpenSession
    let agent: AgentIdentity
    let onKill: () -> Void
    let onReveal: () -> Void
    let scheme: ColorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            AgentBadge(agent: agent, statusIcon: nil, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(YggdrasilTheme.text(scheme))
                    .lineLimit(1)
                Text(session.cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(YggdrasilTheme.textMute(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onKill) {
                Image(systemName: "stop.circle")
                    .foregroundStyle(YggdrasilTheme.statusErr(scheme))
            }
            .buttonStyle(.plain)
            .help("Kill agent + remove tmux session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(perform: onReveal)
    }
}
