// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Security

extension Notification.Name {
    static let sharedAuthTokenDidChange = Notification.Name("com.phibrowser.sharedAuthTokenDidChange")
}

struct SharedAuthToken: Codable {
    let accessToken: String
    let auth0Sub: String?
    let expiresAt: Date?
    let updatedAt: Date
}

final class SharedAuthTokenStore {
    static let shared = SharedAuthTokenStore()

    private let appGroupAccessGroup = "group.com.phibrowser.shared"
    private let service = "com.phibrowser.auth.shared-token"
    #if NIGHTLY_BUILD
    private let account = "auth0-access-token-v1-canary"
    #else
    private let account = "auth0-access-token-v1"
    #endif
    private let accessibility = kSecAttrAccessibleAfterFirstUnlock

    private init() {}

    func upsert(accessToken: String, auth0Sub: String?, expiresAt: Date?) -> Bool {
        guard !accessToken.isEmpty else { return false }
        guard let accessGroup = resolvedAccessGroup() else { return false }

        let payload = SharedAuthToken(
            accessToken: accessToken,
            auth0Sub: auth0Sub,
            expiresAt: expiresAt,
            updatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            postDistributedChangeNotification(hasToken: true, auth0Sub: auth0Sub)
            return true
        }

        if updateStatus != errSecItemNotFound {
            return false
        }

        var createQuery = baseQuery
        applyAccessibilityIfNeeded(to: &createQuery)
        createQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            postDistributedChangeNotification(hasToken: true, auth0Sub: auth0Sub)
        }
        return addStatus == errSecSuccess
    }

    func read() -> SharedAuthToken? {
        guard let accessGroup = resolvedAccessGroup() else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SharedAuthToken.self, from: data)
    }

    func clear() {
        guard let accessGroup = resolvedAccessGroup() else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            postDistributedChangeNotification(hasToken: false, auth0Sub: nil)
        }
    }

    private func resolvedAccessGroup() -> String? {
        if let appGroup = accessGroupFromAppGroupEntitlement() {
            return appGroup
        }
        return appGroupAccessGroup
    }

    private func accessGroupFromAppGroupEntitlement() -> String? {
        let groups = entitlementValues(for: "com.apple.security.application-groups")
        if let match = groups.first(where: { $0 == appGroupAccessGroup || $0.hasSuffix(".\(appGroupAccessGroup)") }) {
            return match
        }
        return groups.first
    }

    private func applyAccessibilityIfNeeded(to query: inout [String: Any]) {
        #if os(macOS)
        if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
            query[kSecAttrAccessible as String] = accessibility
        }
        #else
        query[kSecAttrAccessible as String] = accessibility
        #endif
    }

    private func entitlementValues(for key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        guard let rawValue = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return [] }
        if let array = rawValue as? [String] {
            return array
        }
        if let string = rawValue as? String {
            return [string]
        }
        return []
    }

    private func postDistributedChangeNotification(hasToken: Bool, auth0Sub: String?) {
        #if os(macOS)
        var userInfo: [String: Any] = [
            "has_token": hasToken,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let auth0Sub {
            userInfo["auth0_sub"] = auth0Sub
        }

        DistributedNotificationCenter.default().post(
            name: .sharedAuthTokenDidChange,
            object: nil,
            userInfo: userInfo
        )
        #endif
    }
}
