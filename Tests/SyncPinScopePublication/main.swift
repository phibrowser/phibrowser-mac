import Foundation

/// One pin kind on one device: the access the round probes, the round state the registration owns, and
/// the engine fixture holding the durable cursor table.
@MainActor
final class Device {
    let access = FakePinAccess()
    let state = PinSyncRoundState()
    let recorder = Recorder()
    let engine: PublicationFixture
    var liveEntities: [String: Data] = [:]
    var maps = OwnedOwnerMaps(deadSpaceUuids: ["space-dead"])

    init(table: PhiOwnedItemTable) async {
        engine = PublicationFixture(recorder: recorder)
        await engine.seed(table, label: "pins")
    }

    var registration: OwnedKindRegistration {
        pinRegistration(state: state, access: access, recorder: recorder,
            snapshot: { [unowned self] in
                var out = OwnedSnapshotBytes()
                for (identity, bytes) in self.liveEntities {
                    out.entities[identity] = bytes
                    out.ownerUuids[identity] = "space-a"
                    out.minted[identity] = "guid-\(identity)"
                }
                return out
            },
            // The #176 dead-owner rule as `deadOwnerDeletions` applies it: derived from durable cursor
            // state, so a round that does not persist it recomputes it next time.
            diff: { table in
                var out = OwnedItemTombstoneResult(identities: [], cursorUpdates: [:])
                for (identity, cursor) in table.cursors.sorted(by: { $0.key < $1.key })
                    where cursor.ownerUuid == "space-dead" && !cursor.pendingDelete && cursor.deletedAtMs == nil {
                    var updated = cursor
                    updated.pendingDelete = true
                    updated.deleteDecidedAtMs = 5_000
                    out.identities.append(identity)
                    out.cursorUpdates[identity] = updated
                }
                return out
            })
    }

    /// The production `beginRound`: trigger the follower, then sample the generation, the rows, the
    /// scopes and the follower.
    func beginRound() async {
        try! pinBeginRound(state: state, access: access)()
        await engine.startRound()
    }

    func publish() async { await engine.publish(registration, maps: maps) }
}

/// A tombstone an earlier round queued (`pendingDelete`) and a published pin owned by a deleted Space.
func seededTable() -> PhiOwnedItemTable {
    var table = PhiOwnedItemTable()
    table.cursors["t-queued"] = PhiOwnedItemCursor(entityId: "e-queued", version: 3, reconciled: Data([1]),
                                                  server: Data([1]), ownerUuid: "space-a",
                                                  pendingDelete: true, deleteDecidedAtMs: 10)
    table.cursors["t-dead-owner"] = PhiOwnedItemCursor(entityId: "e-dead", version: 4, reconciled: Data([2]),
                                                       server: Data([2]), ownerUuid: "space-dead")
    return table
}

@main
struct PinScopePublicationTests {
    @MainActor
    static func main() async {
        await blockedRoundPublishesNothingThenNextRoundDoes()
        await commitFenceDropsTheCommit()
        await commitFenceKeepsEarlierSlices()
        await beginRoundSamplesInProductionOrder()
    }

    /// Review round 1 fixture gap: the round-start order. The follow request comes before the busy
    /// sample, so a job it starts blocks this round; the generation is read before the rows, so a
    /// migration committing between the two reads shows as a moved generation at the next probe.
    @MainActor
    static func beginRoundSamplesInProductionOrder() async {
        do {
            let device = await Device(table: PhiOwnedItemTable())
            device.access.followStartsJob = true
            await device.beginRound()
            precondition(device.access.reads == ["follow", "generation", "rows", "row", "key", "busy"],
                         "\(device.access.reads)")
            precondition(device.state.followerBusy && device.state.scopeBlocked,
                         "a job the round's own follow request started blocks the round")
            device.liveEntities["p-1"] = Data([7])
            await device.publish()
            precondition(device.recorder.commits.isEmpty, "the blocked round publishes nothing")
        }
        do {
            let device = await Device(table: PhiOwnedItemTable())
            device.access.duringAllPins = { [unowned device] in device.access.generation += 1 }
            await device.beginRound()
            precondition(device.state.generation == 0, "the generation is sampled before the rows")
            precondition(!device.state.scopeBlocked)
            device.state.rescan(device.access)
            precondition(device.state.scopeMovedMidRound && device.state.scopeBlocked,
                         "the migration between the two reads shows at the next probe")
        }
        print("PASS beginRound order: the follow request precedes the busy sample, and the generation precedes the rows")
    }

    @MainActor
    static func blockedRoundPublishesNothingThenNextRoundDoes() async {
        enum Blocker: CaseIterable { case rowDiffersFromKey, followerBusy, generationMoved, roundTrip }
        for blocker in Blocker.allCases {
            let device = await Device(table: seededTable())
            device.liveEntities = ["l-new": Data([7])]
            switch blocker {
            case .rowDiffersFromKey: device.access.key = .app
            case .followerBusy: device.access.followerBusy = true
            case .generationMoved, .roundTrip: break
            }
            await device.beginRound()
            switch blocker {
            case .generationMoved:
                device.access.row = .space          // A migration lands after the sample.
                device.access.key = .space
                device.access.generation += 1
            case .roundTrip:
                device.access.generation += 2       // X to Y to X: both values match the sample.
            case .rowDiffersFromKey, .followerBusy: break
            }
            await device.publish()

            let table = await device.engine.table("pins")
            let counters = await device.engine.counters("pins")
            let writes = await device.engine.tableWrites
            precondition(device.recorder.commits.isEmpty, "\(blocker): blocked round committed \(device.recorder.commits)")
            precondition(table == seededTable() && writes == 0,
                         "\(blocker): the queued tombstone and the dead-owner decision stay as durable state")
            precondition(counters.scopeMismatch, "\(blocker): blocked publication reports scope_mismatch")
            precondition(device.recorder.notedPublished.isEmpty && device.recorder.hardDeleted.isEmpty
                         && device.recorder.claimed.isEmpty)

            // The next round samples a consistent state and is not blocked: both deletions go out.
            device.access.key = device.access.row
            device.access.followerBusy = false
            await device.beginRound()
            await device.publish()
            let sent = device.recorder.commits.flatMap { $0 }
            let tombstones = Set(sent.filter(\.deleted).compactMap(\.entityId))
            precondition(tombstones == ["e-queued", "e-dead"],
                         "\(blocker): delayed, not lost: \(sent.map { ($0.entityId ?? "new", $0.deleted) })")
            precondition(sent.contains { !$0.deleted && $0.entityId == nil }, "\(blocker): the live create goes out too")
            let after = await device.engine.table("pins")
            for identity in ["t-queued", "t-dead-owner"] {
                precondition(after.cursors[identity]?.pendingDelete == false && after.cursors[identity]?.deletedAtMs != nil,
                             "\(blocker): \(identity) published")
            }
            precondition(after.cursors["l-new"]?.reconciled == Data([7]) && device.recorder.notedPublished == ["l-new"])
            precondition(device.recorder.hardDeleted == ["t-queued", "t-dead-owner"])
        }
        print("PASS publication blocked round: row != key, follower busy, generation moved and an X-Y-X round trip each publish no queued tombstone, no dead-owner deletion, no live entity and write no table; the next unblocked round publishes them all")
    }

    @MainActor
    static func commitFenceDropsTheCommit() async {
        enum Mover: CaseIterable { case migrationLands, followerStarts }
        for mover in Mover.allCases {
            let device = await Device(table: PhiOwnedItemTable())
            device.liveEntities = ["l-new": Data([7])]
            await device.beginRound()
            // The snapshot sees an unblocked round; the move lands during the domain-key read, after the
            // snapshot and before the submit.
            device.recorder.onDomainKeyRead[1] = {
                switch mover {
                case .migrationLands: device.access.generation += 1
                case .followerStarts: device.access.followerBusy = true
                }
            }
            await device.publish()
            precondition(device.recorder.domainKeyReads == 1, "the fence is reached past the snapshot")
            precondition(device.recorder.commits.isEmpty, "\(mover): the fence drops the commit")
            let table = await device.engine.table("pins")
            let counters = await device.engine.counters("pins")
            precondition(table.cursors["l-new"]?.reconciled == nil && table.cursors["l-new"]?.entityId ?? "" == "",
                         "\(mover): nothing is marked published")
            precondition(device.recorder.notedPublished.isEmpty && device.recorder.claimed.isEmpty)
            precondition(counters.scopeMismatch && counters.liveUnpublished == 1)

            device.recorder.onDomainKeyRead = [:]
            device.access.followerBusy = false
            await device.beginRound()
            await device.publish()
            let next = await device.engine.table("pins")
            precondition(device.recorder.commits.count == 1 && next.cursors["l-new"]?.reconciled == Data([7]),
                         "\(mover): the next round publishes it")
        }
        print("PASS publication commit fence: a generation move or a follower start between the snapshot and the submit drops the commit and marks nothing published; the next round sends it")
    }

    @MainActor
    static func commitFenceKeepsEarlierSlices() async {
        // Batches of two: [t-dead-owner, t-queued] go out first; the migration lands during the key read
        // for the live slice, which is dropped.
        let device = await Device(table: seededTable())
        device.liveEntities = ["l-new": Data([7])]
        await device.beginRound()
        device.recorder.onDomainKeyRead[1] = { device.access.generation += 1 }
        await device.publish()
        precondition(device.recorder.commits.count == 1 && device.recorder.commits[0].allSatisfy(\.deleted),
                     "only the slice before the move went out: \(device.recorder.commits)")
        let table = await device.engine.table("pins")
        precondition(table.cursors["t-queued"]?.deletedAtMs != nil && table.cursors["t-dead-owner"]?.deletedAtMs != nil,
                     "earlier slices keep their outcomes")
        precondition(table.cursors["l-new"]?.reconciled == nil && device.recorder.notedPublished.isEmpty
                     && device.recorder.claimed.isEmpty, "the dropped slice is not marked published")
        print("PASS publication commit fence: slices committed before the move keep their outcomes; the slice after it is dropped unpublished")
    }
}
