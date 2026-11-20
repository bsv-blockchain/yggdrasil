// swift-tools-version:5.10
// Spike only: can Yggdrasil/Core build on its own, and off macOS?
import PackageDescription

/// Left out of the portable core, each with the reason (spike findings).
let excluded: [String] = [
    "DependencySmokeImports.swift", // link check for the Mac build only
    "Actions", // built on AppServices and the UI models
    "Control", // built on AppServices and the UI models
    "Remote/RemoteSpawn.swift", // cannot find type 'OpenSession' in scope
    "Settings/AppearanceSettings.swift", // cannot find type 'AppServices' in scope
    "Status/AgentSessionProbe.swift", // cannot find type 'AgentIdentity' in scope
    "Status/AgentTranscriptParser.swift", // cannot find type 'AgentIdentity' in scope
    "Migration/TranscriptTransfer.swift", // cannot find 'AgentSessionLocator' in scope
    "Status/RemoteTranscriptSource.swift", // cannot find type 'TranscriptFile' in scope
    "Status/ClaudeStateDetector.swift", // cannot find type 'AgentActivitySample' in scope
    "Status/AttentionDismissal.swift", // cannot find type 'AgentActivitySample' in scope
    "Status/StatusPoller.swift", // cannot find type 'AgentSessionProbe' in scope
    "Status/SubagentProbe.swift", // cannot find type 'TranscriptFileSystem' in scope
    "Status/TabStatus.swift", // cannot find type 'ClaudeState' in scope
    "Status/RemoteSubagentSource.swift", // cannot find type 'SubagentMetaEntry' in scope
    "Status/SubagentTreeRows.swift", // cannot find type 'SubagentWorkflow' in scope
    "Status/SubagentsModel.swift", // cannot find type 'SubagentInfo' in scope
    "Status/TabStatusModel.swift", // cannot find type 'TabStatus' in scope
]

let package = Package(
    name: "YggdrasilCoreSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.15.0")),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
        .package(path: "Vendor/Clibgit2"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "YggdrasilCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "KeychainAccess", package: "KeychainAccess", condition: .when(platforms: [.macOS])),
                .product(name: "Clibgit2", package: "Clibgit2"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])),
            ],
            path: "Yggdrasil/Core",
            exclude: excluded
        ),
    ]
)
