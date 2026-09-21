# Phi sync publishing

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
publish local settings, Spaces, bookmarks, or pinned tabs must first complete
GetUpdates and process the received updates. Local change notifications use the
same prerequisite as explicit pushes. A completed pull can authorize multiple
commit batches in that round; each batch does not need a separate GetUpdates.

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
  write after GetUpdates and before Commit.

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
  local Profile into it under the old ARK.
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
  `yield_no_partner`). The user-visible consequence of the last one is that an
  edit beats a concurrent delete: the rule reappears on the deleting device, and
  deleting it again after the edit has published removes it everywhere.
- The cursor table lives in `users/<sub>/sync/urlrules-cursors.json`. Its field
  set is exactly the one the bookmark and pinned-tab tables use; the merge
  partner of a rule is a column on the local row, not a cursor field.
- Two flags on the shared Space table, `urlRulesHadRecords` and
  `urlRulesReplayedForEmptyTable`, decide whether an empty table is a loss and
  gate the one-shot full replay that repairs it. They are independent of the
  bookmark and pinned-tab flags. A new store birthday clears the replay latch
  and keeps `urlRulesHadRecords`. The loss criterion is never "local rows still
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
  Bookmarks and pinned tabs never yield: the switch is off for those kinds.
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
  throwing primitives, the batch entry, the V11 migration cases and the
  routing-table refresh.
- `Tests/PhiBrowserTests/AccountUserDefaultsRollbackTests.swift` — the
  `AccountUserDefaults` write-face rollback.

The Chromium half of the routing tie-break is covered by
`phi_url_router_unittest.cc` in the fork, which is built and run separately
(`autoninja -C out/PhiRelease chrome unit_tests`, then
`unit_tests --gtest_filter='PhiURLRouter*'`).

Verification for all of the above is **compile-only**
(`xcodebuild build-for-testing`). `xcodebuild test` is never run: a hosted
XCTest bundle launches a Phi host process that collides with the developer's
running Phi through `ProcessSingleton`.
