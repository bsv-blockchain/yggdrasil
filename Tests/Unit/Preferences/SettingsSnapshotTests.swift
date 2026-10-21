import AppKit
import SwiftUI
import XCTest
@testable import Yggdrasil

/// Renders each Settings pane to PNG, light and dark, against an in-memory
/// database with sample data, for eyeballing layout changes without running
/// the app against real data. Opt-in: set YGGDRASIL_SNAPSHOT_DIR (through
/// xcodebuild, TEST_RUNNER_YGGDRASIL_SNAPSHOT_DIR) to the output folder.
@MainActor
final class SettingsSnapshotTests: XCTestCase {
    func testRenderSettingsPanes() throws {
        guard let dir = ProcessInfo.processInfo.environment["YGGDRASIL_SNAPSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("YGGDRASIL_SNAPSHOT_DIR not set")
        }
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        let (repoID, hostID) = try seed(services)
        let agentID = try services.agentStore.getDefault()?.id
        let outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try render(GeneralPrefsPane(services: services), dark: dark, to: outDir, name: "general-\(suffix)")
            try render(
                RepoPrefsPane(services: services, selectedID: repoID),
                dark: dark,
                to: outDir,
                name: "repos-\(suffix)"
            )
            try render(
                AgentPrefsPane(services: services, selectedID: agentID),
                dark: dark,
                to: outDir,
                name: "agents-\(suffix)"
            )
            try render(
                HostPrefsPane(services: services, selectedID: hostID),
                dark: dark,
                to: outDir,
                name: "hosts-\(suffix)"
            )
        }
    }

    private func seed(_ services: AppServices) throws -> (repo: Int64?, host: Int64?) {
        let repos = try services.database.queue.write { db -> [Repo] in
            try [("bsv-blockchain", "teranode", "/Users/me/src/teranode"), ("bsv-blockchain", "yggdrasil", nil)]
                .map { owner, name, path in
                    var repo = Repo(
                        id: nil, owner: owner, name: name, defaultBranch: "main", localMainPath: path, addedAt: Date()
                    )
                    try repo.insert(db)
                    return repo
                }
        }
        _ = try services.agentStore.add(name: "Codex", command: "codex", args: ["--full-auto"])
        let host = try services.hostStore.add(
            name: "Dev server",
            sshTarget: "siggi@developers-env",
            reposRoot: "/home/siggi/src"
        )
        try services.hostRepoStore.pin(host: host, repo: repos[0])
        _ = try services.hostStore.add(name: "Build box", sshTarget: "buildbox", reposRoot: "/srv/src")
        return (repos[0].id, host.id)
    }

    private func render(_ view: some View, dark: Bool, to dir: URL, name: String) throws {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
