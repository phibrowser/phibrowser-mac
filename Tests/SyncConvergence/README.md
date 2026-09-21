# Hostless convergence harness

From the repository root:

```sh
bash build-scripts/test-sync-convergence.sh
```

Exit status 0 means nothing unexpected happened **in either direction**: no
property failed that is not registered in `ExpectedFailures.swift`, and no
registered failure quietly started passing. A non-zero status prints each
offending property with a shrunk counterexample and the command that reproduces
it. See "Using this as a gate".

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

## Using this as a gate

Any change to a `merge`, a `stamp`, a tombstone decision or a landing decision
must run this and see **0**.

| Status | Meaning |
| --- | --- |
| `0` | No unexpected failure and no unexpected pass. |
| `1` | A property failed that is **not** on the expected-failure list. |
| `2` | Every asserted property held, but a **registered** failure no longer reproduces: the list is stale and must be pruned. |

The expected-failure list lives in
`Sources/SyncConvergence/ExpectedFailures.swift`. It exists because a gate that
is always red gates nothing, and deleting a failing property would gate less
than the harness claims. So a registered property still runs over the same
generators, and its counterexample is still printed in full on every run, green
or red, in its own `EXPECTED FAILURES` section. Each entry names one property,
its root cause, and the ruling or decision it waits on.

Each entry also carries a **witness**: the minimal counterexample, hard-coded
and re-evaluated on every run whatever the seed. The randomized search may or
may not hit a given defect on a given seed, so the witness — not the search — is
what keeps the list from rotting. The day the rule is repaired, the witness
stops reproducing and the run fails with status 2 until the entry is deleted.

What the list cannot do is tell a known violation apart from a **new** one in
the same property. That is why the counterexample is printed rather than
summarised: compare it with the entry's witness before dismissing it.

Registered today:

| Property | Root cause | Waits on |
| --- | --- | --- |
| `bookmarks.associativity` | RC3, the position/rank coherence rule | the pending product decision on rank coherence (ruling C5 area) |
| `urlrules.associativity` | RC3, same rule over target/rank | the same decision |
| `urlrules.absent-always-emitted-field.is-side-independent` | `URLRuleKind.contentBallot` is built from the group's READOUTS, so an absent `path_prefix` and a present empty one tie byte for byte; the merge then copies the whole group from whichever side came first. Not reachable from a Phi publisher — the schema declares the field always emitted | a decision on whether §8.2's content group should resolve a tied ballot through the shared winner over the members' own bytes, the way §4.3's location group now does |

## Layer 1 — algebraic properties of each merge

Randomized, with a seeded SplitMix64 (`SYNC_CONV_SEED`, default
`0x5D1B2E9F00C0FFEE`, printed on every run). Value pools are deliberately tiny,
so equal timestamps, equal bytes and equal locations are the common case rather
than the exception. Generators cover stamp 0, negative stamps, `Int64.max`,
empty strings, embedded NULs, illegal ranks, wrong oneof cases, unknown fields
in each message's reserved range, root-vs-descendant bookmark locations and all
three pin owner shapes. Counterexamples are shrunk on the protobuf wire (drop a
top-level field from every entity, re-parse, keep the reduction if the property
still fails), and both the minimal and the original case are printed.

**The algebraic laws run over WELL-FORMED payloads.** `merge(a, a) == a` is a
statement about a value a publisher can actually emit, so a payload the schema
forbids belongs to a different question — what the merge NORMALISES it to —
which has its own properties below. The generators are constrained to the legal
domain on exactly two points, both tied to a documented contract, and the
adversarial generators are kept, not deleted: they are what feeds the
normalisation properties.

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

### `created_at_ms`: the legal domain is non-negative

`[left, right].filter { $0 > 0 }.min() ?? 0` rewrites a non-positive
`created_at_ms` to 0, so `merge(a, a) != a` for a negative one. That is the
contract, not a defect, and the generators are constrained to the legal domain
accordingly. `phi_entity.proto` declares the field a plain proto3 `int64`
"merged with `min()`, not LWW", and a proto3 scalar with implicit presence
serializes nothing at 0: **0 is indistinguishable from an absent field on the
wire**, so 0 already *is* the encoding of "unset", and `?? 0` is the only value
a merge of two unset sides can produce. Admitting negatives to the `min()` would
be worse than losing them — the field's only consumer is determinism (it is
`getAllSpaces`'s and `bookmarksPublisher`'s last tiebreak), and a peer claiming
`Int64.min` would win the `min()` forever and pin an account's ordering to
garbage, which is the mirror of the "a peer claiming the year 2099 must not drag
the account's logical time" rule in docs/sync.md. The filter is a sanitiser, and
a sanitiser is pinned by its own property, not by weakening idempotence: see
`non-positive-created_at_ms-sanitises-to-unset` below, which asserts that a
non-positive value becomes 0, that the fold is side-independent over the whole
domain legal and not, and that a sanitised value neither wins nor drags a real
instant down. The same helper is shared with the outbound projection on purpose
(R4 / R-exec-16), so this is a rule about the wire, not only about `merge`.

### Merge units and always-emitted fields: well-formed by default

Two more shapes made `merge(a, a) != a`, and both are payloads
`phi_entity.proto` forbids. A merge unit whose members carry DIFFERENT stamps —
§4.3's bookmark location pair, §8.2 rule 1's host/path_prefix/ask content group —
is rewritten onto the unit's designated carrier; an always-emitted
`PhiSettingValue` field that is ABSENT is materialised as an empty submessage.
Both change the bytes with no change of meaning, and
`merge-settles-after-one-pass` already proved the rewrite happens once. The
schema is explicit on both counts ("always emitted, never omitted-when-empty";
one carrier per unit, never `max`, because two clients reading different
carriers would republish over each other forever), and every Phi publisher
assigns every member of a unit one stamp — `BookmarkKind.stamp` writes
`locationStamp` to both location members, `URLRuleKind.setContentStamp` writes
the host's to all three.

So the generators produce coherent units by default, and the adversarial
generators live on behind `malformed:` — they are exactly what the normalisation
properties consume. Nothing was deleted, and the malformed domain is asserted
harder than before: it used to be two `report.note` lines.

## Layer 1b — normalisation of payloads the schema forbids

Four laws, asserted for each malformed shape, on the principle that a merge that
is not idempotent on a forbidden payload must at least be a *normaliser*:

| Property | Statement |
| --- | --- |
| `settles-after-one-pass` | `m = merge(a,a)` implies `merge(m,m) == m` — one extra commit, not a republish loop |
| `is-deterministic` | the same payload normalises the same way after a wire round trip: the result depends on the bytes and on nothing else |
| `is-side-independent` | `merge(a,b) ~ merge(b,a)` against a well-formed peer of the same identity |
| `never-changes-a-value` | the entity's values are untouched; a normalisation may rewrite a stamp or materialise an empty submessage, never a value |

applied to `bookmarks.incoherent-location-unit`,
`urlrules.incoherent-content-group` and, for all four kinds,
`absent-always-emitted-field`. Two extra properties pin the carrier rule
verbatim — both location members and all three content members leave the merge
on the carrier's stamp, whatever the other member claimed — and non-vacuity
checks fail the run if a seed never actually produced the malformed shape.
`urlrules.absent-always-emitted-field.is-side-independent` is where this gate
found a new instance of the tied-ballot hazard; it is registered, see "Using
this as a gate".

## RC3 — a non-associative rule that cannot split an account

`bookmarks.associativity` and `urlrules.associativity` fail, and the cause is
one designed rule (A14 / R-M3-3-25, and R-M3-4a-40 for a rule's target): if two
entities agree on their position, rank is merged by LWW; if they disagree, rank
comes from the position winner, because a rank only means anything inside the
position it was minted in. Whether a given pair "agrees" therefore depends on
which pair is folded first, and three replicas can produce two different ranks.
The minimal shape: `a` and `c` name the same location, and `b` names a different
one whose stamp beats `a`'s and loses to `c`'s — folding `b` in between destroys
`a`'s rank before `a`'s location is ever recognised as `c`'s. (It needs a
stamp/value disagreement, which is why the `[equal stamps]` variants pass: with
one stamp everywhere the position order is a fixed total order on values, so
"beats `a` and loses to `c` while `a` and `c` are equal" is impossible.)

**Non-associativity here is not divergence, and the reason is the protocol, not
the merge.** Every merge in the account is sequenced through one shared value:
the server keeps exactly one *current* value per identity and no history, a
commit carries `baseVersion` and a mismatch is a CONFLICT that writes **nothing**
(never a partial apply), and a replica may only commit after a completed pull.
So no replica ever folds an independent tree and compares it with another's:
every value a replica computes is `merge(its own value, an ancestor of that one
chain)`, and the chain only extends. A replica at rest holds the newest server
value; a replica whose merge of that value differs from it is by definition not
at rest, and commits. Hence *at rest ⟹ all equal*, and the only way this rule
could break an account is a **livelock** — replicas rewriting each other
forever — not a split brain.

The livelock cannot happen either, and for a reason worth writing down: the
position unit is a *join*. `lwwWinner` is a max over a total order, merge never
invents a position that was not already in the system, and the set of positions
is finite, so along any chain the position ballot increases finitely often. The
"positions differ" branch — the only non-monotone step, since it can replace a
rank with one carrying a lower stamp — fires only when the position strictly
increases, so it fires finitely often. Once the position has stabilised, rank is
a plain LWW join, non-decreasing and bounded, and the chain reaches a fixed
point. Every other field is a join (`lwwWinner`) or a meet over a finite set
(`min` for `created_at_ms`, `min` of the nonzero for `source`).

That argument is asserted, not just written down.
`simulation.bookmarks.rank-coherence-cannot-diverge-replicas` and its URL-rule
twin start the three witness values on three replicas and drive **all 90
interleavings** in which each replica takes two (pull, commit) turns — enough to
exercise the CONFLICT path, the loser's re-pull, and every order of the three
values — against the same `SimServer` Layer 2 uses. Both assert convergence and
quiescence under every schedule, and both report the number of DISTINCT
converged values: **2**. That number is the whole user-visible cost of the rule.
A race decides which of two legal outcomes the single chain lands on, and every
replica then agrees on it. It is a product question (which rank should a user
see after a cross-Space move?), which is why the properties are registered
rather than repaired here.

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
going offline for 5–40 steps, and per-replica clock skew. A delete is issued at
most once per identity, so the edit-beats-delete expectation below stays
well defined. Pull and commit are
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
* the **rank-coherence replay**: the registered RC3 counterexample started on
  three replicas and driven through all 90 interleavings the protocol permits,
  asserting convergence and quiescence under every one. See "RC3" above — this
  is the evidence that the registered failure is survivable, and it is asserted
  like any other property rather than argued in prose;
* **edit beats delete (C4)**, in both directions and in one property: an
  identity whose delete no edit contradicted is gone from every replica and
  never resurrects, and an identity whose delete an edit beat is present on
  every replica. A summed non-vacuity check fails the run if the scheduler
  produced no delete-versus-edit race at all, so the property can never pass
  because nothing happened.

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
* `plan`'s parking, adoption (§6), and claim/collapse/transfer for URL rules.
  Delete-versus-edit **is** modelled now, through the production decisions:
  `SyncableOwnedItems.unpublishedEdits` decides direction (i) and
  `max(K.locationStamp, K.contentStamp) > deleteDecidedAtMs` decides direction
  (ii), both called from `Scenarios.swift` rather than reimplemented. What the
  flat model cannot carry is A9's other two conjuncts — a live parent and
  "outside a subtree a tombstone is removing this round" — and the transfer
  outcome, which needs a merge partner; those stay XCTest's job. The tree half
  of C4 is checked separately against the production planner
  (`checkAnEditedChildSurvivesItsFoldersDeletion`): an edited child yields while
  its folder dies, an arrival still naming the dead folder lifts to the Space
  root, and the lifted node satisfies the same reachability invariants.
* Space hide/purge and the 30-day retention lifecycle (Spaces and settings
  therefore have deletes switched off in the model);
* landing into local storage, dense-order projection and the routing refresh;
* `plannedOrder`, deliberately: its signature is in flux on this branch.

The rule-specific half of the yield path -- transfer to a quiescent merge
partner -- is still outside the model; it needs a local-row model (soft deletes,
`pendingLocalEdit`, merge partners) beside the entity model.

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
