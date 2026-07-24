// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Why the deletion flow stopped, in terms the presentation layer can turn
/// into copy. Service errors keep their domain meaning; anything else the
/// injected calls throw (transport failures, cancelled URL tasks, ...)
/// collapses to `network`.
enum AccountDeletionFlowError: Equatable {
    case service(AccountDeletionServiceError)
    case network

    /// Whether the failed attempt may still have landed server-side. Only
    /// these outcomes replay an idempotency key on retry — network trouble
    /// and 5xx, the two reuse cases the Oblivion contract names. A
    /// definitive rejection booked nothing under the key, and a server that
    /// memoizes responses per key would replay the same error forever, so
    /// retries after one must mint a fresh key.
    var isIndeterminate: Bool {
        switch self {
        case .network, .service(.serverError):
            return true
        case .service:
            return false
        }
    }
}

/// Drives the account deletion flow as a plain state machine. It owns no UI:
/// dialogs observe `onStateChange` and render whatever the state says, so
/// the whole flow can be driven by unit tests without AppKit or a modal
/// run loop.
///
/// Every side effect enters through an injected closure whose default points
/// at the real implementation, mirroring `TimeMachineRestoreCoordinator`.
/// In debug builds the Oblivion edges and the credential renewal consult
/// `AccountDeletionFakeResponses` first, so the *DEBUG* menu can play any
/// server behavior through this same seam without touching the network.
/// The destructive edges (credential clearing, local data clearing, quit)
/// and the Sentinel announcement are deliberately real even in fake mode:
/// playing the success scenario end to end exercises the whole finalize —
/// including the startup takeover — without a deletable account.
@MainActor
final class AccountDeletionCoordinator {
    typealias RequestDeletion = (_ idempotencyKey: String) async throws -> AccountDeletionRequestOutcome
    typealias VerifyDeletion = (_ requestID: String, _ code: String) async throws -> Void
    /// Renews the access token after the service rejected it; returns
    /// whether usable credentials came back, deciding the one retry.
    typealias RenewCredentials = () async -> Bool
    /// Announces the deletion to Sentinel: stops the watchdog (so a
    /// Sentinel that chooses to exit is not resurrected), then posts the
    /// Account Deleted Event. Fire-and-forget — no wait, no retry.
    typealias AnnounceAccountDeleted = @MainActor () -> Void
    /// Returns false when the shared-token lock or durable credential fence
    /// is unavailable; the finalize must not notify Sentinel, suspend, or
    /// quit.
    typealias BeginCredentialDeletion = @MainActor () -> Bool
    typealias ClearInitialCredentials = () async -> Void
    typealias ClearCredentials = () async -> Void
    /// Removes everything Phi keeps on this Mac outside the credential
    /// layer. Async because the WKWebView website-data clearing only
    /// reports completion through a callback.
    typealias ClearLocalData = () async -> Void
    typealias Quit = () -> Void

    enum State: Equatable {
        case idle
        /// First Oblivion call in flight; the UI shows progress and blocks
        /// re-triggers.
        case requestingDeletion
        /// A verification code is on its way to the account email. A failed
        /// verification lands back here with the failure inline: the dialog
        /// stays alive and the user re-enters the code in place — restarting
        /// the flow instead would email a fresh code and burn send quota.
        case awaitingVerificationCode(requestID: String, error: AccountDeletionFlowError?)
        /// Second Oblivion call in flight; doubles as the double-submit guard.
        case verifyingCode(requestID: String)
        /// The deletion task is queued server-side. The finalize confirmation
        /// comes next; the flow never claims the deletion itself completed.
        case requestSubmitted
        /// A previously accepted deletion is already running server-side, so
        /// no verification code was sent. The finalize confirmation comes
        /// next, exactly as after `requestSubmitted` — the two states share
        /// one finalize.
        case deletionAlreadyRunning
        /// The user confirmed the finalize step: both clears are running and
        /// the process quits once they finish. Terminal — cancel is
        /// impossible here, and nothing renders after the quit.
        case finalizing
        /// The first step failed. `start()` may be called again to retry; the
        /// idempotency key is kept across indeterminate failures so a retry
        /// never double-books, and minted fresh after definitive rejections.
        case failed(AccountDeletionFlowError)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Fired on every transition, on the main actor.
    var onStateChange: ((State) -> Void)?

    /// Oblivion refuses verification emails sent less than a minute apart, so
    /// the resend edge stays locked this long after every send.
    static let resendCooldown: TimeInterval = 60

    /// When the resend edge unlocks; nil before any code was sent. Updated
    /// alongside the matching state transition, so observers reading it from
    /// `onStateChange` always see the current deadline. The dialog derives
    /// its countdown from this; `resendCode()` enforces it independently.
    private(set) var resendAvailableAt: Date?

    private let requestDeletion: RequestDeletion
    private let verifyDeletion: VerifyDeletion
    private let renewCredentials: RenewCredentials
    private let announceAccountDeleted: AnnounceAccountDeleted
    private let beginCredentialDeletion: BeginCredentialDeletion
    private let clearInitialCredentials: ClearInitialCredentials
    private let clearCredentials: ClearCredentials
    private let clearLocalData: ClearLocalData
    private let quit: Quit
    private let now: () -> Date
    private let makeIdempotencyKey: () -> String

    /// The key of the most recent first-step attempt — `start()` and
    /// `resendCode()` both record theirs here. Survives an indeterminate
    /// first-step failure (network, 5xx) so a `start()` retry replays the
    /// same key and Oblivion dedupes instead of double-booking; a definitive
    /// rejection clears it — nothing was booked under the key, and a server
    /// that memoizes responses per key would otherwise replay the same error
    /// forever. Cleared on cancel: starting over means the user re-confirmed
    /// the warning, which is where a fresh key belongs. A resend normally
    /// mints a new key; the indeterminate-outcome exception lives in
    /// `pendingResendKey`.
    private var idempotencyKey: String?

    /// A resend key whose attempt ended without a definitive server response
    /// (timeout, connection loss, 5xx). The next resend replays it, per the
    /// Oblivion contract: the lost attempt may have landed server-side, and
    /// the replay recovers its request instead of double-booking a new one
    /// (and a new email). Cleared on any definitive first-step outcome and
    /// on cancel — definitive rejections mint a fresh key next time, in
    /// case the server memoizes error responses per key.
    private var pendingResendKey: String?

    init(
        requestDeletion: @escaping RequestDeletion = { idempotencyKey in
#if DEBUG
            if let scenario = await AccountDeletionFakeResponses.scenario {
                return try await AccountDeletionFakeResponses.playRequest(scenario)
            }
#endif
            return try await APIClient.shared.requestAccountDeletion(idempotencyKey: idempotencyKey)
        },
        verifyDeletion: @escaping VerifyDeletion = { requestID, code in
#if DEBUG
            if let scenario = await AccountDeletionFakeResponses.scenario {
                return try await AccountDeletionFakeResponses.playVerify(scenario, code: code)
            }
#endif
            try await APIClient.shared.verifyAccountDeletion(requestID: requestID, code: code)
        },
        renewCredentials: @escaping RenewCredentials = {
#if DEBUG
            if let scenario = await AccountDeletionFakeResponses.scenario {
                return await AccountDeletionFakeResponses.playRenewCredentials(scenario)
            }
#endif
            // Forcing an exchange here is off the table: surplus renewals
            // can exceed Auth0's rotation overlap window and destroy the
            // token family (see AuthManager). Instead, compare tokens around
            // the renewal attempt: its preflight hands the cached
            // credentials back untouched when no renewal is due, and
            // reporting that as "not renewed" skips a retry that would just
            // replay the rejected token. The before-read is the raw
            // in-memory credential — the renewing accessors would refresh an
            // expired token right here and defeat the comparison.
            let tokenBeforeRenewal = await MainActor.run {
                AuthManager.shared.currentCredentials?.accessToken
            }
            let renewed = await AuthManager.shared.renewCredentialsAsync(
                operation: "account deletion"
            )
            return AccountDeletionCoordinator.renewalProducedFreshCredentials(
                tokenBeforeRenewal: tokenBeforeRenewal,
                renewedAccessToken: renewed?.accessToken
            )
        },
        announceAccountDeleted: @escaping AnnounceAccountDeleted = {
            // The watchdog stop must precede the post, following the
            // intentional-shutdown convention: Sentinel may respond to the
            // event by exiting, and must not be resurrected when it does.
            SentinelWatchdog.shared.stop()
            SentinelHelper.postAccountDeletedEvent()
        },
        beginCredentialDeletion: @escaping BeginCredentialDeletion = {
            // Persist the crash-recovery fence and freeze credential writers
            // before Sentinel is notified. No suspension is allowed between
            // this and the announcement.
            return AuthManager.shared.beginAccountDeletionFinalization()
        },
        clearInitialCredentials: @escaping ClearInitialCredentials = {
            // The signed event has captured the account identity. Clear both
            // credential stores without posting the ordinary token-change
            // notification, which could otherwise race Sentinel's verifier.
            await AuthManager.shared.clearInitialAccountDeletionCredentials()
        },
        clearCredentials: @escaping ClearCredentials = {
            // Local-only by design (2026-07-23 decision) — unlike logout,
            // no remote Auth0 `clearSession` runs here. The deletion is
            // queued server-side, so the remote web session dies with the
            // account anyway; the external-browser teardown would flash
            // the default browser right before the quit, and a callback
            // arriving after the quit would relaunch the freshly wiped
            // Phi. The account-deletion fence already cleared credentials
            // before the long-running local-data removal; this final clear
            // verifies the stores again and posts the ordinary shared-token
            // change notification.
            await AuthManager.shared.clearLocalAccountData()
        },
        clearLocalData: @escaping ClearLocalData = {
            await AccountDeletionLocalDataRemoval.removeAll()
        },
        quit: @escaping Quit = {
            // The quit must be unstoppable: both clears already ran, so a
            // quit vetoed by a page's beforeunload prompt, the
            // confirm-to-quit preference, or the downloads-in-progress alert
            // would strand the user in a signed-out browser whose data is
            // already moved aside. `NSApp.terminate` walks all three veto
            // points, so exit the process directly instead. Skipping the
            // graceful shutdown loses nothing here: everything it would
            // write lands in the moved-aside directories (or is swept by
            // the detached cleaner) — it is exactly the data being deleted.
            exit(0)
        },
        now: @escaping () -> Date = Date.init,
        makeIdempotencyKey: @escaping () -> String = AccountDeletionCoordinator.defaultIdempotencyKey
    ) {
        self.requestDeletion = requestDeletion
        self.verifyDeletion = verifyDeletion
        self.renewCredentials = renewCredentials
        self.announceAccountDeleted = announceAccountDeleted
        self.beginCredentialDeletion = beginCredentialDeletion
        self.clearInitialCredentials = clearInitialCredentials
        self.clearCredentials = clearCredentials
        self.clearLocalData = clearLocalData
        self.quit = quit
        self.now = now
        self.makeIdempotencyKey = makeIdempotencyKey
    }

    /// Oblivion expects idempotency keys as lowercase UUID v4.
    nonisolated static func defaultIdempotencyKey() -> String {
        UUID().uuidString.lowercased()
    }

    /// Whether a renewal attempt actually produced different credentials.
    /// `renewCredentialsAsync`'s preflight hands the cached credentials back
    /// untouched when no renewal is due; treating that as "renewed" would
    /// retry with the very token the service just rejected. A nil before
    /// value always counts as fresh: with nothing cached, any credentials
    /// the renewal produced are worth the one retry.
    nonisolated static func renewalProducedFreshCredentials(
        tokenBeforeRenewal: String?,
        renewedAccessToken: String?
    ) -> Bool {
        guard let renewedAccessToken else { return false }
        return renewedAccessToken != tokenBeforeRenewal
    }

    /// Kicks off the flow after the user confirmed the warning, or retries a
    /// failed first step. Ignored in any other state: multiple settings tabs
    /// or a double click must not produce a second request — and a second
    /// emailed code.
    func start() async {
        switch state {
        case .idle, .failed:
            break
        case .requestingDeletion, .awaitingVerificationCode, .verifyingCode,
             .requestSubmitted, .deletionAlreadyRunning, .finalizing:
            AppLogInfo("🗑️ [AccountDeletion] Flow already underway, ignoring start")
            return
        }

        state = .requestingDeletion
        let key = idempotencyKey ?? makeIdempotencyKey()
        idempotencyKey = key
        do {
            acceptFirstStepOutcome(try await retryingAfterTokenRenewal { try await self.requestDeletion(key) })
        } catch {
            AppLogError("🗑️ [AccountDeletion] Deletion request failed: \(error)")
            let flowError = Self.flowError(from: error)
            if !flowError.isIndeterminate {
                // Mirrors `pendingResendKey`: a retry from `.failed` must
                // mint a fresh key after a definitive rejection.
                idempotencyKey = nil
            }
            state = .failed(flowError)
        }
    }

    /// Re-runs the first step to email a fresh code. Only valid while a code
    /// is awaited and the cooldown has lapsed — the UI disables the button
    /// during the cooldown, and the guard here keeps a stale click from
    /// burning a send. A resend is protocol-wise a brand-new request, so it
    /// normally mints a fresh idempotency key and verification continues
    /// with the new request ID; a resend that got no definitive response is
    /// the exception and is replayed under its own key (see
    /// `pendingResendKey`). On failure the flow falls back to code entry
    /// with the error inline, the original request still usable — but the
    /// cooldown re-arms anyway: a timed-out attempt may have landed
    /// server-side, so an immediate re-click could break the one-minute
    /// send spacing.
    func resendCode() async {
        guard case .awaitingVerificationCode(let currentRequestID, _) = state else {
            AppLogInfo("🗑️ [AccountDeletion] No verification pending, ignoring resend")
            return
        }
        if let availableAt = resendAvailableAt, now() < availableAt {
            AppLogInfo("🗑️ [AccountDeletion] Resend still cooling down, ignoring")
            return
        }

        let key = pendingResendKey ?? makeIdempotencyKey()
        idempotencyKey = key
        state = .requestingDeletion
        do {
            acceptFirstStepOutcome(try await retryingAfterTokenRenewal { try await self.requestDeletion(key) })
        } catch {
            AppLogError("🗑️ [AccountDeletion] Resend failed for request \(currentRequestID): \(error)")
            let flowError = Self.flowError(from: error)
            pendingResendKey = flowError.isIndeterminate ? key : nil
            resendAvailableAt = now().addingTimeInterval(Self.resendCooldown)
            state = .awaitingVerificationCode(
                requestID: currentRequestID,
                error: flowError
            )
        }
    }

    /// The success side of the first step, shared by `start()` and
    /// `resendCode()` — a sent code always arms the cooldown alongside the
    /// state transition. Only the failure handling differs between the two
    /// callers.
    private func acceptFirstStepOutcome(_ outcome: AccountDeletionRequestOutcome) {
        pendingResendKey = nil
        switch outcome {
        case .verificationCodeSent(let requestID):
            AppLogInfo("🗑️ [AccountDeletion] Verification code sent for request \(requestID)")
            resendAvailableAt = now().addingTimeInterval(Self.resendCooldown)
            state = .awaitingVerificationCode(requestID: requestID, error: nil)
        case .deletionAlreadyRunning:
            AppLogInfo("🗑️ [AccountDeletion] Deletion already running server-side, skipping verification")
            state = .deletionAlreadyRunning
        }
    }

    /// Submits the emailed verification code. Only valid while a code is
    /// awaited; the in-flight state rejects a second submission. A failure
    /// returns to code entry with the error inline — the request (and its
    /// emailed code) stays valid, so nothing is restarted.
    func submitCode(_ code: String) async {
        guard case .awaitingVerificationCode(let requestID, _) = state else {
            AppLogInfo("🗑️ [AccountDeletion] No verification pending, ignoring code submission")
            return
        }

        state = .verifyingCode(requestID: requestID)
        do {
            try await retryingAfterTokenRenewal { try await self.verifyDeletion(requestID, code) }
            AppLogInfo("🗑️ [AccountDeletion] Deletion request \(requestID) queued")
            state = .requestSubmitted
        } catch {
            AppLogError("🗑️ [AccountDeletion] Verification failed for request \(requestID): \(error)")
            state = .awaitingVerificationCode(requestID: requestID, error: Self.flowError(from: error))
        }
    }

    /// Abandons the flow with no side effects: nothing was cleared, so
    /// cancelling is always safe. Ignored while a call is in flight (the UI
    /// disables cancel there) and once the deletion is booked server-side —
    /// submitted, or found already running — where the account is going
    /// away regardless and the only way forward is the finalize.
    func cancel() {
        switch state {
        case .awaitingVerificationCode, .failed:
            AppLogInfo("🗑️ [AccountDeletion] Flow cancelled")
            idempotencyKey = nil
            pendingResendKey = nil
            resendAvailableAt = nil
            state = .idle
        case .idle, .requestingDeletion, .verifyingCode, .requestSubmitted,
             .deletionAlreadyRunning, .finalizing:
            AppLogInfo("🗑️ [AccountDeletion] Cancel ignored in current state")
        }
    }

    /// Runs the finalize after the user confirmed it on the submitted or
    /// already-running dialog: the credential layer is fenced, the deletion
    /// is announced to Sentinel, credentials and on-disk data are cleared,
    /// credentials are verified clear again, then the process force-quits.
    /// Only valid once the deletion is booked server-side; the immediate
    /// `.finalizing` transition doubles as the re-entry guard, so a double
    /// click cannot start another finalize sequence.
    ///
    /// The durable fence is persisted immediately before the Sentinel
    /// announcement, with no suspension between them. The shared token is
    /// still readable for the event, and a crash after Sentinel accepts it
    /// cannot leave the browser able to restore deleted credentials.
    ///
    /// The credential fence runs before the local-data clear's long
    /// suspensions (the WKWebView sweep), so reopening Phi during cleanup
    /// cannot restore the deleted account from Auth0's local keychain. The
    /// final clear catches an in-flight Auth0 write, and the durable fence
    /// makes a crash fail closed on the next launch.
    func finalizeDeletion() async {
        switch state {
        case .requestSubmitted, .deletionAlreadyRunning:
            break
        case .idle, .requestingDeletion, .awaitingVerificationCode,
             .verifyingCode, .finalizing, .failed:
            AppLogInfo("🗑️ [AccountDeletion] No deletion booked server-side, ignoring finalize")
            return
        }
        let bookedState = state
        state = .finalizing
        guard beginCredentialDeletion() else {
            state = bookedState
            AppLogError(
                "🗑️ [AccountDeletion] Credential safety preflight unavailable; finalize remains pending"
            )
            return
        }
        announceAccountDeleted()
        await clearInitialCredentials()
        await clearLocalData()
        await clearCredentials()
        quit()
    }

    /// Runs an Oblivion call and, when the access token is rejected, renews
    /// the credentials and retries exactly once — the flow spans user
    /// think-time, so a token can expire mid-flow without the user doing
    /// anything wrong. A failed renewal, or a second rejection, surfaces as
    /// `unauthorized`, which the dialog turns into sign-in-again guidance.
    private func retryingAfterTokenRenewal<T>(
        _ call: () async throws -> T
    ) async throws -> T {
        do {
            return try await call()
        } catch AccountDeletionServiceError.unauthorized {
            AppLogInfo("🗑️ [AccountDeletion] Access token rejected; renewing credentials and retrying once")
            guard await renewCredentials() else {
                throw AccountDeletionServiceError.unauthorized
            }
            return try await call()
        }
    }

    private static func flowError(from error: Error) -> AccountDeletionFlowError {
        if let serviceError = error as? AccountDeletionServiceError {
            return .service(serviceError)
        }
        return .network
    }
}
