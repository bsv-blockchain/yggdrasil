# Link PR to Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Right-click an ad-hoc sidebar tab → "Link PR…" → the tab becomes a PR tab (sets `tab.task_id`, fetching the PR on demand); right-click a linked tab → "Unlink PR" → reverts it.

**Architecture:** A tab is "linked" when `tab.task_id` references a `task` row; all downstream UI already keys off that. We add a single-PR REST fetch + an `importPR` upsert path on `TaskSyncService`, a branch→PR-number auto-detect helper, and two `SidebarActions` entry points wired into the existing context menu. UI is an NSAlert with an accessory text field, matching the existing `removeTab` dialog.

**Tech Stack:** Swift, SwiftUI/AppKit, GRDB (SQLite), GitHub REST + GraphQL. Tests use XCTest with `CannedHTTPClient` + `YggdrasilDatabase.inMemory()`.

---

## File Structure

- `Yggdrasil/Core/GitHub/APIResponses.swift` (modify) — add `head.ref` to `RESTPRDTO`; add `headRef` to `RawTask`.
- `Yggdrasil/Core/GitHub/Endpoints.swift` (modify) — add `pullRequest(owner:repo:number:)`.
- `Yggdrasil/Core/GitHub/RESTClient.swift` (modify) — add `pullRequest(owner:name:number:)`.
- `Yggdrasil/Core/GitHub/TaskSyncService.swift` (modify) — add `importPR(...)` and `linkablePRNumber(...)`; expose a reusable single-task upsert wrapper in `TaskSyncWrites`.
- `Yggdrasil/Features/Sidebar/SidebarActions.swift` (modify) — add `linkPR(tab:services:)` + `unlinkPR(id:services:)`.
- `Yggdrasil/Features/Sidebar/SidebarView.swift` (modify) — context-menu branch on link state.
- `Tests/Unit/GitHub/RESTClientTests.swift` (modify) — decode `/pulls/{n}` incl. `head.ref`.
- `Tests/Unit/GitHub/TaskSyncServiceTests.swift` (modify) — `importPR` + `linkablePRNumber` tests.

---

## Task 1: Add `head.ref` to the PR DTO and `RawTask`

**Files:**
- Modify: `Yggdrasil/Core/GitHub/APIResponses.swift`
- Test: `Tests/Unit/GitHub/RESTClientTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/Unit/GitHub/RESTClientTests.swift` (inside the existing `RESTClientTests` class — find it with `grep -n "final class RESTClientTests" Tests/Unit/GitHub/RESTClientTests.swift`):

```swift
func test_pullRequest_decodesHeadRef() async throws {
    let json = """
    {
      "url": "https://api.github.com/repos/o/r/pulls/828",
      "html_url": "https://github.com/o/r/pull/828",
      "number": 828,
      "title": "Add bulk utxos",
      "user": { "login": "siggi" },
      "state": "open",
      "body": null,
      "created_at": "2026-05-29T10:00:00Z",
      "updated_at": "2026-05-29T11:00:00Z",
      "assignees": [],
      "draft": false,
      "merged_at": null,
      "head": { "ref": "feat/bulk-utxos" }
    }
    """
    let http = CannedHTTPClient(responses: [
        HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: nil)
    ])
    let rest = RESTClient(http: http)
    let raw = try await rest.pullRequest(owner: "o", name: "r", number: 828)
    XCTAssertEqual(raw.number, 828)
    XCTAssertEqual(raw.type, .pullRequest)
    XCTAssertEqual(raw.headRef, "feat/bulk-utxos")
    XCTAssertEqual(http.calledURLs.first?.path, "/repos/o/r/pulls/828")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' test -only-testing:YggdrasilTests/RESTClientTests/test_pullRequest_decodesHeadRef 2>&1 | grep -E "error:|fail|PASS"`
Expected: compile error — `RawTask` has no `headRef`, `RESTClient` has no `pullRequest`.

- [ ] **Step 3: Add `head.ref` to `RESTPRDTO`**

In `Yggdrasil/Core/GitHub/APIResponses.swift`, inside `struct RESTPRDTO`, add the `head` property after `mergedAt` and a nested `Head` type, and add the coding key:

```swift
    let mergedAt: Date?
    let head: Head?

    struct User: Decodable {
        let login: String
    }

    struct Head: Decodable {
        let ref: String
    }

    enum CodingKeys: String, CodingKey {
        case url
        case htmlURL = "html_url"
        case number, title, user, state, body, assignees, draft, head
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
    }
```

- [ ] **Step 4: Add `headRef` to `RawTask`**

In `Yggdrasil/Core/GitHub/APIResponses.swift`, add the stored property to `struct RawTask` after `milestoneTitle`:

```swift
    let milestoneTitle: String?
    /// PR source branch (`head.ref`). nil for issues and for PR payloads
    /// that don't carry it. Used to auto-detect which PR matches a tab's
    /// worktree branch when linking.
    let headRef: String?
```

Then set it in both initializers. In `init(issue:)` add at the end:

```swift
        self.milestoneTitle = issue.milestone?.title
        self.headRef = nil
```

In `init(pullRequest:owner:name:)` add at the end:

```swift
        self.labels = []
        self.milestoneTitle = nil
        self.headRef = pull.head?.ref
```

- [ ] **Step 5: Add `Endpoints.pullRequest` + `RESTClient.pullRequest`**

In `Yggdrasil/Core/GitHub/Endpoints.swift`, add inside `enum Endpoints` after `openPullRequests`:

```swift
    /// `/repos/{owner}/{repo}/pulls/{number}` — a single pull request.
    static func pullRequest(owner: String, repo: String, number: Int) -> URL {
        restBase
            .appendingPathComponent("repos")
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
            .appendingPathComponent("pulls")
            .appendingPathComponent(String(number))
    }
```

In `Yggdrasil/Core/GitHub/RESTClient.swift`, add after `openPRsIfModified` (the last method before `static let decoder`):

```swift
    /// Fetch a single PR by number. Works for any state (open / closed /
    /// merged), unlike the open-PRs list. Used by the "Link PR" flow to
    /// import a PR on demand.
    func pullRequest(owner: String, name: String, number: Int) async throws -> RawTask {
        let url = Endpoints.pullRequest(owner: owner, repo: name, number: number)
        let result = try await http.get(url: url, accept: "application/vnd.github+json")
        guard let body = result.body else {
            throw GitHubError.requestFailed(.badServerResponse)
        }
        let dto: RESTPRDTO
        do {
            dto = try Self.decoder.decode(RESTPRDTO.self, from: body)
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        return RawTask(pullRequest: dto, owner: owner, name: name)
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' test -only-testing:YggdrasilTests/RESTClientTests/test_pullRequest_decodesHeadRef 2>&1 | grep -E "Executed|fail"`
Expected: `Executed 1 test, with 0 failures`.

> Note: adding a stored `headRef` to `RawTask` may surface compile errors at other `RawTask(...)` construction sites if any use memberwise init. There are none (both inits are custom), so the two edits in Steps 4 cover it. If the build flags a missing-arg error elsewhere, set `headRef: nil` there.

- [ ] **Step 7: Commit**

```bash
git add Yggdrasil/Core/GitHub/APIResponses.swift Yggdrasil/Core/GitHub/Endpoints.swift Yggdrasil/Core/GitHub/RESTClient.swift Tests/Unit/GitHub/RESTClientTests.swift
git commit -m "feat(github): single-PR fetch + head.ref on RawTask"
```

---

## Task 2: `TaskSyncWrites.upsertSingleTask` — reusable single-task upsert

**Files:**
- Modify: `Yggdrasil/Core/GitHub/TaskSyncService.swift`

The existing `upsertTask` is `private` and takes a `prDetails` dictionary keyed by composite key. We expose a thin wrapper that upserts one `RawTask` (+ optional `PRDetail`) and returns the resulting task id, so `importPR` can reuse the exact same write path.

- [ ] **Step 1: Add the wrapper**

In `Yggdrasil/Core/GitHub/TaskSyncService.swift`, inside `enum TaskSyncWrites`, add after `applyUpserts`:

```swift
    /// Upsert a single task row (+ github_status when a PRDetail is given)
    /// and return its id. Reuses the same `upsertTask` write path as the
    /// full sync so a linked PR is indistinguishable from a synced one.
    static func upsertSingleTask(
        db: Database,
        raw: RawTask,
        repoID: Int64,
        detail: PRDetail?,
        now: Date
    ) throws -> Int64 {
        var prDetails: [String: PRDetail] = [:]
        if let detail {
            prDetails[TaskSyncService.compositeKey(
                owner: raw.repoOwner, name: raw.repoName, number: raw.number
            )] = detail
        }
        try upsertTask(db: db, raw: raw, repoID: repoID, now: now, prDetails: prDetails)
        guard let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM task WHERE repo_id = ? AND type = ? AND number = ?",
            arguments: [repoID, raw.type.rawValue, raw.number]
        ) else {
            throw GitHubError.decodingFailed("upsertSingleTask: task row not found after upsert")
        }
        return id
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Yggdrasil/Core/GitHub/TaskSyncService.swift
git commit -m "feat(sync): expose reusable single-task upsert"
```

---

## Task 3: `TaskSyncService.importPR` + `linkablePRNumber`

**Files:**
- Modify: `Yggdrasil/Core/GitHub/TaskSyncService.swift`
- Test: `Tests/Unit/GitHub/TaskSyncServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/Unit/GitHub/TaskSyncServiceTests.swift` (inside the existing test class — find it with `grep -n "final class TaskSyncServiceTests" Tests/Unit/GitHub/TaskSyncServiceTests.swift`). These reuse the file's existing `insertRepo` helper and `httpResult` helper (find them with `grep -n "func insertRepo\|func httpResult" Tests/Unit/GitHub/TaskSyncServiceTests.swift`):

```swift
func test_importPR_insertsTaskAndReturnsID() async throws {
    let db = try YggdrasilDatabase.inMemory()
    let repoID = try insertRepo(db, owner: "o", name: "r")

    let prJSON = """
    {
      "url": "https://api.github.com/repos/o/r/pulls/828",
      "html_url": "https://github.com/o/r/pull/828",
      "number": 828, "title": "Bulk utxos",
      "user": { "login": "siggi" }, "state": "open", "body": null,
      "created_at": "2026-05-29T10:00:00Z",
      "updated_at": "2026-05-29T11:00:00Z",
      "assignees": [], "draft": false, "merged_at": null,
      "head": { "ref": "feat/bulk-utxos" }
    }
    """
    // GraphQL prDetail body — minimal valid shape (mergeable UNKNOWN, no rollup).
    let detailJSON = """
    {"data":{"repository":{"pullRequest":{"mergeable":"UNKNOWN","reviewDecision":null,"commits":{"nodes":[]}}}}}
    """
    // RESTClient.pullRequest does one GET; GraphQLClient.prDetail does one POST.
    let http = CannedHTTPClient(responses: [
        httpResult(prJSON),
        httpResult(detailJSON)
    ])
    let sync = TaskSyncService(
        database: db,
        rest: RESTClient(http: http),
        graphql: GraphQLClient(http: http)
    )

    let taskID = try await sync.importPR(owner: "o", name: "r", number: 828)

    let (count, savedNumber): (Int, Int?) = try db.queue.read { dbR in
        let c = try Int.fetchOne(dbR, sql: "SELECT COUNT(*) FROM task WHERE id = ?", arguments: [taskID]) ?? 0
        let n = try Int.fetchOne(dbR, sql: "SELECT number FROM task WHERE id = ?", arguments: [taskID])
        return (c, n)
    }
    XCTAssertEqual(count, 1)
    XCTAssertEqual(savedNumber, 828)
}

func test_linkablePRNumber_matchesHeadBranch() async throws {
    let db = try YggdrasilDatabase.inMemory()
    _ = try insertRepo(db, owner: "o", name: "r")
    // openPullRequests returns a bare array of RESTPRDTO.
    let listJSON = """
    [
      {"url":"u","html_url":"h","number":12,"title":"t","user":{"login":"a"},
       "state":"open","body":null,"created_at":"2026-05-29T10:00:00Z",
       "updated_at":"2026-05-29T11:00:00Z","assignees":[],"draft":false,
       "merged_at":null,"head":{"ref":"other-branch"}},
      {"url":"u","html_url":"h","number":828,"title":"t","user":{"login":"a"},
       "state":"open","body":null,"created_at":"2026-05-29T10:00:00Z",
       "updated_at":"2026-05-29T11:00:00Z","assignees":[],"draft":false,
       "merged_at":null,"head":{"ref":"feat/bulk-utxos"}}
    ]
    """
    let http = CannedHTTPClient(responses: [httpResult(listJSON)])
    let sync = TaskSyncService(
        database: db,
        rest: RESTClient(http: http),
        graphql: GraphQLClient(http: http)
    )

    let match = try await sync.linkablePRNumber(forBranch: "feat/bulk-utxos", owner: "o", name: "r")
    XCTAssertEqual(match, 828)

    let http2 = CannedHTTPClient(responses: [httpResult(listJSON)])
    let sync2 = TaskSyncService(
        database: db,
        rest: RESTClient(http: http2),
        graphql: GraphQLClient(http: http2)
    )
    let none = try await sync2.linkablePRNumber(forBranch: "no-such-branch", owner: "o", name: "r")
    XCTAssertNil(none)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' test -only-testing:YggdrasilTests/TaskSyncServiceTests/test_importPR_insertsTaskAndReturnsID -only-testing:YggdrasilTests/TaskSyncServiceTests/test_linkablePRNumber_matchesHeadBranch 2>&1 | grep -E "error:|fail|Executed"`
Expected: compile error — `importPR` / `linkablePRNumber` don't exist.

- [ ] **Step 3: Implement both methods**

In `Yggdrasil/Core/GitHub/TaskSyncService.swift`, inside `actor TaskSyncService`, add after `fullSync()`:

```swift
    /// Fetch one PR by number, upsert it into the task table (+ github_status
    /// from a GraphQL detail), and return its task id. Powers "Link PR" — a
    /// PR the user just opened may not be in any synced list yet, so we fetch
    /// it on demand rather than waiting for the next fullSync.
    ///
    /// Known limitation: a PR the user didn't author and isn't
    /// assigned/review-requested on will be pruned by the next fullSync's
    /// deleteStaleTasks, unlinking the tab. The common case (your own PR)
    /// appears in author:@me and survives.
    func importPR(owner: String, name: String, number: Int) async throws -> Int64 {
        let repoID = try await database.queue.read { db -> Int64 in
            guard let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM repo WHERE owner = ? AND name = ?",
                arguments: [owner, name]
            ) else {
                throw GitHubError.decodingFailed("importPR: repo \(owner)/\(name) not tracked")
            }
            return id
        }
        let raw = try await rest.pullRequest(owner: owner, name: name, number: number)
        let detail = try? await graphql.prDetail(owner: owner, repo: name, number: number)
        let now = Date()
        return try await database.queue.write { db in
            try TaskSyncWrites.upsertSingleTask(
                db: db, raw: raw, repoID: repoID, detail: detail, now: now
            )
        }
    }

    /// Among the repo's open PRs, the number whose head branch equals
    /// `branch`, else nil. Used to pre-fill the Link PR dialog from the
    /// tab's worktree branch.
    func linkablePRNumber(forBranch branch: String, owner: String, name: String) async throws -> Int? {
        let openPRs = try await rest.openPRs(forOwner: owner, name: name)
        return openPRs.first(where: { $0.headRef == branch })?.number
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' test -only-testing:YggdrasilTests/TaskSyncServiceTests/test_importPR_insertsTaskAndReturnsID -only-testing:YggdrasilTests/TaskSyncServiceTests/test_linkablePRNumber_matchesHeadBranch 2>&1 | grep -E "Executed|fail"`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Yggdrasil/Core/GitHub/TaskSyncService.swift Tests/Unit/GitHub/TaskSyncServiceTests.swift
git commit -m "feat(sync): importPR + branch-matched linkablePRNumber"
```

---

## Task 4: `SidebarActions.linkPR` + `unlinkPR`

**Files:**
- Modify: `Yggdrasil/Features/Sidebar/SidebarActions.swift`

`SidebarActions` is an `enum` of static side-effects (see existing `removeTab`). It imports `AppKit` + `Foundation`. The link flow resolves the repo from `services.tabs.repoByTabID`, auto-detects the PR number, shows an NSAlert with an accessory `NSTextField`, then imports + links.

- [ ] **Step 1: Add `unlinkPR` (simple, no dialog)**

In `Yggdrasil/Features/Sidebar/SidebarActions.swift`, add inside `enum SidebarActions` after `removeTab` / `performRemoval`:

```swift
    /// Clear a tab's PR link, reverting it to a plain terminal tab.
    static func unlinkPR(id: Int64, services: AppServices) {
        do {
            try services.tabStore.setTaskID(id: id, taskID: nil)
        } catch {
            YggdrasilLog.ui.error(
                "unlinkPR failed for tab \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        services.tabs.reload()
    }
```

- [ ] **Step 2: Add `linkPR`**

In `Yggdrasil/Features/Sidebar/SidebarActions.swift`, add inside `enum SidebarActions` after `unlinkPR`:

```swift
    /// "Link PR…" — turn an ad-hoc tab into a PR tab. Resolves the owning
    /// repo, auto-detects the PR matching this tab's branch, prompts for a
    /// number (pre-filled), then imports + links. MainActor because it
    /// drives an NSAlert.
    @MainActor
    static func linkPR(tab: YggdrasilTab, services: AppServices) {
        guard let tabID = tab.id else { return }
        guard let repo = services.tabs.repoByTabID[tabID],
              let owner = Optional(repo.owner), let name = Optional(repo.name) else {
            presentInfo(title: "Can't link a PR",
                        text: "This tab isn't inside a tracked repository.")
            return
        }

        Task { @MainActor in
            // Auto-detect: best-effort, ignore errors (just means no prefill).
            let suggested = try? await services.syncService.linkablePRNumber(
                forBranch: tab.branchName, owner: owner, name: name
            )
            let prefill = suggested.map(String.init) ?? ""

            guard let entered = promptForPRNumber(prefill: prefill) else { return } // cancelled
            let interpreted = NewTabSheet.interpretBranchInput(entered).branch
            guard let number = NewTabSheet.parsePRNumber(interpreted) else {
                presentInfo(title: "Enter a PR number",
                            text: "Couldn't read a PR number from “\(entered)”.")
                return
            }

            do {
                let taskID = try await services.syncService.importPR(
                    owner: owner, name: name, number: number
                )
                try services.tabStore.setTaskID(id: tabID, taskID: taskID)
                services.tabs.reload()
                services.triggerSyncNow()
            } catch {
                presentInfo(title: "Couldn't link PR #\(number)",
                            text: String(describing: error))
            }
        }
    }

    /// NSAlert with a text field. Returns the trimmed entry, or nil on cancel.
    @MainActor
    private static func promptForPRNumber(prefill: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Link a Pull Request"
        alert.informativeText = "Enter the PR number to link to this tab."
        alert.addButton(withTitle: "Link")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = prefill
        field.placeholderString = "e.g. 828"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Single-button informational NSAlert.
    @MainActor
    private static func presentInfo(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`.

> If the build errors on `services.syncService` actor isolation (calling an actor method from `@MainActor`), it's fine — the call is already inside `await` in an async `Task`. If it errors that `repoByTabID`/`tabStore`/`triggerSyncNow` aren't found, re-check names with `grep -n "repoByTabID\|func setTaskID\|func triggerSyncNow" Yggdrasil/Features/Sidebar/TabsModel.swift Yggdrasil/Core/Storage/TabStore.swift Yggdrasil/App/AppServices.swift`.

- [ ] **Step 4: Commit**

```bash
git add Yggdrasil/Features/Sidebar/SidebarActions.swift
git commit -m "feat(sidebar): linkPR/unlinkPR actions"
```

---

## Task 5: Wire the context menu

**Files:**
- Modify: `Yggdrasil/Features/Sidebar/SidebarView.swift:395-403` (the `contextMenu(for:)` builder)

- [ ] **Step 1: Add the link/unlink items**

Replace the body of `private func contextMenu(for tab: YggdrasilTab) -> some View` in `Yggdrasil/Features/Sidebar/SidebarView.swift` with:

```swift
    @ViewBuilder
    private func contextMenu(for tab: YggdrasilTab) -> some View {
        Button("Open in Finder") { SidebarActions.openInFinder(path: tab.worktreePath) }
        Button("Open in Terminal.app") { SidebarActions.openInTerminal(path: tab.worktreePath) }
        Divider()
        if let id = tab.id {
            if tabsModel.tasksByTabID[id] == nil {
                Button("Link PR…") {
                    SidebarActions.linkPR(tab: tab, services: services)
                }
            } else {
                Button("Unlink PR") {
                    SidebarActions.unlinkPR(id: id, services: services)
                }
            }
        }
        Divider()
        Button("Remove…", role: .destructive) {
            if let id = tab.id { SidebarActions.removeTab(id: id, services: services) }
        }
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Yggdrasil/Features/Sidebar/SidebarView.swift
git commit -m "feat(sidebar): Link/Unlink PR context-menu items"
```

---

## Task 6: Full suite + lint + manual verify

**Files:** none (verification)

- [ ] **Step 1: Run the whole suite**

Run: `xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' test 2>&1 | grep -E "Executed [0-9]+ tests|TEST"`
Expected: `** TEST SUCCEEDED **`, test count = prior count + 3 (one in Task 1, two in Task 3).

- [ ] **Step 2: Lint**

Run: `swiftlint --strict --quiet`
Expected: no output. If a function-length / complexity rule trips on `linkPR`, extract the import+link block into a private `@MainActor` helper and re-run.

- [ ] **Step 3: Build into the IDE DerivedData and relaunch**

```bash
xcodebuild -project Yggdrasil.xcodeproj -scheme Yggdrasil -destination 'platform=macOS' -derivedDataPath /Users/oskarsson/Library/Developer/Xcode/DerivedData/Yggdrasil-ahnuovszngnyvugwpvdwfkmrrusa build 2>&1 | tail -2
PIDS=$(pgrep -f "Yggdrasil.app/Contents/MacOS/Yggdrasil"); [ -n "$PIDS" ] && kill -9 $PIDS; sleep 2
open /Users/oskarsson/Library/Developer/Xcode/DerivedData/Yggdrasil-ahnuovszngnyvugwpvdwfkmrrusa/Build/Products/Debug/Yggdrasil.app
```

- [ ] **Step 4: Manual verification checklist**

In the running app, on an ad-hoc tab (branch with no PR-number pattern, e.g. `feat/foo`):
1. Right-click → confirm "Link PR…" appears (and "Unlink PR" does not).
2. Click "Link PR…" → dialog appears. If the branch matches an open PR, the number is pre-filled.
3. Enter a PR number → confirm the tab gains a `#xxx` badge, the GitHub pane shows the PR, and the diff base-ref reflects the PR.
4. Right-click the now-linked tab → confirm "Unlink PR" appears (and "Link PR…" does not).
5. Click "Unlink PR" → confirm the badge disappears and it's a plain terminal tab again.
6. Link PR with a bad number (e.g. 999999) → confirm an error alert, tab unchanged.

- [ ] **Step 5: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "fix(sidebar): link-PR verification fixups"
```

(Skip if Steps 1–4 passed clean.)

---

## Self-Review Notes

- **Spec coverage:** RESTPRDTO head.ref + RawTask.headRef (Task 1) ✓; single-PR endpoint + fetch (Task 1) ✓; linkablePRNumber auto-detect (Task 3) ✓; importPR fetch-on-demand + upsert + GraphQL detail (Tasks 2–3) ✓; linkPR/unlinkPR + NSAlert prefill + input reuse (Task 4) ✓; context-menu state branch (Task 5) ✓; known-limitation comment (Task 3 importPR doc) ✓; tests for decode/import/branch-match (Tasks 1, 3) ✓; manual NSAlert verify (Task 6) ✓.
- **Type consistency:** `importPR(owner:name:number:) -> Int64`, `linkablePRNumber(forBranch:owner:name:) -> Int?`, `RawTask.headRef`, `RESTPRDTO.Head.ref`, `TaskSyncWrites.upsertSingleTask(db:raw:repoID:detail:now:)`, `SidebarActions.linkPR(tab:services:)` / `unlinkPR(id:services:)`, `TabStore.setTaskID(id:taskID:)` — names match across tasks and existing code.
- **Input parsing:** `NewTabSheet.interpretBranchInput(_) -> BranchInterpretation` then `NewTabSheet.parsePRNumber(_) -> Int?` — handles `828` → `pr-828` → `828`, `#828`, `pr-828`, and PR URLs (covered by existing `NewTabSheetParseTests`).
