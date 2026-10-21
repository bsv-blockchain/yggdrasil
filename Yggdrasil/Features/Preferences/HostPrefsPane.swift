import SwiftUI

/// ssh hosts tabs can run on. "Check" runs the host preflight, which also
/// installs or updates the `ygg` helper there.
struct HostPrefsPane: View {
    let services: AppServices

    @State private var hosts: [RemoteHost] = []
    @State private var selectedID: Int64?
    @State private var name = ""
    @State private var sshTarget = ""
    @State private var reposRoot = ""
    @State private var checkStatus: [Int64: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote Hosts").font(.title3).bold()
            Text("""
            Agents on a host run in dtach and keep going when Yggdrasil quits or the connection drops. \
            Uses /usr/bin/ssh, so your ~/.ssh/config and ssh agent apply.
            """)
            .font(.callout).foregroundStyle(.secondary)

            List(selection: $selectedID) {
                ForEach(hosts, id: \.id) { host in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name).font(.system(size: 12, weight: .semibold))
                        Text("\(host.sshTarget) · \(host.reposRoot)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        if let id = host.id, let status = checkStatus[id] {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(host.id)
                }
            }
            .frame(minHeight: 120)

            HStack {
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                    .help("Remove host")
                Button("Check") { checkSelected() }
                    .disabled(selectedID == nil)
                    .help("Check required tools and install the helper")
                Spacer()
            }

            Divider()
            Text("Add host").font(.system(size: 13, weight: .semibold))
            HStack {
                TextField("Name", text: $name)
                TextField("ssh target (alias or user@host)", text: $sshTarget)
                TextField("Repos root (/home/me/src)", text: $reposRoot)
                Button("Add") { addHost() }
                    .disabled(name.isEmpty || sshTarget.isEmpty || reposRoot.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        do { hosts = try services.hostStore.list() } catch {
            YggdrasilLog.ui.error("HostPrefsPane reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func addHost() {
        do {
            _ = try services.hostStore.add(name: name, sshTarget: sshTarget, reposRoot: reposRoot)
            name = ""
            sshTarget = ""
            reposRoot = ""
            reload()
        } catch {
            NSAlert.show("Add host failed", message: String(describing: error))
        }
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        do {
            try services.hostStore.remove(id: id)
            selectedID = nil
            reload()
        } catch HostStoreError.hostInUse {
            NSAlert.show("Host in use", message: "Remove or move the tabs running on this host first.")
        } catch {
            NSAlert.show("Remove failed", message: String(describing: error))
        }
    }

    private func checkSelected() {
        guard let id = selectedID, let host = hosts.first(where: { $0.id == id }) else { return }
        checkStatus[id] = "Checking…"
        Task { @MainActor in
            do {
                let report = try await services.remoteControl.preflight(host: host)
                checkStatus[id] = Self.describe(report)
            } catch {
                checkStatus[id] = "Failed: \(String(describing: error))"
            }
        }
    }

    static func describe(_ report: HostPreflightReport) -> String {
        let helper = report.helperInstalled ? " Helper installed." : ""
        guard report.isReady else {
            return "Missing: \(report.missingTools.joined(separator: ", ")).\(helper)"
        }
        return "Ready.\(helper)"
    }
}
