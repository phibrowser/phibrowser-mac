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
        promptDeferrals: Int,
        nextPromptAt: Date?
    )
    case reauthenticating(
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date,
        promptDeferrals: Int,
        nextPromptAt: Date?
    )

    var requiredDetails: (
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date,
        promptDeferrals: Int,
        nextPromptAt: Date?
    )? {
        switch self {
        case let .required(reason, firstDetectedAt, promptDeferrals, nextPromptAt),
             let .reauthenticating(reason, firstDetectedAt, promptDeferrals, nextPromptAt):
            return (reason, firstDetectedAt, promptDeferrals, nextPromptAt)
        case .normal:
            return nil
        }
    }
}

struct AuthReauthenticationPolicy {
    static let `default` = AuthReauthenticationPolicy(
        maxPromptDeferrals: 3,
        maxOfflineDuration: 7 * 24 * 60 * 60,
        promptIntervals: [
            10.0 * 60,
            60.0 * 60
        ]
    )

    let maxPromptDeferrals: Int
    let maxOfflineDuration: TimeInterval
    let promptIntervals: [TimeInterval]

    func shouldForceLogin(
        firstDetectedAt: Date,
        promptDeferrals: Int,
        now: Date
    ) -> Bool {
        promptDeferrals >= maxPromptDeferrals ||
            now.timeIntervalSince(firstDetectedAt) > maxOfflineDuration
    }

    func nextPromptAt(afterDeferrals promptDeferrals: Int, now: Date) -> Date? {
        guard promptDeferrals > 0 else { return nil }
        let intervalIndex = min(promptDeferrals - 1, promptIntervals.count - 1)
        guard promptIntervals.indices.contains(intervalIndex) else {
            return nil
        }
        return now.addingTimeInterval(promptIntervals[intervalIndex])
    }

    func canPrompt(nextPromptAt: Date?, now: Date) -> Bool {
        guard let nextPromptAt else { return true }
        return now >= nextPromptAt
    }
}

private struct PersistedAuthReauthenticationState {
    let reason: AuthReauthenticationReason
    let firstDetectedAt: Date
    let promptDeferrals: Int
    let nextPromptAt: Date?
}

extension AuthManager {
    var requiresReauthentication: Bool {
        reauthenticationState.requiredDetails != nil || hasPersistedReauthenticationState
    }

    func hasReauthenticationGraceSession() -> Bool {
        if let details = reauthenticationState.requiredDetails {
            return !reauthenticationPolicy.shouldForceLogin(
                firstDetectedAt: details.firstDetectedAt,
                promptDeferrals: details.promptDeferrals,
                now: Date()
            )
        }

        return hasPersistedReauthenticationState
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
            promptDeferrals: persisted.promptDeferrals,
            nextPromptAt: persisted.nextPromptAt
        )

        if reauthenticationPolicy.shouldForceLogin(
            firstDetectedAt: persisted.firstDetectedAt,
            promptDeferrals: persisted.promptDeferrals,
            now: Date()
        ) {
            Task { @MainActor [weak self] in
                self?.forceLogoutAfterReauthenticationFailure(reason: "reauthentication_policy_limit")
            }
            return
        }

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
        let promptDeferrals = existing?.promptDeferrals ?? persisted?.promptDeferrals ?? 0
        let nextPromptAt = existing?.nextPromptAt ?? persisted?.nextPromptAt

        recordTrace(
            "reauthentication-required",
            details: [
                "reason": reason.rawValue,
                "firstDetectedAt": iso8601String(firstDetectedAt),
                "promptDeferrals": String(promptDeferrals),
                "nextPromptAt": iso8601String(nextPromptAt)
            ],
            callStackSymbols: Array(Thread.callStackSymbols.prefix(16))
        )

        pauseRenewalForReauthentication()

        reauthenticationState = .required(
            reason: reason,
            firstDetectedAt: firstDetectedAt,
            promptDeferrals: promptDeferrals,
            nextPromptAt: nextPromptAt
        )
        persistReauthenticationState(
            reason: reason,
            firstDetectedAt: firstDetectedAt,
            promptDeferrals: promptDeferrals,
            nextPromptAt: nextPromptAt
        )

        if reauthenticationPolicy.shouldForceLogin(
            firstDetectedAt: firstDetectedAt,
            promptDeferrals: promptDeferrals,
            now: now
        ) {
            forceLogoutAfterReauthenticationFailure(reason: "reauthentication_policy_limit")
            return
        }

        promptForReauthenticationIfNeeded(trigger: "renew_failed")
    }

    @MainActor
    func promptForReauthenticationIfNeeded(trigger: String) {
        guard !isPresentingReauthenticationPrompt,
              let details = reauthenticationState.requiredDetails else {
            return
        }

        let now = Date()
        guard reauthenticationPolicy.canPrompt(nextPromptAt: details.nextPromptAt, now: now) else {
            recordTrace(
                "reauthentication-prompt-skipped",
                details: [
                    "reason": details.reason.rawValue,
                    "trigger": trigger,
                    "nextPromptAt": iso8601String(details.nextPromptAt)
                ]
            )
            return
        }

        isPresentingReauthenticationPrompt = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "Session Expired",
            comment: "Auth reauthentication - Alert title when the access token can no longer be renewed"
        )
        alert.informativeText = NSLocalizedString(
            "Phi needs you to authenticate again to restore account features. You can keep browsing for now, but token-based features will be unavailable until you reauthenticate.",
            comment: "Auth reauthentication - Alert body explaining degraded auth state"
        )
        alert.addButton(withTitle: NSLocalizedString(
            "Reauthenticate",
            comment: "Auth reauthentication - Primary action to start Auth0 web authentication"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "Later",
            comment: "Auth reauthentication - Secondary action to defer Auth0 web authentication"
        ))

        let response = alert.runModal()
        isPresentingReauthenticationPrompt = false

        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let succeeded = await self.reauthenticateExpiredSession()
                if !succeeded {
                    self.forceLogoutAfterReauthenticationFailure(reason: "webauth_failed")
                }
            }
        default:
            let nextDeferrals = details.promptDeferrals + 1
            let nextPromptAt = reauthenticationPolicy.nextPromptAt(
                afterDeferrals: nextDeferrals,
                now: Date()
            )
            reauthenticationState = .required(
                reason: details.reason,
                firstDetectedAt: details.firstDetectedAt,
                promptDeferrals: nextDeferrals,
                nextPromptAt: nextPromptAt
            )
            persistReauthenticationState(
                reason: details.reason,
                firstDetectedAt: details.firstDetectedAt,
                promptDeferrals: nextDeferrals,
                nextPromptAt: nextPromptAt
            )
            recordTrace(
                "reauthentication-deferred",
                details: [
                    "reason": details.reason.rawValue,
                    "trigger": trigger,
                    "promptDeferrals": String(nextDeferrals),
                    "nextPromptAt": iso8601String(nextPromptAt)
                ]
            )

            if reauthenticationPolicy.shouldForceLogin(
                firstDetectedAt: details.firstDetectedAt,
                promptDeferrals: nextDeferrals,
                now: Date()
            ) {
                forceLogoutAfterReauthenticationFailure(reason: "reauthentication_deferred_limit")
            }
        }
    }

    @MainActor
    func reauthenticateExpiredSession() async -> Bool {
        guard let details = reauthenticationState.requiredDetails else {
            return true
        }

        reauthenticationState = .reauthenticating(
            reason: details.reason,
            firstDetectedAt: details.firstDetectedAt,
            promptDeferrals: details.promptDeferrals,
            nextPromptAt: details.nextPromptAt
        )
        recordTrace(
            "reauthentication-started",
            details: [
                "reason": details.reason.rawValue,
                "promptDeferrals": String(details.promptDeferrals)
            ]
        )

        do {
            let results = try await Auth0.webAuth(clientId: clicentId, domain: domain)
                .audience(audience)
                .scope("openid profile email offline_access")
                .provider(makeExternalBrowserAuthProvider())
                .start()

            guard storeReauthenticatedCredentials(results) else {
                reportReauthenticationResult(
                    succeeded: false,
                    reason: details.reason,
                    details: [
                        "failure": "user_mismatch",
                        "promptDeferrals": String(details.promptDeferrals)
                    ]
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
            reauthenticationState = .required(
                reason: details.reason,
                firstDetectedAt: details.firstDetectedAt,
                promptDeferrals: details.promptDeferrals,
                nextPromptAt: details.nextPromptAt
            )
            persistReauthenticationState(
                reason: details.reason,
                firstDetectedAt: details.firstDetectedAt,
                promptDeferrals: details.promptDeferrals,
                nextPromptAt: details.nextPromptAt
            )
            recordTrace(
                "reauthentication-failed",
                details: [
                    "reason": details.reason.rawValue,
                    "error": error.localizedDescription
                ]
            )
            reportReauthenticationResult(
                succeeded: false,
                reason: details.reason,
                details: [
                    "failure": "webauth_error",
                    "error": error.localizedDescription,
                    "promptDeferrals": String(details.promptDeferrals)
                ]
            )
            AppLogError("reauthentication with auth0 failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func forceLogoutAfterReauthenticationFailure(reason: String) {
        let reauthenticationReason = reauthenticationState.requiredDetails?.reason
        recordTrace(
            "reauthentication-forced-logout",
            details: [
                "reason": reason
            ],
            callStackSymbols: Array(Thread.callStackSymbols.prefix(16))
        )
        if let reauthenticationReason {
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

        let nextPromptTimestamp = defaults.double(
            forKey: AccountUserDefaults.DefaultsKey.authReauthenticationNextPromptAt.rawValue
        )
        let nextPromptAt = nextPromptTimestamp > 0
            ? Date(timeIntervalSince1970: nextPromptTimestamp)
            : nil

        return PersistedAuthReauthenticationState(
            reason: reason,
            firstDetectedAt: Date(timeIntervalSince1970: firstDetectedTimestamp),
            promptDeferrals: defaults.integer(
                forKey: AccountUserDefaults.DefaultsKey.authReauthenticationPromptDeferrals.rawValue
            ),
            nextPromptAt: nextPromptAt
        )
    }

    func persistReauthenticationState(
        reason: AuthReauthenticationReason,
        firstDetectedAt: Date,
        promptDeferrals: Int,
        nextPromptAt: Date?
    ) {
        guard let defaults = AccountController.shared.account?.userDefaults else {
            return
        }

        defaults.set(reason.rawValue, forKey: .authReauthenticationReason)
        defaults.set(firstDetectedAt.timeIntervalSince1970, forKey: .authReauthenticationFirstDetectedAt)
        defaults.set(promptDeferrals, forKey: .authReauthenticationPromptDeferrals)
        defaults.set(nextPromptAt?.timeIntervalSince1970, forKey: .authReauthenticationNextPromptAt)
        hasPersistedReauthenticationState = true
    }

    func clearPersistedReauthenticationState() {
        hasPersistedReauthenticationState = false

        guard let defaults = AccountController.shared.account?.userDefaults else {
            return
        }

        defaults.set(nil, forKey: .authReauthenticationReason)
        defaults.set(nil, forKey: .authReauthenticationFirstDetectedAt)
        defaults.set(nil, forKey: .authReauthenticationPromptDeferrals)
        defaults.set(nil, forKey: .authReauthenticationNextPromptAt)
    }
}

extension Notification.Name {
    static let authReauthenticationStateDidChange = Notification.Name("authReauthenticationStateDidChange")
}
