// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Provider-agnostic credential surface. Bitwarden is the first backend, but
/// the app never talks to a vendor directly — it talks to a `CredentialProvider`
/// so that future backends (1Password `op`, Phi's built-in password store) drop
/// in without touching onboarding, settings, or the agent `credentials.*`
/// handlers. Modeled on the `CredentialProvider` trait in `ap-cli`
/// (bitwarden/agent-access): the same `status → unlock → lookup` shape.
///
/// Secret material is wrapped in `RedactedSecret` so it never lands in a log,
/// a Sentry breadcrumb, or a `String(describing:)` by accident. Swift `String`
/// cannot be reliably zeroed (it is not a fixed buffer), so this is redaction
/// for hygiene, not in-memory zeroization — the real zeroization boundary is
/// the helper process, which drops the vault key on lock.
protocol CredentialProvider: AnyObject {
    /// Stable identifier used in prefs and audit records: `"bitwarden"`, …
    var id: String { get }
    /// Human-facing name for settings/onboarding UI.
    var displayName: String { get }

    /// Current readiness. Cheap to call; providers may cache.
    func status() async -> CredentialProviderStatus

    /// Unlock the vault. `secret` is a master password for password-based
    /// unlock; pass `nil` to request the provider's biometric/keychain path.
    /// `twoFactor` is a freshly typed second-factor code for providers whose
    /// unlock is a re-login and whose device trust (remember token) has
    /// expired; normally nil. `newDeviceOtp` is the one-time code such a
    /// provider's server emails when it does not recognize this device; also
    /// normally nil, since only a refused unlock can have produced one.
    func unlock(secret: String?, twoFactor: String?, newDeviceOtp: String?) async throws

    /// Drop the in-memory vault key. Idempotent.
    func lock() async

    /// Resolve a single credential for the given query.
    func lookup(_ query: CredentialQuery) async throws -> CredentialLookupResult

    /// Current TOTP value for the item matching `query`, if the item carries one.
    func totp(for query: CredentialQuery) async throws -> RedactedSecret?
}

/// How the caller wants a credential resolved. Exactly one variant, mirroring
/// the protocol-v0 `CredentialQuery` (domain / id / search).
enum CredentialQuery: Equatable, Sendable {
    /// URL or bare host; the provider normalizes (scheme strip, eTLD+1) per its
    /// own matching policy. `username` narrows to one account when the user
    /// keeps several logins for the same site.
    case domain(String, username: String?)
    /// A vault-item identifier the caller already knows (e.g. from a prior search).
    case itemId(String)
    /// Free-text search over names/usernames/URIs; provider-defined semantics.
    case search(String)
}

/// Readiness of a provider, ordered from "cannot use" to "use now". Distinguishes
/// `loggedOut` (no account on this machine) from `locked` (account present, vault
/// encrypted) because they drive different UI: a login sheet vs. an unlock prompt.
enum CredentialProviderStatus: Equatable, Sendable {
    /// Backend binary/helper is absent — offer install.
    case notInstalled
    /// Present but unusable right now for a provider-specific reason.
    case unavailable(reason: String)
    /// Reachable but no account is authenticated — offer login.
    case loggedOut
    /// Authenticated but the vault is locked — offer unlock.
    case locked
    /// Ready to serve lookups. `account` is a display hint (e.g. the email).
    case ready(account: String?)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Outcome of a `lookup`. `notReady` carries the blocking status so the caller
/// can surface the right call-to-action instead of a generic failure.
enum CredentialLookupResult: Sendable {
    /// The query resolved to exactly one item. `matches` is kept for wire
    /// compatibility and is always 1 — a query fitting several items comes
    /// back as `.ambiguous`, never as an arbitrary pick.
    case found(CredentialItem, matches: Int)
    /// Several vault items fit the query. No secret is released; the caller
    /// gets the candidates' non-secret identities and must narrow the query
    /// (username or id). Deciding which account an agent gets is the user's
    /// call, and it has to happen BEFORE a secret crosses any boundary.
    case ambiguous([CredentialLookupCandidate])
    case notFound
    case notReady(CredentialProviderStatus)
}

/// The non-secret identity of one item in an ambiguous lookup — enough to
/// narrow the query, structurally incapable of carrying a secret. `type` and
/// `name` identify non-login items, which have no username to go by.
struct CredentialLookupCandidate: Sendable {
    var credentialId: String?
    var type: String?
    var name: String?
    var username: String?
    var uri: String?
    var domain: String?
}

/// A resolved credential. Every field is optional — a provider MAY return a
/// subset (username-only partial match, TOTP-only second-factor item), and
/// callers must tolerate any subset (protocol-v0 §5.2). Secret fields are
/// redacted; `debugDescription` reveals only which fields are *present*.
struct CredentialItem: Sendable {
    var credentialId: String?
    /// Wire item type: `login` / `note` / `card` / `identity` / `sshKey`.
    /// nil (an older helper) reads as login.
    var type: String?
    /// Vault item name — display identity, not a secret (like `username`).
    var name: String?
    var domain: String?
    var uri: String?
    var username: String?
    var password: RedactedSecret?
    var totp: RedactedSecret?
    var notes: RedactedSecret?
    /// Type-specific fields of cards, identities, and SSH keys, keyed by their
    /// wire names (`number`, `ssn`, `privateKey`, …). Uniformly redacted —
    /// several are secrets and none needs to be readable app-side.
    var typed: [String: RedactedSecret] = [:]

    /// Presence-only projection for the audit log — records which fields were
    /// released without ever recording their values (mirrors `ap-client`'s
    /// `CredentialFieldSet`).
    var fieldPresence: CredentialFieldSet {
        CredentialFieldSet(
            username: username?.isEmpty == false,
            password: password?.isEmpty == false,
            totp: totp?.isEmpty == false,
            uri: uri?.isEmpty == false,
            notes: notes?.isEmpty == false,
            typed: typed.keys.sorted()
        )
    }
}

/// Which fields a released credential carried — names and booleans only,
/// never values. `typed` lists the type-specific field names present.
struct CredentialFieldSet: Equatable, Sendable {
    var username = false
    var password = false
    var totp = false
    var uri = false
    var notes = false
    var typed: [String] = []
}

extension CredentialItem: CustomDebugStringConvertible {
    var debugDescription: String {
        let f = fieldPresence
        let present = [
            f.username ? "username" : nil,
            f.password ? "password" : nil,
            f.totp ? "totp" : nil,
            f.uri ? "uri" : nil,
            f.notes ? "notes" : nil,
        ].compactMap { $0 } + f.typed
        return "CredentialItem(type: \(type ?? "login"), fields: [\(present.joined(separator: ","))])"
    }
}

/// Redaction wrapper for secret strings. Prints `<redacted>` everywhere; the
/// plaintext is reachable only through the explicit `reveal()` call so a
/// grep for `.reveal(` surfaces every place a secret is actually consumed.
struct RedactedSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    init(_ value: String) { self.value = value }

    /// The plaintext. Call only at the point of use (fill, env injection).
    func reveal() -> String { value }

    var isEmpty: Bool { value.isEmpty }
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
}

/// Errors a provider raises. Structured so callers/UI can react (unlock prompt,
/// disambiguation) rather than parsing a message string.
enum CredentialProviderError: Error, LocalizedError {
    case notInstalled
    case loggedOut
    case locked
    case notReady(CredentialProviderStatus)
    case ambiguous
    /// The backend reported a failure (message is human-readable, not secret).
    case providerFailure(message: String)
    /// The transport to the helper process failed.
    case transport(message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Credential provider is not installed."
        case .loggedOut: return "Not logged in to the credential provider."
        case .locked: return "The vault is locked."
        case .notReady(let status): return "Credential provider not ready (\(status))."
        case .ambiguous: return "Multiple items matched the query."
        case .providerFailure(let message): return message
        case .transport(let message): return "Credential helper transport error: \(message)"
        }
    }
}
