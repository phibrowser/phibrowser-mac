// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ExtensionMessagingTests: XCTestCase {
    func testRegisteredHandlerReceivesContextAndReturnsResponse() {
        let router = ExtensionMessageRouter()
        var receivedContext: ExtensionMessageContext?
        router.register(type: "test.echo") { context in
            receivedContext = context
            return #"{"ok":true}"#
        }

        let response = router.handle(
            type: "test.echo",
            payload: #"{"message":"hello"}"#,
            requestId: "request-123",
            senderId: "extension-456",
            agentName: "test-agent"
        )

        XCTAssertEqual(response, #"{"ok":true}"#)
        XCTAssertEqual(receivedContext?.type, "test.echo")
        XCTAssertEqual(receivedContext?.payload, #"{"message":"hello"}"#)
        XCTAssertEqual(receivedContext?.requestId, "request-123")
        XCTAssertEqual(receivedContext?.senderId, "extension-456")
        XCTAssertEqual(receivedContext?.agentName, "test-agent")
    }

    func testSeparatelyRegisteredTypesDispatchIndependently() {
        let router = ExtensionMessageRouter()
        var handledTypes: [String] = []
        router.register(type: "test.first") { context in
            handledTypes.append(context.type)
            return "first-response"
        }
        router.register(type: "test.second") { context in
            handledTypes.append(context.type)
            return "second-response"
        }

        let firstResponse = router.handle(
            type: "test.first",
            payload: "",
            requestId: "request-first"
        )
        let secondResponse = router.handle(
            type: "test.second",
            payload: "",
            requestId: "request-second"
        )

        XCTAssertEqual(firstResponse, "first-response")
        XCTAssertEqual(secondResponse, "second-response")
        XCTAssertEqual(handledTypes, ["test.first", "test.second"])
    }
}
