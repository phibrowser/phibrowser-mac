// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AccountDeletionResendCountdownTests: XCTestCase {
    private let reference = Date(timeIntervalSinceReferenceDate: 0)

    func testNoDeadlineMeansNoCooldown() {
        XCTAssertEqual(
            AccountVerificationResendCountdown.remainingSeconds(until: nil, now: reference),
            0
        )
    }

    func testElapsedDeadlineMeansNoCooldown() {
        XCTAssertEqual(
            AccountVerificationResendCountdown.remainingSeconds(
                until: reference,
                now: reference
            ),
            0
        )
        XCTAssertEqual(
            AccountVerificationResendCountdown.remainingSeconds(
                until: reference,
                now: reference.addingTimeInterval(5)
            ),
            0
        )
    }

    func testFractionalRemainderRoundsUp() {
        XCTAssertEqual(
            AccountVerificationResendCountdown.remainingSeconds(
                until: reference.addingTimeInterval(0.4),
                now: reference
            ),
            1,
            "The label must never read 0 while the resend is still locked"
        )
    }

    func testFullCooldownReadsSixtySeconds() {
        XCTAssertEqual(
            AccountVerificationResendCountdown.remainingSeconds(
                until: reference.addingTimeInterval(60),
                now: reference
            ),
            60
        )
    }
}
