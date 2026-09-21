# M3-4a lane E — implementer deviation ledger

Each task records only departures from its brief or specification, plus decisions that the
brief explicitly requires documenting. Matching behavior is omitted so the ledger remains useful.

## Task 2a

Propagate `save -> Bool` from four store types, roll back all six `AccountUserDefaults` write
entry points (R-M3-4a-83), and throw on `SpaceSyncMappingManager` persistence failures.

### Decisions the brief requires documenting

1. **Only four write entry points own a `queue.sync` block.** `removeObject(forKey:)` and
   `set(_:forCodableKey:)` forward to another entry point; snapshots and rollback occur inside
   that callee's block. This satisfies §2.5 rule 3 semantically, although its wording suggests
   six separate blocks. A second queue entry would break atomicity: another writer could
   intervene between snapshot and write, and rollback could erase that writer's changes.
2. **Profile mappings consume the result without throwing.** `ProfileSyncMappingStore.setGlobalUuid`
   returns `Bool` without `@discardableResult`. Both `ProfileKeyManager` callers explicitly use
   `_ = mappingStore.setGlobalUuid(...)` with explanatory comments. §13.3 requires consuming the
   result; §11 assigns throwing only to `SpaceSyncMappingManager`. Throwing here would change
   the failure contracts of `registerLocalProfile` / `adoptRemoteProfile` and controller call order.
3. **`removeMapping` / `removeAllMappings` keep their signatures.** Rollback already preserves
   memory/disk agreement on failure, and both consumers have convergence arguments.

### Implementation decisions that differ from the brief

4. **No compilation fix was needed in `PhiSyncEngine.writeState`.** Its `defaults` is
   `UserDefaults`, not `AccountUserDefaults`, so `removeObject(forKey:)` still returns `Void`.
   Leave the existing guard unchanged. The brief/spec similarly misclassify
   `SentinelVersionGuard.swift:234-235` and `PhiChromiumCoordinator.swift:188`; both also use
   plain `UserDefaults` and need no change.
5. **CASE 2a.1–2a.6 need a new host file.** Neither the brief's file list nor the repository
   provided an `AccountUserDefaults` test file. Add
   `Tests/PhiBrowserTests/AccountUserDefaultsRollbackTests.swift`; files in that directory require
   no `project.pbxproj` change.
6. **CASE 2a.7–2a.10 use existing fixtures:** 2a.7 in `PhiOwnedItemStateTests`, 2a.8 in
   `PhiSpaceSyncStateTests`, 2a.9 and 2a.10(a) in `PhiSyncEngineSpaceTests`, and 2a.10(b) in
   `PhiSyncEngineOwnedItemsTests`. Do not duplicate private helpers.
7. **B2-18 variants (b) and (c) live outside `PhiSyncMarkerBoundaryTests.swift`.** Variant (b)
   shares CASE 2a.9's input and positive control in `PhiSyncEngineSpaceTests`; (c) uses the
   existing production-store section of `SpaceSyncMappingManagerTests`. The new file names both.
8. **CASE B2-10 accepts `ownedStore.saveCalls >= 1`.** A pull writes the table after landing and
   again in `publishOwnedKind`, including its empty-work return. An exact count would couple the
   test to structure unrelated to R-M3-4a-83. B2-4d's `setCalls == 1` and CASE 2a.7 already prove
   no internal retry. Task 2b owns precise failure counting.
9. **CASE 2a.10 cannot yet observe both write helpers returning `true`.** The engine discards
   those results through `@discardableResult`. It can assert zero `save` calls when retired or
   without a store, proving that those paths cannot represent failed saves. Task 2b tests the Bool.
10. **`failNextSave` / `failNextSet` are sticky.** Once true, every call fails until the test
    clears the flag. Every case explicitly releases failure this way; one-shot failure would
    allow a second write in the same round to succeed silently.
11. **Four small existing-test adjustments follow directly from this task:** wrap two
    `store.setSyncUuid(...)` calls in `XCTAssertTrue` to consume the result; restore directory
    permissions before cleanup in the three store suites; reset
    `PhiSpaceSyncState.shared.localSpaceIdLookup` in engine-test teardown; and add a store
    constructor returning `Account` without changing the existing constructor or its three cases.

### Validation scope

12. **Compile-only**, under the global constraint (`xcodebuild build-for-testing`). The cases
    using `chmod 0o500` for persistence failure (2a.1–2a.8 and B2-18's main probe / variants
    a and c) were not run. The injection is expected to be deterministic for a non-root process
    because `.atomic` needs a temporary file in the same directory; assertion values remain unmeasured.

## Task 3

Add `PhiSyncMarkerStore` / `marker.json` (§2.10 / R-M3-4a-18), one-time migration, a smaller
`stateKeys`, engine `markerStore` injection, and marker-file deletion during self-revocation/reset.

### Decisions the brief requires documenting

1. **Add `PhiSyncEngine.legacyMarkerStateKeys` (ruling 3, absent from the spec).** `stateKeys`
   shrinks to five entries, but account switching and self-revocation step 5 erase
   `stateKeys + legacyMarkerStateKeys`; `hadCursor` recognizes both. Migration runs after that
   erase. Otherwise a failed migration followed by account switching could migrate the previous
   account's marker into the new account's file. The defaults-backed store's `deleteFile()` also
   removes both legacy keys, preserving reset behavior.
2. **Update comments in two files omitted by §11's Task 3 list (ruling 6).**
   `PhiOwnedItemState.swift` now locates the marker in adjacent `marker.json`.
   `SyncableSettings.swift` uses `phi.sync.version` / `phi.sync.entityId` as `valueSignature`
   deduplication examples; deduplication remains necessary. Update the coordinator debounce
   subscription comment in the same way.

### Implementation decisions that differ from the brief

3. **Append to the existing marker boundary test file.** Task 2a already created it for B2-4d,
   B2-10, and B2-18. Add B2-11a…d and 3.1 / 3.3 / 3.4 / 3.5, plus their header inventory.
4. **`SelfRevokeTests.makeController` needs two new arguments:** `ownedItemStores = []` and
   `markerStore = nil`. CASE 3.2 needs two nonempty cursor tables, but the former argument was
   missing. Existing cases remain unchanged.
5. **No separate failing compilation for step 1.** The missing `PhiSyncMarkerFile` type already
   establishes the expected compile failure; a local build takes minutes. Final compilation used
   a full build followed by an incremental run to obtain exit code 0.
6. **`MemoryMarkerStore.saves` records failed calls too.** Like `MemoryOwnedItemStore.saveCalls`,
   it is an invocation count; `failSaveOnCallNumber` uses that count and `saves.isEmpty` proves no write.
7. **Check legacy keys before loading the store.** The brief leaves order open. Once keys are
   removed, the steady path avoids a disk read while retaining the same outcomes.
8. **Additional assertions follow directly from existing criteria:** CASE 3.3 verifies request
   marker `"4"` and a real empty-marker-file write; 3.5B also checks legacy-only `hadCursor`;
   3.2 verifies legacy-key erasure; and 3.1 separately proves `Data()` differs from nil on disk.
9. **Unchanged-state early return reduces defaults writes.** With an unchanged birthday, the
   fallback no longer rewrites both legacy keys on every page. Existing assertions do not observe
   this; only change notifications could, and production avoids unnecessary persistence.
10. **Rechecked every existing marker assertion after line shifts.** Nine of ten key-seeding
    sites run before engine creation. The one later site is a preview test that checks unchanged
    keys; preview never reads `storedMarker`, so the in-memory mirror does not affect it.

### Validation scope

11. **Compile-only.** The thirteen listed cases (B2-11a…d, 3.1 ×2, 3.2, 3.3, 3.4, 3.5A / B)
    were not run. Non-writing loads, atomic saves, and Gate-driven 3.5A are expected to behave
    deterministically based on equivalent existing file-store and shutdown cases.

## Task 2b

Implement B-2 page boundaries: marker suppression, round-scoped `RemoteView`, earlier guard 2,
per-page owner-map invalidation, four save-failure sites, outcome logging, debug abort switches,
publish gating, and the two acknowledged writes that arm per-kind loss replay.

### Decisions the brief requires documenting

1. **Ruling 3 (R-M3-4a-89):** move guard 2 after `recordsGatedMarkerMoves` and before `do`, reading
   only `spaceTableAtEntry`. Reverse the latch/marker order from `c549c4c5:1690-1691`: first
   acknowledge `persistStoredMarker(nil)`, then persist the three flags through `mutateSpaceTable`,
   then update memory. R-89 replaces R-47's shared-closure wording only. Maintain `hadRecords`
   earlier too, in a separate mutation: the flag closure runs only with empty cursors and could
   never set it true.
2. **Ruling 3b (R-M3-4a-103):** similarly reverse and acknowledge both loss-replay writes in
   `loadOwnedTable`. Both failure branches return `(table, false)` and set the engine's
   `roundOutcome` to `.cursorSaveFailed`. Log only after step 2 succeeds. Explain that no separate
   `publishBlocked` flag is needed because this outcome gates the entire publish phase. Task 6
   supplies CASE U-18 probes.
3. **Ruling 5:** there are four failure sites, not three. Count only `SpaceSyncMappingError.persistFailed`
   in the Space create mapping catch; other mapping errors do not count. Profile refresh failures
   do not count despite §13.2's literal wording: refresh precedes page processing and belongs to
   no page. `spaceCounters.profileRefresh = "failed"` still reports it.
4. **Ruling 6:** emit `logRoundOutcome()` from `run(_:)` before `logSpaceRound()`, rather than the
   spec's `serialized(_:)`; preview emits none. Multiple pulls use the last outcome and accumulate
   pages/failures across the round. Save failure overrides every outcome except `.notMyBirthday`,
   including budget exhaustion and unusable settings, not merely the brief's three named outcomes.
5. **Ruling 8:** use `#if DEBUG || PHI_SYNC_DEBUG_SWITCHES`, without `ADHOC` or project changes;
   this repository enables only `DEBUG`. `abortIfRequested` takes `DebugAbortPoint`, not a string,
   allowing both key constants/body to disappear in release while call sites need no `#if`.
   Key spellings remain unchanged.
6. **Ruling 10:** retain the catch's drain-triggered marker clear and update its §2.4 note 4
   explanation. Split B2-8 into incremental marker-at-page-3 and drain/full-replay variants.
7. **Ruling 11:** preserve existing assertion conditions. Update the interrupted-drain test's
   documentation and nil-assertion message for page boundaries, plus engine guard/order,
   gate-bookkeeping, and durability comments to state persistence precedes that page's marker.
8. **Ruling 12 (R-M3-4a-88 / 92):** add the third conjunct to the sole `canPublishThisRound`
   assignment, leaving downstream publish entries and conflict retry guards unchanged. Use
   `cursorSaveFailures == 0`, not an outcome comparison: early guard/reset failures may precede
   outcome assignment, and the predicate asks whether all local persistence succeeded. Drain
   finalization failure also yields `.cursorSaveFailed` (B2-4b).

### Implementation decisions that differ from the brief

9. **Four test accessors read `LoggedRound`,** captured at outcome emission. Live counters can
   already belong to a queued follow-up round, whose `run` resets them immediately.
10. **Add `FakePhiSyncClient.gateGetUpdatesFromCall`.** It activates the existing gate only from
    request N, allowing tests to stop an automatically queued, non-awaitable follow-up at its
    first request. Used by B2-1c(c), B2-8b, and B2-9's reverse direction; after release, enqueue
    `pullOnce()` to await completion. Nil preserves both existing gate behaviors.
11. **B2-4d does not yet assert one local Space row.** At this stage create precedes mapping;
    failed mapping leaves an unmapped row that retry duplicates. Task 3b's mapping-first change
    and B2-4d-x address that. This probe checks failure counting, unchanged marker, parking,
    and a durable/resolvable mapping on retry.
12. **B2-2b lives in `PinnedTabScopeTests`** to reuse its real `LocalStore` fixture and production
    `AccountPhiPinnedTabAccess.apply` → `applyPinSyncBatchThrowing` path.
13. **B2-7c does not assert zero inbound tombstones or `applied == 1`.** `tombstones` counts the
    received tombstone, so it is 1. Zero outbound tombstones are established by no deleted commits
    and `pushed == 0`.
14. **B2-13 seeds both `drainInProgress` and `hasDrainedFullReplay`.** Otherwise a nil entry marker
    makes guard 1 clear the latter, and the owned publish guard prevents the intended two loads.
15. **B2-5b replays through a second engine.** Direct file mutation cannot update the first engine's
    marker mirror; creating another engine models restart from the rolled-back file.
16. **B2-14(d) releases failure before the second engine's full replay.** Page-1 suppression means
    the first engine never performs write 2. Keeping `failSaveOnCallNumber = 2` in the second
    engine would fail its first-page marker write and contradict the expected successful replay.
17. **The pull catch no longer flushes observations or parks undelivered entities.** Those
    collections are page-local, and the only throw is a `getUpdates` failure before that page
    arrives. `parkUndeliveredOwnedEntities` remains only for `ownedReadFailed`; document this.
18. Add private `persistStoredMarker(_:) -> Bool` and `normalizedMarker(_:)`. The property setter
    writes through the former; page boundaries, guard 2, and loss replay consume its result.
19. **Two assigned Task 2a follow-ups:** skip direct-delivery cache refresh on failed store save;
    capture/restore the shared local-Space lookup in setup/teardown. Keep the known pre-save
    `ownedTables[label] = table` assignment as directed, with its rationale in the write helper.
20. Count failures outside `pull` too, including `.spaceGate` and reset-table writes, and report
    them in that round's outcome. The counter is engine state reset by `run`.

### Validation scope

21. **Compile-only** (`xcodebuild build-for-testing`). The 31 new cases were not run. Follow-up
    and conflict-retry write indices, including B2-1e's fourth write and B2-4b's `saveCalls + 2`,
    were derived from code rather than measured.

### Fix round 1 — one Important review finding

22. **Controller ruling for R-M3-4a-103:** failure of either replay-arming write prevents that kind
    from publishing this round and leaves loss detection retryable next round. Keep both
    `(table, false)` returns and add no load-helper gate. Instead, immediately after
    `guard !loaded.lost` in `publishOwnedKind`, guard `cursorSaveFailures == 0`.
    Otherwise the caller has already passed the round's publish gate and can diff/commit against
    an empty table, recreate its file, suppress future loss detection, and permanently lose replay.
    CASE 2b-L1 is
    `PhiSyncMarkerBoundaryTests.testAFailedLossReplayArmDoesNotPublishAgainstTheLostTableNorRecreateItsFile`.
    An empty settings entity and unreadable Space hashes isolate the zero-commit assertion to
    bookmarks. Task 6's two U-18 R-103 variants cover URL rules.

## Task 3b

Move Space creation mappings before row creation (R-M3-4a-87), and prove dangling-mapping
recovery with B2-17 / B2-17a / B2-17neg / B2-4d-x.

### Decisions the brief requires documenting

1. **One existing test changes its expectation under R-87.** Rename
   `testAFailedCreateWritesNeitherAMappingNorABaseline` to
   `testAFailedCreateLeavesADanglingMappingAndNoRowForTheNextRoundToHeal` and assert one mapping
   to `sync-new`, zero rows, nil `reconciled`, and non-nil `pendingApply`. Update the creation
   ordering comment. Other creation tests retain their assertions: A0 recovery handles the
   second round of failed landing. No existing test asserts the `.mapSpace` call case;
   `PhiSpaceLocalAccessTests:171` remains unchanged with both new knobs defaulting to nil.
2. **Controller ruling 7:** mapping `persistFailed` is the fourth save-failure site; §2.5 rule 4
   needs that count updated. Move Task 2b's catch before landing while preserving parking for
   all mapping errors and counting only persistence failures. B2-4d-x verifies it.
3. **B2-17neg is explanatory, not executable.** The comment above B2-17 and this entry identify
   the three assertions that fail under the old order: one row, one mapping to `sync-new`, and
   a recorded `.dropSpaceMapping`.
4. **Ruling 6's third recovery path is reasoned only:** failed mapping removal leaves a collision
   on remap, so the entity parks until another round. The fake cannot fail removal; document
   the argument in B2-17.

### Implementation decisions that differ from the brief

5. **Insert immediately before `// A2 + A3`,** close to landing. Since `c9ab5806`, a profile-id
   resolution block intervenes after merged-value construction; the brief's earlier placement
   would be semantically equivalent, but this better expresses mapping immediately before row creation.
6. **Retain Task 2b's persistence-failure increment in the moved catch.** The brief's literal
   snippet predates it; task assignment and ruling 7 require it.
7. **B2-17a proves the update branch through `.themeState(newId)`, not `.update(id)`.** Replaying
   identical values produces no field differences, so `access.update` cannot occur. Theme-state
   application is unconditional for a non-default Space; combine it with one total create and
   no mapping removal to prove update without duplication or recovery.
8. **Reuse this file's marker-boundary fixtures.** The brief names private fixtures from another
   file while requiring cases here. Use `makeSpaceAccess`, `spaceCreateEntity`, `pagesByMarker`,
   `makeOwnedEngine`, `drainedSpaceStore`, and `markerStore`; incidental profile/Space names
   differ (`pu-1` / `S`) but appear in no assertion.
9. **Extra replay assertions:** B2-17 checks marker `"3"` after non-persistence landing failure,
   request marker `"3"` with no new page on retry, and a newly minted row id after recovery.
   B2-17a / B2-4d-x similarly verify marker `"0"` for same-page replay.
10. **Filter `spaceCommits` by `PhiSyncEntity.spaceEntityName`.** The other file's helper uses
    a settings-hash exclusion and is private.

### Validation scope

11. **Compile-only.** The three new cases and changed existing case were not run. Recovery,
    update-branch theme application, and create deduplication are inferred from the code paths.

## Task 6

First integration task, based on `154b3f39`: URL-rule cursor table and flags, registration and
coordinator wiring, subscriptions, five rule counters, `reportsRuleCounters`, `landsEmptyBatch`,
rule-side B2 cases, U-18's R-103 variants, and U-11.

### Decisions the brief requires documenting

1. **This task owns the seventh access member, `refreshRoutingTableAfterLanding()`.** It is absent
   from §5.6's protocol inventory. Add it to the protocol, production access (calling
   `SpaceManager.shared.reloadURLRulesFromStore()`), and fake call log. The engine uses the access
   member rather than calling the manager directly. Task 8's unverified assumption remains:
   the main context must see the awaited background save. Refresh follows `access.apply`, but
   compile-only validation does not establish runtime visibility.
2. **Add `OwnedPlanOutput.normalized` and `OwnedLandingOutcome.ownerMoved`,** neither named in
   §11. Count surviving `.move` operations after batch demotion; the plan supplies normalization
   count. `collapsed`, `transferred`, `yieldNoPartner`, and rule adoption remain zero here but
   are included in logging.
3. **Correct brief references:** the `Round` case is at `c549c4c5:687`, not 684, and the entry
   is `handleLocalOwnedChange(label:)`, not `(kind:)`. Wiring/tests use the actual API.
4. **New CASE U-27–U-31** live in the Task 6 section of `URLRuleKindTests`; Task 12 adds their
   numbers to §12.1. The controller-assigned U-11 lives there too.
5. **Store pre-normalization remote bytes in `server`.** `urlRulePlan` fills `serverBytes`
   before `normalizeArrivals` (ruling 5).
6. **Keep tombstone assembly minimal:** one inclusive read and a call with `pendingClaims: []`.
   The `rows` binding is documented as the Task 9 `explicitDeletions` / 8b-3 `deferredDeletions` hook.
7. **`landsEmptyBatch` (R-M3-4a-99)** is true for rules and explicitly false for bookmarks/pins.
   Add only that disjunct to the empty-batch guard, preserving its replay bookkeeping.
   M-35 tests the behavior in 8b-2. Consequently every rule page reaches `writeOwnedTable`,
   adding an atomic rule-cursor write even when unchanged; other kinds retain their early return.

### Implementation decisions that differ from the brief

8. **`localIdentities` reads `state.rows`, without another fetch.** It runs immediately after
   successful `beginRound` in the same `do` block, so that inclusive projection already has the
   required identities. The brief's second read adds no information.
9. **Production `reloadAfterPage` really performs another fetch.** Despite the brief's claim,
   the protocol has no cached-row accessor; `allURLRulesIncludingDeleted()` calls `rebuildCache()`.
   A cache-only API belongs to Task 8's protocol scope and is not added here.
10. **Verify landing before `reloadAfterPage`.** Failed cache rebuilding invalidates the cache,
    after which identity lookup asserts. A successful `apply` has already refreshed it; verify
    then, so a later reread failure cannot make committed rows look absent. On such failure,
    sibling projection falls back to `state.live` grouped by `spaceId`.
11. **An existing-row `.create` becomes `.update` / `.move`.** Lookup includes soft-deleted rows
    (R-M3-4a-42(a)), making replay and resurrection updates rather than duplicates. Batch assembly
    combines/demotes operations. Emit reorders only for other affected siblings whose indices
    changed, preserving §8.3 rank projection rather than relying on final `(sortOrder, id)` order.
12. **Extract pure `ownedRoundLogLine(_:counters:)`.** U-27 needs to inspect formatting, while
    `AppLogInfo` has no test interface and new driving entries are prohibited. A static pure
    formatter supplies observability without driving behavior. Bookmark/pin lines remain byte-identical.
13. **U-18(f)'s retry differs when replay contains a rule.** With a nil disk marker, guard 1
    arms drain at round start; replay lands `r1` and recreates its cursor before loss detection,
    so no latch retry is needed. Split coverage into
    `testAFailedLatchWriteAfterAClearedMarkerStillEndsInAFullReplay` and the empty-account
    `testAFailedLatchWriteIsRetriedWithAnIdempotentMarkerClear`. The latter checks unchanged marker
    save count, armed latch, and drain. Initially use `saveCalls + 2` for the latch write because
    the page writes the Space table first; the review correction below supersedes this count.
14. **U-18(e) initially permits one Space-table write.** Every page writes the table independently
    of replay step 2; assert no additional write and unchanged latch/drain flags. See review correction.
15. **U-18(a)–(d) use decimal marker `"5"` and replay watermark `"3"`.** The fake parses decimal
    watermarks, so the brief's `"M5"` would mean zero. This makes the rule visible only on full
    replay. Variant (c) uses a row without `syncId`, (d) one with it, to cover both criteria.
16. **U-30 also seeds `deletedAtMs`,** following bookmark cases 6.18 / 6.21. Otherwise the same
    round's publish phase can mint keys or process a tombstone after reset, obscuring reset state.
17. **U-28 uses `RecordingSpaceStore`** to record the first true values of the three had-records
    flags. Existing fakes lack a shared recording hook, and changing them requires explicit declaration.
18. **U-29's sink records the registration label without driving the engine.** It matches the
    coordinator subscription shape; engine invocation has no countable test interface. Its real
    store uses a temporary directory cleaned by teardown.
19. **U-11 silences other sections as in 2b-L1.** Mark three mapped Spaces unreadable and seed an
    empty settings entity. Each engine has separate defaults/stores; read the actual committed
    server version instead of hard-coding `v+1`.
20. **Only the three named marker-boundary additions are made:** B2-3 and the shared five-kind
    B2-7 / B2-7b fixture. Other Task 6 placeholders remain for Task 12 to resolve.

### Validation scope

21. **Compile-only:** quiet `build-for-testing`, exit 0, no errors or warnings in touched files.
    Nineteen new cases and three extensions were not run. Landing conversion, conflict retry,
    round-entry replay, and `hadRecordsSeen == [true, true]` are inferred from code.

### Fix round 1 — one Important review finding, tests only

22. **Silence settings and Spaces in U-18(e), (f), and (f-empty).** Their fixture maps three
    cursorless Spaces; otherwise Space creates and a table write precede owned publishing,
    invalidating zero-commit assertions and hitting the wrong failure index. Call
    `silenceOtherSections` from `makeLossFixture`, make it throwing, and add `try` at seven callers.
23. **Recalculate write indices after silencing.** `pushSpaces` still writes its empty-work table:
    page write #1, Space publish write #2, replay latch write #3. Use `saveCalls + 3` in both
    (f) variants; (e) asserts exactly two writes, proving step 2 never ran. Recheck (a)–(d): their
    replay, zero-rule-commit, marker, and drain expectations remain unchanged.
24. **Remove the file's sole compilation warning.** U-29 calls `RunLoop.main.run` through
    synchronous `waitPastDebounceWindow`, matching the local-store test pattern; direct use in
    async context becomes an error in Swift 6.
25. Validation remains compile-only, exit 0 with no touched-file errors/warnings. Coverage comprises
    the failed-marker-clear case, both failed-latch-write cases, and the four shared-fixture variants.

## Task 9

Integrate lifecycle handling: `explicitDeletions` (R-M3-4a-78), rule tombstone inputs, parked-row
retention exemption (R-M3-4a-27), two soft-delete cleanup exits, protocol/registration/fake wiring,
the third controller-owned store, and birthday-reset verification.

### Decisions the brief requires documenting

1. **`explicitDeletions` bypasses only the two owner gates.** Preserve all three predicates,
   pending-claim exclusion, and cursor bookkeeping. Add the default-empty argument after
   `pendingClaims`; existing bookmark/pin callers and eight module-test calls remain unchanged.
   Document the future deferred-deletion exclusion before predicate 1.
2. **Three rule exceptions:** build locals without owner filtering so live rows targeting hidden,
   purged, agent, or stale-incognito Spaces remain in `liveIdentities` by `syncId`. Predicate 3
   protects them, with the two owner gates as a second defense; U-12 variants cover this.
3. **Parked exemption does not refresh `ownerUuid`.** Check `pendingApply` before claimed-owner
   eligibility, count and skip the cursor, and log one kind/count info line when any are parked.
4. **Cleanup exit 1 follows table persistence and precedes conflict retry.** Collect applied
   tombstones alongside minted identities in commit-outcome processing. A hard-delete error logs
   the kind without rollback. The review below adds a successful-save requirement.
5. **Exit 2 needs no store-file change.** Production access reads all rows once, selects
   `deletedDate < cutoff && syncId != nil`, and hard-deletes each in its own transaction. Per-row
   transactions are intentional. Soft-deleted rows without identity are unreachable under R-23.
6. **Both optional registration hooks default to nil,** preserving synthesized initializer
   defaults and requiring no bookmark/pin factory changes.
7. **Self-revocation:** keep the controller's store loop unchanged and append the existing
   `urlRuleStore` in coordinator wiring. Identity clearing remains bookmark-only, with comments
   at the closure and controller step 4. The rule protocol explicitly forbids `clearAllSyncIds`.
8. **Birthday reset already covers the third kind.** The registration loop writes each table;
   Task 6 already resets `urlRulesReplayedForEmptyTable`. No implementation change; CASE 9.3 verifies it.

### Implementation decisions that differ from the brief

9. **U-13c models completed store-side cascade by starting without X's row.** The Space fake does
   not cascade into the rule fake, and modifying it is unnecessary. Assert the engine's mapping
   removal, cursor exemption, zero tombstones, and payload-based recreation separately.
10. **U-13b's first page includes the Space tombstone and three rule updates.** A tombstone alone
    cannot create rule `pendingApply`. Same-page Space-first landing makes rule targets ineligible
    and parks the updates. Seed a landed `su-1` cursor and remove it from unreadable hashes;
    the undo variant restores that cursor to live state.
11. **U-13's RR-B6 restart probe** throws `Boom()` on the first commit to model process loss before
    send, then reuses access/store/client in a new engine. Row `deletedDate` and cursor
    `deleteDecidedAtMs` must survive restart and be written only once.
12. **CASE 9.3 throws on owned commit.** Edit `r1.host`, silence settings/Spaces, and inject
    `.notMyBirthday` into that commit. U-30 instead injects it during GetUpdates.
13. **U-20(a) uses a stale incognito runtime id as the ineligible target.** It exercises the same
    R-8 predicate as an agent Space without needing an actual agent id shape.
14. **Add fake `deleteError`** for both cleanup exits, analogous to `readError`. This task does
    not use it; it is available for review and later failure-path probes.
15. **Expired soft-row purge is independent of `spaceSectionEnabled`,** as specified. Rows older
    than 30 days may be removed before sending their tombstone while the gate is closed. Existing
    origin-(a) diff later emits it if the owner is eligible. An ineligible owner can leave an
    account orphan, matching existing M3-3 bookmark hard-delete behavior.
16. **Add optional `clock` to the rule-test engine factory** for 9.1 / U-13c; omitted clocks
    remain frozen at `Self.now`.

### Validation scope

17. **Compile-only:** exit 0, no errors or touched-file warnings. Sixteen new cases were not run.
    Live-row protection, explicit-deletion gate bypass, applied-tombstone cleanup, parked retention,
    and cursor-before-row expiry are inferred. U-22's other two zero commits assume stable ordering
    reuses baseline ranks, as does U-18(a).

### Fix round 1 — one Important and one Minor review finding

18. **Run exit 1 only after a successful cursor save.** Capture `writeOwnedTable`'s Bool and gate
    hard deletion. On failure, the invisible soft-deleted row survives; next round reloads the
    durable cursor and retries its tombstone before deleting. CASE 9.4
    `test9_4_exit1IsSkippedWhenTheCursorTableSaveFails` calibrates saves in a live-row round, then
    fails the publish write at `saveCalls + N`. Rule empty-page landing also writes the table, so
    a fixed index would be wrong. Assert both `.cursorSaveFailed` and a sent tombstone.
19. **A row-level purge failure does not abort later rows.** Catch per row, count successes, log
    one R12 warning with kind/failure count, and return successes. Only the initial read can throw.
20. **9.3 / 9.4 script empty pages.** Seeded server rows have empty ciphertext solely for commit
    updates; allowing the default pull to receive them would mark them unreadable and suppress commits.
21. Validation remains compile-only, exit 0, no errors or touched-file warnings.

## Task 11

Unify editor Save and agent add/update/delete through `SpaceManager.applyRuleEdits`; remove both
replacement wrappers and optimistic pushes. The editor computes explicit row edits, clears rows
as deletions, and sends only order units for bucket reorder. Remove stale-target fallback/drop
behavior. Agent drafts preserve identity/target/order, and write replies wait for commit.
Commit reference: `task-11-report.md`.

### Four decisions the brief requires documenting

1. **Ruling 1:** Task 5 already supplies optional `URLRuleDraft.spaceId` / `.sortOrder`, where nil
   means omitted. Consume them directly; no blocker. Task 12 updates §15.
2. **Ruling 3:** Task 5 already resolves a missed local id through `syncId` and rewrites `row.id`
   to the draft id. U-14 legacy covers it; §4.3 rule 3 still needs this added by Task 12.
3. **Ruling 5:** the router file is absent from §11, and `write_failed` is a new error code.
   All three registrations return nil for asynchronous `ExtensionMessaging` replies, following
   profile handlers. `ok` now means committed. No repository-wide protocol error-code table
   exists, so handler comments document the code.
4. **Ruling 6 / §6.6 row 5:** Space deletion launches a main-actor task that awaits the throwing
   user-intent cascade and refreshes rules; failure emits one R12 log. This adds a Task hop before
   enqueueing, but no subsequent synchronous store write depends on the old order; only defaults
   theme cleanup follows.

### Implementation decisions that differ from the brief

5. **Controller-approved `SpaceManager.makeForTesting(boundTo:)`:** private initialization/binding
   otherwise make U-24c(a)'s isolated manager impossible. The internal main-actor factory sets only
   `boundAccount`, without publishers, default-Space setup, or the singleton. Mark it test-only;
   source search confirms no production call. Tests assign the account's lazy storage to a temporary store.
6. **Reorder drafts omit content and target units.** Task 5 defines nil as untouched, which is
   safer than copying possibly stale cached values. Only `sortOrder` changes; stamps remain intact.
   Compare existing rows and loaded ids retained in the same bucket: deletion/clearing alone does
   not reorder the bucket, whereas insertion or movement into it does.
7. **Restoration (R-101 / 104):** a dirty row missing from the current store retains its local id
   but gets nil `syncId`, avoiding the soft-deleted identity collision in store step 2b. The brief
   deferred identity reuse to 8b-4; the controller checklist specifies nil. Covered by
   `testADirtyRowDeletedRemotelyComesBackWithoutItsOldSyncId`.
8. **`Row.init(from:)` uppercases lowercase UUID-shaped ids.** Upsert then resolves through `syncId`
   and rewrites the local id. Identity and deletion still work, but this adds a write. U-14's main
   seed uses uppercase UUID to assert unchanged id. Using `storeId` in the draft would avoid it
   but conflict with the brief's legacy-case expectation, so retain the specified behavior.
9. **Three comments still mention removed symbols:** the Task 5 flat initializer comment and
   frozen V7/V8 schema documentation. Code searches find no old symbols. Those files are outside
   this task's allowed files; Task 12 owns final cleanup.
10. **Keep draft compatibility accessors** `host`, `pathPrefix`, and `askBeforeRouting`: production
    no longer uses them, but `URLRouterTests.swift:600` does.
11. **Agent bucket ordering uses `(sortOrder, id)`.** Store output is normally ordered, but the pure
    helper accepts arbitrary input and tests construct it directly.
12. **U-15b/c do not run the engine for tombstone counts.** The real store and fake rule access are
    different objects. Assert row state here; Task 9's U-22 / U-12 cover zero/one tombstone outcomes.
13. **U-24c(b) additionally tests target-changing update,** checking both source and target bucket
    ordering. Delete uses a directly constructed edit set as specified.

### Validation scope

14. **Compile-only:** exit 0, no errors or touched-file warnings. Nine new cases were not run.
    U-14 / U-22 / U-24c(a) rely on Task 8's unverified main-context visibility after awaited
    background save, using the existing `drainMainQueue()` pattern.
15. CASE 11.1 searches find no removed code symbols, exactly three agent `applyRuleEdits` calls,
    and `localStorage` only in `storedRules()`, never inside the three handlers. Comment leftovers
    are listed in item 9.

### Fix round 1 — two Important and one Minor review finding

16. **Use a new private `init(testAccount:)` for the test factory.** The old default initializer
    bound the real account, ensured its default Space, subscribed to publishers, and refreshed
    routing, making count assertions timing-dependent. The new initializer only sets the account.
    Thus U-22's count 1 and U-24c(a)'s 0 → 1 → 2 → 3 are driven only by `applyRuleEdits`.
17. **Skip vanished siblings in reorder drafts.** Pass 3 requires `storedByStoreId[storeId] != nil`.
    Otherwise a remotely deleted sibling enters the insert path with nil content and rolls back
    Save through `noCandidateSurvived` / `rowAlreadyMapped`. CASE 11.2
    `testAReorderStillCommitsWhenASiblingVanishedBehindTheSheet` verifies omission, successful
    commit, and dense order.
18. Change `computeEditSet`'s detailed contract block from doc comments to ordinary comments,
    retaining the first English doc-comment line.
19. Validation remains compile-only, exit 0, no errors or touched-file warnings.

## Task 8b-1

Define D30 signatures/rest predicates and M1 claims; add six access queries/update hooks,
production/fake implementations, re-key operations and store bodies, cursor removal, M1 pre-pass,
claim landing, projection updates, and post-commit retirement of old cursors.
Commit reference: `task-8b-1-report.md`.

### Five decisions the brief requires documenting

1. **Populate the three existing context members:** `pairs`, `adoptedMerges`, and
   `adoptedFieldWrites`. Only clarify the `pairs` comment: entity identity -> stable local id,
   bookmark `guid` or rule `id`. Carry claimed ids through default-empty output/landing maps,
   preserving bookmark/pin construction sites.
2. **Rule `notePersistedClaims` maps local row id -> new syncId,** opposite to bookmark
   identity -> guid. State this in the protocol and both implementations.
3. **M1 is not publish-gated.** It runs in landing's `urlRulePlan`; the existing publish gate is
   unchanged. M-11 uses an undrained `MemorySpaceStore` and expects three adoptions.
4. **Follow §8.4.2's member table:** `adoptedFieldWrites` means merged bytes differ from the
   current local projection; `mustRepublish` means they differ from the arrival. The spec's
   step-2 prose instead ties the first set to any locally winning unit, which is inconsistent.
   Task 12 must record this in §15.
5. **Normalization is an explicit required argument** to all three signature helpers. Every
   caller passes `URLRuleSignatureQueries.normalize` / `LocalStore.normalizedRule`. Row
   signatures normalize independently, including M-8's `"GitHub.com."` fixture.

### Implementation decisions that differ from the brief

6. **Add `tombstonesThisPage` to `mergePartners`.** The brief requires all ten at-rest predicates
   and M-28(a) variant 10, but its signature provides no source for page tombstones. 8b-3 wires
   `input.tombstoned` into this argument.
7. **Share four query implementations in `URLRuleSignatureQueries`.** Production supplies cached
   rows/live rows, and the fake supplies its rows. Duplicating predicates risks divergent rest decisions.
8. **Claim candidates include parked entities as well as arrivals,** matching the planner's
   work set. Otherwise M-1(5)'s failed landing could create a duplicate on parked retry. Exclude
   remote identities already represented locally, including soft-deleted rows, and local rows
   whose identity arrives on this page; both already have an identity-based landing path.
9. **Claims enter account-ranked bucket projection.** Treat them like creates. A changed position
   still writes values even without changed fields; fold the update into re-key rather than
   emitting a second reorder (R-42(b)). A value-bearing batch re-key records its target bucket.
10. **Deduplicate re-key by local id.** Keep the first operation and assert in DEBUG on later
    ones. A later conflicting identity fails post-landing verification and parks.
11. **Fake updates clear merge partners only on resurrection,** matching production rather than
    clearing every live row's pointer. M-20's field-writing claim requires this. Fake re-key
    validates both guards/collisions for the whole batch before mutating rows because it has no transaction.
12. **Add `access:` to `urlRulePlan`** for the signature-index query and pass it from registration.
13. **M-2b stops after pull with a scripted error.** Otherwise normal unkeyed publication would
    recover identity/server metadata and obscure the assertion that M1 left it untouched.
    Seed owner `su-1` to avoid unrelated owner refresh too.
14. **M-18's second page is empty in the main variant.** Only rules are registered; empty pages
    still plan/land through `landsEmptyBatch`. The duplicate-claim variant instead receives a
    second rule with the same signature.
15. **Use remote stamps 5,000,000 ms and increasing V/W/X ranks.** These outrank fixture creation
    time 1,000,000 ms, so merges equal arrivals, no republish is needed, and zero-push assertions
    isolate claiming. Default stamp 100 would legitimately make local units win and republish.
16. **Adoption count still uses `pairs.count` on rollback,** because counting precedes landing,
    as with bookmarks. M-1(5) deliberately does not assert this counter.
17. **No test-file project registration is needed.** The directory uses
    `fileSystemSynchronizedGroups`; the dispatch's gem-registration instruction does not apply.

### Validation scope

18. **Compile-only:** exit 0, no errors/warnings. Twenty-four new cases (18 merge, one cursor-state,
    five local-store) were not run; the report derives each expected path from code.

## Task 8b-2

Implement §8.4.3 M2 convergence: two pointer passes and whole-group reduction (R-82), transactional
merge tail, three store primitives, two pointer-clearing rules, drain gating only step 2,
§6.6 row 8, and pre-landing signatures.

### Decisions the brief requires documenting

1. **Use concrete `[String: RuleSignature]` for pre-landing signatures.** `AnyHashable` would
   require fallible runtime casts; a third associated type would make the non-generic plan and
   all callers generic. Everything is one module, and the module already names pin-specific
   `PinnedTabScope`. Bookmark/pin paths leave this map empty.
2. **Run convergence before pointer updates.** This differs from the spec's interleaved order
   but reaches the same state with fewer writes. The proof in `mergePass` has three parts:
   anchor identity survives (anchor ≤ winner < every loser), anchor-subset cardinality is
   preserved, and final values dominate earlier writes. The second part requires an explicit
   input correction from review F1: compute anchors from pre-delete `anchorRows`, but write
   pointers only to post-delete `liveRows`. Otherwise two published members could collapse to
   one before an unpublished, unlanded third member receives its pointer, violating RR10-8.
   `anchorRows` defaults to `liveRows`; M2a's anchor-cardinality test covers the difference.
3. **Missing-row primitives return without writes and assert in DEBUG, rather than throwing.**
   Inputs came from the same transaction's projection and must exist. Throwing would repeatedly
   roll back the same page.
4. **Subtract this page's transfer targets before M2 step 2** (R-90), in the landing closure.
   At this task stage `transferTargets` necessarily returns empty because 8b-3 owns the new
   step case. Its exhaustive switch will force that task to implement the case; the subtraction
   is already connected.
5. **Use effective account content stamps** (R-94), solely through
   `effectiveAccountStamps(landed:rebaselined:table:identities:)`. R-90 removed the table argument,
   but R-94 restores it for unlanded cursor baselines and adds landed values. Do not restore the
   old baseline-only helper. `convergePass` still consumes its unchanged `[String: Date]` input.
6. **Add the rebaselined input layer** (R-97). Cursor bookkeeping follows landing, so reading the
   table alone misses this page's newer rebaseline (M-33(d)). Pass `output.plan.rebaselined` at
   the engine's landing call.
7. **Carry two per-unit stamps in `URLRuleEffectiveStamps` and batch `accountStamps`** (R-98).
   Before batch assembly, compute them for live identities ∪ landed identities ∪ transfer targets.
   The tail recomputes from identical pure inputs, so results agree. This task supplies the input;
   8b-3 consumes it for transfer.
8. **Permit empty batches end to end** (R-99). Task 6 already supplied the registration/engine
   guard. Here allow store batches with a merge tail even without ops, and remove landing's
   empty-step early return.
9. **The pre-pass rest set is an upper bound** (R-100). In the transaction, before convergence,
   subtract rows now pending local edit, soft-deleted, or absent. Never add identities or
   recompute the cursor-side seven predicates and page-tombstone predicate.
10. **Pass explicit `publishedIdentities`** (R-95), defined by cursor `server != nil`. A non-nil
    row `syncId` alone does not prove publication because M1 assigns it during claim.
11. **Implement §6.6 row 8 through the existing engine refresh hook.** Wrap it in
    `!ops.isEmpty || out.mergeChangedRouting`; no manager/coordinator change. Pointer-only writes
    do not refresh routing (M-7).

### Additional deviations

12. **Add `RuleSignature: Comparable` in an extension.** Sorted group keys avoid randomized
    dictionary traversal, following pin convergence. Compare path presence and value distinctly
    so different signatures never compare equal.
13. **Primitive bodies also take `inout URLRuleTableIndex`.** This implements inclusive addressing
    in one write block and matches existing upsert/delete/re-key bodies. They are internal,
    not private, for the same R-exec-2 reason.
14. **Define merge-tail and batch-outcome types in the sync access file.** Registration/batch
    protocol APIs depend on them, so storage should not own their definitions.
15. **Mark access/store batch results discardable.** Existing row-value tests need not change
    merely to consume a return value. The engine always consumes it.
16. **Assemble the hook in nonisolated `makeURLRuleMergeTail`.** Creating it inside main-actor
    landing would infer incompatible actor isolation. Captures are values and evaluation is pure.
17. **Landed identities include `.claim`.** Claimed rows receive account identity/rank this page
    and must qualify as pointer anchors. Exclusions remain delete and later 8b-3(β). This set
    differs from the landed-value map that supplies effective stamps.
18. **Do not declare `.transfer` yet.** It needs 8b-3's `RuleProjection`. The deferred-tombstone
    outcome and account-stamp batch inputs are already declared and passed through.
19. **One echo-round assertion changes from one apply to two.** An empty rule page now enters
    M2's transaction. Add assertions for zero landing ops and unchanged total refresh count 1.
    Bookmark/pin tests are unchanged.
20. **M2-d injects a re-key collision.** A wrong-identity soft-delete guard is structurally
    unreachable when lookup itself uses `syncId`; keep the guard for future addressing changes.
    The replacement still proves a throw rolls back columns already written by the tail hook.
21. **M-36 performs user writes through fake `applyEditorSave`,** matching store steps 4/9:
    compare content members, then write/flag/stamp only on actual change. Tests may not mutate
    rows directly. `beforeLandingTransaction` is fake-only.
22. **M-6 tests device-independent winner selection directly.** The brief's multi-round shared-server
    script also needs 8b-3 yielding. Here invert local ids, creation times, ordering, and insertion
    order across two devices and verify the same account identity survives.
23. **Defer the explicitly out-of-scope 8b-3 portions** of M-16b, M-17(i), and M-25(e).
    M-17 covers M2 only; M-16b requires yielding entirely.

### Fix round 1 — review F1 / F3 / F2; controller parked F4–F7

25. **F1, Important:** separate pre-delete anchor rows from post-delete write rows, as item 2 now
    describes. Update both comments and the three-part proof; add a pure-value probe.
26. **F3, Minor:** normalize millisecond-zero stamps to absence in effective-stamp layer 1 too.
    No-baseline target/rank stamps are zero (R-12), so a real `Date(1970)` must not reach transfer.
    Fall back independently per unit to layers 2/3; a new identity without a cursor remains absent.
27. **F2, Minor:** move `collapsed` / `mergeChangedRouting` after `createdRows` / `createdPins`,
    restoring the documentation that had attached to the wrong member.

### Fix round 2 — new Important finding on re-review

28. **Only the first pointer pass uses pre-delete anchors.** The first fix applied that domain
    to both passes, but the surviving-anchor proof holds only for convergence's current-signature
    grouping. Pass 2 groups by pre-landing signature when available: a loser deleted under K1
    could become K2's smallest identity and anchor a live row to a row just deleted in the same
    transaction. This is reachable because landed move/update rows retain their pre-pass rest state.
    Add `anchorsFrom` to the nested pass: first pass gets pre-delete `anchorRows`, second gets
    post-delete `liveRows`, matching the spec's `liveAfter`. Update both proofs. Add
    `testM2a_theSecondPassNeverAnchorsOnARowCollapsedThisPage`, with a control where `p` is still live.

### Validation scope

24. **No build**, under the 2026-09-18 amendment forbidding `xcodebuild`. The 33 new cases and
    implementation were reviewed line by line: referenced signatures checked, operation switches
    exhaustive, and four new pure helpers free of actor-isolated state. A branch-wide compilation
    check follows completion of all tasks.

## Task 8b-3

Implement M3 yielding at (α)/(β), transfer and `RuleProjection`, parked/yielded tombstones,
branch-(ii) bookkeeping, round-end 3b admission recheck, and deferred deletions (§8.4.4 / §8.4.6).

### Deviations and implementation decisions

1. **Source-row recheck is not literal equality of six fields** (R-102 / ruling 11). The source
   comes from a baseline-stamped projection: unchanged units retain baseline stamps even when
   their row stamp is nil. Literal stamp equality would permanently park M-12(i)'s target-only
   edit. Instead require equality of host/path/ask/local target, plus both row edit stamps no
   newer than the projected stamps at millisecond precision. Actual Save changes a value;
   stamp comparison also catches A→B→A saves. Missing or soft-deleted rows fail. Production/fake
   share pure `transferSourceUnchanged(row:source:)`.
2. **Count transfer and transfer supersession in the landing transaction.** Ruling 6's literal
   row-stamp comparison misses M-34(b)'s same-page update and (c)'s effective account stamp.
   Both require `max(row stamp, effective account stamp)`, unavailable to the plan. Add batch
   `transferred` / `transferSupersededByDelete` and landing `transferred` / `supersededByDelete`,
   then merge into existing counters. `yield_no_partner` stays in the plan because the pre-pass
   has both of its inputs.
3. **The transfer body takes the shared table index and returns `URLRuleTransferResult`.** The
   index enforces one construction per write block (R-80 / 56); the result exposes content loss
   and target-bucket change. The public throwing helper still returns the number of written units.
   Production/fake share pure `transferDecision`.
4. **`partnerNotAtRest` is a protocol requirement with one extension implementation.** Reuse
   `mergePartners` for partner selection, then distinguish whether the group has a live partner.
   A soft-deleted partner cannot be at rest and must not cause unbounded parking. An at-rest
   identity can itself return true when another live member is not at rest; this is correct for
   a later unpublished edit. Publish-side `pendingApply != nil` restricts the actual guard.
5. **Transfers bypass per-identity coalescing slots.** They write another identity's row, so they
   cannot merge with X's landing write. Keep the upgrade/delete exclusivity assertion.
   Phase order is `upgrades + transfers + passthrough + deletes`.
6. **Add unreachable `.transfer: continue` to bookmark landing's exhaustive switch.** Bookmarks
   never yield tombstones to edits. Pin landing has no corresponding switch.
7. **Add fake editor retarget/delete entry points,** matching store steps 5/7/9 rather than direct
   row mutation. Fake landing receives outcome and α-source inputs. M-37 reuses the existing
   `beforeLandingTransaction` hook; no new injection knob.

### Validation scope

8. **No build**, under the 2026-09-18 amendment. Review signatures and all affected switches
   over step kinds, operations, and tombstone results, including production/fake landing and
   test summaries. The three new pure helpers access no actor-isolated state.

### Fix round 1 — two Important findings, tests only

9. **F1: add engine coverage for the R-84 guard.** The old module probe supplied
   `deferredDeletions` directly and bypassed both set construction and `diff.deferred` consumption.
   Add full-round suppression, an owner-shaped parking negative control, and local-change-round
   coverage through real engine entry points. Verify pending payload and four cursor fields
   survive unchanged, no X tombstone is committed, and rows remain unchanged. The owner-shaped
   control must publish its tombstone. The local-change case also detects substituting live-only
   reads for inclusive rows.
10. **F2: cover both rejected 3b rechecks.** Add missing server-id / zero-version variants with a
    purged owner, proving the earlier cause performs zero writes without revocation. Add a later-round
    hidden-owner case after conflicts, proving recheck still revokes and hard-deletes even with
    `pendingLocalEdit == false`. Add unresolved-owner zero-write coverage followed by mapping
    recovery and one resurrection. Extend existing M-12(ii) with applied-result checks: one
    resurrection, cleared deletion time, and both baselines restored; seed its server row for update.
11. **No production change.** The new probes exercise the existing guard/recheck paths without
    identifying an implementation defect. Leave F3–F8 Minor findings unchanged as directed.
12. **Clarification:** `.localOwnedChange` calls `push`, which first performs preflight pull, so
    planning still runs. Its behavioral assertion covers every round reaching publication;
    structural absence of a corresponding `OwnedPlanOutput` member proves the guard cannot
    accidentally read that set from the plan.

## Task 8b-4

Implement M4's two pending-edit clearing paths (R-79 / 91 / 96) and M5's per-row/per-field
editor dirty tracking (R-72).

### Decisions the brief requires documenting

1. **No change to the three optional draft units.** Task 5 already treats non-nil as present;
   insertion requires content and target or throws `noCandidateSurvived`, rolling back the batch.
   Leave the flat initializer and existing construction sites unchanged.
2. **Share row-side, millisecond-aware clearing projections.** Add `clearingProjection(of:)`
   and `clearingProjectionMatches(row:confirmed:)`. Both clearing paths and snapshot use the
   same projection. Do not truncate stored projection stamps; convert only during comparison.
3. **Add optional `RuleProjection.sortOrder` defaulting to nil.** Existing transfer construction
   stays valid, and transfer never reads rank. Clearing treats nil as unequal, so entity-derived
   projections cannot masquerade as confirmation baselines.
4. **Resolve targets in the kind before passing to storage.** Both clearing operands use local
   `targetSpaceId`; account `targetOwnerUuid` is empty and excluded. Storage still knows no account
   mappings. A nil confirmed target fails closed.
5. **Ruling 14 separates two layers:** the primitive receives identity -> projection entries
   (R-91); the registration closure receives an identity set (R-96) and resolves baselines from
   captured `state.publishBaseline`. Update §8.4.5 / appendix C-28 accordingly.
6. **Restore remotely deleted dirty rows with complete units and nil `syncId`** (R-101).
   The editor need not distinguish hard from soft deletion: Task 5's transactional step 2b
   decides (R-104). After Save, the row uses the newly minted store id. See C-36 / C-39.
7. **Task 12 records the dirty-bit-to-unit mapping** in §15's implementation errata.

### Departures from the brief

8. **Capture `publishResolver` alongside the snapshot baseline.** R-96 fixes the closure type
   to an identity set with no maps, but clearing needs `pendingLocalEditIdentities(resolve:)`.
   A missing captured resolver suppresses clearing for that round. Add no protocol channel.
9. **Capture access strongly in both closures,** matching every other registration closure.
   Weak captures would not eliminate a cycle and would create inconsistent lifetime behavior.
10. **Remove whole-bucket reorder pass 3.** Only the dragged row gets `.order`, and U-21 requires
    exactly one upsert. Sending every sibling would flag the entire bucket as edited and make
    all rows yield to remote deletion. Store densification already reindexes siblings without
    flagging them. Update Task 11's two reorder expectations to M5's single-dragged-row contract.
11. **Keep the now-unused `loaded` argument** in the specified signature. `dirty` answers whether
    the user touched a unit, and `stored` whether values differ. Removing the argument/state
    belongs to another change.
12. **Initially, dirty-field refresh tightening had no implementation to modify.** Task 11 only
    loaded on appearance; the sheet never refreshed afterward. Do not invent a new refresh path
    in this initial implementation. U-15d(3–5) still hold under no refresh, but §5.8 rule 3 is
    missing and must be recorded. Review fix F1 below completes it.
13. **U-15f/g drive remote deletion through the production landing batch, not `pullOnce()`.**
    Use delete/soft-delete operations through the same store body the engine uses, never direct
    field edits. These real-store cases need step 2b, but their suite has no real-store engine
    fixture; adding access + engine + fake client would require new unbuilt infrastructure.
14. **Do not add the editor cases' next-round commit-count assertions** for the same fixture
    reason. Merge tests M-7 / b / c / d / e and M-19 / x cover publication around both clearing paths.
15. **Group M-19 inputs by observable state.** Normalization fixed point, ask changed back, and
    zero-unit transfer all produce flagged rows with snapshot bytes equal to the baseline; cover
    them with one case and three rows. Inject failed clear for (d), separate (e)/(f), and include
    (g) in M-19x's four boundaries.
16. **Run M-20 against real storage.** Reuse merge-store fixtures to exercise each landing op,
    all three M2 writes, inbound hard delete, and editor soft delete, checking a false edit flag.
    Task 9 already covers both Space cascade origins.
17. **Reuse the client's existing commit gate for M-7b/d.** M-7e injects at the access layer's
    `beforeClearPendingLocalEditIfUnchanged`, the only layer that can inspect entries.
18. **Also modify `URLRuleKind.swift`, omitted from the brief's production files.** The two
    shared pure comparison helpers belong beside existing shared transfer predicates, avoiding
    duplicate logic across storage, engine, and registration. Existing members are unchanged.
19. **Fake clearing mirrors production through the same predicate.** Add call records for
    per-row clearing and conditional batch clearing, allowing assertions for one row write and
    no transaction on an empty set.

### Validation scope

20. **No build**, under the amendment; line-by-line review plus `swiftc -parse`. Verify all
    named symbols/argument order, optional-rank Equatable compatibility, registration member order,
    and main-actor access versus storage write-queue execution. No new switch is introduced.

### Fix round 1 — one Critical and three Important findings; five Minor findings left as directed

21. **F1: complete live field refresh while the sheet is open.** Task 11 assigned it to 8b-4,
    while this brief assumed Task 11 had done it.
    - Add published, privately set `SpaceManager.urlRulesRevision`, incremented whenever the
      cache changes: publisher updates, explicit reload, and unbind. Publishing the cached model
      array itself would miss in-place changes with unchanged object identity.
    - Observe the wrapped revision through `.onChange`; the private setter also hides the
      projected publisher. `@ObservedObject` triggers body recomputation. Avoid an initial
      callback before `.onAppear` loads rows.
    - Put merge logic in pure `refreshRows`, with a state-writing wrapper. Treat value/match type
      and ask/target as control groups: any dirty member protects the entire group. Preserve
      new rows and dirty missing rows; remove clean missing rows; append newly stored rows without
      dirty bits. Refresh loaded baselines only for clean units. Dirty state is read-only and is
      absent from the result type, so refresh cannot clear it.
    - Add a refresh token and materialized-row reconfiguration to the table coordinator. The
      existing unchanged-id early return hides content-only refreshes. Only this refresh path
      increments the token, avoiding reconfiguration on every keystroke. Configure existing rows
      without `reloadData`; add Row Equatable for change detection.
    - Known limitation: structural additions/removals still use the existing reload path and can
      lose field-editor focus during typing. That pre-existing behavior is outside this fix.
22. **F2: drive actual refresh in U-15d(3–5).** Assert dirty field and baseline preservation, and
    positive controls showing clean target/text groups update without generating edits. Add (6)
    for append, clean disappearance, and dirty disappearance.
23. **F3: test rank as a clearing unit.** Fake editor reorder updates/densifies order, flags only
    the dragged row, and changes no stamps. Add in-flight reorder, decision-to-write reorder,
    and no-reorder control cases. Removing optional rank or its required-value guard makes the
    first two fail.
24. **F4: fix five stale wildcard-host expectations.** Domain seeds without `*.` decode and encode
    as bare hosts. Correct the three review-named identity/restoration assertions plus the same
    defect in unresolved-target and unseen-row cases.
25. **No clearing logic changed in this review round.** F1 adds view refresh and a manager signal;
    F2–F4 change tests/fakes. Primitives, wiring, projection, and edit-set restoration are unchanged.
26. Leave F5–F9 Minor findings unchanged as directed.

### Fix round 2 — two Important findings in the editor

27. **R2-1: refresh could reappend a row the user just removed.** It remains in storage until Save,
    but was absent from the visible-row `seen` set. Pass `removed` into refresh and define seen
    as visible store ids ∪ removed store ids. Add a test preserving deletion while appending a
    genuinely new remote row, plus an empty-removed control reproducing the old behavior.
28. **R2-2: configuring every materialized cell disrupts the field editor.** Apply both fixes:
    - Return `changedIds` only for rows whose rendered units changed (match/text/ask/target),
      excluding metadata and structural additions/removals. Whole-row `changed` still governs
      state replacement; it intentionally differs from display changes.
    - Skip a cell holding the first responder, recognizing both a text field and the shared
      field editor whose delegate points to it. Dirty-group protection should already prevent
      content replacement, but this defense preserves insertion/selection and catches up later.
    Extend U-15d(3–6) with exact changed-id assertions.
29. Only editor code and its tests change; manager signaling, clearing primitives/wiring, and
    `computeEditSet` remain unchanged.

## Final compile check

Tasks 8b-1–8b-4 and their review fixes were written without compilation under the user's
instruction. At completion, run one branch-wide `xcodebuild build-for-testing` for scheme
`PhiBrowser`, macOS/arm64, with `CODE_SIGNING_ALLOWED=NO`.

The first build found **four errors and one new warning, all in tests**. All eight production
files compiled without errors/warnings: `URLRuleKind`, `SyncableOwnedItems`, `PhiSyncEngine`,
`PhiURLRuleLocalAccess`, `LocalStore+SpaceURLRule`, `PhiOwnedItemState`, `SpaceManager`, and
`SpaceURLRulesEditor`. Fixes change only types/scope, with no weakened assertions, deleted cases,
or production behavior changes.

| # | File:line | Symbol | Cause | Fix |
| - | --------- | ------ | ----- | --- |
| 1 | `Tests/…/Sync/Phi/URLRuleKindTests.swift:3299` | `RuleSnap.mergePartnerSyncId` | U-15f asserts a column absent from the older private snapshot type. | Add the optional member and initializer assignment. Equatable whole-row assertions now also cover this column. |
| 2 | `Tests/…/Sync/Phi/URLRuleMergeTests.swift:1165` | `seedSettled(_:id:…)` | Call argument order places `accountStamp` before `sortOrder`, unlike the declaration. | Swap argument order without changing values. |
| 3 | `Tests/…/Sync/Phi/URLRuleMergeTests.swift:1824` | `counters(_:)` | An earlier local `counters` value shadows the method. | Qualify the later call as `await self.counters(engine)`. |
| 4 | `Tests/…/Sync/Phi/URLRuleMergeTests.swift:2940` | `counters(_:)` | Same shadowing in M3-7's `second` value. | Same qualification. |

Remove the new warning in `LocalStoreURLRuleThrowingTests.swift:1559-1561`: three default
arguments reference main-actor-isolated `Self.t0` from outside isolation. Make this immutable
Sendable constant `private nonisolated static let`.

The rerun reports **TEST BUILD SUCCEEDED**, with no errors. Two remaining nullability warnings
come from unchanged `Sources/ChromiumBridge/ChromiumLauncher.h`. No behavior questions are
introduced by these compilation fixes.

## Task 6 placeholders (final pass)

Task 6 item 20 deferred rule-side marker-boundary placeholders to Task 12. Fill them in that
single test file, without production changes or removing/weakening existing assertions.

| CASE | Result | What it verifies |
| ---- | ------ | ---------------- |
| B2-1c(d) | Filled | Register rules and seed one unpublished eligible `r1`. A bookmark read failure leaves rule `local_read_failed == 0`, one rule commit, and `pushed >= 1`, while bookmark failure count is 1: R-exec-3 is per-kind. |
| B2-6b | Filled | Add rule version 9 and advance the page marker from 8 to 9. A bookmark-only engine creates no rule; the next engine with all three kinds lands one row in `s-1`, identity `r1`, with cursor `srv-r1`. |
| B2-13 | Filled | Put a rule on page 3 after unreadable settings on page 2. The row/cursor and one apply prove unusable settings do not truncate drain. Exactly two had-records loads occur per round, independent of page count; empty-batch landing adds writes, not loads. |
| B2-15 | Filled | Put a rule on final page 5, making its non-settings nature observable through one apply and cursor `srv-r5`. Preserve zero `clearEntityCursor` calls and update-branch assertions. |
| B2-16, rules | Filled | New same-page owner/rule test expects zero parked, one applied, the newly created local Space target, and no pending payload. Add defaulted `targetSpaceUuid` to the entity helper. |
| B2-3 / B2-7 / B2-7b | Already present | Task 6 supplied these named cases; unchanged here. |
| B2-17 rule-side consequences | Not filled | Only the file header mentions them; the case has neither a placeholder nor rule fixture, and item 20 did not list it. Round 2 has no new pages, while parked owned replay runs only in the page loop. Adding a page changes the script, so leave this for acceptance. |

Add `ruleCommits` filtering by `PhiSyncEntity.urlRuleEntityName`, following existing helpers.
Leave the equivalent inline filter unchanged.

Validation: **no build or test execution**, under this round's user instruction. Check all
referenced fixture signatures and argument order against source, then run single-file
`swiftc -parse` successfully. Remaining branch-build risk is type checking; expected behavior
is derived from the three engine entry paths.

## Task 12 (docs half)

This task changes no production or Swift code and runs no build, test, or app. T-M3-4a acceptance
and the Chromium `autoninja` run are outside scope and assigned to the user.

### Changes and locations

| Repository | File | Work |
| ---------- | ---- | ---- |
| Code | `docs/sync.md` | Add marker-boundary documentation after Pull before commit: page order, four store Bool results, defaults rollback, failure outcome/marker/publication behavior, conjunctive publish gating, budget/transport failure, marker-file migration and backup restore, and E-M3-4a-1. Verify URL Rules and add Space ownership/unresolved-target parking, soft-delete cleanup exits, and D30 merge/edit-wins behavior. List five new suites plus Chromium router tests, retaining compile-only guidance. |
| Code | `Sources/Sync/Phi/Proto/README.md` | Verify the generated-type inventory already includes the rule entity. |
| Code | `Sources/LocalStorage/Compatibility/README.md` | Verify the existing V11 statement. |
| Code | This file | Add this task's ledger section. |
| KB | `design/2026-09-16-m3-4a-url-rules-marker-boundary-design.md` §15 | Add writeback conventions, planning errata E-2a–2i, and execution errata E-3–25, deduplicating both ledgers and contract-changing rulings. Leave E-1 unchanged. §15 is authoritative; ledgers/rulings remain execution history. |
| KB | `design/2026-09-18-m3-4a-execution-rulings.md` | Create numbering/status, P1–P4 planning rulings, task decisions/arbitration, user instructions, deferred Minor findings, parallel-lane integration history, five remaining user/controller items, pending final-review/acceptance appendices, and related links. Acceptance status is explicitly pending as of 2026-09-18. |
| KB | `30-projects/phinomenon/sync-service/README.md` | Add M3-4a status, both implementation areas, process/scale, validation, five pending items, known limitations, and a rulings link. Advance milestone status from finalized spec to implementation complete with review/acceptance pending. |
| KB | `60-knowledge-items/guidelines/assign-every-spec-clause-to-exactly-one-task.md` | Draft the lesson from mutually deferring briefs: every spec clause needs one task owner; claims that another task implemented it require verification, with a blocker if false. |
| KB | `60-knowledge-items/pitfalls/compile-only-suites-hide-vacuous-assertions.md` | Draft the lesson from thousands of unexecuted cases across four milestones and five classes of vacuous assertions: each case needs a falsifiable note, and critical decisions need negative controls. |

### Source checks before §15 writeback

- Both partner queries take `tombstonesThisPage`.
- M1 candidates include arrivals and parked entities.
- Convergence precedes pointer updates; pass 1 uses pre-delete anchors, pass 2 post-delete rows.
- Transfer supersession is counted transactionally; source recheck requires four equal values
  and row stamps no newer at millisecond precision, not six-field literal equality.
- Manager revision signaling has three increment sites and the editor observes it.
- Only the dragged row receives `.order`.
- Drafts have three optional units and three compatibility forwarding accessors.
- Expired soft-row purge is ungated; exit-1 hard deletion requires successful cursor save.
- The isolated test manager initializer binds nothing and has no production caller.
- Clearing and transfer predicates share the existing rule-kind file.
- The five new test filenames in the branch diff match the verification documentation.

### Work assigned elsewhere

1. **User:** run Chromium `autoninja -C out/PhiRelease chrome unit_tests` and
   `unit_tests --gtest_filter='PhiURLRouter*'`, then commit Task 10's five Chromium changes using
   its report's message once validation passes.
2. **User:** run `LocalStoreURLRuleThrowingTests` alone on a machine without Phi running to verify
   U-24's currently unmeasured main-context visibility assumption.
3. **User:** complete two-device T-M3-4a acceptance (24 checks, five prerequisites, and both
   steady-state counter tables), then record results in §15 and rulings appendices A/B.
   Current status is `pending — acceptance not yet run (2026-09-18)`.
4. **User:** synchronize the KB with origin. This historical task committed locally only under
   its dispatch constraint, without pull/rebase/upload, so its checkout could be stale.
5. **Controller:** complete branch review over `c9ab5806..e24be36a`, dispatched alongside this
   task, and record findings in appendix A. §15/README currently say final review pending.
6. **Acceptance decision:** B2-17's rule-side consequence assertion remains absent because it
   requires changing the no-new-page second round; recorded as E-M3-4a-24(1).

## Final review fix (I-1)

Fix the branch review's sole Important finding over `c9ab5806..e24be36a`; see
`.superpowers/sdd/2026-09-17-m3-4a-url-rules-marker-boundary-plan/final-review.md`.

1. **Finding:** the R-103 guard in `publishOwnedKind` reads round-global `cursorSaveFailures == 0`.
   When only bookmarks existed, per-kind and global behavior were indistinguishable. With three
   kinds, a bookmark push-side cursor failure suppresses pins/rules before snapshot, including
   clearing path (b) and 3b rechecks. §2.5 rule 6 forbids broadening R-exec-3 to global behavior;
   R-103 concerns one failed replay-arming attempt.
2. **Fix:** snapshot `failuresBeforeLoad` before loading and compare the counter afterward.
   Keep the lost-table guard and suppression after either failed arming write, so that kind
   still cannot publish/recreate its file. Leave the deliberately round-global
   `canPublishThisRound` predicate unchanged.
3. **Probes in the three-kind B2-1c family:**
   - (e) `testAPushSideCursorSaveFailureOfOneKindDoesNotSuppressTheLaterKinds`: fail the bookmark
     publish-table write, expect no bookmark commit but one pin/rule commit each, durable cursors,
     and a save-failed outcome. The initial write-index assumption was corrected below.
   - (f) `testAFailedLossReplayArmStillSkipsOnlyItsOwnKind`: seed bookmark had-records and fail
     marker clear at save 2, after page marker save 1. Bookmarks still do not publish, recreate
     the file, or arm the latch; pins/rules each commit once. This preserves 2b-L1's negative control.
4. **Existing expectations remain semantically unchanged.** Earlier multi-kind failures occur
   during landing or single-kind execution and remain governed by the round gate. Rule-side
   R-103 variants fail within their own load, producing a nonzero delta and remaining suppressed.
5. **Build:** `build-for-testing`; log at
   `.superpowers/sdd/2026-09-17-m3-4a-url-rules-marker-boundary-plan/final-build-4.log`.
6. **Re-review correction, test literals only:** empty pages do not write bookmark/pin landing
   tables because `landsEmptyBatch` is false. Only rules enter empty-page planning/landing.
   Change (e) to fail save 1 and expect one save, the publish early-return write; (f) expects
   zero saves because it returns before any table write. The probes still distinguish the fix.
7. **Correct CASE 2b-L1's save count to zero** for the same reason. Its intended assertion that
   publication does not recreate the file is unchanged.
