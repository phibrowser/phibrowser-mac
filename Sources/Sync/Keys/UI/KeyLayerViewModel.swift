import CryptoKit
import Foundation

/// State machine for the account key bootstrap / recovery-code join flow.
enum KeyLayerPhase: Equatable {
    case idle
    case showingRecoveryCode(String)
    case enteringRecoveryCode
    case working
    case done
    case error(String)
}

/// Drives the recovery-code UI: owns all state transitions and error mapping
/// so the SwiftUI views underneath it stay purely presentational.
@MainActor
final class KeyLayerViewModel: ObservableObject {
    @Published private(set) var phase: KeyLayerPhase = .idle

    private let manager: AccountKeyManager

    init(manager: AccountKeyManager) {
        self.manager = manager
    }

    /// Starts account bootstrap, generating a new recovery code. If the account
    /// was already initialized by another device, routes to the join flow instead.
    func startBootstrap() async {
        phase = .working
        do {
            phase = .showingRecoveryCode(try await manager.bootstrap())
        } catch AccountKeyError.alreadyInitialized {
            phase = .enteringRecoveryCode
        } catch {
            phase = .error("\(error)")
        }
    }

    /// Confirms the user saved the displayed recovery code, completing bootstrap.
    func confirmSaved() {
        guard case .showingRecoveryCode = phase else { return }
        phase = .done
    }

    /// Joins the account using a recovery code entered by the user.
    func submitRecoveryCode(_ code: String) async {
        phase = .working
        do {
            try await manager.joinWithRecoveryCode(code)
            phase = .done
        } catch {
            phase = .error(NSLocalizedString(
                "Invalid recovery code. Please check it and try again.",
                comment: "Key layer recovery code entry - error shown when the entered code is rejected"))
        }
    }
}

#if DEBUG
// MARK: - Preview support

/// No-op `KeyEnvelopeAPI` fake used only to drive SwiftUI previews for the two
/// key-layer views without touching the network.
struct PreviewKeyEnvelopeAPI: KeyEnvelopeAPI {
    func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool { true }
    func getAccount() async throws -> AccountKeyStateDTO? { nil }
    func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {}
    func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? { nil }
    func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String { "preview" }
    func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO] { [] }
    func getJoinRequest(id: String) async throws -> JoinRequestDTO {
        JoinRequestDTO(requestId: id, requestingPublicKey: Data(), name: "", platform: "macos",
                       status: "pending", grantedArkEnvelope: Data(), createdAt: Date(), resolvedByDeviceKeyId: nil)
    }
    func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws {}
    func denyJoinRequest(id: String) async throws {}
}

/// No-op `DeviceKeyProviding` fake used only to drive SwiftUI previews for the
/// two key-layer views without touching the Keychain.
struct PreviewDeviceKeyProvider: DeviceKeyProviding {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey { privateKey }
    func deviceKeyId() throws -> String { "preview-device" }
}

extension KeyLayerViewModel {
    /// A view model backed entirely by in-memory preview fakes, for `#Preview` use.
    static func preview() -> KeyLayerViewModel {
        KeyLayerViewModel(manager: AccountKeyManager(
            api: PreviewKeyEnvelopeAPI(),
            deviceKeyProvider: PreviewDeviceKeyProvider()))
    }
}
#endif
