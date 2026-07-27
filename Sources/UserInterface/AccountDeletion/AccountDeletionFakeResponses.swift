// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#if DEBUG

import Foundation

/// A debug-only branch of the deletion flow, selected from the *DEBUG* menu.
/// Each scenario plays out one server behavior without any network request,
/// so every UI branch can be exercised without a deletable account, without
/// burning the daily verification-email quota, and without waiting out real
/// expiry or cooldown windows.
enum AccountDeletionFakeScenario: CaseIterable {
    /// Both steps succeed; any submitted code is accepted.
    case success
    /// The "emailed" code is `AccountDeletionFakeResponses.acceptedCode`;
    /// any other entry fails verification like a mistyped code, so the
    /// inline error, in-place re-entry, and eventual recovery are all
    /// observable.
    case wrongCode
    /// Verification always fails as it would after the code's 10-minute
    /// lifetime.
    case codeExpired
    /// The first step fails as it would when the send quota or minimum
    /// resend interval is hit.
    case rateLimited
    /// The first step fails with a 500.
    case serverError
    /// The first step reports a deletion already running server-side: no
    /// code is sent and verification is skipped.
    case deletionAlreadyRunning
    /// Both steps reject the access token, and the faked renewal "succeeds",
    /// so the renew-and-retry-once path runs end to end and lands on the
    /// sign-in-again guidance.
    case tokenExpired
    /// The first step fails like a 404; the copy must stay generic and not
    /// reveal whether an account exists.
    case notFound
    /// Both steps fail with a connection loss, as when the network drops
    /// mid-flow.
    case networkFailure

    var menuTitle: String {
        switch self {
        case .success:
            return "Success"
        case .wrongCode:
            return "Wrong Code"
        case .codeExpired:
            return "Code Expired"
        case .rateLimited:
            return "Rate Limited"
        case .serverError:
            return "Server Error"
        case .deletionAlreadyRunning:
            return "Deletion Already Running"
        case .tokenExpired:
            return "Token Expired"
        case .notFound:
            return "Not Found"
        case .networkFailure:
            return "Network Failure"
        }
    }
}

/// Debug-only fake Oblivion responses. The fakes enter through the
/// coordinator's existing injection seam — its default closures consult
/// `scenario` before touching `APIClient` — so there is no second mock path,
/// and none of this compiles into release builds.
@MainActor
enum AccountDeletionFakeResponses {
    /// The scenario the next fake call plays, nil when fake mode is off.
    /// Deliberately in-memory only: every launch starts on the real network,
    /// so a forgotten selection cannot masquerade as a broken flow later.
    static var scenario: AccountDeletionFakeScenario?

    /// The code `wrongCode` accepts, standing in for the emailed one.
    static let acceptedCode = "123456"

    /// The request identifier every fake first step hands out.
    static let requestID = "fake-request"

    /// Artificial latency so the in-flight UI states stay observable.
    /// Tests set it to zero.
    static var responseDelay: TimeInterval = 1

    static func playRequest(
        _ scenario: AccountDeletionFakeScenario
    ) async throws -> AccountDeletionRequestOutcome {
        AppLogInfo("🗑️ [AccountDeletion] Playing fake deletion request: \(scenario)")
        try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        return try requestOutcome(for: scenario)
    }

    static func playVerify(
        _ scenario: AccountDeletionFakeScenario, code: String
    ) async throws {
        // Never log the code, fake or not.
        AppLogInfo("🗑️ [AccountDeletion] Playing fake verification: \(scenario)")
        try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        try verifyOutcome(for: scenario, code: code)
    }

    /// The renew-credentials edge in fake mode: pretends the renewal
    /// succeeded so the coordinator's one retry plays out, without touching
    /// the real Auth0 session.
    static func playRenewCredentials(_ scenario: AccountDeletionFakeScenario) -> Bool {
        AppLogInfo("🗑️ [AccountDeletion] Playing fake credential renewal: \(scenario)")
        return true
    }

    /// First-step mapping, pure so tests can pin every branch.
    static func requestOutcome(
        for scenario: AccountDeletionFakeScenario
    ) throws -> AccountDeletionRequestOutcome {
        switch scenario {
        case .success, .wrongCode, .codeExpired:
            return .verificationCodeSent(requestID: requestID)
        case .deletionAlreadyRunning:
            return .deletionAlreadyRunning
        case .rateLimited:
            throw AccountDeletionServiceError.rateLimited
        case .serverError:
            throw AccountDeletionServiceError.serverError(statusCode: 500)
        case .tokenExpired:
            throw AccountDeletionServiceError.unauthorized
        case .notFound:
            throw AccountDeletionServiceError.notFound
        case .networkFailure:
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Verification mapping, pure so tests can pin every branch. Scenarios
    /// that already failed the first step keep their error here too: the
    /// flow cannot reach verification for them, and mirroring the error
    /// keeps the mapping total instead of inventing a special case.
    static func verifyOutcome(
        for scenario: AccountDeletionFakeScenario, code: String
    ) throws {
        switch scenario {
        case .success, .deletionAlreadyRunning:
            return
        case .wrongCode:
            guard code == acceptedCode else {
                throw AccountDeletionServiceError.invalidRequest
            }
        case .codeExpired:
            throw AccountDeletionServiceError.expired
        case .rateLimited:
            throw AccountDeletionServiceError.rateLimited
        case .serverError:
            throw AccountDeletionServiceError.serverError(statusCode: 500)
        case .tokenExpired:
            throw AccountDeletionServiceError.unauthorized
        case .notFound:
            throw AccountDeletionServiceError.notFound
        case .networkFailure:
            throw URLError(.notConnectedToInternet)
        }
    }
}

#endif
