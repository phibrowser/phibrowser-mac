// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// Layer 2: N replicas, one in-memory server, a seeded scheduler.
//
// The simulation runs at the MERGE level. `PhiSyncEngine` is an actor with
// LocalStore / UserDefaults / key-manager dependencies that cannot be built
// hostlessly, so what is modelled here is the part the engine delegates: the
// per-identity merge, the commit/version protocol and the pull-before-commit
// discipline. What is deliberately NOT modelled is listed in the README.
//
// The server models the real one:
//   - one CURRENT value per client tag, never a history;
//   - one global, monotonically increasing version counter;
//   - Commit carries baseVersion; a mismatch is CONFLICT and writes nothing;
//   - GetUpdates(since:) returns only the latest value of each entity whose
//     version exceeds the watermark, so intermediate states are never delivered;
//   - tombstones are rows like any other and are never collected.

// MARK: - Server

final class SimServer {
    struct Row {
        var version: Int64
        var payload: Data?
        var deleted: Bool
    }

    enum CommitOutcome { case applied(Int64), conflict(Int64) }

    private(set) var rows: [String: Row] = [:]
    private(set) var version: Int64 = 0
    private(set) var commits = 0
    private(set) var conflicts = 0
    private(set) var tombstones = 0

    func commit(tag: String, baseVersion: Int64, payload: Data?, deleted: Bool) -> CommitOutcome {
        let current = rows[tag]?.version ?? 0
        guard current == baseVersion else {
            conflicts += 1
            return .conflict(current)
        }
        version += 1
        rows[tag] = Row(version: version, payload: payload, deleted: deleted)
        commits += 1
        if deleted { tombstones += 1 }
        return .applied(version)
    }

    func getUpdates(since watermark: Int64) -> [(tag: String, row: Row)] {
        rows.filter { $0.value.version > watermark }
            .map { (tag: $0.key, row: $0.value) }
            .sorted { $0.row.version < $1.row.version }
    }
}

// MARK: - Kind adapter

/// How one replica stamps one changed merge unit at one moment.
///
/// With `hlcMax` set this is the PRODUCTION rule, evaluated by the production
/// `PhiHybridClock.editStamp` (AM-1): the edit's own wall-clock time, raised one
/// above the stamp of the value it overwrites. With `hlcMax` nil it is the plain
/// millisecond LWW Phi shipped before C2, kept runnable so the two can be
/// compared on the same seed.
struct SimStamper {
    /// The replica's own, possibly skewed, wall clock at the moment of the edit.
    var editWallMs: Int64
    /// The replica's logical time (`PhiHybridClock.maxSeen`), or nil for
    /// pre-C2 behaviour.
    var hlcMax: Int64?

    /// `previous` is the stamp of the value being overwritten; nil for a create,
    /// which overwrote nothing and takes logical time as its floor.
    func stamp(overwriting previous: Int64?) -> Int64 {
        guard let hlcMax else { return editWallMs }
        return PhiHybridClock.editStamp(editWallMs: editWallMs,
                                        overwrittenStampMs: previous ?? hlcMax)
    }
}

struct SimKind<E: SwiftProtobuf.Message & Equatable> {
    var name: String
    /// Identity -> fresh entity.
    var create: (String, SimStamper, inout SplitMix64) -> E
    /// A user edit on this replica's clock. Mirrors the production `stamp`
    /// rules: a changed merge unit takes the edit stamp, everything else keeps
    /// the stamp it already had.
    var edit: (E, SimStamper, inout SplitMix64) -> E
    /// The content value used by the "later edit wins" intent probe.
    var content: (E) -> String
    /// The stamp on the merge unit `content` reads. The intent probe needs it to
    /// tell a CAUSAL edit (the author had already seen the value it overwrites,
    /// so the hybrid clock guarantees it wins) from a CONCURRENT one (it had
    /// not, and no clock can order the two by true time).
    var contentStamp: (E) -> Int64
    /// A content-only edit, for the intent probe.
    var setContent: (E, String, SimStamper) -> E
    /// Every LWW stamp the entity carries, folded into the replica's clock on
    /// pull exactly as `PhiSyncEngine` folds a landed entity's stamps.
    var stamps: (E) -> [Int64]
    var merge: (E, E) -> E
    var supportsDelete: Bool = true
}

// MARK: - Replica

final class SimReplica<E: SwiftProtobuf.Message & Equatable> {
    let id: Int
    var clockSkewMs: Int64 = 0
    var offlineUntil = 0
    /// The PRODUCTION hybrid logical clock, one per replica, observed on every
    /// pull and advanced by every local stamp -- the same object `PhiSyncEngine`
    /// keeps in `hlcMax`.
    var clock = PhiHybridClock()

    var store: [String: E] = [:]
    /// Identities this replica has deleted. A local delete is terminal here:
    /// a live arrival for a deleted identity is discarded, which is what
    /// `plan`'s `supersededByDelete` does for bookmarks and pins by default.
    var deleted: Set<String> = []
    var baseVersion: [String: Int64] = [:]
    var reconciled: [String: E] = [:]
    var deleteAcknowledged: Set<String> = []
    var watermark: Int64 = 0
    /// Pull-before-commit: set by a completed pull, cleared by a commit round.
    var drained = false

    init(id: Int) { self.id = id }

    func now(step: Int) -> Int64 { 1_700_000_000_000 + Int64(step) * 1_000 + clockSkewMs }

    /// The stamper for an edit made at `step`. Edits are stamped when they
    /// HAPPEN, including while this replica is offline; nothing here waits for
    /// the reconnect, which is the defect C2 removes.
    func stamper(step: Int, hybrid: Bool) -> SimStamper {
        SimStamper(editWallMs: now(step: step), hlcMax: hybrid ? clock.maxSeen : nil)
    }

    var hasPendingWork: Bool {
        for (identity, entity) in store where reconciled[identity] != entity { return true }
        return !deleted.subtracting(deleteAcknowledged).isEmpty
    }
}

// MARK: - Scenario result

struct SimOutcome {
    var converged = true
    var divergence: String?
    var rounds = 0
    /// False when the bounded quiescing loop ran out of rounds: the replicas
    /// were still rewriting each other's entities, which is a republish
    /// livelock even if the final states happen to agree.
    var quiesced = true
    var quiesceCommits = 0
    var commits = 0
    var conflicts = 0
    var duplicatePages = 0
    var droppedPages = 0
    var offlineEpisodes = 0
    var deletes = 0
    /// Identities whose converged content is NOT the latest edit by true wall
    /// clock, split by what a clock can actually promise.
    ///
    /// CAUSAL: the last true-time edit was made by a replica that had already
    /// observed the stamp of every earlier content edit, so the hybrid clock
    /// stamps it strictly above all of them and it MUST win. A causal loss is a
    /// real defect and is asserted away, not reported.
    ///
    /// CONCURRENT: the last true-time edit was made without having seen a
    /// competing edit. The two are concurrent, LWW has to pick one, and under
    /// skew it can pick the one that is earlier by true time. No logical clock
    /// fixes that -- ordering concurrent writes by true time is what LWW gives
    /// up by definition -- so these stay reported.
    var causalIntentLosses: [String] = []
    var concurrentIntentLosses: [String] = []
    var intentChecked = 0
    var intentLosses: [String] { causalIntentLosses + concurrentIntentLosses }
}

struct Simulation<E: SwiftProtobuf.Message & Equatable> {
    var kind: SimKind<E>
    var identities: [String]
    var replicaCount = 3
    var steps = 400
    var clockSkew: [Int64] = []
    /// Stamp through the production `PhiHybridClock`. False replays the plain
    /// wall-clock LWW that shipped before C2, for a same-seed comparison.
    var hybridClock = true

    func run(rng: inout SplitMix64, report: Report) -> SimOutcome {
        var outcome = SimOutcome()
        let server = SimServer()
        var replicas: [SimReplica<E>] = (0..<replicaCount).map { SimReplica<E>(id: $0) }
        for (index, replica) in replicas.enumerated() where index < clockSkew.count {
            replica.clockSkewMs = clockSkew[index]
        }

        // True wall-clock order of content edits, independent of any replica's
        // skewed clock. This is the "intent" the design wants LWW to honour.
        var lastContentEdit: [String: (step: Int, value: String, causal: Bool)] = [:]
        // Highest stamp any content edit has ever carried, per identity. An edit
        // whose replica already held a content stamp at least this high had seen
        // every competing edit, so AM-1 stamps it strictly above all of them.
        var highestContentStamp: [String: Int64] = [:]

        // Seed replica 0 with every identity so the run has something to merge.
        for identity in identities {
            let seed = kind.create(identity, replicas[0].stamper(step: 0, hybrid: hybridClock),
                                   &rng)
            replicas[0].store[identity] = seed
            for stamp in kind.stamps(seed) { replicas[0].clock.observe(stamp) }
            highestContentStamp[identity] = kind.contentStamp(seed)
        }

        func pull(_ replica: SimReplica<E>, duplicate: Bool) {
            let page = server.getUpdates(since: replica.watermark)
            let deliveries = duplicate ? 2 : 1
            for _ in 0..<deliveries {
                for item in page {
                    replica.baseVersion[item.tag] = item.row.version
                    if item.row.deleted {
                        replica.store.removeValue(forKey: item.tag)
                        replica.reconciled.removeValue(forKey: item.tag)
                        replica.deleted.insert(item.tag)
                        replica.deleteAcknowledged.insert(item.tag)
                        continue
                    }
                    guard let payload = item.row.payload,
                          let remote = try? E(serializedBytes: payload) else { continue }
                    // A tombstone this replica already holds is terminal.
                    guard !replica.deleted.contains(item.tag) else { continue }
                    // Fold every landed LWW stamp into logical time, the way
                    // `PhiSyncEngine.observeStamps` does at landing. Only the
                    // entity's `PhiSettingValue` stamps, never `created_at_ms`.
                    for stamp in kind.stamps(remote) { replica.clock.observe(stamp) }
                    let merged = replica.store[item.tag].map { kind.merge($0, remote) } ?? remote
                    replica.store[item.tag] = merged
                    replica.reconciled[item.tag] = remote
                }
            }
            replica.watermark = page.last?.row.version ?? replica.watermark
            replica.drained = true
            if duplicate { outcome.duplicatePages += 1 }
        }

        func commit(_ replica: SimReplica<E>) {
            guard replica.drained else { return }
            for identity in replica.deleted.subtracting(replica.deleteAcknowledged).sorted() {
                switch server.commit(tag: identity,
                                     baseVersion: replica.baseVersion[identity] ?? 0,
                                     payload: nil, deleted: true) {
                case .applied(let version):
                    replica.baseVersion[identity] = version
                    replica.deleteAcknowledged.insert(identity)
                case .conflict:
                    // One scoped retry needs another drained pull first.
                    replica.drained = false
                    return
                }
            }
            for identity in replica.store.keys.sorted() {
                guard let entity = replica.store[identity],
                      replica.reconciled[identity] != entity,
                      let payload = try? entity.serializedData() else { continue }
                switch server.commit(tag: identity,
                                     baseVersion: replica.baseVersion[identity] ?? 0,
                                     payload: payload, deleted: false) {
                case .applied(let version):
                    replica.baseVersion[identity] = version
                    replica.reconciled[identity] = entity
                    // The GetUpdates watermark is NOT advanced here. A commit
                    // returns the new version of ONE entity; jumping the shared
                    // progress marker to it would skip every lower-versioned row
                    // another replica wrote since this replica's last pull, and
                    // those rows' baseVersions would then never refresh --
                    // exactly the "commit versions and conflict detection remain
                    // necessary" case in docs/sync.md. The replica re-receives
                    // its own commit on the next pull, as it does in production.
                case .conflict:
                    replica.drained = false
                    return
                }
            }
        }

        for step in 0..<steps {
            let replica = replicas[rng.below(replicas.count)]
            if replica.offlineUntil > step { continue }

            switch rng.below(10) {
            case 0, 1, 2, 3:
                guard let identity = replica.store.keys.sorted().randomElement(using: &rng),
                      let current = replica.store[identity] else { break }
                let stamper = replica.stamper(step: step, hybrid: hybridClock)
                let edited = rng.chance(3)
                    ? kind.setContent(current, "c\(step)", stamper)
                    : kind.edit(current, stamper, &rng)
                replica.store[identity] = edited
                // A local stamp advances logical time exactly as `hlcNow()` does.
                for stamp in kind.stamps(edited) { replica.clock.observe(stamp) }
                // Record only an edit that actually CHANGED the content value,
                // keyed by the TRUE step and never by the replica's clock -- that
                // is the whole point of the probe. Recording every edit would log
                // the stale content a rank-only edit happened to be holding.
                if kind.content(edited) != kind.content(current) {
                    // Causal iff this replica's content unit already carried a
                    // stamp at least as high as every earlier content edit's: AM-1
                    // then stamps the new value above all of them.
                    let ceiling = highestContentStamp[identity] ?? Int64.min
                    lastContentEdit[identity] = (step: step, value: kind.content(edited),
                                                 causal: kind.contentStamp(current) >= ceiling)
                    highestContentStamp[identity] = max(ceiling, kind.contentStamp(edited))
                }
            case 4:
                guard kind.supportsDelete, rng.chance(20),
                      let identity = replica.store.keys.sorted().randomElement(using: &rng)
                else { break }
                replica.store.removeValue(forKey: identity)
                replica.reconciled.removeValue(forKey: identity)
                replica.deleted.insert(identity)
                lastContentEdit.removeValue(forKey: identity)
                highestContentStamp.removeValue(forKey: identity)
                outcome.deletes += 1
            case 5, 6:
                // Pull and commit are SEPARATE scheduler actions so another
                // replica can commit in between and the CONFLICT path is really
                // exercised; a pull immediately followed by its own commit could
                // never see a stale baseVersion.
                if rng.chance(8) {
                    // Dropped response: the page never arrives, the watermark
                    // does not move, and the same page is redelivered later.
                    outcome.droppedPages += 1
                    replica.drained = false
                    break
                }
                pull(replica, duplicate: rng.chance(6))
            case 7, 8:
                commit(replica)
            default:
                if rng.chance(3) {
                    replica.offlineUntil = step + rng.int(5...40)
                    outcome.offlineEpisodes += 1
                }
            }
        }

        // --- Quiesce ------------------------------------------------------------
        for replica in replicas { replica.offlineUntil = 0 }
        var round = 0
        let quiesceStartCommits = server.commits
        while round < 200 {
            round += 1
            let before = server.version
            var moved = false
            for replica in replicas {
                pull(replica, duplicate: false)
                commit(replica)
                pull(replica, duplicate: false)
            }
            for replica in replicas where replica.hasPendingWork { moved = true }
            if !moved && server.version == before { break }
        }
        outcome.rounds = round
        outcome.quiesced = round < 200
        outcome.quiesceCommits = server.commits - quiesceStartCommits
        outcome.commits = server.commits
        outcome.conflicts = server.conflicts

        // --- Convergence --------------------------------------------------------
        let reference = replicas[0]
        for replica in replicas.dropFirst() {
            let leftKeys = Set(reference.store.keys), rightKeys = Set(replica.store.keys)
            if leftKeys != rightKeys {
                outcome.converged = false
                outcome.divergence = "replica 0 holds \(leftKeys.sorted()); "
                    + "replica \(replica.id) holds \(rightKeys.sorted())"
                break
            }
            for identity in leftKeys.sorted() {
                guard let left = reference.store[identity], let right = replica.store[identity],
                      strippingUnknown(left) != strippingUnknown(right) else { continue }
                outcome.converged = false
                outcome.divergence = """
                    identity=\(identity)
                      replica 0 = \(left.oneLine)
                      replica \(replica.id) = \(right.oneLine)
                    """
                break
            }
            if !outcome.converged { break }
        }

        // Deleted identities stay deleted everywhere.
        let deletedEverywhere = replicas.reduce(into: Set<String>()) { $0.formUnion($1.deleted) }
        for identity in deletedEverywhere.sorted() {
            for replica in replicas where replica.store[identity] != nil {
                outcome.converged = false
                outcome.divergence = (outcome.divergence ?? "")
                    + "\n  resurrected tombstone \(identity) on replica \(replica.id)"
            }
        }

        // --- Intent probe -------------------------------------------------------
        // Causal losses are asserted by the caller; concurrent ones are reported.
        for (identity, edit) in lastContentEdit.sorted(by: { $0.key < $1.key }) {
            guard let converged = reference.store[identity] else { continue }
            outcome.intentChecked += 1
            guard kind.content(converged) != edit.value else { continue }
            let line = "\(identity): last wall-clock edit at step \(edit.step) wrote "
                + "'\(edit.value)', converged value is '\(kind.content(converged))'"
            if edit.causal {
                outcome.causalIntentLosses.append(line)
            } else {
                outcome.concurrentIntentLosses.append(line)
            }
        }
        return outcome
    }
}

private extension Array {
    func randomElement(using rng: inout SplitMix64) -> Element? {
        isEmpty ? nil : self[rng.below(count)]
    }
}
