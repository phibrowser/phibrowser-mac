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
sync. Revoked-device registration can rotate that identity; the native HTTP
client resolves it for each request instead of retaining the pre-join ID.
Invalidation fails closed in memory even if its persistence fails.

Legacy completion migrates only after fresh device authorization, unlocked keys,
fresh remote Profile/Space evidence, complete injective mappings, and the legacy
enabled/drained Space state have all been verified. An explicit pending flag
prevents migration. Mapping resolution or ARK unlock alone never proves enrollment.

Setup has one modal host through introduction, verification, Profile/Space
matching, overwrite review and completion. Finish later, Escape and window close
retain unpaired status and discard unsubmitted choices. They remain available
while loading/reviewing/revalidating; confirmed writes and recovery-code
acknowledgement cannot be dismissed. Background work never reopens setup.

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

All native data rounds and Chromium ready-key exposure require enrollment.
Read-only pairing previews use the serialized engine queue without advancing
cursors or landing/publishing data. Each preview starts with an empty marker and
store birthday, then pins subsequent pages to the first response's server
generation. A changed persisted birthday or `not_my_birthday` response discards
preview choices and requires explicit reconfiguration. Ordinary previews never
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

Withdrawing eligibility synchronously blocks
in-flight native writes, stops the invalidation schedule, and notifies Chromium.
A generation fence also rejects old rounds after rapid re-enrollment.

## Sync status contract

The pane aggregates the native context and every eligible user Profile. Missing
contexts, an empty Profile enumeration, unsupported bridge selectors and malformed
payloads mean Checking. Unpaired always means Not started. A partial failure
cannot become global Up to date; the summary time is the oldest successful time
among all required contexts.

Native success requires a drained pull, accepted publication, successful cursor
persistence, and no pending/quarantined input, output, or follow-up work. Local
changes invalidate the current result before debounce. Chromium exposes the
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
| `pendingApply` | inbound — a decrypted entity this device could not land yet (§3.5 fallback B, a landing failure, a mapping write failure, a rebind that did not take effect) | the apply pass | a successful landing |
| `pendingProjection` | outbound — this device's own projection of the Space, with each changed field already stamped at the time the user changed it (ruling C2-a, design option S2) | the stamping pass, from the debounced local-Spaces-change round, ahead of the pull gate | a landing, an accepted commit, a tombstone, or a revert that leaves nothing to publish |

Both are serialized `PhiSpaceEntity` bytes in `sync.phiSpaces`, both are
optional, and neither is on the wire. Adding `pendingProjection` needed no
`formatVersion` bump and no SwiftData migration: synthesized `Codable` decoding
reads an optional with `decodeIfPresent`, so a table written by a build without
the field decodes with it nil (the rule
`PhiOwnedItemCursor.rekeyRejectRounds` states for its own addition). A build
**older** than this one ignores the key and stamps Space edits at publish time
again, which is the pre-C2-a behaviour — correct, just coarser.

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
(`xcodebuild build-for-testing`); the convergence harness is the one exception.
`xcodebuild test` is never run: a hosted XCTest bundle launches a Phi host
process that collides with the developer's running Phi through
`ProcessSingleton`. Nothing here is a substitute for two real Macs — the
cross-device acceptance cases, including the known limitations this document
records, live in [Sync E2E test cases](sync-e2e-test-cases.md), which is a
manual QA reference and not an execution report.
