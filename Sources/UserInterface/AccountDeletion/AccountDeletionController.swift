// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Owns the account deletion flow started from the Phi account subpage in
/// chrome://settings. Chromium only relays the click: the account credentials,
/// the API client and the app lifetime all live on this side, so everything
/// the user sees from the warning onwards belongs here.
@MainActor
final class AccountDeletionController {
    static let shared = AccountDeletionController()

    private let coordinator = AccountDeletionCoordinator()
    private var isPresentingWarning = false
    private var flowPresenter: PhiAlertPresenter?

    var isFlowActive: Bool {
        isPresentingWarning || flowPresenter != nil
    }

    private init() {}

    /// Warns about the consequences and names the account being deleted.
    /// Confirming presents the flow dialog and sends the deletion request;
    /// cancelling leaves no trace, so the entry point stays usable.
    func start() {
        guard !isPresentingWarning else {
            AppLogInfo("🗑️ [AccountDeletion] Warning already on screen, ignoring request")
            return
        }

        // One flow at a time: another settings tab (or a double click) must
        // not stack a second dialog. The coordinator additionally guards the
        // network side, but the first dialog keeps the screen.
        guard flowPresenter == nil else {
            AppLogInfo("🗑️ [AccountDeletion] Flow dialog already on screen, ignoring request")
            return
        }
        guard !AccountDataExportController.shared.isFlowActive else {
            AppLogInfo("🗑️ [AccountDeletion] Account data export flow is active, ignoring request")
            return
        }

        // The subpage disables its entry point while signed out, so an absent
        // account means it went away between the page load and the click.
        guard let email = signedInAccountEmail else {
            AppLogInfo("🗑️ [AccountDeletion] No signed-in account, ignoring request")
            return
        }

        guard let window = alertParentWindow else {
            AppLogError("🗑️ [AccountDeletion] No window to attach the warning to")
            return
        }

        isPresentingWarning = true
        window.presentPhiAlert(warningConfiguration(email: email)) { [weak self] response in
            self?.isPresentingWarning = false
            guard response == .alertFirstButtonReturn else {
                AppLogInfo("🗑️ [AccountDeletion] Cancelled at the warning")
                return
            }
            AppLogInfo("🗑️ [AccountDeletion] Warning confirmed")
            self?.beginDeletionFlow(email: email, over: window)
        }
    }

    /// Presents the live flow dialog and kicks off the deletion request. The
    /// dialog renders whatever the coordinator state says; dismissing it
    /// abandons the flow, which the coordinator guarantees clears nothing.
    private func beginDeletionFlow(email: String, over window: NSWindow) {
        let viewState = AccountDeletionFlowViewState()
        // Seeding from the coordinator (instead of assuming .idle) lets the
        // dialog reattach to a flow that lost its UI, e.g. after its window
        // died mid-request.
        viewState.state = coordinator.state
        viewState.resendAvailableAt = coordinator.resendAvailableAt
        coordinator.onStateChange = { [coordinator, weak viewState] state in
            viewState?.resendAvailableAt = coordinator.resendAvailableAt
            viewState?.state = state
        }

        flowPresenter = window.presentPhiAlert(onDismiss: { [weak self] _ in
            guard let self else { return }
            self.flowPresenter = nil
            self.coordinator.onStateChange = nil
            self.coordinator.cancel()
        }, content: { dismiss in
            AccountDeletionFlowView(
                viewState: viewState,
                maskedEmail: AccountVerificationEmailMasking.masked(email),
                dismiss: dismiss,
                submit: { [coordinator] code in
                    // Never log the code itself.
                    Task {
                        await coordinator.submitCode(code)
                    }
                },
                resend: { [coordinator] in
                    Task {
                        await coordinator.resendCode()
                    }
                },
                retry: { [coordinator] in
                    // start() from the failed state retries the first step;
                    // the coordinator owns the idempotency-key policy.
                    Task {
                        await coordinator.start()
                    }
                },
                finalize: { [coordinator] in
                    // Clears the local data and then the credential layer,
                    // then force-quits; the coordinator guards re-entry.
                    Task {
                        await coordinator.finalizeDeletion()
                    }
                }
            )
        })

        Task { [coordinator] in
            await coordinator.start()
        }
    }

    /// The account the warning names. Read from the cached profile the account
    /// row displays, falling back to the ID-token identity that covers the
    /// window before the profile prefetch lands.
    private var signedInAccountEmail: String? {
        guard let account = AccountController.shared.account else { return nil }

        let profile: Profile? = account.userDefaults.codableValue(
            forKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue
        )
        if let profile, profile.auth0_id == account.userID, !profile.email.isEmpty {
            return profile.email
        }

        guard let email = account.userInfo?.email, !email.isEmpty else { return nil }
        return email
    }

    /// The deletion entry point lives in a settings tab, so the browser window
    /// hosting it is the sheet's parent. The active browser window comes
    /// first: at click time some floating panel can happen to be key, and the
    /// sheet must not attach to it.
    private var alertParentWindow: NSWindow? {
        MainBrowserWindowControllersManager.shared.activeWindowController?.window
            ?? NSApp.keyWindow
    }

    private func warningConfiguration(email: String) -> PhiAlertAppKitConfiguration {
        let messageFormat = NSLocalizedString("accountDeletion.confirmation.message", value: "This deletes the Phi account %@ and everything Phi has stored on this Mac — browsing history, cookies, passwords, bookmarks, and Spaces. None of it can be recovered.\n\nOnce the deletion request is submitted, Phi signs you out and quits.",
            comment: "Account deletion - Warning explaining what deleting the Phi account destroys. %@ is the account's email address"
        )
        let exportWarning = NSLocalizedString(
            "accountDeletion.confirmation.exportWarning",
            value: "Download any data export you want to keep before deleting your account. Deletion cancels exports in progress and permanently removes existing download files and links.",
            comment: "Account deletion - Warning that account deletion cancels and removes data exports"
        )

        return PhiAlertAppKitConfiguration(
            title: NSLocalizedString("accountDeletion.confirmation.title", value: "Delete your Phi account?",
                comment: "Account deletion - Title of the warning shown before deleting the Phi account"
            ),
            message: String(format: messageFormat, email) + "\n\n" + exportWarning,
            style: .critical,
            // Deletion is irreversible, so no button answers the Return key —
            // a reflexive Return must not confirm it. Escape still cancels.
            defaultButton: .noButton,
            secondaryAction: PhiAlertAppKitAction(
                NSLocalizedString("accountDeletion.confirmation.cancelButton", value: "Cancel",
                    comment: "Account deletion - Button dismissing the deletion warning without deleting anything"
                ),
                response: .alertSecondButtonReturn
            ),
            primaryAction: PhiAlertAppKitAction(
                NSLocalizedString("accountDeletion.confirmation.deleteAccountButton", value: "Delete Account",
                    comment: "Account deletion - Destructive button confirming the deletion warning"
                ),
                response: .alertFirstButtonReturn
            )
        )
    }
}
