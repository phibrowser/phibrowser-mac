// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

/// The store side of the pairing reset (docs/sync.md, "Replacing this Mac's data at pairing"):
/// the one-transaction owned-item wipe, the forced `default-space` recreation and `phiDataCounts`.
@MainActor
final class LocalStorePairingResetTests: XCTestCase {
    private var directory: URL?

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> LocalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStorePairingResetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        return LocalStore(account: Account(userID: "test-user"), storeDirectoryURL: url,
                          presentsCompatibilityAlerts: false)
    }

    private static let noAgentSpaces: (String, String, String) -> Bool = { _, _, _ in false }

    private func createSpace(_ spaceId: String, profileId: String = LocalStore.defaultProfileId,
                             in store: LocalStore) async throws {
        try await store.createSpaceThrowing(profileId: profileId, name: spaceId, colorHex: "#3A6FF8",
                                            iconName: "phi:a", spaceId: spaceId, createdDate: nil)
    }

    /// A bookmark folder with one bookmark under the Space's root, a pinned row in each state, and
    /// one live plus one soft-deleted URL rule.
    private func seedOwnedItems(spaceId: String, profileId: String = LocalStore.defaultProfileId,
                                in store: LocalStore) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let root = try XCTUnwrap(try store.bookmarkRoot(profileId: profileId, spaceId: spaceId,
                                                             in: context, createIfNeeded: true))
            let folder = Self.row("folder-\(spaceId)", type: .bookmarkFolder, profileId: profileId, spaceId: spaceId)
            folder.parent = root
            context.insert(folder)
            let bookmark = Self.row("bookmark-\(spaceId)", type: .bookmark, profileId: profileId, spaceId: spaceId)
            bookmark.parent = folder
            context.insert(bookmark)
            context.insert(Self.row("pin-\(spaceId)", type: .pinnedTab, profileId: profileId, spaceId: spaceId))
            let dormant = Self.row("dormant-\(spaceId)", type: .pinnedTab, profileId: profileId, spaceId: nil)
            dormant.isPinnedTabDormant = true
            context.insert(dormant)
            context.insert(SpaceURLRule(spaceId: spaceId, host: "live-\(spaceId).example", sortOrder: 0))
            context.insert(SpaceURLRule(spaceId: spaceId, host: "gone-\(spaceId).example", sortOrder: 1,
                                        deletedDate: Date()))
        }
    }

    private static func row(_ guid: String, type: TabDataType, profileId: String, spaceId: String?) -> TabDataModel {
        let row = TabDataModel(title: guid, guid: guid, index: 0, url: URL(string: "https://example.com/\(guid)")!,
                               favicon: nil, createdDate: Date(), updatedDate: Date())
        row.dataType = type
        row.profileId = profileId
        row.spaceId = spaceId
        return row
    }

    private func snapshot(_ store: LocalStore) async throws -> (tabs: Set<String>, rules: Int, spaces: [String: String]) {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            (Set(try context.fetch(FetchDescriptor<TabDataModel>()).map(\.guid)),
             try context.fetchCount(FetchDescriptor<SpaceURLRule>()),
             Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SpaceModel>())
                .map { ($0.spaceId, $0.profileId) }))
        }
    }

    func testTheWipeKeepsRootsDeletesDormantPinsAndHardDeletesRules() async throws {
        let store = try makeStore()
        try await store.recreateDefaultSpaceForPairingResetThrowing(profileId: LocalStore.defaultProfileId)
        try await createSpace("work", in: store)
        try await seedOwnedItems(spaceId: LocalStore.defaultSpaceId, in: store)
        try await seedOwnedItems(spaceId: "work", in: store)
        let roots = try await store.performBackgroundWriteAndWaitThrowing { context in
            try store.canonicalRootGuids(in: context)
        }
        XCTAssertEqual(roots.count, 2)

        try await store.wipePhiOwnedItemsForPairingReset()

        let after = try await snapshot(store)
        XCTAssertEqual(after.tabs, roots, "only the canonical roots survive; dormant pins go too")
        XCTAssertEqual(after.rules, 0, "soft-deleted rules are hard-deleted as well")
        XCTAssertEqual(Set(after.spaces.keys), [LocalStore.defaultSpaceId, "work"], "the wipe never deletes Spaces")
    }

    func testTheWipeIsIdempotent() async throws {
        let store = try makeStore()
        try await store.recreateDefaultSpaceForPairingResetThrowing(profileId: LocalStore.defaultProfileId)
        try await seedOwnedItems(spaceId: LocalStore.defaultSpaceId, in: store)

        try await store.wipePhiOwnedItemsForPairingReset()
        let first = try await snapshot(store)
        try await store.wipePhiOwnedItemsForPairingReset()
        let second = try await snapshot(store)

        XCTAssertEqual(first.tabs, second.tabs)
        XCTAssertEqual(second.rules, 0)
        XCTAssertEqual(try store.phiDataCounts(isExcludedSpace: Self.noAgentSpaces), PhiDataCounts())
    }

    /// `ensureDefaultSpace` refuses to resurrect a deleted default Space while other Spaces exist;
    /// the reset's forced variant creates it, bound to the requested Profile, with a root.
    func testTheForcedRecreationCreatesTheDefaultSpaceWhileOtherSpacesExist() async throws {
        let store = try makeStore()
        try await createSpace("work", profileId: "Profile 2", in: store)
        store.ensureDefaultSpace(profileId: LocalStore.defaultProfileId)
        var spaces = try await snapshot(store).spaces
        XCTAssertNil(spaces[LocalStore.defaultSpaceId], "precondition: the ordinary bootstrap refuses")

        let created = try await store.recreateDefaultSpaceForPairingResetThrowing(profileId: LocalStore.defaultProfileId)
        let again = try await store.recreateDefaultSpaceForPairingResetThrowing(profileId: "Profile 2")

        XCTAssertTrue(created)
        XCTAssertFalse(again, "an existing row is left as it is")
        spaces = try await snapshot(store).spaces
        XCTAssertEqual(spaces[LocalStore.defaultSpaceId], LocalStore.defaultProfileId)
        let root = try await store.performBackgroundWriteAndWaitThrowing { context in
            try store.existingBookmarkRoot(profileId: LocalStore.defaultProfileId,
                                           spaceId: LocalStore.defaultSpaceId, in: context)?.guid
        }
        XCTAssertNotNil(root, "the recreated default Space has its bookmark root")
    }

    /// The reset re-binds `default-space` away from a Profile it deletes; ordinary rebinds refuse.
    func testTheDefaultSpaceRebindMovesTheRowAndItsRoot() async throws {
        let store = try makeStore()
        try await store.recreateDefaultSpaceForPairingResetThrowing(profileId: "Profile 2")
        try await store.changeSpaceProfileThrowing(spaceId: LocalStore.defaultSpaceId,
                                                   toProfileId: LocalStore.defaultProfileId)
        let refused = try await snapshot(store).spaces[LocalStore.defaultSpaceId]
        XCTAssertEqual(refused, "Profile 2", "precondition: the ordinary rebind refuses the default Space")

        try await store.rebindDefaultSpaceForPairingResetThrowing(toProfileId: LocalStore.defaultProfileId)

        let rebound = try await snapshot(store).spaces[LocalStore.defaultSpaceId]
        XCTAssertEqual(rebound, LocalStore.defaultProfileId)
        let root = try await store.performBackgroundWriteAndWaitThrowing { context in
            try store.existingBookmarkRoot(profileId: LocalStore.defaultProfileId,
                                           spaceId: LocalStore.defaultSpaceId, in: context)?.profileId
        }
        XCTAssertEqual(root, LocalStore.defaultProfileId)
    }

    /// The counts are exactly what the wipe removes: zero on a fresh install, everything seeded
    /// before the wipe, and only the non-default Space left after it.
    func testCountsMatchWhatTheWipeRemoves() async throws {
        let store = try makeStore()
        try await store.recreateDefaultSpaceForPairingResetThrowing(profileId: LocalStore.defaultProfileId)
        XCTAssertEqual(try store.phiDataCounts(isExcludedSpace: Self.noAgentSpaces), PhiDataCounts(),
                       "a fresh install (default Space and its empty root) has nothing to replace")

        try await createSpace("work", in: store)
        try await createSpace("agent", in: store)
        try await seedOwnedItems(spaceId: "work", in: store)
        let counts = try store.phiDataCounts { name, _, _ in name == "agent" }
        XCTAssertEqual(counts, PhiDataCounts(nonDefaultUserSpaces: 1, bookmarks: 1, bookmarkFolders: 1,
                                             pinnedTabs: 2, urlRules: 1, softDeletedURLRules: 1))

        try await store.wipePhiOwnedItemsForPairingReset()
        XCTAssertEqual(try store.phiDataCounts { name, _, _ in name == "agent" },
                       PhiDataCounts(nonDefaultUserSpaces: 1))
    }

    /// The sweep after a Profile deletion removes the Profile's row and its unlinked leftovers (a
    /// legacy root, Profile-scoped pins) but keeps a root a Space still links. Idempotent.
    func testTheProfileRowSweepKeepsLinkedRootsAndIsIdempotent() async throws {
        let store = try makeStore()
        try await store.recreateDefaultSpaceForPairingResetThrowing(profileId: "Profile 2")
        try await store.rebindDefaultSpaceForPairingResetThrowing(toProfileId: LocalStore.defaultProfileId)
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let legacy = Self.row("legacy-root", type: .bookmarkFolder, profileId: "Profile 2", spaceId: "gone-space")
            context.insert(legacy)
            context.insert(Self.row("profile-pin", type: .pinnedTab, profileId: "Profile 2", spaceId: nil))
        }
        let linkedRoot = try await store.performBackgroundWriteAndWaitThrowing { context in
            try store.existingBookmarkRoot(profileId: LocalStore.defaultProfileId,
                                           spaceId: LocalStore.defaultSpaceId, in: context)?.guid
        }
        XCTAssertTrue(try store.profileRowIds().contains("Profile 2"))

        try await store.deleteProfileRowsForPairingResetThrowing(profileId: "Profile 2")
        try await store.deleteProfileRowsForPairingResetThrowing(profileId: "Profile 2")

        let tabs = try await snapshot(store).tabs
        XCTAssertFalse(tabs.contains("legacy-root"))
        XCTAssertFalse(tabs.contains("profile-pin"))
        XCTAssertTrue(tabs.contains(try XCTUnwrap(linkedRoot)), "the root default-space links stays")
        XCTAssertFalse(try store.profileRowIds().contains("Profile 2"))
        XCTAssertEqual(try store.phiDataCounts(isExcludedSpace: Self.noAgentSpaces), PhiDataCounts())
    }
}
