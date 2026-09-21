// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

@MainActor
final class LocalStorePinnedTabTransferTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        // This class runs real scope migrations, whose success path writes UserDefaults.standard.
        // In hosted tests, that is Phi's own preferences domain.
        clearPinnedTabScopeMirrorDefaults()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testSpaceTransferPreservesPersistedFieldsAndDeletesSourceAtomically() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        let createdDate = Date(timeIntervalSince1970: 100)
        let updatedDate = Date(timeIntervalSince1970: 200)
        let lastSeen = Date(timeIntervalSince1970: 300)
        try insertPinned(
            in: store,
            guid: "source-pin",
            profileId: "Default",
            spaceId: "space-a",
            title: "Source",
            url: "https://origin.example",
            createdDate: createdDate,
            updatedDate: updatedDate,
            configure: { model in
                model.favicon = Data([1, 2, 3])
                model.overrideTitle = "Override"
                model.isOpenned = true
                model.isCreatedByChromium = true
                model.needUpdateMetaData = true
                model.source = TabSource.arc.rawValue
                model.secondaryUrl = URL(string: "https://secondary.example")
                model.secondaryTitle = "Secondary"
                model.lastSeen = lastSeen
                model.pinLineageId = "source-lineage"
            }
        )

        let result = try await store.transferPinnedTab(
            guid: "source-pin",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let copied = try XCTUnwrap(store.getAllPinnedTabs(for: "Default", spaceId: "space-b").first)
        XCTAssertEqual(result.guidMapping["source-pin"], copied.guid)
        XCTAssertNotEqual(copied.guid, "source-pin")
        XCTAssertEqual(copied.title, "Source")
        XCTAssertEqual(copied.url.absoluteString, "https://origin.example")
        XCTAssertEqual(copied.favicon, Data([1, 2, 3]))
        XCTAssertEqual(copied.overrideTitle, "Override")
        XCTAssertTrue(copied.isOpenned)
        XCTAssertTrue(copied.isCreatedByChromium)
        XCTAssertTrue(copied.needUpdateMetaData)
        XCTAssertEqual(copied.source, TabSource.arc.rawValue)
        XCTAssertEqual(copied.secondaryUrl?.absoluteString, "https://secondary.example")
        XCTAssertEqual(copied.secondaryTitle, "Secondary")
        XCTAssertEqual(copied.createdDate, createdDate)
        XCTAssertEqual(copied.lastSeen, lastSeen)
        XCTAssertEqual(copied.pinLineageId, "source-lineage")
        XCTAssertEqual(copied.profileId, "Default")
        XCTAssertEqual(copied.spaceId, "space-b")
    }

    func testSpaceTransferMovesWholeSplitAndNormalizesPartnerGuids() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "left",
            profileId: "Default",
            spaceId: "space-a",
            title: "Left",
            url: "https://left.example",
            index: 0,
            configure: {
                $0.splitPartnerGuid = "right"
                $0.layout = SplitLayout.horizontal.rawValue
            }
        )
        try insertPinned(
            in: store,
            guid: "right",
            profileId: "Default",
            spaceId: "space-a",
            title: "Right",
            url: "https://right.example",
            index: 1,
            configure: { $0.layout = SplitLayout.horizontal.rawValue }
        )

        let result = try await store.transferPinnedTab(
            guid: "left",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(target.count, 2)
        XCTAssertEqual(target[0].guid, result.guidMapping["left"])
        XCTAssertEqual(target[1].guid, result.guidMapping["right"])
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
        XCTAssertEqual(target[0].layout, SplitLayout.horizontal.rawValue)
        XCTAssertEqual(target[1].layout, SplitLayout.horizontal.rawValue)
    }

    func testLivePartnerHintTransfersPairBeforePersistedLinksAreWritten() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "left",
            profileId: "Default",
            spaceId: "space-a",
            title: "Left",
            url: "https://left.example",
            index: 0
        )
        try insertPinned(
            in: store,
            guid: "right",
            profileId: "Default",
            spaceId: "space-a",
            title: "Right",
            url: "https://right.example",
            index: 1
        )

        let result = try await store.transferPinnedTab(
            guid: "left",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            partnerGuidHint: "right",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(target.count, 2)
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
    }

    func testSharedProfileOwnerReordersWithoutReplacingPhysicalGuid() async throws {
        let store = try makeStoreWithSpaces()
        for (index, guid) in ["a", "b", "c"].enumerated() {
            try insertPinned(
                in: store,
                guid: guid,
                profileId: "Default",
                spaceId: nil,
                title: guid.uppercased(),
                url: "https://\(guid).example",
                index: index
            )
        }

        let result = try await store.transferPinnedTab(
            guid: "a",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 2
        )
        drainMainQueue()

        XCTAssertEqual(result.guidMapping, ["a": "a"])
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").map(\.guid),
            ["b", "c", "a"]
        )

        let rawGapResult = try await store.transferPinnedTab(
            guid: "b",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 2,
            destinationIndexIncludesSourceUnit: true
        )
        drainMainQueue()

        XCTAssertEqual(rawGapResult.guidMapping, ["b": "b"])
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").map(\.guid),
            ["c", "b", "a"]
        )
    }

    func testNormalSplitCreationUsesTargetSpaceOwnerAndPersistsPair() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)

        let result = try await store.createPinnedTabsForCrossWindowDrop(
            [
                PinnedTabCreationInput(
                    tabId: 10,
                    title: "Left",
                    url: "https://left.example",
                    partnerTabId: 11,
                    layout: SplitLayout.horizontal.rawValue
                ),
                PinnedTabCreationInput(
                    tabId: 11,
                    title: "Right",
                    url: "https://right.example",
                    partnerTabId: 10,
                    layout: SplitLayout.horizontal.rawValue
                ),
            ],
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(
            target.map(\.guid),
            [try XCTUnwrap(result.guidByTabId[10]), try XCTUnwrap(result.guidByTabId[11])]
        )
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
        XCTAssertEqual(target[0].layout, SplitLayout.horizontal.rawValue)
        XCTAssertEqual(target[1].layout, SplitLayout.horizontal.rawValue)
    }

    // MARK: - Scope migration merge key (R-M3-3-16)

    // CASE 2b.1: contentSignature(for:) included title, URL, and favicon; mergeCandidates
    // merges same-lineage copies only when signatures match. D9 keeps favicons device-local,
    // so identical pins can legitimately have different favicon bytes. Including them lets the
    // same account scope change produce one row on A and two on B, permanently diverging pin counts.
    func testScopeMigrationMergesLineageAcrossDifferingFaviconBytes() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "p1",
            profileId: "Default",
            spaceId: "space-a",
            title: "Shared",
            url: "https://shared.example",
            configure: { model in
                model.pinLineageId = "L"
                model.favicon = Data([0x1])
            }
        )
        try insertPinned(
            in: store,
            guid: "p2",
            profileId: "Default",
            spaceId: "space-b",
            title: "Shared",
            url: "https://shared.example",
            configure: { model in
                model.pinLineageId = "L"
                model.favicon = nil
            }
        )

        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        drainMainQueue()

        let merged = store.getAllPinnedTabs(for: "Default").filter { $0.pinLineageId == "L" }
        XCTAssertEqual(merged.count, 1)
    }

    // CASE 5b.5: two-fixture regression for R-M3-3-16. Different favicons on two machines
    // must produce identical rows after the same scope migration. CASE 2b.1 only checks
    // merging variants on one machine, a necessary but insufficient condition. D9 makes
    // device-local favicon differences normal; including them in the merge key can permanently
    // diverge the machines' pin counts while each considers its own result correct.
    func testTwoDevicesWithDifferentFaviconBytesMigrateToIdenticalRows() async throws {
        // A has favicons everywhere; B has nil everywhere. Lineage, title, URL, and index match
        // exactly, so both machines must agree.
        let deviceA = try await makeMigrationFixtureStore(favicons: [Data([0x1]), Data([0x2])])
        let deviceB = try await makeMigrationFixtureStore(favicons: [nil, nil])

        for store in [deviceA, deviceB] {
            try await store.changePinnedTabScope(
                to: .profile,
                preferredProfileId: "Default",
                preferredSpaceId: "space-a"
            )
        }
        drainMainQueue()

        let rowsA = migratedRows(in: deviceA)
        let rowsB = migratedRows(in: deviceB)
        XCTAssertEqual(rowsA.count, rowsB.count, "Both machines must produce the same number of merged rows")
        XCTAssertEqual(rowsA.map(\.lineage), rowsB.map(\.lineage))
        XCTAssertEqual(rowsA.map(\.index), rowsB.map(\.index))
        XCTAssertEqual(rowsA.map(\.title), rowsB.map(\.title))
        XCTAssertEqual(rowsA.map(\.url), rowsB.map(\.url))
    }

    // MARK: - applyPinSyncBatchThrowing（Task 5b）

    // Store equivalent of CASE 5b.4b ③: the whole batch is one transaction; any failed op
    // rolls back earlier operations. Calling the five throwing APIs separately creates N
    // transactions and allows partial success, for which the engine would record a baseline (R-exec-2).
    func testAFailingOpRollsBackEveryEarlierOpInTheSameBatch() async throws {
        let store = try makeStoreWithSpaces()
        try insertPinned(in: store, guid: "p-a", profileId: "Default", spaceId: nil,
                         title: "A", url: "https://a.example", index: 0)

        await assertThrows(.rowNotFound) {
            try await store.applyPinSyncBatchThrowing([
                .update(guid: "p-a", fields: PinFieldPatch(title: "Renamed")),
                .delete(guid: "no-such-guid"),
            ])
        }

        let title = try pinRow("p-a", in: store)?.title
        XCTAssertEqual(title, "A", "Partial success is impossible")
    }

    // Normalize indexes once per touched owner at the end; pins group by owner, not parent.
    // A batch can touch one owner repeatedly, so per-op normalization only guarantees density
    // at that instant. Remaining gaps change the next rank-to-index projection and diverge devices' order.
    func testTheBatchLeavesEveryTouchedOwnerDenselyNumbered() async throws {
        let store = try makeStoreWithSpaces()
        for (index, guid) in ["p-0", "p-1", "p-2"].enumerated() {
            try insertPinned(in: store, guid: guid, profileId: "Default", spaceId: nil,
                             title: guid, url: "https://\(guid).example", index: index)
        }

        // Deleting the middle row leaves indexes 0 and 2; final normalization must close the gap.
        try await store.applyPinSyncBatchThrowing([.delete(guid: "p-1")])
        drainMainQueue()

        let remaining = store.getAllPinnedTabs(for: "Default")
            .sorted { ($0.index, $0.guid) < ($1.index, $1.guid) }
        XCTAssertEqual(remaining.map(\.guid), ["p-0", "p-2"])
        XCTAssertEqual(remaining.map(\.index), [0, 1], "The index gap is closed")
    }

    // An importing Space throws its dedicated case, not targetNotWritable, without any writes.
    // targetNotWritable means a deleted Space or changed Profile, a structural failure; import
    // is transient and parks for retry. Conflating them makes §11.2's parked count unable
    // to distinguish retryable parking from permanent failure.
    func testABatchTargetingAnImportingSpaceThrowsTheDedicatedCase() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(in: store, guid: "p-a", profileId: "Default", spaceId: "space-a",
                         title: "A", url: "https://a.example")
        ImportTargetLock.shared.begin(into: "space-a")
        defer { ImportTargetLock.shared.end(into: "space-a") }

        await assertThrows(.spaceImporting(spaceId: "space-a")) {
            try await store.applyPinSyncBatchThrowing([
                .update(guid: "p-a", fields: PinFieldPatch(title: "Renamed")),
            ])
        }

        let title = try pinRow("p-a", in: store)?.title
        XCTAssertEqual(title, "A", "No bytes are written while locked")
    }

    // The create operation carries source through to the physical row (Step 2).
    // PhiPinTabEntity field 8 is source, merged by PinKind.merge using the nonzero side.
    // Omitting it writes the default 0; the next snapshot republishes 0 and erases the remote import origin.
    func testCreateCarriesSourceAndLineageAndCreatedDateOntoTheRow() async throws {
        let store = try makeStoreWithSpaces()
        let born = Date(timeIntervalSince1970: 7_777)

        try await store.createPinnedTabThrowing(
            guid: "p-new",
            url: try XCTUnwrap(URL(string: "https://new.example")),
            title: "New",
            profileId: "Default",
            lineageId: "l-remote",
            createdDate: born,
            source: TabSource.safari.rawValue
        )
        drainMainQueue()

        let landed = try XCTUnwrap(try pinRow("p-new", in: store))
        XCTAssertEqual(landed.source, TabSource.safari.rawValue)
        XCTAssertEqual(landed.pinLineageId, "l-remote", "Preserve the wire identity without minting a replacement")
        XCTAssertEqual(landed.createdDate, born)
    }

    // A split patch writes both directions in one transaction (§7.4 / I11), resolving partners
    // by normalized lineage. reconcilePinnedSplitPartners only visits active SplitGroups,
    // which newly synced split pins lack. A one-way write would never repair its partner;
    // comparing lowercase wire lineage directly with uppercase local lineage always yields rowNotFound.
    func testASplitPartnerPatchLinksBothDirectionsThroughTheNormalisedLineage() async throws {
        let store = try makeStoreWithSpaces()
        try insertPinned(in: store, guid: "p-left", profileId: "Default", spaceId: nil,
                         title: "Left", url: "https://left.example", index: 0,
                         configure: { $0.pinLineageId = "L-LEFT" })
        try insertPinned(in: store, guid: "p-right", profileId: "Default", spaceId: nil,
                         title: "Right", url: "https://right.example", index: 1,
                         configure: { $0.pinLineageId = "L-RIGHT" })

        // The patch carries normalized lowercase wire lineage; the local column is uppercase.
        try await store.applyPinSyncBatchThrowing([
            .update(guid: "p-left", fields: PinFieldPatch(splitPartnerLineageId: "l-right")),
        ])
        drainMainQueue()

        XCTAssertEqual(try pinRow("p-left", in: store)?.splitPartnerGuid, "p-right")
        XCTAssertEqual(try pinRow("p-right", in: store)?.splitPartnerGuid, "p-left",
                       "The reverse link is written in the same transaction")
    }

    // I1: a half whose partner has not arrived still applies, with a nil local link (§7.4 rule 3).
    // Throwing rolls back the entire pin batch, prevents baselines, and replays it forever,
    // stalling pin sync even though partial arrival is normal. The engine records
    // pendingPartnerLineage on the cursor and repairs both directions when the partner arrives.
    func testAHalfWhoseSplitPartnerHasNotLandedStillLandsWithANilLink() async throws {
        let store = try makeStoreWithSpaces()
        try insertPinned(in: store, guid: "p-left", profileId: "Default", spaceId: nil,
                         title: "Left", url: "https://left.example", index: 0,
                         configure: { $0.pinLineageId = "L-LEFT" })

        // Round 1: only the left half arrives; its patch names the right half's lineage.
        try await store.applyPinSyncBatchThrowing([
            .update(guid: "p-left", fields: PinFieldPatch(title: "Renamed",
                                                          splitPartnerLineageId: "l-right")),
        ])
        drainMainQueue()

        XCTAssertNil(try pinRow("p-left", in: store)?.splitPartnerGuid, "The link remains nil")
        XCTAssertEqual(try pinRow("p-left", in: store)?.title, "Renamed",
                       "A missing partner does not roll back other operations in the batch")

        // Round 2: the partner arrives and both directions are repaired together.
        try await store.applyPinSyncBatchThrowing([
            .create(PhiLocalPin.fixture(lineageId: "l-right",
                                        guid: "p-right",
                                        profileId: "Default",
                                        index: 1,
                                        title: "Right",
                                        url: try XCTUnwrap(URL(string: "https://right.example")))),
            .update(guid: "p-left", fields: PinFieldPatch(splitPartnerLineageId: "l-right")),
        ])
        drainMainQueue()

        XCTAssertEqual(try pinRow("p-left", in: store)?.splitPartnerGuid, "p-right")
        XCTAssertEqual(try pinRow("p-right", in: store)?.splitPartnerGuid, "p-left")
    }

    // M4: a patch changing nothing throws instead of silently succeeding.
    // This was the only batch path where no error did not imply a write; that violates
    // §4.9 and lets the engine record a baseline for a write that never happened.
    func testAPatchThatChangesNothingThrowsInsteadOfSilentlySucceeding() async throws {
        let store = try makeStoreWithSpaces()
        try insertPinned(in: store, guid: "p-a", profileId: "Default", spaceId: nil,
                         title: "A", url: "https://a.example")

        await assertThrows(.noCandidateSurvived) {
            try await store.applyPinSyncBatchThrowing([
                .update(guid: "p-a", fields: PinFieldPatch()),
            ])
        }

        // Outer some with inner nil for URL means unchanged; a patch containing only this also changes nothing.
        await assertThrows(.noCandidateSurvived) {
            try await store.applyPinSyncBatchThrowing([
                .update(guid: "p-a", fields: PinFieldPatch(url: .some(nil))),
            ])
        }
    }

    // M6: deleting one half clears the survivor's reverse link in the same transaction.
    // The UI deletes split pins together, but §7.2 lets the engine delete just the remotely
    // unpinned half. A dangling partner guid makes migration signatures treat the survivor
    // as an ordinary pin and makes the merged UI cell try to render a nonexistent half.
    func testDeletingOneHalfOfASplitPairClearsTheSurvivorsLink() async throws {
        let store = try makeStoreWithSpaces()
        try insertPinned(in: store, guid: "p-left", profileId: "Default", spaceId: nil,
                         title: "Left", url: "https://left.example", index: 0,
                         configure: { $0.splitPartnerGuid = "p-right" })
        try insertPinned(in: store, guid: "p-right", profileId: "Default", spaceId: nil,
                         title: "Right", url: "https://right.example", index: 1,
                         configure: { $0.splitPartnerGuid = "p-left" })

        try await store.applyPinSyncBatchThrowing([.delete(guid: "p-left")])
        drainMainQueue()

        XCTAssertNil(try pinRow("p-left", in: store))
        XCTAssertNil(try pinRow("p-right", in: store)?.splitPartnerGuid,
                     "The surviving half no longer references a nonexistent row")
    }

    // M6, other half: clear the partner only when it points back to this row.
    // A stale one-way link may point to a pin already paired elsewhere; clearing that pin
    // would break another valid split pair.
    func testDeletingAHalfLeavesAPartnerThatPointsSomewhereElseAlone() async throws {
        let store = try makeStoreWithSpaces()
        try insertPinned(in: store, guid: "p-left", profileId: "Default", spaceId: nil,
                         title: "Left", url: "https://left.example", index: 0,
                         configure: { $0.splitPartnerGuid = "p-right" })
        // The right pin is now paired with p-other and no longer points back to p-left.
        try insertPinned(in: store, guid: "p-right", profileId: "Default", spaceId: nil,
                         title: "Right", url: "https://right.example", index: 1,
                         configure: { $0.splitPartnerGuid = "p-other" })
        try insertPinned(in: store, guid: "p-other", profileId: "Default", spaceId: nil,
                         title: "Other", url: "https://other.example", index: 2,
                         configure: { $0.splitPartnerGuid = "p-right" })

        try await store.applyPinSyncBatchThrowing([.delete(guid: "p-left")])
        drainMainQueue()

        XCTAssertEqual(try pinRow("p-right", in: store)?.splitPartnerGuid, "p-other",
                       "The other valid split pair is unaffected")
        XCTAssertEqual(try pinRow("p-other", in: store)?.splitPartnerGuid, "p-right")
    }

    // MARK: - updateActivePinnedTabThrowing / removeActivePinnedTabThrowing

    // CASE 2b.2: refusing a guid outside the current scope is intentional fail-closed behavior.
    // Sync must observe the refusal or it will record a baseline for a write that never happened.
    func testUpdateActivePinnedTabThrowingRejectsARowOutsideTheActiveScope() async throws {
        let store = try await makeStoreWithAnInactiveSpaceBPin()

        await assertThrows(.rowNotInActiveScope) {
            try await store.updateActivePinnedTabThrowing(
                guid: "space-b-pin",
                url: URL(string: "https://edited.example"),
                title: "Edited"
            )
        }
    }

    // CASE 2b.3: separate entry point from 2b.2; §4.9 requires one case for each ActivePinnedTab API.
    func testRemoveActivePinnedTabThrowingRejectsARowOutsideTheActiveScope() async throws {
        let store = try await makeStoreWithAnInactiveSpaceBPin()

        await assertThrows(.rowNotInActiveScope) {
            try await store.removeActivePinnedTabThrowing(guid: "space-b-pin")
        }
    }

    // CASE 2b.4
    func testRemoveActivePinnedTabThrowingThrowsWhenTheRowIsMissing() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)

        await assertThrows(.rowNotFound) {
            try await store.removeActivePinnedTabThrowing(guid: "no-such-guid")
        }
    }

    // A space-b pin becomes an out-of-scope backup after migration preferring space-a.
    // migratePinnedTabs retains source rows and creates new Profile-shaped physical rows,
    // so a UI action queued during the handoff can still arrive with the old guid.
    private func makeStoreWithAnInactiveSpaceBPin() async throws -> LocalStore {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "space-b-pin",
            profileId: "Default",
            spaceId: "space-b",
            title: "B",
            url: "https://b.example"
        )
        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        drainMainQueue()
        return store
    }

    private func assertThrows(_ expected: LocalStoreWriteError,
                              file: StaticString = #filePath,
                              line: UInt = #line,
                              _ block: () async throws -> Void) async {
        do {
            try await block()
            XCTFail("Expected \(expected) to be thrown.", file: file, line: line)
        } catch let error as LocalStoreWriteError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    /// One machine's fixture: Space scope, one pin in each of space-a and space-b with
    /// identical lineage, title, URL, and index; only favicon bytes differ.
    private func makeMigrationFixtureStore(favicons: [Data?]) async throws -> LocalStore {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        for (offset, spaceId) in ["space-a", "space-b"].enumerated() {
            try insertPinned(
                in: store,
                guid: "pin-\(spaceId)",
                profileId: "Default",
                spaceId: spaceId,
                title: "Shared",
                url: "https://shared.example",
                configure: { model in
                    model.pinLineageId = "shared-lineage"
                    model.favicon = favicons[offset]
                }
            )
        }
        return store
    }

    /// Read the migrated Profile collection ordered by (index, guid), comparing only identity
    /// and order fields: D9 explicitly permits different favicons across machines.
    private func migratedRows(in store: LocalStore)
        -> [(lineage: String, index: Int, title: String, url: String)] {
        store.getAllPinnedTabs(for: "Default")
            .sorted { ($0.index, $0.guid) < ($1.index, $1.guid) }
            .map { (lineage: $0.pinLineageId ?? $0.guid,
                    index: $0.index,
                    title: $0.title,
                    url: $0.url.absoluteString) }
    }

    private func pinRow(_ guid: String, in store: LocalStore) throws -> TabDataModel? {
        let context = try XCTUnwrap(store.getMainContext())
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        return try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )).first
    }

    private func makeStoreWithSpaces() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: "Default"))
        context.insert(SpaceModel(
            spaceId: "space-a",
            profileId: "Default",
            name: "A",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 0
        ))
        context.insert(SpaceModel(
            spaceId: "space-b",
            profileId: "Default",
            name: "B",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 1
        ))
        try context.save()
        return store
    }

    private func insertPinned(
        in store: LocalStore,
        guid: String,
        profileId: String,
        spaceId: String?,
        title: String,
        url: String,
        index: Int = 0,
        createdDate: Date = Date(),
        updatedDate: Date = Date(),
        configure: (TabDataModel) -> Void = { _ in }
    ) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProfileModel>()).first(where: {
                $0.profileId == profileId
            })
        )
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: index,
            url: try XCTUnwrap(URL(string: url)),
            favicon: nil,
            createdDate: createdDate,
            updatedDate: updatedDate
        )
        model.dataType = .pinnedTab
        model.profileId = profileId
        model.spaceId = spaceId
        model.pinLineageId = guid
        configure(model)
        context.insert(model)
        model.profile = profile
        try context.save()
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
