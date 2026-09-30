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
| R3 | Native data pauses immediately (amended by section 10, confirmed by the owner on 2026-09-29: it pauses when the round in flight ends; a pause never aborts a round that has been admitted). The Sync status shows the pause only after 15 seconds |
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
| M10 | With a mapped Profile that has no window on B, install on A an extension that opens a welcome tab on install: no window appears on B for that Profile |
| M11 | Delete a Profile that was loaded in the background: its directory is removed without restarting the app |

## 9. Accepted residuals

| # | Residual |
| --- | --- |
| A1 | Edits made during a pause carry the resume time (section 3, point 8) |
| A2 | Profile loading relies on upstream keep-alive behaviour until the framework has an explicit call |
| A3 | A Profile loaded without a window publishes an empty open-tabs header for this device |
| A4 | Background-loaded Profiles stay loaded after sign-out, account switch or removing this Mac from sync: the loader stops but has no unload call, and a load in flight at teardown completes and stays loaded. They are released when the app quits. Follow-up: the explicit hold and release call in the framework (A2) |

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

### 10.10 Amendments after the second review

The second external review (Codex, 2026-09-29) found all twelve findings
against version 1 closed, three of them by task P2b, and confirmed the
round-boundary rule as sound for data integrity. It raised four new points.
They are folded in here; no further design review is planned, the
implementation is reviewed as code.

Amendment AM-1 and the owner ruling R3 as amended were confirmed by the owner
on 2026-09-29: native data pauses when the round in flight ends, a pause never
aborts a round that has been admitted, and at launch no device starts a round
before the Profile list has been enumerated. P3 and P4 may start.

| # | Finding | Amendment |
| --- | --- | --- |
| AM-1 | At launch the Profile list is empty until the first refresh succeeds. The predicate reads an empty list as "nothing to sync" and admits rounds. With an empty list the apply loop can also treat a valid mapped Profile as missing and drop its mapping, and the key layer prunes its unmapped evidence against that list (note for P4, item 6 of the P2b report) | `ProfileManager` exposes whether the list has been enumerated successfully at least once. Until then the engine gate is on, no episode is started, no key is withdrawn, and the status stays at Checking. A failed refresh is retried with the delays of 10.5. The key layer does not prune evidence against a list that has not been enumerated. This applies to every new engine before its first round is requested |
| AM-2 | A helper round that was dispatched just before an episode starts never reaches the coordinated success it waits for | On episode start the helper invalidates the observations of a round in flight and keeps the request as queued. At 15 seconds the request is cancelled and marked as cancelled. When the episode ends a fresh round is created. The engine round itself is never cancelled. The pause check is repeated after every asynchronous participant read |
| AM-3 | The exempt round types share the common tail of a round, which drains the favicon backfill queue and starts network requests | A round that was admitted only through the exemption, while the gate is on, skips the favicon tail. The admission decision is carried to the tail; no check is added inside the round's data writes |
| AM-4 | Replacing `silentUnlockAndResolve()` by the repair pass in the Profile-list sink also changed devices that are not paused | The replacement applies only while an episode exists |

Implementation constraints confirmed by the review:

| Point | Constraint |
| --- | --- |
| Admission | The gate is checked inside `run(_:)` after the wait for the previous round, not where the round is queued |
| Chained work | Pull-then-publish and conflict retries are part of the admitted round and finish. A follow-up pull of a page budget is a new round and meets the gate |
| Publication after a pause | The catch-up at the end is sufficient: its pull is followed by the publication of every native kind |
| Notifying the bridge | `episode` and `applied` are committed before the bridge is notified |
| Status | The pause is presented as an overlay computed when the status is read, not as a phase written once, because the completion of the admitted round writes the phase |

Changes to the invariants and residuals of 10.9:

| # | Change |
| --- | --- |
| I7 | Scoped to P3 and P4, with one exception: at launch no device starts a round before the Profile list has been enumerated (AM-1). The background loading of Profiles (P6) changes resource use on every device by design and is not covered by I7 |
| B7 (new) | During the one round that finishes after an episode has started, a deletion of a Space that arrives from the account is applied even if the Space belongs to the unmapped Profile: the Space is hidden and its contents are kept for the retention period |
| B8 (new) | A retirement during the adopt step's own lookup can still write one mapping into the retired account's own store (implementation note N17) |

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
| N18 | "Latest failure" is the last failure the pass met in its order (lookups, listing, registrations); a measured pass that reports the auto-create round's failure (N7) reports that failure's category. `clearResolved()` clears the category together with the pass result | The category explains the result beside it, so the two are set and cleared together. Consequence for P4: a failed startup unlock (offline) goes through `clearResolved()` and leaves no category; the prerequisites step, not the category, covers "not unlocked" |
| N19 | Offline is `KeyAPIError.transport` wrapping `URLError` `.notConnectedToInternet`, `.networkConnectionLost`, `.cannotFindHost`, `.cannotConnectToHost`, `.dnsLookupFailed`, `.timedOut`, `.internationalRoamingOff`, `.dataNotAllowed`. A transport error wrapping `.userAuthenticationRequired` (the envelope client's "no token to send") is sign-in expired | `.timedOut` is counted as offline because a 45-second request timeout on this backend almost always means no usable connection. Other transport errors (TLS, bad response, cancellation) are `other` |

### P6

| # | Deviation or addition | Why |
| --- | --- | --- |
| N20 | The initial delay counts from `startPhiSyncIfReady()` passing its guards, not from the first window | That is the one moment at which the account is unlocked, enrollment is complete and native sync runs. At launch it follows the silent unlock, a network round trip after Chromium's session restore has opened the first window. The Swift side has no single "first window" signal that also says sync can use a Profile |
| N21 | Sync now reaches the loader through a new `PhiChromiumCoordinator.requestSyncNow()`, which the Devices pane calls instead of `syncHelper.requestSyncNow()` (one line in `DevicesSettingHostingViewController`) | The helper never dispatches while a Profile is Checking, so a Chromium participant's `requestSync` is never called for the case that matters. Wrapping the call keeps the helper free of any loader dependency |
| N22 | Nothing refreshes `ProfileManager` when a Profile unloads: the bridge has no Profile load or unload callback, and `$profiles` only changes on an explicit `refresh()`. The loader asks for a refresh every 60 seconds while it runs, and a second `$profiles` subscription (not deduplicated by id, unlike the key layer's) re-evaluates after every refresh by anyone else | Smallest check that sees an unload; `listProfiles` is a synchronous in-memory read. The subscription hops to the next main-actor turn because `@Published` emits before storing and the loader's own refresh must not re-enter it |
| N23 | A load that has not completed after 60 seconds counts as failed; a Profile the loader has just loaded waits 60 seconds before a list that still says "not loaded" can ask again | A completion that never fires would otherwise stop loading for good; the cached list stays stale until the next refresh |
| N24 | Pacing values: gap 5 s, retry 30 s doubling to 10 min, recheck 60 s | "A few seconds" and "growing delay" made concrete. 15 Profiles need about 30 s + 15 x (load) + 14 x 5 s, roughly 1 minute 45 seconds |
| N25 | The loader receives the whole Profile list with a user-assignable flag instead of `userAssignableProfiles` | So the harness can prove that the agent fallback Profile is skipped. It has no mapping either, so the key check skips it too |
| N26 | A Sync now request while the loader cannot load (paused, not enumerated, ineligible, switched off) is dropped, not queued | The helper's own queue (plan 10.7) decides what a Sync now during a pause becomes; the loader continues through `evaluate()` when the pause ends |
| N27 | Hooks for P4: `isPaused` and `isProfileListEnumerated` are closures of `SyncProfileLoader.init` with the defaults "not paused" and "enumerated"; the coordinator passes neither yet. P4 passes "an episode exists" (engine gate on) and AM-1's "list enumerated", and calls `syncProfileLoader?.evaluate()` where 10.2 step 5 says "tell the Profile loader to continue" and when the list is enumerated for the first time | P3 and P4 are not implemented yet |
| N28 | Review F1: the loader's 60-second recheck calls a new `ProfileManager.refreshIfChanged()` instead of `refresh()`. It does the same bridge read and decode, assigns `profiles` only when the decoded list differs (`PhiBrowserProfile` is `Hashable`, so the comparison includes `isLoaded` and `isInUse`), and runs neither the chat-archive drain nor the display-name upserts. `refresh()` is unchanged | Candidate (a) of the review. No `refresh()` caller waits for an emission (all read `profiles` synchronously after the call) and no subscriber relies on a publish of an unchanged list: the key layer's `$profiles` sink deduplicates by id, the loader's own sink only re-evaluates, and the SwiftUI observers (and `AllDownloadsListView`'s `onChange`) only re-render. So (b) was possible too, but it would change what about 30 other `refresh()` calls do (settings pane `onAppear`s, agent Space routing, import repair, the key layer's `localProfilesProvider`, the create/rename/delete completions) and need a flag to keep the side effects for them; (a) leaves them exactly as they are. Every Profile mutation goes through `refresh()`, so a change the light read publishes is in practice a load or in-use change; if it ever is a rename or a new Profile, the next `refresh()` runs the side effects |
| N29 | Review F2: no unload at teardown; documented as residual A4 and in docs/sync.md's Teardown row, no code change. Manual checks M10 (an extension's welcome tab must not open a window for a background-loaded Profile) and M11 (deleting a background-loaded Profile removes its directory without a restart) added; both need real builds. docs/sync.md now states that a started loader that cannot load wakes once per recheck interval without refreshing or loading, and the harness proves it and that nothing runs before it is started | Unloading needs the framework's hold and release call; `ensureProfileLoaded:` has no counterpart today |
| N30 | Review F3: `loadNow()` clears the recheck time, so the step it triggers re-reads the Profile list (`refreshIfChanged()`, N28) before choosing what to load. The recheck interval then counts from that read | Otherwise Sync now worked from a list up to 60 seconds old and missed a Profile whose last window had just closed |
| N31 | Review F4: the loader's `isEligible` also requires `!nativeSyncRequiresReconfiguration` (the engine's `requiresReconfiguration`: set by `not_my_birthday` or `pauseForReconfiguration()`, and read from the persisted `sync/marker.json` flag when the engine is built) | Confirmed by reading: in that state `SyncKeyController.profileSyncInfo` still returns keys (it checks only pairing complete and `chromiumKeysWithdrawn`, which nothing sets; `resolved` is cleared only by the confirmed cleanup), so mapped Profiles still had a deliverable key and loading went on. The engine flag, not `SyncKeyController.requiresReconfiguration`, because `isEligible` already requires this engine and the controller's getter reads the marker file from disk at every evaluation. Leaving the state needs the confirmed cleanup, which retires the engine and so rebuilds the loader |

### P3

| # | Deviation or addition | Why |
| --- | --- | --- |
| N32 | The engine gate is a private lock-protected class `ProfileMappingGate` beside `StopSignal`, with `nonisolated func setProfileMappingPause(_ paused: Bool)` and `nonisolated var isProfileMappingPaused: Bool`. `run(_:)` reads it once, after the retirement check, the preview's early return, the blocked-deletion path and `guard !isStopped`, and before any round state is reset or the status is touched. Nothing else in a round reads it | Section 10.3 and the admission constraint of 10.10. The pairing stop (`suspendForPairing()`, `paired`, the generation) is untouched |
| N33 | No status reason setter in the engine, although the task table names one for P3 | Section 10 moves the status out of the engine: the coordinator publishes the reason (10.2 step 5), the helper reports the pause phase (10.7), and the pause is an overlay computed when the status is read (10.10). The engine exposes only `isProfileMappingPaused`; the overlay is P5's |
| N34 | No initialiser parameter for AM-1 | `buildPhiSyncEngine` builds the engine synchronously on the main actor and the initialiser queues no round, so turning the gate on right after the constructor (where `pauseForReconfiguration()` already runs) is in force before any round is requested. The `ProfileManager` "enumerated" flag is not part of P3 (not listed under it) and is left to P4 |
| N35 | The queue's Syncing update in `serialized(_:)` is decided when a round is queued; admission is decided when it runs. A round queued with the gate off and turned away later leaves the Syncing written at queue time, and `queuedDataRounds` still counts it, so a round in flight when the gate comes on can finish as Syncing (a follow-up is queued) instead of Up to date. The status then reads Syncing until P5's overlay (after 15 seconds) or the catch-up round that ends the episode | Correcting it in the engine would need either a gate read inside the round's completion or a status write for a round that is turned away; both add engine reads of the gate that 10.3 does not have. The overlay of 10.10 is the owner of what the pause shows |
| N36 | AM-3's carried decision is set only for the Space gate edge and the local deletion intent. The preview is exempt through its existing early return, which already never reached the favicon tail | No change to the preview path was needed |
| N37 | The local deletion intent while the engine is also stopped (pairing, reconfiguration, generation change) keeps its existing blocked path, which runs before the gate check. With only the gate on it runs as an ordinary round without the favicon tail | The blocked path is unchanged; the exemption adds nothing to it |
| N38 | Hostless coverage is a new fixture `Tests/SyncStatus/RoundAdmissionFixture.swift`, run by `test-sync-status.sh`, which extracts the production `StopSignal`, `isStopped`, the gate and its accessors, `Round`, `requiresReconfiguration`, `markLocalChangePending()`, `serialized(_:)` and `run(_:)`; round bodies are stand-ins that record what ran. `test-sync-space-replay.sh` is not extended: none of the methods it extracts changed, and the Space gate exemption is decided at admission, which the new fixture covers | The cases the task asks for need the queue, the admission and the tail together. Mutating the admission check or the tail condition makes the fixture fail |

P4 must call:

| When | Call |
| --- | --- |
| Right after `PhiSyncEngine(...)` in `buildPhiSyncEngine`, while the Profile list has not been enumerated (AM-1), or as part of the reconciliation that runs at the end of engine build, before any round is requested | `engine.setProfileMappingPause(true)` (nonisolated, synchronous, main actor safe) |
| Reconciliation step 5, gate desired on (episode exists, or list not enumerated) | `engine.setProfileMappingPause(true)` |
| Reconciliation step 5, change from on to off | `engine.setProfileMappingPause(false)`, then `phiInvalidationCoordinator?.requestCatchUp()`, then `Task { await engine.runRetentionSweep() }` (a sweep queued while the gate was on, including the one `startPhiSyncIfReady()` queues, was turned away), then `syncProfileLoader?.evaluate()` |
| `SyncProfileLoader.init` | `isPaused: { [weak engine] in engine?.isProfileMappingPaused ?? false }` or the coordinator's own episode state, and `isProfileListEnumerated:` from `ProfileManager` (N27) |
| Teardown | Nothing on the engine is required: a retired engine turns every round away already, and a new engine starts with the gate off. Clearing it on a retired engine is harmless |

### P4 (commits `6d172aef`, `9171ce5c`, `cd27048a`, `6590d9c4`)

| # | Deviation, interpretation or addition | Why |
| --- | --- | --- |
| N39 | The episode, the outputs last applied and the timers live in `SyncProfileMappingPauseReconciler` (`Sources/Sync/`), of which the coordinator holds the only instance (`profileMappingPauseState`). Only `reconcileProfileMappingPause(profiles:)` drives it; `kickRepair()` touches only the repair loop. The pure steps are `nextEpisode` (step 3), `desiredOutputs` (step 4) and `profileListFollowUp` (AM-4) | 10.1 names the coordinator as owner; keeping the state in a small injected type lets `build-scripts/test-sync-profile-mapping-episode.sh` run it hostless, as `SyncProfileLoader` does |
| N40 | Every applied output carries the identity of the object it went to (engine for the gate and the helper, controller for the key flag). An output applied to an object that is no longer current is forgotten, not cleared, and a gate that goes off on an engine that is gone does not resume | A new engine starts with its gate off and a new helper with no pause, so teardown only has to reconcile without an engine; no resume (catch-up, sweep, loader) runs on teardown |
| N41 | Prerequisites: engine present, controller present and not retired, account key unlocked, `ProfilePairingGate.isPaired` and `phiSyncPairingEnabled` | "Enrollment complete" read as "enrolled and activated", the same pair the helper's eligibility uses; during activation after a fresh pairing no episode starts before sync is enabled |
| N42 | The AM-1 gate applies whenever an engine exists and the list has not been enumerated, whatever the other prerequisites | AM-1 applies "to every new engine before its first round is requested"; exempt rounds (preview, Space gate, local deletion) are unaffected by the gate anyway |
| N43 | The AM-1 list retry is a reconciler timer, armed while an engine exists and the list is not enumerated, at 5 s doubling to 5 min. It calls `ProfileManager.refresh()` (not `refreshIfChanged()`) and then reconciles | A first successful read is the ordinary first population and should run `refresh()`'s side effects like any other; it publishes, and the Profile-list sink reconciles with the new list |
| N44 | Resume (P3 table item 3) runs in its order, but the catch-up and the retention sweep only while the invalidation coordinator is running, that is, once `startPhiSyncIfReady()` has started the schedule. The loader always re-evaluates | Before that start nothing was turned away, and the start requests its own catch-up (`invalidation.start()`) and queues its own sweep. At launch the first enumeration usually opens the gate inside the silent unlock, before the start, and an unconditional sweep would queue a second one. `requestCatchUp()` is a no-op on a stopped coordinator in any case |
| N45 | The status value is `SyncProfileMappingPauseStatus` (`.none`, `.grace`, `.paused(reason:failureCategory:unmappedProfileIds:)`), declared beside the predicate so the helper harness needs no coordinator type. The helper's `Report` gains `profileMappingPause` and `syncNowCancelledByPause`; `SyncStatusSnapshot.swift` is untouched | `SyncRequestState` has no cancelled case and that file belongs to P5; "cancelled and marked as cancelled" is `request == .idle` with the flag set |
| N46 | During the grace the helper keeps its summary and snapshots and reads no participant, but `request` shows a queued Sync now as `.queued(.busy)` | "Keeps and returns its last report" together with "a Sync now request stays queued": the request state describes that request, and Busy is the existing reason that says "waiting for the current sync" |
| N47 | Helper episode start (`.none` to `.grace` or `.paused`): new generation (the observation in flight and its refresh task are dropped), the round in flight and an early-ended round are dropped, a Sync now the round carried becomes pending again, `needsRound` is set. Episode end: `needsRound` is set; the fresh round is dispatched on the helper's poll under the existing minimum interval | AM-2. Not a membership change (10.7): observed ids, the common time, the persistence failure and the rate limit are kept |
| N48 | The shown pause survives `membershipDidChange()` and `resetIneligible()` in the report; the Sync now cancellation flag clears on the next request, at episode end and on those resets | The Profile-list sink still calls `membershipDidChange()` on every membership change, including the one that starts an episode |
| N49 | The repair loop runs its first pass when the episode starts. A kick while a pass runs asks for exactly one pass after it. The Profile-list sink and the unlock observer kick only an episode that existed before their reconciliation; a new episode's own first pass covers the rest | Two passes for one event would each list the account; both halves are single-flight, so the second would only wait for the first |
| N50 | The 15-second timer is armed again for the remainder when it fires before the injected clock has reached the mark | `Task.sleep` and `Date()` are different clocks; a timer that fired a few milliseconds early would otherwise never withdraw the keys |
| N51 | A reconciliation re-entered from one of its own effects (the loader's `evaluate()` can publish the Profile list, whose sink reconciles synchronously) is queued and runs right after the current one with the latest inputs | The state is committed before any effect, so the re-entered call is correct, but its effects must not interleave with the remaining effects of the outer call |
| N52 | Foreground and wake kick the repair loop from the two observers `startPhiSyncIfReady()` already installs; no observer is added | I5. An episode requires activation, after which the schedule starts at once, so those observers exist whenever an episode can |
| N53 | AM-1's "the key layer does not prune evidence against a list that has not been enumerated" is in `SyncKeyController` (P2b's file): an injected `isProfileListEnumerated` (default true, so hosted tests are unchanged) guards the intersection in `noteUnmappedEvidence` | The pass reads the list through `localProfilesProvider`, which cannot tell "no Profiles" from "not read yet" |
| N54 | The Profile-list sink deduplicates the full list by ids (`removeDuplicates(by:)`) instead of mapping it to ids first | It passes the list itself to the reconciliation (10.2); the emissions are the same |
| N55 | I7 on this diff. New timers: the 15-second mark and the repair wait (only while an episode exists), the list retry (only while an engine exists and the list is not enumerated: AM-1's exception). New tasks: one per repair pass (only inside an episode), one per timer. No new observer or subscription. Work added to existing triggers on a device with no episode: the reconciliation evaluates the predicate (a defaults read of the mapping table and property reads) and applies nothing; `kickRepair()` returns at once; the sink's follow-up is `silentUnlockAndResolve()` as before; the helper's pause is `.none` and its paths are unchanged. The harness case "a device with no episode" proves no timer, no effect and no log over ten minutes of triggers, kicks, a failed pass result and an engine rebuild | Checked by reading the diff and by the harness |
| N56 | Not covered hostlessly: the coordinator's wiring (which trigger calls the reconciliation, the effect closures, the sink's pipeline), the P2 N11 path in the running app, and the pane's Retry, which P5 wires to `retryProfileMappingRepair()` | These need the app; the build compiles them |

P5 receives:

| From | Member | Type | Meaning |
| --- | --- | --- | --- |
| `SyncHelper.report` | `profileMappingPause` | `SyncProfileMappingPauseStatus` | `.paused(reason:failureCategory:unmappedProfileIds:)` while an episode is 15 seconds or older, `.none` otherwise (the grace included). Overlay it on `summary` when the status is read |
| same | `.paused` `reason` | `SyncProfileMappingPause.Reason` | `registering`, `retrying` or `needsAttention`, from the last pass (per pass, residual B4) |
| same | `.paused` `failureCategory` | `SyncProfileMappingFailureCategory?` | Offline, sign-in expired, server error or other; nil after a pass that failed nothing and before any pass |
| same | `.paused` `unmappedProfileIds` | `[String]` | Sorted local Profile ids; the pane looks the names up in `ProfileManager` |
| `SyncHelper.report` | `syncNowCancelledByPause` | `Bool` | A queued Sync now request was cancelled by the shown pause; `request` is `.idle`, and the pane announces nothing |
| `SyncHelper.report` | `profileListNotEnumeratedSince` | `Date?` | The engine gate is on because the Profile list has not been enumerated (AM-1), since the engine was built; nil otherwise. Kept across membership changes and ineligibility, cleared at helper stop. The time since is `now - value`; a device whose list read keeps failing shows nothing else (review R3) |
| `SyncHelper.report` | `request` | `SyncRequestState` | Unchanged type. During the grace a Sync now shows as `.queued(reason: .busy, notBefore: nil)` |
| `PhiChromiumCoordinator` | `retryProfileMappingRepair()` | `@MainActor () -> Void` | The pane's Retry: an immediate repair pass and the first delay again; nothing outside an episode |
| `PhiChromiumCoordinator` | `requestSyncNow()` | unchanged | While the pause is shown the helper cancels the request at once |

### Review fixes, second round (R2 to R8)

| # | Deviation, interpretation or addition | Why |
| --- | --- | --- |
| N57 | R2(a): `reconcile(_:profileListFollowUp:)` takes the Profile-list sink's follow-up. A reentrant call queues its inputs and its follow-ups as one pending value (the latest inputs win, every follow-up queued so far is kept), and the loop delivers them right after the step for those inputs, with the choice made from the episode before and after that step. `runProfileListFollowUp(_:)` in the coordinator does what the sink did after its reconciliation | A sink nested in a reconciliation (the resume lets the loader publish the list) used to choose from the episode as it stood before its own inputs were applied, and scheduled a silent unlock beside the repair of the episode those inputs started. Keeping inputs and follow-ups in one value means a queued follow-up cannot outlive the loop that takes it; Swift has no exception that could unwind between queueing and delivery. The harness proves exactly-once delivery for two nested sinks, a plain reconciliation queued behind them and a sink inside a delivery |
| N58 | R2(b): `shouldRunDeferredSilentUnlock(chosenFor:current:hasEpisode:)` is checked when the follow-up's task runs, before `silentUnlockAndResolve()` is called. The check cannot cover an episode that starts while that call is already waiting on the device-envelope lookup | That window exists without the pause too (see the report on `silentUnlockAndResolve()`); closing it would change the key layer's failure path, which this round does not touch |
| N59 | R3: the AM-1 list retry has its own cap, `Timing.maximumListRetryDelay` = 30 s (5, 10, 20, 30, 30, ...); the repair loop keeps 5 minutes. The cap is logged once per wait and the enumeration after it once, with elapsed seconds only. The wait is an output of the reconciliation (`Outputs.listNotEnumerated`, bound to the engine like the gate, its start carried from the previous `applied`), handed to the helper by `setProfileListNotEnumerated(since:)`; an engine that is gone has its wait forgotten, not cleared | While the list is unread no round starts at all, so a five-minute wait delays the start of sync; a read that never completes (one entry that does not decode) otherwise leaves the gate on silently. The start is the first reconciliation that sees the engine with the list unread, which is the one at the end of `buildPhiSyncEngine`, so it is the engine's build time without a new stored property |
| N60 | R4: `Inputs.controllerIsBeingRetired`, set only by the reconciliation in `stopPhiSync()`, makes step 5 forget keys withdrawn from that controller instead of clearing the flag and notifying. `stopPhiSync()` has one caller, `invalidateSyncKeyController()`, which calls `retire()` right after it; `retire()` goes through `clearResolved()`, which notifies when the cache was populated, and the function notifies again at its end | Restoring first would let Chromium restart every Profile's sync with the old account's keys between the two notifications. The retired controller keeps `chromiumKeysWithdrawn` set, which only makes its already empty cache answer nil. 10.8's "clears the outputs of this feature" holds for the gate and the helper through N40, and for the keys through `retire()` |
