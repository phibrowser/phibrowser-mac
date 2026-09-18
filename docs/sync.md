# Phi sync publishing

## Pull before commit

The `feature/phi-sync` branch has no invalidation channel. Every round that may
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

When M4 invalidation is integrated, skipping this prerequisite requires both a
healthy notification channel and successful catch-up, with no pending refresh,
invalidation, or conflict. Receiving SSE `ready` alone does not establish that
state. Disabled or lost notification delivery must restore pull-before-commit.

The engine owns the prerequisite inside its serialized round queue. Callers and
the transport must not independently decide whether a commit is safe to send.

## URL Rules

URL rules are the fifth entity kind (`phi-urlrule`) and the third owned-item
kind registered with the engine, under the label `urlrules`. The engine has no
rule-specific branch: the kind is data in the `ownedKinds` list, and the round
order is settings, Spaces, bookmarks, pinned tabs, URL rules — rules are always
the last kind on a page, so the "last kind landed but the marker not yet
written" restart window falls on them.

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
