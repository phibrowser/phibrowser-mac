// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

/// CASE 5b.4b: the only case exercising the production implementation.
/// Without it, green fakes leave production projection, ordering, and transaction
/// boundaries untested. AccountPhiPinnedTabAccess must accept store/defaults in init:
/// accepting Account instead reaches lazy account.localStorage in the real user
/// directory, leaving no seam for the temporary store this test requires.
@MainActor
final class PhiPinnedTabLocalAccessTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    // MARK: - ① Projection and ordering

    /// allPins preserves inserted count and (ownerKey, index, guid) order, excluding
    /// dormant rows. Ordering determines commit sequence and index projection, so it
    /// is a contract. Fake-only assertions would miss production's default SwiftData
    /// fetch order, which can cause two commits every round and devices oscillating in pin order.
    func testProductionAccessProjectsInOwnerIndexGuidOrderAndDropsDormantRows() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        // Default local scope is Profile, so ownerKey is profileId: Default precedes Work.
        try insertPin(in: store, guid: "p-b", lineageId: "L-B", profileId: "Default", index: 1)
        try insertPin(in: store, guid: "p-a", lineageId: "L-A", profileId: "Default", index: 0)
        try insertPin(in: store, guid: "p-w", lineageId: "L-W", profileId: "Work", index: 0)
        try insertPin(in: store, guid: "p-d", lineageId: "L-D", profileId: "Default", index: 2,
                      configure: { $0.isPinnedTabDormant = true })

        let rows = try access.allPins()

        XCTAssertEqual(rows.map(\.guid), ["p-a", "p-b", "p-w"])
        XCTAssertEqual(rows.map(\.index), [0, 1, 0])
        XCTAssertEqual(rows.map(\.profileId), ["Default", "Default", "Work"])
    }

    /// Projection preserves pinLineageId (P11), while isKnownLocalPin matches normalized
    /// lowercase wire lineage. Two of three local lineage sources are uppercase, from
    /// UUID().uuidString or guid fallback. Direct lowercase comparison would classify
    /// every local pin as absent and tombstone the entire batch.
    func testKnownLocalPinNormalisesBothSidesOfTheLineageComparison() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p1", lineageId: "ABC-UPPER", profileId: "Default")

        let rows = try access.allPins()

        XCTAssertEqual(rows.map(\.lineageId), ["ABC-UPPER"], "Project the column unchanged without lowercasing")
        XCTAssertTrue(access.isKnownLocalPin("abc-upper", ownerKey: "Default"),
                      "Normalized lowercase wire lineage must match")
        XCTAssertFalse(access.isKnownLocalPin("no-such-lineage", ownerKey: "Default"))
    }

    /// The diff domain uses the same fetch without scope filtering (R-exec-4). Backup
    /// rows outside the snapshot remain in that domain with their actual owners (R-exec-11).
    /// Not claiming a row for sync does not mean deleting it from the account; confusing
    /// these would make a scope transition tombstone all pins on every device.
    /// Return rows, not bare lineages: PinKind.identity(of:) must protect each backup's
    /// own identity, without shielding deleted same-lineage rows under other owners.
    func testIdentitiesKeepAnOutOfScopeBackupRowThatTheSnapshotDrops() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p-profile", lineageId: "l-profile", profileId: "Default")
        // With Profile scope, a Space-shaped row is outside this round's snapshot,
        // matching a physical backup retained after Space-to-Profile migration.
        try insertPin(in: store, guid: "p-space", lineageId: "l-space",
                      profileId: "Default", spaceId: "space-a")

        let snapshot = try access.allPins()
        let domain = try access.allPinRows()

        XCTAssertEqual(snapshot.map(\.guid), ["p-profile"], "Out-of-scope rows are absent from the snapshot")
        XCTAssertEqual(Set(domain.map(\.guid)), ["p-profile", "p-space"],
                       "They remain in the diff domain")
        let backup = try XCTUnwrap(domain.first { $0.guid == "p-space" })
        XCTAssertEqual(backup.spaceId, "space-a", "The actual owner protects only this row's own identity")
        XCTAssertEqual(backup.profileId, "Default")
    }

    /// isKnownLocalPin compares full (lineage, owner) identity (R-M3-3-15). Out-of-scope
    /// backups remain absent from this lookup while the diff domain is unchanged.
    /// One lineage under N owners is N account entities. A lineage-only lookup would
    /// find missing (L, Work) because (L, Default) remains, write a baseline for failed
    /// application, and park a legitimate Work deletion indefinitely. This matches
    /// the pin lost on Mac B, 2026-09-14.
    func testKnownLocalPinMatchesOnTheFullIdentityNotTheBareLineage() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        // The same lineage under two owners; default Profile scope uses profileId as owner.
        try insertPin(in: store, guid: "p-default", lineageId: "L-Shared", profileId: "Default")
        try insertPin(in: store, guid: "p-work", lineageId: "L-Shared", profileId: "Work")
        // Also include a same-lineage Space-shaped backup outside the active Profile scope.
        try insertPin(in: store, guid: "p-backup", lineageId: "L-Shared",
                      profileId: "Default", spaceId: "space-a")

        _ = try access.allPins()

        XCTAssertTrue(access.isKnownLocalPin("l-shared", ownerKey: "Default"))
        XCTAssertTrue(access.isKnownLocalPin("l-shared", ownerKey: "Work"))
        XCTAssertFalse(access.isKnownLocalPin("l-shared", ownerKey: "space-a"),
                       "Out-of-scope backups are excluded by the allPins contract")
        XCTAssertFalse(access.isKnownLocalPin("l-shared", ownerKey: nil),
                       "Without a resolved local owner, this local identity cannot exist")

        // Delete only the Work physical row, preserving Default and the backup.
        let context = try XCTUnwrap(store.getMainContext())
        context.delete(try XCTUnwrap(try row("p-work", in: store)))
        try context.save()
        _ = try access.allPins()

        XCTAssertFalse(access.isKnownLocalPin("l-shared", ownerKey: "Work"),
                       "A same-lineage row under another owner cannot hide this owner's missing row")
        XCTAssertTrue(access.isKnownLocalPin("l-shared", ownerKey: "Default"),
                      "The other owner's row remains present")
        XCTAssertEqual(Set(try access.allPinRows().map(\.guid)), ["p-default", "p-backup"],
                       "The diff still includes out-of-scope backups (R-exec-4), protecting complete identities")
    }

    /// Before a successful read this round, allPinRows throws and isKnownLocalPin
    /// returns false. An empty collection would mean every local pin disappeared in
    /// §4.7 and tombstone every cursor, the failure R-exec-4 prevents.
    func testIdentitiesThrowBeforeAnySuccessfulSnapshotThisRound() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p1", lineageId: "l1", profileId: "Default")

        var threw = false
        do { _ = try access.allPinRows() } catch { threw = true }

        XCTAssertTrue(threw, "Never return an empty collection that causes a full-batch tombstone publication")
    }

    // MARK: - ② Operations change persisted rows

    /// Read the store directly after apply to verify create/update/delete on physical
    /// rows, preserving create lineageId/source/createdDate. A default nil lineage
    /// would remint an unknown identity and republish the inbound pin as new next round.
    /// Defaulting source would erase the remote import origin.
    func testApplyLandsCreateUpdateAndDeleteOntoTheRealStore() async throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p-a", lineageId: "l-a", profileId: "Default",
                      index: 0, title: "A")
        try insertPin(in: store, guid: "p-gone", lineageId: "l-gone", profileId: "Default",
                      index: 1, title: "Gone")
        _ = try access.allPins()

        let born = Date(timeIntervalSince1970: 4_242)
        let created = PhiLocalPin.fixture(lineageId: "l-new",
                                          guid: "p-new",
                                          profileId: "Default",
                                          index: 0,
                                          title: "New",
                                          url: try XCTUnwrap(URL(string: "https://new.example")),
                                          source: TabSource.arc.rawValue,
                                          createdDate: born)
        try await access.apply(PinApplyBatch(unordered: [
            .create(created),
            .update(guid: "p-a", fields: PinFieldPatch(title: "Renamed")),
            .delete(guid: "p-gone"),
        ]))

        let landed = try XCTUnwrap(try row("p-new", in: store))
        XCTAssertEqual(landed.pinLineageId, "l-new", "Preserve the wire identity without minting a replacement")
        XCTAssertEqual(landed.source, TabSource.arc.rawValue)
        XCTAssertEqual(landed.createdDate, born)
        XCTAssertEqual(try row("p-a", in: store)?.title, "Renamed")
        XCTAssertNil(try row("p-gone", in: store))
    }

    /// Successful apply rereads before returning so §4.5 can verify application before
    /// writing baselines in the same round. Merely clearing the cache reports every
    /// lineage absent, causing the engine to treat all identities as dead mappings and tombstone them.
    func testApplyRebuildsTheSnapshotSoThePostLandingRecheckSeesTheNewRows() async throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p-a", lineageId: "l-a", profileId: "Default")
        _ = try access.allPins()

        try await access.apply(PinApplyBatch(unordered: [
            .create(PhiLocalPin.fixture(lineageId: "l-new", guid: "p-new", profileId: "Default",
                                        index: 1, title: "New")),
        ]))

        XCTAssertTrue(access.isKnownLocalPin("l-new", ownerKey: "Default"),
                      "Verification reads the rows after application")
        XCTAssertEqual(Set(try access.allPinRows().map(\.guid)), ["p-a", "p-new"])
    }

    // MARK: - ③ One transaction for the entire batch

    /// Failing a later op also rolls back earlier ops. Calling separate throwing APIs
    /// creates N transactions and permits partial success; the engine would record
    /// a baseline for partially applied operations, preventing later diff or snapshot repair.
    func testAFailingOpRollsBackTheWholeBatch() async throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p-a", lineageId: "l-a", profileId: "Default", title: "A")
        _ = try access.allPins()

        var thrown: Error?
        do {
            // Sorted order is create, update, delete; the final op cannot find its row.
            try await access.apply(PinApplyBatch(unordered: [
                .delete(guid: "no-such-guid"),
                .update(guid: "p-a", fields: PinFieldPatch(title: "Renamed")),
                .create(PhiLocalPin.fixture(lineageId: "l-new", guid: "p-new",
                                            profileId: "Default", index: 1)),
            ]))
        } catch {
            thrown = error
        }

        XCTAssertEqual(thrown as? LocalStoreWriteError, .rowNotFound)
        XCTAssertEqual(try row("p-a", in: store)?.title, "A", "The batch update also rolls back")
        XCTAssertNil(try row("p-new", in: store), "The batch create also rolls back")
    }

    // MARK: - accountScope()

    /// Missing or unknown account scope returns nil, never Profile fallback. Fallback
    /// would invent an account value where none was published, falsely trigger §7.3
    /// mismatch on a Space-scoped machine, and stall the entire pin section.
    func testAccountScopeIsNilWhenTheMirrorKeyIsMissingOrUnrecognised() throws {
        let store = try makeStore()
        // Use a disposable suite: standard defaults are process-shared, polluting other
        // cases and leaving a key on the developer's machine.
        let suiteName = "PhiPinAccessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let access = AccountPhiPinnedTabAccess(store: store, defaults: defaults)

        XCTAssertNil(access.accountScope(), "Missing key")

        defaults.set("galaxy", forKey: "PhiPinnedTabScope")
        XCTAssertNil(access.accountScope(), "Unknown value")

        defaults.set(PinnedTabScope.space.rawValue, forKey: "PhiPinnedTabScope")
        XCTAssertEqual(access.accountScope(), .space)
    }

    // MARK: - Fixtures

    private func makeStore() throws -> LocalStore {
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
        context.insert(ProfileModel(profileId: "Work"))
        context.insert(SpaceModel(spaceId: "space-a", profileId: "Default", name: "A",
                                  colorHex: "#000000", iconName: "star", sortOrder: 0))
        try context.save()
        return store
    }

    /// Follow LocalStorePinnedTabTransferTests.insertPinned: insert a pinnedTab row
    /// directly into the main context, bypassing API normalization/reordering so tests control every field.
    @discardableResult
    private func insertPin(in store: LocalStore,
                           guid: String,
                           lineageId: String,
                           profileId: String,
                           spaceId: String? = nil,
                           index: Int = 0,
                           title: String = "T",
                           url: String = "https://pin.example",
                           configure: (TabDataModel) -> Void = { _ in }) throws -> TabDataModel {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProfileModel>())
                .first(where: { $0.profileId == profileId })
        )
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: index,
            url: try XCTUnwrap(URL(string: url)),
            favicon: nil,
            createdDate: Date(timeIntervalSince1970: 1_000),
            updatedDate: Date(timeIntervalSince1970: 1_000)
        )
        model.dataType = .pinnedTab
        model.profileId = profileId
        model.spaceId = spaceId
        model.pinLineageId = lineageId
        configure(model)
        context.insert(model)
        model.profile = profile
        try context.save()
        return model
    }

    private func row(_ guid: String, in store: LocalStore) throws -> TabDataModel? {
        let context = try XCTUnwrap(store.getMainContext())
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        return try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )).first
    }
}
