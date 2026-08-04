// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class AccountDataExportCoordinatorTests: XCTestCase {
    private static let requestExpiry = Date.distantFuture
    private var states: [AccountDataExportCoordinator.State] = []

    private func makeCoordinator(
        requestExport: @escaping AccountDataExportCoordinator.RequestExport = { _ in
            .verificationCodeSent(
                requestID: "req-1",
                expiresAt: AccountDataExportCoordinatorTests.requestExpiry
            )
        },
        verifyExport: @escaping AccountDataExportCoordinator.VerifyExport = { _, _ in
            .init(taskID: "task-1", status: .queued)
        },
        renewCredentials: @escaping AccountDataExportCoordinator.RenewCredentials = { false },
        now: @escaping () -> Date = Date.init,
        makeIdempotencyKey: @escaping () -> String = { "key-1" },
        isSessionCurrent: @escaping AccountDataExportCoordinator.IsSessionCurrent = { true },
        sleep: @escaping AccountDataExportCoordinator.Sleep = { _ in }
    ) -> AccountDataExportCoordinator {
        let coordinator = AccountDataExportCoordinator(
            requestExport: requestExport,
            verifyExport: verifyExport,
            renewCredentials: renewCredentials,
            now: now,
            makeIdempotencyKey: makeIdempotencyKey,
            isSessionCurrent: isSessionCurrent,
            sleep: sleep
        )
        coordinator.onStateChange = { [weak self] state in self?.states.append(state) }
        return coordinator
    }

    func testStartRequestsExportWithGeneratedIdempotencyKey() async {
        var keys: [String] = []
        let coordinator = makeCoordinator(
            requestExport: { key in
                keys.append(key)
                return .verificationCodeSent(
                    requestID: "req-7",
                    expiresAt: Self.requestExpiry
                )
            },
            makeIdempotencyKey: { "generated-key" }
        )

        await coordinator.start()

        XCTAssertEqual(keys, ["generated-key"])
        XCTAssertEqual(
            states,
            [
                .requestingExport,
                .awaitingVerificationCode(
                    requestID: "req-7",
                    expiresAt: Self.requestExpiry,
                    error: nil
                ),
            ]
        )
    }

    func testSubmitCodeQueuesExport() async {
        var calls: [(String, String)] = []
        let coordinator = makeCoordinator(verifyExport: { requestID, code in
            calls.append((requestID, code))
            return .init(taskID: "task-7", status: .queued)
        })

        await coordinator.start()
        await coordinator.submitCode("123456")

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "req-1")
        XCTAssertEqual(calls.first?.1, "123456")
        XCTAssertEqual(coordinator.state, .exportAccepted(taskID: "task-7", status: .queued))
    }

    func testExistingActiveTaskSkipsVerification() async {
        var verifyCount = 0
        let coordinator = makeCoordinator(
            requestExport: { _ in .existingTask(taskID: "task-8", status: .collecting) },
            verifyExport: { _, _ in
                verifyCount += 1
                return .init(taskID: "unused", status: .queued)
            }
        )

        await coordinator.start()

        XCTAssertEqual(verifyCount, 0)
        XCTAssertEqual(coordinator.state, .exportAccepted(taskID: "task-8", status: .collecting))
    }

    func testTerminalExistingTaskOffersFreshRetry() async {
        var keys: [String] = []
        var outcomes: [AccountDataExportRequestOutcome] = [
            .existingTask(taskID: "task-old", status: .failed),
            .verificationCodeSent(
                requestID: "req-new",
                expiresAt: Self.requestExpiry
            ),
        ]
        let coordinator = makeCoordinator(
            requestExport: { key in
                keys.append(key)
                return outcomes.removeFirst()
            },
            makeIdempotencyKey: { "key-\(keys.count + 1)" }
        )

        await coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.taskEnded(.failed)))

        await coordinator.start()

        XCTAssertEqual(keys, ["key-1", "key-2"])
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(
                requestID: "req-new",
                expiresAt: Self.requestExpiry,
                error: nil
            )
        )
    }

    func testIndeterminateStartRetryReusesKey() async {
        var keys: [String] = []
        var attempt = 0
        let coordinator = makeCoordinator(
            requestExport: { key in
                keys.append(key)
                attempt += 1
                if attempt == 1 { throw URLError(.timedOut) }
                return .verificationCodeSent(
                    requestID: "req-1",
                    expiresAt: Self.requestExpiry
                )
            },
            makeIdempotencyKey: { "stable-key" }
        )

        await coordinator.start()
        await coordinator.start()

        XCTAssertEqual(keys, ["stable-key", "stable-key"])
    }

    func testResendAfterCooldownUsesNewKeyAndRequestID() async {
        let now = Date(timeIntervalSince1970: 1_000)
        var currentNow = now
        var keys: [String] = []
        var request = 0
        let coordinator = makeCoordinator(
            requestExport: { key in
                keys.append(key)
                request += 1
                return .verificationCodeSent(
                    requestID: "req-\(request)",
                    expiresAt: Self.requestExpiry
                )
            },
            now: { currentNow },
            makeIdempotencyKey: { "key-\(keys.count + 1)" }
        )

        await coordinator.start()
        await coordinator.resendCode()
        XCTAssertEqual(keys, ["key-1"])

        currentNow = now.addingTimeInterval(AccountDataExportCoordinator.resendCooldown)
        await coordinator.resendCode()

        XCTAssertEqual(keys, ["key-1", "key-2"])
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(
                requestID: "req-2",
                expiresAt: Self.requestExpiry,
                error: nil
            )
        )
    }

    func testUnauthorizedRenewsAndRetriesExactlyOnce() async {
        var requestCount = 0
        var renewalCount = 0
        let coordinator = makeCoordinator(
            requestExport: { _ in
                requestCount += 1
                if requestCount == 1 { throw AccountDataExportServiceError.unauthorized }
                return .verificationCodeSent(
                    requestID: "req-1",
                    expiresAt: Self.requestExpiry
                )
            },
            renewCredentials: {
                renewalCount += 1
                return true
            }
        )

        await coordinator.start()

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(renewalCount, 1)
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(
                requestID: "req-1",
                expiresAt: Self.requestExpiry,
                error: nil
            )
        )
    }

    func testDismissResetsAcceptedStateWithoutCancellingServerTask() async {
        let coordinator = makeCoordinator(
            requestExport: { _ in .existingTask(taskID: "task-8", status: .retrying) }
        )
        await coordinator.start()

        coordinator.dismiss()

        XCTAssertEqual(coordinator.state, .idle)
    }

    func testAccountSwitchStopsVerificationBeforeNetworkCall() async {
        var sessionIsCurrent = true
        var verifyCount = 0
        let coordinator = makeCoordinator(
            verifyExport: { _, _ in
                verifyCount += 1
                return .init(taskID: "unexpected", status: .queued)
            },
            now: { Date(timeIntervalSince1970: 1_000) },
            isSessionCurrent: { sessionIsCurrent }
        )

        await coordinator.start()
        sessionIsCurrent = false
        await coordinator.submitCode("123456")

        XCTAssertEqual(verifyCount, 0)
        XCTAssertEqual(
            coordinator.state,
            .failed(.service(.unauthorized))
        )
    }

    func testExpiredChallengeDoesNotSubmitCode() async {
        var verifyCount = 0
        let coordinator = makeCoordinator(
            requestExport: { _ in
                .verificationCodeSent(
                    requestID: "expired-request",
                    expiresAt: Date(timeIntervalSince1970: 999)
                )
            },
            verifyExport: { _, _ in
                verifyCount += 1
                return .init(taskID: "unexpected", status: .queued)
            },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await coordinator.start()
        await coordinator.submitCode("123456")

        XCTAssertEqual(verifyCount, 0)
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(
                requestID: "expired-request",
                expiresAt: Date(timeIntervalSince1970: 999),
                error: .service(.expired)
            )
        )
    }

    func testTransientServerErrorBacksOffAndRetriesWithSameKey() async {
        var requestCount = 0
        var keys: [String] = []
        var delays: [TimeInterval] = []
        let coordinator = makeCoordinator(
            requestExport: { key in
                keys.append(key)
                requestCount += 1
                if requestCount == 1 {
                    throw AccountDataExportServiceError.serverError(
                        statusCode: 503,
                        requestID: "request-503"
                    )
                }
                return .verificationCodeSent(
                    requestID: "req-after-retry",
                    expiresAt: Self.requestExpiry
                )
            },
            makeIdempotencyKey: { "stable-key" },
            sleep: { delays.append($0) }
        )

        await coordinator.start()

        XCTAssertEqual(keys, ["stable-key", "stable-key"])
        XCTAssertEqual(delays, [AccountDataExportCoordinator.transientRetryDelay])
        XCTAssertEqual(
            coordinator.state,
            .awaitingVerificationCode(
                requestID: "req-after-retry",
                expiresAt: Self.requestExpiry,
                error: nil
            )
        )
    }

    func testRateLimitedVerificationEndsInteractiveFlow() async {
        let coordinator = makeCoordinator(
            verifyExport: { _, _ in
                throw AccountDataExportServiceError.rateLimited
            }
        )

        await coordinator.start()
        await coordinator.submitCode("123456")

        XCTAssertEqual(
            coordinator.state,
            .failed(.service(.rateLimited))
        )
    }
}
