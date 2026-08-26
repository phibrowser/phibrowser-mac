import Foundation

/// Builds the production-wired key stack (real /keys/v1 client + Keychain device key).
/// A factory rather than a shared singleton: the Devices settings surface owns one stack
/// for its lifetime, so no app-global sync state is introduced.
enum SyncKeyStack {
    static func make() -> (manager: AccountKeyManager, approvals: DeviceApprovalService) {
        let api = KeyEnvelopeAPIClient(tokenProvider: { AuthManager.shared.getAccessTokenSyncly() })
        let store = DeviceKeyStore()
        let manager = AccountKeyManager(api: api, deviceKeyProvider: store)
        let approvals = DeviceApprovalService(api: api, keyManager: manager, deviceKeyProvider: store)
        return (manager, approvals)
    }
}
