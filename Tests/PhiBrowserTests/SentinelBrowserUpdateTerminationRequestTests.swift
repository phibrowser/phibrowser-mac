// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelBrowserUpdateTerminationRequestTests: XCTestCase {
    func testBuildsStableBrowserUpdateTerminationRequest() {
        let request = SentinelBrowserUpdateTerminationRequest.make(
            sentinelBundleID: "com.phibrowser.Sentinel",
            browserBundleID: "com.phibrowser.Mac",
            requestID: "request-1"
        )

        XCTAssertEqual(SentinelBrowserUpdateTerminationRequest.notificationName.rawValue, "com.phibrowser.sentinel.prepareForBrowserUpdate")
        XCTAssertEqual(request.sentinelBundleID, "com.phibrowser.Sentinel")
        XCTAssertEqual(request.userInfo["requestID"], "request-1")
        XCTAssertEqual(request.userInfo["browserBundleID"], "com.phibrowser.Mac")
        XCTAssertEqual(request.userInfo["reason"], "browser_update_install")
    }

    func testBuildsCanaryBrowserUpdateTerminationRequest() {
        let request = SentinelBrowserUpdateTerminationRequest.make(
            sentinelBundleID: "com.phibrowser.canary.Sentinel",
            browserBundleID: "com.phibrowser.canary.Mac",
            requestID: "request-2"
        )

        XCTAssertEqual(request.sentinelBundleID, "com.phibrowser.canary.Sentinel")
        XCTAssertEqual(request.userInfo["browserBundleID"], "com.phibrowser.canary.Mac")
        XCTAssertEqual(request.userInfo["reason"], "browser_update_install")
    }
}
