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
        firstDetectedAt: Date
    )
    case reauthenticating(
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date
    )

    var requiredDetails: (
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date
    )? {
        switch self {
        case let .required(reason, firstDetectedAt),
             let .reauthenticating(reason, firstDetectedAt):
            return (reason, firstDetectedAt)
        case .normal:
            return nil
        }
    }
}

private struct PersistedAuthReauthenticationState {
    let reason: AuthReauthenticationReason
    let firstDetectedAt: Date
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
            firstDetectedAt: persisted.firstDetectedAt
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

        recordTrace(
            "reauthentication-required",
            details: [
                "reason": reason.rawValue,
                "firstDetectedAt": iso8601String(firstDetectedAt)
            ],
            callStackSymbols: Array(Thread.callStackSymbols.prefix(16))
        )

        pauseRenewalForReauthentication()

        reauthenticationState = .required(
            reason: reason,
            firstDetectedAt: firstDetectedAt
        )
        persistReauthenticationState(
            reason: reason,
            firstDetectedAt: firstDetectedAt
        )

        promptForReauthenticationIfNeeded(trigger: "renew_failed")
        notifyAuthSessionChanged("reauth-required")
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
        alert.messageText = NSLocalizedString(
            "Sign in again to continue",
            comment: "Auth reauthentication - Alert title when the access token can no longer be renewed"
        )
        alert.informativeText = NSLocalizedString(
            "We need to refresh your session before account features can keep working. Please sign in again.",
            comment: "Auth reauthentication - Alert body explaining required authentication"
        )
        alert.addButton(withTitle: NSLocalizedString(
            "Reauthenticate",
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
        guard let details = reauthenticationState.requiredDetails else {
            return true
        }

        reauthenticationState = .reauthenticating(
            reason: details.reason,
            firstDetectedAt: details.firstDetectedAt
        )
        recordTrace(
            "reauthentication-started",
            details: [
                "reason": details.reason.rawValue
            ]
        )

        do {
            let results = try await Auth0.webAuth(clientId: clicentId, domain: domain)
                .audience(audience)
                .scope("openid profile email offline_access")
                .provider(makeExternalBrowserAuthProvider())
                .start()

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
                details: credentialSnapshotDetails()
            )
            return true
        } catch {
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
            firstDetectedAt: Date
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
            details: reportDetails
        )
    }

    @MainActor
    func forceLogoutAfterReauthenticationFailure(reason: String, shouldReport: Bool = true) {
        let reauthenticationReason = reauthenticationState.requiredDetails?.reason
        recordTrace(
            "reauthentication-forced-logout",
            details: [
                "reason": reason
            ],
            callStackSymbols: Array(Thread.callStackSymbols.prefix(16))
        )
        if shouldReport, let reauthenticationReason {
            reportReauthenticationResult(
                succeeded: false,
                reason: reauthenticationReason,
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

        return PersistedAuthReauthenticationState(
            reason: reason,
            firstDetectedAt: Date(timeIntervalSince1970: firstDetectedTimestamp)
        )
    }

    func persistReauthenticationState(
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date
    ) {
        guard let defaults = AccountController.shared.account?.userDefaults else {
            return
        }

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
        defaults.set(nil, forKey: "authReauthenticationFailedAttempts")
        defaults.set(nil, forKey: "authReauthenticationPromptDeferrals")
        defaults.set(nil, forKey: "authReauthenticationNextPromptAt")
    }
}

extension Notification.Name {
    static let authReauthenticationStateDidChange = Notification.Name("authReauthenticationStateDidChange")

    /// Any Phi auth session change worth telling Chromium about: login,
    /// logout, renewal completion, reauthentication required. Payload-free —
    /// Chromium re-reads the session and reconciles.
    static let phiAuthSessionDidChange = Notification.Name("phiAuthSessionDidChange")
}
