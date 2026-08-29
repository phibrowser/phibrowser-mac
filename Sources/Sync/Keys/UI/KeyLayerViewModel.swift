import CryptoKit
import Foundation

/// A local (on-disk) Chromium profile as offered to the pairing UI: the local
/// identity half of a local-profile <-> remote-profile pairing decision.
struct PairingLocal: Equatable, Identifiable {
    let profileId: String
    let displayName: String
    var id: String { profileId }
}

/// State machine for the account key bootstrap / recovery-code join flow.
enum KeyLayerPhase: Equatable {
    case idle
    case showingRecoveryCode(String)
    case enteringRecoveryCode
    case chooseJoinMethod
    case waitingForApproval(code: String, deadline: Date)
    case joinDenied
    case joinExpired
    case working
    case done
    case error(String)
    /// Semi-automatic pairing (M2-4 Task 5): more than one unmapped local
    /// profile and more than one unclaimed remote profile — `resolveMappings()`
    /// can't disambiguate on its own, so the user picks.
    case pairingProfiles(locals: [PairingLocal], remotes: [RemoteProfile])
}

/// Drives the recovery-code UI: owns all state transitions and error mapping
/// so the SwiftUI views underneath it stay purely presentational.
@MainActor
final class KeyLayerViewModel: ObservableObject {
    @Published private(set) var phase: KeyLayerPhase = .idle
    /// Set when a pairing decision fails to apply (surfaced by `ProfilePairingView`
    /// while `phase` stays `.pairingProfiles`); cleared at the start of the next
    /// `submitPairing` call.
    @Published private(set) var pairingError: String?

    private let manager: AccountKeyManager
    private var currentRequestId: String?
    private var pollTimer: Timer?

    init(manager: AccountKeyManager) {
        self.manager = manager
    }

    /// Entry point when opening the key-layer window: unlock if possible, otherwise route to
    /// first-device bootstrap or the join-method choice.
    func beginSetup() async {
        phase = .working
        do {
            switch try await manager.unlockAtStartup() {
            case .unlocked:
                phase = .done
            case .notSignedIn:
                phase = .error(NSLocalizedString("You’re not signed in.",
                    comment: "Key layer - not signed in"))
            case .needsJoin:
                phase = try await manager.accountExists() ? .chooseJoinMethod : .working
                if case .working = phase { await startBootstrap() }
            }
        } catch {
            phase = .error("\(error)")
        }
    }

    func showRecoveryEntry() { phase = .enteringRecoveryCode }
    func chooseJoinAgain() { phase = .chooseJoinMethod }

    /// Requests approval from another device, then begins polling for the outcome.
    func startJoinRequest() async {
        phase = .working
        do {
            let ticket = try await manager.requestJoinApproval()
            currentRequestId = ticket.requestId
            phase = .waitingForApproval(code: ticket.verificationCode, deadline: Date().addingTimeInterval(900))
            startPollTimer()
        } catch let e as JoinRequestError where e == .tooManyPending {
            phase = .error(NSLocalizedString("Too many pending requests. Try again later or use a recovery code.",
                comment: "Key layer - too many pending join requests"))
        } catch {
            phase = .error("\(error)")
        }
    }

    /// One poll iteration (also called directly by tests).
    func pollOnce() async {
        guard let id = currentRequestId else { return }
        do {
            switch try await manager.pollJoin(requestId: id) {
            case .approved: stopPolling(); phase = .done
            case .denied:   stopPolling(); phase = .joinDenied
            case .expired:  stopPolling(); phase = .joinExpired
            case .pending(let deadline):
                if Date() > deadline { stopPolling(); phase = .joinExpired }
                else if case .waitingForApproval(let code, _) = phase {
                    phase = .waitingForApproval(code: code, deadline: deadline)
                }
            }
        } catch {
            // Transient poll failure: keep waiting; the next tick retries.
        }
    }

    func cancelJoin() {
        stopPolling()
        currentRequestId = nil
        phase = .chooseJoinMethod
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPollTimer() {
        stopPolling()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
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

    // MARK: - Semi-automatic profile pairing (M2-4 Task 5)

    /// Loads the still-unmapped local profiles and the still-unclaimed remote
    /// (account-registered) profiles and moves to `.pairingProfiles` so the
    /// user can resolve the ambiguous mapping by hand.
    ///
    /// Both sides are filtered by the persisted mapping rather than shown
    /// whole. An already-mapped local must not appear here: every row offers
    /// "Register as new", which `ProfileKeyManager.registerLocalProfile` now
    /// refuses with `alreadyMapped` for a mapped profile — and rightly so,
    /// since minting a second UUID would orphan that profile's existing
    /// envelope. Excluding the remotes those locals already claim likewise
    /// keeps the "create on this Mac" toggle from duplicating a profile that
    /// is in fact already present.
    func startPairing(controller: SyncKeyController) async {
        phase = .working
        do {
            let allLocals = controller.localProfiles()
            let claimedUuids = Set(allLocals.compactMap {
                controller.profileKeys.mappedGlobalUuid(forProfileId: $0.profileId)
            })
            let locals = allLocals
                .filter { controller.profileKeys.mappedGlobalUuid(forProfileId: $0.profileId) == nil }
                .map { PairingLocal(profileId: $0.profileId, displayName: $0.displayName) }
            let remotes = try await controller.profileKeys.accountProfiles()
                .filter { !claimedUuids.contains($0.uuid) }
            phase = .pairingProfiles(locals: locals, remotes: remotes)
        } catch {
            phase = .error("\(error)")
        }
    }

    /// Applies the user's pairing decisions, then re-runs `resolveMappings()`
    /// so the controller's resolved cache (and `needsPairing`) reflect the new
    /// mappings. `.createLocal` creates the on-disk profile first (via the
    /// bridge) and adopts the remote onto the resulting profileId; if that
    /// creation fails, the decision is skipped and its error is surfaced
    /// while staying on `.pairingProfiles` rather than moving to `.done`.
    func submitPairing(_ decisions: [PairingDecision], controller: SyncKeyController) async {
        phase = .working
        pairingError = nil
        for decision in decisions {
            do {
                switch decision {
                case .adopt(let localProfileId, let remoteUuid):
                    _ = try await controller.profileKeys.adoptRemoteProfile(
                        uuid: remoteUuid, forLocalProfile: localProfileId)
                case .registerNew(let localProfileId, let displayName):
                    _ = try await controller.profileKeys.registerLocalProfile(
                        profileId: localProfileId, displayName: displayName)
                case .createLocal(let remoteUuid, let displayName):
                    let newProfileId = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                        ProfileManager.shared.createProfile(displayName: displayName) { profileId in
                            continuation.resume(returning: profileId)
                        }
                    }
                    guard let newProfileId else {
                        pairingError = String(format: NSLocalizedString(
                            "Couldn’t create a profile named “%@” on this Mac.",
                            comment: "Pairing - local profile creation failed"), displayName)
                        continue
                    }
                    _ = try await controller.profileKeys.adoptRemoteProfile(
                        uuid: remoteUuid, forLocalProfile: newProfileId)
                }
            } catch {
                pairingError = "\(error)"
            }
        }
        guard pairingError == nil else {
            // Reload so the view reflects whatever succeeded before the
            // failure, and stay in .pairingProfiles for another attempt.
            await startPairing(controller: controller)
            return
        }
        await controller.resolveMappings()
        phase = .done
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
    func listProfiles() async throws -> [ProfileSummaryDTO] { [] }
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? { nil }
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool { true }
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
