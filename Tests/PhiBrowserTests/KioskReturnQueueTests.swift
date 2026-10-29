// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Pins how a Kiosk finds the application its external link came from
/// (`KioskReturnQueue`): by the URL its first tab opened, as Chromium
/// reports it.
final class KioskReturnQueueTests: XCTestCase {
    private let application = NSRunningApplication.current

    func testAKioskClaimsTheEntryForTheURLChromiumOpened() throws {
        var queue = KioskReturnQueue()
        queue.add(try XCTUnwrap(URL(string: "HTTPS://Linear.app")), returningTo: application)

        XCTAssertIdentical(queue.claim(forTabURL: "https://linear.app/"), application)
        XCTAssertNil(queue.claim(forTabURL: "https://linear.app/"))
    }

    func testALinkThatNeverBecameAKioskDoesNotReachAnUnrelatedOne() throws {
        // The defect: entries were claimed in order, so a link Chromium opened
        // as a regular tab handed its application to the next Kiosk.
        var queue = KioskReturnQueue()
        queue.add(try XCTUnwrap(URL(string: "https://example.com/stale")),
                  returningTo: application)

        XCTAssertNil(queue.claim(forTabURL: "https://example.com/other"))
    }

    func testDefaultPortsAreDropped() throws {
        var queue = KioskReturnQueue()
        queue.add(try XCTUnwrap(URL(string: "http://example.com:80/path?q=1")),
                  returningTo: application)

        XCTAssertIdentical(queue.claim(forTabURL: "http://example.com/path?q=1"), application)
    }

    func testAnEntryExpires() throws {
        var queue = KioskReturnQueue()
        let now = Date()
        queue.add(try XCTUnwrap(URL(string: "https://example.com/")),
                  returningTo: application, now: now)

        XCTAssertNil(queue.claim(forTabURL: "https://example.com/",
                                 now: now.addingTimeInterval(KioskReturnQueue.lifetime + 1)))
    }
}
