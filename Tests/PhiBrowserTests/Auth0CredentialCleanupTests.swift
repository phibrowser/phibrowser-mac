// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Security
import XCTest
@testable import Phi

final class Auth0CredentialCleanupTests: XCTestCase {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PHI-1900-test",
            kSecAttrAccount as String: "credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    func testMissingCredentialSucceedsWithoutRetry() {
        var sdkCalled = false
        XCTAssertTrue(Auth0KeychainCredentialsStorage.clear(
            query: query,
            sdkClear: { sdkCalled = true; return false },
            copyMatching: { _, _ in
                XCTAssertTrue(sdkCalled)
                return errSecItemNotFound
            },
            deleteMatching: { _ in XCTFail("Unexpected retry"); return errSecSuccess },
            deleteLegacyItem: { _ in XCTFail("Unexpected legacy delete"); return errSecSuccess }
        ))
    }

    func testSDKAndRetrySuccessDoNotReplaceAbsenceVerification() {
        var deletionAttempts = 0
        XCTAssertFalse(Auth0KeychainCredentialsStorage.clear(
            query: query,
            sdkClear: { true },
            copyMatching: { _, _ in errSecSuccess },
            deleteMatching: { _ in deletionAttempts += 1; return errSecSuccess },
            deleteLegacyItem: { _ in XCTFail("Unexpected legacy delete"); return errSecSuccess }
        ))
        XCTAssertEqual(deletionAttempts, 8, "False success must stop at the retry limit")
    }

    func testInitialVerificationErrorDoesNotRetryDeletion() {
        XCTAssertFalse(Auth0KeychainCredentialsStorage.clear(
            query: query,
            sdkClear: { false },
            copyMatching: { _, _ in errSecInteractionNotAllowed },
            deleteMatching: { _ in XCTFail("Unexpected retry after a lookup error"); return errSecSuccess },
            deleteLegacyItem: { _ in XCTFail("Unexpected legacy delete"); return errSecSuccess }
        ))
    }

    func testCredentialDisappearingBeforeReferenceLookupRequiresAbsenceVerification() {
        for finalStatus in [errSecItemNotFound, errSecNotAvailable] {
            var reads = 0
            XCTAssertEqual(Auth0KeychainCredentialsStorage.clear(
                query: query,
                sdkClear: { false },
                copyMatching: { _, result in
                    reads += 1
                    switch reads {
                    case 1:
                        XCTAssertNil(result)
                        return errSecSuccess
                    case 2:
                        XCTAssertNotNil(result)
                        return errSecItemNotFound
                    default:
                        XCTAssertNil(result)
                        return finalStatus
                    }
                },
                deleteMatching: { _ in errSecInvalidOwnerEdit },
                deleteLegacyItem: { _ in XCTFail("Disappeared item must not be deleted"); return errSecSuccess }
            ), finalStatus == errSecItemNotFound)
            XCTAssertEqual(reads, 3)
        }
    }

    func testOtherDeletionErrorsDoNotUseLegacyFallback() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable] {
            XCTAssertFalse(Auth0KeychainCredentialsStorage.clear(
                query: query,
                sdkClear: { false },
                copyMatching: { _, result in
                    XCTAssertNil(result)
                    return errSecSuccess
                },
                deleteMatching: { _ in status },
                deleteLegacyItem: { _ in XCTFail("Unexpected legacy delete"); return errSecSuccess }
            ))
        }
    }

    func testOwnerMismatchLookupFailureRemainsBlocked() {
        XCTAssertFalse(Auth0KeychainCredentialsStorage.clear(
            query: query,
            sdkClear: { false },
            copyMatching: { _, result in
                result == nil ? errSecSuccess : errSecInteractionNotAllowed
            },
            deleteMatching: { _ in errSecInvalidOwnerEdit },
            deleteLegacyItem: { _ in XCTFail("Unexpected legacy delete"); return errSecSuccess }
        ))
    }

    func testOwnerMismatchRejectsMissingOrNonLegacyReference() {
        for reference: CFTypeRef? in [nil, Data() as CFData] {
            XCTAssertFalse(Auth0KeychainCredentialsStorage.clear(
                query: query,
                sdkClear: { false },
                copyMatching: { _, result in
                    result?.pointee = reference
                    return errSecSuccess
                },
                deleteMatching: { _ in errSecInvalidOwnerEdit },
                deleteLegacyItem: { _ in XCTFail("Unexpected legacy delete"); return errSecSuccess }
            ))
        }
    }

    func testVerificationErrorRemainsBlockedAfterSuccessfulDelete() {
        var reads = 0
        XCTAssertFalse(Auth0KeychainCredentialsStorage.clear(
            query: query,
            sdkClear: { false },
            copyMatching: { _, _ in
                reads += 1
                return reads == 1 ? errSecSuccess : errSecNotAvailable
            },
            deleteMatching: { _ in errSecSuccess },
            deleteLegacyItem: { _ in XCTFail("Unexpected legacy delete"); return errSecSuccess }
        ))
    }

    func testOwnerMismatchDeletesOnlyExactCredentialAndAllowsReplacement() throws {
        try withTemporaryKeychain { keychain in
            var credentialQuery = query
            credentialQuery[kSecMatchSearchList as String] = [keychain]
            var otherAccount = credentialQuery
            otherAccount[kSecAttrAccount as String] = "credentials-nightly"
            var otherService = credentialQuery
            otherService[kSecAttrService as String] = "another-product"
            for itemQuery in [credentialQuery, otherAccount, otherService] {
                try addCredential(matching: itemQuery, to: keychain, differentOwner: true)
            }

            var deleteQuery = credentialQuery
            deleteQuery.removeValue(forKey: kSecMatchLimit as String)
            // A real file-keychain ACL reproduces PHI-1900 without touching
            // the user's login keychain or storing an actual credential.
            XCTAssertEqual(SecItemDelete(deleteQuery as CFDictionary), errSecInvalidOwnerEdit)
            var fallbackCalls = 0
            XCTAssertTrue(Auth0KeychainCredentialsStorage.clear(
                query: credentialQuery,
                sdkClear: { SecItemDelete(deleteQuery as CFDictionary) == errSecSuccess },
                copyMatching: { query, result in
                    let attributes = query as NSDictionary
                    XCTAssertNil(attributes[kSecReturnData as String])
                    XCTAssertEqual(attributes[kSecAttrService as String] as? String, "PHI-1900-test")
                    XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "credentials")
                    return SecItemCopyMatching(query, result)
                },
                deleteLegacyItem: {
                    fallbackCalls += 1
                    return SecKeychainItemDelete($0)
                }
            ))
            XCTAssertEqual(fallbackCalls, 1)
            XCTAssertEqual(SecItemCopyMatching(credentialQuery as CFDictionary, nil), errSecItemNotFound)
            XCTAssertEqual(SecItemCopyMatching(otherAccount as CFDictionary, nil), errSecSuccess)
            XCTAssertEqual(SecItemCopyMatching(otherService as CFDictionary, nil), errSecSuccess)

            try addCredential(matching: credentialQuery, to: keychain, differentOwner: false)
            XCTAssertEqual(SecItemCopyMatching(credentialQuery as CFDictionary, nil), errSecSuccess)
            XCTAssertTrue(Auth0KeychainCredentialsStorage.clear(
                query: credentialQuery,
                sdkClear: { SecItemDelete(deleteQuery as CFDictionary) == errSecSuccess },
                deleteLegacyItem: { _ in XCTFail("Replacement should use ordinary deletion"); return errSecSuccess }
            ))
        }
    }

    func testLegacyFailureOrFalseSuccessCannotAdmitGuest() throws {
        try withTemporaryKeychain { keychain in
            var credentialQuery = query
            credentialQuery[kSecMatchSearchList as String] = [keychain]
            try addCredential(matching: credentialQuery, to: keychain, differentOwner: true)
            for status in [errSecAuthFailed, errSecSuccess] {
                var fallbackCalls = 0
                XCTAssertFalse(Auth0KeychainCredentialsStorage.clear(
                    query: credentialQuery,
                    sdkClear: { false },
                    deleteLegacyItem: { _ in fallbackCalls += 1; return status }
                ))
                XCTAssertEqual(fallbackCalls, status == errSecSuccess ? 8 : 1)
                XCTAssertEqual(SecItemCopyMatching(credentialQuery as CFDictionary, nil), errSecSuccess)
            }
        }
    }

    func testMatchingCredentialsAcrossKeychainsAreClearedWithoutDeletingNeighbors() throws {
        for firstHasDifferentOwner in [false, true] {
            try withTemporaryKeychain { first in
                try withTemporaryKeychain { second in
                    var credentialQuery = query
                    credentialQuery[kSecMatchSearchList as String] = [first, second]
                    var otherAccount = credentialQuery
                    otherAccount[kSecAttrAccount as String] = "credentials-nightly"
                    var otherService = credentialQuery
                    otherService[kSecAttrService as String] = "another-product"
                    try addCredential(matching: credentialQuery, to: first, differentOwner: firstHasDifferentOwner)
                    try addCredential(matching: credentialQuery, to: second, differentOwner: true)
                    for keychain in [first, second] {
                        try addCredential(matching: otherAccount, to: keychain, differentOwner: false)
                        try addCredential(matching: otherService, to: keychain, differentOwner: false)
                    }

                    var fallbackCalls = 0
                    XCTAssertTrue(Auth0KeychainCredentialsStorage.clear(
                        query: credentialQuery,
                        sdkClear: { false },
                        deleteLegacyItem: {
                            fallbackCalls += 1
                            return SecKeychainItemDelete($0)
                        }
                    ))
                    XCTAssertEqual(fallbackCalls, firstHasDifferentOwner ? 2 : 1)
                    XCTAssertEqual(SecItemCopyMatching(credentialQuery as CFDictionary, nil), errSecItemNotFound)
                    for keychain in [first, second] {
                        otherAccount[kSecMatchSearchList as String] = [keychain]
                        otherService[kSecMatchSearchList as String] = [keychain]
                        XCTAssertEqual(SecItemCopyMatching(otherAccount as CFDictionary, nil), errSecSuccess)
                        XCTAssertEqual(SecItemCopyMatching(otherService as CFDictionary, nil), errSecSuccess)
                    }
                }
            }
        }
    }

    private func withTemporaryKeychain(_ body: (SecKeychain) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Auth0CredentialCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var keychain: SecKeychain?
        let password = UUID().uuidString
        let status = password.withCString {
            SecKeychainCreate(
                directory.appendingPathComponent("test.keychain").path,
                UInt32(password.utf8.count), $0, false, nil, &keychain
            )
        }
        XCTAssertEqual(status, errSecSuccess)
        let createdKeychain = try XCTUnwrap(keychain)
        defer { XCTAssertEqual(SecKeychainDelete(createdKeychain), errSecSuccess) }
        try body(createdKeychain)
    }

    private func addCredential(
        matching query: [String: Any],
        to keychain: SecKeychain,
        differentOwner: Bool
    ) throws {
        var attributes = query
        attributes.removeValue(forKey: kSecMatchLimit as String)
        attributes.removeValue(forKey: kSecMatchSearchList as String)
        attributes[kSecUseKeychain as String] = keychain
        attributes[kSecValueData as String] = Data("synthetic-non-secret".utf8)
        if differentOwner {
            var trustedApplication: SecTrustedApplication?
            XCTAssertEqual(
                SecTrustedApplicationCreateFromPath("/usr/bin/security", &trustedApplication),
                errSecSuccess
            )
            let trusted = try XCTUnwrap(trustedApplication)
            var access: SecAccess?
            XCTAssertEqual(
                SecAccessCreate("PHI-1900 test" as CFString, [trusted] as CFArray, &access),
                errSecSuccess
            )
            attributes[kSecAttrAccess as String] = try XCTUnwrap(access)
        }
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
    }
}
