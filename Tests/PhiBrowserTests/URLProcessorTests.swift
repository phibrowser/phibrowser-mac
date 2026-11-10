// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class URLProcessorTests: XCTestCase {
    func testUserInputKeepsLocalFileAndExtensionURLsUnchanged() {
        let urls = [
            "file:///Users/someone/Documents/page.html",
            "chrome-extension://abcdefghijklmnop/options.html"
        ]

        for url in urls {
            XCTAssertEqual(URLProcessor.processUserInput(url), url)
            XCTAssertTrue(URLProcessor.isURL(url))
        }
    }

    func testOriginNavigationComparisonTreatsWWWAndRootSlashAsEquivalent() {
        XCTAssertTrue(
            URLProcessor.areEquivalentForOriginNavigation(
                "https://google.com",
                "https://www.google.com/"
            )
        )
    }

    func testOriginNavigationComparisonPreservesMeaningfulURLDifferences() {
        let cases = [
            ("http://example.com/path?q=a", "https://example.com/path?q=a", "scheme"),
            ("https://example.com/Path?q=a", "https://example.com/path?q=a", "path case"),
            ("https://example.com/path?q=A", "https://example.com/path?q=a", "query case"),
            ("https://example.com/path", "https://example.com/path/", "non-root slash")
        ]

        for (lhs, rhs, difference) in cases {
            XCTAssertFalse(
                URLProcessor.areEquivalentForOriginNavigation(lhs, rhs),
                "Origin navigation must preserve the \(difference) difference"
            )
        }
    }
}
