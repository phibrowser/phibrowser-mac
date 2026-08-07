// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The slot snapshot's windowMap used to be a record of live controllers only.
/// A lazy reopen breaks that equation: a parked ghost's Space stays on the
/// strip while its window exists only in the session file, and the snapshot is
/// the ONE record mapping that window back to its Space. `persistSlotsSnapshot`
/// therefore writes the live map plus the slot's still-parked ghosts — and
/// each ghost entry must also leave on its own once it stops describing a
/// parked window, or the snapshot would resurrect windows forever.
///
/// These pin the per-slot map it writes and the encode/decode pair the entry
/// round-trips through. What they cannot reach — that `persistSlotsSnapshot`
/// feeds these functions its real state, scoped to the right slot — rests on
/// the comments at the call site, the same line `SlotsSnapshotPersistGateTests`
/// draws.
final class SlotSnapshotGhostPreservationTests: XCTestCase {
    // MARK: - What the persisted map holds

    func testNoParkedGhostsWritesTheLiveMapUnchanged() {
        // Load-bearing until the lazy-restore wiring lands, and the rollback
        // story afterwards: with nothing parked, the snapshot a reopen reads
        // is exactly the one written today.
        let live = [101: "space-a", 102: "space-b"]

        let persisted = SpaceManager.persistedWindowMap(
            liveWindowMap: live,
            parkedGhosts: [:],
            unclaimedWindowIds: [],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(persisted, live)
    }

    func testStillParkedGhostRidesAlongWithTheLiveMap() {
        // Window 55 was parked by the reopen and nothing has touched it since:
        // unclaimed, Space still in the store. Its entry is what the NEXT
        // reopen classifies from, so it must survive this persist cycle.
        let persisted = SpaceManager.persistedWindowMap(
            liveWindowMap: [101: "space-a"],
            parkedGhosts: [55: "space-b"],
            unclaimedWindowIds: [55],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(persisted, [101: "space-a", 55: "space-b"])
    }

    func testClaimedGhostRetiresFromThePersistedMap() {
        // The ghost materialized: its window came back and claimed its id, so
        // 55 is no longer unclaimed. The live controller map now speaks for
        // that window (under its current-run id); keeping the parked entry too
        // would hand the next reopen the same window twice.
        let persisted = SpaceManager.persistedWindowMap(
            liveWindowMap: [101: "space-a", 203: "space-b"],
            parkedGhosts: [55: "space-b"],
            unclaimedWindowIds: [],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(persisted, [101: "space-a", 203: "space-b"])
    }

    func testDeletedSpaceGhostRetiresFromThePersistedMap() {
        // The parked window's Space was deleted from the strip. An entry
        // naming a gone Space could never be classified back to a ghost (the
        // classifier fails eager on it), so persisting it would replay a
        // window the user explicitly deleted the Space of.
        let persisted = SpaceManager.persistedWindowMap(
            liveWindowMap: [101: "space-a"],
            parkedGhosts: [55: "space-b"],
            unclaimedWindowIds: [55],
            liveSpaceIds: ["space-a"]
        )

        XCTAssertEqual(persisted, [101: "space-a"])
    }

    func testLiveWindowWinsAnIdCollisionOutright() {
        // Current-run ids and parked previous-session ids never legitimately
        // collide — the id generator is monotonic across runs — so a
        // collision means the parked record is stale. The live window is the
        // one the user can see; its Space must be the one written.
        let persisted = SpaceManager.persistedWindowMap(
            liveWindowMap: [55: "space-a"],
            parkedGhosts: [55: "space-b"],
            unclaimedWindowIds: [55],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(persisted, [55: "space-a"])
    }

    // MARK: - The entry's plist round trip

    func testWindowMapRoundTripsThroughItsPersistedEncoding() {
        // Ghost and live entries write through the same encoder, so one
        // round trip covers the shape a lazy reopen depends on: what
        // `persistSlotsSnapshot` encodes is what `loadRestoreSnapshot`
        // decodes, ghosts included.
        let map = [7: "space-a", 55: "space-b"]

        XCTAssertEqual(
            SpaceManager.decodedWindowMap(SpaceManager.encodedWindowMap(map)),
            map
        )
    }

    func testDecodingToleratesForeignShapesTheWayTheLoaderAlwaysHas() {
        // A snapshot is user-writable state on disk; the reader has always
        // answered damage with "no windows" rather than a crash or a partial
        // guess it cannot label. Same for a key that no longer parses as an
        // id: that pair is dropped, the readable rest survives.
        XCTAssertEqual(SpaceManager.decodedWindowMap(nil), [:])
        XCTAssertEqual(SpaceManager.decodedWindowMap(["7": 12]), [:])
        XCTAssertEqual(SpaceManager.decodedWindowMap("not-a-map"), [:])
        XCTAssertEqual(
            SpaceManager.decodedWindowMap(["7": "space-a", "not-an-id": "space-b"]),
            [7: "space-a"]
        )
    }

    func testDecodingDropsKeysOutsideTheRangeAWindowIdCanHave() {
        // "Parses as an id" has to mean the range an id can actually have,
        // not merely "parses as an Int": a parked window's id reaches the
        // bridge through a trapping 32-bit conversion, so a wider key would
        // survive the decoder only to crash the first Space switch or Space
        // deletion that touched it. The readable rest of the same map still
        // survives, exactly as for an unparseable key.
        XCTAssertEqual(
            SpaceManager.decodedWindowMap([
                "7": "space-a",
                String(Int(Int32.max) + 1): "space-past-the-top",
                String(Int(Int32.min) - 1): "space-past-the-bottom",
            ]),
            [7: "space-a"]
        )
    }

    func testDecodingDropsKeysNoSavedWindowCouldBe() {
        // A SessionID is always positive. `0` and `-1` are the two ids the
        // claim path reserves for windows that re-created nothing saved, so a
        // snapshot naming one describes a window that cannot exist — and
        // parking it would strand its Space behind a claim nobody can answer.
        XCTAssertEqual(
            SpaceManager.decodedWindowMap([
                "0": "space-zero", "-1": "space-stand-in", "7": "space-a",
            ]),
            [7: "space-a"]
        )
    }
}
