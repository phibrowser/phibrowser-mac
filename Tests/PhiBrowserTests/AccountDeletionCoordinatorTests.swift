// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class AccountDeletionCoordinatorTests: XCTestCase {
    private var recordedStates: [AccountDeletionCoordinator.State] = []

    /// Records every invocation of the finalize edges in order — the
    /// Sentinel announcement plus the destructive edges. Only the finalize
    /// may reach them: the credential fence precedes the announcement and
    /// surrounds the long local-data removal, and quit runs last.
    private var destructiveEdgeEvents: [String] = []

    private func makeCoordinator(
        requestDeletion: @escaping AccountDeletionCoordinator.RequestDeletion = { _ in
            .verificationCodeSent(requestID: "req-1")
        },
        verifyDeletion: @escaping AccountDeletionCoordinator.VerifyDeletion = { _, _ in },
        renewCredentials: @escaping AccountDeletionCoordinator.RenewCredentials = { false },
        makeIdempotencyKey: @escaping () -> String = { "key-1" },
        now: @escaping () -> Date = Date.init,
        beginCredentialDeletion: AccountDeletionCoordinator.BeginCredentialDeletion? = nil,
        clearInitialCredentials: AccountDeletionCoordinator.ClearInitialCredentials? = nil,
        clearCredentials: AccountDeletionCoordinator.ClearCredentials? = nil,
        clearLocalData: AccountDeletionCoordinator.ClearLocalData? = nil
    ) -> AccountDeletionCoordinator {
        let coordinator = AccountDeletionCoordinator(
            requestDeletion: requestDeletion,
            verifyDeletion: verifyDeletion,
            renewCredentials: renewCredentials,
            announceAccountDeleted: { [weak self] in
                self?.destructiveEdgeEvents.append("announceAccountDeleted")
            },
            beginCredentialDeletion: { [weak self] in
                self?.destructiveEdgeEvents.append("beginCredentialDeletion")
                return beginCredentialDeletion?() ?? true
            },
            clearInitialCredentials: { [weak self] in
                self?.destructiveEdgeEvents.append("clearInitialCredentials")
                await clearInitialCredentials?()
            },
            clearCredentials: { [weak self] in
                self?.destructiveEdgeEvents.append("clearCredentials")
                await clearCredentials?()
            },
            clearLocalData: { [weak self] in
                self?.destructiveEdgeEvents.append("clearLocalData")
                await clearLocalData?()
            },
            quit: { [weak self] in self?.destructiveEdgeEvents.append("quit") },
            now: now,
            makeIdempotencyKey: makeIdempotencyKey
        )
        coordinator.onStateChange = { [weak self] state in
            self?.recordedStates.append(state)
        }
        return coordinator
    }

    private func waitForRecordedStates(atLeast count: Int) async {
        for _ in 0..<1_000 where recordedStates.count < count {
            await Task.yield()
        }
    }

    /// Yields until `condition` holds (or the yield budget runs out), for
    /// tests that must catch a coordinator mid-flight.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
    }

    // MARK: - Happy path

    func testStartRequestsDeletionWithGeneratedIdempotencyKey() async {
        var capturedKeys: [String] = []
        let coordinator = makeCoordinator(
            requestDeletion: { idempotencyKey in
                capturedKeys.append(idempotencyKey)
                return .verificationCodeSent(requestID: "req-7")
            },
            makeIdempotencyKey: { "generated-key" }
        )

        await coordinator.start()

        XCTAssertEqual(capturedKeys, ["generated-key"])
        XCTAssertEqual(
            recordedStates,
            [.requestingDeletion, .awaitingVerificationCode(requestID: "req-7", error: nil)]
        )
    }

    func testSubmitCodeVerifiesAndReportsSubmission() async {
        var capturedCalls: [(requestID: String, code: String)] = []
        let coordinator = makeCoordinator(verifyDeletion: { requestID, code in
            capturedCalls.append((requestID, code))
        })

        await coordinator.start()
        await coordinator.submitCode("123456")

        XCTAssertEqual(capturedCalls.count, 1)
        XCTAssertEqual(capturedCalls.first?.requestID, "req-1")
        XCTAssertEqual(capturedCalls.first?.code, "123456")
        XCTAssertEqual(
            recordedStates,
            [
                .requestingDeletion,
                .awaitingVerificationCode(requestID: "req-1", error: nil),
                .verifyingCode(requestID: "req-1"),
                .requestSubmitted,
            ]
        )
    }

    // MARK: - Already-running deletion

    func testStartWithRunningDeletionSkipsVerification() async {
        var verifyCallCount = 0
        let coordinator = makeCoordinator(
            requestDeletion: { _ in .deletionAlreadyRunning },
            verifyDeletion: { _, _ in verifyCallCount += 1 }
        )

        await coordinator.start()

        XCTAssertEqual(verifyCallCount, 0)
        XCTAssertEqual(recordedStates, [.requestingDeletion, .deletionAlreadyRunning])
    }

    // MARK: - Single flight

    func testStartWhileRequestInFlightIsIgnored() async {
        var requestCallCount = 0
        var resumeRequest: CheckedContinuation<AccountDeletionRequestOutcome, Error>?
        let coordinator = makeCoordinator(requestDeletion: { _ in
            requestCallCount += 1
            return try await withCheckedThrowingContinuation { resumeRequest = $0 }
        })

        let firstStart = Task { await coordinator.start() }
        await waitForRecordedStates(atLeast: 1)

        await coordinator.start()

        XCTAssertEqual(requestCallCount, 1)

        resumeRequest?.resume(returning: .verificationCodeSent(requestID: "req-1"))
        await firstStart.value

        XCTAssertEqual(coordinator.state, .awaitingVerificationCode(requestID: "req-1", error: nil))
    }

    func testStartWhileAwaitingCodeIsIgnored() async {
        var requestCallCount = 0
        let coordinator = makeCoordinator(requestDeletion: { _ in
            requestCallCount += 1
            return .verificationCodeSent(requestID: "req-1")
        })

        await coordinator.start()
        await coordinator.start()

        XCTAssertEqual(requestCallCount, 1)
        XCTAssertEqual(coordinator.state, .awaitingVerificationCode(requestID: "req-1", error: nil))
    }

    func testSubmitCodeWithoutPendingRequestIsIgnored() async {
        var verifyCallCount = 0
        let coordinator = makeCoordinator(verifyDeletion: { _, _ in verifyCallCount += 1 })

        await coordinator.submitCode("123456")

        XCTAssertEqual(verifyCallCount, 0)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(recordedStates, [])
    }

    // MARK: - Failures

    func testRequestServiceFailureSurfacesAsServiceError() async {
        let coordinator = makeCoordinator(requestDeletion: { _ in
            throw AccountDeletionServiceError.rateLimited
        })

        await coordinator.start()

        XCTAssertEqual(coordinator.state, .failed(.service(.rateLimited)))
    }

    func testRequestTransportFailureSurfacesAsNetworkError() async {
        let coordinator = makeCoordinator(requestDeletion: { _ in
            throw URLError(.notConnectedToInternet)
        })

        await coordinator.start()

        XCTAssertEqual(coordinator.state, .failed(.network))
    }

    func testVerifyFailureFallsBackToCodeEntryWithInlineError() async {
        let coordinator = makeCoordinator(verifyDeletion: { _, _ in
            throw AccountDeletionServiceError.invalidRequest
        })

        await coordinator.start()
        await coordinator.submitCode("000000")

        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(requestID: "req-1", error: .service(.invalidRequest))
        )
    }

    func testWrongCodeCanBeResubmittedWithoutNewDeletionRequest() async {
        var requestCallCount = 0
        var verifyAttempts: [String] = []
        let coordinator = makeCoordinator(
            requestDeletion: { _ in
                requestCallCount += 1
                return .verificationCodeSent(requestID: "req-1")
            },
            verifyDeletion: { _, code in
                verifyAttempts.append(code)
                if verifyAttempts.count == 1 {
                    throw AccountDeletionServiceError.invalidRequest
                }
            }
        )

        await coordinator.start()
        await coordinator.submitCode("000000")
        await coordinator.submitCode("123456")

        XCTAssertEqual(coordinator.state, .requestSubmitted)
        XCTAssertEqual(verifyAttempts, ["000000", "123456"])
        XCTAssertEqual(
            requestCallCount, 1,
            "Re-entering the code must not restart the flow (that would email a fresh code)"
        )
    }

    func testRetryAfterServerErrorReusesIdempotencyKey() async {
        var capturedKeys: [String] = []
        var keysGenerated = 0
        let coordinator = makeCoordinator(
            requestDeletion: { idempotencyKey in
                capturedKeys.append(idempotencyKey)
                if capturedKeys.count == 1 {
                    throw AccountDeletionServiceError.serverError(statusCode: 500)
                }
                return .verificationCodeSent(requestID: "req-1")
            },
            makeIdempotencyKey: {
                keysGenerated += 1
                return "key-\(keysGenerated)"
            }
        )

        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.service(.serverError(statusCode: 500))))

        await coordinator.start()

        XCTAssertEqual(coordinator.state, .awaitingVerificationCode(requestID: "req-1", error: nil))
        XCTAssertEqual(
            capturedKeys, ["key-1", "key-1"],
            "A retried first step must reuse the original idempotency key"
        )
        XCTAssertEqual(keysGenerated, 1)
    }

    func testRetryAfterNetworkFailureReusesIdempotencyKey() async {
        var capturedKeys: [String] = []
        var keysGenerated = 0
        let coordinator = makeCoordinator(
            requestDeletion: { idempotencyKey in
                capturedKeys.append(idempotencyKey)
                if capturedKeys.count == 1 {
                    throw URLError(.timedOut)
                }
                return .verificationCodeSent(requestID: "req-1")
            },
            makeIdempotencyKey: {
                keysGenerated += 1
                return "key-\(keysGenerated)"
            }
        )

        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.network))

        await coordinator.start()

        XCTAssertEqual(
            capturedKeys, ["key-1", "key-1"],
            "A timed-out attempt may have landed server-side; replaying the key lets Oblivion dedupe"
        )
    }

    func testRetryAfterDefinitiveRejectionMintsFreshKey() async {
        var capturedKeys: [String] = []
        var keysGenerated = 0
        let coordinator = makeCoordinator(
            requestDeletion: { idempotencyKey in
                capturedKeys.append(idempotencyKey)
                if capturedKeys.count == 1 {
                    throw AccountDeletionServiceError.rateLimited
                }
                return .verificationCodeSent(requestID: "req-1")
            },
            makeIdempotencyKey: {
                keysGenerated += 1
                return "key-\(keysGenerated)"
            }
        )

        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.service(.rateLimited)))

        await coordinator.start()

        XCTAssertEqual(
            capturedKeys, ["key-1", "key-2"],
            "A definitive rejection books nothing under the key; replaying it could replay a memoized error forever"
        )
    }

    // MARK: - Token renewal

    func testUnauthorizedRequestRenewsCredentialsAndRetriesOnce() async {
        var capturedKeys: [String] = []
        var renewCallCount = 0
        let coordinator = makeCoordinator(
            requestDeletion: { key in
                capturedKeys.append(key)
                if capturedKeys.count == 1 {
                    throw AccountDeletionServiceError.unauthorized
                }
                return .verificationCodeSent(requestID: "req-1")
            },
            renewCredentials: {
                renewCallCount += 1
                return true
            },
            makeIdempotencyKey: { "key-1" }
        )

        await coordinator.start()

        XCTAssertEqual(renewCallCount, 1)
        XCTAssertEqual(
            capturedKeys, ["key-1", "key-1"],
            "The renewed retry belongs to the same attempt and must reuse its key"
        )
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(requestID: "req-1", error: nil)
        )
    }

    func testUnauthorizedRequestAfterRenewalSurfacesSignInGuidance() async {
        var requestCallCount = 0
        var renewCallCount = 0
        let coordinator = makeCoordinator(
            requestDeletion: { _ in
                requestCallCount += 1
                throw AccountDeletionServiceError.unauthorized
            },
            renewCredentials: {
                renewCallCount += 1
                return true
            }
        )

        await coordinator.start()

        XCTAssertEqual(requestCallCount, 2, "Exactly one retry after the renewal")
        XCTAssertEqual(renewCallCount, 1, "A second rejection must not renew again")
        XCTAssertEqual(coordinator.state, .failed(.service(.unauthorized)))
        XCTAssertEqual(destructiveEdgeEvents, [])
    }

    func testFailedRenewalSkipsTheRetry() async {
        var requestCallCount = 0
        let coordinator = makeCoordinator(
            requestDeletion: { _ in
                requestCallCount += 1
                throw AccountDeletionServiceError.unauthorized
            },
            renewCredentials: { false }
        )

        await coordinator.start()

        XCTAssertEqual(
            requestCallCount, 1,
            "Without fresh credentials a retry would just fail again"
        )
        XCTAssertEqual(coordinator.state, .failed(.service(.unauthorized)))
    }

    func testUnauthorizedVerifyRenewsCredentialsAndRetriesOnce() async {
        var verifyAttempts: [String] = []
        var renewCallCount = 0
        let coordinator = makeCoordinator(
            verifyDeletion: { _, code in
                verifyAttempts.append(code)
                if verifyAttempts.count == 1 {
                    throw AccountDeletionServiceError.unauthorized
                }
            },
            renewCredentials: {
                renewCallCount += 1
                return true
            }
        )

        await coordinator.start()
        await coordinator.submitCode("123456")

        XCTAssertEqual(renewCallCount, 1)
        XCTAssertEqual(
            verifyAttempts, ["123456", "123456"],
            "The renewed retry must resubmit the same code to the same request"
        )
        XCTAssertEqual(coordinator.state, .requestSubmitted)
    }

    func testNonUnauthorizedFailureDoesNotRenew() async {
        var renewCallCount = 0
        let coordinator = makeCoordinator(
            requestDeletion: { _ in throw AccountDeletionServiceError.rateLimited },
            renewCredentials: {
                renewCallCount += 1
                return true
            }
        )

        await coordinator.start()

        XCTAssertEqual(renewCallCount, 0, "Only a rejected token warrants a renewal")
        XCTAssertEqual(coordinator.state, .failed(.service(.rateLimited)))
    }

    func testUnauthorizedResendRenewsAndRetriesUnderTheSameFreshKey() async {
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        var capturedKeys: [String] = []
        var keysGenerated = 0
        var renewCallCount = 0
        let coordinator = makeCoordinator(
            requestDeletion: { key in
                capturedKeys.append(key)
                if capturedKeys.count == 2 {
                    throw AccountDeletionServiceError.unauthorized
                }
                return .verificationCodeSent(requestID: "req-\(capturedKeys.count)")
            },
            renewCredentials: {
                renewCallCount += 1
                return true
            },
            makeIdempotencyKey: {
                keysGenerated += 1
                return "key-\(keysGenerated)"
            },
            now: { clock }
        )

        await coordinator.start()
        clock = clock.addingTimeInterval(60)
        await coordinator.resendCode()

        XCTAssertEqual(renewCallCount, 1)
        XCTAssertEqual(
            capturedKeys, ["key-1", "key-2", "key-2"],
            "The renewed retry is part of the same resend attempt, not a new resend"
        )
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(requestID: "req-3", error: nil)
        )
    }

    // MARK: - Cancel

    func testCancelWhileAwaitingCodeReturnsToIdleAndRestartMakesFreshKey() async {
        var capturedKeys: [String] = []
        var nextKeyNumber = 1
        let coordinator = makeCoordinator(
            requestDeletion: { idempotencyKey in
                capturedKeys.append(idempotencyKey)
                return .verificationCodeSent(requestID: "req-1")
            },
            makeIdempotencyKey: {
                defer { nextKeyNumber += 1 }
                return "key-\(nextKeyNumber)"
            }
        )

        await coordinator.start()
        coordinator.cancel()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(
            destructiveEdgeEvents, [],
            "Cancelling must clear nothing and quit nothing"
        )

        await coordinator.start()

        XCTAssertEqual(capturedKeys, ["key-1", "key-2"])
    }

    func testCancelAfterFailureReturnsToIdle() async {
        let coordinator = makeCoordinator(requestDeletion: { _ in
            throw AccountDeletionServiceError.serverError(statusCode: 500)
        })

        await coordinator.start()
        coordinator.cancel()

        XCTAssertEqual(coordinator.state, .idle)
    }

    func testCancelAfterSubmissionIsIgnored() async {
        let coordinator = makeCoordinator()

        await coordinator.start()
        await coordinator.submitCode("123456")
        coordinator.cancel()

        XCTAssertEqual(coordinator.state, .requestSubmitted)
        XCTAssertEqual(
            destructiveEdgeEvents, [],
            "Nothing may be cleared before the finalize is confirmed"
        )
    }

    func testCancelWhileDeletionAlreadyRunningIsIgnored() async {
        let coordinator = makeCoordinator(requestDeletion: { _ in .deletionAlreadyRunning })

        await coordinator.start()
        coordinator.cancel()

        XCTAssertEqual(
            coordinator.state, .deletionAlreadyRunning,
            "The deletion is running server-side; like after a submission, the only way forward is the finalize"
        )
        XCTAssertEqual(destructiveEdgeEvents, [])
    }

    // MARK: - Resend & cooldown

    /// A coordinator whose fake clock the test can advance, with the first
    /// step handing out sequential request IDs and keys so every resend is
    /// distinguishable from the send before it.
    private func makeResendFixture(
        failRequestNumbers: Set<Int> = [],
        failureError: Error = AccountDeletionServiceError.rateLimited,
        verifyDeletion: @escaping AccountDeletionCoordinator.VerifyDeletion = { _, _ in }
    ) -> (
        coordinator: AccountDeletionCoordinator,
        advanceClock: (TimeInterval) -> Void,
        capturedKeys: () -> [String]
    ) {
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        var keys: [String] = []
        var keysGenerated = 0
        let coordinator = makeCoordinator(
            requestDeletion: { key in
                keys.append(key)
                if failRequestNumbers.contains(keys.count) {
                    throw failureError
                }
                return .verificationCodeSent(requestID: "req-\(keys.count)")
            },
            verifyDeletion: verifyDeletion,
            makeIdempotencyKey: {
                keysGenerated += 1
                return "key-\(keysGenerated)"
            },
            now: { clock }
        )
        return (coordinator, { clock = clock.addingTimeInterval($0) }, { keys })
    }

    func testResendBeforeCooldownExpiryIsIgnored() async {
        let fixture = makeResendFixture()

        await fixture.coordinator.start()
        fixture.advanceClock(59)

        await fixture.coordinator.resendCode()

        XCTAssertEqual(
            fixture.capturedKeys(), ["key-1"],
            "The cooldown must swallow a resend before the minute is up"
        )
        XCTAssertEqual(
            fixture.coordinator.state,
            .awaitingVerificationCode(requestID: "req-1", error: nil)
        )
    }

    func testResendAfterCooldownMintsFreshKey() async {
        let fixture = makeResendFixture()

        await fixture.coordinator.start()
        fixture.advanceClock(60)

        await fixture.coordinator.resendCode()

        XCTAssertEqual(
            fixture.capturedKeys(), ["key-1", "key-2"],
            "A user-initiated resend is a new request and must not reuse the old key"
        )
        XCTAssertEqual(
            recordedStates,
            [
                .requestingDeletion,
                .awaitingVerificationCode(requestID: "req-1", error: nil),
                .requestingDeletion,
                .awaitingVerificationCode(requestID: "req-2", error: nil),
            ]
        )
    }

    func testVerificationAfterResendUsesNewRequestID() async {
        var verifiedRequestIDs: [String] = []
        let fixture = makeResendFixture(verifyDeletion: { requestID, _ in
            verifiedRequestIDs.append(requestID)
        })

        await fixture.coordinator.start()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()
        await fixture.coordinator.submitCode("123456")

        XCTAssertEqual(verifiedRequestIDs, ["req-2"])
        XCTAssertEqual(fixture.coordinator.state, .requestSubmitted)
    }

    func testResendRestartsCooldown() async {
        let fixture = makeResendFixture()

        await fixture.coordinator.start()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()

        fixture.advanceClock(59)
        await fixture.coordinator.resendCode()
        XCTAssertEqual(
            fixture.capturedKeys().count, 2,
            "The resend must restart the cooldown, not keep the original deadline"
        )

        fixture.advanceClock(1)
        await fixture.coordinator.resendCode()
        XCTAssertEqual(fixture.capturedKeys(), ["key-1", "key-2", "key-3"])
    }

    func testFailedResendRearmsCooldown() async {
        let fixture = makeResendFixture(failRequestNumbers: [2])

        await fixture.coordinator.start()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()

        fixture.advanceClock(59)
        await fixture.coordinator.resendCode()
        XCTAssertEqual(
            fixture.capturedKeys().count, 2,
            "A timed-out resend may have landed server-side; the spacing guard must re-arm"
        )

        fixture.advanceClock(1)
        await fixture.coordinator.resendCode()
        XCTAssertEqual(fixture.capturedKeys().count, 3)
    }

    func testResendFailureFallsBackToCodeEntryWithOldRequestID() async {
        var verifiedRequestIDs: [String] = []
        let fixture = makeResendFixture(
            failRequestNumbers: [2],
            verifyDeletion: { requestID, _ in verifiedRequestIDs.append(requestID) }
        )

        await fixture.coordinator.start()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()

        XCTAssertEqual(
            fixture.coordinator.state,
            .awaitingVerificationCode(requestID: "req-1", error: .service(.rateLimited)),
            "A failed resend must keep the original request usable, error inline"
        )

        await fixture.coordinator.submitCode("123456")

        XCTAssertEqual(
            verifiedRequestIDs, ["req-1"],
            "After a failed resend, verification must still target the original request"
        )
        XCTAssertEqual(destructiveEdgeEvents, [])
    }

    func testTimedOutResendIsReplayedUnderItsOwnKey() async {
        let fixture = makeResendFixture(
            failRequestNumbers: [2],
            failureError: URLError(.timedOut)
        )

        await fixture.coordinator.start()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()

        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()

        XCTAssertEqual(
            fixture.capturedKeys(), ["key-1", "key-2", "key-2"],
            "A resend with no definitive response may have landed server-side; replaying its key recovers that request instead of double-booking"
        )
        XCTAssertEqual(
            fixture.coordinator.state,
            .awaitingVerificationCode(requestID: "req-3", error: nil)
        )

        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()
        XCTAssertEqual(
            fixture.capturedKeys().last, "key-3",
            "A definitive success ends the replay; the next resend is a new request again"
        )
    }

    func testServerErrorResendIsReplayedUnderItsOwnKey() async {
        let fixture = makeResendFixture(
            failRequestNumbers: [2],
            failureError: AccountDeletionServiceError.serverError(statusCode: 500)
        )

        await fixture.coordinator.start()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()

        XCTAssertEqual(fixture.capturedKeys(), ["key-1", "key-2", "key-2"])
    }

    func testDefinitivelyRejectedResendMintsFreshKeyNextTime() async {
        let fixture = makeResendFixture(failRequestNumbers: [2])

        await fixture.coordinator.start()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()
        fixture.advanceClock(60)
        await fixture.coordinator.resendCode()

        XCTAssertEqual(
            fixture.capturedKeys(), ["key-1", "key-2", "key-3"],
            "A definitive rejection must not be replayed — the server may memoize error responses per key"
        )
    }

    func testResendWithoutPendingCodeIsIgnored() async {
        var requestCallCount = 0
        let coordinator = makeCoordinator(requestDeletion: { _ in
            requestCallCount += 1
            return .verificationCodeSent(requestID: "req-1")
        })

        await coordinator.resendCode()

        XCTAssertEqual(requestCallCount, 0)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(recordedStates, [])
    }

    // MARK: - Finalize

    func testFinalizeClearsCredentialsBeforeAndAfterLongLocalDataRemoval() async {
        var resumeLocalDataRemoval: CheckedContinuation<Void, Never>?
        let coordinator = makeCoordinator(clearLocalData: {
            await withCheckedContinuation { resumeLocalDataRemoval = $0 }
        })

        await coordinator.start()
        await coordinator.submitCode("123456")

        let finalize = Task { await coordinator.finalizeDeletion() }
        await waitUntil { resumeLocalDataRemoval != nil }

        XCTAssertEqual(
            destructiveEdgeEvents,
            [
                "beginCredentialDeletion",
                "announceAccountDeleted",
                "clearInitialCredentials",
                "clearLocalData",
            ],
            "Credentials must be gone while the long local-data removal is still running"
        )
        XCTAssertEqual(coordinator.state, .finalizing)

        resumeLocalDataRemoval?.resume()
        await finalize.value

        XCTAssertEqual(
            destructiveEdgeEvents,
            [
                "beginCredentialDeletion",
                "announceAccountDeleted",
                "clearInitialCredentials",
                "clearLocalData",
                "clearCredentials",
                "quit",
            ],
            "The final credential clear catches any write that landed during local-data removal"
        )
        XCTAssertEqual(coordinator.state, .finalizing)
    }

    func testFinalizeFromAlreadyRunningUsesTheSameSafeClearOrder() async {
        var verifyCallCount = 0
        let coordinator = makeCoordinator(
            requestDeletion: { _ in .deletionAlreadyRunning },
            verifyDeletion: { _, _ in verifyCallCount += 1 }
        )

        await coordinator.start()
        await coordinator.finalizeDeletion()

        XCTAssertEqual(verifyCallCount, 0, "The already-running branch never verifies")
        XCTAssertEqual(
            destructiveEdgeEvents,
            [
                "beginCredentialDeletion",
                "announceAccountDeleted",
                "clearInitialCredentials",
                "clearLocalData",
                "clearCredentials",
                "quit",
            ],
            "The already-running branch shares the normal safe finalize order"
        )
        XCTAssertEqual(coordinator.state, .finalizing)
    }

    func testFinalizeStopsWhenCredentialSafetyPreflightFails() async {
        let coordinator = makeCoordinator(beginCredentialDeletion: { false })

        await coordinator.start()
        await coordinator.submitCode("123456")
        await coordinator.finalizeDeletion()

        XCTAssertEqual(
            destructiveEdgeEvents,
            ["beginCredentialDeletion"],
            "A failed lock or fence preflight must stop before notifying Sentinel, suspending cleanup, or quit"
        )
        XCTAssertEqual(
            coordinator.state,
            .requestSubmitted,
            "The booked deletion remains retryable from the confirmation step"
        )
    }

    func testFinalizeBeforeSubmissionIsIgnored() async {
        let coordinator = makeCoordinator()

        await coordinator.start()
        await coordinator.finalizeDeletion()

        XCTAssertEqual(destructiveEdgeEvents, [])
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(requestID: "req-1", error: nil)
        )
    }

    func testFinalizeWhileFinalizeInFlightIsIgnored() async {
        var resumeLocalDataRemoval: CheckedContinuation<Void, Never>?
        let coordinator = makeCoordinator(clearLocalData: {
            await withCheckedContinuation { resumeLocalDataRemoval = $0 }
        })

        await coordinator.start()
        await coordinator.submitCode("123456")

        let firstFinalize = Task { await coordinator.finalizeDeletion() }
        await waitUntil { resumeLocalDataRemoval != nil }

        await coordinator.finalizeDeletion()

        resumeLocalDataRemoval?.resume()
        await firstFinalize.value

        XCTAssertEqual(
            destructiveEdgeEvents,
            [
                "beginCredentialDeletion",
                "announceAccountDeleted",
                "clearInitialCredentials",
                "clearLocalData",
                "clearCredentials",
                "quit",
            ],
            "A double click on the confirmation must not start another finalize sequence"
        )
    }

    func testCancelDuringFinalizeIsIgnored() async {
        var resumeLocalDataRemoval: CheckedContinuation<Void, Never>?
        let coordinator = makeCoordinator(clearLocalData: {
            await withCheckedContinuation { resumeLocalDataRemoval = $0 }
        })

        await coordinator.start()
        await coordinator.submitCode("123456")

        let finalize = Task { await coordinator.finalizeDeletion() }
        await waitUntil { resumeLocalDataRemoval != nil }

        coordinator.cancel()
        XCTAssertEqual(coordinator.state, .finalizing)

        resumeLocalDataRemoval?.resume()
        await finalize.value

        XCTAssertEqual(destructiveEdgeEvents.last, "quit")
    }

    func testStartDuringFinalizeIsIgnored() async {
        var requestCallCount = 0
        var resumeLocalDataRemoval: CheckedContinuation<Void, Never>?
        let coordinator = makeCoordinator(
            requestDeletion: { _ in
                requestCallCount += 1
                return .verificationCodeSent(requestID: "req-1")
            },
            clearLocalData: {
                await withCheckedContinuation { resumeLocalDataRemoval = $0 }
            }
        )

        await coordinator.start()
        await coordinator.submitCode("123456")

        let finalize = Task { await coordinator.finalizeDeletion() }
        await waitUntil { resumeLocalDataRemoval != nil }

        await coordinator.start()
        XCTAssertEqual(requestCallCount, 1)

        resumeLocalDataRemoval?.resume()
        await finalize.value
    }

    // MARK: - Idempotency key default

    func testDefaultIdempotencyKeyIsLowercaseUUID() {
        let key = AccountDeletionCoordinator.defaultIdempotencyKey()

        XCTAssertEqual(key, key.lowercased())
        XCTAssertNotNil(UUID(uuidString: key))
    }

    // MARK: - Renewal freshness check

    func testRenewalReturningSameTokenCountsAsNotRenewed() {
        // The renewal preflight returns the cached credentials untouched
        // when no renewal is due; retrying with the same rejected token is
        // pointless, so the flow goes straight to sign-in guidance.
        XCTAssertFalse(
            AccountDeletionCoordinator.renewalProducedFreshCredentials(
                tokenBeforeRenewal: "token-a",
                renewedAccessToken: "token-a"
            )
        )
        XCTAssertTrue(
            AccountDeletionCoordinator.renewalProducedFreshCredentials(
                tokenBeforeRenewal: "token-a",
                renewedAccessToken: "token-b"
            )
        )
        XCTAssertFalse(
            AccountDeletionCoordinator.renewalProducedFreshCredentials(
                tokenBeforeRenewal: "token-a",
                renewedAccessToken: nil
            ),
            "No credentials from the renewal means nothing to retry with"
        )
        XCTAssertTrue(
            AccountDeletionCoordinator.renewalProducedFreshCredentials(
                tokenBeforeRenewal: nil,
                renewedAccessToken: "token-b"
            ),
            "With nothing cached beforehand, any renewed credentials are worth the retry"
        )
    }
}

final class AccountDeletionCredentialFenceTests: XCTestCase {
    func testFencePersistsUntilExplicitlyDeactivated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let markerURL = directory.appendingPathComponent("credential-fence")
        let firstInstance = AccountDeletionCredentialFence(markerURL: markerURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(firstInstance.isActive)
        XCTAssertTrue(firstInstance.activate())

        let relaunchedInstance = AccountDeletionCredentialFence(markerURL: markerURL)
        XCTAssertTrue(relaunchedInstance.isActive)
        XCTAssertTrue(relaunchedInstance.deactivate())
        XCTAssertFalse(firstInstance.isActive)
    }
}

final class AccountDeletionExternalBrowserAuthGateTests: XCTestCase {
    func testOnlyAuthorizedReplacementLoginCallbackPassesDeletionFence() {
        let authManager = AuthManager()
        let authorizedToken = UUID()
        let callbackURL = URL(string: "https://\(authManager.domain)/callback")!
        var receivedURL: URL?

        authManager.setAccountDeletionInProgress(true)
        authManager.setAccountDeletionReplacementLoginToken(authorizedToken)
        defer {
            authManager.clearBrowserAuthCallbackListener()
            authManager.clearAccountDeletionReplacementLoginToken()
            authManager.setAccountDeletionInProgress(false)
        }

        _ = authManager.registerBrowserAuthCallbackListener(
            { receivedURL = $0 },
            accountDeletionReplacementLoginToken: nil
        )
        XCTAssertFalse(authManager.resumeExternalBrowserAuthentication(with: callbackURL))
        XCTAssertNil(receivedURL)

        _ = authManager.registerBrowserAuthCallbackListener(
            { receivedURL = $0 },
            accountDeletionReplacementLoginToken: UUID()
        )
        XCTAssertFalse(authManager.resumeExternalBrowserAuthentication(with: callbackURL))
        XCTAssertNil(receivedURL)

        let unregister = authManager.registerBrowserAuthCallbackListener(
            { receivedURL = $0 },
            accountDeletionReplacementLoginToken: authorizedToken
        )
        XCTAssertTrue(authManager.resumeExternalBrowserAuthentication(with: callbackURL))
        XCTAssertEqual(receivedURL, callbackURL)
        unregister()
    }
}
