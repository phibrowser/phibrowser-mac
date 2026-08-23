// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import Security

extension Notification.Name {
    #if NIGHTLY_BUILD
    static let sharedAuthTokenDidChange = Notification.Name("com.phibrowser.canary.sharedAuthTokenDidChange")
    #else
    static let sharedAuthTokenDidChange = Notification.Name("com.phibrowser.sharedAuthTokenDidChange")
    #endif
}

struct SharedAuthToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let auth0Sub: String?
    let expiresAt: Date?
    let updatedAt: Date
    let renewedBy: String?
    let revisionID: UUID?
}

/// Non-secret identity for one authenticated Keychain payload.
///
/// The revision changes on every browser write, including same-account token
/// rotation. It can therefore scope caches and optimistic transactions without
/// exposing bearer credentials.
struct SharedAuthScope: Equatable, Hashable, Sendable {
    let accountID: String
    let revisionID: UUID
}

/// Immutable credentials and scope decoded from one Keychain read.
struct SharedAuthTokenSnapshot: Equatable, Sendable {
    let scope: SharedAuthScope
    let accessToken: String
}

/// Severity level for diagnostics emitted by `SharedAuthTokenStore`.
enum SharedAuthTokenStoreLogLevel {
    case info
    case warning
    case error
}

/// Receives diagnostic events from `SharedAuthTokenStore`. The store itself
/// has no logging dependency so the file can be copied verbatim between the
/// Phi browser and Phi Sentinel projects; each host wires its own logger
/// (CocoaLumberjack-backed `AppLog*` in Phi, `SentinelLogger` in Sentinel).
///
/// When no delegate is attached (the default), the store runs silently.
protocol SharedAuthTokenStoreLogDelegate: AnyObject {
    func sharedAuthTokenStore(
        _ store: SharedAuthTokenStore,
        log level: SharedAuthTokenStoreLogLevel,
        _ message: String
    )
}

final class SharedAuthTokenStore {
    static let shared = SharedAuthTokenStore()

    /// Hosts attach their own logger here on startup. Held weakly so a
    /// host's lifecycle owns the logger; the store does not retain it.
    weak var logDelegate: SharedAuthTokenStoreLogDelegate?

    private let appGroupAccessGroup = "group.com.phibrowser.shared"
    private let service = "com.phibrowser.auth.shared-token"
    #if NIGHTLY_BUILD
    private let account = "auth0-access-token-v1-canary"
    #else
    private let account = "auth0-access-token-v1"
    #endif
    private let accessibility = kSecAttrAccessibleAfterFirstUnlock
    private let legacyRevisionLock = NSLock()
    private var lastLegacyPayloadDigest: Data?
    private var lastLegacyRevisionID: UUID?

    private init() {}

    private func log(_ level: SharedAuthTokenStoreLogLevel, _ message: String) {
        logDelegate?.sharedAuthTokenStore(self, log: level, message)
    }

    func upsert(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        auth0Sub: String?,
        expiresAt: Date?,
        renewedBy: String? = nil
    ) -> Bool {
        guard !accessToken.isEmpty else {
            log(.error, "[SharedAuthTokenStore] upsert refused: accessToken is empty")
            return false
        }
        guard let accessGroup = resolvedAccessGroup() else {
            log(.error, "[SharedAuthTokenStore] upsert refused: no resolvable access group")
            return false
        }

        let payload = SharedAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            auth0Sub: auth0Sub,
            expiresAt: expiresAt,
            updatedAt: Date(),
            renewedBy: renewedBy,
            revisionID: UUID()
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            log(.error, "[SharedAuthTokenStore] upsert refused: failed to JSON-encode SharedAuthToken payload")
            return false
        }

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

        let updateStatus = runKeychainOpWithRetry(label: "SecItemUpdate") {
            SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        }
        if updateStatus == errSecSuccess {
            postDistributedChangeNotification(hasToken: true, auth0Sub: auth0Sub)
            return true
        }

        if updateStatus != errSecItemNotFound {
            log(.error, "[SharedAuthTokenStore] SecItemUpdate failed: \(Self.describe(updateStatus))")
            return false
        }

        var createQuery = baseQuery
        applyAccessibilityIfNeeded(to: &createQuery)
        createQuery[kSecValueData as String] = data
        let addStatus = runKeychainOpWithRetry(label: "SecItemAdd") {
            SecItemAdd(createQuery as CFDictionary, nil)
        }
        if addStatus == errSecSuccess {
            postDistributedChangeNotification(hasToken: true, auth0Sub: auth0Sub)
            return true
        }

        log(.error, "[SharedAuthTokenStore] SecItemAdd failed: \(Self.describe(addStatus))")
        return false
    }

    func read() -> SharedAuthToken? {
        readPayload()?.token
    }

    /// Returns account identity, bearer credential, and an opaque generation
    /// from one Keychain value. Older Sentinel/browser payloads do not contain
    /// `revisionID`; those receive a stable process-local UUID while their exact
    /// raw payload remains unchanged. New writes always persist a fresh UUID.
    func authenticatedSnapshot() -> SharedAuthTokenSnapshot? {
        guard let payload = readPayload(),
              !payload.token.accessToken.isEmpty,
              let accountID = payload.token.auth0Sub,
              !accountID.isEmpty else {
            return nil
        }
        let revisionID = payload.token.revisionID ?? legacyRevisionID(for: payload.data)
        return SharedAuthTokenSnapshot(
            scope: SharedAuthScope(accountID: accountID, revisionID: revisionID),
            accessToken: payload.token.accessToken
        )
    }

    private func readPayload() -> (token: SharedAuthToken, data: Data)? {
        guard let accessGroup = resolvedAccessGroup() else {
            log(.error, "[SharedAuthTokenStore] read failed: no resolvable access group")
            return nil
        }

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
        let status = runKeychainOpWithRetry(label: "SecItemCopyMatching") {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecSuccess {
            guard let data = item as? Data else {
                log(.error, "[SharedAuthTokenStore] SecItemCopyMatching returned success but item is not Data")
                return nil
            }
            guard let token = try? JSONDecoder().decode(SharedAuthToken.self, from: data) else {
                return nil
            }
            return (token, data)
        }
        // `errSecItemNotFound` is the legitimate "no shared token yet" state
        // (e.g., before first login on this device), so don't log it.
        if status != errSecItemNotFound {
            log(.error, "[SharedAuthTokenStore] SecItemCopyMatching failed: \(Self.describe(status))")
        }
        return nil
    }

    private func legacyRevisionID(for payload: Data) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("phibrowser.shared-auth.legacy-revision.v1".utf8))
        hasher.update(data: payload)
        let digest = Data(hasher.finalize())

        legacyRevisionLock.lock()
        defer { legacyRevisionLock.unlock() }
        if lastLegacyPayloadDigest == digest, let lastLegacyRevisionID {
            return lastLegacyRevisionID
        }
        let revisionID = UUID()
        lastLegacyPayloadDigest = digest
        lastLegacyRevisionID = revisionID
        return revisionID
    }

    /// Removes the shared token. Account deletion suppresses the first change
    /// notification so the signed `accountDeleted` event reaches Sentinel
    /// before Sentinel drops its in-memory account identity; the final clear
    /// posts the normal notification.
    @discardableResult
    func clear(postChangeNotification: Bool = true) -> Bool {
        guard let accessGroup = resolvedAccessGroup() else {
            log(.error, "[SharedAuthTokenStore] clear failed: no resolvable access group")
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true
        ]

        let status = runKeychainOpWithRetry(label: "SecItemDelete") {
            SecItemDelete(query as CFDictionary)
        }
        if status == errSecSuccess || status == errSecItemNotFound {
            if postChangeNotification {
                postDistributedChangeNotification(hasToken: false, auth0Sub: nil)
            }
            return true
        }
        // A failed clear leaves a stale (and possibly server-revoked) RT in the
        // shared store. Surface this loudly because subsequent recovery flows
        // will pick that token up and ferrt again.
        log(.error, "[SharedAuthTokenStore] SecItemDelete failed: \(Self.describe(status))")
        return false
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

    /// Runs a keychain operation once, retrying it once after a brief delay
    /// when the first attempt returns a likely-transient failure. Sleep/wake
    /// transitions, securityd contention right after device unlock, and brief
    /// memory pressure occasionally surface as `errSecInternalComponent`,
    /// `errSecAllocate`, or other non-permanent statuses; a single 150ms
    /// pause clears the vast majority of these without keeping the caller
    /// blocked for long.
    ///
    /// `errSecSuccess` and `errSecItemNotFound` skip the retry: success is
    /// already terminal, and "not found" is a meaningful state used by both
    /// `upsert` (to fall through to `SecItemAdd`) and `clear` (already in
    /// the desired state).
    private func runKeychainOpWithRetry(
        label: String,
        op: () -> OSStatus
    ) -> OSStatus {
        let first = op()
        if first == errSecSuccess || first == errSecItemNotFound {
            return first
        }

        usleep(150_000) // 150ms
        let second = op()
        if second == errSecSuccess {
            log(.info, "[SharedAuthTokenStore] \(label) recovered on retry: first=\(Self.describe(first))")
        } else if second != errSecItemNotFound {
            log(.warning, "[SharedAuthTokenStore] \(label) retry did not recover: first=\(Self.describe(first)), second=\(Self.describe(second))")
        }
        return second
    }

    /// Renders an OSStatus as `OSStatus(<code>) <Apple-provided message>`.
    /// The Apple message comes from `SecCopyErrorMessageString`, which
    /// understands all `errSec*` constants and returns nil only for unknown
    /// statuses.
    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return "OSStatus(\(status)) \(message ?? "no description")"
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
