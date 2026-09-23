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
enum KeyLayerStrings {
    static let invalidRecoveryCode = NSLocalizedString("sync.setup.invalidRecoveryCode", value: "Check your recovery code and try again.", comment: "Sync recovery input rejected")
    static let connectionFailed = NSLocalizedString("sync.setup.connectionFailed", value: "Couldn’t connect to sync. Check your connection and try again.", comment: "Sync setup request failed")
    static let signInRequired = NSLocalizedString("sync.setup.signInRequired", value: "Sign in again to continue setting up sync.", comment: "Sync setup authentication expired")
}

enum KeyLayerPhase: Equatable {
    case idle
    case introduction
    case readyToPair
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

    /// True while the window must not be closed by the user (review A9). `bootstrap()` has
    /// already initialized the account on the server by the time the recovery code is on
    /// screen; it is shown exactly once, a second bootstrap is refused, and there is no
    /// "regenerate". Closing the window without confirming would lose it for good.
    var requiresAcknowledgement: Bool {
        if case .showingRecoveryCode = self { return true }
        return false
    }
}

/// Thrown when the pairing load runs past its deadline. Deliberately private
/// and deliberately NOT an `Error` any caller can catch by type: the only thing
/// downstream of it is `runPairingLoad`'s own mapping to a localized `.error`.
private struct PairingLoadTimedOut: Error {}

/// Drives the recovery-code UI: owns all state transitions and error mapping
/// so the SwiftUI views underneath it stay purely presentational.
@MainActor
final class KeyLayerViewModel: ObservableObject {
    @Published private(set) var phase: KeyLayerPhase = .idle
    /// Set when a pairing decision fails to apply (surfaced by `ProfilePairingView`
    /// while `phase` stays `.pairingProfiles`); cleared at the start of the next
    /// `submitPairing` call.
    @Published private(set) var pairingError: String?
    @Published private(set) var inputError: String?
    @Published var recoveryInput = ""
    @Published private(set) var workingOperation = false
    private var operationGeneration = 0
    private var pollingInFlight = false
    private(set) var createdAccountInThisFlow = false
    private let beginEnrollment: @MainActor () throws -> Void
    var onVerified: (@MainActor () -> Void)?

    private var flowIsCurrent: Bool { flowController?.isRetired != true }

    private func verified() {
        guard flowIsCurrent else { return }
        stopPolling()
        currentRequestId = nil
        guard flowController?.requiresReconfiguration != true else {
            phase = .error(SyncReconfigurationStrings.returnToSettings); return
        }
        recoveryInput = ""
        phase = .readyToPair
        onVerified?()
    }

    func cancelFlow() {
        cancelJoin()
        pairingLoad?.cancel()
        recoveryInput = ""
    }

    /// True for the whole of `submitPairing`, from the first decision to the last.
    ///
    /// `.working` is not only the pairing load's phase: a submit holds it too,
    /// across every `adoptRemoteProfile` / `registerLocalProfile` /
    /// `createLocalProfileAndAdopt` await, while mutating the very mapping table
    /// a load reads to decide which locals are still unmapped. So the two flows
    /// are made MUTUALLY EXCLUSIVE, not merely load-versus-load: `startPairing`
    /// refuses while this is set, and the gate modal greys its retry button on it.
    ///
    /// Without that, the load's `.pairingProfiles` write would land on top of a
    /// submit -- offering "Register as new" for a local the submit is in the
    /// middle of adopting (whose next submit then throws `alreadyMapped`), or
    /// reverting a finished modal to a stale candidate list. And it needs no
    /// user at all to happen: the gate re-drives a presented modal on every
    /// `.measured` announcement, and a `.createLocal` decision provokes one
    /// itself by creating a profile.
    ///
    /// `@Published` because the modal's retry button reads it: a plain stored
    /// property would leave the button greyed until the next `phase` change.
    @Published private(set) var isSubmitting = false

    private let manager: AccountKeyManager
    private var currentRequestId: String?
    private var pollTimer: Timer?
    private var joinPollTask: Task<JoinPollResult, Error>?
    /// The shared controller for the duration of this setup flow, captured when
    /// the flow opens (`beginSetup(controller:)`). Every terminal transition to
    /// `.done` re-runs `resolveMappings()` on it so a profile established in
    /// this session (bootstrap, recovery-code join, or approval join) registers
    /// immediately, instead of only on the next app launch's startup resolve.
    /// Held only for the short life of the flow, so it cannot go stale against
    /// a sign-out/sign-in controller rebuild; nil in tests and when signed out.
    private var flowController: SyncKeyController?

    /// The pairing load currently in flight, so a second `startPairing` can
    /// CANCEL AND REPLACE it instead of running two loads at once. A cancelled
    /// load is forbidden to write `phase`, so only the newest one ever lands.
    private var pairingLoad: Task<Void, Never>?

    /// How long `startPairing` waits for the account's profiles before giving
    /// up. `URLSession.shared`'s default timeout is 60 s PER REQUEST, so an
    /// unbounded load could sit in `.working` for minutes; the modal needs an
    /// answer -- even a failure -- well inside a user's patience. Injectable so
    /// tests do not have to wait for it.
    private let loadDeadline: Duration

    init(manager: AccountKeyManager, loadDeadline: Duration = .seconds(45),
         beginEnrollment: @escaping @MainActor () throws -> Void = { try ProfilePairingGate.shared.beginEnrollment() }) {
        self.beginEnrollment = beginEnrollment
        self.manager = manager
        self.loadDeadline = loadDeadline
    }

    /// Entry point when opening the key-layer window: unlock if possible, otherwise route to
    /// first-device bootstrap or the join-method choice.
    func beginSetup(controller: SyncKeyController? = nil) async {
        flowController = controller
        guard controller?.requiresReconfiguration != true else {
            phase = .error(SyncReconfigurationStrings.returnToSettings); return
        }
        operationGeneration += 1
        let generation = operationGeneration
        phase = .working
        do {
            let result = try await manager.unlockAtStartup()
            guard generation == operationGeneration, flowIsCurrent else { return }
            switch result {
            case .unlocked:
                if ProfilePairingGate.shared.isPaired { phase = .done }
                else { try beginEnrollment(); verified() }
            case .notSignedIn:
                phase = .error(KeyLayerStrings.signInRequired)
            case .needsJoin:
                let exists = try await manager.accountExists()
                guard generation == operationGeneration, flowIsCurrent else { return }
                phase = exists ? .chooseJoinMethod : .introduction
            }
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            phase = .error(KeyLayerStrings.connectionFailed)
        }
    }

    func continueSetup() async { await startBootstrap() }

    func showRecoveryEntry() {
        cancelJoin()
        inputError = nil
        phase = .enteringRecoveryCode
    }
    func chooseJoinAgain() { cancelJoin() }

    func startJoinRequest() async {
        guard !workingOperation else { return }
        operationGeneration += 1
        let generation = operationGeneration
        workingOperation = true
        defer { if generation == operationGeneration { workingOperation = false } }
        phase = .working
        do {
            try beginEnrollment()
            let ticket = try await manager.requestJoinApproval()
            guard generation == operationGeneration, flowIsCurrent else {
                withdrawJoinRequest(ticket.requestId)
                return
            }
            currentRequestId = ticket.requestId
            phase = .waitingForApproval(code: ticket.verificationCode, deadline: Date().addingTimeInterval(900))
            startPollTimer()
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            phase = .error(KeyLayerStrings.connectionFailed)
        }
    }

    func pollOnce() async {
        guard let id = currentRequestId, !pollingInFlight else { return }
        pollingInFlight = true
        defer { pollingInFlight = false; joinPollTask = nil }
        let generation = operationGeneration
        let task = Task { try await manager.pollJoin(requestId: id) }
        joinPollTask = task
        do {
            let result = try await task.value
            guard generation == operationGeneration, currentRequestId == id, flowIsCurrent else { return }
            inputError = nil
            switch result {
            case .approved: verified()
            case .denied: stopPolling(); phase = .joinDenied
            case .expired: stopPolling(); phase = .joinExpired
            case .pending(let deadline):
                if Date() > deadline { stopPolling(); phase = .joinExpired }
                else if case .waitingForApproval(let code, _) = phase {
                    phase = .waitingForApproval(code: code, deadline: deadline)
                }
            }
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            inputError = KeyLayerStrings.connectionFailed
        }
    }

    func cancelJoin() {
        operationGeneration += 1
        workingOperation = false
        stopPolling()
        joinPollTask?.cancel()
        if let id = currentRequestId { withdrawJoinRequest(id) }
        currentRequestId = nil
        inputError = nil
        phase = .chooseJoinMethod
    }

    private func withdrawJoinRequest(_ id: String) {
        // Keep cleanup alive after the window/model closes. It can only withdraw this
        // ticket; a later flow's replacement must not be affected by a delayed response.
        Task { [manager] in
            do { try await manager.cancelJoinApproval(requestId: id) }
            catch { AppLogWarn("[phi-sync] join withdrawal failed: \(PhiSyncLog.describe(error))") }
        }
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
        guard !workingOperation else { return }
        operationGeneration += 1
        let generation = operationGeneration
        workingOperation = true
        defer { if generation == operationGeneration { workingOperation = false } }
        phase = .working
        do {
            try beginEnrollment()
            let code = try await manager.bootstrap()
            guard generation == operationGeneration, flowIsCurrent else { return }
            createdAccountInThisFlow = true
            phase = .showingRecoveryCode(code)
        } catch AccountKeyError.alreadyInitialized {
            guard generation == operationGeneration, flowIsCurrent else { return }
            phase = .chooseJoinMethod
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            phase = .error(KeyLayerStrings.connectionFailed)
        }
    }

    func confirmSaved() async {
        guard case .showingRecoveryCode = phase else { return }
        verified()
    }

    func submitRecoveryCode(_ code: String) async {
        guard !workingOperation else { return }
        operationGeneration += 1
        let generation = operationGeneration
        recoveryInput = code
        inputError = nil
        workingOperation = true
        phase = .enteringRecoveryCode
        defer { if generation == operationGeneration { workingOperation = false } }
        do {
            try beginEnrollment()
            try await manager.joinWithRecoveryCode(code)
            guard generation == operationGeneration, flowIsCurrent else { return }
            verified()
        } catch AccountKeyError.badRecoveryCode {
            guard generation == operationGeneration, flowIsCurrent else { return }
            inputError = KeyLayerStrings.invalidRecoveryCode
        } catch KeyAPIError.http(401, _) {
            guard generation == operationGeneration, flowIsCurrent else { return }
            inputError = KeyLayerStrings.signInRequired
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            inputError = KeyLayerStrings.connectionFailed
        }
    }

    // MARK: - Semi-automatic profile pairing (M2-4 Task 5)

    /// Loads the still-unmapped local profiles and the still-unclaimed remote
    /// (account-registered) profiles and moves to `.pairingProfiles` so the
    /// user can resolve the ambiguous mapping by hand.
    ///
    /// Existing mappings claim only UUIDs present in the freshly fetched account list.
    /// After a server reset, old persisted mappings must not hide local profiles from
    /// matching. Loading only classifies candidates; adoption/registration updates the
    /// mapping after the user confirms. Valid mappings still exclude both sides to avoid
    /// duplicate registration or local creation.
    ///
    /// Pressing "retry" while a load is still in flight CANCELS AND REPLACES it:
    /// the modal's retry button is pressable in every phase now (it used to be
    /// disabled in exactly the `.working` phase a stalled load sits in), and the
    /// gate re-drives an already-presented modal, so this can be called again at
    /// any moment. The method still does not return until the load it installed
    /// has finished, because every caller -- `submitPairing`'s failure reload,
    /// the retry button, the modal host, the Devices pane -- reads `phase`
    /// straight after awaiting it.
    ///
    /// A load started while `submitPairing` is applying decisions would not be a
    /// replacement but a SECOND writer of `phase` and a reader of a half-written
    /// mapping table, so that one case is turned away instead (see
    /// `isSubmitting`). The submit's own reload is not affected: it clears the
    /// flag before reloading, because that reload is its continuation.
    func cancelPairingLoad() { pairingLoad?.cancel(); pairingLoad = nil }

    func startPairing(controller: SyncKeyController) async {
        guard !isSubmitting else {
            // Metadata only (R12).
            AppLogInfo("[phi-sync] pairing load skipped; a submit is still applying decisions")
            return
        }
        pairingLoad?.cancel()
        phase = .working
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runPairingLoad(controller: controller)
        }
        pairingLoad = task
        await task.value
    }

    /// One pairing load, bounded by `loadDeadline` and safe to cancel.
    ///
    /// EVERY write of `phase` here is guarded by a cancellation check taken in
    /// the same synchronous stretch: a load that has been replaced must not
    /// land its (stale, or merely cancelled) result on top of its replacement's.
    private func runPairingLoad(controller: SyncKeyController) async {
        guard !Task.isCancelled else { return }
        let profileKeys = controller.profileKeys
        do {
            let accountProfiles = try await withDeadline(loadDeadline) {
                try await profileKeys.accountProfiles()
            }
            guard !Task.isCancelled, !controller.isRetired else { return }
            let remoteUuids = Set(accountProfiles.map(\.uuid))
            let allLocals = controller.localProfiles()
            let claimedUuids = Set(allLocals.compactMap {
                profileKeys.mappedGlobalUuid(forProfileId: $0.profileId)
            }).intersection(remoteUuids)
            let locals = allLocals.filter {
                guard let uuid = profileKeys.mappedGlobalUuid(forProfileId: $0.profileId) else { return true }
                return !remoteUuids.contains(uuid)
            }.map { PairingLocal(profileId: $0.profileId, displayName: $0.displayName) }
            let remotes = accountProfiles.filter { !claimedUuids.contains($0.uuid) }
            // The modal is the second writer of the undecryptable set (§3.6's
            // per-round refresh is the first): a row whose envelope did not open
            // here is read-only and must not make the gate think there is
            // something the user could still decide.
            for remote in remotes where remote.name == nil {
                controller.noteUndecryptableRemote(remote.uuid)
            }
            for remote in remotes where remote.name != nil {
                controller.noteDecryptableRemote(remote.uuid)
            }
            AppLogInfo("[phi-sync] pairing load finished; \(locals.count) local, \(remotes.count) remote candidates")
            phase = .pairingProfiles(locals: locals, remotes: remotes)
        } catch is PairingLoadTimedOut {
            guard !Task.isCancelled else { return }
            AppLogWarn("[phi-sync] pairing load exceeded its \(loadDeadline) deadline")
            phase = .error(NSLocalizedString(
                "Couldn’t load the account’s profiles in time. Check your connection and retry.",
                comment: "Pairing - load timeout"))
        } catch {
            guard !Task.isCancelled else { return }
            // R12: log detailed errors only; show fixed localized text, not interpolated Swift errors without
            // catalog keys.
            AppLogWarn("[phi-sync] pairing load failed: \(PhiSyncLog.describe(error))")
            phase = .error(PairingWizardStrings.profileLoadFailed)
        }
    }

    /// Races `body` against `deadline`. The loser is cancelled either way, so a
    /// deadline that lands really does take the in-flight request down with it
    /// rather than leaving it running behind an error screen.
    private func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil   // the deadline landed first
            }
            // The first child to finish decides; `next()` rethrows a real
            // failure from `body` unchanged, which is what keeps every existing
            // error path (`notUnlocked`, transport, HTTP) reading as it did.
            while let result = try await group.next() {
                group.cancelAll()
                guard let result else { throw PairingLoadTimedOut() }
                return result
            }
            throw PairingLoadTimedOut()
        }
    }

    /// Apply pairing decisions; return true on success, otherwise set pairingError, reload candidates and
    /// return false. This first half extracted from submitPairing owns isSubmitting's exclusion window while
    /// decisions apply (:45-64).
    ///
    /// createLocal first creates the on-disk profile via the bridge, then adopts the remote identity; failed
    /// creation surfaces an error and keeps pairingProfiles instead of done. This method exclusively writes
    /// phase during submission: reject new startPairing loads and cancel any already in flight, including the
    /// gate's periodic modal refresh.
    ///
    /// Idempotency (§5.1 / §10.6 item 4): ProfileKeyManagerError.alreadyMapped means done. Retry replays
    /// frozen profileDecisions after Space failure through backToSpaces → spaces → Finish.
    /// registerLocalProfile refuses still-valid mappings, while initialSelections seeds unmatched locals
    /// as registerNew, making this replay normal. Treating it as error would trap the wizard in step 1
    /// forever. SpaceSyncMappingError.alreadyMapped follows the same rule. adoptRemoteProfile already
    /// overwrites idempotently.
    ///
    /// createLocal needs its own branch guard: it never throws alreadyMapped, and reusablePendingProfile
    /// covers only creation followed by failed adoption. Successful adoption clears the pending entry, so
    /// unguarded replay creates a duplicate X (2).
    @discardableResult
    func applyPairingDecisions(_ decisions: [PairingDecision],
                               controller: SyncKeyController) async -> Bool {
        isSubmitting = true
        defer { isSubmitting = false }
        pairingLoad?.cancel()
        phase = .working
        pairingError = nil
        for decision in decisions {
            guard !controller.isRetired else { return false }
            do {
                switch decision {
                case .adopt(let localProfileId, let remoteUuid):
                    _ = try await controller.profileKeys.adoptRemoteProfile(
                        uuid: remoteUuid, forLocalProfile: localProfileId)
                case .registerNew(let localProfileId, let displayName):
                    _ = try await controller.profileKeys.registerLocalProfile(
                        profileId: localProfileId, displayName: displayName)
                case .createLocal(let remoteUuid, let displayName):
                    // Idempotency (§5.1): an account UUID already mapped locally is done. Retry replays frozen
                    // decisions after Space failure; successful adoption cleared reusablePendingProfile, so
                    // recreating would persist an extra X (2) profile even though the later UUID-claimed guard
                    // keeps mappings correct.
                    //
                    // Guard at the decision layer, not createLocalProfileAndAdopt: automatic creation (§3.6)
                    // uses missing UUIDs and cannot reach this case. A shared early return would add an
                    // unreachable branch there and falsely increment created counts.
                    if controller.localProfileId(forGlobalUuid: remoteUuid) != nil {
                        // R12: metadata only, no profileId or UUID.
                        AppLogInfo("[phi-sync] pairing decision already applied; treating as done")
                        continue
                    }
                    // One shared implementation with §3.6's auto-create
                    // (`createLocalProfileAndAdopt`); only the `phase` /
                    // `pairingError` state machine stays here, and the direct
                    // `ProfileManager` dependency moves back into the key layer.
                    do {
                        _ = try await controller.createLocalProfileAndAdopt(
                            uuid: remoteUuid, displayName: displayName)
                    } catch ProfileKeyManagerError.badEnvelope {
                        // The one throw that means "the bridge did not make a
                        // profile"; the generic catch below would render it as
                        // raw enum text in the modal.
                        pairingError = String(format: NSLocalizedString(
                            "Couldn’t create a profile named “%@” on this Mac.",
                            comment: "Pairing - local profile creation failed"), displayName)
                        continue
                    }
                }
            } catch ProfileKeyManagerError.alreadyMapped {
                // The sole new catch branch; R12 metadata only, no profileId or UUID.
                AppLogInfo("[phi-sync] pairing decision already applied; treating as done")
                continue
            } catch {
                AppLogWarn("[phi-sync] a pairing decision failed: \(PhiSyncLog.describe(error))")
                pairingError = PairingWizardStrings.profileDecisionFailed
            }
        }
        guard pairingError == nil else {
            // Reload so the view reflects whatever succeeded before the
            // failure, and stay in .pairingProfiles for another attempt.
            // Clear the flag FIRST: this reload is the submit's own tail, not a
            // competing load, and `startPairing` would otherwise turn it away
            // and leave the modal parked in `.working` for good.
            isSubmitting = false
            await startPairing(controller: controller)
            return false
        }
        return true
    }

    /// Legacy Profile-only entry applies decisions and returns to the unified pairing flow.
    /// It cannot complete enrollment; the wizard owns the full Profile/Space obligation.
    ///
    /// The intentional failure-path change is idempotent success for repeated alreadyMapped submissions.
    /// Rendering, strings, button predicates and ProfilePairingModel inputs/decisions remain unchanged. Normal
    /// Devices UI already filters mapped locals in runPairingLoad (:277-280); only tests can resubmit that
    /// state, so testAFailedSubmitStillReloadsTheCandidatesInsteadOfParkingInWorking now uses a one-time PUT
    /// failure.
    func submitPairing(_ decisions: [PairingDecision], controller: SyncKeyController) async {
        guard await applyPairingDecisions(decisions, controller: controller), !controller.isRetired else { return }
        phase = .readyToPair
    }

    /// Whether every row the user CAN decide has been decided. Rows whose remote
    /// envelope will not open (`name == nil`) are excluded: they are read-only,
    /// both of their decisions would throw inside `adoptRemoteProfile`, and
    /// counting them would leave a modal that can never be closed.
    ///
    /// It takes only the REMOTE rows: a local row always has a decision (the
    /// picker's `registerNew` is its default and `startPairing` seeds it), so
    /// `locals` would be an unused parameter -- and an unused parameter in an
    /// enable predicate reads like a check that is happening and is not.
    /// `claimedRemoteUuids` / `createLocalUuids` are the view's own
    /// `@State selections` / `remoteChoices`, projected to uuid sets.
    func allRowsDecided(remotes: [RemoteProfile],
                        claimedRemoteUuids: Set<String>,
                        createLocalUuids: Set<String>) -> Bool {
        let decidableRemotes = remotes.filter { $0.name != nil }
        return !decidableRemotes.contains {
            !claimedRemoteUuids.contains($0.uuid) && !createLocalUuids.contains($0.uuid)
        }
    }
}

#if DEBUG
// MARK: - Preview support

/// No-op `KeyEnvelopeAPI` fake used only to drive SwiftUI previews for the two
/// key-layer views without touching the network.
struct PreviewKeyEnvelopeAPI: KeyEnvelopeAPI {
    func listDevices() async throws -> [AccountDeviceDTO] { [] }
    func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool { true }
    func getAccount() async throws -> AccountKeyStateDTO? { nil }
    func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {}
    func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? { nil }
    func revokeDevice(deviceKeyId: String) async throws {}
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
    func getDomainKey(domain: String) async throws -> Data? { nil }
    func putDomainKey(domain: String, envelope: Data) async throws -> Bool { true }
}

/// No-op `DeviceKeyProviding` fake used only to drive SwiftUI previews for the
/// two key-layer views without touching the Keychain.
struct PreviewDeviceKeyProvider: DeviceKeyProviding {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey { privateKey }
    func deviceKeyId() throws -> String { "preview-device" }
    func rotate() throws {}
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
