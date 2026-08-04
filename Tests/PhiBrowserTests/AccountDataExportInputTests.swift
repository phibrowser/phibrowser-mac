// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AccountDataExportInputTests: XCTestCase {
    func testCodeInputKeepsOnlySixASCIIDigits() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized("12a 34-567"), "123456")
        XCTAssertEqual(AccountVerificationCodeInput.sanitized("１２３４５６"), "")
    }

    func testEmailMaskKeepsOnlyFirstCharacterAndDomain() {
        XCTAssertEqual(AccountVerificationEmailMasking.masked("person@example.com"), "p•••@example.com")
    }

    func testResendCountdownRoundsUp() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            AccountVerificationResendCountdown.remainingSeconds(
                until: now.addingTimeInterval(1.1),
                now: now
            ),
            2
        )
    }
}
