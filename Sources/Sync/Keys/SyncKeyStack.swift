import Foundation

/// Builds the production-wired key stack (real /keys/v1 client + Keychain device key).
/// A factory, not a shared singleton: as of M2-4 the stack is owned app-scoped by
/// `SyncKeyController`, which `PhiChromiumCoordinator` builds and holds for the app's
/// lifetime; the Devices settings pane consumes that shared instance rather than
/// building its own. Callers that need a stack outside that shared instance (e.g. a
/// signed-out fallback) can still build one through this factory directly.
enum SyncKeyStack {
    /// `accountId == nil` keeps the pre-M3-2 fixed Keychain item. The Devices
    /// pane can be opened with no account signed in, so this is a real case and
    /// not a convenience default.
    static func make(accountId: String?) -> (api: KeyEnvelopeAPIClient, manager: AccountKeyManager, approvals: DeviceApprovalService) {
        // Bound to the account the stack was built for (PR #145 review, P1 "bind key API
        // requests to the stack's account identity"): a multi-request key flow — bootstrap is
        // `PUT /keys/v1/account` then `POST /keys/v1/devices` — can be suspended across a
        // sign-out of A and a sign-in as B, and a provider that reads "whoever is signed in
        // now" would send its next request with B's bearer token and A's key material. A
        // request for a stack whose account is no longer current gets no token, and
        // `KeyEnvelopeAPIClient` refuses to send it. Token renewal within the same account is
        // unaffected: the id is compared, not the token.
        let api = KeyEnvelopeAPIClient(tokenProvider: {
            boundToken(stackAccountId: accountId,
                       currentAccountId: AccountController.shared.account?.userID,
                       token: AuthManager.shared.getAccessTokenSyncly())
        })
        let store = DeviceKeyStore(accountId: accountId)
        let manager = AccountKeyManager(api: api, deviceKeyProvider: store)
        let approvals = DeviceApprovalService(api: api, keyManager: manager, deviceKeyProvider: store)
        return (api, manager, approvals)
    }

    /// The token a request from a stack built for `stackAccountId` may carry. A stack bound
    /// to an account gets the token only while that account is the signed-in one; a stack
    /// built with no account (the signed-out Devices pane) is not bound and passes the token
    /// through. Pure, so the rule is testable without the singletons.
    static func boundToken(stackAccountId: String?, currentAccountId: String?, token: String?) -> String? {
        guard let stackAccountId else { return token }
        return stackAccountId == currentAccountId ? token : nil
    }
}
