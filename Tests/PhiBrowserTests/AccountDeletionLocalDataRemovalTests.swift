// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class AccountDeletionLocalDataRemovalTests: XCTestCase {
    // MARK: - Deadline race

    func testAwaitWithDeadlineReportsCompletionWhenTheOperationFinishesInTime() async {
        let finished = await AccountDeletionLocalDataRemoval.awaitWithDeadline(seconds: 5) {}

        XCTAssertTrue(finished)
    }

    func testAwaitWithDeadlineGivesUpOnAStalledOperation() async {
        let finished = await AccountDeletionLocalDataRemoval.awaitWithDeadline(seconds: 0.05) {
            // A callback that never arrives and ignores cancellation — the
            // shape of a stalled WebKit storage sweep. A task-group
            // implementation would hang here (the group drains its
            // children on exit), which is exactly what this test pins.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }

        XCTAssertFalse(finished)
    }

    // MARK: - Sync device key

    /// A throwaway service, never the default: the default service holds the
    /// developer's real device keys.
    private func makeTestDeviceKeyService() -> String {
        "com.phibrowser.sync.device-key.test.\(UUID().uuidString)"
    }

    func testRemoveSyncDeviceKeyDeletesOnlyTheDeletedAccountsItem() throws {
        let service = makeTestDeviceKeyService()
        let deleted = DeviceKeyStore(service: service, accountId: "auth0|deleted")
        let other = DeviceKeyStore(service: service, accountId: "auth0|other")
        let legacy = DeviceKeyStore(service: service, accountId: nil)
        defer { try? deleted.deleteItem(); try? other.deleteItem(); try? legacy.deleteItem() }
        // Account items first so each mints its own key instead of copying
        // the legacy one; then the legacy item.
        let deletedId = try deleted.deviceKeyId()
        let otherId = try other.deviceKeyId()
        let legacyId = try legacy.deviceKeyId()

        AccountDeletionLocalDataRemoval.removeSyncDeviceKey(auth0Sub: "auth0|deleted") {
            DeviceKeyStore(service: service, accountId: $0)
        }

        XCTAssertEqual(try other.deviceKeyId(), otherId, "Another account's item stays")
        XCTAssertEqual(try legacy.deviceKeyId(), legacyId, "The legacy item is never deleted")
        let reloadedId = try deleted.deviceKeyId()
        XCTAssertNotEqual(reloadedId, deletedId, "The deleted account's item is gone")
        XCTAssertEqual(reloadedId, legacyId, "A fresh enrollment copies the legacy key")
    }

    func testRemoveSyncDeviceKeyWithoutSubjectIsANoOp() throws {
        let service = makeTestDeviceKeyService()
        let legacy = DeviceKeyStore(service: service, accountId: nil)
        defer { try? legacy.deleteItem() }
        let legacyId = try legacy.deviceKeyId()
        var madeStores = 0

        AccountDeletionLocalDataRemoval.removeSyncDeviceKey(auth0Sub: nil) {
            madeStores += 1
            return DeviceKeyStore(service: service, accountId: $0)
        }
        AccountDeletionLocalDataRemoval.removeSyncDeviceKey(auth0Sub: "") {
            madeStores += 1
            return DeviceKeyStore(service: service, accountId: $0)
        }

        XCTAssertEqual(madeStores, 0)
        XCTAssertEqual(try legacy.deviceKeyId(), legacyId)
    }

    // MARK: - Sibling channel mapping

    func testSiblingProductBundleIDPairsCanaryWithRelease() {
        XCTAssertEqual(
            AccountDeletionLocalDataRemoval.siblingProductBundleID(for: "com.phibrowser.canary.Mac"),
            "com.phibrowser.Mac"
        )
        XCTAssertEqual(
            AccountDeletionLocalDataRemoval.siblingProductBundleID(for: "com.phibrowser.Mac"),
            "com.phibrowser.canary.Mac"
        )
    }

    func testSiblingProductBundleIDWithoutDotsHasNoSibling() {
        XCTAssertNil(AccountDeletionLocalDataRemoval.siblingProductBundleID(for: "phi"))
    }
}
