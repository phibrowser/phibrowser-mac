// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import XCTest
@testable import Phi

final class ProfileChatArchiveJournalTests: XCTestCase {
    private func withJournal(_ run: (ProfileChatArchiveJournal) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try run(ProfileChatArchiveJournal(fileURL: root.appendingPathComponent("pending.json")))
    }

    func testIntentSurvivesReloadAndWaitsForDeletion() throws {
        try withJournal { journal in
            let entry = try journal.prepare(profileId: "Profile A")
            let reloaded = ProfileChatArchiveJournal(fileURL: journal.fileURL)
            XCTAssertEqual(try reloaded.load(), [entry])
            XCTAssertEqual(try reloaded.ready(existingProfileIds: ["Profile A"]), [])
            try reloaded.finish(entry.operationId, deleted: true)
            XCTAssertEqual(try reloaded.ready(existingProfileIds: []).map(\.operationId), [entry.operationId])
        }
    }

    func testCrashAfterDeletionRecoversUnconfirmedIntent() throws {
        try withJournal { journal in
            let entry = try journal.prepare(profileId: "Profile A")
            XCTAssertEqual(try journal.ready(existingProfileIds: ["Default"]).map(\.operationId), [entry.operationId])
        }
    }

    func testFailedDeletionOrAcceptedDeliveryRemovesOnlyItsOperation() throws {
        try withJournal { journal in
            let first = try journal.prepare(profileId: "A")
            let second = try journal.prepare(profileId: "B")
            try journal.finish(first.operationId, deleted: false)
            XCTAssertEqual(try journal.load(), [second])
        }
    }

    func testDifferentAccountPathsNeverSharePendingOperations() throws {
        try withJournal { journal in
            _ = try journal.prepare(profileId: "A")
            let other = ProfileChatArchiveJournal(fileURL: journal.fileURL.deletingLastPathComponent().appendingPathComponent("other-account.json"))
            XCTAssertEqual(try other.load(), [])
        }
    }

    func testAIOrAccountUnavailabilityPausesDeliveryNotRecording() throws {
        try withJournal { journal in
            _ = try journal.prepare(profileId: "A")
            XCTAssertFalse(ProfileChatArchiveJournal.deliveryAllowed(aiEnabled: false, authenticated: true))
            XCTAssertFalse(ProfileChatArchiveJournal.deliveryAllowed(aiEnabled: true, authenticated: false))
            XCTAssertTrue(ProfileChatArchiveJournal.deliveryAllowed(aiEnabled: true, authenticated: true))
            XCTAssertEqual(try journal.load().count, 1)
        }
    }
}
