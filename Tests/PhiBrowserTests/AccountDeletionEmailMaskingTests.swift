// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AccountDeletionEmailMaskingTests: XCTestCase {
    func testMasksLocalPartAndKeepsDomain() {
        XCTAssertEqual(
            AccountVerificationEmailMasking.masked("someone@example.com"),
            "s•••@example.com"
        )
    }

    func testKeepsOnlyTheFirstLocalCharacter() {
        XCTAssertEqual(AccountVerificationEmailMasking.masked("ab@c.d"), "a•••@c.d")
    }

    func testSingleCharacterLocalPartStaysRecognizable() {
        XCTAssertEqual(AccountVerificationEmailMasking.masked("a@b.c"), "a•••@b.c")
    }

    func testEmptyLocalPartMasksWithoutLeadingCharacter() {
        XCTAssertEqual(AccountVerificationEmailMasking.masked("@b.c"), "•••@b.c")
    }

    func testValueWithoutAtSignMasksEntirely() {
        XCTAssertEqual(AccountVerificationEmailMasking.masked("not-an-email"), "•••")
    }

    func testEmptyValueMasksEntirely() {
        XCTAssertEqual(AccountVerificationEmailMasking.masked(""), "•••")
    }
}
