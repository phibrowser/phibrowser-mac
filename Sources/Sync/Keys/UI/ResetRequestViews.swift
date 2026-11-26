// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// The pages of starting sync over from a Mac that is not set up for sync (docs/sync.md,
/// "Starting over from a Mac that is not set up for sync"). Purely presentational: every
/// transition is `KeyLayerViewModel`'s.

/// The explanation page, and the fresh sign-in that follows it.
struct ResetExplanationView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(ResetRequestStrings.explanationTitle)
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ResetRequestStrings.explanationStatements.enumerated()), id: \.offset) { _, statement in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•")
                        Text(statement).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.body)
                    .themedForeground(.textPrimary)
                }
            }

            Button(ResetRequestStrings.explanationLearnMore) { SyncHelpLinks.openStartOver() }
                .buttonStyle(.link)
                .font(.callout)

            if let error = viewModel.inputError {
                Text(error).font(.callout).foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button(ResetRequestStrings.back) { viewModel.leaveStartOver() }
                    .buttonStyle(.bordered)
                Button(ResetRequestStrings.explanationContinue) {
                    Task { await viewModel.continueStartOver() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(minWidth: 420, alignment: .leading)
    }
}

/// Shown while the fresh sign-in waits in the browser.
struct ResetSigningInView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
            Text(ResetRequestStrings.signInTitle)
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)
            Text(ResetRequestStrings.signInMessage)
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)
            Button(ResetRequestStrings.signInCancel) { viewModel.cancelStartOverSignIn() }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}

/// The waiting page: the request is pending until `executeAfter`. **Close** keeps it.
struct WaitingForResetView: View {
    @ObservedObject var viewModel: KeyLayerViewModel
    let executeAfter: Date
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(ResetRequestStrings.waitingTitle)
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)
            Text(ResetRequestStrings.waitingMessage(executeAfter: executeAfter))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let error = viewModel.inputError {
                Text(error).font(.callout).foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button(ResetRequestStrings.cancelRequest) {
                    Task { await viewModel.cancelResetRequest() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.workingOperation)
                Button(ResetRequestStrings.close) { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.workingOperation)
            }
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}

/// A refusal or the end of a request. Every one returns to the join-method page except an
/// expired request, which offers to start over again.
struct ResetRefusalView: View {
    @ObservedObject var viewModel: KeyLayerViewModel
    let refusal: ResetRefusal

    var body: some View {
        VStack(spacing: 24) {
            Text(title).font(.title2.bold()).themedForeground(.textPrimaryStrong)
            Text(message)
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if refusal == .expired {
                Button(ResetRequestStrings.startOverAgain) { viewModel.startOverAgain() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(ResetRequestStrings.back) { viewModel.leaveStartOver() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(minWidth: 360)
    }

    private var title: String {
        switch refusal {
        case .devicesActive: return ResetRequestStrings.devicesActiveTitle
        case .requestExists: return ResetRequestStrings.requestExistsTitle
        case .denied: return ResetRequestStrings.deniedTitle
        case .expired: return ResetRequestStrings.expiredTitle
        }
    }

    private var message: String {
        switch refusal {
        case .devicesActive(let lastActiveAt): return ResetRequestStrings.devicesActiveMessage(lastActiveAt: lastActiveAt)
        case .requestExists(let executeAfter): return ResetRequestStrings.requestExistsMessage(executeAfter: executeAfter)
        case .denied: return ResetRequestStrings.deniedMessage
        case .expired: return ResetRequestStrings.expiredMessage
        }
    }
}

/// A start over failure whose outcome is unknown: Try again resumes the journaled request.
struct ResetErrorView: View {
    @ObservedObject var viewModel: KeyLayerViewModel
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            Text(NSLocalizedString("sync.setup.error.title", value: "Something went wrong", comment: "Sync setup - title of the error page"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)
            Text(message)
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button(ResetRequestStrings.back) { viewModel.leaveStartOver() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.workingOperation)
                Button(ResetRequestStrings.retry) { Task { await viewModel.retryReset() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.workingOperation)
            }
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}

#if DEBUG
#Preview("Start Over Explanation") { ResetExplanationView(viewModel: KeyLayerViewModel.preview()) }
#Preview("Waiting For Reset") {
    WaitingForResetView(viewModel: KeyLayerViewModel.preview(),
                        executeAfter: Date().addingTimeInterval(48 * 3600), onClose: {})
}
#endif
