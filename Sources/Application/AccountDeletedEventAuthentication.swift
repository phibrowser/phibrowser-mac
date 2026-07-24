// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import Security

struct AccountDeletedSignedContent: Codable, Equatable {
    let signatureVersion: String
    let notificationName: String
    let sentinelBundleID: String
    let browserBundleID: String
    let requestID: String
    let auth0Sub: String
    let issuedAt: String
}

enum SentinelAccountDeletedEventError: Error, Equatable, CustomStringConvertible {
    case missingField(String)
    case signingKeyUnavailable
    case invalidIssuedAt
    case signingFailed

    var description: String {
        switch self {
        case .missingField(let field): return "missing field \(field)"
        case .signingKeyUnavailable: return "signing key unavailable"
        case .invalidIssuedAt: return "invalid issuedAt"
        case .signingFailed: return "signing failed"
        }
    }
}

enum AccountDeletedEventAuthentication {
    static let signatureVersion = "1"
    static let keyByteCount = 32

    static func signature(
        for content: AccountDeletedSignedContent,
        key: Data
    ) throws -> String {
        guard key.count == keyByteCount else {
            throw SentinelAccountDeletedEventError.signingKeyUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let message = try encoder.encode(content)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        return Data(authenticationCode).base64EncodedString()
    }
}

final class AccountDeletedSigningKeyStore {
    static let shared = AccountDeletedSigningKeyStore()

    static let service = "com.phibrowser.sentinel.account-deleted-auth"
    static let account = "hmac-v1"

    private enum ReadResult {
        case found(Data)
        case notFound
        case failed
    }

    private let appGroupAccessGroup = "group.com.phibrowser.shared"

    private init() {}

    func readOrCreate() -> Data? {
        guard let accessGroup = resolvedAccessGroup() else {
            return nil
        }

        switch read(accessGroup: accessGroup) {
        case .found(let key):
            return key
        case .notFound:
            return create(accessGroup: accessGroup)
        case .failed:
            return nil
        }
    }

    private func read(accessGroup: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = runKeychainOperationWithRetry {
            item = nil
            return SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess,
              let key = item as? Data,
              key.count == AccountDeletedEventAuthentication.keyByteCount else {
            return .failed
        }
        return .found(key)
    }

    private func create(accessGroup: String) -> Data? {
        var key = Data(count: AccountDeletedEventAuthentication.keyByteCount)
        let randomStatus = key.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(
                kSecRandomDefault,
                AccountDeletedEventAuthentication.keyByteCount,
                buffer.baseAddress!
            )
        }
        guard randomStatus == errSecSuccess else {
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: key
        ]
        let status = runKeychainOperationWithRetry(
            terminalStatuses: [errSecSuccess, errSecItemNotFound, errSecDuplicateItem]
        ) {
            SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess {
            return key
        }
        if status == errSecDuplicateItem,
           case .found(let existingKey) = read(accessGroup: accessGroup) {
            return existingKey
        }
        return nil
    }

    private func resolvedAccessGroup() -> String? {
        let groups = entitlementValues(for: "com.apple.security.application-groups")
        return groups.contains(appGroupAccessGroup) ? appGroupAccessGroup : nil
    }

    private func entitlementValues(for key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let rawValue = SecTaskCopyValueForEntitlement(
                task,
                key as CFString,
                nil
              ) else {
            return []
        }
        if let values = rawValue as? [String] {
            return values
        }
        if let value = rawValue as? String {
            return [value]
        }
        return []
    }

    private func runKeychainOperationWithRetry(
        terminalStatuses: Set<OSStatus> = [errSecSuccess, errSecItemNotFound],
        operation: () -> OSStatus
    ) -> OSStatus {
        let first = operation()
        guard !terminalStatuses.contains(first) else {
            return first
        }
        Thread.sleep(forTimeInterval: 0.15)
        return operation()
    }
}
