// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum AccountDataExportFlowError: Equatable {
    case service(AccountDataExportServiceError)
    case taskEnded(AccountDataExportTaskStatus)
    case network

    var isIndeterminate: Bool {
        switch self {
        case .network, .service(.serverError):
            return true
        case .service, .taskEnded:
            return false
        }
    }
}

/// Drives the trusted native half of the account data export flow. Chromium
/// only relays the settings click; this coordinator owns idempotency, token
/// renewal, resend timing and the two Oblivion calls.
@MainActor
final class AccountDataExportCoordinator {
    typealias RequestExport = (_ idempotencyKey: String) async throws -> AccountDataExportRequestOutcome
    typealias VerifyExport = (
        _ requestID: String,
        _ code: String
    ) async throws -> AccountDataExportVerificationOutcome
    typealias RenewCredentials = () async -> Bool
    typealias IsSessionCurrent = () -> Bool
    typealias Sleep = (_ seconds: TimeInterval) async -> Void

    static let transientRetryDelay: TimeInterval = 1

    enum State: Equatable {
        case idle
        case requestingExport
        case awaitingVerificationCode(
            requestID: String,
            expiresAt: Date,
            error: AccountDataExportFlowError?
        )
        case verifyingCode(requestID: String)
        case exportAccepted(taskID: String, status: AccountDataExportTaskStatus)
        case failed(AccountDataExportFlowError)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?

    static let resendCooldown: TimeInterval = 60
    private(set) var resendAvailableAt: Date?

    private let requestExport: RequestExport
    private let verifyExport: VerifyExport
    private let renewCredentials: RenewCredentials
    private let now: () -> Date
    private let makeIdempotencyKey: () -> String
    private let isSessionCurrent: IsSessionCurrent
    private let sleep: Sleep

    private var idempotencyKey: String?
    private var pendingResendKey: String?

    init(
        requestExport: @escaping RequestExport = { idempotencyKey in
            try await APIClient.shared.requestAccountDataExport(
                idempotencyKey: idempotencyKey
            )
        },
        verifyExport: @escaping VerifyExport = { requestID, code in
            try await APIClient.shared.verifyAccountDataExport(
                requestID: requestID,
                code: code
            )
        },
        renewCredentials: @escaping RenewCredentials = {
            let renewed = await AuthManager.shared.renewCredentialsAsync(
                operation: "account data export",
                force: true
            )
            return renewed != nil
        },
        now: @escaping () -> Date = Date.init,
        makeIdempotencyKey: @escaping () -> String = AccountDataExportCoordinator.defaultIdempotencyKey,
        isSessionCurrent: @escaping IsSessionCurrent = { true },
        sleep: @escaping Sleep = { seconds in
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.requestExport = requestExport
        self.verifyExport = verifyExport
        self.renewCredentials = renewCredentials
        self.now = now
        self.makeIdempotencyKey = makeIdempotencyKey
        self.isSessionCurrent = isSessionCurrent
        self.sleep = sleep
    }

    nonisolated static func defaultIdempotencyKey() -> String {
        UUID().uuidString.lowercased()
    }

    func start() async {
        guard ensureSessionCurrent() else { return }
        switch state {
        case .idle, .failed:
            break
        case .requestingExport, .awaitingVerificationCode,
             .verifyingCode, .exportAccepted:
            AppLogInfo("[AccountDataExport] Flow already underway, ignoring start")
            return
        }

        state = .requestingExport
        let key = idempotencyKey ?? makeIdempotencyKey()
        idempotencyKey = key
        do {
            let outcome = try await retryingTransientServerError {
                try await self.requestExport(key)
            }
            acceptFirstStepOutcome(outcome)
        } catch {
            AppLogError("[AccountDataExport] Export request failed: \(error)")
            let flowError = Self.flowError(from: error)
            if !flowError.isIndeterminate {
                idempotencyKey = nil
            }
            state = .failed(flowError)
        }
    }

    func resendCode() async {
        guard ensureSessionCurrent() else { return }
        guard case .awaitingVerificationCode(
            let currentRequestID,
            let currentExpiresAt,
            _
        ) = state else {
            AppLogInfo("[AccountDataExport] No verification pending, ignoring resend")
            return
        }
        if let availableAt = resendAvailableAt, now() < availableAt {
            AppLogInfo("[AccountDataExport] Resend still cooling down, ignoring")
            return
        }

        let key = pendingResendKey ?? makeIdempotencyKey()
        idempotencyKey = key
        state = .requestingExport
        do {
            let outcome = try await retryingTransientServerError {
                try await self.requestExport(key)
            }
            acceptFirstStepOutcome(outcome)
        } catch {
            AppLogError("[AccountDataExport] Verification-code resend failed: \(error)")
            let flowError = Self.flowError(from: error)
            if flowError == .service(.rateLimited) {
                pendingResendKey = nil
                state = .failed(flowError)
                return
            }
            pendingResendKey = flowError.isIndeterminate ? key : nil
            resendAvailableAt = now().addingTimeInterval(Self.resendCooldown)
            state = .awaitingVerificationCode(
                requestID: currentRequestID,
                expiresAt: currentExpiresAt,
                error: flowError
            )
        }
    }

    func submitCode(_ code: String) async {
        guard ensureSessionCurrent() else { return }
        guard case .awaitingVerificationCode(
            let requestID,
            let expiresAt,
            _
        ) = state else {
            AppLogInfo("[AccountDataExport] No verification pending, ignoring code")
            return
        }
        guard now() < expiresAt else {
            state = .awaitingVerificationCode(
                requestID: requestID,
                expiresAt: expiresAt,
                error: .service(.expired)
            )
            return
        }

        state = .verifyingCode(requestID: requestID)
        do {
            let outcome = try await retryingTransientServerError {
                try await self.verifyExport(requestID, code)
            }
            acceptTask(taskID: outcome.taskID, status: outcome.status)
        } catch {
            AppLogError("[AccountDataExport] Verification failed: \(error)")
            let flowError = Self.flowError(from: error)
            if flowError == .service(.rateLimited) {
                state = .failed(flowError)
                return
            }
            state = .awaitingVerificationCode(
                requestID: requestID,
                expiresAt: expiresAt,
                error: flowError
            )
        }
    }

    /// Clears only the local flow state. An accepted export remains queued on
    /// the service and is rediscovered the next time the user opens the flow.
    func dismiss() {
        switch state {
        case .requestingExport, .verifyingCode:
            AppLogInfo("[AccountDataExport] Dismiss ignored while a request is in flight")
        case .idle, .awaitingVerificationCode, .exportAccepted, .failed:
            idempotencyKey = nil
            pendingResendKey = nil
            resendAvailableAt = nil
            state = .idle
        }
    }

    private func acceptFirstStepOutcome(_ outcome: AccountDataExportRequestOutcome) {
        pendingResendKey = nil
        switch outcome {
        case .verificationCodeSent(let requestID, let expiresAt):
            resendAvailableAt = now().addingTimeInterval(Self.resendCooldown)
            state = .awaitingVerificationCode(
                requestID: requestID,
                expiresAt: expiresAt,
                error: nil
            )
        case .existingTask(let taskID, let status):
            acceptTask(taskID: taskID, status: status)
        }
    }

    private func acceptTask(taskID: String, status: AccountDataExportTaskStatus) {
        if status.isActive || status == .delivered {
            state = .exportAccepted(taskID: taskID, status: status)
            return
        }

        idempotencyKey = nil
        state = .failed(.taskEnded(status))
    }

    private func retryingAfterTokenRenewal<T>(
        _ call: () async throws -> T
    ) async throws -> T {
        guard isSessionCurrent() else {
            throw AccountDataExportServiceError.unauthorized
        }
        do {
            let result = try await call()
            guard isSessionCurrent() else {
                throw AccountDataExportServiceError.unauthorized
            }
            return result
        } catch AccountDataExportServiceError.unauthorized {
            AppLogInfo("[AccountDataExport] Access token rejected; renewing once")
            guard await renewCredentials() else {
                throw AccountDataExportServiceError.unauthorized
            }
            guard isSessionCurrent() else {
                throw AccountDataExportServiceError.unauthorized
            }
            let result = try await call()
            guard isSessionCurrent() else {
                throw AccountDataExportServiceError.unauthorized
            }
            return result
        }
    }

    private func retryingTransientServerError<T>(
        _ call: () async throws -> T
    ) async throws -> T {
        do {
            return try await retryingAfterTokenRenewal(call)
        } catch let error as AccountDataExportServiceError {
            guard case .serverError = error else { throw error }
            await sleep(Self.transientRetryDelay)
            return try await retryingAfterTokenRenewal(call)
        }
    }

    private func ensureSessionCurrent() -> Bool {
        guard isSessionCurrent() else {
            idempotencyKey = nil
            pendingResendKey = nil
            resendAvailableAt = nil
            state = .failed(.service(.unauthorized))
            return false
        }
        return true
    }

    private static func flowError(from error: Error) -> AccountDataExportFlowError {
        if let serviceError = error as? AccountDataExportServiceError {
            return .service(serviceError)
        }
        return .network
    }
}
