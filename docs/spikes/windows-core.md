# Spike: can Yggdrasil's Core build on Windows?

Branch `claude-spike/windows-core`, 2026-11-20. Not for main: the `#if`
fences and the logger stand-in are scaffolding to find out what fails.

## How

`Package.swift` builds `Yggdrasil/Core` as a SwiftPM library on its own,
without the app. The files that need the app or macOS are excluded, each with
its reason. It was built three ways:

- **macOS:** `swift build --target YggdrasilCore`
- **Linux:** the `swift:6.1-noble` Docker image, with libgit2 and SQLite from apt
- **Windows:** `.github/workflows/spike-windows-core.yml` on `windows-latest`,
  with Swift 6.4.2 and libgit2 and SQLite from vcpkg

## Result

The standalone part of Core compiles on Windows. Every remaining error is a
reference to the POSIX-only files listed under "Platform layer" below.

### What builds alone

64 of the 98 Core files, about 6,250 of 11,500 lines:

- Storage and Models (GRDB)
- Git (libgit2 and the git CLI)
- GitHub sync (URLSession, REST and GraphQL)
- Remote (ssh hosts and the helper)
- Auth (the gh CLI)
- Diff, and parts of Migration and Status

### What doesn't build alone, and why

**The action and control-API layers** (`Core/Actions`, `Core/Control`) are
built on the app's composition root, `AppServices`, and on its UI models:
`TabsModel`, `SessionsModel`/`OpenSession`, `AgentTerminalSurface`,
`NewTabSheet` helpers, `SidebarActions` and `PaneLayout`. A headless core
would first have to separate these.

**Three links below that** cause the twelve other exclusions:

- `RemoteSpawn` uses `OpenSession` and `AgentTerminalSurface`.
- `AppearanceSettings` uses `AppServices`.
- `AgentSessionProbe` and `AgentTranscriptParser` use `AgentIdentity`, which
  is in `Yggdrasil/UI` and imports SwiftUI. This takes the whole status stack
  with it: `StatusPoller`, the subagent probes and `TabStatus`.

### Dependencies

| Dependency | Windows |
|---|---|
| GRDB 6.29 (what the app uses) | **No.** About 20 errors (`strcmp`, Foundation bridging). |
| GRDB 7.12 | Yes. Windows support arrived in 7.10. The app would need to move to 7.x. The standalone Core compiles against 7.12 on macOS with warnings only. |
| libgit2 (vcpkg) | Headers resolve. Linking is unverified: a library build doesn't link. |
| SQLite (vcpkg) | Same as libgit2. |
| swift-crypto (for CryptoKit) | Yes. A drop-in replacement in `BranchSlug`. |
| URLSession | Yes, with `import FoundationNetworking`. |
| SwiftTerm | Not tried. Its PTY is `forkpty`, so it is left out on Windows. |
| KeychainAccess | No. It uses Apple's Security framework. Needs a Windows Credential Manager store. |
| Swift 6.1 toolchain | No. Its clang 19 is too old for the runner's MSVC STL, which needs clang 20+. Swift 6.4.2 works. |

### Platform layer that Windows has to replace

- **`Terminal/CodingAgentRunner`, `Terminal/ChildReaper`:** `forkpty`,
  `waitpid`, `kill`/SIGTERM. Windows needs ConPTY and job objects. This is the
  agent terminal, the core of the app.
- **`Git/FileLock`:** `flock`. Windows needs `LockFileEx`.
- **`Git/WorktreeWatcher`:** FSEvents. Windows needs `ReadDirectoryChangesW`.
- **`Logging/YggdrasilLogger`:** `os.Logger`. The spike's stand-in keeps all 97
  `privacy: .public` call sites as they are. swift-log would be the real one.
- **`Auth/KeychainStore`:** see KeychainAccess above.
- **`CodingAgentRunner.shellQuote`:** used by `SSHSubprocessRunner`. It is a
  pure function and can move out of the platform file.

Linux has all of the POSIX calls above, so it builds the same set,
`CodingAgentRunner`, `ChildReaper` and `FileLock` included.

## What it means

- A Windows client could reuse the storage, git, GitHub sync and ssh-host
  layers.
- Before that, these need work:
  - separate the action and control layers from the UI models;
  - split a UI-free `AgentIdentity` out of the badge;
  - move to GRDB 7;
  - put the platform layer above behind protocols.
- The UI (about 11,000 lines in `Features/`, `App/` and `UI/`) and the terminal
  view are a rewrite in any case: there is no SwiftUI, AppKit or SwiftTerm view
  on Windows.
