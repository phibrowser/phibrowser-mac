// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ContentBlockingCustomFilterSheetTests: XCTestCase {
    func testNameIsRequired() {
        var input = ContentBlockingCustomFilterInput(kind: .url, name: "  ", url: "https://a.example/l.txt")
        XCTAssertEqual(input.validationError, "Give the filter a name.")
        input.name = "Mine"
        XCTAssertNil(input.validationError)
    }

    func testUrlMustBeHttp() {
        for bad in ["", "example.com/list.txt", "ftp://a.example/l", "https://", "javascript:alert(1)"] {
            let input = ContentBlockingCustomFilterInput(kind: .url, name: "Mine", url: bad)
            XCTAssertEqual(input.validationError, "Enter a full http(s) URL.", bad)
        }
        XCTAssertNil(ContentBlockingCustomFilterInput(kind: .url, name: "Mine", url: " http://a.example/l.txt ").validationError)
    }

    func testRulesMustNotBeEmpty() {
        var input = ContentBlockingCustomFilterInput(kind: .rules, name: "Mine", rules: "\n  \n")
        XCTAssertEqual(input.validationError, "Enter at least one filter rule.")
        input.rules = "||ads.example^"
        XCTAssertNil(input.validationError)
        // The URL field is ignored for pasted rules.
        input.url = "not a url"
        XCTAssertNil(input.validationError)
    }
}
