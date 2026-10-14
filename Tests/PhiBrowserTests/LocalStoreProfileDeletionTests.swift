// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

/// `LocalStore.deleteProfileRowCascadeThrowing` (docs/sync.md, "Profile deletion and rename").
@MainActor
final class LocalStoreProfileDeletionTests: XCTestCase {
    private var directory: URL?

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> LocalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStoreProfileDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        return LocalStore(account: Account(userID: "test-user"), storeDirectoryURL: url,
                          presentsCompatibilityAlerts: false)
    }

    private func insertTab(_ guid: String, profileId: String, spaceId: String?,
                           in store: LocalStore) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let row = TabDataModel(title: guid, guid: guid, index: 0, url: URL(string: "https://example.com")!,
                                   favicon: nil, createdDate: Date(), updatedDate: Date())
            row.profileId = profileId
            row.spaceId = spaceId
            context.insert(row)
        }
    }

    /// A Profile deleted after a remote Space deletion: its hidden Space and that Space's rows go
    /// with it, so nothing reappears bound to a missing Profile once the sync table is reset.
    func testTheCascadeRemovesHiddenSpacesProfilePinsAndTheProfileRow() async throws {
        let store = try makeStore()
        for (spaceId, profileId) in [("hidden", "P2"), ("other", "P3")] {
            try await store.createSpaceThrowing(profileId: profileId, name: spaceId, colorHex: "#3A6FF8",
                                                iconName: "phi:a", spaceId: spaceId, createdDate: nil)
        }
        try await insertTab("in-hidden", profileId: "P2", spaceId: "hidden", in: store)
        try await insertTab("profile-pin", profileId: "P2", spaceId: nil, in: store)
        try await insertTab("other-pin", profileId: "P3", spaceId: nil, in: store)
        try await store.performBackgroundWriteAndWaitThrowing { context in
            context.insert(ProfileModel(profileId: "P2"))
        }

        try await store.deleteProfileRowCascadeThrowing(profileId: "P2", hiddenSpaceIds: ["hidden"])
        // Idempotent: the engine runs it again after a crash.
        try await store.deleteProfileRowCascadeThrowing(profileId: "P2", hiddenSpaceIds: ["hidden"])

        let (spaces, tabs, profiles) = try await store.performBackgroundWriteAndWaitThrowing { context in
            (try context.fetch(FetchDescriptor<SpaceModel>()).map(\.spaceId),
             try context.fetch(FetchDescriptor<TabDataModel>()).map(\.guid),
             try context.fetch(FetchDescriptor<ProfileModel>()).map(\.profileId))
        }
        XCTAssertFalse(spaces.contains("hidden"))
        XCTAssertTrue(spaces.contains("other"))
        XCTAssertFalse(tabs.contains("in-hidden"))
        XCTAssertFalse(tabs.contains("profile-pin"))
        XCTAssertTrue(tabs.contains("other-pin"))
        XCTAssertFalse(profiles.contains("P2"))
    }

    /// A new Profile row records when it was created, which the Profile entity publishes as
    /// `created_at_ms`; an existing row without one is left alone (0 stays "unknown").
    func testANewProfileRowRecordsItsCreationDate() async throws {
        let store = try makeStore()
        try await store.performBackgroundWriteAndWaitThrowing { context in
            context.insert(ProfileModel(profileId: "Old"))
        }
        let before = Date()

        let created = try XCTUnwrap(try store.profile(with: "New", createIfNeeded: true))
        let existing = try XCTUnwrap(try store.profile(with: "Old", createIfNeeded: true))

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(created.createdDate), before.addingTimeInterval(-1))
        XCTAssertNil(existing.createdDate)
    }
}
