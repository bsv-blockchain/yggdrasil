import AppKit
import GRDB
import SwiftUI

/// First-launch sheet. Three steps: detect `gh`, prompt the user to
/// `gh auth login` if not authenticated, and walk through adding a first
/// tracked repo. Tracked via a flag in the `setting` table so the sheet
/// only fires once.
struct OnboardingSheet: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss

    enum Step {
        case welcome
        case ghCheck
        case firstRepo
        case done
    }

    static let settingKey = "onboarding_complete"

    @State private var step: Step = .welcome
    @State private var ghPath: String?
    @State private var ghAuthenticated: Bool = false
    @State private var checking: Bool = false
    @State private var ghCheckError: String?
    @State private var repoOwnerName: String = ""
    @State private var localPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).bold()
            Group {
                switch step {
                case .welcome: welcomeContent
                case .ghCheck: ghCheckContent
                case .firstRepo: firstRepoContent
                case .done: doneContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            HStack {
                if step != .welcome {
                    Button("Skip Setup") { finish() }
                }
                Spacer()
                primaryButton
            }
        }
        .padding(24)
        .frame(width: 560, height: 380)
    }

    private var title: String {
        switch step {
        case .welcome: "Welcome to Loom"
        case .ghCheck: "Check GitHub CLI"
        case .firstRepo: "Add Your First Repo"
        case .done: "All Set"
        }
    }

    // MARK: - Steps

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loom is a one-window coding-agent + GitHub workflow tool.")
            Text("This quick walkthrough sets up the two prerequisites:")
                .foregroundStyle(.secondary)
            Text("1. The `gh` CLI authenticated against your GitHub account.")
            Text("2. One tracked repo so the sidebar has something to show.")
            Text("You can also configure these in Preferences → Repos at any time.")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private var ghCheckContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if checking {
                ProgressView("Checking gh…").progressViewStyle(.linear)
            } else if let path = ghPath {
                Label("`gh` found at \(path)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if ghAuthenticated {
                    Label("Authenticated with GitHub", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not authenticated", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Run this in Terminal, then click Re-check:")
                    Text("gh auth login").font(.system(.body, design: .monospaced))
                        .padding(6).background(Color.gray.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } else {
                Label("`gh` not found", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Install via Homebrew, then click Re-check:")
                Text("brew install gh").font(.system(.body, design: .monospaced))
                    .padding(6).background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if let error = ghCheckError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button("Re-check") { Task { await checkGH() } }
                .disabled(checking)
                .padding(.top, 6)
        }
        .task { await checkGH() }
    }

    private var firstRepoContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the repo as owner/name and pick the local clone.")
                .foregroundStyle(.secondary)
            TextField("e.g. bsv-blockchain/teranode", text: $repoOwnerName)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Local clone path", text: $localPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { pickLocalPath() }
            }
            Text("This step is optional. Skip Setup → add via Preferences → Repos later.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Setup complete.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Click the sidebar's + to start your first session.")
                .foregroundStyle(.secondary)
        }
    }

    private var primaryButton: some View {
        switch step {
        case .welcome:
            return AnyView(Button("Continue") { step = .ghCheck }
                .keyboardShortcut(.defaultAction))
        case .ghCheck:
            return AnyView(Button("Continue") { step = .firstRepo }
                .keyboardShortcut(.defaultAction))
        case .firstRepo:
            return AnyView(Button("Add Repo & Finish") { addRepoAndFinish() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAddRepo))
        case .done:
            return AnyView(Button("Close") { finish() }
                .keyboardShortcut(.defaultAction))
        }
    }

    private var canAddRepo: Bool {
        let trimmedName = repoOwnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.contains("/")
            && !localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func checkGH() async {
        checking = true
        defer { checking = false }
        ghCheckError = nil

        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        let detected = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        ghPath = detected

        guard let ghBinary = detected else {
            ghAuthenticated = false
            return
        }
        do {
            let runner = ProcessRunner()
            let result = try await runner.run(executable: ghBinary, arguments: ["auth", "status"])
            ghAuthenticated = result.exitCode == 0
        } catch {
            ghCheckError = String(describing: error)
            ghAuthenticated = false
        }
    }

    private func pickLocalPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick the local clone of \(repoOwnerName)"
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            localPath = url.path
        }
    }

    private func addRepoAndFinish() {
        let raw = repoOwnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            NSAlert.show("Bad repo name", message: "Use owner/name.")
            return
        }
        do {
            try services.database.queue.write { db in
                var repo = Repo(
                    id: nil, owner: parts[0], name: parts[1],
                    defaultBranch: "main",
                    localMainPath: localPath.isEmpty ? nil : localPath,
                    addedAt: Date()
                )
                try repo.insert(db)
            }
            step = .done
        } catch {
            NSAlert.show("Add repo failed", message: String(describing: error))
        }
    }

    private func finish() {
        let store = SettingsStore(database: services.database)
        try? store.set("1", forKey: Self.settingKey)
        dismiss()
    }
}

extension OnboardingSheet {
    /// `true` when the user has not completed onboarding before. Read by
    /// `RootView` to decide whether to show the sheet.
    static func shouldShow(services: AppServices) -> Bool {
        let store = SettingsStore(database: services.database)
        return (try? store.get(forKey: settingKey)) == nil
    }
}
