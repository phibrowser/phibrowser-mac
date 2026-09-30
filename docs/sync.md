# Phi sync publishing

For manual cross-device acceptance, see the [Sync E2E test cases](sync-e2e-test-cases.md).

## Enrollment and setup

Settings exposes **Sync**; the internal `devices` route remains stable. The pane
shows account/status, active devices and approval requests,
and recovery/removal. Device metadata comes from `GET /keys/v1/devices` through
`KeyEnvelopeAPIClient`; `created_at` is never displayed as last activity.

`ProfilePairingGate` owns `sync.pairingEnrollment` in account defaults. Version 1
records the device key ID and explicit complete/unpaired result. Missing,
malformed, future-version and mismatched-device records are unpaired. Completion
persists the verified post-registration device identity before permitting data
sync. The optional `recoveryConfirmationRequired` field defaults to false for
older version-1 records. First-device setup durably sets it before bootstrap;
`setPaired(true)` rejects completion while it remains true. Beginning enrollment
preserves it. Explicit reconfiguration/removal clears the old enrollment. Revoked-device registration can rotate that identity; the native HTTP
client resolves it for each request instead of retaining the pre-join ID.
Invalidation fails closed in memory even if its persistence fails.

First-device setup states that the recovery code is shown only once. **I've saved
it** discards the display and opens an empty confirmation page. The existing
recovery-code decoder and account-envelope decryption verify the supplied code;
only successful verification and durable clearing of the pending flag permit
Profile/Space matching. A valid checksum alone is insufficient. No recovery code
or derived secret is persisted. Wrong input and transport/storage failures retain
the confirmation page and keep sync off. Re-entry can be deferred by closing the
window; reopening or restarting requires confirmation even when device-key unlock
succeeds. The one-time display itself still cannot be dismissed. Full pairing
remains a separate prerequisite for native writes and Chromium ready-key exposure.
If bootstrap throws before returning a code, the pending flag is cleared: a lost
account-creation response must not claim that the user saved an unseen code.
An existing account then uses the ordinary join/recovery choices. This does not
add a reset for an account whose only recovery code was lost during creation.
Local enrollment/confirmation writes report a local save error, distinct from
connectivity failures, and a failed confirmation write keeps the gate closed.

Legacy completion migrates only after fresh device authorization, unlocked keys,
fresh remote Profile/Space evidence, complete injective mappings, and the legacy
enabled/drained Space state have all been verified. An explicit pending flag
prevents migration. Mapping resolution or ARK unlock alone never proves enrollment.
A check that fails transiently (offline, token refresh) retries with backoff, and
an explicit setup request runs one attempt before starting a new enrollment.

Setup has one modal host through introduction, verification, Profile/Space
matching, overwrite review and completion. Finish later appears only after
verification, on the pairing pages; the join-method and approval-waiting pages
have no Finish later button. Escape and window close, and Finish later in pairing,
retain unpaired status and discard unsubmitted choices. They remain available
while loading/reviewing/revalidating; confirmed writes and recovery-code
acknowledgement cannot be dismissed. Background work never reopens setup.
Mapping notifications affect only the setup session's current controller. A late
`.cleared` from a retired previous controller cannot dismiss another account's
verification or recovery-code window; retiring the current controller still does.
Closing an actual setup session refreshes the Sync pane's device authorization
state without changing enrollment. A verified device that defers matching remains
unpaired, with its device list and removal controls available.

Cancelling an approval request, switching to recovery, or closing verification
withdraws that request using the existing account-authenticated join-request deny
endpoint. Late POST responses are withdrawn by exact request ID. New requests
wait for earlier creates on the same account manager and withdraw outstanding
tickets for the exact device public key before posting; a failed withdrawal
blocks replacement. Other devices' requests are untouched. Cancelled polling
cannot consume a late approval response. Verification codes identify public keys,
so retrying with the same device identity intentionally keeps the same code.

Space matching preserves valid stored identities first, then suggests unique
exact-name matches within the Profile selected in step 1 (or already mapped).
Ambiguous names stay undecided. Changing Profile choices recomputes automatic
suggestions; explicit Space choices, including clearing a picker, survive Back.
Suggestions never persist mappings or bypass overwrite review and Finish.
A missing stored Space identity may receive a suggestion, but absence from readable
choices alone does not authorize replacement. Preview carries the count of entities
it could not decrypt, identify, validate by tag, or accept as supported Spaces.
Only a fresh fully paginated preview with zero such skips can authorize replacing
the exact prior mapping after confirmation. Known non-Space kinds, default Space,
and tombstones are intentionally excluded and do not count as uncertainty.
Preflight also revalidates this completeness evidence. Mapping validation and the
replacement use one durable write: a claimed target, changed old identity or failed
save preserves the old mapping. An incomplete preview does not auto-complete an
apparently empty account. These guards reuse existing pairing error text.

Every entry and submission preflight fetches new Profile and Space candidates;
GET requests bypass response caches. A failed refresh has no cached-choice
fallback. Profile candidate filtering treats a persisted mapping as claimed only
when its UUID still appears in that fresh account list. Missing old identities
remain selectable locally after a server reset; merely loading candidates does
not change mappings. Explicit adoption replaces the old mapping. Registering as
new requires a definitive missing old key record, preserves the mapping on
transport/auth failures, and writes its replacement only after a successful PUT.
Account/session generations fence late responses. Preflight freezes
choice/navigation edits while permitting Finish later. Confirmed partial mapping
writes are real and reused on retry; only full completion opens eligibility.
Within the same session, completed Profile writes advance the expected review
snapshot so a Space-write retry retains its remaining choices. Fresh preflight
still rejects independent changes to the server candidates or reviewed Space data.

After enrollment the background mapping pass (`SyncKeyController.resolveMappings()`)
never adopts an account Profile by count: one unmapped local beside one unclaimed
account Profile stays unmapped (M3-4 ruling D20). Auto-create's same-name twin
search still adopts, after a Profile auto-create already made for that uuid. A
local with no twin is registered as a new account Profile without asking, once no
account Profile is left that auto-create could still claim. Envelopes that do not
open under the ARK, and uuids the persisted mapping gives to deleted locals, never
hold registration. Register and lookup failures are classified: transient
(transport, 5xx, 408/429, 401/403, locked, a mapping that moved) holds the pass
(`.held`); definitive (bad envelope, another 4xx, an undecodable body) measures
and reports `.definitiveFailure`. The controller publishes the Profiles whose
mapping it knows to be absent on the server (`knownUnmappedProfileIds`), the last
pass result and the Profiles it is creating, read on
`.phiProfileMappingsDidResolve`; the pure `SyncProfileMappingPause` turns them into
a pause decision. The known-unmapped set is evidence, not a per-pass answer: a
Profile enters when a lookup finds its persisted mapping's envelope gone (404) or
a measured pass leaves it unmapped, and leaves only when a pass or an adopt
resolves it or it no longer exists locally. A held pass erases nothing, and
`clearResolved()` keeps the set while the account key is still available; it
empties once the key is gone or the controller is retired. So a mapping whose
envelope is gone keeps pausing even when its replacement registration fails.
Beside the pass result the controller publishes `lastMappingsFailureCategory`
(`SyncProfileMappingFailureCategory`: offline, sign-in expired, server error,
other), for the Sync status only. It names the latest failure the pass met (for
a measured pass that reports an auto-create failure, that failure's), carries no
text or identifiers, changes neither the pass result nor the pause's reason, and
is nil after a pass that succeeds and after `clearResolved()`. `runMappingRepairPass()` runs auto-create and then a mapping pass,
both single-flight, outside the engine, under the existing gates (enrollment
complete, unlocked). The coordinator turns these inputs into the pause described
below. Until `ProfileManager` has enumerated the Profile list once
(`isProfileListEnumerated`), a pass does not prune the known-unmapped set against
the empty list it sees.

All native data rounds and Chromium ready-key exposure require enrollment.
Completing setup replays the shared Phi data type once under the confirmed Space
mappings, because no round (not even the gate close) runs while unpaired. Completion
atomically stores an optional replay token in the version-1 enrollment record;
legacy migration leaves it absent. Startup and activation pass the token to the
engine. The serialized gate and every live pull compare it with the Space table's
optional `lastEnrollmentReplayToken`, saving that acknowledgement together with
`markerMovedWhileGateShut` before clearing the marker. Failed saves block incremental
pulls and retry; a crash before activation restores the same demand from enrollment.
Once acknowledged, the same token never requests another replay. Both added fields
decode as absent in older records, preserving their prior behavior. The existing
single writer and shared marker own replay; no per-kind cursor is added.
Read-only pairing previews use the serialized engine queue without advancing
cursors or landing/publishing data. Each preview starts with an empty marker and
store birthday, then pins subsequent pages to the first response's server
generation. A changed persisted birthday or `not_my_birthday` response discards
preview choices and requires explicit reconfiguration. Legacy enrollment stops
retrying when this persisted condition is observed; only explicit setup can recover.
Ordinary previews never
repair persisted sync metadata or depend on background sync to repair it while
enrollment is incomplete.

Native `not_my_birthday` handling preserves cursors, baselines, mappings, and
local browsing data. It records `requiresReconfiguration` in the account's
`sync/marker.json` and stops native data rounds, including after restart. Retry,
reopening settings, and Finish later cannot reset this state. Settings → Sync
shows **Set up sync again**, with confirmation before cleanup. Chromium's
existing protocol-error recovery is unchanged.

Explicit reconfiguration and successful **Remove this device from sync** share
one native cleanup path in `SyncKeyController`. Remote self-revocation succeeds
before removal touches local state; rejection leaves local state intact. Cleanup
retires the engine, journals its intent, durably withdraws enrollment, discards
resolved keys/ARK and parked device registration envelopes, clears Profile/Space mappings, owned-item cursor files,
bookmark sync IDs, engine defaults and settings timestamp/value sidecars, the
default-Space UUID mirror, and the Space sync table. Removal also rotates the
device key. Browsing rows, local profiles/Spaces, preference values, login, URL
Rule IDs and pin lineage remain. The marker journal is deleted last; failures
retain the reset requirement and may be retried explicitly without revoking
again. A `removalPending` flag retains the required key rotation after partial
removal. If writing the journal itself fails, the coordinator retains the pending
intent for the current process and keeps the native engine paused. Account switches fence post-await global writes and preserve pending
account journals. Setup re-fetches server state and all matching must complete
before sync becomes eligible again.
Login initialization requested during cleanup is deferred until cleanup exits,
then resolves the current account again. Multiple requests coalesce; sign-out
does not resurrect a previous account, and removal alone does not request startup.

Withdrawing eligibility synchronously blocks
in-flight native writes, stops the invalidation schedule, and notifies Chromium.
A generation fence also rejects old rounds after rapid re-enrollment.

The pause while a local Profile is unmapped is a separate, softer stop. The
engine keeps an in-memory, lock-protected gate beside the stop signal
(`PhiSyncEngine.setProfileMappingPause(_:)`, read back through
`isProfileMappingPaused`), which the coordinator sets and clears synchronously
on the main actor. It takes effect at round boundaries: `run(_:)` reads it once,
after the wait for the previous round, and a pull, push, local-change round
(settings, Spaces, owned kinds) or retention sweep that meets it returns before
it writes anything or shows Syncing. A round admitted before the gate came on
finishes with all its landings, cursor saves, acknowledgements and marker
advance; nothing inside a round reads the gate, it never bumps the generation,
and it is not the pairing stop (`suspendForPairing()`), which does abort a
round. Exempt: the read-only preview, the Space gate edge and the local
deletion intent. A round admitted only through that exemption while the gate
is on skips the favicon backfill tail, so the pause starts no favicon request.
While the gate is on, neither `markLocalChangePending()` nor the queue's own
Syncing update changes the status. Rounds turned away are not replayed:
clearing the gate admits the next round, and the caller requests a catch-up and
queues the retention sweep again. An engine whose gate is never set behaves
exactly as before.

`PhiChromiumCoordinator` owns the pause (plan 2026-09-29, section 10). Its state
is an episode (an identifier and the time the predicate first reported an
unmapped Profile) and the outputs last applied, in memory only, held by a
`SyncProfileMappingPauseReconciler` (`Sources/Sync/`). Every output is derived by
one idempotent function, `reconcileProfileMappingPause(profiles:)`, which commits
the episode and the outputs before it applies any difference:

| Step | Rule |
| --- | --- |
| Prerequisites | Engine present, key controller present and not retired, account key unlocked, enrollment complete and activated, and this Mac not requiring reconfiguration (`nativeSyncRequiresReconfiguration`, the same source as the Profile loader's eligibility: an account reset by another device keeps enrollment and the key until setup runs again). Without them there is no episode and every output of the pause is off |
| Predicate | `SyncProfileMappingPause` over the user-assignable Profiles of the list the trigger passed (the Profile-list sink passes the value it was given; every other caller the current list), the persisted mappings, `knownUnmappedProfileIds`, `profileIdsBeingCreated` and the last pass result. Evaluated only with the prerequisites met and the list enumerated |
| Episode | Starts when the predicate pauses, runs a repair pass at once and arms one timer for its 15-second mark; ends when the predicate is clear or a prerequisite goes. A second unmapped Profile does not restart it |
| Engine gate | On while an episode exists, and from engine construction until the Profile list has been enumerated (AM-1) |
| Chromium keys | `chromiumKeysWithdrawn` set, then `notifyPhiSyncKeysChanged`, once an episode is 15 seconds old; cleared and notified when it ends |
| Status | The helper gets `SyncProfileMappingPauseStatus`: `.grace` for the first 15 seconds, then `.paused` with the reason, the failure category and the unmapped Profile ids, `.none` otherwise |
| Resume | When the gate goes from on to off on the current engine: a catch-up from the invalidation coordinator and the retention sweep again (both only once the schedule has started; before that `startPhiSyncIfReady()` requests its own), then the Profile loader re-evaluates |

Triggers: the Profile-list sink, the `.phiProfileMappingsDidResolve` and
`.phiProfileAutoCreateDidRun` observers, the episode's 15-second mark, the end of
engine build (before any round is requested), `activatePairedSync()`,
`startPhiSyncIfReady()` and the unlock observer before they enable work, and
teardown. A pause never aborts a round, never bumps the generation and never
stops or starts the invalidation coordinator; the invalidation stream stays
connected and the pulls it requests return at admission. Nothing about it is
persisted.

Repair: one loop per episode calls `runMappingRepairPass()` (unless reconfiguration is required when the pass falls due: the engine enters that state without telling the coordinator, so the pass is skipped without network work, the delay does not grow, and a reconciliation ends the episode), then waits 5 seconds,
doubling to 5 minutes, and repeats while its episode is current. Foreground,
wake, an unlock and the pane's Retry (`retryProfileMappingRepair()`) replace the
pending wait with an immediate pass and restart the delay at 5 seconds; a request
during a pass runs one more pass after it. During an episode, and with the
account key unlocked, the Profile-list sink runs this repair instead of
`silentUnlockAndResolve()`, so a failed device-envelope lookup cannot clear the
key cache (AM-4); on a device with no episode the sink is unchanged. The sink's
choice is made by the reconciliation right after the episode transition for its
list is committed: a sink that runs inside another reconciliation (the resume
lets the Profile loader refresh the list) has its inputs queued, and its choice
waits for them, so an episode they start selects nothing rather than the silent
unlock. A silent unlock chosen this way runs later, in a task, and only if the
key controller it was chosen for is still current and no episode exists by then.
A Profile
the key layer is creating can start an episode for the moment before its id is
known (the list publishes before `createProfile` returns); nothing is aborted or
shown and the episode ends when its adopt does.

Launch (AM-1): `ProfileManager.isProfileListEnumerated` becomes true on the first
complete, non-empty bridge read and never goes back. Until then the gate is on,
no episode starts and no key is withdrawn; while an engine exists and the list is
still not enumerated, the list is read again after 5 seconds, doubling to 5
minutes. A first enumeration with nothing unmapped only opens the gate.

Timers exist only while they have work: the 15-second mark and the repair wait
during an episode, the list retry before enumeration. Sign-out, account switch,
self-removal and engine retirement (`stopPhiSync()`) reconcile without an engine,
which ends the episode, cancels its timers, gives the keys back while the
controller still exists and forgets the gate and helper pause of the engine being
dropped. A device on which the predicate stays clear sees no change beyond the
launch gate: no timer, no repair pass, no withdrawal, no catch-up, no report
change.

Accepted residuals: an edit made during a pause is stamped when the next round
runs; a round admitted before the episode finishes under the partial behaviour
(the Spaces of the unmapped Profile are left out, the apply loop's checks keep an
existing row from being created again, and a deletion of such a Space arriving
from the account is applied); Chromium keeps syncing the mapped Profiles for the
first 15 seconds; the reason is per pass, not per Profile.

## Sync status contract

`SyncHelper` is the account-scoped macOS owner of the common completion time.
It runs while the sync stack lives, independently of the settings pane, which
reads its report. It observes the native context and every eligible user Profile
through the existing optional Chromium status callbacks, with a three-second
delay between observations (slow or timed-out replies extend the interval).
Observation reads the cached user Profile list once and never calls
`ProfileManager.refresh()`. The existing Profile-list subscription synchronously
invalidates outstanding observations when membership changes.

Only startup, membership changes, an explicit pane reload, failed status, or
known stale success evidence (five minutes) may request a coordinated round.
All requests share a minimum interval of 60 seconds; explicit reloads coalesce
with an active round. A queued explicit reload preserves the observed phase and
last common time until dispatch; it does not invalidate a completed barrier.
Ordinary pending work, commit-only cycles, native remote
applies, and late successful replies never request another round. The engines'
existing local-change and invalidation schedulers continue to own normal work.
A requested round pulls native data and refreshes all Profile namespaces through
the existing account-wide `notifyPhiSyncInvalidation` catch-up (both Profile UUID
and type list empty; a nonempty UUID with empty types is a no-op). The native
participant does not start either itself: it asks the running
`PhiSyncInvalidationCoordinator` for a catch-up, whose pull performs both, so helper,
SSE and fallback-timer pulls share one coalesced, single-flight pull. A request made
while a pull is running is served by one follow-up pull. The participant refuses
(the helper reports Rejected) when the coordinator is absent or stopped, in addition
to the pairing, key, account and bridge-support gates.

`requestSyncNow()` is the explicit "Sync now" request. It has the pane reload's
semantics, joins an observation in progress and then observes once more, so a
request recorded during a poll is never left behind, and returns the report's
`SyncRequestState`. `Report.request` describes that request only; the pane-open
request and automatic demand never appear in it. It is In flight (with the round's
start) while a round that a Sync now request started, or joined after the tap, is
active; Queued while a Sync now request waits, with the reason Unobservable (a
participant is missing or Checking), Busy (Initial sync or Syncing) or Rate limited
(with the earliest dispatch time); Rejected after an adapter refused a dispatch that
carried a Sync now request, until the next tap or accepted dispatch; otherwise Idle. Membership changes, ineligibility and stop reset it
to Idle. A queued request dispatches on the helper's own poll. The helper's
`ExplicitRequestPolicy` decides only explicit requests while a participant is
unobservable: `.waitForAllObservable` (the default) keeps them queued;
`.dispatchToObservable` dispatches once every observable participant is settled,
still sends the request to every participant and keeps the unobservable one in the
completion barrier, so such a round expires without a common time and without an
error. Automatic demand always waits for every participant.

All required participants remain in the barrier, including lazy Profiles that
have not been loaded. Missing reads and Checking snapshots are unobservable, not
stale evidence. While any participant is unobservable or reports Initial sync or
Syncing, the helper only observes and defers new requests, including queued pane
reloads. Even another context's aging success cannot force a round in that state.
It never loads Profiles for status. Once every context is observable and settled,
retained startup/membership/expired-round demand can establish a fresh barrier.

The helper starts a round only after all adapters accept their requests locally;
pairing, keys, account identity and bridge support gate dispatch. An accepted
request may still be dropped inside Chromium. A round expires after 60 seconds
at the next bounded observation and retains the previous common time. Expiry
reports Needs attention only when all engines claim Up to date without fresh
completion evidence. Checking, Initial sync and Syncing remain their observed
states, and real engine failures retain their existing error state. A previous
timeout never overrides later missing status or healthy work. Retry waits at least
another 60 seconds and until every context is observable and settled. A round also ends
early, for the request state, when the summary stays Offline or Needs attention with every
participant settled and sampled after dispatch (a revision newer than at dispatch; a
Chromium Profile's revision moves on every read) for at least one poll interval (3 seconds)
of time, measured by timestamps, not by the number of observations. Its request baseline is
kept until the round's timeout: if every context then reports a newer success, the common
time is recorded exactly as the running round would have, and no demand remains; after the
timeout the baseline is dropped without recording anything. Automatic demand after an early
end waits until the round's timeout plus the minimum interval, the time it would have waited
after expiry, so failing sync is not retried more often; an explicit request needs only the
minimum interval, and a membership change, ineligibility or a new dispatch clears the kept
baseline and the extra delay. Rejected requests have the same rate limit and cannot be
completed by unrelated success samples. Rebuilding the stack stops the old helper.

Only when every required context is Up to date with a success newer than its
round baseline and no earlier than the round request can the helper persist one
`sync.lastCoordinatedSuccess` in account defaults. The common time records when
the Mac verified the barrier; individual engine times remain diagnostic evidence.
The native status is re-read synchronously after all bridge awaits, so a local
edit or failure while querying Profiles cannot be hidden by an old native sample.
Profile observations use Chromium's existing pending-work fence; they are separate
observations, not an atomic multi-Profile transaction or request-ID acknowledgements.
Late evidence cannot complete an expired round or itself create more demand. A partial
failure or pending work retains the previous common time; failed persistence
reports Needs attention and cannot advance it. A real persistence failure remains
through timeout, membership changes and request retries until a successful write
or a sync lifecycle reset; ordinary missing/busy observations cannot erase it.
Missing contexts, an empty Profile
enumeration, unsupported selectors and malformed payloads never prove completion.
Their observed state remains Checking, including after round expiry; they never
cause automatic catch-up retries. An actual dispatch or persistence failure
remains distinct from an observation timeout.
The Profile mapping pause reaches the helper through
`setProfileMappingPause(_:)`, which the coordinator's reconciliation calls and
nothing else. It is neither eligibility nor a membership change: it keeps the
barrier's membership, the common time and the rate limit, and while it holds no
participant is read or asked for a round. When an episode starts, the
observations of a round in flight are invalidated (that round could never reach
its coordinated success; the engine round itself is not cancelled) and a Sync now
request it carried stays queued. During the first 15 seconds (`.grace`) the report
is kept as it was and a Sync now request stays queued as Busy. From 15 seconds
(`.paused`) `Report.profileMappingPause` carries the pause and a queued Sync now
request is cancelled, `request` returns to Idle and `syncNowCancelledByPause` is
set so the pane announces nothing; a new request is cancelled the same way. The
presentation overlays the pause on the summary when it reads the report, because
the completion of a round admitted before the pause still writes the phase. The
pause is checked again after every asynchronous participant read. When it ends,
the helper asks for a fresh round on its own poll, with a still-queued Sync now
request; this does not call `membershipDidChange()`.
Unpaired means Not started. Account retirement fences late callbacks; explicit
removal/reconfiguration clears the account's common timestamp.

`registerUpstream` / `unregisterUpstream` reserve the same completion barrier for
an eventual authenticated Sentinel adapter. Registration contributes a namespaced
participant id, a status reader and a sync request callback; it immediately
invalidates prior completion evidence. Until registered Sentinel is not required.
This hook introduces no Sentinel data type, IPC transport, key ownership or remote
API access in UI code. The future adapter must use this Mac coordination path and
supply bounded status reads plus genuine completed-round evidence. Adapters own
their initialization and ordinary progress independently of helper requests.

Native success requires a drained pull, accepted publication, successful cursor
persistence, and no pending/quarantined input, output, or follow-up work. A conflict
resolved by the same round's scoped retry does not count as a failure. Exhausted
conflicts and other failures remain failures even when another item recovers.
Domain-key lookup failures count toward the round's status: network unavailability
(including transport errors wrapped by the key client) reports Offline; HTTP,
authorization and key-envelope failures report Needs attention. Failed rounds
retain the previous success time, and a later successful round clears the failure.
Rows that are deliberately never published (hidden, purged or unmapped owner Spaces)
and refused arrivals are exclusions, not pending work.

The native snapshot also carries in-memory `SyncNativeDetail` (never persisted, so a
relaunch starts empty); Chromium snapshots carry none. Per Phi kind (Settings, Spaces,
Bookmarks, Pinned tabs, URL rules; no Profiles yet) it holds received and sent counts of the
most recent round in which that kind had activity, with that round's time, and the pending
(waiting to send) and held (parked) counts from the kind's table after the last round that
visited it. Settings count changed keys; Space and owned kinds count landings and published
entities plus tombstones. Owned pending is the live edits the round did not publish (outside
the slice budget, or sent and not applied, a conflict counted once after its scoped retry) plus
the pending-delete cursors, each counted once; a round whose publication pass did not run keeps
the last known count. Held uses the same conditions that make the round's inbound work pending:
Spaces parked, held for a Profile or tombstone-parked; owned items parked, tombstone-parked or
waiting for a split partner; settings unreadable. Kinds a round does not read keep their values:
owned kinds while the Space gate is shut or whose table the round did not load. The Space table
is read every round, so Space pending and held follow it even with the gate shut (with no
activity counts). Every detail change is a status update, so it bumps the revision. The last
problem is one `SyncProblemCategory` with an optional kind and a time, chosen by precedence
(reset required, save failed on this Mac, couldn't read data on this Mac, sign-in expired,
offline, rejected by server, server error, unreadable remote data). HTTP 401/403 map to sign-in
expired, other HTTP, key-envelope and unattributed outbound failures to server error, exhausted
conflicts and rejected commits to rejected by server, an owned kind's local read failure to
couldn't read data (with the kind), unreadable tags to unreadable remote data without a kind
(the Space table quarantines owned kinds' tags too). It is replaced by the next failing round,
kept through rounds that neither fail nor succeed, and cleared only by a final Up to date. Held
items alone produce no category. Invariant, covered by the status harness: a round that ends
Needs attention always has a non-zero held count or a problem category. R12: the detail has no string field, so it cannot
carry names, identifiers, URLs, hosts, error text or status numbers.

The Sync settings pane reads all of this only from `SyncHelper.report`. Its Sync now
button calls `requestSyncNow()` directly, not through the pane's 3-second poll, whose
in-flight guard would otherwise drop the tap. `SyncNowButtonState.reduce` maps the summary
phase and `Report.request` to the control (Queued Busy: waiting for the current sync;
Queued Rate limited: starting shortly; Queued Unobservable: waiting for profiles;
Rejected: could not start); the pane adds its own unlock and pairing check. The view alone
turns kinds, counts and `SyncProblemCategory` into localized text; the Sync layer produces
no user-facing strings. Local
changes to sync-visible fields invalidate the current result before debounce.
Local-only activity timestamps and favicon updates do not create pending sync
work. Every invalidation must have a corresponding debounced round, including
a content edit reverted before that round begins. Chromium exposes the
optional versioned `getProfileSyncStatus:completion:` observation for already
loaded user Profiles; it never creates Profiles or sync services. It combines
transport/auth/crypto/controller state, initial downloads, cycle evidence,
active-delegate pending counts, and a final backend pending-work fence. The old
transport-only local-data count API cannot be used for full-sync status.

Old frameworks safely remain Checking. A matched framework build and manual
cross-device acceptance are required before release; object compilation alone
does not establish runtime correctness. See the UX acceptance record in
[sync-e2e-test-cases.md](sync-e2e-test-cases.md).

## Chromium sync endpoint

`ChromiumLauncher` supplies a default `--sync-url` when starting the embedded
framework. Canary builds (`NIGHTLY_BUILD=1`) use
`https://sync.stag.phibrowser.com/chromium-sync`; release builds
(`NIGHTLY_BUILD=0`) use `https://sync.phibrowser.com/chromium-sync`.
The build channel selects this default independently of `DEBUG`. Explicit
launch arguments are appended afterwards, so a supplied `--sync-url=...`
overrides the channel default.

## Phi Chat profile exclusion

The dedicated `PhiChat` Chromium profile is local-only. It must not participate
in Profile pairing, Profile key registration, or browser data sync. Identify it
by its reserved directory basename, never by the user-visible display name.

Chromium's `phi::ListProfiles()` excludes this profile before returning the
bridge list. `ProfileManager.userAssignableProfiles` supplies that list to
`SyncKeyController`, so the Chat profile receives no account-global UUID or
resolved sync key. Chromium may construct a `SyncService` for the loaded Chat
profile, but `SyncServiceImpl::GetDisableReasons()` blocks the engine while its
`PhiSyncKeyProvider` has no ready UUID/key pair. Preserve both boundaries when
changing Profile enumeration or sync startup.

This describes the browser sync domains; conversation storage has its own
ownership and lifecycle.

## Chromium account and key lifecycle

The optional `getPhiSyncAccountInfo` delegate query exposes stable native session
identity independently of `getAuth0AccessTokenSyncly`. A signed-in session returns
`subject` and optional `email`; confirmed sign-out returns an empty dictionary;
restoration still in progress returns `nil`. Reauthentication grace preserves the
account identity while withholding its bearer token. Publish these state changes
before sending `notifyPhiAuthStateChanged`.

Chromium suspends an unresolved account without clearing sync metadata. Older
clients without the query can establish identity from a valid JWT, but a missing
JWT is treated as unresolved, never as evidence of sign-out. Confirmed sign-out
still clears metadata, and the next native sign-in restores full-sync setup even
when the Profile UUID and key have not changed.

Withdrawing a Profile key stops the Chromium engine, including initialization,
without clearing its metadata. Returning the same UUID/key resumes the existing
sync state; changing the UUID retains the existing namespace-reset behavior.
`SyncKeyController.chromiumKeysWithdrawn` withdraws every Profile's key at once:
`profileSyncInfo` answers nil while it is set and the same UUID/key after it is
cleared, because the resolved cache is untouched. Only the coordinator's
Profile mapping pause sets it: once an episode is 15 seconds old, and back when
the episode ends or its prerequisites go, each time committing its state before
it sends `notifyPhiSyncKeysChanged` (see "Enrollment and setup").

## Profile loading

Chromium runs a Profile's sync only while the Profile is loaded, and
`getProfileSyncStatus` reports nothing (Checking) for a Profile that is not, so
the helper never completes a coordinated round while one is missing. Every
mapped Profile is therefore loaded in the background (plan 2026-09-29, R5).
`SyncProfileLoader` (`Sources/Sync/`) decides; `PhiChromiumCoordinator` builds
and retires it with the engine and the helper, and supplies the Profile list,
the checks, the load call and a timer.

| Point | Rule |
| --- | --- |
| Which | User-assignable Profiles that the cached list reports as not loaded and for which `SyncKeyController.profileSyncInfo` would return a key now (enrolled, keys not withdrawn, mapping resolved under the unlocked account key) |
| Call | `ensureProfileLoaded:`, the existing bridge call: loads without a window, returns at once if already loaded, takes no keep-alive of its own. Completions are handled on the main thread |
| When | The first load no earlier than 30 seconds after `startPhiSyncIfReady()` starts the schedule (unlocked, enrolled, native sync running; at launch this follows the silent unlock and so the session restore of the first window). One load at a time, 5 seconds after the previous one ended |
| Unloaded again | A Profile that had a window unloads after its last window closes, and nothing tells the Mac side. The loader re-reads `ProfileManager`'s list every 60 seconds while it runs, through `refreshIfChanged()`: the same bridge read as `refresh()`, assigned and published only when the decoded list differs (`isLoaded` included), with none of `refresh()`'s side effects (chat-archive drain, display-name upserts). It re-evaluates on every published change by anyone else; a Profile shown as not loaded again is loaded again. A Profile it loaded itself waits 60 seconds before a still-stale list can ask for it again |
| Sync now | `PhiChromiumCoordinator.requestSyncNow()` (the pane's button) first tells the loader to re-read the list (so a Profile unloaded since the last recheck counts) and to load every Profile that needs it at once, without the initial delay, the gap or a pending retry delay, once each, then asks the helper; its request stays queued as Unobservable until the Profiles report |
| Not while | Disabled by the developer switch, not eligible (signed out or another account, controller retired, not enrolled, account key locked, or the account reset by another device so that this Mac requires reconfiguration), sync paused for an unmapped Profile, or the Profile list not enumerated yet. The coordinator supplies the last two: the engine's `isProfileMappingPaused` (on during an episode and before enumeration) and `ProfileManager.isProfileListEnumerated`; the loader re-evaluates when the gate goes off. A Sync now request made meanwhile is dropped. While it cannot load, a started loader still wakes once per recheck interval (60 seconds) to re-read these conditions, without refreshing the list or loading; before `startPhiSyncIfReady()` has started it, it does nothing at all |
| Failures | A failed load, or one that has not completed after 60 seconds, is retried after 30 seconds, doubling up to 10 minutes; the other Profiles go on. A Profile seen loaded forgets its failures |
| Teardown | Sign-out, account switch, self-removal and engine retirement stop the loader with the engine. A load already requested cannot be cancelled; its completion is ignored. There is no unload call: the Profiles it loaded stay in memory until the app quits, and so does a Profile whose load was in flight at teardown (plan residual A4, until the framework has an explicit hold and release call) |
| Logs | Counts and durations only, no Profile identifiers |

The helper's `ExplicitRequestPolicy` stays `.waitForAllObservable`.

Developer switch: `phi.sync.debug.profileLoadingDisabled` in
`UserDefaults.standard`. Absent or false, the loader runs; true turns it off,
for measuring memory without it. It is read at every decision, so it takes
effect within one recheck interval. It is not a synced setting and has no UI.

Dependency on upstream Chromium: a Profile loaded this way and never given a
window stays loaded until the process exits, because Chromium gives every newly
loaded Profile a "waiting for first browser window" keep-alive that only a
window clears. That is upstream behaviour, not a Phi contract; a Chromium
rebase can change it, and the loader would then keep reloading Profiles that
unload. An explicit hold and release call in the framework is follow-up work.
A Profile loaded without a window also publishes an empty open-tabs header for
this device (plan residual A3).

## Pairing and initial catch-up

The Space pairing page lists unmatched account Spaces even when this Mac has
only its default Space. Those account Spaces are added automatically after
pairing; they do not require placeholder local Spaces or manual mappings.

When the Space gate opens, the coordinator waits for the engine's queued gate
transition before requesting catch-up through the invalidation scheduler. A
healthy SSE stream uses a 300-second fallback interval, so relying on its next
tick can leave a newly joined device empty for almost five minutes. Repeated
mapping notifications do not schedule more work when the gate is unchanged.
Capture the same invalidation coordinator as the engine, so an old account's
completion cannot wake its replacement after teardown.

## Pull before commit

Invalidation schedules refreshes but does not bypass preflight. Every round that may
publish local settings, Spaces, bookmarks, pinned tabs or URL rules must first
complete GetUpdates and process the received updates. Local change notifications use
the same prerequisite as explicit pushes. A completed pull can authorize multiple
commit batches in that round; each batch does not need a separate GetUpdates.

The gate is on **publication**, not on stamping. The settings stamping pass (AM-1)
and the Spaces one (C2-a) deliberately run from the debounced local-change path
*ahead* of this gate, so an offline edit carries its own edit time; they write local
sidecar and cursor state and commit nothing. See "Stamps and the hybrid logical
clock".

- A network/key failure or an unfinished paginated pull prevents publishing for
  the whole round, including the entity kinds after the failing section.
- Exhausting the page budget is not success. The existing bounded follow-up
  rounds continue downloading, and publishing resumes only after a pull drains.
- A commit conflict requires another successful, drained pull before its one
  scoped retry. If that pull fails, later sections must also stop publishing.
- Successful downloading does not override existing per-entity protections:
  unreadable payloads, incomplete initial replay, unavailable local data, and
  unresolved ownership still retain their existing guards and recovery paths.
- Local edits survive a failed pull and remain eligible for a later round.
  Incoming updates are merged with current local data before building commits.
- Space reconciliation projects the current local fields and order against the
  saved baseline before applying incoming rows. The winning Profile binding is
  resolved after merging. Pending local deletions learn the incoming version
  without recreating the deleted row; a remote tombstone can finalize them.
- Commit versions and conflict detection remain necessary: another device can
  write after GetUpdates and before Commit. For the Phi data type (2000) the
  account also answers a create whose client tag already names a **live** row
  holding **different** content with CONFLICT carrying that row's entity id and
  version, instead of overwriting it (sync-service `d49cf41`). Three cases are
  not conflicts: a create whose content is byte-identical to the live row is
  idempotent, a create against a tombstoned row undeletes that row, and the
  Chromium data types still upsert by client tag as before. The engine harvests
  the id and version through `harvestTriple` before its one scoped retry, so the
  retry is an update at that version rather than a second create. `harvestTriple`
  writes the id only when it is nonempty and never moves the version backwards,
  and the conflict branch never leaves a cursor versioned but unidentified — that
  combination would be sent as a create with a nonzero `base_version`, which the
  server answers INVALID_MESSAGE.

Any future optimization that skips this prerequisite requires both a
healthy notification channel and successful catch-up, with no pending refresh,
invalidation, or conflict. Receiving SSE `ready` alone does not establish that
state. Disabled or lost notification delivery must restore pull-before-commit.

The engine owns the prerequisite inside its serialized round queue. Callers and
the transport must not independently decide whether a commit is safe to send.

## Marker persistence boundary

A pull is no longer a single all-or-nothing round: it is a sequence of pages,
and each page runs routing, landing, derived-state writes, cursor persistence
and finally the marker write, in that order. The shared marker only moves past
a page whose writes all reached disk, and it covers all five entity kinds —
settings, Spaces, bookmarks, pinned tabs and URL rules.

- The four store types return `Bool` from `save`. `AccountUserDefaults` rolls
  the in-memory snapshot back when the write to disk fails, so memory never
  leads disk.
- Any failed persistence in a page leaves that page with
  `marker_advanced=false`, makes the round publish nothing, reports
  `outcome=cursor_save_failed`, and replays the same page on the next round.
- The publish gate is a conjunction, `canPublishThisRound && !cursorSaveFailed`
  — the first half is the gate described under "Pull before commit", this
  section only adds the second. It is one boolean assigned in one place, so
  every publishing entry point and every scoped conflict retry reads the same
  value. A round that did not drain (`page_budget_exhausted`) or failed
  (`pull_failed`) therefore also publishes nothing, but `page_budget_exhausted`
  still advances the marker.
- The marker and the store birthday now live in `users/<sub>/sync/marker.json`
  instead of `UserDefaults.standard`, with a one-shot migration. Restoring a
  user-data backup therefore restores the marker that belongs to that backup,
  and the replay it triggers re-lands the missing rows instead of emitting
  tombstones for them.
- Known residual `E-M3-4a-1`: the first whole-scale adoption of settings is not
  atomic, so a crash between "values written" and "adoption flag written"
  replays the page and performs that adoption a second time. It is recorded in
  the milestone's design errata and is not fixed here.

### `pendingApply` and `pendingProjection`

A Space cursor carries one payload in each direction, and they are symmetric:

| field | direction | written by | cleared by |
| --- | --- | --- | --- |
| `pendingApply` | inbound — a decrypted entity this device could not land yet (§3.5 fallback B, a landing failure, a mapping write failure, a rebind that did not take effect, a mapped Space the sync view leaves out) | the apply pass | a successful landing |
| `pendingProjection` | outbound — this device's own projection of the Space, with each changed field already stamped at the time the user changed it (ruling C2-a, design option S2) | the stamping pass, from the debounced local-Spaces-change round, ahead of the pull gate | a landing, an accepted commit, a tombstone, or a revert that leaves nothing to publish |

Both are serialized `PhiSpaceEntity` bytes in `sync.phiSpaces`, both are
optional, and neither is on the wire. Adding `pendingProjection` needed no
`formatVersion` bump and no SwiftData migration: synthesized `Codable` decoding
reads an optional with `decodeIfPresent`, so a table written by a build without
the field decodes with it nil (the rule
`PhiOwnedItemCursor.rekeyRejectRounds` states for its own addition). A build
**older** than this one ignores the key and stamps Space edits at publish time
again, which is the pre-C2-a behaviour — correct, just coarser.

The last case guards a create over an existing row. The apply pass finds the
landing target in `currentSpaces()`, which leaves out a Space whose Profile has
no sync mapping, but validates the mapped local id against unfiltered storage.
For such a Space the target is missing although its row exists, and `land`
would create a row under a `spaceId` that is already taken; `spaceId` is
unique, so SwiftData overwrote the existing row (Profile binding and order
reset, bookmark root orphaned). The pass parks the entity instead, and
`LocalStore.createSpaceBody` refuses a duplicate `spaceId` with
`LocalStoreWriteError.spaceAlreadyExists`, which the pass's landing-failure
catch also turns into a park.

`pendingProjection` is written only for a cursor that already has a
`reconciled` baseline. A Space this device has never published has no per-field
history to preserve, so its first publication stays wholesale (A1) and is
stamped at publish time as before. `SyncableSpaces.snapshot` reads the field
back as the effective baseline for *stamps only*; `reconciled` remains what
decides whether a field changed at all.

## Default Space role

Two things that used to be one, and are now separate by name (ruling C1):

- The **identity** `"default-space"` — the well-known first-launch Space row
  (`LocalStore.defaultSpaceId`) and the reserved account uuid it is hard-wired
  to (`SyncableSpaces.defaultSpaceUuid`). It needs no mapping row and it carries
  D1's two field suppressions: `profile_uuid` and `theme_id` are neither emitted
  nor applied for it. Those suppressions are attached to the IDENTITY, tested as
  `uuid == defaultSpaceUuid` in both directions, and they do **not** follow the
  role.
- The **role** — the Space windows opened without context land on, the app-chrome
  theme anchor, and the pre-selected import target. It starts on the identity and
  moves when its holder is deleted.

The role is **synced state**: one account-level LWW register, the string key
`PhiDefaultSpaceUuid` in the existing `phi-settings` map, whose value is the
holder's account Space uuid. `PhiDefaultSpaceMirror` owns the key, both closures
and the mount-time reseed, exactly as `PinnedTabScopeMirror` does for the
pinned-tab scope; there is no proto change and no new channel. One register
cannot hold zero or two holders, which is why this is not a per-Space flag.

- **Local → register.** The one hand-off inside `SpaceManager.deleteSpace` also
  publishes the successor's account uuid. An unmapped successor publishes
  nothing: a local id must never reach the wire, and every device falls back
  until a later hand-off names a mapped Space. Agent and Incognito Spaces can
  never hold the role — the hand-off picks from `userSpaces`.
- **Register → local.** `SpaceManager.applyAccountDefaultSpace(syncUuid:)` writes
  `AccountUserDefaults.defaultSpaceId`, which is now the *applied cache* of the
  register, and republishes the default-Space theme. `currentDefaultSpaceId` and
  its 40+ readers are unchanged; only its last-resort fallback moved from "first
  in the local list" to the first live user Space in account order, ties broken
  on the synced `createdDate` rather than the device-local `profileId`.
- **Fall back, and never write back.** A register naming a Space that has not
  arrived, is not paired, is hidden inside the 30-day window, or was purged is
  left standing and the local pointer is left alone. Clearing it would be a
  device-local decision that wins account-wide, and the fallback is a pure
  function of the synced Space set, so every device agrees without a write.
- **Re-evaluation.** The register is re-applied when the settings entity lands
  (the `phiSyncedSettingsDidApply` observer), when the Space list changes
  (`handleSpacesUpdate`, which covers a Space that arrived on a later page, an
  unhide and a purge), and after every mapping pass
  (`.phiProfileMappingsDidResolve`, which covers a Space paired by the wizard
  without any local row changing). All three call the same idempotent apply.
- **Seeding.** The mount-time reseed writes the key at stamp **0**, from the
  local pointer's account identity or else from the well-known default identity.
  Seeding is not a user action, so it loses to any real hand-off, and two
  devices seeding different values converge on `lwwWinner`'s byte tie-break.
- **Account switches drop the key.** The mirror lives in the device-wide
  `UserDefaults.standard`, and unlike the other mirrored settings its value is
  an account identity. `resetPhiSyncCursorIfAccountChanged` removes the key and
  both sidecars, so the next account never publishes the previous account's
  Space uuid; the mount-time reseed then writes that account's own answer.
- **Mixed versions.** An old client neither reads nor writes the key; `merge`
  carries it through and `apply` refuses to write unregistered keys, so a round
  trip through an old client preserves the account's role. The old client keeps
  its own device-local role until it updates — no worse than before C1, when
  every client had one.
- **Not in the D7 overwrite confirmation.** The role is not a per-Space field
  and the register is self-correcting, so the join-time diff does not mention it.

Consequence accepted with the ruling: once the role sits on an ordinary Space,
that Space carries its own `theme_id`, so the global theme picker (which writes
`setTheme(forSpaceId: currentDefaultSpaceId)`) pins and syncs a theme on it.
`resolvedThemeId` still falls back to the global theme when the holder has no
pin.

### Deleting the identity

The `default-space` row is an ordinary deletable Space. `deleteSpace` refuses
only Incognito Spaces and the last remaining user Space, so a local delete of it
was always allowed and always queued a tombstone — but the engine used to ignore
an inbound `default-space` tombstone, and `SyncableSpaces.land` assumed the row
always existed locally. Both are fixed:

- A `default-space` tombstone lands like any other: hide → `deletedAtMs` →
  30-day retention → purge.
- A live `default-space` entity whose local row is gone is created under this
  device's own `Default` profile (D1 publishes no `profile_uuid` to resolve for
  it), still with no `theme_id` and no rebind. Before, it parked forever on
  `unresolvedProfile`.
- **Safety case.** Hiding the last live user Space would leave a device with
  none, which is the invariant `deleteSpace`'s own guard holds. When the
  `default-space` tombstone would do that — the deleting device had a successor
  this one has not received or paired yet — it is deferred on the existing
  `pendingTombstone` parking and retried every round, so it lands as soon as any
  other user Space is live here. The residual is a divergence window: the Space
  stays visible on that device until then, and a parked tombstone has no give-up
  condition (backlog B-5). The guard is scoped to this identity; an ordinary
  Space's tombstone still hides unconditionally, as it always has.
- In a mixed account, old clients still ignore the tombstone, so the Space
  lingers there until they update; the tombstone is the current value of that
  row and is redelivered on their next full replay.

## Local Space deletion

`SpaceManager.deleteSpace` is the one delete origin (design §9.1): the strip,
Settings > Spaces, the app menu, the CDP `agentSpace.spaces.delete` face and the
startup orphan sweep all reach its single sync hook in `finishDeletingSpace`,
after the early-return guards. The engine marks `pendingDelete` only on a cursor
with an `entityId`; a Space without a mapping (an agent Space) records nothing.

- **Cascade first, intent second.** The deletion intent reaches the engine only
  after `deleteSpaceCascadeThrowing` has committed. A failed cascade puts the
  Space back in the strip and records nothing, so no tombstone is sent for a
  Space that still exists. Sending one deleted it on every other device, dropped
  its mapping on `.applied`, and the next round minted the surviving row a new
  uuid and published it as a new Space, detached from its account-side bookmarks
  and pins.
- **Identity captured up front, in-flight rounds held off.** Before the cascade,
  `PhiSpaceSyncState.beginLocalDeletion` resolves the Space's sync uuid and puts
  it in an in-memory being-deleted set; the intent carries that uuid, and the
  engine round records `pendingDelete` under it without resolving the mapping
  again. That round writes the table even while the engine is paused for
  pairing, reconfiguration or an unmapped Profile (a local write, not network; it still runs in the
  engine's round queue, so it never interleaves with a round holding a table
  copy); the deletion is published when sync next runs. Only a retired engine
  (sign-out, key invalidation) skips it. The mark ends when that round has run
  (or when the cascade fails). While it stands, the apply loop treats an arriving entity for the uuid like a
  `pendingDelete` one — delete beats a concurrent edit for Spaces (design §9.2):
  it learns the entity id and version for the tombstone, keeps the mapping and
  lands nothing. The mark is read before the entity is considered, and again
  after each observation that the row is gone, before any decision based on that
  absence: inside the dead-mapping repair (the row check failed) before the
  mapping is dropped, and when the landing target is missing from
  `currentSpaces()` before `land` could create the row again. The later reads are
  what keep a round already in flight from re-landing the Space: a deletion that
  begins and cascades while the round is between two reads is visible only to
  the later one, and because the mark is set before the cascade and held until
  after the deletion round, a read made after the row is observed absent cannot
  miss it. The last read covers the default identity too; its row is deletable,
  so it can be marked. The entity is parked in `pendingApply` so that it still
  lands if the cascade fails; a recorded deletion clears it.
- **Every ending drops the mapping of a row that is gone.** An accepted
  tombstone (R-D6-10), a `pendingDelete` finalized locally because it was never
  published, and a tombstone given up after three rejections all leave a cursor
  with `deletedAtMs` and `hidden`, and remove the Space's mapping when its local
  row no longer exists. The row can still exist when an older build recorded the
  `pendingDelete` before a cascade that then failed (this build records it only
  after the cascade committed). For such a row the mapping is kept: dropping it
  would publish the row as a new Space under a fresh uuid. With the mapping in
  place the cursor's `hidden` applies, so the row's windows are closed and it
  leaves the strip like a remote deletion (design §9.2), and the retention sweep
  purges it after 30 days. The device then agrees with the account, where the
  tombstone was applied (or, for the other two endings, where the Space was never
  published or stays as the give-up already accepts).
- **Last-user-Space fallback.** Hiding such a row must not leave the device with
  no live user Space, the invariant `deleteSpace` holds (the older build counted
  the row as remaining when the user deleted the others). When no other live
  user Space is left, the mapping of that row is dropped instead and it is not
  hidden: it stays visible and a later round publishes it under a new uuid, the
  behaviour before the rule above. This is logged as a count.
- **Retention purge retry.** The 30-day sweep drops a Space's mapping only
  after its purge cascade succeeded, so a purged cursor whose mapping is still
  present marks a cascade that failed or was cut short, and every later sweep
  retries it. A retried uuid is skipped (and counted in the log) when its local
  row was created after the cursor's `deletedAtMs`: such a row cannot be the
  Space that was deleted, and no known path maps a purged uuid to a live Space.
  The check compares against the row's `createdDate`, which for a Space landed
  from the account is the account's `created_at_ms`, so it is a guard, not a
  proof.
- **Accepted gap: a crash between the cascade and the engine round.**
  `pendingDelete` is written by a queued engine round, not in the cascade's
  transaction, and nothing about the deletion is persisted before that round. If
  the app dies after the cascade committed and before the round wrote the cursor
  table, no tombstone is ever sent: the Space stays on every other device, and
  when the account next delivers its entity (a peer edit or a replay) the
  interrupted-deletion repair in the apply loop drops the dead mapping and lands
  the entity again under a new local id. The Space reappears here; deleting it again
  removes it everywhere. The same happens when the account is switched while the
  cascade runs, and when the engine is retired (sign-out or key invalidation)
  between the cascade and its round: the retirement also clears the facade's
  direct store, so there is nowhere left to record the deletion. Closing this
  gap would need a persisted deletion intent, which is a format change and is
  not done.

## Stamps and the hybrid logical clock

Every LWW stamp on the wire is a `PhiSettingValue.updated_at_ms`, an `int64` of
epoch milliseconds. Ruling C2 replaced the "devices run NTP" premise behind
those stamps with a hybrid logical clock, stamped at **edit** time rather than
at publish time. The wire format did not change: stamps are simply integers
that can now run ahead of wall clock.

`Sources/Sync/Phi/PhiHybridClock.swift` holds the formula below and AM-2's
correction helpers (`wallClockCorrectionThresholdMs`, `wallClockCorrection`,
`corrected`), and nothing else. It is a value type of its own so the engine and
the hostless convergence harness run the *same* code rather than two copies that
could drift.

```
stamp()  = max(wallMs, maxSeen + 1)          // also advances maxSeen
observe(s) = maxSeen = max(maxSeen, s)
editStamp(editWallMs, overwritten) = max(editWallMs, overwritten + 1)
```

`maxSeen` is the largest stamp this device has ever issued or landed.
`+ 1` saturates: `Int64.max` is a legal stamp on the wire and must not trap.

### Two clocks, and which quantity uses which

`PhiSyncEngine` keeps both. Mixing them up is the most dangerous mistake in
this area, so the split is explicit:

| clock | quantities |
| --- | --- |
| `hlcNow()` — hybrid logical | the `now:` argument of every `snapshot` / `stamp` call (settings, Spaces, bookmarks, pins, URL rules), `clearedPinSplitPartner`, all rank stamps, and **`deleteDecidedAtMs`** |
| `now()` — wall clock | retention sweeps, `deletedAtMs`, `purgedAtMs`, `refusedAtMs`, the unreadable-tag record, round deadlines, `lastProfileRefreshAtMs` |

The rule of thumb: a value that is *compared against another wire stamp* is
logical; a value that is *compared against wall clock* (a 30-day window, a
timeout) stays wall clock. That split is also what AM-2's clock correction
follows exactly — see "Correcting a broken clock at the source" below: the
`hlcNow()` row is corrected, the `now()` row is not.

### Edit-time stamping (AM-1)

A changed merge unit takes the row's own edit-date column, raised one above the
stamp of the value it overwrites:

- settings — `SyncableSettings.snapshot` stamps a changed key
  `max(now, previousSidecarStamp + 1)`, and the pass now runs from the debounced
  local-change path **before** the pull gate, so an offline edit carries its own
  time. It only runs early once `hasAdopted` is true: with no sidecar history
  `snapshot` treats every registered key as changed.
- bookmarks and pins — content fields take `contentUpdatedDate ?? createdDate`.
  The bookmark **location** merge unit (`space_uuid` + `parent_uuid`, one shared
  stamp) takes `locationUpdatedDate`, the optional column schema V13 adds to
  `TabDataModel`. A local user move writes it; a reorder inside one parent is
  rank, a landed remote move is not an edit, and the Space retag a moved folder
  performs on its descendants is diagnostic and never republished (R-M3-3-18).
  The one engine-authored writer is C4's lift of a yielded child out of a
  remotely deleted folder, a location this device must defend against peers that
  still hold the old parent ("Edit beats delete"). A row with no recorded move —
  pre-V13, or one whose location only
  ever arrived from a peer — keeps the pre-V13 behaviour exactly: `hlcNow()`
  against a baseline, stamp 0 without one.
- URL rules — content takes `contentUpdatedDate`, the target takes
  `targetUpdatedDate`; both were already edit-time and now carry the AM-1 bump,
  which closes the same slow-clock hole. `rank` uses `hlcNow()`.
- pin `split_partner_uuid` stays on `hlcNow()`. Ruling Q-R2-3 wants it folded
  into the content stamp, but `updateTabSplitPartnerBody` is shared with sync
  landing, so setting `contentUpdatedDate` there would restamp landed remote
  links as local edits.
- Spaces — there is no edit-date column to take, so the edit time is *recorded*
  instead, in the cursor's `pendingProjection` (see "Marker persistence
  boundary"). `SpaceModel` has no such column and `theme_id`, the overlay
  opacities and the Profile binding are not on the row at all — they are joined
  in from `AccountUserDefaults` at the sync boundary — so a row-level column
  could not have covered them, and would have been coarser than the per-field
  LWW the wire uses. A debounced local-Spaces change runs a stamping pass ahead
  of the pull gate: it projects the current Spaces through
  `SyncableSpaces.snapshot`, stamps each changed field at that moment, and
  persists the result. The publish pass re-projects, finds the same bytes, and
  keeps the stamps rather than issuing new ones.

  Three consequences worth naming. A field whose bytes match the **baseline**
  again — edited and put back before publishing — takes the account's own stamp
  back, so a revert publishes nothing. A field whose bytes match the **pending
  projection** keeps the stamp it was given, so a second offline edit of another
  field leaves the first field's edit time alone. And `rank` is unchanged: only
  a Space outside §7's kept set is rewritten, and the pass records that stamp
  once instead of re-issuing it on every later local change.

  The stamping pass honours `isStopped`, the Space gate and `spaceStore` /
  `spaceAccess`, and it inherits `snapshot`'s exclusions (parked, refused,
  hidden, soft-deleted and unmapped Spaces are never projected, so a parked
  Space keeps stamping at publish time). It deliberately does **not** honour the
  pull gate — that is the point — or guard 1's `hasDrainedFullReplay`, because
  guard 1 protects the account from a device that has not seen its Spaces yet
  and this pass commits nothing; the "no baseline, no pending projection" rule
  above covers that case structurally. Identities are resolved read-only, never
  minted. A failed table write costs nothing irrecoverable: the edit is still on
  the row and the next pass re-projects it at that pass's stamp, while the
  failure itself closes `canPublishThisRound` for the round.

The bare edit column is never enough on its own: a device whose clock runs
behind would replace a value it merged from a peer with a *smaller* stamp and
lose its own, causally later, edit — which is the defect C2 exists to remove.

Everything else is still stamped at publish time, on `hlcNow()`:

| quantity | why it has no edit time |
| --- | --- |
| every **rank**, on every kind | a drag has no edit-date column on any kind, and ruling Q-R2-5 leaves it that way; M3-4a §14.3 item 11 already registers the cost. A Space rank is the one that comes closest: the stamping pass runs from the drag's own debounced round, so its `hlcNow()` is taken within the debounce of the drag rather than at the next successful pull. That is a consequence of where the pass sits, not a promise — the stamp is still an `hlcNow()`, not a recorded drag time, and it is the pass's clock that a peer compares against |
| pin `split_partner_uuid` | the only column it could borrow is shared with sync landing (above) |
| a Space with no `reconciled` baseline | first publication is wholesale (A1), so there is no per-field history to preserve; the same applies to a parked Space, which `snapshot` excludes |

### Where `maxSeen` lives, and why it is not beside the marker

`phi.sync.hlcMax` is in `UserDefaults.standard`, in `PhiSyncEngine.stateKeys`.
This is deliberately the **opposite** decision from the marker above, for the
opposite reason. A user-data import replaces the account directory, so
`marker.json` and the cursor tables roll back together with the database — that
is exactly right for a progress marker. Logical time must not roll back with
it: a rewound `maxSeen` lets this device re-issue stamps the account already
holds, so an edit made after the restore can lose to the value it is trying to
overwrite. It is still account-scoped, because logical time is per account, and
`stateKeys` is what makes it so.

Losing it is cheap. On an account switch or a clean install `stateKeys` is
wiped and `maxSeen` restarts at wall clock; because pull-before-commit is
mandatory, the first pull of the first round re-learns it from every landed
stamp before any commit can be sent.

### What is observed, and the no-clamp rule

Only `PhiSettingValue.updated_at_ms` values are folded into `maxSeen`, at
landing time, before anything in the same round stamps. Explicitly **not**
`created_at_ms` — a creation instant merged with `min()`, so a peer claiming
the year 2099 must not drag the account's logical time — and not `deletedAtMs`,
`purgedAtMs` or `refusedAtMs`.

**Inbound stamps are never rewritten, and `maxSeen` is never clamped.** A clamp
on receive would change the merge input, and two devices with different wall
clocks would clamp differently, so `SyncableSettings.lwwWinner` — whose whole
contract is that it depends only on the two values — would pick different
winners on different devices. That is divergence, not a repair. Clamping only
`maxSeen` adoption is convergence-safe but worse in practice: the device with
the broken clock would then win every field permanently. A device a year ahead
therefore drags the account's logical time with it, and the clock degrades
gracefully into a Lamport counter, which still orders causally related edits
correctly.

### Correcting a broken clock at the source (AM-2)

The no-clamp rule above is about *receiving*. It says nothing about what this
device puts on the wire next, and that is where a wildly wrong clock can be
repaired without touching anybody's merge input. `PhiSyncHTTPClient` exposes the
`Date` response header of every successful GetUpdates and Commit as epoch
milliseconds (`lastServerDateMs`; nil when the header is absent or is not one of
RFC 7231's three HTTP-date forms). The engine turns it into an offset estimate,
`serverMs − now()` at receipt, and keeps it in
`phi.sync.wallClockOffsetMs`. There is no RTT compensation: the quantity that
matters here is measured in minutes.

| | |
| --- | --- |
| threshold | `PhiHybridClock.wallClockCorrectionThresholdMs`, **5 minutes** |
| below it | **no correction at all.** Ordinary skew is harmless — LWW never promised true-time ordering of concurrent writes at that resolution — and a re-measured correction would only jitter this device's stamps round to round |
| beyond it | the whole measured offset is applied, in either direction |

The stored value is the *correction*, not the raw measurement, so no second
reader has to re-apply the threshold. It changes only what this device stamps
next, so every device still merges byte-identical inputs and R2.4 stands
untouched. A change is logged once, at metadata level (the two offsets and the
threshold, never a header or anything a user typed).

**What is corrected** is every wall-clock instant that becomes an LWW stamp, and
only those:

* `hlcNow()`'s argument — so every `now:` above, every rank, `deleteDecidedAtMs`
  and the whole settings/Spaces stamping path inherit it for free;
* the row **edit columns** `OwnedItemKind.stamp` reads, as `editWallMs + offset`.
  This half is not optional: `contentUpdatedDate`, `locationUpdatedDate` and
  `targetUpdatedDate` are written by `LocalStore` from the same broken `Date()`,
  so correcting only `hlcNow()` would leave every edit-time stamp uncorrected.
  The engine hands the offset to `SyncableOwnedItems.snapshot` beside `hlcMax`,
  and the kinds apply it *before* AM-1 raises the result above the stamp it
  overwrites. The columns themselves are never rewritten — they are local
  wall-clock quantities that other readers compare against wall clock.

The correction reaches **every stamp, inbound as well as outbound**. Publication
is not the only place an edit column becomes a stamp: the local projections
planning builds — `OwnedPlanInput.wallOffsetMs` → the bookmark/pin/URL-rule
`*LocalProjections` helpers, and the adoption and claiming projections in
`SyncableOwnedItems.adopt` and `urlRuleClaims` — read the same columns to form
the *local side of an incoming merge*. Leaving those raw is not a cosmetic gap:
on a device an hour fast, an **earlier** local edit beats a **later** remote one
at merge time and the uncorrected stamp lands in `reconciled`, where the
corrected outbound path can no longer undo it. What the claiming projections
keep at 0 is `hlcMax` and `now`, which is a separate ruling: AM-1's logical floor
would let an untouched local row beat the arrival it is claiming. An edit time is
corrected wherever one is read.

**What is not corrected** is everything in the `now()` row of the table above:
retention sweeps, `deletedAtMs`, `purgedAtMs`, `refusedAtMs`, the round
deadlines, `lastProfileRefreshAtMs`. Each is compared against this device's own
wall clock, and correcting one side of that comparison is how a correction turns
into a bug.

Why the offset is **persisted**, and persisted in `stateKeys`: an offline edit is
stamped at edit time (AM-1), so a plane edit on a Mac whose clock is a year out
would otherwise be stamped a year ahead the moment it publishes. The last
estimate is the best answer available until the next pull, and a broken clock is
broken by a roughly constant amount. The offset is a property of the *device*,
not the account, so `stateKeys` is coarser than strictly necessary — an account
switch wipes it. That is deliberate: one auditable list of "everything the
engine persists for an account" is worth more than the saving, and
pull-before-commit re-learns the value from the first response of the first
round, before any commit can be sent. The only window a wipe opens is an offline
edit between an account switch and the next successful pull, which is the window
a wiped `maxSeen` already has.

Stamp 0 is untouched by all of this. It still means "derived, must never beat a
real action" — no-baseline ranks, a no-baseline bookmark location with no
recorded move, the reseeded scope mirror — it is never produced by the clock,
and observing it is a no-op because `max` is. A no-baseline location that *does*
record a move takes AM-1's `hlcMax` floor instead: that is what will let a
deliberately lifted bookmark survive a republish over a tombstone (R4.6),
instead of leaving a location any peer can overwrite at will.

### `deleteDecidedAtMs` and A9

`cursor.deleteDecidedAtMs` is written from `hlcNow()`, not `now()`, and this is
mandatory rather than tidy. A9 (`SyncableOwnedItems.plan`) compares it against
`max(K.locationStamp(of: merged), K.contentStamp(of: merged))`, both wire LWW
stamps: if the decision stayed on wall clock while stamps moved to logical time,
then on any account whose logical time has run ahead of wall clock *every*
inbound entity would look newer than the deletion and A9 would cancel *every*
local delete. `deletedAtMs` is the opposite case — it drives the 30-day
retention expiry against `now()` — and stays wall clock. Both ends carry a
comment saying so.

The `contentStamp` half is ruling C4-a and is new: M3-3 shipped A9 on the
location stamp alone (CASE U-23), so a remote **rename** that arrived after this
device had decided to delete still lost. The other two conjuncts are unchanged —
the cancelled deletion must land under a live parent and outside a subtree a
remote tombstone is removing this round — and they are what keeps a cancelled
deletion from landing an orphan. `contentStamp` is a kind query beside
`locationStamp`: the newest of the four bookmark content stamps, of the three pin
content stamps, or the URL rule's content-group carrier; its protocol default is
`locationStamp`, so a kind that declares no content unit keeps A9 as shipped.

### Mixed versions

There is no format flag and no negotiation. An old client compares stamps with
`>` exactly as before and converges with a new client on every field; it simply
stamps plain wall clock, which is `<=` what a new client would stamp. On a
healthy account (`maxSeen` ≈ wall) the two are indistinguishable. The one real
cost, stated plainly: on an account whose logical time has run ahead of wall
clock, an **old** client's edits can lose to the values it is trying to
overwrite, with no user-visible explanation, bounded by the skew.

Downgrading one device is the same story locally. A build older than C2-a
ignores the `pendingProjection` key in `sync.phiSpaces` — it does not know the
field, so `Codable` drops it — and stamps its Space edits at publish time
again. It publishes correct, merely coarser, stamps, and re-upgrading picks the
field up from wherever the stamping pass next writes it. Nothing is lost in
either direction and no table is invalidated.

## Edit beats delete

Ruling C4. When a delete and an edit of the same item are concurrent, **the edit
wins**, whichever side reached the server first, for bookmarks, folders, pinned
tabs and URL rules alike. The reason is asymmetry of cost, not symmetry of
mechanism: a delete is easy to redo, an edit is not, and a wrongly kept deletion
costs more than a wrongly kept item. This supersedes M3-3's decision to keep
bookmarks and pins out of yielding on grounds of volume; the blast radius is held
down by the predicate below instead, and by `resurrected` on the counter line,
whose steady state is ~0.

**Say it plainly, because users see it:** an item you deleted can reappear on
your device when another device had an unpublished edit of it. Deleting it again
after that edit has published removes it everywhere. The folder you deleted stays
gone, but the bookmark being edited inside it reappears at the top level of that
Space.

### Direction (i) — an inbound tombstone meets an unpublished local edit

The item **yields**: the local row is kept, both cursor baselines are cleared,
the tombstone's entity id and version are harvested, `deletedAtMs` is written and
kept, and the end of the publish segment republishes the item at
`baseVersion` = that tombstone's version. Convergence here is by **version, not
by stamp**: a deletion carries no LWW stamp, so the resurrection does not have to
out-stamp anything — the server hands every device a strictly newer version of
the same client tag, including the device that deleted it. Rules may instead
transfer the edit to a quiescent merge partner; bookmarks and pins have no merge
partner, so yielding is their only outcome.

What counts as an unpublished edit is **derived**, not a column
(`SyncableOwnedItems.unpublishedEdits`): a live local row currently claims the
identity, its cursor has a baseline, and the round's projection differs from that
baseline in its content signature or its owner reference. It is OR'd with the
value-based `server != reconciled` ("we won a merge and owe the account a
republish"), matching rules.

- **Rank is not an edit.** Dragging an item does not resurrect it, dense
  re-indexing must never look like intent, and the projection carries the
  baseline's rank anyway. `is_folder` is an invariant, refused rather than merged.
- **"A live local row currently claims it" is a hard conjunct**, not an
  implementation accident. It is what makes pin scope migration safe (T5): a
  migration is a tombstone under the old `(lineage, owner)` identity plus a create
  under the new one, and after it no live row claims the old identity, so its
  tombstone hard-deletes. Two further protections stand in front of it — a scope
  mismatch parks every arrival *and* every tombstone before either yield branch
  runs, and `normalizeVariants` re-lineaging has the same shape.
- A bookmark whose parent folder is still unpublished has no projection, so it
  does not yield. That is the conservative direction and is left as is.

### Direction (ii) — a local pending delete meets an inbound edit

A9, extended by C4-a from a newer location stamp to a newer stamp on any merge
unit; see "`deleteDecidedAtMs` and A9" above for the condition and the clock it
depends on. When the cancelled item's local row is already gone, landing
**recreates** it from the payload rather than dropping the steps — otherwise the
next round's diff would find the row missing and the delete would win after all.

For URL rules the boundary is drawn by branch order rather than by a second
predicate: an inbound entity for a soft-deleted rule reaches A9 only after the
transfer and park branches have found no merge partner at all. A collapse loser
points at its winner for as long as that winner exists, so an **engine-authored**
collapse deletion is never the one an edit cancels; when the winner is gone too,
the group is empty and keeping the edited rule is the coherent outcome.

### Trees: lift, never resurrect the folder chain

- A child **edited** inside a folder another device deleted yields, and the
  folder's deletion lifts it to the Space root. The folder stays deleted.
  Resurrecting it on the strength of a child's edit would be a much larger claim,
  and it would have to resurrect the whole ancestor chain to be coherent.
- A child **added** inside such a folder is not an edit of the folder either. It
  has no cursor, so it cannot yield; the same lift keeps it, and it publishes as
  a new root-level bookmark.
- A **rename of the folder itself** is an edit of the folder, so the folder
  yields and reappears — empty, plus any children that yielded in their own
  right. Its other children were deleted with an intent nobody contradicted.
- The same rule covers direction (ii): a child whose deletion an inbound edit
  cancels while its folder's deletion stands is lifted to the root. `classify`
  therefore treats a cursor with a local `pendingDelete` as a dead parent — the
  folder's row is already gone here — unless that folder's own arrival is in the
  same working set, in which case the child stays inside it.
- The landing transaction is where this is enforced. A folder `.delete` that
  still has children is **refused** by the store (`folderNotEmpty`), so lifting
  the survivors is not an optimisation: without it the whole batch would roll back
  and retry forever. `landBookmarks` lifts every surviving descendant to the Space
  root in the same batch, phase-ordered before the delete.
- A lifted child's new location is an engine-authored decision this device must
  defend against peers that still believe it lives inside the folder, so the lift
  **records** `locationUpdatedDate` when the child is in the yielded state — the
  one exception to "only a local user move writes that column". Its republish has
  no baseline, and without a recorded move the no-baseline path would stamp the
  location 0, which any peer could overwrite at will.
- **A folder-move cycle resolves by last operation wins** (ruling C5-a). Two
  devices moving F1 into F2 and F2 into F1 produce a page whose parent graph has
  a cycle. `SyncableOwnedItems.plan` step 4 is a Kahn topological sort; what it
  cannot order is a cycle, and instead of dropping it into `refused` — which
  applied **neither** move and left every device on the tree it already had —
  the planner breaks it:
  - The member whose **location stamp is oldest** loses. An exact tie is settled
    on the UUID, where the lexicographically **greater** one wins, so no device
    can disagree about which folder moves.
  - The loser goes back to **the location its own `reconciled` baseline names** —
    the account's last agreed position for it, the same bytes on every device —
    and takes that baseline's rank back with it, because a rank only orders
    siblings under one parent. It is **not** lifted to the Space root.
  - That revert is republished with an **engine-authored** location stamp of
    `max(every stamp in the cycle) + 1`, computed from the cycle's own values and
    never from the device's clock (`PhiHybridClock.editStamp`, folded into
    `hlcMax` like any stamp this device issues). Two devices landing the same
    page therefore author the same bytes, landing it twice changes nothing, and
    no peer's copy of either move can win afterwards.
  - The winner's location is left exactly as received. In a longer cycle only the
    **oldest** move is put back, which is all it takes to break the cycle; every
    other move stands.
  - If the loser has **no baseline here** — both folders are new to this device
    and arrived in one page already forming a cycle — there is nothing to go back
    to, and the Space root is the only location every device can name. That is
    the one case where a cycle does lift.
  - If the loser's baseline parent is itself **dead**, the shipped B8 rule takes
    over: `classify` already reports a tombstoned or deleted parent as `.lift`,
    and the folder lands at the Space root through that one path. No second
    lifting mechanism exists.
  - The losing move may be **this device's own**, and then its local row moves
    back too: *you moved A into B while another device moved B into A afterwards,
    so A goes back to where it was.* The planner forces the `move` step for a
    reverted folder even though the merged location now equals the baseline, and
    marks it for republication, because the account still holds the move this
    device just undid.
  - Broken cycles are counted in `cycles_broken` on the round's counter line and
    are **no longer** part of `refused`; `refused` keeps its old meaning, "the
    page was dropped", for a cycle no kind can break (pins and URL rules have no
    parent reference, so they never form one).
  - The graph is built over the page's arrivals **plus the live local rows they
    point at**, so a cycle closed by a **local row** is found too: this device's
    own move of F1 into F2 — published or not — meeting F2's arrival under F1,
    with F1 nowhere in the page. Neither device ever sees both moves in one page
    in that race, so a page-only graph would land the cycle on both of them and
    nothing would repair it. A local row's side of the comparison is its
    projection's location stamp, which under AM-1 is its move's own time; its
    revert is the same one an arrival gets, and it is republished, so the peer
    learns where the folder went back to. Each arrival is compared through the
    location that will actually land — the arrival merged with this device's
    projection — so a stale arrival the local row already beats is not a cycle.
  - **The projection domain is what makes that half real.**
    `OwnedItemPlanContext.localProjections` used to cover the page and nothing
    else — arrivals, parked payloads, this round's tombstones — and a folder the
    page never mentions had no projection, so the walk reached it, found nothing,
    and stopped: `b` landed under `a`, the local row kept `a` under `b`, and
    `cycles_broken` was 0 on a device that now holds a cycle. The domain is
    therefore the page's own identities **plus the live local parent chain above
    each arrival's landing parent**, computed by
    `SyncableOwnedItems.projectionDomain`. That is the smallest domain the walk
    can reach — it follows one parent edge at a time — so it adds one entry per
    ancestor per page rather than projecting the whole table. The extra entries
    are inert everywhere else: α and the step-5 merge are keyed on identities the
    page carries. **Parked payloads seed that walk exactly as arrivals do** —
    `projectionDomain` takes the whole parking map and decodes it, because a
    parked move retried on its own is a page with no arrivals at all and the
    folder this device moved under it is reachable only from the parked payload's
    own parent reference. The **hostless convergence harness calls the same function**
    rather than handing the planner every local row, which is why the gap it used
    to hide is now a gate failure.
  - One case authors nothing: the losing move was **published from this device**,
    so the commit wrote that location into its own `reconciled` and it no longer
    knows where the folder came from. Reverting the other member instead would
    undo the newer move, so it lands the arrival and waits. Every peer still
    holds the pre-move baseline, computes the same loser, and publishes the
    revert that repairs this device. Its tree holds the cycle until then.

### Pinned tabs

- A resurrected pin whose split partner was deleted (and did not itself yield)
  comes back **unlinked, silently**. No code enforces this: deleting the partner
  already clears the back-reference in the same transaction, and the republished
  pin carries the empty link at `hlcNow()`, which beats a peer's stale non-empty
  one. Yielding both halves because one was edited is explicitly not done — the
  user deleted the other half and did not touch it.
- Scope migration is never a delete an edit can beat (T5, above).
- Only a **Space-owned** identity can have its yield revoked by a hidden or
  purged Space. A Profile- or App-scoped pin has no Space cursor to consult, so
  it is admitted rather than withheld; testing `spaceCursors[owner]` alone would
  have withheld those yields every round, forever (T6).

### Mixed versions

The resurrection is protocol-invisible: an ordinary update at the tombstone's
version. An old client receives a live entity whose version exceeds its cursor's
and already resurrects it. Only new clients *yield*, so an old client that
receives a tombstone for a bookmark it has just edited still hard-deletes it and
loses the edit — nothing regresses, the guarantee is simply not yet universal.
There is no cursor-file format change. After a yield, a downgrade leaves the row
live and unpublished until the build is upgraded or the tombstone cursor expires.

## Refusals, retries and account switches

Rules established by the 2026-09-20 review of the integration branch. Each is
pinned by a test named in its own `// Review A<n>` comment in the code.

- **Opening the Space gate is marker-first.** The nil marker is persisted
  before `markerMovedWhileGateShut` is consumed and the drain armed; a failed
  marker write leaves the latch standing and every live pull retries the
  arming from it (`PhiSyncEngine.armSpaceReplayIfNeeded`). The two files
  cannot commit atomically, and the opposite order let an incremental pull
  finalize a drain over the entities the shut episode walked past.
- **A loss observed at round entry stands.** Publication treats an owned
  cursor table as lost when the store reported loss at round entry, even if
  the landing in between wrote a non-empty file back; otherwise cursor-less
  local rows were committed as `entityId = nil` creates over the account tree.
- **Unreadable settings never rewind the shared marker.** A tombstoned,
  undecryptable or foreign settings entity is recorded durably
  (`phi.sync.unreadableSettings`: reason, domain-key fingerprint, build); the
  marker advances page by page and the drain finalizes as usual, so Space and
  owned-item publication continue. `pushSettings` keeps refusing through
  `storedEntityId != nil && storedLastEntity == nil`. The entry of a later
  pull replays the data type once, marker-first, when the domain key or the
  build has changed; a tombstone heals by the round counter, which now counts
  rounds from the record rather than requiring the tombstone to be re-sent.
- **A failed account-wide reorder fails its page.** The Space table rolls
  back to what the page found, the failure counts as a cursor-save failure
  (marker held, no publication), and the replay retries the reorder; kept rank
  baselines would otherwise republish the stale local order over the peer's.
- **Rows landed into a Space belong to that Space's Profile.** Bookmark and
  Space-scoped pin landing resolve the Profile from the Space binding
  (`OwnerResolver.localProfileIdForSpace`) before any sibling or default
  fallback, and landing a parentless bookmark materializes a missing root for
  an existing Space instead of parking the batch on `rowNotFound`.
- **An account switch drops the account's `marker.json`.** The entity cursor
  in `UserDefaults.standard` is wiped on a switch; resuming a previously used
  account from its advanced marker with no entity id would make the next push
  a create that overwrites that account's settings. One full replay per
  switch is the price.
- **Bootstrap never loses the ARK after the account exists.** Once
  `PUT /keys/v1/account` succeeded the ARK is cached and the recovery code is
  returned no matter what; a failed device registration is parked as the ARK
  sealed to this device's own key (`phi.sync.pendingDeviceRegistration.<id>`,
  ciphertext only) and finished by `unlockAtStartup()`. The recovery-code
  window refuses to close until the user confirms they saved the code.
- **A revoked device identity is rotated, not resubmitted.** `POST
  /keys/v1/devices` answering 409 rotates the device key and retries once. The
  key is stored `ThisDeviceOnly`, so a migrated or restored Mac does not share
  an identity with its source.
- **Key API requests are bound to the stack's account.** `SyncKeyStack.make`
  builds its token provider around the account id it was given: a request
  from a stack whose account is no longer the signed-in one gets no token, and
  `KeyEnvelopeAPIClient` never sends a request without one (it throws a
  transport error instead of an empty bearer, which callers must treat as
  transient, not as a sign-out). A bootstrap suspended across a sign-out of A
  and a sign-in as B therefore fails its `POST /keys/v1/devices` under B and
  is finished under A from the parked registration. Token renewal within the
  same account passes: the id is compared, not the token.
- **A retired `SyncKeyController` writes nothing.** Teardown calls
  `retire()`; a pass parked in a network call when the account went away
  resumes on the next account's token and used to register every unmapped
  local Profile into it under the old ARK. `retire()` also cancels the shared
  auto-create round, and the round, `createLocalProfileAndAdopt` and the repair
  pass check retirement after every await and before every create, adopt or
  mapping write. A stopped round returns `.failed` without posting
  `.phiProfileAutoCreateDidRun`. When the bridge's create completes after
  retirement, the Profile stays local and unmapped (it is not deleted), never
  enters `profileIdsBeingCreated`, and only metadata is logged. An adopt whose
  own lookup is in flight at retirement can still write its mapping, into the
  retired account's mapping store.
- **Guest migration ignores soft-deleted rules** on both stores: a Space
  deletion soft-deletes its rules for the sync tombstone, and a Guest store has
  no engine to purge them.

## URL Rules

URL rules are the fifth entity kind (`phi-urlrule`) and the third owned-item
kind registered with the engine, under the label `urlrules`. The engine has no
rule-specific branch: the kind is data in the `ownedKinds` list, and the round
order is settings, Spaces, bookmarks, pinned tabs, URL rules — rules are always
the last kind on a page, so the "last kind landed but the marker not yet
written" restart window falls on them.

- A rule's owner is its target **Space**, never a Profile: the wire carries
  `target_space_uuid`, and the Profile is derived from the Space the device
  resolves it to. A rule whose `target_space_uuid` does not resolve on this
  device is parked — its target is never rewritten to some other Space and the
  entity is never discarded.
- Deleting a rule locally is always a soft delete: the row keeps its identity,
  gains a `deletedDate`, and the round's diff turns it into a tombstone. The row
  itself is hard-deleted only after that tombstone is `.applied`, and a soft
  row that never got its tombstone out is purged 30 days later.
- Three automatic merge passes run over rules that look identical (same
  normalized host, path prefix and target): a claim pass re-keys a matching
  local row onto an inbound identity instead of creating a second row
  (`adopted`), a collapse pass soft-deletes all but one member of a settled
  group (`collapsed`), and a yield pass keeps an unpublished local edit alive
  when a remote delete arrives for the same rule (`transferred` /
  `yield_no_partner`). The last pass is this kind's half of ruling C4; its
  user-visible consequence is stated once, under "Edit beats delete".
- The cursor table lives in `users/<sub>/sync/urlrules-cursors.json`. Its field
  set is exactly the one the bookmark and pinned-tab tables use; the merge
  partner of a rule is a column on the local row, not a cursor field.
- Two flags on the shared Space table, `urlRulesHadRecords` and
  `urlRulesReplayedForEmptyTable`, decide whether an empty table is a loss and
  gate the one-shot full replay that repairs it. They are independent of the
  bookmark and pinned-tab flags. A birthday mismatch preserves both flags until
  explicit reconfiguration clears the native sync state. The loss criterion is never "local rows still
  carry a `syncId`": every live rule row carries one, so that test would replay
  the whole type on every round.
- The local projection is not frozen at the start of a round. The first read
  seeds the round; after every landed page the engine re-reads the rows. A
  failed re-read keeps the previous projection and is never treated as zero
  rows. A failed first read fails the kind closed for the round
  (`local_read_failed`), the same as the other two kinds.
- A page whose arrivals, tombstones and parked items are all empty still runs
  the rule kind's plan and landing (`landsEmptyBatch`), because local
  convergence for rules does not depend on an inbound entity.
- Landing translates each plan step to one batch operation keyed by `syncId`,
  computes the dense per-bucket order for the source and target buckets, and
  applies the whole page as one transaction. When the transaction commits, the
  engine re-reads the rows and asks the local access to refresh the Chromium
  routing table once per page — the change publisher alone cannot be relied on,
  because it deduplicates on instances SwiftData refreshes in place.
- The counter line for `urlrules` ends with six rule-specific fields:
  `normalized`, `owner_moved`, `adopted`, `collapsed`, `transferred`,
  `yield_no_partner`. Their steady state is zero. `normalized` counts inbound
  entities the engine had to normalize before landing (those are republished);
  `owner_moved` counts the target changes that survived batch merging.
  `adopted`, `collapsed`, `transferred` and `yield_no_partner` are filled by the
  claim, collapse and yield passes. `transferred` counts the transfers that
  wrote at least one merge unit; a transfer that loses every unit writes nothing
  and is not counted. `yield_no_partner` counts the yields whose rule had no
  merge partner at all — it is how a legitimate leftover is told apart from a
  defect, so it is never inferred from `resurrected`.
- An inbound tombstone for a rule that still holds an unpublished user edit does
  not hard-delete the row. If the local merge partner of that rule is at rest,
  the edit is transferred onto the partner per merge unit (content group and
  target, each with its own stamp, the target side comparing against
  `max(row stamp, effective account stamp)`) and only then is the row hard
  deleted; both operations run in the same landing transaction, and the
  transaction re-reads the source row first — if the user saved it between the
  pre-pass and the transaction, neither operation runs and the tombstone is
  parked for the next round. If the partner exists but is not at rest, the
  tombstone is parked. If there is no partner row at all, the rule yields: the
  row stays, both baselines are cleared, `deletedAtMs` is written and kept, and
  the end of the publish segment republishes the rule from that tombstone's
  version. Every publish segment re-checks that admission, because the
  republication can fail or be interrupted; a rule whose target Space has since
  gone hidden or purged has the yield revoked and the row hard-deleted instead.
  Bookmarks and pinned tabs yield as well since ruling C4, without the transfer
  and park branches, which need a merge partner; see "Edit beats delete".
- While a rule's inbound entity is parked because its merge partner is not at
  rest, the round's diff emits no tombstone for it and writes nothing at all
  into its cursor. Both conjuncts matter: an owner-shaped park is not covered by
  the guard, and a plain collapse loser never carries a parked entity.
- Local rule edits reach the engine through the store-level
  `urlRuleChangesPublisher()` (debounced in the store, deduplicated on value
  snapshots), never through the UI publisher. The coordinator subscribes with a
  bare sink and tears the subscription down with the engine.

## Verification

`PhiSyncEngineTests`, `PhiSyncEngineSpaceTests`, and
`PhiSyncEngineOwnedItemsTests` cover wire ordering, failed and paginated pulls,
remote merge before publication, and bounded conflict recovery. These tests use
dedicated defaults suites and injected in-memory protocol/local-access fakes.

The marker boundary and the URL rule kind add five test files:

- `Tests/PhiBrowserTests/Sync/Phi/PhiSyncMarkerBoundaryTests.swift` — the
  per-page marker boundary: forced cursor-write failures, the zero-publish
  round, the deterministic abort switches, the loss-replay ordering and the
  mapping-before-row create branch.
- `Tests/PhiBrowserTests/Sync/Phi/URLRuleKindTests.swift` — the rule codec,
  normalization, merge units, counters, the editor's edit set and the
  `pendingLocalEdit` lifecycle.
- `Tests/PhiBrowserTests/Sync/Phi/URLRuleMergeTests.swift` — the three
  automatic merge passes (claim, collapse, yield) end to end through the
  engine.
- `Tests/PhiBrowserTests/LocalStoreURLRuleThrowingTests.swift` — the store-level
  throwing primitives, the batch entry, every real-store migration case (V11 to
  V12, which adds the six sync columns to `SpaceURLRule`; V12 to V13, which adds
  `TabDataModel.locationUpdatedDate` and backfills nothing) and the
  routing-table refresh.
- `Tests/PhiBrowserTests/AccountUserDefaultsRollbackTests.swift` — the
  `AccountUserDefaults` write-face rollback.

`Tests/PhiBrowserTests/Sync/Phi/PhiHybridClockTests.swift` covers the hybrid
logical clock itself, the stamp-0 invariants that survive it, the offline-edit
scenarios for both a rename and a move, the §4.3 carrier rule under the location
edit date, and A9's boundary on an account whose logical time has run a year
ahead of wall clock, for the location stamp and for C4-a's content stamp. The
write side — which gestures record `locationUpdatedDate` and which deliberately
do not — lives in `Tests/PhiBrowserTests/LocalStoreBookmarkThrowingTests.swift`.

Space edit-time stamping (C2-a) is covered on both sides of the pull gate:
`SyncableSpacesTests.swift` for the projection rules themselves — an offline
rename keeping its own time, two successive offline edits keeping their own
per-field times, a slow clock still clearing the stamp it overwrites, a revert
collapsing back onto the baseline, a drag restamping only the Space that moved
and not restamping it again, and D1's suppressions surviving all of it — and
`PhiSyncEngineSpaceTests.swift` for the round: the stamping pass running behind
a shut pull gate, a landing merging against the pending projection and then
spending it, a shut Space gate holding the pass, and a failed cursor write that
neither loses the edit nor publishes. `PhiSpaceSyncStateTests.swift` pins the
cursor round trip with and without the new key.

"Edit beats delete" is covered in three places: the derived predicate, the tree
outcomes and both A9 halves in `SyncableOwnedItemsTests.swift`; the rules
boundary, including a collapse loser whose soft delete an edit must not cancel,
in `URLRuleMergeTests.swift`; and the engine half — the republish at the
tombstone's own version, the `resurrected` counter, the folder-delete lift, a
redelivered tombstone that must not undo its own yield, a Profile-scoped pin's
yield, and the unlinked split partner — in `PhiSyncEngineOwnedItemsTests.swift`.

One suite is **not** compile-only. The hostless convergence harness runs:

```sh
bash build-scripts/test-sync-convergence.sh          # ~20 s, fixed default seed
```

It symlinks the production merge files — `SyncableSettings`, `SyncableSpaces`,
`BookmarkKind`, `PinKind`, `URLRuleKind`, `SyncableOwnedItems`,
`PinnedTabScopeMirror`, `PhiDefaultSpaceMirror`, `PhiHybridClock` and the
generated protos — at their real `internal` visibility, slices out of `Sources/`
at build time the handful of value types and constants they name, and builds one
SwiftPM executable: no `xcodebuild`, no Phi host, no Chromium framework, no
network, and nothing written under `Sources/`. It does need Python 3 and a
resolved `swift-protobuf` checkout, which it takes from the one Xcode resolved
into DerivedData at the revision `Package.resolved` pins, or from
`SWIFT_PROTOBUF_PATH`. Layer 1 asserts the algebraic properties of each `merge`
and of the clock; Layer 2 runs 3+ simulated replicas against a model of the real
server, with each replica stamping through the
production `PhiHybridClock` (`SYNC_CONV_HLC=0` replays the pre-C2 wall-clock
behaviour for comparison, and the skew scenarios always run both). Under clock
skew the harness asserts that a **causally later** edit always wins — an edit
whose author had already observed every competing edit — while reporting
concurrent losses, which LWW gives up by definition. Layer 2 also asserts ruling
C4 in both directions, using the production decision functions: an item whose
delete an edit beat exists on every replica, and a delete no edit contradicted
stays gone everywhere. See `Tests/SyncConvergence/README.md`.

It is a **regression gate**, not a report: any change to a `merge`, a `stamp`, a
tombstone or a landing-decision function must run it and see exit status 0.
Status 0 means no property failed that was not already registered in
`Tests/SyncConvergence/Sources/SyncConvergence/ExpectedFailures.swift`, and no
registered failure silently started passing; status 1 is an unexpected
violation, status 2 a registered entry that no longer reproduces and must be
removed. Every registered entry carries a hard-coded witness that is re-evaluated
on every run, and each is printed in full — root cause, what it waits on and its
counterexample — green or red.

There are two entries today, `bookmarks.associativity` and
`urlrules.associativity`, and they are the same rule twice: "the position winner
supplies rank" (A14 / R-M3-3-25, and R-M3-4a-40 for a rule's target) is not
associative, because whether two positions agree — so rank merges by LWW — or
differ — so rank comes from the position winner — depends on which pair is folded
first. This is a **designed rule retained by ruling C5-b, not a defect**: replicas
cannot diverge from it, because every value a replica computes is a merge against
the single server chain, so fold order decides only which legal outcome a race
lands on. The harness asserts exactly that separately
(`simulation.*.rank-coherence-cannot-diverge-replicas`) and reports how many
distinct converged values the witness can produce. Repairing the rule would
change which rank a user sees after a cross-Space move, so it is a product call
rather than a merge-layer fix; neither entry may be deleted until the rule itself
changes.

The Chromium half of the routing tie-break is covered by
`phi_url_router_unittest.cc` in the fork, which is built and run separately
(`autoninja -C out/PhiRelease chrome unit_tests`, then
`unit_tests --gtest_filter='PhiURLRouter*'`).

Every XCTest suite named above is **compile-only**
(`xcodebuild build-for-testing`). The convergence harness and standalone hostless
regressions execute independently of that application host.
`xcodebuild test` is never run: a hosted XCTest bundle launches a Phi host
process that collides with the developer's running Phi through
`ProcessSingleton`. Nothing here is a substitute for two real Macs — the
cross-device acceptance cases, including the known limitations this document
records, live in [Sync E2E test cases](sync-e2e-test-cases.md), which is a
manual QA reference and not an execution report.

The hostless `./build-scripts/test-sync-space-replay.sh` regression covers enrollment
replay persistence, failed latch/marker writes, restart before activation, and
one-shot replay without launching the application.
