// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

enum AccountDataExportErrorCopy {
    static func inlineMessage(for error: AccountDataExportFlowError) -> String {
        switch error {
        case .service(.invalidRequest):
            return wrongCodeText
        case .service(.expired):
            return codeExpiredText
        case .service, .taskEnded, .network:
            return failureMessage(for: error)
        }
    }

    static func failureMessage(for error: AccountDataExportFlowError) -> String {
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
        case .taskEnded:
            return taskEndedText
        case .network:
            return networkText
        }
    }

    private static let wrongCodeText = NSLocalizedString(
        "accountDataExport.verification.invalidCodeError",
        value: "That code isn't correct. Check the code from the email and try again.",
        comment: "Account data export - Inline error when the submitted verification code is rejected"
    )
    private static let codeExpiredText = NSLocalizedString(
        "accountDataExport.verification.expiredCodeError",
        value: "That code has expired. Click Resend Code to get a new one.",
        comment: "Account data export - Inline error when the verification code expired"
    )
    private static let rateLimitedText = NSLocalizedString(
        "accountDataExport.verification.rateLimitError",
        value: "Too many attempts for now. Please wait a few minutes and try again.",
        comment: "Account data export - Error when the service rate limit is hit"
    )
    private static let signedOutText = NSLocalizedString(
        "accountDataExport.sessionExpiredError",
        value: "Your session has expired. Please sign in again, then restart the export.",
        comment: "Account data export - Error when the access token remains rejected after renewal"
    )
    private static let serverErrorText = NSLocalizedString(
        "accountDataExport.serviceUnavailableError",
        value: "The data export service is temporarily unavailable. Please try again later.",
        comment: "Account data export - Error when the service reports a server error"
    )
    private static let genericText = NSLocalizedString(
        "accountDataExport.genericError",
        value: "Something went wrong. Please try again later.",
        comment: "Account data export - Generic failure that does not reveal account existence"
    )
    private static let networkText = NSLocalizedString(
        "accountDataExport.networkError",
        value: "Couldn't reach the data export service. Check your internet connection and try again.",
        comment: "Account data export - Error when the network request cannot complete"
    )
    private static let taskEndedText = NSLocalizedString(
        "accountDataExport.previousTaskEndedError",
        value: "That export is no longer available. Try again to request a new one.",
        comment: "Account data export - Error when a previously returned export task has ended without an available download"
    )
}

@MainActor
final class AccountDataExportFlowViewState: ObservableObject {
    @Published var state: AccountDataExportCoordinator.State = .idle
    @Published var resendAvailableAt: Date?
}

struct AccountDataExportFlowView: View {
    @ObservedObject var viewState: AccountDataExportFlowViewState
    let maskedEmail: String
    let dismiss: PhiAlertDismissAction
    let submit: (String) -> Void
    let resend: () -> Void
    let retry: () -> Void

    @State private var code = ""
    @Environment(\.phiAppearance) private var appearance

    private static let contentHeight: CGFloat = 144
    private static let statusSlotHeight: CGFloat = 34

    var body: some View {
        PhiAlert(
            title: NSLocalizedString(
                "accountDataExport.window.title",
                value: "Export Account Data",
                comment: "Account data export - Title of the verification and status dialog"
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
            if case .verifyingCode = oldState,
               case .awaitingVerificationCode(_, _, let error) = newState,
               error != nil {
                code = ""
            }
            if case .requestingExport = oldState,
               case .awaitingVerificationCode(_, _, let error) = newState,
               error == nil {
                code = ""
            }
            switch newState {
            case .idle, .exportAccepted, .failed:
                code = ""
            case .requestingExport, .awaitingVerificationCode, .verifyingCode:
                break
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewState.state {
        case .idle, .requestingExport:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
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
        case .exportAccepted(_, let status):
            Text(status == .delivered ? Self.deliveredText : Self.acceptedText)
        case .failed(let error):
            Text(AccountDataExportErrorCopy.failureMessage(for: error))
        }
    }

    private var statusLine: some View {
        Group {
            if isVerifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.verifyingText)
                }
            } else if let error = inlineError {
                Text(AccountDataExportErrorCopy.inlineMessage(for: error))
                    .foregroundStyle(.red)
            } else {
                Text(String(format: Self.enterCodeFormat, maskedEmail))
            }
        }
        .frame(height: Self.statusSlotHeight, alignment: .topLeading)
    }

    private var inlineError: AccountDataExportFlowError? {
        if case .awaitingVerificationCode(_, _, let error) = viewState.state {
            return error
        }
        return nil
    }

    @ViewBuilder
    private var stateActions: some View {
        switch viewState.state {
        case .idle, .requestingExport:
            PhiAlertActions { cancelButton(disabled: true) }
        case .awaitingVerificationCode, .verifyingCode:
            PhiAlertActions(
                secondaryAction: { cancelButton(disabled: isVerifying) },
                primaryAction: {
                    PhiAlertButton(Self.verifyText, role: .primary) {
                        submit(code)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isVerifying || !isCodeComplete)
                    .opacity(isVerifying || !isCodeComplete ? 0.5 : 1)
                }
            )
        case .exportAccepted:
            PhiAlertActions { closeButton }
        case .failed(let error):
            if error == .service(.unauthorized) ||
                error == .service(.rateLimited) {
                PhiAlertActions { closeButton }
            } else {
                PhiAlertActions(
                    secondaryAction: { closeButton },
                    primaryAction: {
                        PhiAlertButton(Self.tryAgainText, role: .primary) {
                            retry()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                )
            }
        }
    }

    private var closeButton: some View {
        PhiAlertButton(Self.closeText) { dismiss() }
            .keyboardShortcut(.cancelAction)
    }

    private func cancelButton(disabled: Bool) -> some View {
        PhiAlertButton(Self.cancelText) { dismiss() }
            .keyboardShortcut(.cancelAction)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
    }

    private var isVerifying: Bool {
        if case .verifyingCode = viewState.state { return true }
        return false
    }

    private var isCodeComplete: Bool {
        code.count == AccountVerificationCodeInput.length
    }

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

    private static let requestingFormat = NSLocalizedString(
        "accountDataExport.verification.sendingCodeProgress",
        value: "Sending a verification code to %@…",
        comment: "Account data export - Progress while requesting a code. %@ is the masked account email"
    )
    private static let enterCodeFormat = NSLocalizedString(
        "accountDataExport.verification.codePrompt",
        value: "Enter the 6-digit code sent to %@.",
        comment: "Account data export - Verification prompt. %@ is the masked account email"
    )
    private static let verifyingText = NSLocalizedString(
        "accountDataExport.verification.verifyingProgress",
        value: "Verifying the code…",
        comment: "Account data export - Progress while checking the verification code"
    )
    private static let resendText = NSLocalizedString(
        "accountDataExport.verification.resendButton",
        value: "Resend Code",
        comment: "Account data export - Button requesting a fresh verification code"
    )
    private static let resendCooldownFormat = NSLocalizedString(
        "accountDataExport.verification.resendCooldownButton",
        value: "Resend Code (%ds)",
        comment: "Account data export - Disabled resend label. %d is the seconds remaining"
    )
    private static let verifyText = NSLocalizedString(
        "accountDataExport.verification.verifyButton",
        value: "Verify",
        comment: "Account data export - Button submitting the emailed verification code"
    )
    private static let acceptedText = NSLocalizedString(
        "accountDataExport.submission.acceptedMessage",
        value: "We're preparing your data export. We'll email you a download link when it's ready. The link will be available for seven days.",
        comment: "Account data export - Message after an export task is accepted but not yet complete"
    )
    private static let deliveredText = NSLocalizedString(
        "accountDataExport.submission.deliveredMessage",
        value: "Your data export is ready. Check your email for the download link. The link will be available for seven days.",
        comment: "Account data export - Message when an existing task has already sent its download email"
    )
    private static let tryAgainText = NSLocalizedString(
        "accountDataExport.failure.retryButton",
        value: "Try Again",
        comment: "Account data export - Button retrying a failed export request"
    )
    private static let closeText = NSLocalizedString(
        "accountDataExport.closeButton",
        value: "Close",
        comment: "Account data export - Button closing the flow dialog"
    )
    private static let cancelText = NSLocalizedString(
        "accountDataExport.cancelButton",
        value: "Cancel",
        comment: "Account data export - Button abandoning verification without cancelling a server task"
    )

    private static let codeAccessibilityLabel = NSLocalizedString(
        "accountDataExport.verification.codeField.accessibilityLabel",
        value: "Verification code",
        comment: "Account data export - Accessibility label for the verification code field"
    )
}
