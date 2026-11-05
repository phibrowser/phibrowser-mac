// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Security
import SimpleKeychain
import XCTest
@testable import Phi

final class Auth0CredentialStoreMigrationTests: XCTestCase {
    private let account = "credentials"
    private let legacyData = Data("legacy".utf8)
    private var suiteName: String!
    private var defaults: UserDefaults!

    private var dataProtection: Auth0CredentialStoreMigration.ReadResult = .notFound
    private var legacy: Auth0CredentialStoreMigration.ReadResult = .notFound
    private var addStatus: OSStatus = errSecSuccess
    private var clearLegacySucceeds = true
    private var addedData: [Data] = []
    private var legacyClearCount = 0
    private var legacyReadCount = 0

    override func setUp() {
        super.setUp()
        suiteName = "Auth0CredentialStoreMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func run(discardsLegacyCredential: Bool = false) -> Auth0CredentialStoreMigration.Outcome {
        Auth0CredentialStoreMigration.runIfNeeded(
            account: account,
            defaults: defaults,
            discardsLegacyCredential: discardsLegacyCredential,
            readDataProtection: { dataProtection },
            addToDataProtection: { data in
                addedData.append(data)
                if addStatus == errSecSuccess {
                    dataProtection = .found(data)
                }
                return addStatus
            },
            readLegacy: {
                legacyReadCount += 1
                return legacy
            },
            clearLegacy: {
                legacyClearCount += 1
                if clearLegacySucceeds {
                    legacy = .notFound
                }
                return clearLegacySucceeds
            }
        )
    }

    private var isCompleted: Bool {
        defaults.bool(forKey: Auth0CredentialStoreMigration.completedKey(account: account))
    }

    private var isCleanupPending: Bool {
        defaults.bool(forKey: Auth0CredentialStoreMigration.legacyCleanupPendingKey(account: account))
    }

    func testMovesLegacyCredentialAndDeletesIt() {
        legacy = .found(legacyData)

        XCTAssertEqual(run(), .migrated)
        XCTAssertEqual(addedData, [legacyData])
        XCTAssertEqual(dataProtection, .found(legacyData))
        XCTAssertEqual(legacy, .notFound)
        XCTAssertTrue(isCompleted)
        XCTAssertFalse(isCleanupPending)
    }

    func testCompletedMigrationNeverReadsLegacyAgain() {
        legacy = .found(legacyData)
        XCTAssertEqual(run(), .migrated)

        legacy = .found(Data("resurrected".utf8))
        dataProtection = .notFound
        XCTAssertEqual(run(), .alreadyMigrated)
        XCTAssertEqual(legacyReadCount, 1)
        XCTAssertEqual(addedData.count, 1)
    }

    func testNoLegacyCredentialCompletesWithoutWriting() {
        XCTAssertEqual(run(), .noLegacyCredential)
        XCTAssertTrue(addedData.isEmpty)
        XCTAssertTrue(isCompleted)
    }

    func testExistingDataProtectionItemWinsAndLegacyIsDeleted() {
        let current = Data("current".utf8)
        dataProtection = .found(current)
        legacy = .found(legacyData)

        XCTAssertEqual(run(), .alreadyInDataProtectionKeychain)
        XCTAssertTrue(addedData.isEmpty)
        XCTAssertEqual(legacyReadCount, 0)
        XCTAssertEqual(dataProtection, .found(current))
        XCTAssertEqual(legacy, .notFound)
        XCTAssertTrue(isCompleted)
    }

    func testBlockedRecoveryDeletesLegacyInsteadOfMoving() {
        legacy = .found(legacyData)

        XCTAssertEqual(run(discardsLegacyCredential: true), .discardedLegacyCredential)
        XCTAssertTrue(addedData.isEmpty)
        XCTAssertEqual(dataProtection, .notFound)
        XCTAssertEqual(legacy, .notFound)
        XCTAssertTrue(isCompleted)
    }

    func testDuplicateFromConcurrentMigrationKeepsExistingItem() {
        let concurrent = Data("concurrent".utf8)
        var reads = 0

        let outcome = Auth0CredentialStoreMigration.runIfNeeded(
            account: account,
            defaults: defaults,
            discardsLegacyCredential: false,
            readDataProtection: {
                reads += 1
                return reads == 1 ? .notFound : .found(concurrent)
            },
            addToDataProtection: { _ in errSecDuplicateItem },
            readLegacy: { .found(legacyData) },
            clearLegacy: { true }
        )

        XCTAssertEqual(outcome, .migrated)
        XCTAssertTrue(isCompleted)
    }

    func testWriteFailureKeepsLegacyAndRetriesNextLaunch() {
        legacy = .found(legacyData)
        addStatus = errSecMissingEntitlement

        XCTAssertEqual(run(), .dataProtectionWriteFailed(errSecMissingEntitlement))
        XCTAssertEqual(legacyClearCount, 0)
        XCTAssertFalse(isCompleted)

        addStatus = errSecSuccess
        XCTAssertEqual(run(), .migrated)
        XCTAssertEqual(legacy, .notFound)
    }

    func testUnverifiedWriteKeepsLegacy() {
        let outcome = Auth0CredentialStoreMigration.runIfNeeded(
            account: account,
            defaults: defaults,
            discardsLegacyCredential: false,
            readDataProtection: { .notFound },
            addToDataProtection: { _ in errSecSuccess },
            readLegacy: { .found(legacyData) },
            clearLegacy: { XCTFail("Legacy must survive an unverified write"); return true }
        )

        XCTAssertEqual(outcome, .dataProtectionVerificationFailed)
        XCTAssertFalse(isCompleted)
    }

    func testDataProtectionReadFailureLeavesLegacyUntouched() {
        dataProtection = .failed(errSecMissingEntitlement)
        legacy = .found(legacyData)

        XCTAssertEqual(run(), .dataProtectionReadFailed(errSecMissingEntitlement))
        XCTAssertEqual(legacyReadCount, 0)
        XCTAssertEqual(legacyClearCount, 0)
        XCTAssertFalse(isCompleted)
    }

    func testLegacyReadFailureKeepsCredentialAndRetriesUntilReadable() {
        legacy = .failed(errSecAuthFailed)

        for _ in 0..<5 {
            XCTAssertEqual(run(), .legacyReadFailed(errSecAuthFailed))
            XCTAssertFalse(isCompleted)
        }
        XCTAssertEqual(legacyClearCount, 0)
        XCTAssertTrue(addedData.isEmpty)

        legacy = .found(legacyData)
        XCTAssertEqual(run(), .migrated)
        XCTAssertEqual(dataProtection, .found(legacyData))
    }

    func testLegacyReadFailureEndsOnceLoginWritesDataProtectionItem() {
        legacy = .failed(errSecAuthFailed)
        XCTAssertEqual(run(), .legacyReadFailed(errSecAuthFailed))

        let relogin = Data("relogin".utf8)
        dataProtection = .found(relogin)
        XCTAssertEqual(run(), .alreadyInDataProtectionKeychain)
        XCTAssertEqual(dataProtection, .found(relogin))
        XCTAssertEqual(legacyClearCount, 1)
        XCTAssertTrue(isCompleted)
    }

    func testBlockedRecoveryDeletesWithoutReadingEitherKeychain() {
        let outcome = Auth0CredentialStoreMigration.runIfNeeded(
            account: account,
            defaults: defaults,
            discardsLegacyCredential: true,
            readDataProtection: {
                XCTFail("Discard must not read the data protection keychain")
                return .failed(errSecMissingEntitlement)
            },
            addToDataProtection: { _ in
                XCTFail("Discard must not write")
                return errSecSuccess
            },
            readLegacy: {
                XCTFail("Discard must not decrypt the legacy item")
                return .failed(errSecAuthFailed)
            },
            clearLegacy: { true }
        )

        XCTAssertEqual(outcome, .discardedLegacyCredential)
        XCTAssertTrue(isCompleted)
        XCTAssertFalse(isCleanupPending)
    }

    func testBlockedRecoveryDeletionFailureIsRetriedNextLaunch() {
        legacy = .found(legacyData)
        clearLegacySucceeds = false

        XCTAssertEqual(run(discardsLegacyCredential: true), .discardedLegacyCredential)
        XCTAssertTrue(isCompleted)
        XCTAssertTrue(isCleanupPending)
        XCTAssertEqual(legacyReadCount, 0)

        clearLegacySucceeds = true
        XCTAssertEqual(run(discardsLegacyCredential: true), .alreadyMigrated)
        XCTAssertFalse(isCleanupPending)
        XCTAssertEqual(legacy, .notFound)
        XCTAssertEqual(legacyReadCount, 0)
    }

    func testPendingLegacyCleanupRetriesUntilItSucceeds() {
        legacy = .found(legacyData)
        clearLegacySucceeds = false

        XCTAssertEqual(run(), .migrated)
        XCTAssertTrue(isCleanupPending)

        XCTAssertEqual(run(), .alreadyMigrated)
        XCTAssertTrue(isCleanupPending)
        XCTAssertEqual(legacyReadCount, 1, "Cleanup must not read the legacy secret")

        clearLegacySucceeds = true
        XCTAssertEqual(run(), .alreadyMigrated)
        XCTAssertFalse(isCleanupPending)
        XCTAssertEqual(legacyClearCount, 3)
    }

    func testOnlyUnwrittenDataProtectionOutcomesKeepLegacyReadable() {
        let authoritative: [Auth0CredentialStoreMigration.Outcome] = [
            .dataProtectionReadFailed(errSecMissingEntitlement),
            .dataProtectionWriteFailed(errSecMissingEntitlement),
            .dataProtectionVerificationFailed,
        ]
        let resolved: [Auth0CredentialStoreMigration.Outcome] = [
            .alreadyMigrated,
            .migrated,
            .alreadyInDataProtectionKeychain,
            .noLegacyCredential,
            .discardedLegacyCredential,
            .legacyReadFailed(errSecAuthFailed),
        ]
        XCTAssertTrue(authoritative.allSatisfy(\.leavesLegacyCredentialAuthoritative))
        XCTAssertFalse(resolved.contains(where: \.leavesLegacyCredentialAuthoritative))
    }

    func testStorageFallsBackOnlyWhenPrimaryHasNoEntry() {
        let primary = SimpleKeychain(service: "PHI-DPK-migration-test-primary-\(UUID().uuidString)")
        let fallback = SimpleKeychain(service: "PHI-DPK-migration-test-fallback-\(UUID().uuidString)")
        defer {
            try? primary.deleteItem(forKey: account)
            try? fallback.deleteItem(forKey: account)
        }
        let storage = Auth0KeychainCredentialsStorage(keychain: primary, fallbackKeychain: fallback)
        XCTAssertNil(storage.getEntry(forKey: account))

        XCTAssertNoThrow(try fallback.set(legacyData, forKey: account))
        XCTAssertEqual(storage.getEntry(forKey: account), legacyData)

        let renewed = Data("renewed".utf8)
        XCTAssertTrue(storage.setEntry(renewed, forKey: account))
        XCTAssertEqual(try? primary.data(forKey: account), renewed)
        XCTAssertEqual(try? fallback.data(forKey: account), legacyData, "Writes must not touch the fallback")
        XCTAssertEqual(storage.getEntry(forKey: account), renewed)
    }

    func testMigrationStateIsScopedPerAccount() {
        legacy = .found(legacyData)
        XCTAssertEqual(run(), .migrated)

        XCTAssertFalse(defaults.bool(
            forKey: Auth0CredentialStoreMigration.completedKey(account: "credentials-nightly")
        ))
    }
}
