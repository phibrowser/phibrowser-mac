// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SentinelBrowserUpdateTerminationRequestTests: XCTestCase {
    func testPhiChatHotkeyPreferenceChannelsMatchBrowserAndSentinel() {
        let stable = PhiChatHotkeyPreferenceChannel.make(
            browserBundleIdentifier: "com.phibrowser.Mac"
        )
        let canary = PhiChatHotkeyPreferenceChannel.make(
            browserBundleIdentifier: "com.phibrowser.canary.Mac"
        )
        let dev = PhiChatHotkeyPreferenceChannel.make(
            browserBundleIdentifier: "com.phibrowser.dev.Mac"
        )

        XCTAssertEqual(stable.key, "phiChat.hotkeyEnabled.stable")
        XCTAssertEqual(canary.key, "phiChat.hotkeyEnabled.canary")
        XCTAssertEqual(dev.key, "phiChat.hotkeyEnabled.dev")
        XCTAssertEqual(
            stable.notificationName.rawValue,
            "com.phibrowser.phiChat.hotkeyPreferenceDidChange"
        )
        XCTAssertEqual(
            canary.notificationName.rawValue,
            "com.phibrowser.canary.phiChat.hotkeyPreferenceDidChange"
        )
        XCTAssertEqual(
            dev.notificationName.rawValue,
            "com.phibrowser.dev.phiChat.hotkeyPreferenceDidChange"
        )
    }

    func testSentinelBundleIdentifierMatchesBrowserChannel() {
        XCTAssertEqual(
            SentinelHelper.loginItemIdentifier(browserBundleIdentifier: "com.phibrowser.Mac"),
            "com.phibrowser.Sentinel"
        )
        XCTAssertEqual(
            SentinelHelper.loginItemIdentifier(browserBundleIdentifier: "com.phibrowser.canary.Mac"),
            "com.phibrowser.canary.Sentinel"
        )
        XCTAssertEqual(
            SentinelHelper.loginItemIdentifier(browserBundleIdentifier: "com.phibrowser.dev.Mac"),
            "com.phibrowser.dev.Sentinel"
        )
    }

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
