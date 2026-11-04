import SwiftUI

/// The pinned Yggdrasil session in the main pane: Claude with the Yggdrasil
/// MCP loaded. It needs the control API's socket; while that's off, the pane
/// asks to turn it on rather than doing so behind the user's back.
struct ManagerPaneView: View {
    let services: AppServices
    let tab: YggdrasilTab
    @State private var failure: String?
    @Environment(\.colorScheme) private var scheme

    private var control: ControlService? {
        services.control
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(YggdrasilTheme.border(scheme))
                .frame(height: 0.5)
            content
        }
        .background(YggdrasilTheme.bgPane(scheme))
        .onAppear(perform: ensureSession)
        .onChange(of: control?.isRunning) { _, _ in ensureSession() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tree")
                .foregroundStyle(YggdrasilTheme.accent)
            Text("Yggdrasil")
                .font(.system(size: 12, weight: .semibold))
            Text("Claude with the Yggdrasil tools")
                .font(.system(size: 11))
                .foregroundStyle(YggdrasilTheme.textMute(scheme))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        if let control, !control.isRunning {
            notice(
                control.lastError ?? "The Yggdrasil session uses the control API, which is off.",
                action: control.lastError == nil ? "Turn On" : nil
            ) {
                control.isEnabled = true
            }
        } else if let failure {
            notice(failure, action: "Try Again") {
                self.failure = nil
                ensureSession()
            }
        } else if let id = tab.id, let session = services.sessions.sessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                AgentTerminalSurface(
                    tabID: id,
                    cwd: session.cwd,
                    command: session.command,
                    args: session.args,
                    env: session.env,
                    sessionStore: services.sessionStore,
                    sessions: services.sessions,
                    host: nil,
                    initialPrompt: nil,
                    isActive: services.tabs.selectedID == id
                )
                if services.sessions.exitedTabs[id] != nil {
                    HStack {
                        Text("The Yggdrasil session ended.")
                        Button("Start Again") { restart() }
                    }
                    .font(.system(size: 11))
                    .padding(8)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notice(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "powerplug")
                .font(.system(size: 22))
                .foregroundStyle(YggdrasilTheme.textFaint(scheme))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(YggdrasilTheme.textDim(scheme))
            if let action {
                Button(action, action: perform)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ensureSession() {
        guard let id = tab.id, let control, control.isRunning,
              !services.sessions.sessions.contains(where: { $0.id == id })
        else { return }
        do {
            try services.sessions.add(ManagerSession.session(
                tab: tab, services: services, yggctlPath: ControlService.yggctlPath, socketPath: control.socketPath
            ))
        } catch {
            failure = "Couldn't start the Yggdrasil session: \(error.actionMessage)"
        }
    }

    private func restart() {
        do {
            try ManagerSession.restart(tab: tab, services: services)
        } catch {
            failure = "Couldn't start the Yggdrasil session: \(error.actionMessage)"
        }
    }
}
