// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

/// Failure path for LocalStoreActor.perform(_:).
/// LocalStoreActor is a ModelActor with one shared modelContext for all process-wide
/// background writes. performBackgroundWrite, AndWait, and AndWaitThrowing all reach
/// it through the same FIFO queue. Context state after a failure therefore affects
/// every subsequent write, not just the failed operation.
@MainActor
final class LocalStoreWriteRollbackTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// A normal write must still persist after a previous save failure.
    /// perform's catch formerly logged without rollback, unlike performThrowing. Invalid
    /// changes remained in the shared context and caused every subsequent save to fail
    /// until a throwing write happened to roll them back. On Mac B, 2026-09-14, this lasted
    /// 19 seconds, silently losing two unpins and causing a Space application to fail.
    ///
    /// Reproduce the invalid shape by setting profile on a TabDataModel before insertion.
    /// Through the ProfileModel.tabs inverse, SwiftData registers a placeholder with six
    /// empty required columns; the whole save fails validation (NSCocoaErrorDomain 1560).
    ///
    /// This is a characterization test, not a guaranteed pre-fix failure probe. It verifies
    /// that subsequent writes remain possible only if step ① actually fails. Investigation
    /// §6 did not identify when placeholders materialize in Core Data; the incident began
    /// about 100 seconds after a successful migration save. If ① succeeds, the test passes
    /// without exercising rollback. Assertion ② carries the test; the empty-guid check is
    /// a fallback, since investigation found placeholders could not persist in either outcome.
    func testAFailedWriteDoesNotPoisonTheNextWrite() async throws {
        let store = try makeStore()

        // ① Invalid write. perform logs rather than throws, so it has no result to assert; step ② carries the test.
        await store.performBackgroundWriteAndWait { context in
            let profiles = (try? context.fetch(FetchDescriptor<ProfileModel>())) ?? []
            guard let profile = profiles.first else { return }
            let orphan = TabDataModel(
                title: "Orphan",
                guid: "orphan",
                index: 0,
                url: URL(string: "https://orphan.example")!,
                favicon: nil,
                createdDate: Date(timeIntervalSince1970: 1_000),
                updatedDate: Date(timeIntervalSince1970: 1_000)
            )
            orphan.dataType = .pinnedTab
            // Deliberately set the relationship without ever inserting; the inverse registers a blank placeholder.
            orphan.profile = profile
        }

        // ② A normal write must succeed. Without rollback, the placeholder left by ①
        // makes this entire save fail too, preventing the row from persisting.
        await store.performBackgroundWriteAndWait { context in
            let model = TabDataModel(
                title: "Healthy",
                guid: "healthy",
                index: 0,
                url: URL(string: "https://healthy.example")!,
                favicon: nil,
                createdDate: Date(timeIntervalSince1970: 2_000),
                updatedDate: Date(timeIntervalSince1970: 2_000)
            )
            model.dataType = .pinnedTab
            context.insert(model)
        }

        XCTAssertEqual(store.getTab(by: "healthy")?.title, "Healthy",
                      "The previous failure must not make this write fail")
        XCTAssertNil(store.getTab(by: "orphan"), "The invalid write must not persist")
        XCTAssertTrue(store.getAllTabs().allSatisfy { !$0.guid.isEmpty },
                      "No blank placeholders persisted")
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
        try context.save()
        return store
    }
}
