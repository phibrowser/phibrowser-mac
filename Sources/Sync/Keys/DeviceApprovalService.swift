import CryptoKit
import Foundation

enum DeviceApprovalError: Error { case notUnlocked }

/// A pending device-join request, ready to present for approval.
struct PendingApproval: Identifiable, Equatable {
    let id: String
    let name: String
    let platform: String
    let verificationCode: String
    let deadline: Date
    let requestingPublicKey: Data
}

/// Approver-side orchestration: lists pending join requests and, for an already-unlocked
/// device, admits a new device by sealing the in-memory ARK to its public key.
final class DeviceApprovalService {
    private let api: KeyEnvelopeAPI
    private let keyManager: AccountKeyManager
    private let deviceKeyProvider: DeviceKeyProviding

    init(api: KeyEnvelopeAPI, keyManager: AccountKeyManager, deviceKeyProvider: DeviceKeyProviding) {
        self.api = api
        self.keyManager = keyManager
        self.deviceKeyProvider = deviceKeyProvider
    }

    func listPendingApprovals() async throws -> [PendingApproval] {
        try await api.listPendingJoinRequests().map { s in
            PendingApproval(id: s.requestId, name: s.name, platform: s.platform,
                verificationCode: PhiKeyCrypto.verificationCode(forPublicKey: s.requestingPublicKey),
                deadline: s.createdAt.addingTimeInterval(15 * 60),
                requestingPublicKey: s.requestingPublicKey)
        }
    }

    func approve(_ approval: PendingApproval) async throws {
        guard let ark = keyManager.currentARK else { throw DeviceApprovalError.notUnlocked }
        let arkBytes = ark.withUnsafeBytes { Data($0) }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: approval.requestingPublicKey)
        let envelope = try PhiKeyCrypto.sealToPublicKey(arkBytes, recipient: recipient)
        try await api.approveJoinRequest(id: approval.id, grantedArkEnvelope: envelope,
            resolvedByDeviceKeyId: try deviceKeyProvider.deviceKeyId())
    }

    func deny(_ approval: PendingApproval) async throws {
        try await api.denyJoinRequest(id: approval.id)
    }
}
