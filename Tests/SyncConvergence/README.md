# Hostless convergence harness

From the repository root:

```sh
bash build-scripts/test-sync-convergence.sh
```

Exit status 0 means every asserted property held. A non-zero status prints each
violated property with a shrunk counterexample and the command that reproduces
it.

```sh
SYNC_CONV_SEED=0xDEADBEEF bash build-scripts/test-sync-convergence.sh   # replay a seed
SYNC_CONV_ITERATIONS=5000 SYNC_CONV_STEPS=4000 bash build-scripts/...   # soak
SYNC_CONV_SKEW=0 bash build-scripts/test-sync-convergence.sh            # drop skew scenarios
SYNC_CONV_HLC=0 bash build-scripts/test-sync-convergence.sh             # pre-C2 wall-clock stamping
SYNC_CONV_SCRATCH=~/.cache/phi-sync-conv bash build-scripts/...         # keep the build cache
```

Requires the Xcode Swift toolchain and Python 3. It does **not** run
`xcodebuild`, launch Phi, load the Chromium framework, touch a user profile or
use the network. Like `Tests/SyncInvalidation`, it compiles selected production
sources into one temporary executable and runs it; the script removes every
artifact it created on exit.

## Why

The ~300 XCTest sync tests are compile-only in practice: a hosted XCTest bundle
launches a Phi host that collides with the developer's running Phi through
`ProcessSingleton` (docs/sync.md, "Verification"). Nothing therefore exercises
randomized multi-replica convergence. The merge layer is pure, so it can be
tested without a host at all.

## How the production code is compiled without the app

`Tests/SyncConvergence` is a small SwiftPM package with one executable target.

* **Merge core — symlinks, never copies.**
  `Sources/SyncConvergence/PhiSyncCore/*.swift` are relative symlinks to
  `Sources/Sync/Phi/{SyncableSettings,SyncableSpaces,BookmarkKind,PinKind,URLRuleKind,SyncableOwnedItems,PinnedTabScopeMirror,PhiHybridClock}.swift`,
  and `PhiSyncCore/Proto` is a symlink to `Sources/Sync/Phi/Proto/Generated`.
  The harness lives in the same target, so it sees these declarations at their
  production `internal` visibility: no `public` annotations, no `@testable`,
  and no change under `Sources/`.

* **Value types and constants — sliced at build time.**
  The merge core also names `PhiLocalBookmark`, `PhiOwnedItemTable`,
  `PhiSyncEntity`, `PinnedTabScope`, `LocalStore.normalizedRule`,
  `SpaceManager.isRoutableRuleTarget` and a handful of others. Each lives in a
  file whose other half drags in LocalStore, SwiftData, AppKit, ThemedColor,
  `AccountUserDefaults` or the logger, so the file cannot be compiled whole.
  `extract_production_slices.py` slices exactly those declarations out of
  `Sources/` into `PhiSyncCore/Slices/ProductionSlices.swift` at build time —
  the same technique `build-scripts/test-sync-invalidation.sh` uses to slice
  `refreshSpaceSyncGate` out of `PhiChromiumCoordinator.swift`. Static members
  of app objects (`SpaceManager`, `AgentSpaceManager`, `LocalStore`,
  `PhiPreferences`) are re-hosted in same-named enums; the member bodies are
  production text. A renamed or restructured declaration fails the extraction
  loudly rather than testing a stale copy, and the generated file is gitignored
  so no copy is ever committed.

* **SwiftProtobuf — the checkout Xcode already resolved.**
  The build script reads the revision `Phi.xcodeproj`'s `Package.resolved` pins
  (1.38.1 / `55d7a1cc`), finds a matching checkout — `$SWIFT_PROTOBUF_PATH`,
  then `Vendor/swift-protobuf`, then
  `~/Library/Developer/Xcode/DerivedData/Phi-*/SourcePackages/checkouts/swift-protobuf`
  — and symlinks it to `.deps/swift-protobuf`, which `Package.swift` declares as
  a local path dependency. Nothing is fetched, vendored or committed, and a
  revision mismatch is a warning naming the pinned revision.

## Layer 1 — algebraic properties of each merge

Randomized, with a seeded SplitMix64 (`SYNC_CONV_SEED`, default
`0x5D1B2E9F00C0FFEE`, printed on every run). Value pools are deliberately tiny,
so equal timestamps, equal bytes and equal locations are the common case rather
than the exception. Generators cover stamp 0, negative stamps, `Int64.max`,
empty strings, embedded NULs, illegal ranks, wrong oneof cases, unknown fields
in each message's reserved range, incoherent merge-unit member stamps,
root-vs-descendant bookmark locations and all three pin owner shapes.
Counterexamples are shrunk on the protobuf wire (drop a top-level field from
every entity, re-parse, keep the reduction if the property still fails), and
both the minimal and the original case are printed.

For settings, Spaces, bookmarks, pins and URL rules:

| Property | Statement |
| --- | --- |
| `idempotence` | `merge(a, a) == a` |
| `merge-settles-after-one-pass` | `m = merge(a,a)` implies `merge(m, m) == m` — tells a one-time normalisation apart from a republish loop |
| `commutativity` | `merge(a, b) ~ merge(b, a)` |
| `associativity` | all 6 orders of three replicas, left- and right-folded (12 results), agree |
| `unknown-fields-preserved-from-remote` | the reserved-range contract in `Proto/README.md` |
| `created_at_ms-survives-a-merge-with-itself` | the one non-LWW scalar all four entity kinds share |
| settings `unknown-registry-keys-survive` | the key union — settings' forward compatibility is unknown MAP KEYS, not reserved fields |

`~` is equality after clearing **the entity's own `unknownFields`, and nothing
else**. That exclusion is required rather than convenient: `SyncableSpaces`,
`BookmarkKind`, `PinKind` and `URLRuleKind` all start the merged message from
`remote` so a newer client's reserved fields survive (`Proto/README.md`,
"Reserved-field preservation is a contract"), so `merge(a,b)` always carries
b's unknown bytes and `merge(b,a)` always carries a's, by design. Preservation
is asserted as its own property, so excluding it from the comparison cannot
hide a regression.

Two further documented asymmetries are generated away rather than excluded,
because production refuses the disagreement instead of merging it:
`BookmarkKind.merge` takes `is_folder` from remote (a row cannot change between
bookmark and folder; `refuses` rejects `isFolderMismatch`) and `PinKind.merge`
leaves the owner oneof at remote's (the owner is half the pin's identity). A
same-identity trio therefore always shares `is_folder` and the owner. The same
reasoning fixes `bookmark_uuid` / `pin_uuid` / `rule_uuid` across a trio: merge
is a per-identity operation.

Also asserted: `SyncableSettings.lwwWinner` (the one shared winner, R4) obeys
the same three laws, and the fractional rank channel —

* `rankBetween(a, b)` is strictly between legal bounds and its output is
  `isLegalRank`, including 32 rounds of repeated subdivision of one interval;
* `isLegalRank` accepts every shape this file can produce and rejects empty,
  trailing-lowest-digit and out-of-alphabet ranks;
* `assignRanks` never hands `rankBetween` an unsafe bound — asserted through
  the production seam, the injectable `rankBetween` parameter that
  `SyncableOwnedItems` routes through its probe — assigns only legal ranks, and
  leaves the effective `(rank, identity)` order strictly increasing;
* `BookmarkKind.rankToIndex` is a dense permutation of `0..<n`.

Untrusted ranks are never fed to `rankBetween` directly: it has release-build
preconditions, so the harness respects the same decoding boundary the
production code does.

## Layer 2 — merge-level multi-replica simulation

N ≥ 3 in-memory replicas, one in-memory server, one seeded scheduler. Run for
settings, Spaces, bookmarks, pins and URL rules, plus clock-skew variants.

The server models the real one: one **current** value per client tag and no
history; one global monotonically increasing version; `Commit(baseVersion:)`
with a mismatch returning CONFLICT and writing nothing; `GetUpdates(since:)`
returning only the latest value of each entity past the watermark, so an
intermediate state is never delivered; tombstones delivered like entities and
never collected.

Replicas keep `store` (identity → entity), a tombstone set, a per-identity
`baseVersion`, a `reconciled` baseline and a GetUpdates watermark, and obey
pull-before-commit: a commit needs a completed pull, and a CONFLICT clears that
flag so the one scoped retry happens only after another drained pull
(docs/sync.md, "Pull before commit"). The commit response advances only that
entity's version, never the shared watermark — jumping the marker to it would
skip lower-versioned rows another replica wrote in between.

The scheduler interleaves: local edits of random fields, deletes, pulls,
commits, duplicate page delivery, dropped responses followed by retry, replicas
going offline for 5–40 steps, and per-replica clock skew. Pull and commit are
separate actions precisely so another replica can commit in between and the
CONFLICT path is really exercised. Edits stamp exactly the way the production
`stamp` functions do: a merge unit takes the edit time only when its value
changed, the bookmark location's two members share one stamp, the rule content
group's three members share the host's stamp, and a rule bucket change
restamps rank (§8.2 rule 4).

After a bounded quiescing loop the harness asserts:

* every replica holds the same identities with the same values;
* the loop actually reached quiescence — hitting the bound is a republish
  livelock even when the final states agree, so it is its own property;
* a deleted identity is gone from every replica and never resurrects.

Bookmark tree invariants are checked against the **production planner** rather
than a re-implementation: the converged set is fed to
`SyncableOwnedItems.plan(BookmarkKind.self, …)` with an `OwnerResolver` that
resolves the simulated Spaces, and the harness asserts that no identity on a
parent cycle is ever planned, that every planned node reaches a Space root
through planned ancestors, and that an acyclic set lands completely with
`refused == 0`. A hand-built two-cycle is the positive control, so the check
cannot pass vacuously.

## The clock (C2)

`PhiHybridClock` is symlinked in like the merge files, so Layer 1's clock
properties and Layer 2's replicas exercise the **production** formula, not a
copy. That is the reason the formula lives in a value type of its own rather
than inside `PhiSyncEngine`, which cannot build hostlessly.

Layer 1 asserts: strictly increasing stamps under a frozen wall clock, survival
of a backwards wall-clock jump, `observe(0)` as a no-op, `stamp()` never
producing 0, a one-year-future peer stamp exceeded by the next local stamp,
saturation at `Int64.max`, AM-1's `max(editWallMs, overwritten + 1)`, and
order-independence of observation.

Each Layer 2 replica owns a `PhiHybridClock`, observes every landed entity's
stamps on pull, and stamps **at edit time**, including while offline —
`SimStamper` routes every changed merge unit through the production
`PhiHybridClock.editStamp`. `SYNC_CONV_HLC=0` replays the plain wall-clock LWW
Phi shipped before C2 for comparison.

**Clock skew is a switchable scenario, not a green-washed one.** With replicas
6 h ahead and 90 min behind, convergence is asserted and holds, and the skew
scenarios are run **twice on the same seed** — `[skew,wall]` for the pre-C2
baseline and `[skew]` for the production clock — so one run prints the before
and the after.

The intent probe is split by what a clock can actually promise:

* **causal** — the last true-time edit was made by a replica that had already
  observed the stamp of every earlier content edit. AM-1 then stamps it strictly
  above all of them, so it *must* win. This is **asserted** under the hybrid
  clock (`simulation.<name>.a-causally-later-edit-wins`), not reported.
* **concurrent** — the last true-time edit was made without having seen a
  competing edit. LWW has to pick one, and under skew it can pick the earlier
  one by true time. Ordering concurrent writes by true time is what LWW gives up
  by definition; no logical clock restores it, so these stay reported.

Typical default-seed run: `[skew,wall]` loses 4 of 7 bookmarks (4 causal), 3 of
6 rules (2 causal) and the settings entity; `[skew]` loses 1 of 7 bookmarks,
0 of 6 rules and the settings entity — **0 causal everywhere**. The residue is
concurrent by construction.

## What Layer 2 does not cover

The simulation is at the merge level. `PhiSyncEngine` is an actor wired to
LocalStore, `UserDefaults`, the key manager, the marker file and the Chromium
bridge, none of which builds hostlessly, so the following are **not** modelled
and remain the XCTest suites' job:

* pagination, the page budget, and the per-page marker boundary
  (`marker_advanced`, `cursor_save_failed`);
* encryption, client-tag validation and the unreadable-payload paths;
* `plan`'s parking, adoption (§6), claim/collapse/yield for URL rules, and A9's
  "a newer inbound location cancels a local deletion" — the model treats a
  local delete as terminal, which is `plan`'s default for bookmarks and pins
  (`supersededByDelete`) but not the rule kind's yield behaviour;
* Space hide/purge and the 30-day retention lifecycle (Spaces and settings
  therefore have deletes switched off in the model);
* landing into local storage, dense-order projection and the routing refresh;
* `plannedOrder`, deliberately: its signature is in flux on this branch.

Adding the rule yield path and A9 to the scheduler is the obvious next step; it
needs a local-row model (soft deletes, `pendingLocalEdit`, merge partners)
beside the entity model.

## Limitations

* The value pools are small by design. They find tie-path bugs quickly but will
  not find a bug that needs a specific long string.
* Shrinking only removes whole top-level fields; it never shrinks a stamp or a
  string, so a minimal case can still carry an uninteresting value.
* `Phi_PhiSettingEntity.values` is a protobuf map, whose serialization order is
  not stable, so the simulation compares entities rather than bytes.
* The harness asserts the merge laws. Whether a violated law is reachable
  through `PhiSyncEngine` is a separate question, answered per finding in the
  failure output rather than by the harness.
