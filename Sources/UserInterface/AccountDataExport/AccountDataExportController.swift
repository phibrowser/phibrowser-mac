// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Owns the account-data export UI started from chrome://settings. The native
/// side keeps the Auth0 token and verification code out of Chromium WebUI.
@MainActor
final class AccountDataExportController {
    static let shared = AccountDataExportController()

    private var coordinator: AccountDataExportCoordinator?
    private var isPresentingConfirmation = false
    private var flowPresenter: PhiAlertPresenter?
    private var activeUserID: String?
    private var accountObserver: NSObjectProtocol?

    var isFlowActive: Bool {
        isPresentingConfirmation || flowPresenter != nil
    }

    private init() {
        accountObserver = NotificationCenter.default.addObserver(
            forName: .mainAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissIfAccountChanged()
            }
        }
    }

    func start() {
        guard !isPresentingConfirmation, flowPresenter == nil else {
            AppLogInfo("[AccountDataExport] Dialog already presented, ignoring request")
            return
        }
        guard !AccountDeletionController.shared.isFlowActive else {
            AppLogInfo("[AccountDataExport] Account deletion flow is active, ignoring request")
            return
        }
        guard let account = signedInAccountContext else {
            AppLogInfo("[AccountDataExport] No signed-in account, ignoring request")
            return
        }
        guard let authSession = AuthManager.shared.captureAuthenticatedSession(
            expectedUserID: account.userID
        ) else {
            AppLogInfo("[AccountDataExport] Authentication session changed before confirmation")
            return
        }
        guard let window = alertParentWindow else {
            AppLogError("[AccountDataExport] No window available for the export dialog")
            return
        }

        isPresentingConfirmation = true
        window.presentPhiAlert(confirmationConfiguration(email: account.email)) { [weak self] response in
            guard let self else { return }
            self.isPresentingConfirmation = false
            guard response == .alertFirstButtonReturn else {
                AppLogInfo("[AccountDataExport] Cancelled before requesting a code")
                return
            }
            guard AuthManager.shared.isAuthenticatedSessionCurrent(
                authSession,
                expectedUserID: account.userID
            ) else {
                AppLogInfo("[AccountDataExport] Account changed during confirmation")
                return
            }
            self.beginExportFlow(
                account: account,
                authSession: authSession,
                over: window
            )
        }
    }

    private func beginExportFlow(
        account: (userID: String, email: String),
        authSession: UInt64,
        over window: NSWindow
    ) {
        let coordinator = AccountDataExportCoordinator(
            requestExport: { idempotencyKey in
                try await APIClient.shared.requestAccountDataExport(
                    idempotencyKey: idempotencyKey,
                    expectedAuthSession: authSession
                )
            },
            verifyExport: { requestID, code in
                try await APIClient.shared.verifyAccountDataExport(
                    requestID: requestID,
                    code: code,
                    expectedAuthSession: authSession
                )
            },
            renewCredentials: {
                await AuthManager.shared.renewCredentialsAsync(
                    operation: "account data export",
                    expectedSession: authSession,
                    force: true
                ) != nil
            },
            isSessionCurrent: {
                AuthManager.shared.isAuthenticatedSessionCurrent(
                    authSession,
                    expectedUserID: account.userID
                )
            }
        )
        self.coordinator = coordinator
        activeUserID = account.userID

        let viewState = AccountDataExportFlowViewState()
        viewState.state = coordinator.state
        viewState.resendAvailableAt = coordinator.resendAvailableAt
        coordinator.onStateChange = { [coordinator, weak viewState] state in
            viewState?.resendAvailableAt = coordinator.resendAvailableAt
            viewState?.state = state
        }

        flowPresenter = window.presentPhiAlert(onDismiss: { [weak self] _ in
            guard let self else { return }
            self.flowPresenter = nil
            coordinator.onStateChange = nil
            coordinator.dismiss()
            self.coordinator = nil
            self.activeUserID = nil
        }, content: { dismiss in
            AccountDataExportFlowView(
                viewState: viewState,
                maskedEmail: AccountVerificationEmailMasking.masked(account.email),
                dismiss: dismiss,
                submit: { [coordinator] code in
                    Task { await coordinator.submitCode(code) }
                },
                resend: { [coordinator] in
                    Task { await coordinator.resendCode() }
                },
                retry: { [coordinator] in
                    Task { await coordinator.start() }
                }
            )
        })

        Task { [coordinator] in await coordinator.start() }
    }

    private var signedInAccountContext: (userID: String, email: String)? {
        guard let account = AccountController.shared.account else { return nil }

        let profile: Profile? = account.userDefaults.codableValue(
            forKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue
        )
        if let profile, profile.auth0_id == account.userID, !profile.email.isEmpty {
            return (account.userID, profile.email)
        }

        guard let email = account.userInfo?.email, !email.isEmpty else { return nil }
        return (account.userID, email)
    }

    private func dismissIfAccountChanged() {
        guard let activeUserID,
              AccountController.shared.account?.userID != activeUserID else {
            return
        }
        AppLogInfo("[AccountDataExport] Account changed; dismissing export flow")
        flowPresenter?.dismiss(.cancel)
    }

    private var alertParentWindow: NSWindow? {
        MainBrowserWindowControllersManager.shared.activeWindowController?.window
            ?? NSApp.keyWindow
    }

    private func confirmationConfiguration(email: String) -> PhiAlertAppKitConfiguration {
        let messageFormat = NSLocalizedString(
            "accountDataExport.confirmation.message",
            value: "We'll send a verification code to %@. Once verified, we'll prepare a copy of the personal data associated with your Phi Browser account and email you a download link. The link will be available for seven days.",
            comment: "Account data export - Confirmation message before requesting a code. %@ is the account email"
        )

        return PhiAlertAppKitConfiguration(
            title: NSLocalizedString(
                "accountDataExport.confirmation.title",
                value: "Export your account data?",
                comment: "Account data export - Title of the confirmation shown before requesting a code"
            ),
            message: String(format: messageFormat, email),
            secondaryAction: PhiAlertAppKitAction(
                NSLocalizedString(
                    "accountDataExport.confirmation.cancelButton",
                    value: "Cancel",
                    comment: "Account data export - Button dismissing the confirmation"
                ),
                response: .alertSecondButtonReturn
            ),
            primaryAction: PhiAlertAppKitAction(
                NSLocalizedString(
                    "accountDataExport.confirmation.sendCodeButton",
                    value: "Send Code",
                    comment: "Account data export - Button requesting the verification email"
                ),
                response: .alertFirstButtonReturn
            )
        )
    }
}
