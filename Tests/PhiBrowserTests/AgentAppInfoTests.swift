// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// `agentSpace.app.info` tells an agent which Phi build it is talking to,
/// with the same values the browser's own feedback reports carry.
final class AgentAppInfoTests: XCTestCase {
    func testAppInfoReportsTheBuildThatAnswers() throws {
        let reply = try XCTUnwrap(
            ExtensionMessageRouter.shared.handle(
                type: "agentSpace.app.info", payload: "{}",
                requestId: "agent-app-info-test", senderId: "cdp"),
            "agentSpace.app.info must answer synchronously")
        let info = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])

        XCTAssertEqual(info["ok"] as? Bool, true)
        XCTAssertEqual(info["name"] as? String, "Phi Browser")
        XCTAssertEqual(info["version"] as? String, SystemUtils.appVersion)
        XCTAssertEqual(info["channel"] as? String, FeedbackOutbox.channelName)
        XCTAssertEqual(info["buildNumber"] as? String, SystemUtils.buildNumber)
    }
}
