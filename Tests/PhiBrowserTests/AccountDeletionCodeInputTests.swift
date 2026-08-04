// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AccountDeletionCodeInputTests: XCTestCase {
    func testDigitsPassThroughUnchanged() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized("123456"), "123456")
    }

    func testPartialEntryIsKept() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized("12"), "12")
    }

    func testNonDigitCharactersAreDropped() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized("12a!b3"), "123")
    }

    func testPastedCodeWithSpaceSeparatorsIsAccepted() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized(" 123 456 "), "123456")
    }

    func testPastedCodeWithDashSeparatorsIsAccepted() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized("123-456"), "123456")
    }

    func testInputIsCappedAtSixDigits() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized("1234567890"), "123456")
    }

    func testNonASCIIDigitsAreRejected() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized("１２３４５６"), "")
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(AccountVerificationCodeInput.sanitized(""), "")
    }
}
