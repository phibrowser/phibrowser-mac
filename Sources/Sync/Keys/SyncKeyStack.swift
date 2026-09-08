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
        let api = KeyEnvelopeAPIClient(tokenProvider: { AuthManager.shared.getAccessTokenSyncly() })
        let store = DeviceKeyStore(accountId: accountId)
        let manager = AccountKeyManager(api: api, deviceKeyProvider: store)
        let approvals = DeviceApprovalService(api: api, keyManager: manager, deviceKeyProvider: store)
        return (api, manager, approvals)
    }
}
