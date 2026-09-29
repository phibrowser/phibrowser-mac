# Sync Now and Per-Kind Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the remainder of milestone M3-4d in the Settings → Sync pane: a "Sync now" button and a per-kind status breakdown (received / sent / waiting to send / held counts per Phi data kind, plus a categorized last problem). Target: the release after 2.12.0.

**Architecture:** Extend the existing status path, engine `SyncStatusState` → `PhiSyncEngine.statusSnapshot` → `SyncHelper` participant → `SyncHelper.Report` → `DevicesSettingViewModel` → `DevicesSettingView`, with Foundation-only value types in `Sources/Sync/SyncStatusSnapshot.swift`. A manual request goes through `SyncHelper` only. No new coordinator, no new polling loop, no UI access to cursor files, engine, or Chromium.

**Tech Stack:** Swift/SwiftUI, hostless `swiftc` harnesses under `build-scripts/`, `Resources/Localizable.xcstrings`.

**Spec:** [Sync settings and resumable setup](../specs/2026-09-23-sync-ux-design.md), amended by Task T6 of this plan. Product ruling: M3-4 ruling D25 in the knowledge base (`30-projects/phinomenon/sync-service/design/2026-09-16-m3-4-design-rulings.md`, line 62). Predecessor: [Sync status and devices](2026-09-23-sync-status-devices-implementation.md).

**Line references:** every `file:line` in this plan refers to `origin/dev` at `3474beb5`. Re-locate by symbol name if the file has moved on.

## Product contract

D25, English translation (the original is Chinese and lives in the knowledge base at
`30-projects/phinomenon/sync-service/design/2026-09-16-m3-4-design-rulings.md:62`):

> *(Translation)* Rename the **Devices pane** in Settings to **Sync**. Keep pairing and
> device removal; add a **sync status** display. Default scope (to be refined by the M3-4d
> spec; the user may change it when reviewing the spec): account and this device's identity;
> overall state (idle / syncing / error / paused) and the time of the last successful round;
> per kind (Settings / Spaces / Bookmarks / Pinned tabs / URL rules / Profiles) the last
> landed and published counts, and the parked and pending counts; the most recent error
> (R12: metadata only); "Sync now". After M4a, add one row for the realtime channel status.

Knowledge-base status (`30-projects/phinomenon/sync-service/status.md:30`, `:46`; backlog
`design/2026-09-15-client-stabilization-backlog.md` row PL-3): #153 (`9ff12904`) delivered
the renamed pane, resumable setup, explicit reset recovery and summary status. "D25's
per-kind counts and a 'Sync now' button are not in the pane (an explicit pane reload can
request a round)".

What `origin/dev` already has:

- Pane title "Sync" (`Sources/UserInterface/Preferences/Devices/DevicesSettingViewController.swift:7`).
- Seven summary phases (`Sources/Sync/SyncStatusSnapshot.swift:14`), coordinated success
  time `sync.lastCoordinatedSuccess` (`Sources/Sync/SyncHelper.swift:7`).
- A Details disclosure with one phase per *context*: `"phi"` plus each user Profile
  (`DevicesSettingView.swift:212-236`).
- Device list, pending approvals, reconfiguration, removal.

The gap: no per-kind rows or counts, no last problem (errors are reduced to booleans in
`PhiSyncEngine.swift:1581-1591`), no Sync now button.

Where the 2026-09-23 UX spec and D25 differ, and how this plan resolves it (see provisional
decision 7):

| Topic | D25 | UX spec | This plan |
| --- | --- | --- | --- |
| Identity | Account and this device's identity | Pane does not show the account email (spec :50-52) | Spec wins: no email |
| States | idle / syncing / error / paused | Signed out … Needs attention, no "paused" (spec :56-66) | Spec wins: no "paused" |
| Sync now | Required | Not mentioned; only "Retry" on Needs attention (spec :66) | D25 wins; spec addendum (T6) |
| Per-kind counts | Required | Acceptance 11: no unsupported categories shown as available (spec :344-347) | D25 wins; spec addendum (T6) |
| Last error | Metadata only (R12) | Predecessor plan: "Do not introduce raw diagnostic errors" (`2026-09-23-sync-status-devices-implementation.md:420`) | Categorized last problem only; addendum (T6) |
| Realtime row | After M4a | "Do not infer success from … an SSE connection" (spec :68) | Deferred |

## Provisional decisions, pending owner confirmation

Numbered to match the open questions of the originating brief. Implement against these;
if the owner changes one, only the tasks named in that item change.

1. **Meaning of "Received" and "Sent".** Per kind, the counts of the most recent round in
   which that kind had non-zero activity, together with that round's time. Held in memory
   only; nothing new is persisted. After relaunch the rows show no counts until a round has
   activity. (T1, T2, T5)
2. **Counts shown.** Received, sent, waiting to send (pending), held (parked). Conflicts,
   refused and unreadable are not shown as numbers. Pending and held appear only when
   non-zero. (T2, T5)
3. **Placement.** Pending and held counts appear only inside the Details disclosure, under
   the `"phi"` context. (T5)
4. **Scope of kinds.** No Profiles row until M3-4b exists. No Chromium per-category rows.
   (T1, T5)
5. **Rate limit and unloaded Profiles.** Keep the shared 60-second helper interval for
   manual requests. The policy for an unloaded (permanently Checking) Profile is **NOT
   decided**: the part of T3 that depends on it is blocked on the owner, and the
   request-state API is designed so either policy can be plugged in. (T3)
6. **Routing.** Sync now routes through `SyncHelper` only. The `"phi"` participant is
   rerouted through `phiInvalidationCoordinator.requestCatchUp()` so manual, SSE and timer
   pulls share one single-flight. (T3, T4)
7. **States and identity.** No "paused" state is added and the account email is not shown:
   the UX spec wins over D25 on states and identity. D25 wins on "Sync now" and per-kind
   counts, which requires an addendum to the UX spec (acceptance item 11 and the "no raw
   diagnostic errors" rule are reworded to allow per-kind counts and a categorized last
   problem). (T6)
8. **Last problem lifetime and content.** Cleared by the next fully successful round. Only
   a localized category and a relative time are shown; no HTTP status number, no internal
   text. (T1, T2, T5)
9. **Realtime-channel row.** Deferred; not part of this plan.
10. **BH-43 / BH-44.** No dedicated copy or actions; they become visible only through the
    held count and the last-problem category. One addition: when the only reason for
    Needs attention is held items waiting for a Profile that is not paired, the pane can
    say so with a distinct category, "Waiting for a profile to be paired". The enum case and
    string are added here (T1, T5); the engine-side producer depends on a separate fix
    (register item DI-1) and may land later. Until then the case is never produced.

## Global Constraints

- Dependencies point **UI → Sync only**. New value types are Foundation-only (no SwiftUI,
  AppKit or `NSLocalizedString`) and live in `Sources/Sync/SyncStatusSnapshot.swift` next to
  `SyncContextPhase`, `SyncContextSnapshot`, `SyncStatusSummary`, `SyncRoundCompletion` and
  `SyncStatusState`. The engine and `SyncHelper` emit enums and counts; the view localizes
  them, like `statusTitle` (`DevicesSettingView.swift:293-303`). No UI type may enter
  `PhiSyncEngine` or `SyncHelper`; this feature must not add to register item BH-40 (engine
  reading `SpaceManager.incognitoRuleTargetId` at `PhiSyncEngine.swift:7723`, agent layer
  consuming `URLRulesEditor.EditSet`).
- Extend the existing boundary types: `SyncContextSnapshot`, `SyncStatusState`,
  `SyncHelper.Report`, `SyncHelper.Participant`. Do not create another global state
  container, parallel coordinator, or status-owned polling loop (spec :290-303).
- The pane never reads cursor files (`bookmarks-cursors.json`, `pins-cursors.json`,
  `urlrules-cursors.json`, `PhiOwnedItemState.swift:8-17`) or the `sync.phiSpaces` table.
  Counts are computed by the engine at round end, where the tables are already in memory.
- No request may bypass pairing, key, account, or bridge gates, the engine's serialized
  round queue (`PhiSyncEngine.swift:1422-1440`), or the publish gate
  (`canPublishThisRound`, `PhiSyncEngine.swift:2389`).
- **Privacy (R12, M3-1 design §R12; URL-rules design §13.1; `contracts.md:21-22`).**
  The UI may show: kind name, counts, phase, time (relative), and a localized last-problem
  category. The UI must not show: `PhiSyncLog.describe` output or any internal type name,
  HTTP status numbers (decision 8), uuids or uuid prefixes, tag hashes, entity ids, Space /
  Profile / bookmark / rule names, URLs, hosts or path prefixes, or the identity of any held
  item. `SyncErrorSummary` has no `String` field, so R12 holds by construction.
- Localization: semantic `sync.*` keys with explicit English `value:` and translator
  `comment:`; English-only new entries in `Resources/Localizable.xcstrings`; counts via
  `String.localizedStringWithFormat` with plural variations (pattern:
  `ProfilesSettingsView.swift:194-203`). No CJK characters in Swift string literals under
  `Sources/` (guard: `Tests/PhiBrowserTests/Sync/Keys/SourceStringLanguageTests.swift`, which
  is hosted and therefore only compiled; check changed files manually).
- **Hosted XCTest must keep compiling but is never run** (policy: running it launches a Phi
  host). Evidence comes from hostless harnesses and manual acceptance only.
- **Concurrent engine work.** Branch `fix/sync-data-integrity` is editing
  `PhiSyncEngine.swift` in the Space apply loop, the retention sweep and the pull loop's
  Space routing. T2 keeps its engine edits confined to the status and counter code
  (`SyncStatusState` use, `run`'s round tail, `finishStatusRound`, `noteStatusError`,
  `logSpaceRound`, `logOwnedRounds`, the settings push/apply count sites, and counter
  increments) to limit merge conflicts. Do not reformat or move surrounding code.
- Chromium: no source or build changes in this plan. Builds are handed to the owner; agents
  do not run `autoninja`.
- Product commits follow the repository rules; pushing, merging and distribution need
  their own instruction.

## Review Focus

- A tap on Sync now during the pane's 3 s poll is not lost (defect D1).
- A request within 60 s of the pane-open request shows a queued state and dispatches on its
  own later; it is never silently discarded (D2).
- An unloaded Profile does not leave the button spinning forever without explanation (D3,
  blocked policy).
- A kind not visited in a round (gate closed, settings-only round) keeps its previous
  counts; an older revision cannot overwrite newer detail.
- Held (parked) items currently force Needs attention (`PhiSyncEngine.swift:1553`, `:1574`);
  the per-kind held count and last-problem category must explain it.
- No string reaching the pane from the engine carries user content.

## Defects to fix while wiring the button

| ID | Defect | Location | Fix (task) |
| --- | --- | --- | --- |
| D1 | `DevicesSettingViewModel.refresh` returns early while `refreshInFlight`; a Sync now tap during the 3 s poll (which also runs pending/device network calls) is silently dropped | `DevicesSettingViewModel.swift:80-89` | Sync now calls the helper's explicit-request API directly, or records a pending flag consumed when the in-flight refresh ends (T5) |
| D2 | `SyncHelper.refresh(requestSync:)` returns `Void` and `Report` (`SyncHelper.swift:19-23`) has no request state, so the pane cannot tell dispatched, coalesced, queued (60 s interval) or rejected apart | `SyncHelper.swift:110-121`, `:223-238` | Add `SyncRequestState` to `Report` and a request API that returns it (T1, T3) |
| D3 | A lazy, unloaded user Profile is permanently Checking (`ChromiumSyncStatus.swift:31-33`; `docs/sync.md:176-182`), so `canRequest` (`SyncHelper.swift:215-222`) is never true and no explicit request ever dispatches | `SyncHelper.swift:215-238` | Pluggable policy; decision blocked on owner (T3) |

## Prerequisites and source evidence

Existing round triggers (all at `3474beb5`):

| Trigger | Where | Effect |
| --- | --- | --- |
| Pane load / reload | `DevicesSettingViewModel.swift:120` → `DevicesSettingHostingViewController.swift:123-127` → `SyncHelper.refresh(requestSync: true)` | Participant `requestSync` |
| Helper self-demand (startup, membership, failed phase, success older than 300 s) | `SyncHelper.swift:223-238`; background poll every 3 s at `:97-106` | Same participant |
| `"phi"` participant | `PhiChromiumCoordinator.swift:727-739` | `Task { await engine.pullOnce() }` plus `bridge.notifyPhiSyncInvalidation(account, "", [], "")` (account-wide Chromium catch-up); Profile participants return `true` (`:740-743`) |
| SSE catch-up / hints, fallback timer (60 s unhealthy, 300 s healthy) | `PhiSyncInvalidation.swift:164-243`, pull closure `PhiChromiumCoordinator.swift:682-709` | Coalesced (0.25 s), single-flight `pullTask` (`PhiSyncInvalidation.swift:302-324`); catch-up pulls Phi and notifies the bridge |
| Foreground / wake | `PhiChromiumCoordinator.swift:966-976` | `invalidation.foregroundOrWake()` |
| Local edits (2 s debounce, `:186`) | settings `:980-1022`, Spaces `:1042-1044`, owned kinds `:1047-1078` | `handleLocal*Change` |
| Pairing / unlock activation | `PhiChromiumCoordinator.swift:933-989` | `invalidation.start()` → catch-up |

Gates already in place: helper `isEligible` (`PhiChromiumCoordinator.swift:713-720`: account,
engine identity, `isPaired`, `phiSyncPairingEnabled`, ARK), participant gates (`:729-734`),
engine stop/pairing checks in `run` (`PhiSyncEngine.swift:1442-1451`).

Numbers the engine has today (in memory, reset per round at `PhiSyncEngine.swift:1468`
unless noted):

| Number | Settings | Spaces | Bookmarks / Pins / URL rules |
| --- | --- | --- | --- |
| Landed | none (`SyncableSettings.apply`, `SyncableSettings.swift:398`, returns no count) | `SpaceRoundCounters.applied` (private, `:1780-1794`) | `OwnedRoundCounters.applied` (`:348-380`, e.g. `:4134`) |
| Published | logged only: `pushed settings keys=N` (`:3146`) | `.pushed`, `.tombstones` (e.g. `:3523`) | `.pushed`, `.tombstones` (e.g. `:4781`) |
| Parked | `unreadableSettingsRecord != nil` | derived from table in `logSpaceRound` (`:1800-1801`) | derived in `logOwnedRounds` (`:5023-5025`) |
| Pending publish | none | `pendingProjection` / `pendingDelete` (`:1564`) | `.pendingPublish`, `pendingDelete` (`:1565-1566`) |

Round-level: `LoggedRound` and the `round outcome=…` line (`:795-806`, `:1599-1615`);
`RoundOutcome` enum (`:1903-1912`). Errors: `noteStatusError` keeps booleans only
(`:1581-1591`); commit rejected / conflict exhausted (`:3150-3165`) and `cursorSaveFailures`
(`:785`) never reach status (register BH-43). `logSpaceRound` / `logOwnedRounds` run after
`finishStatusRound` (`:1543-1546`) and are skipped while the Space gate is closed.
Profiles have no numbers (M3-4b not started). Chromium exposes per-Profile phase only;
`enabledCategories` is decoded (`ChromiumSyncStatus.swift:22-25`) and dropped.

### File structure

| File | Responsibility |
| --- | --- |
| `Sources/Sync/SyncStatusSnapshot.swift` | New value types, merge helper, button-state reducer |
| `Sources/Sync/Phi/PhiSyncEngine.swift` | Produce per-kind detail and last problem at round end (status/counter code only) |
| `Sources/Sync/Phi/SyncableSettings.swift` | Settings apply returns a changed-key count |
| `Sources/Sync/SyncHelper.swift` | Explicit request API, request state in `Report`, pluggable unobservable policy |
| `Sources/ChromiumBridge/PhiChromiumCoordinator.swift` | Reroute `"phi"` participant through `requestCatchUp()` |
| `Sources/UserInterface/Preferences/Devices/DevicesSettingView.swift`, `DevicesSettingViewModel.swift`, `DevicesSettingHostingViewController.swift` | Button, last problem, per-kind rows, D1 fix, accessibility |
| `Resources/Localizable.xcstrings` | English entries |
| `Tests/SyncStatus/*`, `Tests/SyncHelper/main.swift`, `Tests/SyncInvalidation/*` | Hostless cases |

No new source files are required; if one is added, register it in `Phi.xcodeproj/project.pbxproj`
and in the harness script that compiles it.

## Verification commands

Hostless only (no Phi host is launched):

```sh
bash build-scripts/test-sync-status.sh
bash build-scripts/test-sync-helper.sh
bash build-scripts/test-sync-invalidation.sh
```

Compile-only for hosted XCTest (`xcodebuild build-for-testing` with the scheme and
destination used by the predecessor plans). Never `xcodebuild test`.

### Task T1: Status value types

**Size:** S. **Depends on:** none.

**Files:** Modify `Sources/Sync/SyncStatusSnapshot.swift`, `Tests/SyncStatus/main.swift`.

**Interfaces (Foundation-only, `Equatable`, `Sendable`):**

```swift
enum SyncKind: String, CaseIterable, Sendable { case settings, spaces, bookmarks, pinnedTabs, urlRules }

struct SyncKindStatus: Equatable, Sendable {
    var received: Int          // last round with non-zero activity (decision 1)
    var sent: Int
    var activityAt: Date?      // that round's time; nil until a round has activity
    var pending: Int           // current table state, every round
    var held: Int              // current table state, every round
}

enum SyncProblemCategory: String, Sendable {
    case offline, signInExpired, serverError, saveFailedOnThisMac, rejectedByServer,
         unreadableRemoteData, resetRequired, waitingForProfilePairing
}

struct SyncErrorSummary: Equatable, Sendable {   // no String fields (R12 by construction)
    let category: SyncProblemCategory
    let kind: SyncKind?
    let at: Date
}

struct SyncNativeDetail: Equatable, Sendable {
    var kinds: [SyncKind: SyncKindStatus]
    var lastProblem: SyncErrorSummary?
}

enum SyncRequestState: Equatable, Sendable {
    case idle
    case queued(reason: QueueReason, notBefore: Date?)
    case inFlight(startedAt: Date)
    case rejected
    enum QueueReason: String, Sendable { case busy, rateLimited, unobservable }
}
```

- `SyncContextSnapshot` gains `var detail: SyncNativeDetail? = nil`; existing initializers
  and Chromium decoding (`ChromiumSyncStatus.swift:13-26`) keep compiling unchanged.
- No Profiles case in `SyncKind` (decision 4).
- `waitingForProfilePairing` exists but has no producer yet (decision 10, DI-1).

- [ ] Add a pure merge: `SyncNativeDetail.merging(round:)`: kinds absent from the round
  keep their previous values; `received`/`sent`/`activityAt` change only when the round's
  received or sent for that kind is non-zero; `pending`/`held` always take the round's
  table values for kinds the round visited.
- [ ] Add a pure button reducer, e.g. `SyncNowButtonState.reduce(summary:request:)`,
  returning enabled / progress / hint so View and tests share one rule.
- [ ] Hostless cases (T7 lists them) in `Tests/SyncStatus/main.swift`.

### Task T2: Engine produces per-kind detail and last problem

**Size:** M. **Depends on:** T1.

**Files:** Modify `Sources/Sync/Phi/PhiSyncEngine.swift`, `Sources/Sync/Phi/SyncableSettings.swift`,
`Tests/SyncStatus/ConflictFixture.swift`, and `build-scripts/test-sync-status.sh` only if a new
production method must be spliced. Compile-fix hosted `Tests/PhiBrowserTests/Sync/Phi/PhiSyncEngine*Tests.swift`
if signatures change.

**Merge-conflict rule:** edit only status and counter code (see Global Constraints);
`fix/sync-data-integrity` owns the Space apply loop, retention sweep, and pull-loop Space
routing.

- [ ] Settings counts: make `SyncableSettings.apply` (`SyncableSettings.swift:398`) return
  the number of keys it changed (`@discardableResult`), accumulate into a round-local
  settings received count; record `outgoing.values.count` at the push success site
  (`PhiSyncEngine.swift:3146`) as settings sent.
- [ ] Spaces: from `spaceCounters.applied` / `.pushed` + `.tombstones`, and table-derived
  pending (`pendingProjection`/`pendingDelete`) and held (`pendingApply`/`heldProfileUuid`).
- [ ] Owned kinds: map registration labels `bookmarks` / `pins` / `urlrules`
  (`PhiSyncEngine.swift:5544`, `:6435`, `:7189`) to `SyncKind`; received = `applied`,
  sent = `pushed + tombstones`, pending = `pendingPublish` + `pendingDelete` cursors, held =
  table-derived `pendingApply || pendingTombstone`.
- [ ] Build the round's detail in the round tail after `logSpaceRound()` / `logOwnedRounds()`
  (they compute parked; `:1543-1546`), or compute held directly from the in-memory tables.
  Only kinds actually visited this round are included (gate closed ⇒ Space/owned absent).
  Merge into `SyncStatusState` via T1's merge; do not reload cursor files.
- [ ] Last problem: record a `SyncErrorSummary` for the round when
  `noteStatusError` fires (offline vs. HTTP 401/403 ⇒ `signInExpired` vs. other HTTP ⇒
  `serverError`, key-envelope/decode ⇒ `serverError`), commit rejected / conflict exhausted
  (`:3150-3165`) ⇒ `rejectedByServer`, `cursorSaveFailures > 0` ⇒ `saveFailedOnThisMac`,
  unreadable settings or Space/owned unreadable ⇒ `unreadableRemoteData`,
  `requiresReconfiguration` / `notMyBirthday` ⇒ `resetRequired`. Precedence when several
  occur: resetRequired, saveFailedOnThisMac, signInExpired, offline, rejectedByServer,
  serverError, unreadableRemoteData. Attach `kind` when the failure is kind-specific.
- [ ] Clear `lastProblem` when `finishStatusRound` reaches `.upToDate` (decision 8); keep it
  on any other phase.
- [ ] Revision: `SyncStatusState.update` bumps the revision on phase change; also bump when
  detail changes so the helper's newest-revision rule (`SyncStatusSnapshot.swift:23-26`)
  cannot let an old sample overwrite newer detail.
- [ ] Do not log anything new beyond R12 metadata; add no string fields.
- [ ] Update `Tests/SyncStatus/ConflictFixture.swift` stubs for any member the spliced
  `finishStatusRound` / `noteStatusError` now reference; add T7 cases.

### Task T3: SyncHelper explicit request and request state

**Size:** M. **Depends on:** T1. **Partly blocked:** the unobservable-Profile policy
(decision 5) awaits the owner.

**Files:** Modify `Sources/Sync/SyncHelper.swift`, `Tests/SyncHelper/main.swift`.

**Interfaces:**
- `Report` gains `var request: SyncRequestState = .idle`.
- `func requestSyncNow() async -> SyncRequestState`: marks an explicit request (same
  semantics as `refresh(requestSync: true)`), runs or joins an observation, and returns the
  resulting state. `refresh(requestSync:)` stays for the pane-open path.
- Init parameter `unobservablePolicy: ExplicitRequestPolicy` with cases
  `.waitForAllObservable` (current behavior, default) and `.dispatchToObservable`
  (dispatch explicit requests when every *observable* participant is settled, excluding
  permanently Checking Profiles from the dispatch precondition but not from the completion
  barrier).

- [ ] Derive `report.request`: `.inFlight(startedAt)` while `round != nil`;
  `.queued(.rateLimited, nextRequestAt)` when an explicit request waits on the 60 s
  interval (unchanged, decision 5); `.queued(.busy, nil)` when a participant is
  initialSync/syncing; `.queued(.unobservable, nil)` when a participant is Checking or
  missing; `.rejected` after `requestRejected`; `.idle` otherwise. Ineligible and
  membership resets return `.idle`.
- [ ] A queued explicit request keeps dispatching on the helper's own 3 s poll
  (`SyncHelper.swift:97-106`); no new timer.
- [ ] **Blocked on owner:** choose the default `unobservablePolicy`. Until decided, ship
  `.waitForAllObservable` and surface `.queued(.unobservable, nil)` in the UI (T5) so the
  button explains itself.
- [ ] Hostless cases (T7).

### Task T4: Route the "phi" participant through the invalidation coordinator

**Size:** S. **Depends on:** T3.

**Files:** Modify `Sources/ChromiumBridge/PhiChromiumCoordinator.swift` (`:727-739`);
optionally `Sources/Sync/Phi/PhiSyncInvalidation.swift` if `requestCatchUp()` must report
acceptance; `Tests/SyncInvalidation/*` if it changes.

- [ ] Replace `Task { await engine.pullOnce() }` plus the direct bridge call with
  `phiInvalidationCoordinator.requestCatchUp()`, whose pull closure (`:682-709`) already
  pulls Phi and sends the account-wide Chromium catch-up. Manual, SSE and timer pulls then
  share one single-flight `pullTask` (decision 6).
- [ ] `requestSync` returns `false` when the coordinator is absent or not running
  (`isRunning`, `PhiSyncInvalidation.swift:151`), keeping the existing gates
  (`PhiChromiumCoordinator.swift:729-734`). If `requestCatchUp()` needs to return a Bool,
  add that without changing its coalescing.
- [ ] Do not expose `isHealthy` to the pane (decision 9).

### Task T5: Pane

**Size:** M. **Depends on:** T1, T2, T3.

**Files:** Modify `DevicesSettingView.swift`, `DevicesSettingViewModel.swift`,
`DevicesSettingHostingViewController.swift`, `Resources/Localizable.xcstrings`;
compile-fix `Tests/PhiBrowserTests/Sync/Keys/DevicesSettingViewModelTests.swift`.

Current layout (`DevicesSettingView.swift:23-74`): reconfiguration card, pairing card,
state switch (loading / sign-in / failed+Retry / needsJoin+Set up / status card), Devices
section, action error, Recovery and removal. The status card (`:199-238`) is a
`SettingsDetailCard` with a `row(title){details}control:{EmptyView()}`, a `Divider`, the
Details disclosure button, and per-context `SettingsDetailRow`s.

- [ ] Hosting controller: add `viewModel.syncNow = { await helper.requestSyncNow() }` beside
  `syncReport` (`DevicesSettingHostingViewController.swift:123-127`).
- [ ] View model: `@Published requestState: SyncRequestState`, `@Published nativeDetail:
  SyncNativeDetail?` (from `report.snapshots["phi"]?.detail`), and `func syncNow() async`
  that bypasses the `refreshInFlight` guard (D1).
- [ ] Sync now button in the status row's empty `control:` slot (`DevicesSettingView.swift:208-210`)
  using `actionButton`; show a small `ProgressView` and disable while queued or in flight;
  shown only when `unlockState == .unlocked` and the summary is not `notStarted`. The status
  row keeps its position (spec :53-55).
- [ ] Last problem: one `hintText`/`errorText` line under the phase: category string plus
  relative time. Nothing else.
- [ ] Per-kind rows inside the Details expansion under the `"phi"` context: one
  `SettingsDetailRow` per `SyncKind`, trailing "Received N · Sent N" when
  `activityAt != nil`, plus "Waiting to send N" / "Held N" only when non-zero
  (decisions 2-3). No Profiles row, no Chromium categories.
- [ ] Accessibility: label on the progress indicator; completion announcement via
  `NSAccessibility.post(element:notification: .announcementRequested)` (deployment target
  macOS 14.0); each per-kind row combined into one element with a spoken summary; Details
  disclosure gets button trait and expanded/collapsed value.
- [ ] Strings (English-only catalog entries, plural variations for counts):

| Key | English value |
| --- | --- |
| `sync.status.syncNow` | Sync Now |
| `sync.status.syncNowQueued` | Waiting for current sync… |
| `sync.status.syncNowWaitingProfiles` | Waiting for all profiles to be available |
| `sync.status.syncNowFailed` | Couldn't start sync. Try again later. |
| `sync.status.syncNowDone` | Sync finished (VoiceOver announcement) |
| `sync.status.kind.settings` | Settings |
| `sync.status.kind.spaces` | Spaces |
| `sync.status.kind.bookmarks` | Bookmarks |
| `sync.status.kind.pinnedTabs` | Pinned tabs |
| `sync.status.kind.urlRules` | URL rules (confirm the product name used elsewhere) |
| `sync.status.kindReceived` | Received %lld |
| `sync.status.kindSent` | Sent %lld |
| `sync.status.kindPending` | Waiting to send %lld |
| `sync.status.kindHeld` | Held %lld |
| `sync.status.lastProblem` | Last problem: %1$@ (%2$@) |
| `sync.status.problem.offline` | No connection |
| `sync.status.problem.signInExpired` | Sign-in expired |
| `sync.status.problem.serverError` | Server error |
| `sync.status.problem.saveFailed` | Couldn't save sync state on this Mac |
| `sync.status.problem.rejected` | Server rejected changes |
| `sync.status.problem.unreadable` | Some synced data couldn't be read |
| `sync.status.problem.resetRequired` | Sync needs to be reset |
| `sync.status.problem.waitingForProfilePairing` | Waiting for a profile to be paired |

- [ ] Manually check changed Swift files for CJK characters in literals.

### Task T6: Documentation and UX spec addendum

**Size:** S. **Depends on:** T5.

**Files:** `docs/superpowers/specs/2026-09-23-sync-ux-design.md`, `docs/sync.md`,
`docs/sync-e2e-test-cases.md`; knowledge base `30-projects/phinomenon/sync-service/status.md`
(rows at `:30`, `:46`) and backlog rows PL-3, BH-43, BH-44.

- [ ] UX spec addendum: add Sync now to the Account and status section; reword acceptance
  item 11 to allow per-kind counts for supported Phi kinds (never unsupported ones); reword
  the "no raw diagnostic errors" rule to allow a categorized last problem with relative
  time and no internal text; record decision 7 (no "paused", no email).
- [ ] `docs/sync.md` "Sync status contract" (`:153-248`): request state, explicit request
  API, per-kind detail semantics (decision 1), last-problem categories and clearing rule,
  `"phi"` participant routing through `requestCatchUp()`.
- [ ] e2e cases for T8; knowledge-base rows updated with commit references when merged.

### Task T7: Hostless test cases

Written together with T1-T4; listed here per harness.

**`build-scripts/test-sync-status.sh`** (splices production `finishStatusRound`,
`noteStatusError` and commit outcome handlers into `Tests/SyncStatus/ConflictFixture.swift`):
- [ ] Merge keeps unvisited kinds; zero-activity round keeps previous received/sent and time.
- [ ] Pending and held from Space and owned tables; settings received/sent counts.
- [ ] Last-problem category for offline, HTTP 401/403, HTTP 5xx, commit rejected, conflict
  exhausted, cursor-save failure, not-my-birthday / reconfiguration, unreadable; precedence.
- [ ] Last problem cleared by the next `.upToDate` round, kept otherwise.
- [ ] Older revision cannot overwrite newer detail.
- [ ] Button reducer truth table.

**`build-scripts/test-sync-helper.sh`:**
- [ ] idle → queued(busy) → inFlight → idle on completion.
- [ ] Within 60 s: queued(rateLimited, notBefore) then auto-dispatch after `notBefore` on the poll.
- [ ] Coalesce with an active round (inFlight, no second dispatch).
- [ ] Participant refusal ⇒ rejected; ineligible and membership change ⇒ idle.
- [ ] Unobservable participant ⇒ queued(unobservable) under `.waitForAllObservable`;
  dispatch under `.dispatchToObservable` while the barrier still requires it.
- [ ] Report carries the `"phi"` detail unchanged.

**`build-scripts/test-sync-invalidation.sh`** (only if T4 changes the coordinator):
- [ ] Manual catch-up coalesces with a pending SSE catch-up; not running ⇒ refused.

Not coverable hostless: view model and view wiring, VoiceOver, two-Mac behavior (T8).

### Task T8: Compile check and manual acceptance

**Size:** S-M. **Depends on:** T5 (T6 in parallel).

- [ ] Run the hostless harnesses above. Run `build-for-testing` so hosted XCTest compiles;
  do not run it.
- [ ] Matched build, two Macs, staging accounts (owner runs builds): Sync now idle, during
  a round, within 60 s, offline, sign-in expired, cursor-save failure, a held item, an
  unloaded Profile, locked key, unpaired device; VoiceOver announcement and keyboard use;
  long localized labels.
- [ ] Record cases as Not run until executed.

## Work breakdown

| Task | Size | Depends on |
| --- | --- | --- |
| T1 Value types | S (0.5 d) | none |
| T2 Engine detail and last problem | M (1-1.5 d) | T1 |
| T3 SyncHelper request API | M (1 d), policy part blocked on owner | T1 |
| T4 Participant routing | S (0.25 d) | T3 |
| T5 Pane | M (1-1.5 d) | T1-T3 |
| T6 Docs and spec addendum | S (0.25 d) | T5 |
| T7 Hostless cases | included in T1-T4 | with T1-T4 |
| T8 Compile check and acceptance | S-M (0.5 d) | T5 |

Order: T1 → (T2 ∥ T3) → T4 → T5 → T6 → T8. Total about 4-5.5 engineer-days, no Chromium
changes. Chromium per-type counts would need a bridge payload v2 and a Chromium rebuild (L)
and are out of scope (decision 4).

## Coverage and completion

T1-T3 implement D25's per-kind counts, last problem and Sync now; T4 unifies the request
path; T5 presents them; T6 amends the spec where D25 overrides it; T7-T8 provide evidence.
The work is complete only with passing hostless harnesses, a compiling hosted target, and
recorded manual acceptance, or explicit Not run entries.

## Implementation notes

Deviations from the plan text, recorded as they were made.

- **T1.** The merge takes the round time explicitly: `SyncNativeDetail.merging(round:at:)`.
  Its input is a new Foundation-only `SyncRoundDetail` (the round's visited kinds plus its
  most severe problem, collected with `note(_:kind:)`), so the category precedence is a pure,
  tested rule instead of engine code. `SyncProblemCategory` cases are declared in precedence
  order; `waitingForProfilePairing` is last. `SyncKind(ownedLabel:)` maps the engine's
  owned-kind registration labels. The button reducer `SyncNowButtonState.reduce(summary:request:)`
  also returns `isVisible` (false while Not started); the pane still adds its own unlock
  check.
- **T2.** The round detail is built inside `finishStatusRound` by a new
  `roundStatusDetail(spaces:)`, not after `logSpaceRound()` / `logOwnedRounds()`: it reuses the
  Space table `finishStatusRound` already loads and the in-memory owned tables, and uses the
  same visit rule as those logs (Space gate open and a Space store present) plus "the owned
  table was loaded and read this round". `build-scripts/test-sync-status.sh` splices it and
  `resetRequiredRound`.
  Settings "sent" counts keys whose value differs from the last server entity (by
  `SyncableSettings.signature`), not `outgoing.values.count`, because the whole entity is
  always committed; "received" counts keys whose local value changed. Settings pending is
  always 0 and settings held is 1 while the entity is unreadable. Space held also counts
  `pendingTombstone`, matching what forces Needs attention. Owned pending is the plan's
  `pendingPublish` + `pendingDelete` cursors, which counts an over-budget delete twice.
  Outbound failures without an error value (seal failure, outcome-count mismatch) fall back to
  `serverError`; `NSURLErrorUserAuthenticationRequired` maps to `signInExpired`. `resetRequired`
  is also recorded at engine start with a persisted reconfiguration requirement and by
  `pauseForReconfiguration()`. An owned kind's unreadable arrivals do not fail a round, so
  their category survives only when something else keeps the round from succeeding. A local
  read failure (`ownedReadFailed`) still forces Needs attention without a category; no listed
  category fits it.
- **T3.** `ExplicitRequestPolicy` is nested in `SyncHelper`; the default stays
  `.waitForAllObservable` (owner decision pending), and switching is the one init argument
  `unobservablePolicy:` at `PhiChromiumCoordinator`'s `SyncHelper(...)`. `.rejected` comes from
  a dedicated flag set by a refused dispatch and cleared by an accepted one, a membership
  change or an ineligibility reset, so a persistence failure cannot mask or fake it. Queue
  reasons are reported in the order they clear: unobservable, busy, rate limited. "Up to date
  without a timestamp" counts as unobservable, as in `SyncStatusSummary`. Under
  `.dispatchToObservable` at least one participant must be observable. `requestSyncNow()`
  joins an observation in progress and then observes once more; to let it start that second
  observation safely, `refresh` now clears `refreshTask` only when it still holds its own task.
- **T4.** Rerouted as planned; `PhiSyncInvalidation.swift` is unchanged. Checked before
  changing it: `requestCatchUp()` is a silent no-op while the coordinator is stopped, so the
  participant checks `isRunning` itself and returns `false` (Rejected) then; the coordinator
  is started only when pairing, the pairing flag and the ARK are all present, the same
  conditions as the helper's `isEligible`, and it is built and retired together with the
  engine. The `.catchUp` demand performs both the native `pullOnce()` and the account-wide
  Chromium catch-up, as the old participant did. The pull closure calls the bridge
  optionally, so the participant keeps its bridge-support check to refuse rather than accept
  a request the bridge cannot serve. Differences from before: the pull starts after the
  0.25 s coalescing window, and a request during a running pull is served by one follow-up
  pull instead of a second concurrent `pullOnce()` task. `requestCatchUp()` needed no return
  value. New hostless case in `Tests/SyncInvalidation/main.swift`.
- **T5.** `SyncNowButtonState.Hint` gained `.startingShortly`, so Rate limited ("Sync will
  start shortly…", `sync.status.syncNowStartingShortly`) and Busy ("Waiting for current
  sync…") read differently; the hostless truth table follows. The hosting controller sets
  `viewModel.syncNowReport` (it calls `requestSyncNow()` and returns the helper's report,
  so one `apply` path serves the poll and the tap) rather than a closure returning only the
  state. The view model also keeps `isSubmittingSyncNow` so the control shows progress from
  the tap until the helper answers, and a `syncNowOutcome` the view turns into the
  VoiceOver announcement: "Sync finished" when a request it saw queued or in flight returns to
  Idle, the failure text when it ends Rejected; an Idle answer to the tap itself (helper
  stopped or ineligible) announces nothing. The hint sits beside the button in the control
  slot, in a fixed 200 pt, single-line, tail-truncated area with the full text as tooltip and
  accessibility hint, and the progress indicator keeps its space while hidden, so the row does
  not move; the plan's "one hint line under the phase" would have changed the row's height.
  The last-problem line shows the category and a relative time only (no kind). Kinds with no
  counts yet, or with nothing non-zero to show, read "No recent changes"
  (`sync.status.kindNoActivity`, added). Extra strings: `sync.status.syncNowInProgress`
  (progress label) and `sync.status.detailsExpanded` / `detailsCollapsed` (disclosure value).
  URL rules use "URL rules", the sentence-case form the sync strings already use
  (`sync.contents.phi`); the editor's title-case "URL Rules" is a window title. Sync now is
  also disabled while a reconfiguration runs. Plural variations are English one/other with
  identical text, so translators get the plural slots. One view-model case was added to the
  hosted `DevicesSettingViewModelTests` (compiled, never run).
- **Review I-3.** `SyncHelper` keeps a separate `syncNowPending`, set only by
  `requestSyncNow()`; the pane-open `refresh(requestSync: true)` still sets
  `explicitRefreshPending` and dispatches exactly as before, but no longer shows on the
  button. Queued derives from `syncNowPending` alone. In flight is expressed by one flag on the
  helper's `Round` (`syncNow`), set when the dispatch consumed `syncNowPending` or when a tap
  arrives while any round runs (the tap joins it, as coalescing already did); an automatic or
  pane-open round without a tap reports Idle. Rejected is set only when a dispatch that
  consumed `syncNowPending` is refused, and is cleared by the next tap or any accepted dispatch.
- **Review I-1.** The round records participant revisions at dispatch and ends early when
  the observed summary is Offline or Needs attention and every participant is settled with a
  revision past the recorded one, and the condition has held without interruption for at
  least one poll interval (3 s) by timestamp: the existing barrier test (`completionBarrier`)
  expects a Profile that reports Offline once and then Up to date inside the same round to
  complete it, Chromium retries on its own, and the pane timer, the helper poll and
  `requestSyncNow` can observe less than a second apart, so counting observations was not enough
  (second review F1). The early-ended round's `startedAt` and `previousSuccesses` are kept as
  `endedRound` until `startedAt + roundTimeout`; a success inside that window is recorded as the
  running round would have (common time saved, `needsRound` and `automaticRetryAt` cleared), so
  the summary does not sit at Checking. A new dispatch, a membership change, a changed participant
  set or ineligibility drops it; the latter two also reset `automaticRetryAt`. Chromium revisions are per-read counters, so for Profiles the
  condition means "sampled after dispatch"; the native revision moves on every engine status
  update. No new request state: an early end returns the request to Idle with a failed summary,
  and the pane (I-2) reports it as a failure. `automaticRetryAt` (start + timeout + minimum
  interval) keeps automatic `failed`/`needsRound`/stale demand on the pre-fix schedule; the
  pane-open request and Sync now are limited only by the ordinary minimum interval.
- **Review I-2.** The view model captures `summary.lastSuccess` at the tap. On the move to
  Idle it announces "Sync finished" only for Up to date with a newer common success; otherwise
  the native last-problem category, or the new `sync.status.syncNowIncomplete` ("Sync did not
  finish"). A nil report or a Not started summary ends the wait silently. `SyncNowOutcome`
  now carries a `Result` (`finished`, `failed(category)`, `rejected`) instead of a Bool. The last
  problem may predate the tap (for example after a round that expired without a new failure);
  it is still the best available category.
- **Review I-4 / I-5 / M-1.** Owned pending is now `liveUnpublished` (status-only counter:
  live candidates outside the slice, plus live work items of a pass that did not apply, with
  conflicts counted by the scoped retry pass) plus `pendingDelete` cursors; `testRoundDetail` no
  longer asserts the double count. Not counted: conflicted live items when the retry's pull
  fails (the round fails with a category anyway) and items refused over an unreadable tag. When
  the kind's unrestricted publication pass did not run (`publicationCounted` false, for example
  publication closed), the count keeps the last known value, at least the pending deletes,
  because the live edits are unknown without a snapshot. Held now includes
  `pendingPartnerLineage`. New category `readFailedOnThisMac` ("Couldn’t read data on this Mac"),
  third in precedence after save failed, noted per failed owned kind (sorted, so the first kind
  is stable); `roundOutcome == .cursorSaveFailed` also notes save failed, even without a counted
  write failure. To make the invariant hold with the Space gate shut, the Spaces row is now
  included whenever a Space store exists (pending/held from the table, no activity counts); this
  changes the T2 rule that a gate-shut round leaves Spaces out. Owned kinds are still left out
  while the gate is shut (their tables are not loaded then). M-1: unreadable tags in the Space
  table are noted without a kind, and also while the gate is shut. New hostless case
  `testNeedsAttentionIsExplained` checks the invariant for every Needs-attention condition of
  `finishStatusRound`.
- **Review M-2, skipped.** The settings `invalidMessage` path does not recover inside the round:
  `dropTheEntityCursorAfterInvalidMessage()` sets `roundOutboundFailed`, so the round ends Needs
  attention and only the next round rediscovers the entity. Without the note the round would
  get the `serverError` fallback instead, which is less accurate; the note is kept.
- **Review M-3.** A per-kind row with counts appends the relative time of that activity
  (abbreviated, for example "5 min. ago") to its trailing text, which is also the row's
  accessibility value. The trailing text is one line, middle-truncated, with the full text as
  tooltip; the longest English row fits the pane's width by estimate only (never seen).
- **Review M-4.** Added: `manualCatchUpTests` (T4) covers the coordinator side of a stopped
  coordinator. Left out: a hostless case for the participant's refusal itself, because it is an
  inline closure in `PhiChromiumCoordinator` that reads `AccountController`, `ChromiumLauncher`,
  the key controller and the pairing flag, and the harness splices only named methods; and
  splicing the settings sent/received count sites, which sit inside `pushSettings` and the pull's
  settings apply, whose surrounding wire and storage code the fixture would have to stub.
- **Second review F2 / M-a.** The view model also captures the tap time and names a problem
  only when its recorded time is at or after the tap; otherwise "Sync did not finish". "Sync
  finished" now needs only a common success newer than at the tap, whatever the current phase,
  because the helper moves `lastSuccess` only on a coordinated success.
