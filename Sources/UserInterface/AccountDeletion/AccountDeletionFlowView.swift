// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// User-facing copy for deletion flow failures. Two contexts share most
/// entries but diverge where the meaning depends on where the flow stands:
/// `inlineMessage` renders in the code-entry dialog, where the request is
/// still alive, so a rejected request means a mistyped code and an expiry
/// points at Resend Code; `failureMessage` renders when the first step
/// failed, where neither reading applies and both collapse to the generic
/// copy. The generic copy deliberately covers not-found too: it must read
/// exactly like any other failure so no response reveals whether an
/// account exists.
enum AccountDeletionErrorCopy {
    static func inlineMessage(for error: AccountDeletionFlowError) -> String {
        switch error {
        case .service(.invalidRequest):
            return wrongCodeText
        case .service(.expired):
            return codeExpiredText
        case .service, .network:
            return failureMessage(for: error)
        }
    }

    static func failureMessage(for error: AccountDeletionFlowError) -> String {
        switch error {
        case .service(.unauthorized):
            return signedOutText
        case .service(.rateLimited):
            return rateLimitedText
        case .service(.serverError):
            return serverErrorText
        case .service(.invalidRequest), .service(.expired),
             .service(.notFound), .service(.unexpectedResponse):
            return genericText
        case .network:
            return networkText
        }
    }

    private static let wrongCodeText = NSLocalizedString("accountDeletion.verification.invalidCodeError", value: "That code isn't correct. Check the code from the email and try again.",
        comment: "Account deletion - Inline error when the submitted verification code is rejected"
    )

    private static let codeExpiredText = NSLocalizedString("accountDeletion.verification.expiredCodeError", value: "That code has expired. Click Resend Code to get a new one.",
        comment: "Account deletion - Inline error when the verification code expired; points at the resend button"
    )

    private static let rateLimitedText = NSLocalizedString("accountDeletion.verification.rateLimitError", value: "Too many attempts for now. Please wait a few minutes and try again.",
        comment: "Account deletion - Error when the deletion service rate limit is hit"
    )

    private static let signedOutText = NSLocalizedString("accountDeletion.sessionExpiredError", value: "Your session has expired. Please sign in again, then restart the deletion.",
        comment: "Account deletion - Error when the access token stays rejected even after renewing it"
    )

    private static let serverErrorText = NSLocalizedString("accountDeletion.serviceUnavailableError", value: "The deletion service is temporarily unavailable. Please try again later.",
        comment: "Account deletion - Error when the deletion service reports a server error"
    )

    private static let genericText = NSLocalizedString("accountDeletion.genericError", value: "Something went wrong. Please try again later.",
        comment: "Account deletion - Generic error; deliberately vague so it cannot reveal whether an account exists"
    )

    private static let networkText = NSLocalizedString("accountDeletion.networkError", value: "Couldn't reach the deletion service. Check your internet connection and try again.",
        comment: "Account deletion - Error when the network request could not complete"
    )
}

/// The dialog's live mirror of the coordinator state. The controller forwards
/// `onStateChange` into it so the sheet content re-renders on every
/// transition without the coordinator knowing about SwiftUI.
@MainActor
final class AccountDeletionFlowViewState: ObservableObject {
    @Published var state: AccountDeletionCoordinator.State = .idle
    /// When the resend button unlocks, mirrored from the coordinator on every
    /// transition; the countdown itself ticks against the wall clock in the
    /// view.
    @Published var resendAvailableAt: Date?
}

/// The live deletion flow dialog, presented after the user confirms the
/// warning. It renders whatever the coordinator state says — progress while
/// the deletion request is in flight, the code entry boxes once the
/// verification code is out — so later steps add states, not dialogs.
/// Verify hands the entered code to the coordinator; cancelling dismisses
/// the sheet and the controller abandons the flow, which clears nothing.
struct AccountDeletionFlowView: View {
    @ObservedObject var viewState: AccountDeletionFlowViewState
    let maskedEmail: String
    let dismiss: PhiAlertDismissAction
    /// Receives the entered six-digit code when Verify is clicked; the
    /// controller forwards it to the coordinator.
    let submit: (String) -> Void
    /// Asks the coordinator for a fresh verification code; the button only
    /// enables once the cooldown in `viewState.resendAvailableAt` lapsed.
    let resend: () -> Void
    /// Retries a failed first step through the coordinator, which replays
    /// the original idempotency key after indeterminate failures (so a retry
    /// cannot double-book) and mints a fresh one after definitive
    /// rejections.
    let retry: () -> Void
    /// Confirms the finalize once the deletion is booked server-side —
    /// submitted, or found already running: the coordinator clears the
    /// local data and then the credential layer, then force-quits.
    let finalize: () -> Void

    @State private var code = ""

    @Environment(\.phiAppearance) private var appearance

    /// Every state renders into the same fixed-height box: the sheet window
    /// is sized once at presentation and never resized, so the content must
    /// not change height when the state switches. Sized for the tallest
    /// state, the code entry (two-line status slot + digit boxes + resend
    /// line).
    private static let contentHeight: CGFloat = 144

    /// The status slot above the digit boxes fits two lines of copy, so a
    /// wrapping error message cannot push the boxes and the resend row down.
    private static let statusSlotHeight: CGFloat = 34

    var body: some View {
        PhiAlert(
            title: NSLocalizedString("accountDeletion.window.title", value: "Delete Phi Account",
                comment: "Account deletion - Title of the deletion flow dialog"
            )
        ) {
            Image(nsImage: .phiAlertIcon)
                .renderingMode(NSImage.phiAlertIcon.isTemplate ? .template : .original)
                .foregroundStyle(appearance.isLight ? Color.black : Color.white)
        } content: {
            stateContent
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.contentHeight,
                    maxHeight: Self.contentHeight,
                    alignment: .topLeading
                )
        } actions: {
            stateActions
        }
        .onChange(of: viewState.state) { oldState, newState in
            // A failed verification falls back to code entry with the error
            // copy in the status line. Clear the boxes so the user re-enters
            // a code instead of resubmitting the rejected one.
            if case .verifyingCode = oldState,
               case .awaitingVerificationCode(_, let error) = newState,
               error != nil {
                code = ""
            }
            // A successful resend lands back in code entry through the
            // requesting state with a fresh request: whatever was typed
            // belongs to the superseded code, so start the boxes clean. A
            // FAILED resend (error inline) keeps the original request — and
            // any typed digits — usable.
            if case .requestingDeletion = oldState,
               case .awaitingVerificationCode(_, let error) = newState,
               error == nil {
                code = ""
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewState.state {
        case .idle, .requestingDeletion:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(format: Self.requestingFormat, maskedEmail))
            }
        case .awaitingVerificationCode, .verifyingCode:
            VStack(alignment: .leading, spacing: 12) {
                statusLine
                AccountVerificationCodeEntry(
                    code: $code,
                    isDisabled: isVerifying,
                    accessibilityLabel: Self.codeAccessibilityLabel
                )
                resendRow
            }
        case .requestSubmitted:
            Text(Self.submittedText)
        case .finalizing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(Self.finalizingText)
            }
        case .deletionAlreadyRunning:
            Text(Self.alreadyRunningText)
        case .failed(let error):
            Text(AccountDeletionErrorCopy.failureMessage(for: error))
        }
    }

    /// The line above the digit boxes: the entry prompt, the verification
    /// progress, or — after a rejected code or a failed resend — the error
    /// copy, all sharing one fixed slot so swapping them never reflows the
    /// boxes below.
    private var statusLine: some View {
        Group {
            if isVerifying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(Self.verifyingText)
                }
            } else if let error = inlineError {
                Text(AccountDeletionErrorCopy.inlineMessage(for: error))
                    .foregroundStyle(.red)
            } else {
                Text(String(format: Self.enterCodeFormat, maskedEmail))
            }
        }
        .frame(height: Self.statusSlotHeight, alignment: .topLeading)
    }

    private var inlineError: AccountDeletionFlowError? {
        if case .awaitingVerificationCode(_, let error) = viewState.state {
            return error
        }
        return nil
    }

    @ViewBuilder
    private var stateActions: some View {
        switch viewState.state {
        case .idle, .requestingDeletion:
            // The coordinator ignores cancellation while the request is in
            // flight, so the button reflects that instead of lying.
            PhiAlertActions {
                cancelButton(disabled: true)
            }
        case .awaitingVerificationCode, .verifyingCode:
            PhiAlertActions(
                secondaryAction: {
                    cancelButton(disabled: isVerifying)
                },
                primaryAction: {
                    // No Return-key shortcut: like the warning before it,
                    // the destructive confirmation must be a deliberate
                    // click, not a reflexive Return.
                    PhiAlertButton(
                        NSLocalizedString("accountDeletion.verification.verifyButton", value: "Verify",
                            comment: "Account deletion - Button submitting the emailed verification code"
                        ),
                        role: .destructive
                    ) {
                        submit(code)
                    }
                    .disabled(isVerifying || !isCodeComplete)
                    .opacity(isVerifying || !isCodeComplete ? 0.5 : 1)
                }
            )
        case .requestSubmitted, .deletionAlreadyRunning:
            // The one explicit confirmation before the quit: no Close and
            // no Escape — the deletion is underway server-side, whether
            // just queued or found already running, so the only way
            // forward is the finalize — and, like Verify, no Return
            // shortcut: the click must be deliberate.
            PhiAlertActions {
                signOutAndQuitButton(disabled: false)
            }
        case .finalizing:
            PhiAlertActions {
                signOutAndQuitButton(disabled: true)
            }
        case .failed(let error):
            // Sign-in guidance leaves nothing to retry in place; every other
            // failure stays recoverable through the coordinator, whose key
            // handling on the retried start depends on how this one failed.
            if error == .service(.unauthorized) {
                PhiAlertActions {
                    closeButton
                }
            } else {
                PhiAlertActions(
                    secondaryAction: {
                        closeButton
                    },
                    primaryAction: {
                        // Like Verify, no Return-key shortcut: retrying the
                        // deletion request must be a deliberate click.
                        PhiAlertButton(
                            NSLocalizedString("accountDeletion.failure.retryButton", value: "Try Again",
                                comment: "Account deletion - Button retrying the failed deletion request"
                            ),
                            role: .destructive
                        ) {
                            retry()
                        }
                    }
                )
            }
        }
    }

    private var closeButton: some View {
        PhiAlertButton(
            NSLocalizedString("accountDeletion.closeButton", value: "Close",
                comment: "Account deletion - Button closing the deletion flow dialog"
            )
        ) {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
    }

    private var isVerifying: Bool {
        if case .verifyingCode = viewState.state { return true }
        return false
    }

    private var isCodeComplete: Bool {
        code.count == AccountVerificationCodeInput.length
    }

    /// The resend affordance under the digit boxes. The countdown ticks
    /// against the wall clock: the coordinator only knows the unlock date,
    /// and re-rendering each second is purely presentational.
    private var resendRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = AccountVerificationResendCountdown.remainingSeconds(
                until: viewState.resendAvailableAt,
                now: context.date
            )
            let isLocked = isVerifying || remaining > 0
            Button(action: resend) {
                Text(
                    remaining > 0
                        ? String(format: Self.resendCooldownFormat, remaining)
                        : Self.resendText
                )
                .themedForeground(isLocked ? .textSecondary : .themeColor)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
        }
    }

    /// The finalize confirmation, kept on screen (disabled) while the
    /// clears run so the state switch does not reflow the dialog.
    private func signOutAndQuitButton(disabled: Bool) -> some View {
        PhiAlertButton(
            NSLocalizedString("accountDeletion.completion.signOutAndQuitButton", value: "Sign Out and Quit",
                comment: "Account deletion - Button confirming the finalize: Phi clears its local data, signs out and quits"
            ),
            role: .destructive
        ) {
            finalize()
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func cancelButton(disabled: Bool) -> some View {
        PhiAlertButton(
            NSLocalizedString("accountDeletion.cancelButton", value: "Cancel",
                comment: "Account deletion - Button abandoning the deletion flow without deleting anything"
            )
        ) {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private static let requestingFormat = NSLocalizedString("accountDeletion.verification.sendingCodeProgress", value: "Sending a verification code to %@…",
        comment: "Account deletion - Progress text while the deletion request is in flight. %@ is the masked account email"
    )

    private static let enterCodeFormat = NSLocalizedString("accountDeletion.verification.codePrompt", value: "Enter the 6-digit code sent to %@.",
        comment: "Account deletion - Prompt above the verification code boxes. %@ is the masked account email"
    )

    private static let verifyingText = NSLocalizedString("accountDeletion.verification.verifyingProgress", value: "Verifying the code…",
        comment: "Account deletion - Progress text while the verification code is being checked"
    )

    private static let resendText = NSLocalizedString("accountDeletion.verification.resendButton", value: "Resend Code",
        comment: "Account deletion - Button requesting a fresh verification code"
    )

    private static let resendCooldownFormat = NSLocalizedString("accountDeletion.verification.resendCooldownButton", value: "Resend Code (%ds)",
        comment: "Account deletion - Resend button label while the one-minute cooldown runs. %d is the seconds remaining"
    )

    private static let submittedText = NSLocalizedString("accountDeletion.submission.successMessage", value: "Your deletion request has been submitted. You will receive an email receipt once the deletion is complete.\n\nPhi will now sign you out, remove its data from this Mac, and quit.",
        comment: "Account deletion - Text shown once the deletion request is queued server-side; the deletion itself has not finished yet, and the finalize confirmation comes next"
    )

    private static let finalizingText = NSLocalizedString("accountDeletion.finalizingProgress", value: "Signing you out and removing Phi's data from this Mac…",
        comment: "Account deletion - Progress text while the finalize clears local data, right before the app quits"
    )

    private static let alreadyRunningText = NSLocalizedString("accountDeletion.submission.alreadyInProgressMessage", value: "A deletion request for this account is already being processed. You will receive an email receipt once the deletion is complete.\n\nPhi will now sign you out, remove its data from this Mac, and quit.",
        comment: "Account deletion - Text shown when a previous deletion request is already running server-side; the finalize confirmation comes next, as after a submission"
    )

    private static let codeAccessibilityLabel = NSLocalizedString(
        "accountDeletion.verification.codeField.accessibilityLabel",
        value: "Verification code",
        comment: "Account deletion - Accessibility label of the verification code input"
    )
}
