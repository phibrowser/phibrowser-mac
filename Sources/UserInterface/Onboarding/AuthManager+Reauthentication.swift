// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Auth0
import Foundation

enum AuthReauthenticationReason: String, Equatable {
    case invalidRefreshToken = "invalid_refresh_token"
    case refreshTokenDeleted = "refresh_token_deleted"
}

enum AuthReauthenticationState: Equatable {
    case normal
    case required(
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date,
        incidentID: UUID
    )
    case reauthenticating(
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date,
        incidentID: UUID
    )

    var requiredDetails: (
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date,
        incidentID: UUID
    )? {
        switch self {
        case let .required(reason, firstDetectedAt, incidentID),
             let .reauthenticating(reason, firstDetectedAt, incidentID):
            return (reason, firstDetectedAt, incidentID)
        case .normal:
            return nil
        }
    }
}

/// Ensures only the latest Web Auth attempt can commit a reauthentication result.
struct AuthReauthenticationAttemptState {
    private(set) var currentID: UUID?

    mutating func begin() -> UUID {
        let attemptID = UUID()
        currentID = attemptID
        return attemptID
    }

    mutating func finishIfCurrent(_ attemptID: UUID) -> Bool {
        guard currentID == attemptID else {
            return false
        }
        currentID = nil
        return true
    }
}

enum AuthReauthenticationWebAuthRunner {
    /// Cancels and registers the replacement transaction without yielding the main actor.
    @MainActor
    static func run<Output, Failure: Error>(
        replacingActiveSession: Bool,
        cancel: () -> Void,
        start: (@escaping (Result<Output, Failure>) -> Void) -> Void
    ) async throws -> Output {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Output, Error>) in
            let completionLock = NSLock()
            var completed = false

            let finish: (Result<Output, Failure>) -> Void = { result in
                completionLock.lock()
                guard !completed else {
                    completionLock.unlock()
                    return
                }
                completed = true
                completionLock.unlock()

                switch result {
                case .success(let output):
                    continuation.resume(returning: output)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            if replacingActiveSession {
                cancel()
            }
            start(finish)
        }
    }
}

private struct PersistedAuthReauthenticationState {
    let reason: AuthReauthenticationReason
    let firstDetectedAt: Date
    let incidentID: UUID
}

extension AuthManager {
    var requiresReauthentication: Bool {
        reauthenticationState.requiredDetails != nil || hasPersistedReauthenticationState
    }

    func hasReauthenticationGraceSession() -> Bool {
        reauthenticationState.requiredDetails != nil || hasPersistedReauthenticationState
    }

    func restorePersistedReauthenticationStateIfNeeded(
        promptIfDue: Bool,
        trigger: String
    ) {
        guard reauthenticationState.requiredDetails == nil else {
            return
        }

        guard let persisted = persistedReauthenticationState() else {
            hasPersistedReauthenticationState = false
            return
        }

        hasPersistedReauthenticationState = true
        reauthenticationState = .required(
            reason: persisted.reason,
            firstDetectedAt: persisted.firstDetectedAt,
            incidentID: persisted.incidentID
        )

        if promptIfDue {
            Task { @MainActor [weak self] in
                self?.promptForReauthenticationIfNeeded(trigger: trigger)
            }
        }
    }

    @MainActor
    func enterReauthenticationRequiredState(reason: AuthReauthenticationReason) {
        let now = Date()
        hydrateAccountForReauthenticationIfNeeded()
        restorePersistedReauthenticationStateIfNeeded(
            promptIfDue: false,
            trigger: "renew_failed"
        )
        let existing = reauthenticationState.requiredDetails
        let persisted = existing == nil ? persistedReauthenticationState() : nil
        let firstDetectedAt = existing?.firstDetectedAt ?? persisted?.firstDetectedAt ?? now
        let incidentID = existing?.incidentID ?? persisted?.incidentID ?? UUID()

        recordTrace(
            "reauthentication-required",
            details: [
                "reason": reason.rawValue,
                "firstDetectedAt": iso8601String(firstDetectedAt),
                "incidentID": incidentID.uuidString
            ],
            callStackSymbols: Array(Thread.callStackSymbols.prefix(16))
        )

        pauseRenewalForReauthentication()

        reauthenticationState = .required(
            reason: reason,
            firstDetectedAt: firstDetectedAt,
            incidentID: incidentID
        )
        persistReauthenticationState(
            reason: reason,
            firstDetectedAt: firstDetectedAt,
            incidentID: incidentID
        )

        // Upload the full logs once per incident, not again for a restored pending session.
        if existing == nil {
            reportReauthenticationRequired(
                reason: reason,
                firstDetectedAt: firstDetectedAt,
                incidentID: incidentID
            )
        }

        promptForReauthenticationIfNeeded(trigger: "renew_failed")
    }

    @MainActor
    func promptForReauthenticationIfNeeded(trigger: String) {
        guard !isPresentingReauthenticationPrompt,
              let details = reauthenticationState.requiredDetails else {
            return
        }

        recordTrace(
            "reauthentication-prompt-presented",
            details: [
                "reason": details.reason.rawValue,
                "trigger": trigger
            ]
        )

        isPresentingReauthenticationPrompt = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("oobe.reauthentication.title", value: "Sign in again to continue",
            comment: "Auth reauthentication - Alert title when the access token can no longer be renewed"
        )
        alert.informativeText = NSLocalizedString("oobe.reauthentication.message", value: "We need to refresh your session before account features can keep working. Please sign in again.",
            comment: "Auth reauthentication - Alert body explaining required authentication"
        )
        alert.addButton(withTitle: NSLocalizedString("oobe.reauthentication.confirmButton", value: "Reauthenticate",
            comment: "Auth reauthentication - Primary action to start Auth0 web authentication"
        ))

        alert.runModal()
        isPresentingReauthenticationPrompt = false

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reauthenticateExpiredSession()
        }
    }

    @MainActor
    func reauthenticateExpiredSession() async -> Bool {
        if case .reauthenticating = reauthenticationState {
            return false
        }

        guard let details = reauthenticationState.requiredDetails else {
            return true
        }

        let attemptID = reauthenticationAttempts.begin()
        return await performReauthentication(
            details: details,
            attemptID: attemptID,
            replacingActiveSession: false
        )
    }

    /// Replaces an in-flight attempt so an explicit user action can take priority.
    @MainActor
    func restartReauthenticationSession() async -> Bool {
        guard let details = reauthenticationState.requiredDetails else {
            return true
        }

        let replacesActiveSession: Bool
        if case .reauthenticating = reauthenticationState {
            replacesActiveSession = true
        } else {
            replacesActiveSession = false
        }

        let attemptID = reauthenticationAttempts.begin()

        if replacesActiveSession {
            recordTrace(
                "reauthentication-restarted",
                details: [
                    "reason": details.reason.rawValue
                ]
            )
        }

        return await performReauthentication(
            details: details,
            attemptID: attemptID,
            replacingActiveSession: replacesActiveSession
        )
    }

    @MainActor
    private func performReauthentication(
        details: (
            reason: AuthReauthenticationReason,
            firstDetectedAt: Date,
            incidentID: UUID
        ),
        attemptID: UUID,
        replacingActiveSession: Bool
    ) async -> Bool {
        reauthenticationState = .reauthenticating(
            reason: details.reason,
            firstDetectedAt: details.firstDetectedAt,
            incidentID: details.incidentID
        )
        recordTrace(
            "reauthentication-started",
            details: [
                "reason": details.reason.rawValue
            ]
        )

        do {
            let webAuth = Auth0.webAuth(clientId: clicentId, domain: domain)
                .audience(audience)
                .scope("openid profile email offline_access")
                .provider(makeExternalBrowserAuthProvider())
            let results = try await AuthReauthenticationWebAuthRunner.run(
                replacingActiveSession: replacingActiveSession,
                cancel: { cancelOngoingWebAuthentication() },
                start: { webAuth.start($0) }
            )

            guard reauthenticationAttempts.finishIfCurrent(attemptID) else {
                recordTrace(
                    "reauthentication-result-ignored",
                    details: [
                        "outcome": "success",
                        "reason": details.reason.rawValue
                    ]
                )
                return false
            }
            guard storeReauthenticatedCredentials(results) else {
                handleReauthenticationFailure(
                    details: details,
                    failure: "user_mismatch",
                    extraDetails: [:]
                )
                return false
            }
            reauthenticationState = .normal
            clearPersistedReauthenticationState()
            recordTrace("reauthentication-succeeded", details: credentialSnapshotDetails())
            reportReauthenticationResult(
                succeeded: true,
                reason: details.reason,
                incidentID: details.incidentID,
                details: credentialSnapshotDetails()
            )
            return true
        } catch {
            guard reauthenticationAttempts.finishIfCurrent(attemptID) else {
                recordTrace(
                    "reauthentication-result-ignored",
                    details: [
                        "outcome": "failure",
                        "reason": details.reason.rawValue
                    ]
                )
                return false
            }
            handleReauthenticationFailure(
                details: details,
                failure: "webauth_error",
                extraDetails: [
                    "error": error.localizedDescription
                ]
            )
            AppLogError("reauthentication with auth0 failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    private func handleReauthenticationFailure(
        details: (
            reason: AuthReauthenticationReason,
            firstDetectedAt: Date,
            incidentID: UUID
        ),
        failure: String,
        extraDetails: [String: String]
    ) {
        var reportDetails = extraDetails
        reportDetails["failure"] = failure

        recordTrace(
            "reauthentication-failed",
            details: [
                "reason": details.reason.rawValue
            ].merging(reportDetails) { _, newValue in newValue }
        )
        forceLogoutAfterReauthenticationFailure(reason: failure, shouldReport: false)
        reportReauthenticationResult(
            succeeded: false,
            reason: details.reason,
            incidentID: details.incidentID,
            details: reportDetails
        )
    }

    @MainActor
    func forceLogoutAfterReauthenticationFailure(reason: String, shouldReport: Bool = true) {
        let reauthenticationDetails = reauthenticationState.requiredDetails
        recordTrace(
            "reauthentication-forced-logout",
            details: [
                "reason": reason
            ],
            callStackSymbols: Array(Thread.callStackSymbols.prefix(16))
        )
        if shouldReport, let reauthenticationDetails {
            reportReauthenticationResult(
                succeeded: false,
                reason: reauthenticationDetails.reason,
                incidentID: reauthenticationDetails.incidentID,
                details: [
                    "failure": "forced_logout",
                    "forcedLogoutReason": reason
                ]
            )
        }
        transitionToLoggedOutState()
    }

    private func persistedReauthenticationState() -> PersistedAuthReauthenticationState? {
        guard let defaults = AccountController.shared.account?.userDefaults,
              let reasonRaw = defaults.string(forKey: AccountUserDefaults.DefaultsKey.authReauthenticationReason.rawValue),
              let reason = AuthReauthenticationReason(rawValue: reasonRaw) else {
            return nil
        }

        let firstDetectedTimestamp = defaults.double(
            forKey: AccountUserDefaults.DefaultsKey.authReauthenticationFirstDetectedAt.rawValue
        )
        guard firstDetectedTimestamp > 0 else {
            return nil
        }

        let incidentID: UUID
        if let rawID = defaults.string(forKey: AccountUserDefaults.DefaultsKey.authReauthenticationIncidentID.rawValue),
           let storedID = UUID(uuidString: rawID) {
            incidentID = storedID
        } else {
            // Give pending incidents from older versions a stable ID for subsequent restores.
            incidentID = UUID()
            defaults.set(incidentID.uuidString, forKey: .authReauthenticationIncidentID)
        }

        return PersistedAuthReauthenticationState(
            reason: reason,
            firstDetectedAt: Date(timeIntervalSince1970: firstDetectedTimestamp),
            incidentID: incidentID
        )
    }

    func persistReauthenticationState(
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date,
        incidentID: UUID
    ) {
        guard let defaults = AccountController.shared.account?.userDefaults else {
            return
        }

        defaults.set(incidentID.uuidString, forKey: .authReauthenticationIncidentID)
        defaults.set(reason.rawValue, forKey: .authReauthenticationReason)
        defaults.set(firstDetectedAt.timeIntervalSince1970, forKey: .authReauthenticationFirstDetectedAt)
        hasPersistedReauthenticationState = true
    }

    func clearPersistedReauthenticationState() {
        hasPersistedReauthenticationState = false

        guard let defaults = AccountController.shared.account?.userDefaults else {
            return
        }

        defaults.set(nil, forKey: .authReauthenticationReason)
        defaults.set(nil, forKey: .authReauthenticationFirstDetectedAt)
        defaults.set(nil, forKey: .authReauthenticationIncidentID)
        defaults.set(nil, forKey: "authReauthenticationFailedAttempts")
        defaults.set(nil, forKey: "authReauthenticationPromptDeferrals")
        defaults.set(nil, forKey: "authReauthenticationNextPromptAt")
    }
}

extension Notification.Name {
    static let authReauthenticationStateDidChange = Notification.Name("authReauthenticationStateDidChange")
}
