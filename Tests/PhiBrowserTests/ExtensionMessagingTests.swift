// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ExtensionMessagingTests: XCTestCase {
    func testEnvelopeEncodeDecodeRoundTrip() throws {
        let payload: [String: AnyCodable] = ["k": .string("v")]
        let envelope = ExtensionMessageEnvelope(
            action: "notification.card.request",
            version: "1",
            correlationId: "req-1",
            payload: payload
        )
        let data = try envelope.encode()
        let decoded = try ExtensionMessageEnvelope.decode(from: data)
        XCTAssertEqual(decoded.action, "notification.card.request")
        XCTAssertEqual(decoded.version, "1")
        XCTAssertEqual(decoded.correlationId, "req-1")
        XCTAssertEqual(decoded.payload?["k"]?.stringValue, "v")
    }

    func testRouterDispatchesByAction() throws {
        let router = ExtensionMessageRouter()
        var handled = false
        router.register(action: "notification.card.request") { _ in
            handled = true
            return nil
        }
        let envelope = ExtensionMessageEnvelope(
            action: "notification.card.request",
            version: "1",
            correlationId: "req-2",
            payload: [:]
        )
        let data = try envelope.encode()
        _ = router.handle(message: String(data: data, encoding: .utf8)!, requestId: "req-2")
        XCTAssertTrue(handled)
    }

    func testRouterRegistersMultipleActions() throws {
        let router = ExtensionMessageRouter()
        var handled: [String] = []
        router.register(actions: "notification.card.request", "notification.card.response") { envelope in
            handled.append(envelope.action)
            return nil
        }

        let request = ExtensionMessageEnvelope(
            action: "notification.card.request",
            version: "1",
            correlationId: "req-3",
            payload: [:]
        )
        let response = ExtensionMessageEnvelope(
            action: "notification.card.response",
            version: "1",
            correlationId: "req-4",
            payload: [:]
        )

        _ = router.handle(message: String(data: try request.encode(), encoding: .utf8)!, requestId: "req-3")
        _ = router.handle(message: String(data: try response.encode(), encoding: .utf8)!, requestId: "req-4")

        XCTAssertEqual(handled.sorted(), ["notification.card.request", "notification.card.response"])
    }
}
