// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation
import Security

enum BitwardenSessionStoreUninstallError: Error, Equatable, LocalizedError {
    case deletionFailed(OSStatus)
    case verificationFailed(OSStatus)
    case itemStillPresent

    var errorDescription: String? {
        switch self {
        case .deletionFailed(let status):
            return "The Bitwarden session could not be removed from Keychain (OSStatus \(status))."
        case .verificationFailed(let status):
            return "The Bitwarden Keychain cleanup could not be verified (OSStatus \(status))."
        case .itemStillPresent:
            return "The Bitwarden session is still present in Keychain after cleanup."
        }
    }
}

/// The Bitwarden session record the *app* persists so a browser restart can
/// re-establish the vault without a fresh login. Mirrors the helper's wire
/// shape: `masterPassword` present means "unlocked-restore" (silent re-login),
/// absent means "locked-restore" (identity known, vault sealed).
/// `twoFactorToken` is the server-issued 2FA remember token (device trust, not
/// vault-key material) — without it, every unlock/restore of a 2FA account is
/// a fresh login the server refuses for lack of a second factor. `identityURL`/
/// `apiURL` pin a non-default server (EU cloud / self-hosted); nil is US cloud.
/// Records persisted before the token existed decode with it nil.
struct BitwardenPersistedSession: Codable, Equatable {
    let email: String
    let masterPassword: String?
    var twoFactorToken: String?
    let identityURL: String?
    let apiURL: String?
}

/// App-owned Keychain custody for the Bitwarden session.
///
/// Custody lives here, not in `PhiBitwardenHelper`, on purpose. The helper is a
/// world-executable, Phi-signed binary; a same-user attacker could spawn it with
/// their own socketpair, and if the helper read a session from a Keychain item
/// scoped to *its* code signature, that spawned copy would satisfy the same ACL
/// and could silently restore the vault and serve lookups. Storing the session
/// here binds the item's ACL to the *app's* code signature instead — which the
/// helper binary does not satisfy — and the helper receives its session only via
/// an explicit `restore` the app sends after the handshake. See
/// `docs/bitwarden-password-manager.md` under "Session persistence".
///
/// This uses the **data-protection keychain** (`kSecUseDataProtectionKeychain`):
/// access is scoped by the app's keychain access group, an OS-enforced boundary
/// the helper binary (which carries no such entitlement) cannot satisfy —
/// stronger than the file keychain's trusted-application ACL the helper's old
/// store relied on. On this keychain `kSecAttrAccessible` is actually honored
/// (it is silently inert on the file keychain), pinning the item to
/// after-first-unlock, this-device-only, and never synced to iCloud. Canary and
/// the daily build are additionally separated by both access group and the
/// account name below.
enum BitwardenSessionStore {
    private static let service = "com.phibrowser.bitwarden.session"

    /// Selects the data-protection keychain for every operation. Must be passed
    /// consistently on add/update, copy, and delete or the item written to one
    /// keychain is invisible to a query against the other.
    private static let useDataProtection: [String: Any] =
        [kSecUseDataProtectionKeychain as String: true]

    // Canary and the daily browser must not collide on one machine (distinct
    // signing identities would otherwise fight over one item's ACL).
    #if NIGHTLY_BUILD
    private static let account = "vault-session-canary"
    #else
    private static let account = "vault-session"
    #endif

    /// Stores (or replaces) the session. Best-effort: a Keychain failure is
    /// logged and swallowed so it never fails an otherwise-successful login —
    /// the cost is only a re-login after the next restart.
    static func save(_ session: BitwardenPersistedSession) {
        guard let data = try? JSONEncoder().encode(session) else {
            AppLogError("[BitwardenSessionStore] encode failed")
            return
        }
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        base.merge(useDataProtection) { current, _ in current }
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        if update != errSecItemNotFound {
            AppLogError("[BitwardenSessionStore] SecItemUpdate failed: \(describe(update))")
            return
        }
        var create = base
        create[kSecValueData as String] = data
        // App-group-only across lock states; the account is never synced to
        // iCloud. Honored because this is the data-protection keychain.
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(create as CFDictionary, nil)
        if add != errSecSuccess {
            AppLogError("[BitwardenSessionStore] SecItemAdd failed: \(describe(add))")
        }
    }

    /// Loads the persisted session, or nil if absent/unreadable/corrupt.
    static func load() -> BitwardenPersistedSession? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query.merge(useDataProtection) { current, _ in current }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                AppLogError("[BitwardenSessionStore] read failed: \(describe(status))")
            }
            return nil
        }
        return try? JSONDecoder().decode(BitwardenPersistedSession.self, from: data)
    }

    /// Removes the persisted session (logout, or when a restore reveals it is
    /// stale). Idempotent — a missing item is not an error.
    static func clear() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query.merge(useDataProtection) { current, _ in current }
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogError("[BitwardenSessionStore] clear failed: \(describe(status))")
        }
    }

    /// Strict uninstall-only removal. Unlike the best-effort logout path above,
    /// this verifies absence directly and distinguishes a missing item from an
    /// unreadable Keychain or another Security.framework failure.
    static func clearAndVerifyForUninstall() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query.merge(useDataProtection) { current, _ in current }
        try clearAndVerifyForUninstall(
            deleteItem: { SecItemDelete(query as CFDictionary) },
            itemStatus: { SecItemCopyMatching(query as CFDictionary, nil) },
            retryDelay: { usleep(150_000) }
        )
    }

    static func clearAndVerifyForUninstall(
        deleteItem: () -> OSStatus,
        itemStatus: () -> OSStatus,
        retryDelay: () -> Void
    ) throws {
        let firstDelete = deleteWithRetry(deleteItem, retryDelay: retryDelay)
        guard firstDelete == errSecSuccess || firstDelete == errSecItemNotFound else {
            throw BitwardenSessionStoreUninstallError.deletionFailed(firstDelete)
        }

        let firstStatus = itemStatus()
        if firstStatus == errSecItemNotFound { return }
        guard firstStatus == errSecSuccess else {
            throw BitwardenSessionStoreUninstallError.verificationFailed(firstStatus)
        }

        // A writer may have won immediately before the persistence fence. With
        // future writes disabled, one final delete must make absence stable.
        let secondDelete = deleteWithRetry(deleteItem, retryDelay: retryDelay)
        guard secondDelete == errSecSuccess || secondDelete == errSecItemNotFound else {
            throw BitwardenSessionStoreUninstallError.deletionFailed(secondDelete)
        }
        let secondStatus = itemStatus()
        if secondStatus == errSecItemNotFound { return }
        if secondStatus == errSecSuccess {
            throw BitwardenSessionStoreUninstallError.itemStillPresent
        }
        throw BitwardenSessionStoreUninstallError.verificationFailed(secondStatus)
    }

    private static func deleteWithRetry(
        _ deleteItem: () -> OSStatus,
        retryDelay: () -> Void
    ) -> OSStatus {
        let first = deleteItem()
        if first == errSecSuccess || first == errSecItemNotFound {
            return first
        }
        retryDelay()
        return deleteItem()
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return "OSStatus(\(status)) \(message ?? "no description")"
    }
}
