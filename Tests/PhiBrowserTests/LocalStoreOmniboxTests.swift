// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

@MainActor
final class LocalStoreOmniboxTests: XCTestCase {
    func testReadDoesNotAdvanceEpochAndFailedPreconditionDoes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        let coordinator: OmniboxNativeQueryCoordinator<UInt64> = store.makeOmniboxQueryCoordinator()
        let initial = try await readEpoch(store, coordinator)
        let unchanged = try await readEpoch(store, coordinator)
        XCTAssertEqual(unchanged, initial)
        do {
            try await store.performBackgroundWriteAndWaitThrowing(precondition: {
                throw ProbeError.refused
            }, { _ in XCTFail("A refused precondition must not enter the writer body") })
            XCTFail("Expected refusal")
        } catch ProbeError.refused {}
        let afterRefusal = try await readEpoch(store, coordinator)
        XCTAssertEqual(afterRefusal, initial + 1)
        await store.performBackgroundWriteAndWait { _ in }
        let afterNoOp = try await readEpoch(store, coordinator)
        XCTAssertEqual(afterNoOp, initial + 2)
        try await store.closeForAccountDirectoryRemoval()
    }

    private func readEpoch(_ store: LocalStore,
                           _ coordinator: OmniboxNativeQueryCoordinator<UInt64>) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { continuation in
            coordinator.submit(ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max),
                               read: { try await store.readForOmnibox { _, epoch in epoch } },
                               completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
        }
    }

    private enum ProbeError: Error { case refused }
}
