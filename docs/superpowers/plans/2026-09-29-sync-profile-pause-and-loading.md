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
| R3 | Native data pauses immediately (amended by section 10, pending the owner's confirmation: it pauses when the round in flight ends). The Sync status shows the pause only after 15 seconds |
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

## 10. Timing design for P3 and P4 (version 2)

Version 1 set the engine stop bit synchronously and bumped the generation, so
a round in flight was aborted. External review (Codex, 2026-09-29, twelve
findings, eight of them severe) showed that such aborts are not safe once
they become routine: an abort after a landing and before its baseline is
saved lets a later snapshot treat the landed value as a fresh local edit, and
an abort between an accepted first publication and its acknowledgement lets a
later local deletion go unrecorded. Version 1 also carried too much stored
state: the stored phase and the epoch invalidated the retry task on the way
from grace to paused, and the inert path could leave the feature's own bits
set. Version 1 is withdrawn.

Version 2 rests on two decisions:

1. **The pause takes effect at round boundaries.** No round is aborted. While
   the pause holds, no new round starts. A round already running finishes
   normally.
2. **Outputs are derived, not stored.** One idempotent function computes what
   the engine gate, the key withdrawal, the helper and the status should be,
   from the prerequisites, the predicate and the clock, and applies the
   difference.

This changes owner ruling R3 in one respect, to be confirmed by the owner:
native data no longer stops at once; it stops when the round in flight ends.

### 10.1 Owner and state

`PhiChromiumCoordinator` owns the pause. Main actor only, never persisted.

| Field | Meaning |
| --- | --- |
| `episode` | Nil, or an identifier plus the time the predicate first reported an unmapped Profile. It ends when the predicate is clear or the prerequisites are gone |
| `applied` | The outputs last applied: engine gate, keys withdrawn, status published. Used only to apply differences |

Presentation is derived: during the first 15 seconds of an episode nothing is
shown and Chromium keys are delivered; after that the pause is shown and the
keys are withdrawn.

### 10.2 One reconciliation function

`reconcileProfileMappingPause(profiles:)` is synchronous and runs on the main
actor. It takes the Profile list as an argument: the Profile-list sink passes
the value it was given, because the published property still holds the
previous list while the sink runs. Other callers pass the current list.

Callers: the Profile-list sink, the observers of
`.phiProfileMappingsDidResolve` and `.phiProfileAutoCreateDidRun`, the
15-second timer of the episode, the end of engine build, enrollment and
unlock changes before they enable work, and teardown.

| Step | Rule |
| --- | --- |
| 1. Prerequisites | Enrollment complete, account key unlocked, engine present, controller not retired. If any is missing the desired outputs are all off and the episode ends. The feature's own outputs are still cleared if they were applied, so nothing of this feature stays set |
| 2. Predicate | Evaluated on the given list, the persisted mappings, the key layer's unmapped evidence (10.6), the last pass result and the Profiles being created |
| 3. Episode | Predicate paused and no episode: start one, start its repair loop (10.5), arm one timer for its 15-second mark. Predicate clear and an episode exists: end it |
| 4. Desired outputs | Engine gate on while an episode exists. Keys withdrawn and status published while an episode exists and is at least 15 seconds old |
| 5. Apply differences | Gate on or off. Keys: set the flag on the controller, notify the bridge. Status: publish or clear the reason. On the change from gate on to gate off: request a catch-up from the invalidation coordinator, queue the retention sweep, tell the Profile loader to continue |

The invalidation coordinator is never stopped or started by this feature.
While the gate is on, the pulls it requests return at the round entry check.
`activatePairedSync()` and `startPhiSyncIfReady()` are not changed, except
that they call the reconciliation function before they enable work.

### 10.3 Engine gate

A nonisolated, lock-based flag next to `StopSignal`, not part of it: it does
not bump the generation and is not read by the write guards inside a round.
It is read in one place, the round entry check.

| Round type | While the gate is on |
| --- | --- |
| Pull, push, local-change rounds, retention sweep | Return at the round entry check without setting Syncing |
| `.preview`, `.recordLocalDeletion`, `.spaceGate` | Run normally |

`markLocalChangePending()` and the unconditional Syncing update in
`serialized()` do nothing for a round that the gate turns away.

A round that is running when the gate turns on finishes, including its
landings, cursor saves, acknowledgements and marker advance. For that one
round the existing behaviour applies: the Spaces of an unmapped Profile are
left out of the snapshot, and the apply loop's defensive checks keep an
existing row from being created again.

### 10.4 Profiles created by the key layer

No global flag. A Profile that the key layer creates is unmapped for a moment
before its id is known and until its adopt step ends. The reconciliation may
start an episode in that moment. Nothing is aborted, nothing is shown for 15
seconds, and the episode ends when the adopt step ends. The per-Profile
exclusion of P2 (`profileIdsBeingCreated`) stays and shortens that moment.

### 10.5 Repair loop

One loop per episode, identified by the episode. It calls
`runMappingRepairPass()`, never a bare resolve and never the startup unlock
path, waits, and repeats while its episode is the current one. The delay
starts at 5 seconds and doubles to 5 minutes. Foreground, wake, unlock and the
pane's Retry replace the pending wait with an immediate pass and reset the
delay, only while an episode exists. Outside an episode nothing of this
feature calls the key layer.

The Profile-list sink calls the repair pass instead of
`silentUnlockAndResolve()` when the controller is already unlocked, so a
failed device-envelope lookup no longer clears the key cache during an
episode.

### 10.6 Key layer additions (task P2b)

| Item | Change |
| --- | --- |
| Unmapped evidence | A Profile whose mapping is known to be absent on the server stays in the published unmapped set until it is positively resolved. A held pass and a cache clear while the account key is still available do not erase it |
| Retirement | Auto-create and create-and-adopt check retirement after every suspension and immediately before every mutation of the Profile list. Retiring the controller cancels the shared auto-create task |
| Failure category | The key layer publishes a status-only category next to the pass result: offline, sign-in expired, server error, other. The predicate's reason stays as it is |

### 10.7 Helper and status

The helper gets a pause-aware path, separate from eligibility and from
membership changes:

| Episode age | Helper |
| --- | --- |
| Under 15 seconds | Dispatches nothing. Keeps and returns its last report. A Sync now request stays queued and is dispatched when the episode ends |
| 15 seconds or more | Reports the pause phase with the reason and the failure category. A queued Sync now request is cancelled and marked as cancelled, so the pane announces nothing. The pane shows Retry instead of Sync now |

Ending an episode does not call `membershipDidChange()`.

### 10.8 Teardown

Sign-out, account switch, engine retirement and key-controller invalidation
end the episode, which stops its repair loop and timer, and run the
reconciliation, which clears the outputs of this feature by step 1.

### 10.9 Invariants and accepted residuals

| # | Invariant |
| --- | --- |
| I1 | While an episode exists, no pull, push, local-change round or retention sweep starts |
| I2 | This feature never aborts a round and never changes the generation |
| I3 | No step that ends the pause is stopped by the pause |
| I4 | Outputs of this feature are changed only by the reconciliation function, on the main actor, and are cleared whenever the prerequisites are missing |
| I5 | The feature installs no observer or publisher besides its own timer and repair loop, and never stops or starts the invalidation coordinator |
| I6 | Nothing about the pause is persisted |
| I7 | A device on which the predicate stays clear sees no change: no timer, no key-layer call, no withdrawal, no catch-up, no report change |

| # | Accepted residual |
| --- | --- |
| B1 | Edits made during a pause carry the resume time |
| B2 | A round in flight when an episode starts finishes under the old partial behaviour; the apply loop's defensive checks cover it |
| B3 | Chromium keeps syncing the mapped Profiles for the first 15 seconds of an episode |
| B4 | Reasons are per pass, not per Profile |
| B5 | The invalidation stream stays connected during a pause; its hints are dropped and the catch-up at the end replaces them |
| B6 | The two hazards of aborting a round (baseline lost after a landing; acknowledgement lost after an accepted first publication) remain for the existing abort paths, unpairing and reconfiguration. They are recorded in the debt register and are not made more frequent by this feature |

## Implementation notes

### P1 (commit `00b8b45f`)

| # | Deviation | Why |
| --- | --- | --- |
| N1 | `SyncProfileMappingPause.evaluate` takes a fifth input, `lastPassResult: SyncProfileMappingPassResult?`, next to the four in 4.1 | The reason (`registering` / `retrying` / `needsAttention`) cannot be derived from the four sets. The enum lives in the predicate's file, so the predicate stays Foundation-only and the key layer publishes that type |
| N2 | Reason is pass-level, not per Profile | The key layer classifies a pass, not each Profile. A definitive failure anywhere in the last pass gives `needsAttention` while any Profile is unmapped |

### P2

| # | Deviation or addition | Why |
| --- | --- | --- |
| N3 | The register branch also ignores account uuids that the persisted mapping gives to a local Profile that no longer exists (`claimable = remote − claimed − undecryptable − persisted-mapped`) | A deleted local keeps its mapping entry, so auto-create never grows that account Profile back and nothing on this Mac can claim it. Without this, one deleted Profile holds registration of every new local for good, which under R1 is a pause that never ends. Neither the twin search nor auto-create could ever adopt such a uuid, so no adopt is lost |
| N4 | `ensureLocalProfilesForAccount()` is single-flight (a caller arriving mid-round gets that round's outcome) | The repair pass calls it from outside the engine; two interleaving rounds would each create a Profile for the same uuid |
| N5 | Lookup failures of mapped locals are classified too, not only register and adopt failures | A mapped local whose envelope no longer opens (definitive) was held silently forever; it now reports `.definitiveFailure`. The pass is still `.held` for the predicates, as before |
| N6 | An error type not listed in the classifier is transient | Before BH-15 every failure was retried on the next trigger; that stays the default. `ProfileKeyManagerError.alreadyMapped` is transient (the next pass sees the mapping that refused it) |
| N7 | A measured pass that leaves a Profile unmapped reports the latest auto-create round's failure class | Otherwise a Profile waiting behind an account Profile that auto-create keeps failing to claim reads as `registering` forever. `createLocalProfileAndAdopt` throws `badEnvelope` for "the bridge made no Profile" as well, so that case reports `needsAttention` |
| N8 | A Profile leaving `profileIdsBeingCreated` without an adopt posts `.phiProfileMappingsDidResolve` as `.held` | No pass follows a failed adopt, and the pause has to count that Profile at once. `.held` changes nothing for the pairing gate |
| N9 | A transient register failure now holds `needsPairing` / `needsPairingActionable` instead of setting them true | Required by "held, not measured-unmapped". Only the pairing gate reads them on announcements, and it acts on `.cleared` only; the Sync pane reads enrollment, not these |
| N10 | BH-16 done: the auto-create cap counts attempts (twin adopts and creates), not successes | Small; a round whose creates keep failing now stops after three attempts |
| N11 | Known gap for P4: a Profile enters `profileIdsBeingCreated` only after `createProfile` returns its id, but `ProfileManager.createProfile` refreshes the list (and so fires the `$profiles` sink) in the same main-queue block just before it completes | The synchronous check in the sink sees the new Profile as unmapped for that one step. P4 must tolerate it (for example evaluate after the sink's hop, or treat a creation in flight as ignorable); the key layer cannot name a Profile before the bridge does |

### P2b

| # | Deviation or addition | Why |
| --- | --- | --- |
| N12 | `lastMeasuredUnmappedProfileIds` is replaced by `knownUnmappedProfileIds` (non-optional), and the predicate's input is renamed to match. It is not a second property beside the measured set | The evidence set contains every Profile the measured set did (a measured pass adds its unmapped Profiles to it) and differs only in surviving held passes and a cache clear. Keeping both would give the predicate two inputs of which one is always a subset of the other; the old name would describe the wrong meaning. The hosted test that read the old name reads the new one |
| N13 | A Profile enters the evidence on a 404 only when it has a persisted mapping; a Profile with no mapping enters it only through a measured pass | The predicate already pauses for a Profile with no persisted mapping, so a "no mapping, so nothing to look up" nil adds no information |
| N14 | A successful adopt (twin adopt, create-and-adopt) removes the adopted Profile from the evidence, besides a pass that resolves it | Otherwise the wrap-up pass after an adopt must succeed before the pause ends; a transient failure in that pass would keep pausing for a Profile that is mapped and readable |
| N15 | An auto-create round stopped by retirement returns `.failed` and posts no `.phiProfileAutoCreateDidRun`, although that notification was documented as posted before every return | A retired resolve pass announces nothing either (review A11), and `.failed` is what `PhiSpaceLocalAccess` already answers for a dropped controller. The observers (pairing gate hysteresis, Space gate refresh) belong to the account that is gone |
| N16 | `createLocalProfileAndAdopt` throws `CancellationError` once retired: before the create, after the create returns, and after the adopt returns | Callers must not count the Profile as created. The pairing wizard already checks `isRetired` before each decision and reports a generic failure for the throw, which only a retired (torn-down) controller can see |
| N17 | Residual: `ProfileKeyManager.adoptRemoteProfile` writes the mapping right after its own envelope lookup returns, with no suspension in between that the controller could fence. A retirement that lands inside that lookup can still write one mapping | The store is account-scoped, so the write lands in the retired account's table and names a Profile of that account; fencing it would need a retirement hook inside `ProfileKeyManager`, outside this task. The same holds for `registerLocalProfile` since review A11 |
