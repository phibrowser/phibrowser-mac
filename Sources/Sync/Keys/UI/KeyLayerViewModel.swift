import CryptoKit
import Foundation

/// A local (on-disk) Chromium profile as offered to the pairing UI: the local
/// identity half of a local-profile <-> remote-profile pairing decision.
struct PairingLocal: Equatable, Identifiable {
    let profileId: String
    let displayName: String
    /// This device's Default profile (`LocalStore.defaultProfileId`), which may
    /// only pair with the account's default profile (docs/sync.md, "Profile
    /// pairing and the default profile").
    let isDefault: Bool
    var id: String { profileId }
}

/// State machine for the account key bootstrap / recovery-code join flow.
enum KeyLayerStrings {
    static let invalidRecoveryCode = NSLocalizedString("sync.setup.invalidRecoveryCode", value: "Check your recovery code and try again.", comment: "Sync recovery input rejected")
    static let connectionFailed = NSLocalizedString("sync.setup.connectionFailed", value: "Couldn’t connect to sync. Check your connection and try again.", comment: "Sync setup request failed")
    static let saveFailed = NSLocalizedString("sync.setup.saveFailed", value: "Couldn’t save sync setup on this device. Try again.", comment: "Sync setup - local enrollment or recovery confirmation could not be saved")
    static let signInRequired = NSLocalizedString("sync.setup.signInRequired", value: "Sign in again to continue setting up sync.", comment: "Sync setup authentication expired")
    static let tooManyJoinRequests = NSLocalizedString("sync.setup.tooManyJoinRequests", value: "Too many pending requests. Try again later or use a recovery code.", comment: "Sync setup error shown when the account already has too many pending requests to join from a new device")
}

/// Why a request to start sync over did not go ahead (docs/sync.md, "Starting over from a Mac
/// that is not set up for sync"). Each one has cleared the journal.
enum ResetRefusal: Equatable {
    /// 409 `devices_active` on the request or at execution, or a `blocked` status.
    case devicesActive(lastActiveAt: Date?)
    /// 409 `reset_request_exists`: another Mac's request is pending.
    case requestExists(executeAfter: Date?)
    case denied
    case expired
}

enum KeyLayerPhase: Equatable {
    case idle
    case introduction
    case readyToPair
    case showingRecoveryCode(String)
    case enteringRecoveryCode
    case confirmingRecoveryCode
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
    /// Starting over without the old data (docs/sync.md, "Starting over from a Mac that is not
    /// set up for sync"): the explanation page, the fresh sign-in in the browser, the waiting
    /// page, a refusal, and an error that keeps the journal for Retry.
    case resetExplanation
    case resetSigningIn
    case waitingForReset(executeAfter: Date)
    case resetRefused(ResetRefusal)
    case resetError(String)

    /// True while the window must not be closed by the user (review A9). `bootstrap()` has
    /// already initialized the account on the server by the time the recovery code is on
    /// screen; a second bootstrap is refused and there is no "regenerate". The confirmation
    /// page can come back here while the flow is open (`showRecoveryCodeAgain`), but closing
    /// the window without confirming would lose the code for good.
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
    /// The recovery code this flow's bootstrap displayed, held in memory only until it is
    /// verified or the flow is cancelled, so the confirmation page's Back button can show it
    /// again (feedback #248: "I've saved it" used to turn that page into a dead end). Never
    /// persisted or logged: it is key material. A reopened window or a restart starts a new
    /// model, which has nothing to return to.
    private var unconfirmedRecoveryCode: String?
    private let recoveryConfirmationRequired: @MainActor () -> Bool
    private let setRecoveryConfirmationRequired: @MainActor (Bool) throws -> Void
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
        guard !recoveryConfirmationRequired() else { phase = .confirmingRecoveryCode; return }
        recoveryInput = ""
        phase = .readyToPair
        onVerified?()
    }

    func cancelFlow() {
        // Closing the window during the fresh sign-in abandons it; the journal and any
        // request already on the server stay (Close keeps the request).
        let wasSigningIn = phase == .resetSigningIn
        cancelJoin()
        if wasSigningIn { cancelReauthentication() }
        pairingLoad?.cancel()
        recoveryInput = ""
        unconfirmedRecoveryCode = nil
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
         beginEnrollment: @escaping @MainActor () throws -> Void = { try ProfilePairingGate.shared.beginEnrollment() },
         recoveryConfirmationRequired: @escaping @MainActor () -> Bool = { ProfilePairingGate.shared.requiresRecoveryConfirmation },
         setRecoveryConfirmationRequired: @escaping @MainActor (Bool) throws -> Void = { try ProfilePairingGate.shared.setRecoveryConfirmationRequired($0) },
         resetJournal: SyncResetRequestJournalStore? = nil,
         reauthenticate: @escaping @MainActor () async -> InteractiveReauthenticationResult = { await AuthManager.shared.reauthenticateInteractively() },
         cancelReauthentication: @escaping @MainActor () -> Void = { AuthManager.shared.cancelOngoingWebAuthentication() },
         resetPollInterval: TimeInterval = 60) {
        self.resetJournal = resetJournal
        self.reauthenticate = reauthenticate
        self.cancelReauthentication = cancelReauthentication
        self.resetPollInterval = resetPollInterval
        self.recoveryConfirmationRequired = recoveryConfirmationRequired
        self.setRecoveryConfirmationRequired = setRecoveryConfirmationRequired
        self.beginEnrollment = beginEnrollment
        self.manager = manager
        self.loadDeadline = loadDeadline
    }

    /// Entry point when opening the key-layer window: unlock if possible, otherwise route to
    /// first-device bootstrap or the join-method choice.
    func beginSetup(controller: SyncKeyController? = nil) async {
        // Reopening or retrying a live host must not erase its only display of the code.
        guard !phase.requiresAcknowledgement else { return }
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
                accountExistsWithoutEnvelope = false
                discardResetJournalAfterEnrollment()
                if recoveryConfirmationRequired() { phase = .confirmingRecoveryCode }
                else if ProfilePairingGate.shared.isPaired { phase = .done }
                else { try beginEnrollment(); verified() }
            case .notSignedIn:
                phase = .error(KeyLayerStrings.signInRequired)
            case .needsJoin:
                // A journaled reset request wins: the window lands on its waiting page and
                // asks the server where the request stands.
                if let journal = resetJournal?.load() {
                    accountExistsWithoutEnvelope = true
                    resumeReset(journal)
                    await pollResetOnce()
                    return
                }
                let exists = try await manager.accountExists()
                guard generation == operationGeneration, flowIsCurrent else { return }
                accountExistsWithoutEnvelope = exists
                phase = exists ? (recoveryConfirmationRequired() ? .confirmingRecoveryCode : .chooseJoinMethod) : .introduction
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

    /// Retry from `.error` re-derives the route instead of assuming a join: the failure
    /// may have come from first-device bootstrap on an account no other device has
    /// initialized, where the join-method choice offers nothing that can work.
    func retrySetup() async {
        cancelJoin()
        await beginSetup(controller: flowController)
    }

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
        } catch JoinRequestError.tooManyPending {
            guard generation == operationGeneration, flowIsCurrent else { return }
            phase = .error(KeyLayerStrings.tooManyJoinRequests)
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
        guard !workingOperation, !phase.requiresAcknowledgement else { return }
        operationGeneration += 1
        let generation = operationGeneration
        workingOperation = true
        defer { if generation == operationGeneration { workingOperation = false } }
        phase = .working
        do {
            try beginEnrollment()
            try setRecoveryConfirmationRequired(true)
        } catch {
            phase = .error(KeyLayerStrings.saveFailed)
            return
        }
        do {
            let code = try await manager.bootstrap()
            guard generation == operationGeneration, flowIsCurrent else { return }
            createdAccountInThisFlow = true
            unconfirmedRecoveryCode = code
            phase = .showingRecoveryCode(code)
        } catch AccountKeyError.alreadyInitialized {
            guard generation == operationGeneration, flowIsCurrent else { return }
            accountExistsWithoutEnvelope = true
            do { try setRecoveryConfirmationRequired(false); phase = .chooseJoinMethod }
            catch { phase = .error(KeyLayerStrings.saveFailed) }
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            // No code reached the display. A lost PUT response can leave an
            // existing server account, but cannot truthfully require re-entry of
            // a code the user never saw. Retry uses the ordinary recovery route.
            do {
                try setRecoveryConfirmationRequired(false)
                phase = .error(KeyLayerStrings.connectionFailed)
            } catch { phase = .error(KeyLayerStrings.saveFailed) }
        }
    }

    func confirmSaved() async {
        guard case .showingRecoveryCode = phase else { return }
        recoveryInput = ""
        inputError = nil
        phase = .confirmingRecoveryCode
    }

    /// Whether the confirmation page can go back to the code display: only for the code THIS
    /// model showed, and only until it is verified. A model that reached the page from
    /// `beginSetup` (window reopened, restart) holds no code and offers re-entry alone.
    var canShowRecoveryCodeAgain: Bool {
        phase == .confirmingRecoveryCode && unconfirmedRecoveryCode != nil
    }

    /// Back from the confirmation page: re-displays the same code (nothing is regenerated)
    /// and pins the window again until the next "I've saved it". The durable pending flag
    /// is untouched, so sync stays off.
    func showRecoveryCodeAgain() {
        guard !workingOperation, phase == .confirmingRecoveryCode,
              let code = unconfirmedRecoveryCode else { return }
        recoveryInput = ""
        inputError = nil
        phase = .showingRecoveryCode(code)
    }

    func submitRecoveryCode(_ code: String) async {
        guard !workingOperation, !phase.requiresAcknowledgement else { return }
        operationGeneration += 1
        let generation = operationGeneration
        let confirming = phase == .confirmingRecoveryCode || recoveryConfirmationRequired()
        recoveryInput = code
        inputError = nil
        workingOperation = true
        phase = confirming ? .confirmingRecoveryCode : .enteringRecoveryCode
        defer { if generation == operationGeneration { workingOperation = false } }
        do {
            try beginEnrollment()
        } catch {
            inputError = KeyLayerStrings.saveFailed
            return
        }
        do {
            try await manager.joinWithRecoveryCode(code)
            guard generation == operationGeneration, flowIsCurrent else { return }
            if confirming {
                do { try setRecoveryConfirmationRequired(false) }
                catch { inputError = KeyLayerStrings.saveFailed; return }
            }
            unconfirmedRecoveryCode = nil
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

    // MARK: - Starting over without the old data (docs/sync.md, "Starting over from a Mac that is not set up for sync")

    /// The account's `sync.resetRequest` journal. Nil when the flow was built without one
    /// (previews, the pairing wizard's own key model); the third join choice is then hidden.
    private let resetJournal: SyncResetRequestJournalStore?
    /// `AuthManager.reauthenticateInteractively()`, injected so tests need no Auth0.
    private let reauthenticate: @MainActor () async -> InteractiveReauthenticationResult
    /// Ends a fresh sign-in still waiting in the browser; the pending `reauthenticate()` then
    /// answers `.cancelled`.
    private let cancelReauthentication: @MainActor () -> Void
    /// How often the waiting page asks the server where the request stands.
    private let resetPollInterval: TimeInterval
    /// Set when the account probe answered that the account exists while this Mac holds no
    /// envelope (`.needsJoin`), the only situation the third join choice is offered in.
    private var accountExistsWithoutEnvelope = false

    /// Whether the join-method page offers **Start over without the old data**.
    var canStartOver: Bool { resetJournal != nil && accountExistsWithoutEnvelope }

    /// The third join choice: withdraws any approval request this flow holds and shows the
    /// explanation page.
    func showStartOver() {
        guard canStartOver, !workingOperation else { return }
        cancelJoin()
        phase = .resetExplanation
    }

    /// Continue on the explanation page: the fresh sign-in, then the request.
    func continueStartOver() async {
        guard phase == .resetExplanation, !workingOperation else { return }
        await signInThenRequestReset(staleRetryLeft: true)
    }

    /// Cancel while the fresh sign-in waits in the browser: back to the explanation page.
    func cancelStartOverSignIn() {
        guard phase == .resetSigningIn else { return }
        operationGeneration += 1
        cancelReauthentication()
        inputError = nil
        phase = .resetExplanation
    }

    /// Back from the explanation, refusal and error pages. The journal is untouched: a request
    /// whose outcome is unknown stays journaled, and the next window opens on its waiting page.
    func leaveStartOver() {
        guard !workingOperation else { return }
        cancelJoin()
    }

    private func signInThenRequestReset(staleRetryLeft: Bool) async {
        operationGeneration += 1
        let generation = operationGeneration
        inputError = nil
        phase = .resetSigningIn
        let outcome = await reauthenticate()
        guard generation == operationGeneration, flowIsCurrent else { return }
        switch outcome {
        case .signedIn:
            await sendResetRequest(staleRetryLeft: staleRetryLeft)
        case .cancelled:
            phase = .resetExplanation
        case .wrongAccount:
            inputError = ResetRequestStrings.signInWrongAccount
            phase = .resetExplanation
        case .failed:
            inputError = ResetRequestStrings.signInFailed
            phase = .resetExplanation
        }
    }

    /// Withdraws this device's join tickets, journals the operation, then sends it: journal
    /// first, request second. A journal left by an earlier attempt whose outcome is unknown is
    /// sent again under the same operation, which the server replays.
    private func sendResetRequest(staleRetryLeft: Bool) async {
        guard let store = resetJournal else { return }
        operationGeneration += 1
        let generation = operationGeneration
        workingOperation = true
        defer { if generation == operationGeneration { workingOperation = false } }
        inputError = nil
        phase = .working
        do {
            try await manager.withdrawOutstandingJoinRequests()
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request: join withdrawal failed: \(PhiSyncLog.describe(error))")
            phase = .resetError(ResetRequestStrings.requestFailed)
            return
        }
        guard generation == operationGeneration, flowIsCurrent else { return }
        let journal: SyncResetRequestJournal
        do {
            if let existing = store.load() {
                journal = existing
            } else {
                journal = SyncResetRequestJournal(operationId: UUID(),
                                                  deviceKeyID: try manager.currentDeviceKeyId(),
                                                  createdAt: Date())
                try store.save(journal)
            }
        } catch {
            AppLogWarn("[phi-sync] reset request: journal write failed: \(PhiSyncLog.describe(error))")
            phase = .resetError(KeyLayerStrings.saveFailed)
            return
        }
        let operation = journal.operationId.uuidString.lowercased()
        do {
            let request = try await manager.requestSyncReset(operationId: journal.operationId,
                                                             deviceKeyId: journal.deviceKeyID)
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogInfo("[phi-sync] reset request \(operation) answered: \(request.status)")
            await apply(request, journal: journal, store: store, generation: generation)
        } catch ResetRequestError.staleAuthentication {
            // Nothing was created: the journal goes, and a second attempt is a new operation.
            store.clear()
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request \(operation) refused: stale_authentication; sign-in retry left: \(staleRetryLeft)")
            if staleRetryLeft {
                workingOperation = false
                await signInThenRequestReset(staleRetryLeft: false)
            } else {
                phase = .resetError(ResetRequestStrings.staleSignIn)
            }
        } catch ResetRequestError.devicesActive(let lastActiveAt, _) {
            store.clear()
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogInfo("[phi-sync] reset request \(operation) refused: devices_active")
            phase = .resetRefused(.devicesActive(lastActiveAt: lastActiveAt))
        } catch ResetRequestError.requestExists(let executeAfter) {
            store.clear()
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogInfo("[phi-sync] reset request \(operation) refused: reset_request_exists")
            phase = .resetRefused(.requestExists(executeAfter: executeAfter))
        } catch ResetRequestError.accountNotFound {
            // The account is already empty: first-device setup.
            store.clear()
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogInfo("[phi-sync] reset request \(operation) refused: account_not_found; routing to first-device setup")
            accountExistsWithoutEnvelope = false
            phase = .introduction
        } catch let error as ResetRequestError {
            // A definitive refusal (`device_known`, `reset_request_conflict`, 400): the server
            // holds nothing for this operation, so the journal goes and Retry starts afresh.
            store.clear()
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request \(operation) refused: \(error)")
            phase = .resetError(ResetRequestStrings.requestFailed)
        } catch {
            // Transport or server failure: the outcome is unknown, so the journal stays.
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request \(operation) failed: \(PhiSyncLog.describe(error))")
            phase = .resetError(ResetRequestStrings.requestFailed)
        }
    }

    /// Lands on the waiting page for a journaled request (window reopened, Retry) and starts the
    /// poll. Without a confirmed date the page waits for the first answer in `.working`.
    private func resumeReset(_ journal: SyncResetRequestJournal) {
        inputError = nil
        if let executeAfter = journal.executeAfter {
            phase = .waitingForReset(executeAfter: executeAfter)
            startResetPollTimer()
        } else {
            phase = .working
        }
    }

    /// One `GET /keys/v1/reset-requests/{operation}`: every 60 seconds while the waiting page
    /// is open, and on each (re)open.
    func pollResetOnce() async {
        guard let store = resetJournal, let journal = store.load(),
              !pollingInFlight, !workingOperation else { return }
        pollingInFlight = true
        defer { pollingInFlight = false }
        let generation = operationGeneration
        let operation = journal.operationId.uuidString.lowercased()
        do {
            let request = try await manager.syncResetStatus(operationId: journal.operationId)
            guard generation == operationGeneration, flowIsCurrent else { return }
            await apply(request, journal: journal, store: store, generation: generation)
        } catch ResetRequestError.notFound {
            // Gone with the account (another reset or a purge), or never created. The account
            // probe decides where setup goes from here.
            store.clear()
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogInfo("[phi-sync] reset request \(operation) not found; re-running the account probe")
            await rerunAccountProbe()
        } catch ResetRequestError.notRequester {
            store.clear()
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request \(operation) belongs to another device key; journal dropped")
            stopPolling()
            phase = .chooseJoinMethod
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request \(operation) status failed: \(PhiSyncLog.describe(error))")
            if let executeAfter = journal.executeAfter {
                if phase != .waitingForReset(executeAfter: executeAfter) {
                    phase = .waitingForReset(executeAfter: executeAfter)
                    startResetPollTimer()
                }
                inputError = KeyLayerStrings.connectionFailed
            } else {
                stopPolling()
                phase = .resetError(KeyLayerStrings.connectionFailed)
            }
        }
    }

    /// Acts on a request's status, from the `PUT`, a poll or a re-read after `not_pending`.
    private func apply(_ request: ResetRequestDTO, journal: SyncResetRequestJournal,
                       store: SyncResetRequestJournalStore, generation: Int) async {
        let operation = journal.operationId.uuidString.lowercased()
        inputError = nil
        switch request.status {
        case "pending":
            let confirmed = journal.confirmed(executeAfter: request.executeAfter,
                                              joinRequestId: request.joinRequestId)
            if confirmed != journal {
                do { try store.save(confirmed) }
                catch { AppLogWarn("[phi-sync] reset request \(operation): journal update failed: \(PhiSyncLog.describe(error))") }
            }
            if Date() >= request.executeAfter {
                await executeReset(confirmed, store: store, generation: generation)
            } else {
                if phase != .waitingForReset(executeAfter: request.executeAfter) {
                    phase = .waitingForReset(executeAfter: request.executeAfter)
                }
                if pollTimer == nil { startResetPollTimer() }
            }
        case "approved":
            await completeApprovedReset(journal: journal, joinRequestId: request.joinRequestId,
                                        executeAfter: request.executeAfter, store: store, generation: generation)
        case "denied":
            finishReset(store, operation: operation, status: request.status)
            phase = .resetRefused(.denied)
        case "blocked":
            finishReset(store, operation: operation, status: request.status)
            phase = .resetRefused(.devicesActive(lastActiveAt: nil))
        case "expired":
            finishReset(store, operation: operation, status: request.status)
            phase = .resetRefused(.expired)
        case "cancelled":
            finishReset(store, operation: operation, status: request.status)
            phase = .chooseJoinMethod
        case "executed":
            finishReset(store, operation: operation, status: request.status)
            await rerunAccountProbe()
        default:
            stopPolling()
            AppLogWarn("[phi-sync] reset request \(operation) has an unknown status: \(request.status)")
            phase = .resetError(ResetRequestStrings.requestFailed)
        }
    }

    /// A terminal status: the journal goes and the poll stops.
    private func finishReset(_ store: SyncResetRequestJournalStore, operation: String, status: String) {
        stopPolling()
        store.clear()
        AppLogInfo("[phi-sync] reset request \(operation) ended: \(status)")
    }

    /// An enrolled Mac said "Yes, it was me": it approved the request's join row, so this Mac
    /// completes the ordinary approved join (`verified()`), then pairing. Nothing is deleted.
    private func completeApprovedReset(journal: SyncResetRequestJournal, joinRequestId: String,
                                       executeAfter: Date, store: SyncResetRequestJournalStore,
                                       generation: Int) async {
        let operation = journal.operationId.uuidString.lowercased()
        stopPolling()
        do {
            try beginEnrollment()
        } catch {
            phase = .resetError(KeyLayerStrings.saveFailed)
            return
        }
        do {
            let result = try await manager.pollJoin(requestId: joinRequestId)
            guard generation == operationGeneration, flowIsCurrent else { return }
            switch result {
            case .approved:
                finishReset(store, operation: operation, status: "approved")
                verified()
            case .denied:
                finishReset(store, operation: operation, status: "denied")
                phase = .resetRefused(.denied)
            case .expired:
                finishReset(store, operation: operation, status: "expired")
                phase = .resetRefused(.expired)
            case .pending:
                phase = .waitingForReset(executeAfter: executeAfter)
                startResetPollTimer()
            }
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request \(operation): approved join failed: \(PhiSyncLog.describe(error))")
            phase = .waitingForReset(executeAfter: executeAfter)
            inputError = KeyLayerStrings.connectionFailed
            startResetPollTimer()
        }
    }

    /// `POST .../execute` once `execute_after` has passed. 200 and 404 both mean the account is
    /// empty: the journal goes and the account probe routes to first-device setup.
    private func executeReset(_ journal: SyncResetRequestJournal, store: SyncResetRequestJournalStore,
                              generation: Int) async {
        let operation = journal.operationId.uuidString.lowercased()
        stopPolling()
        workingOperation = true
        defer { if generation == operationGeneration { workingOperation = false } }
        phase = .working
        do {
            try await manager.executeSyncReset(operationId: journal.operationId, deviceKeyId: journal.deviceKeyID)
            finishReset(store, operation: operation, status: "executed")
            guard generation == operationGeneration, flowIsCurrent else { return }
            workingOperation = false
            await rerunAccountProbe()
        } catch ResetRequestError.notFound {
            finishReset(store, operation: operation, status: "executed (404)")
            guard generation == operationGeneration, flowIsCurrent else { return }
            workingOperation = false
            await rerunAccountProbe()
        } catch ResetRequestError.tooEarly(let serverExecuteAfter) {
            // Clock skew: keep waiting and show the server's date.
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogInfo("[phi-sync] reset request \(operation) execute refused: too_early")
            let executeAfter = serverExecuteAfter ?? journal.executeAfter ?? Date().addingTimeInterval(resetPollInterval)
            if let joinRequestId = journal.joinRequestId {
                try? store.save(journal.confirmed(executeAfter: executeAfter, joinRequestId: joinRequestId))
            }
            phase = .waitingForReset(executeAfter: executeAfter)
            startResetPollTimer()
        } catch ResetRequestError.devicesActive(let lastActiveAt, _) {
            finishReset(store, operation: operation, status: "blocked")
            guard generation == operationGeneration, flowIsCurrent else { return }
            phase = .resetRefused(.devicesActive(lastActiveAt: lastActiveAt))
        } catch ResetRequestError.notPending {
            // Resolved underneath (an approval or a denial won the race): read the status.
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogInfo("[phi-sync] reset request \(operation) execute refused: not_pending; re-reading the status")
            do {
                let request = try await manager.syncResetStatus(operationId: journal.operationId)
                guard generation == operationGeneration, flowIsCurrent else { return }
                guard request.status != "pending" else {
                    phase = .resetError(ResetRequestStrings.executeFailed)
                    return
                }
                workingOperation = false
                await apply(request, journal: journal, store: store, generation: generation)
            } catch {
                guard generation == operationGeneration, flowIsCurrent else { return }
                phase = .resetError(ResetRequestStrings.executeFailed)
            }
        } catch ResetRequestError.notRequester {
            finishReset(store, operation: operation, status: "not_requester")
            guard generation == operationGeneration, flowIsCurrent else { return }
            phase = .chooseJoinMethod
        } catch {
            // Unknown outcome: the journal stays and Retry asks again.
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request \(operation) execute failed: \(PhiSyncLog.describe(error))")
            phase = .resetError(ResetRequestStrings.executeFailed)
        }
    }

    /// The account probe again, as when the window opens: after the account was emptied it
    /// answers 404 and `beginSetup` routes to `.introduction`.
    private func rerunAccountProbe() async {
        stopPolling()
        await beginSetup(controller: flowController)
    }

    /// **Cancel request** on the waiting page. Answers that leave nothing to withdraw count as
    /// done (`AccountKeyManager.cancelSyncReset`); a transport failure keeps the request, the
    /// journal and the page.
    func cancelResetRequest() async {
        guard !workingOperation else { return }
        guard let store = resetJournal, let journal = store.load() else {
            cancelJoin()
            return
        }
        operationGeneration += 1
        let generation = operationGeneration
        workingOperation = true
        defer { if generation == operationGeneration { workingOperation = false } }
        stopPolling()
        inputError = nil
        let operation = journal.operationId.uuidString.lowercased()
        do {
            try await manager.cancelSyncReset(operationId: journal.operationId, deviceKeyId: journal.deviceKeyID)
            store.clear()
            AppLogInfo("[phi-sync] reset request \(operation) cancelled")
            guard generation == operationGeneration, flowIsCurrent else { return }
            workingOperation = false
            cancelJoin()
        } catch {
            guard generation == operationGeneration, flowIsCurrent else { return }
            AppLogWarn("[phi-sync] reset request \(operation) cancel failed: \(PhiSyncLog.describe(error))")
            inputError = ResetRequestStrings.cancelFailed
            startResetPollTimer()
        }
    }

    /// Try again on a start over error page: a journaled request whose creation was never
    /// confirmed is sent again under the same operation; a confirmed one is asked about; with
    /// no journal the flow starts again from the explanation.
    func retryReset() async {
        guard !workingOperation else { return }
        guard let journal = resetJournal?.load() else {
            inputError = nil
            phase = .resetExplanation
            return
        }
        if journal.executeAfter == nil {
            await sendResetRequest(staleRetryLeft: true)
        } else {
            resumeReset(journal)
            await pollResetOnce()
        }
    }

    /// The expired page's **Start over again**.
    func startOverAgain() {
        guard !workingOperation else { return }
        cancelJoin()
        phase = .resetExplanation
    }

    /// This Mac holds an envelope again (an approval completed, possibly in an earlier session
    /// that stopped before clearing): a journal left behind is withdrawn best effort and dropped.
    private func discardResetJournalAfterEnrollment() {
        guard let store = resetJournal, let journal = store.load() else { return }
        store.clear()
        AppLogInfo("[phi-sync] reset request \(journal.operationId.uuidString.lowercased()) dropped: this Mac is set up for sync")
        Task { [manager] in
            do { try await manager.cancelSyncReset(operationId: journal.operationId, deviceKeyId: journal.deviceKeyID) }
            catch { AppLogWarn("[phi-sync] leftover reset request withdrawal failed: \(PhiSyncLog.describe(error))") }
        }
    }

    private func startResetPollTimer() {
        stopPolling()
        let timer = Timer(timeInterval: resetPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .waitingForReset = self.phase else { return }
                await self.pollResetOnce()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
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
            }.map { PairingLocal(profileId: $0.profileId, displayName: $0.displayName,
                                 isDefault: $0.profileId == LocalStore.defaultProfileId) }
            let remotes = accountProfiles.filter { !claimedUuids.contains($0.uuid) }
            // More account defaults than the local Default can take: concurrent
            // first pairings each registered one. The extras are ordinary
            // profiles in the sheet (`ProfilePairingModel`). Metadata only (R12).
            let spareDefaults = remotes.filter { $0.isDefault == true }.count
                - (locals.contains(where: \.isDefault) ? 1 : 0)
            if spareDefaults > 0 {
                AppLogWarn("[phi-sync] default-identity conflict: \(spareDefaults) extra account default profile(s) offered as ordinary profiles")
            }
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
            phase = .error(NSLocalizedString("sync.pairing.error.profileLoadTimedOut",
                value: "Couldn’t load the account’s profiles in time. Check your connection and retry.",
                comment: "Profile matching - error shown when the account's profiles did not load in time"))
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
                        uuid: remoteUuid, forLocalProfile: localProfileId,
                        isDefault: localProfileId == LocalStore.defaultProfileId)
                case .registerNew(let localProfileId, let displayName):
                    _ = try await controller.profileKeys.registerLocalProfile(
                        profileId: localProfileId, displayName: displayName,
                        isDefault: localProfileId == LocalStore.defaultProfileId)
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
                        pairingError = String(format: NSLocalizedString("sync.pairing.error.createLocalProfileFailed",
                            value: "Couldn’t create a profile named “%@” on this Mac.",
                            comment: "Profile matching - error shown when a profile could not be created on this Mac; %@ is the profile name"), displayName)
                        continue
                    }
                }
            } catch ProfileKeyManagerError.alreadyMapped {
                // The sole new catch branch; R12 metadata only, no profileId or UUID.
                AppLogInfo("[phi-sync] pairing decision already applied; treating as done")
                continue
            } catch ProfileKeyManagerError.defaultMismatch {
                // The model never offers this pairing; the account changed under
                // the sheet (another device registered a default). The reload below
                // shows the current options. R12: metadata only.
                AppLogWarn("[phi-sync] a pairing decision broke the default-profile rule; refused")
                pairingError = NSLocalizedString("sync.pairing.error.defaultProfileMismatch",
                    value: "This Mac’s default profile can only be matched with the account’s default profile. Review the matches and try again.",
                    comment: "Profile matching - error shown when a chosen match would pair a default profile with a non-default one")
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
    func resetAccount(operationId: UUID, deviceKeyId: String) async throws {}
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
    func replaceProfileKeyEnvelope(uuid: String, expected: Data, envelope: Data) async throws -> Bool {
        throw URLError(.unsupportedURL)
    }
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool { true }
    func getDomainKey(domain: String) async throws -> Data? { nil }
    func putDomainKey(domain: String, envelope: Data) async throws -> Bool { true }
    func putResetRequest(operationId: UUID, deviceKeyId: String, publicKey: Data,
                         name: String, platform: String) async throws -> ResetRequestDTO {
        ResetRequestDTO(operationId: operationId.uuidString.lowercased(), status: "pending", createdAt: Date(),
                        executeAfter: Date().addingTimeInterval(48 * 3600), joinRequestId: "preview")
    }
    func getResetRequest(operationId: UUID) async throws -> ResetRequestDTO {
        throw ResetRequestError.notFound
    }
    func cancelResetRequest(operationId: UUID, deviceKeyId: String) async throws {}
    func executeResetRequest(operationId: UUID, deviceKeyId: String) async throws {}
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
