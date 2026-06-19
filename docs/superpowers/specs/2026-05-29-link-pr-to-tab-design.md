# Link an ad-hoc tab to a PR

**Date:** 2026-05-29
**Status:** Approved (design), pending implementation

## Problem

A sidebar tab created ad-hoc (e.g. on branch `feat/foo`, not from a PR or
issue) has no GitHub linkage: no `#xxx` badge, no GitHub pane content, no
CI/review status, and the diff pane falls back to a default base ref. Once
the user pushes that branch and opens a PR on GitHub, there's currently no
way to "upgrade" the existing tab into a PR tab — they'd have to remove the
tab and re-create it from the PR.

## Goal

Right-click a tab → **Link PR…** → confirm/enter a PR number → the tab
becomes a PR tab (sets `tab.task_id`, ensuring the `task` row exists).
Right-click a linked tab → **Unlink PR** → reverts to a plain terminal tab.

## Scope

**PRs only.** The trigger ("after pushing to GitHub") is inherently a PR
action, and the payoff (CI status, review state, diff base-ref,
review-counting) is all PR semantics. Issues have no head branch (so
auto-detect can't apply) and none of the PR status payoff. Issue-linking is
explicitly out of scope.

The app already differentiates issues and PRs (`YggdrasilTask.Kind` =
`.issue`/`.pullRequest`, the `task.type` column, distinct sidebar badges,
the PRs/Issues filter pills). This feature only adds PR linking.

## Data model

A tab is "linked" when `tab.task_id` references a `task` row. All downstream
consumers (GitHub pane, `#xxx` badge via `TabRowViewModel.trailingBadge`,
diff base-ref via `DiffSubPane.resolveBaseRef`, review-counting) already key
off `task_id`. So linking reduces to: **ensure the task row exists, then set
`task_id`.** No schema change.

## Components

### 1. `RESTPRDTO` + `RawTask` — carry the head branch

Add `head.ref` decoding to `RESTPRDTO` (the GitHub list/get-PR endpoints
return `head: { ref: "<branch>" }`). Surface it on `RawTask` as
`headRef: String?` so branch-matching can work. Existing `RawTask(issue:)`
sets it `nil` (issues have no head).

### 2. `Endpoints.pullRequest(owner:repo:number:)`

`GET /repos/{owner}/{repo}/pulls/{number}` — single-PR fetch.

### 3. `RESTClient.pullRequest(owner:name:number:) -> RawTask`

Fetch + decode one PR into a `RawTask`. Works for any number / state (open,
closed, merged) — not limited to the open-PR list page cap.

### 4. `TaskSyncService.linkablePRNumber(forBranch:owner:name:) -> Int?`

Lists open PRs for the repo (`RESTClient.openPRs`), returns the `number`
whose `headRef == branch`, else `nil`. Used to pre-fill the dialog. Requires
`headRef` from component 1.

### 5. `TaskSyncService.importPR(owner:name:number:) -> Int64`

Fetch-on-demand path:
1. `rest.pullRequest(owner:name:number:)` → `RawTask`.
2. `graphql.prDetail(owner:repo:number:)` → `PRDetail` (for instant CI/
   review status so the linked tab is immediately useful).
3. Inside one DB write, reuse the existing upsert path
   (`TaskSyncWrites.upsertTask`, exposed via a thin wrapper) to insert/update
   the `task` row + `github_status` row.
4. Return the task id.

Resolving the repo: the caller passes owner/name resolved from
`repoByTabID[tabID]` (the tab's worktree → owning `Repo`).

### 6. `SidebarActions.linkPR(tab:services:)`

1. Resolve the owning `Repo` from `services.tabs.repoByTabID[tab.id]`. If
   none → NSAlert "This tab isn't inside a tracked repo." and stop.
2. `await services.syncService.linkablePRNumber(forBranch: tab.branchName,
   owner:name:)` for the suggested number.
3. Show an NSAlert with an accessory `NSTextField` pre-filled with the
   suggestion (or empty). Buttons: **Link** / **Cancel**. Same NSAlert
   pattern as the existing `removeTab`.
4. On Link: interpret the field text through the existing
   `NewTabSheet.interpretBranchInput` then `NewTabSheet.parsePRNumber`, so
   `828`, `#828`, `pr-828`, and a full PR URL all resolve to a number.
   Empty/uninterpretable → NSAlert "Enter a PR number." and stop.
5. `try await services.syncService.importPR(...)` → `task_id`.
6. `services.tabStore.setTaskID(id: tabID, taskID: …)` →
   `services.tabs.reload()` → `services.triggerSyncNow()`.
7. Any thrown error (bad number, 404, network) → NSAlert with the message;
   tab unchanged.

### 7. `SidebarActions.unlinkPR(id:services:)`

`services.tabStore.setTaskID(id:, nil)` → `services.tabs.reload()`. Reverts
the tab to a plain terminal tab.

### 8. `SidebarView.contextMenu(for:)`

- `services.tabs.tasksByTabID[id] == nil` → show **Link PR…**.
- else → show **Unlink PR**.

Mutually exclusive based on link state.

## Error handling

| Case | Behaviour |
|------|-----------|
| Tab not inside a tracked repo | NSAlert, no-op |
| Empty / uninterpretable input | NSAlert "Enter a PR number", no-op |
| PR fetch fails (404 / network) | NSAlert with the error, tab unchanged |
| Auto-detect finds nothing | Dialog opens with an empty field (manual entry) |

## Known limitation

A linked PR the user **didn't author** and **isn't assigned/review-requested
on** gets pruned by the next sync's `TaskSyncWrites.deleteStaleTasks`, which
unlinks the tab. The common case — the user's own PR — appears in
`author:@me` and survives. Per the design decision, we document this in a
code comment rather than engineer around it (e.g. tab-referenced-task
protection). If it becomes a real annoyance, the follow-up is to make
`deleteStaleTasks` skip tasks referenced by a `tab.task_id`.

## Testing (TDD)

- **`RESTClientTests`** — decode a `/pulls/{n}` fixture including
  `head.ref`; assert `RawTask.headRef`.
- **`linkablePRNumber`** — stubbed REST returning open PRs; asserts the
  branch-matched number, and `nil` when no head ref matches.
- **`importPR`** — stubbed REST + GraphQL; asserts a `task` row and a
  `github_status` row appear and the returned id matches.
- **Input parsing** — reuse `NewTabSheetParseTests`; add bare-number / URL
  cases exercised via the link path if not already covered.
- **`TabStore.setTaskID` nil-clear** — already covered (unlink path).
- The NSAlert UI itself is not unit-tested (consistent with `removeTab`).

## Out of scope

- Issue linking.
- Auto-linking without user action (the lazy branch-name link already covers
  `pr-N`/`issue-N` branches; this feature is for branches that *don't* encode
  the number).
- Protecting linked tasks from `deleteStaleTasks` (documented limitation).
