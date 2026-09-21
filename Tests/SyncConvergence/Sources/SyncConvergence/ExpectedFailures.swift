// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// The properties this gate knows are violated today, and the evidence that the
// violation is survivable.
//
// A gate that is always red gates nothing; a gate that deletes its failing
// property gates less than it claims. So nothing here is removed: the property
// still runs over the same generators, its counterexample is still printed, and
// the run still fails if ANY property outside this list fails.
//
// Every entry carries a WITNESS -- the minimal counterexample, hard-coded and
// re-evaluated on every run, whatever the seed. The randomized search may or
// may not hit the defect on a given seed, so the witness is what keeps the list
// from rotting: the day the rule is repaired the witness stops reproducing, the
// run prints UNEXPECTED PASS and fails until the entry is deleted.
//
// The list cannot distinguish a known violation from a NEW one in the same
// property, so each entry names exactly one property and the counterexample is
// printed in full on every run for a human to compare against the witness.

struct ExpectedFailure {
    /// Exactly the id `Report.check` is called with.
    var property: String
    var rootCause: String
    /// The ruling or decision this entry is waiting on.
    var waitsOn: String
    /// True while the hard-coded counterexample STILL violates the rule.
    var witness: () -> Bool
}

// MARK: - The witnesses

/// The minimal shape behind the rank-coherence root cause, as three replicas of
/// one bookmark. `a` and `c` name the SAME location; `b` names a different one
/// whose stamp beats `a`'s and loses to `c`'s. Folding `b` in between destroys
/// `a`'s rank before `a`'s location is ever recognised as `c`'s, so the two
/// fold orders disagree about rank.
func bookmarkRankCoherenceWitness() -> (Phi_PhiBookmarkEntity, Phi_PhiBookmarkEntity,
                                        Phi_PhiBookmarkEntity) {
    func make(_ space: String, _ locationStamp: Int64,
              _ rank: String, _ rankStamp: Int64) -> Phi_PhiBookmarkEntity {
        var entity = Phi_PhiBookmarkEntity()
        entity.bookmarkUuid = "11111111-1111-4111-8111-111111111111"
        entity.spaceUuid = settingValue(space, locationStamp)
        entity.parentUuid = settingValue("", locationStamp)
        entity.rank = settingValue(rank, rankStamp)
        entity.title = settingValue("t", 1)
        entity.url = settingValue("https://a.example/", 1)
        entity.secondaryURL = settingValue("", 1)
        entity.secondaryTitle = settingValue("", 1)
        entity.createdAtMs = 1
        return entity
    }
    return (make("space-a", 100, "z", 900),
            make("space-b", 200, "M", 100),
            make("space-a", 300, "V", 50))
}

/// The same shape for URL rules, where the coherence rule is target + rank
/// instead of location + rank. The content group is identical across the three
/// so only the target/rank rule is under test.
func ruleRankCoherenceWitness() -> (Phi_PhiURLRuleEntity, Phi_PhiURLRuleEntity,
                                    Phi_PhiURLRuleEntity) {
    func make(_ target: String, _ targetStamp: Int64,
              _ rank: String, _ rankStamp: Int64) -> Phi_PhiURLRuleEntity {
        var entity = Phi_PhiURLRuleEntity()
        entity.ruleUuid = "11111111-1111-4111-8111-111111111111"
        entity.host = settingValue("example.com", 1)
        entity.pathPrefix = settingValue("/a", 1)
        entity.ask = settingValue(bool: true, 1)
        entity.targetSpaceUuid = settingValue(target, targetStamp)
        entity.rank = settingValue(rank, rankStamp)
        entity.createdAtMs = 1
        return entity
    }
    return (make("space-a", 100, "z", 900),
            make("space-b", 200, "M", 100),
            make("space-a", 300, "V", 50))
}

/// The second registered shape, found by this gate's own normalisation
/// properties: two rules whose content group reads back IDENTICALLY, one of
/// which omits `path_prefix` altogether. `contentBallot` is built from the
/// READOUTS (`host.stringValue`, `pathPrefix.stringValue`, `ask.boolValue`) plus
/// the host carrier's stamp, so it cannot tell "absent" from "present and
/// empty": the two ballots are byte-identical, `lwwWinner` returns its left
/// argument, and the merge copies the whole group from whichever side came
/// first. `merge(a, b)` and `merge(b, a)` then differ in bytes.
///
/// This is the same structural hole `BookmarkKind.merge` closes for its location
/// ballot -- a ballot that does not cover everything the merge copies -- and the
/// difference is only in the oneof's presence, never in a value. It is
/// registered rather than fixed because the shape is NOT reachable from a Phi
/// publisher: phi_entity.proto declares `path_prefix` always emitted.
func ruleAbsentContentMemberWitness() -> (Phi_PhiURLRuleEntity, Phi_PhiURLRuleEntity) {
    var present = Phi_PhiURLRuleEntity()
    present.ruleUuid = "11111111-1111-4111-8111-111111111111"
    present.host = settingValue("example.com", 7)
    present.pathPrefix = settingValue("", 7)
    present.ask = settingValue(bool: false, 7)
    present.targetSpaceUuid = settingValue("space-a", 7)
    present.rank = settingValue("V", 7)
    present.createdAtMs = 1
    let absent = withoutField(present, number: 3) ?? present
    return (absent, present)
}

/// True while the two fold orders of the witness still disagree.
func foldOrdersDisagree<E: SwiftProtobuf.Message & Equatable>(
    _ trio: (E, E, E), _ merge: (E, E) -> E) -> Bool {
    strippingUnknown(merge(merge(trio.0, trio.1), trio.2))
        != strippingUnknown(merge(trio.0, merge(trio.1, trio.2)))
}

// MARK: - The list

private let rankCoherenceRootCause = """
    the "location winner supplies rank" coherence rule (A14 / R-M3-3-25, and R-M3-4a-40 for a \
    rule's target) is not associative: whether two positions AGREE -- so rank is merged by LWW -- \
    or DIFFER -- so rank comes from the position winner -- depends on which pair is folded first. \
    It is a designed rule, not a coding mistake, and replicas cannot diverge from it: see \
    simulation.*.rank-coherence-cannot-diverge-replicas below and the README, "RC3".
    """

let expectedFailures: [ExpectedFailure] = [
    ExpectedFailure(
        property: "bookmarks.associativity",
        rootCause: rankCoherenceRootCause,
        waitsOn: "the pending product decision on position/rank coherence (ruling C5 area). "
            + "Repairing the rule changes which rank a user sees after a cross-Space move, so it "
            + "is a product call, not a merge-layer fix.",
        witness: {
            foldOrdersDisagree(bookmarkRankCoherenceWitness()) {
                BookmarkKind.merge(local: $0, remote: $1)
            }
        }),
    ExpectedFailure(
        property: "urlrules.associativity",
        rootCause: rankCoherenceRootCause,
        waitsOn: "the same decision; §8.2 rule 4 ties a rule's rank to its target bucket exactly "
            + "as §4.3 ties a bookmark's rank to its location.",
        witness: {
            foldOrdersDisagree(ruleRankCoherenceWitness()) {
                URLRuleKind.merge(local: $0, remote: $1)
            }
        }),
    ExpectedFailure(
        property: "urlrules.absent-always-emitted-field.is-side-independent",
        rootCause: """
            `URLRuleKind.contentBallot` is built from the content group's READOUTS, so it cannot \
            tell an ABSENT `path_prefix` from one that is present and empty. The two ballots tie \
            byte for byte, `lwwWinner` returns its left argument, and the merge copies the whole \
            group from whichever side came first: merge(a,b) and merge(b,a) differ in the oneof's \
            presence, never in a value. It is the same structural hole BookmarkKind.merge closes \
            for its location ballot, and unlike that one it is NOT reachable from a Phi \
            publisher -- phi_entity.proto declares path_prefix always emitted, so only a \
            truncated, hand-written or foreign payload produces it.
            """,
        waitsOn: "a decision on whether §8.2's content group should resolve a tied ballot through "
            + "the shared winner over the members' own bytes, the way §4.3's location group now "
            + "does. Found by this harness; out of scope for the change that added the gate.",
        witness: {
            let pair = ruleAbsentContentMemberWitness()
            return strippingUnknown(URLRuleKind.merge(local: pair.0, remote: pair.1))
                != strippingUnknown(URLRuleKind.merge(local: pair.1, remote: pair.0))
        }),
]

// MARK: - Why a non-associative rule cannot split the account

/// Replay the witness through the schedules the REAL protocol permits.
///
/// Non-associativity is not divergence. Under the protocol every merge in the
/// account is sequenced through one shared value: the server keeps exactly one
/// CURRENT value per identity and no history, a commit carries `baseVersion` and
/// a mismatch is a CONFLICT that writes nothing, and a replica may only commit
/// after a completed pull. So no replica ever folds an independent tree and
/// compares it with another replica's: every value a replica computes is
/// `merge(its own value, an ancestor of the single server chain)`, and the chain
/// only ever extends. A replica at rest holds the newest server value; a replica
/// whose merge of that value differs from it is not at rest, and commits. The
/// fold order therefore decides WHICH legal outcome the chain lands on -- the
/// outcome of a race -- and never whether two devices agree on it.
///
/// This replays exactly that. Each of the three witness values starts on its own
/// replica, and every interleaving of (pull, commit) over the three replicas is
/// driven to quiescence. The assertion is convergence; the number of DISTINCT
/// converged values is reported, because that number being greater than one is
/// the user-visible cost of the rule and the reason the entries above exist.
private func replayOneIdentity<E: SwiftProtobuf.Message & Equatable>(
    _ values: [E], identity: String, schedule: [Int],
    merge: (E, E) -> E) -> (values: [E], quiesced: Bool) {
    let server = SimServer()
    var store = values
    var reconciled: [E?] = Array(repeating: nil, count: values.count)
    var base = [Int64](repeating: 0, count: values.count)
    var watermark = [Int64](repeating: 0, count: values.count)
    var drained = [Bool](repeating: false, count: values.count)

    func pull(_ index: Int) {
        for item in server.getUpdates(since: watermark[index]) {
            base[index] = item.row.version
            watermark[index] = item.row.version
            guard let payload = item.row.payload,
                  let remote = try? E(serializedBytes: payload) else { continue }
            store[index] = merge(store[index], remote)
            reconciled[index] = remote
        }
        drained[index] = true
    }

    func commit(_ index: Int) {
        guard drained[index], reconciled[index] != store[index],
              let payload = try? store[index].serializedData() else { return }
        switch server.commit(tag: identity, baseVersion: base[index], payload: payload,
                             deleted: false) {
        case .applied(let version):
            base[index] = version
            reconciled[index] = store[index]
        case .conflict:
            // Pull before commit: the one scoped retry needs another drained pull.
            drained[index] = false
        }
    }

    for index in schedule {
        pull(index)
        commit(index)
    }
    var rounds = 0
    while rounds < 50 {
        rounds += 1
        let before = server.version
        for index in values.indices {
            pull(index)
            commit(index)
            pull(index)
        }
        let pending = values.indices.contains { reconciled[$0] != store[$0] }
        if !pending && server.version == before { break }
    }
    return (store, rounds < 50)
}

/// Every interleaving in which three replicas each take two (pull, commit)
/// turns: 6!/(2!·2!·2!) = 90 schedules, which is enough to hit the CONFLICT
/// path, the losing replica's re-pull and every order of the three values.
private func twoTurnsEach() -> [[Int]] {
    var out: [[Int]] = []
    func walk(_ prefix: [Int], _ remaining: [Int]) {
        if remaining.allSatisfy({ $0 == 0 }) { out.append(prefix); return }
        for index in remaining.indices where remaining[index] > 0 {
            var next = remaining
            next[index] -= 1
            walk(prefix + [index], next)
        }
    }
    walk([], [2, 2, 2])
    return out
}

func checkRankCoherenceCannotDivergeReplicas(report: Report) {
    func probe<E: SwiftProtobuf.Message & Equatable>(
        _ name: String, _ trio: (E, E, E), _ merge: (E, E) -> E) {
        let converged = "simulation.\(name).rank-coherence-cannot-diverge-replicas"
        let quiesces = "simulation.\(name).rank-coherence-reaches-quiescence"
        var outcomes: Set<String> = []
        for schedule in twoTurnsEach() {
            let run = replayOneIdentity([trio.0, trio.1, trio.2], identity: "rc3-\(name)",
                                        schedule: schedule, merge: merge)
            let stripped = run.values.map { strippingUnknown($0) }
            report.check(converged, stripped.dropFirst().allSatisfy { $0 == stripped[0] }, """
                  schedule = \(schedule)
                  replica 0 = \(run.values[0].oneLine)
                  replica 1 = \(run.values[1].oneLine)
                  replica 2 = \(run.values[2].oneLine)
                """)
            report.check(quiesces, run.quiesced,
                         "schedule \(schedule) was still committing after 50 idle rounds: the "
                         + "replicas keep rewriting each other, which IS the way a "
                         + "non-associative rule could break an account")
            outcomes.insert(stripped[0].oneLine)
        }
        report.markPassed(converged)
        report.markPassed(quiesces)
        report.note("""
            simulation.\(name): the rank-coherence witness converges under all \
            \(twoTurnsEach().count) permitted schedules, onto \(outcomes.count) DISTINCT value(s) \
            depending on the schedule. More than one is the whole user-visible cost of the \
            non-associative rule: a race decides which legal outcome the single server chain \
            lands on, and every replica then agrees on it.
            """)
    }
    probe("bookmarks", bookmarkRankCoherenceWitness()) { BookmarkKind.merge(local: $0, remote: $1) }
    probe("urlrules", ruleRankCoherenceWitness()) { URLRuleKind.merge(local: $0, remote: $1) }
}
