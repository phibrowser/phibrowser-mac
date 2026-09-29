# Sync: pause while a Profile is unmapped, and load every Profile

Date: 2026-09-29. Target: the release after 2.12.0 (around 2026-10-14).

Line references are hints into `origin/dev` at `3474beb5`. Verify each against
the code before relying on it. Abbreviations: **SKC**
`SyncKeyController.swift`, **Coord** `PhiChromiumCoordinator.swift`, **Engine**
`Sources/Sync/Phi/PhiSyncEngine.swift`.

This is an architectural change. It replaces the partial mode in which sync
kept running and left out the Spaces of a Profile without a mapping.

## 1. Owner rulings (2026-09-29)

| # | Ruling |
| --- | --- |
| R1 | Every local Profile that is meant to sync takes part in sync. If one is not mapped to an account Profile, sync is paused as a whole until it is |
| R2 | The pause covers Chromium-side sync too. Chromium keys are withdrawn after a delay of 15 seconds, so a Profile that maps within seconds does not restart every Chromium sync engine |
| R3 | Native data pauses immediately. The Sync status shows the pause only after 15 seconds |
| R4 | A new local Profile is registered as a new account Profile automatically. The user is not asked |
| R5 | Every mapped Profile is loaded so it syncs without a window. First version: Swift only, through the existing bridge call. Memory per sync-only Profile is tolerable up to 200 to 300 MB and is to be measured |

Open, deferred to M3-4b: whether a Profile whose account Profile was deleted
by another device counts as unmapped (pause) or excluded.

## 2. Which Profiles the rule covers

`ProfileManager.userAssignableProfiles`: the bridge's Profile list minus the
agent fallback Profile. PhiChat, incognito, guest and system Profiles never
appear in it. `SyncKeyController.localProfilesProvider` and
`syncStatusProfileIDs` already read this list.

"Unmapped" has two meanings in code; the pause uses both:

| Meaning | Source | Used for |
| --- | --- | --- |
| No persisted mapping | `profileKeys.mappedGlobalUuid` | The immediate, synchronous check |
| Not resolved in the last measured pass | `SyncKeyController.resolved` / `stillUnmapped` | Covers a persisted mapping whose server envelope is gone |

Profiles that the key layer is itself creating (auto-create, the wizard's
"create local") are ignored by the predicate until their adopt step has
finished or failed.

## 3. Constraints found by reading the code

These decide the design. Breaking any of them produces a pause that never ends
or loses data.

1. **The pause has its own predicate and its own stop bit.** It must not flip
   `ProfilePairingGate.isPaired` and must not reuse
   `engine.suspendForPairing()`. Registration and adopt are gated on
   `isPairingComplete()` (SKC ~536), auto-create on `isPaired` (SKC ~720),
   Chromium key delivery on the same (SKC ~210).
2. **Auto-create runs only inside an engine pull today** (Engine ~2014-2037).
   While paused there is no pull. The repair pass (section 4.3) must call it
   from outside the engine.
3. **Nothing re-runs `resolveMappings` periodically.** Its triggers are the
   Profile list changing, unlock, join and pairing. A retry timer is required.
4. **Three existing defects turn into pause-forever or wrong data under this
   rule** and are prerequisites:

   | Item | Defect | Fix |
   | --- | --- | --- |
   | BH-14 | One new local plus one new remote Profile are merged by count (SKC ~554-562). D20 already cancels this | Remove the branch |
   | BH-15 | `try?` swallows register and adopt failures and the pass still reports `.measured` (SKC ~548, ~557) | Classify errors; see 4.3 |
   | A4 | An undecryptable remote Profile keeps `unclaimed` non-empty, which blocks registration for good (SKC ~538-539) | Register branch uses `unclaimed` minus the undecryptable set |

5. **Engine intents that are local writes must survive the pause.**
   `.recordLocalDeletion` and `.spaceGate` are dropped by the round entry
   guard today when the engine is stopped. `.preview` is already exempt and
   must stay exempt, because the pairing wizard needs it.
6. **Resume must not go through `startPhiSyncIfReady`.** It adds observers and
   publishers again without removing the old ones.
   `PhiSyncInvalidationCoordinator.start()` requests a catch-up by itself.
7. **The retention sweep runs once per engine start.** Queue it again on
   resume.
8. **Edits made during a pause are stamped at resume time** because settings
   and Space edits are stamped at round time. Accepted residual: such an edit
   can beat a peer's edit that was really made later.

## 4. Design

### 4.1 Predicate

A pure type `SyncProfileMappingPause` in `Sources/Sync/Keys/`, Foundation
only. Inputs: syncable local Profile ids, persisted mappings, the unmapped set
of the last measured pass, the set being created by the key layer. Output:
paused or not, the unmapped ids, and a reason.

| Reason | Meaning | Status category |
| --- | --- | --- |
| `registering` | A pass is running or due | None during the first 15 seconds, then `waitingForProfilePairing` |
| `retrying` | The last attempt failed with a transient error | `waitingForProfilePairing`; offline shown as offline |
| `needsAttention` | The server refused definitively | Needs attention, with a Retry action |

### 4.2 What pauses and how

| Activity | During a pause | Mechanism |
| --- | --- | --- |
| Engine rounds: pull, push, local-change rounds | Stopped at once | New `StopSignal` bit; generation bump aborts a round in flight |
| Retention sweep | Deferred | Queued again on resume |
| `.recordLocalDeletion`, `.spaceGate`, `.preview` | Keep working | Exempt from the new bit |
| Local-change publishers | Stay installed | Their rounds do nothing; `markLocalChangePending` must not show Syncing |
| Invalidation stream, timers, catch-up | Stopped | `PhiSyncInvalidationCoordinator.stop()` |
| `SyncHelper` rounds | Stopped | `isEligible` gains "not paused"; a `pauseReason` closure feeds the report |
| Chromium sync of every Profile | Stopped after 15 seconds | `profileSyncInfo` returns nil, then `notifyPhiSyncKeysChanged`. Withdrawing a key stops the engine without clearing metadata; returning the same key resumes it |
| Registration, adopt, auto-create | Keep working | Not gated by the pause; driven by the repair pass |
| Device approval, device list, self-revoke, reconfiguration | Keep working | Independent of the engine |

The synchronous check runs in the Profile-list sink (Coord ~412-429), before
any await, so a round in flight stops at its next stop check.

### 4.3 Repair pass and retry

`SyncKeyController` exposes one entry: run `ensureLocalProfilesForAccount()`
(twin search and auto-create), then `resolveMappings()`. Order matters: a
dead mapping then heals to the same uuid instead of forking.

Triggers while paused: entering the pause, a timer with growing delay (5
seconds up to 5 minutes), foreground and wake, unlock, the pane's Retry.

Error classes for register and adopt:

| Class | Examples | Result |
| --- | --- | --- |
| Transient | Transport, offline, 5xx, 401, not unlocked | Pass reports held, reason `retrying`, retry |
| Definitive | Bad envelope, unexpected 4xx | Reason `needsAttention` |

### 4.4 Resume

The mappings observer (Coord ~799-810) recomputes the predicate after a
measured pass. When clear: clear the engine bit, `invalidation.start()`,
`notifyPhiSyncKeysChanged` if keys were withdrawn, `membershipDidChange()` on
the helper, queue the retention sweep.

### 4.5 Status and pane

New phase for "paused, waiting for a Profile" in `SyncSummaryPhase` and
`SyncContextPhase`, distinct from "Not paired". The existing "Not paired" card
and its "Continue setup" action are not reused: once enrollment is complete
that action leads nowhere. The pane names the Profile (a local name, not sync
content), shows the reason, and offers Retry, which runs the repair pass.

The coordinator owns the predicate and produces the category. The Sync layer
emits enums only.

### 4.6 Loading every Profile

| Point | Decision |
| --- | --- |
| Call | `bridge.ensureProfileLoaded`, which loads without a window and takes no keep-alive of its own |
| Which Profiles | User-assignable, mapped, key ready, `isLoaded == false` |
| When | Starting 30 to 60 seconds after the first window, one at a time with a gap. Again whenever a refresh of the Profile list shows a mapped Profile unloaded (a Profile unloads after its last window closes). At once when the user asks for Sync now |
| Not while paused | Loading waits for the pause to end |
| Switch | A developer default, on by default, to turn loading off for measurement. Not synced, no UI |
| Helper policy | Stays `.waitForAllObservable` |

Dependency to document: a Profile loaded this way stays loaded because
Chromium gives every newly loaded Profile a "waiting for first browser window"
keep-alive that only a window clears. That is upstream behaviour, not a Phi
contract, and a Chromium rebase can change it. An explicit hold and release
call in the framework is follow-up work.

## 5. Contracts amended

| Document | Change |
| --- | --- |
| M3-2 design 3.5 | The gate gains "every syncable local Profile is mapped", for all data |
| M3-2 design 3.1 | `needsPairing` splits: the local half pauses, the remote half does not |
| M3-2 design 3.6 | Auto-create also runs outside engine rounds |
| M3-2 design 6.3, M3-2b design 3.2 and 3.4 | "Unmapped Profile: skip" becomes a defensive rule for excluded Profiles only |
| M3-4 rulings D20 | Content unchanged; implemented here |
| UX spec state table | New state, distinct from "Not paired" |
| `docs/sync.md` | Enrollment and setup; status contract; Chromium key lifecycle; Profile loading |
| KB `contracts.md` | Mapping readiness becomes an account-wide precondition |
| KB debt register | DI-1 closed by this rule plus the defensive fixes; BH-14, BH-15 closed |

## 6. Code that stays

Do not delete these; they protect against situations on the remote side:
the `currentSpaces()` filter on unmapped Profiles, `unresolvedProfile`
parking, `heldProfileUuid`, the dead-mapping repair, the unmapped-owner
handling of owned kinds.

## 7. Tasks

| # | Task | Files | Size | Verify |
| --- | --- | --- | --- | --- |
| P1 | Predicate type | New file under `Sources/Sync/Keys/` (register in the Xcode project) | S | New hostless harness, pattern of `test-sync-helper.sh` |
| P2 | Key layer: remove the 1:1 adopt; classify errors; undecryptable remotes no longer block registration; publish the unmapped ids; `profileSyncInfo` nil while keys are withdrawn; repair pass entry | `SyncKeyController.swift`, `ProfileKeyManager.swift` | M | `test-sync-pairing.sh`, `test-sync-pairing-retry.sh` |
| P3 | Engine stop bit with the three exemptions; quiet `markLocalChangePending`; status reason setter | `PhiSyncEngine.swift` | M | `test-sync-space-replay.sh`, `test-sync-status.sh` |
| P4 | Coordinator: synchronous check, observer, pause and resume sequences, retry task, 15-second key withdrawal, helper eligibility and reason | `PhiChromiumCoordinator.swift`, `SyncHelper.swift` | M | Extend `test-sync-invalidation.sh` or add an extraction harness; `test-sync-helper.sh` |
| P5 | Status phase, 15-second status grace, pane card with Retry, strings | `SyncStatusSnapshot.swift`, the Devices pane files, `Localizable.xcstrings` | M | `test-sync-status.sh`, `test-sync-helper.sh`; compile |
| P6 | Profile loader | New small type plus wiring in the coordinator | S-M | Hostless case for the selection and pacing logic; compile |
| P7 | Docs in the repository | `docs/sync.md`, UX spec, `docs/sync-e2e-test-cases.md` | S | — |
| P8 | Knowledge base | Section 5 rows, debt register, Chromium keep-alive note | S | — |

Order: P1, P2, P3, P4, P5, P6, P7, P8. One commit per task.

Base: the branch is built on the merge of `fix/sync-data-integrity` and
`feat/sync-now-kind-status`. P3 depends on the first (deletion recorded while
the engine is stopped; the apply loop's defensive checks), P5 on the second
(status types, request state, pane).

## 8. Manual checks, two Macs

| # | Check |
| --- | --- |
| M1 | Create a Profile on A: pause, then resume within seconds, no status flicker; Chromium data of the other Profiles continues without a fresh download |
| M2 | Create a Profile offline: stable pause with a reason after 15 seconds; go online: resumes by itself |
| M3 | A and B each create a Profile at the same time: two account Profiles, no merge |
| M4 | Move a synced Space onto a brand-new Profile on A, edit it on B: no duplicate, no overwrite |
| M5 | Delete a published Space during a pause: it does not come back after resume |
| M6 | An undecryptable account Profile exists: a new local Profile still registers |
| M7 | Import from another browser creating several Profiles: one pause, all registered, resume |
| M8 | Memory: with N Profiles, footprint of all Phi processes 10 seconds and 2 minutes after the background load, per additional Profile |
| M9 | Open a Space in a Profile that was loaded in the background: tabs restore correctly |

## 9. Accepted residuals

| # | Residual |
| --- | --- |
| A1 | Edits made during a pause carry the resume time (section 3, point 8) |
| A2 | Profile loading relies on upstream keep-alive behaviour until the framework has an explicit call |
| A3 | A Profile loaded without a window publishes an empty open-tabs header for this device |
