# Decisions Log

Design decisions made during the build that weren't in the spec, with rationale and date.

---

## 2026-05-26 — Replace SwiftGit2 SwiftPM dep with a local `Clibgit2` system module

**Spec §2 line under review:** *"Git operations | git subprocess for worktrees + status; SwiftGit2/libgit2 for diff computation."*

**Problem.** Upstream `github.com/SwiftGit2/SwiftGit2` does not ship a `Package.swift` on any branch or tag — it is still Carthage-only. Verified `master`, `release-2.0`, `xcode-15`, `applesilicon-support`, plus all numbered tags (`v0.1`–`v0.3`, `0.4.0`–`0.6.0`) — all 404 for `Package.swift`. Commonly-cited community SwiftPM forks (`light-tao`, `bdrelling`, `johnxnguyen`, `SwiftDocOrg`) don't exist as referenced — no SwiftPM-ready maintained fork was located. Phase 0 AC #6 (*"All four SwiftPM deps resolved and import-able"*) was unachievable as written.

**Decision.** Drop the SwiftGit2 binding. Provide libgit2 access via a local SwiftPM package at `Vendor/Clibgit2/` declaring `.systemLibrary(name: "Clibgit2", pkgConfig: "libgit2", providers: [.brew(["libgit2"])])`. Phase 7's `DiffEngine` will write a thin Swift wrapper around the C API on top.

**Rationale.**
- Honours the spec's actual intent (libgit2-quality diff, not subprocess parsing).
- Removes a fragile third-party dep with no SwiftPM story for one we fully control.
- Faster Phase 7 implementation than wrapping a Carthage-only library.

**Trade-offs.**
- Dev box and CI runners now need `brew install libgit2` (added to README + CI).
- We write more glue code in Phase 7 than if SwiftGit2 had worked. Estimate +1–2 days.
- libgit2 1.9.x ABI is what we'll target; pin via Brewfile in Phase 8 if needed.

**Approval.** User chose this option at Phase 0 boot when asked for a call between (block-and-defer / system-libgit2 / hunt-for-fork).

---

## 2026-05-26 — Use XcodeGen to manage `Loom.xcodeproj`

**Spec §2 says:** *"Build | Xcode project committed."* but doesn't specify how to author/maintain `project.pbxproj`.

**Decision.** Author `project.yml` in repo root; `xcodegen generate` produces `Loom.xcodeproj`. Both the YAML and the generated project are committed; regeneration is idempotent.

**Rationale.** Hand-editing pbxproj across SwiftPM dep changes is fragile. XcodeGen is a single binary (`brew install xcodegen`), produces reviewable YAML diffs, and is the de-facto standard for Swift-monorepos that want reproducible projects. Tuist was considered and rejected as overkill for one app target.

**Trade-offs.** Anyone modifying targets/build settings edits `project.yml` and re-runs `xcodegen generate`. The generated pbxproj is also committed so `xcodebuild` works without XcodeGen installed, but they may drift if someone hand-edits the pbxproj. Adding a `make project` target + pre-commit check is on the to-do list for Phase 8.

---

## 2026-05-26 — No App Sandbox in Phase 0

**Spec §0.4 step 4** asks Phase 0 to *"document why"* if sandbox is disabled.

**Decision.** `com.apple.security.app-sandbox = false`. The other Phase 0 entitlements: `network.client = true`, `files.user-selected.read-write = true`.

**Rationale.** Loom must spawn arbitrary user-chosen executables (`gh`, `git`, `zsh`, `claude`) and access user-owned git checkouts at arbitrary paths under `~`. App Sandbox cannot model "any directory the user clones a repo into" without bookmark gymnastics on every path. Disabling sandbox is the correct posture for a developer power-tool; we sign with Developer ID and notarise in Phase 8 to retain Gatekeeper acceptance.

**Trade-offs.** No Mac App Store distribution path (acceptable per spec §6: out of scope). Hardened runtime stays enabled so we keep the security floor.

---

## 2026-05-26 — Work directly on `main` (exception to spec §0.2 step 4)

**Spec §0.2 step 4 says:** *"Commit everything on a branch named `phase-N/<short-description>`."*

**Decision.** Phase 1+ commits land directly on `main`. Phase branches and worktrees are not used for now.

**Rationale.** No collaborators yet; no remote; no risk of stepping on shared state. The branch ceremony adds friction without adding safety in a solo pre-public phase.

**Trade-offs.** Lose the ability to keep a Phase N+1 work-in-progress while Phase N is in human review. Acceptable while no review queue exists. If/when the repo gains collaborators or goes public, revert to the spec's branch-per-phase convention — `decisions.md` is the place to overturn this entry.

**Approval.** User instructed *"Just work in main for now, as an exception. Nobody is using this yet"* after Phase 0 approval.

---

## 2026-05-27 — Headless agent runner uses `/bin/sh -c 'cd && exec'`; UI surface uses native `currentDirectory`

**Spec §2.1 says:** *"spawn `<profile.command> <profile.args>` directly inside a PTY at the worktree path. No interactive shell wrapper."*

**Decision.** Two code paths in Phase 3, differing only in how cwd is set:

- **UI path (`AgentTerminalSurface`)** uses `SwiftTerm.LocalProcessTerminalView.startProcess(executable:, args:, currentDirectory:)`, which accepts the cwd directly. **Zero shell wrap.** Matches spec exactly.
- **Headless test path (`CodingAgentRunner`)** uses bare `SwiftTerm.LocalProcess`, which does NOT accept a `currentDirectory` parameter. Minimal wrap: `/bin/sh -c 'cd "<cwd>" && exec <cmd> <args>'`. Non-interactive (no `-i`), reads no rc files, and `exec` replaces the shell so signals reach the agent directly.

**Rationale.** Spec's "no interactive shell wrapper" is about avoiding the user's `.zshrc` / `.bashrc` / `.profile` ceremony, not banning every conceivable `/bin/sh` invocation. The non-interactive `sh -c` form satisfies the spirit (no profile loading) and is required because bare `LocalProcess` has no cwd parameter.

**Trade-offs.**
- Two slightly-different spawn implementations.
- If/when SwiftTerm exposes `currentDirectory` on `LocalProcess` (or we patch our fork), drop the wrap and converge on one path. Tracked as a Phase 8 cleanup item.

**Approval.** Self-documented at Phase 3 finalization; surfaced in `phase-3-report.md` §3.1 for review.

---
