// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class NotificationCardManagerTests: XCTestCase {
    private final class TestMessenger: ExtensionMessagingProtocol {
        var responses: [(response: String, requestId: String)] = []
        var errors: [(error: String, requestId: String)] = []
        var broadcasts: [(type: String, payload: String)] = []
        var agentEvents: [(type: String, payload: String, principalId: String)] = []

        func sendResponse(_ response: String, requestId: String) {
            responses.append((response, requestId))
        }

        func sendError(_ error: String, requestId: String) {
            errors.append((error, requestId))
        }

        func broadcast(type: String, payload: String) {
            broadcasts.append((type, payload))
        }

        func broadcastToAgent(type: String, payload: String, principalId: String) {
            agentEvents.append((type, payload, principalId))
        }
    }

    func testDedupesByTaskId() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)
        _ = manager.enqueueCard(
            envelope: makeEnvelope(
                taskID: "t1",
                expiresAt: "2000"
            ),
            correlationId: "req-1"
        )
        _ = manager.enqueueCard(
            envelope: makeEnvelope(
                taskID: "t1",
                expiresAt: "3000"
            ),
            correlationId: "req-2"
        )
        XCTAssertEqual(manager.count, 1)
    }

    func testEvictsOldestOnOverflow() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 1, now: { 1000 }, messenger: messenger)
        _ = manager.enqueueCard(
            envelope: makeEnvelope(taskID: "a", expiresAt: "2000"),
            correlationId: "r1"
        )
        _ = manager.enqueueCard(
            envelope: makeEnvelope(taskID: "b", expiresAt: "3000"),
            correlationId: "r2"
        )
        XCTAssertEqual(manager.count, 1)
        XCTAssertEqual(manager.oldestTaskId, "b")
        XCTAssertTrue(messenger.responses.isEmpty)
        XCTAssertEqual(messenger.broadcasts.count, 1)
        XCTAssertEqual(messenger.broadcasts.first?.type, "notification")
        let broadcastJSON = messenger.broadcasts[0].payload.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let inner = broadcastJSON?["payload"] as? [String: Any]
        XCTAssertEqual(inner?["decision"] as? String, "timeout")
        XCTAssertEqual(inner?["task_id"] as? String, "a")
    }

    func testPreservesCustomButtonTitleFromPayload() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)

        _ = manager.enqueueCard(
            envelope: makeEnvelope(
                taskID: "custom-button",
                expiresAt: "2000",
                buttonTitle: "Open Chat"
            ),
            correlationId: "req-1"
        )

        let card = expectation(description: "card published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.latestCard?.buttonTitle, "Open Chat")
            card.fulfill()
        }
        wait(for: [card], timeout: 1.0)
    }

    func testFallsBackToRunWhenButtonTitleMissingOrEmpty() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)

        _ = manager.enqueueCard(
            envelope: makeEnvelope(taskID: "missing-button", expiresAt: "2000"),
            correlationId: "req-1"
        )
        _ = manager.enqueueCard(
            envelope: makeEnvelope(
                taskID: "empty-button",
                expiresAt: "3000",
                buttonTitle: ""
            ),
            correlationId: "req-2"
        )

        let cards = expectation(description: "cards published")
        DispatchQueue.main.async {
            let missingButtonCard = manager.allCards.first { $0.taskId == "missing-button" }
            let emptyButtonCard = manager.allCards.first { $0.taskId == "empty-button" }
            XCTAssertEqual(missingButtonCard?.buttonTitle, "Run")
            XCTAssertEqual(emptyButtonCard?.buttonTitle, "Run")
            cards.fulfill()
        }
        wait(for: [cards], timeout: 1.0)
    }

    func testAgentNotificationRequiresAuthenticatedDirectSession() {
        let manager = NotificationCardManager()
        for context in [
            agentContext(principalId: nil),
            agentContext(principalId: ""),
            agentContext(senderId: "extension"),
        ] {
            XCTAssertEqual(manager.handleAgentRequest(context: context),
                           #"{"ok":false,"error":"agent_session_required"}"#)
        }
        XCTAssertEqual(manager.count, 0)
        XCTAssertEqual(ExtensionMessageRouter.shared.handle(
            type: "notification.show", payload: "{}", requestId: "test", senderId: "cdp"),
            #"{"ok":false,"error":"agent_session_required"}"#)
    }

    func testAgentNotificationRejectsInvalidPayloads() {
        let manager = NotificationCardManager()
        for payload in [
            "not json", "{}",
            #"{"title":" ","message":"Body"}"#,
            #"{"title":"Title","message":""}"#,
            #"{"title":"Title","message":"Body","buttonTitle":1}"#,
            #"{"title":"Title","message":"Body","expiresInSeconds":0}"#,
            #"{"title":"Title","message":"Body","expiresInSeconds":86401}"#,
            #"{"title":"Title","message":"Body","expiresInSeconds":1.5}"#,
        ] {
            XCTAssertEqual(manager.handleAgentRequest(context: agentContext(payload: payload)),
                           #"{"ok":false,"error":"invalid_params"}"#)
        }
        XCTAssertEqual(manager.count, 0)
    }

    func testAgentNotificationAcknowledgesAndRoutesDecisionOnlyToOwner() throws {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(now: { 1000 }, messenger: messenger)
        let reply = manager.handleAgentRequest(context: agentContext(payload:
            #"{"title":"Ready","message":"Review the result","buttonTitle":"Review","expiresInSeconds":60}"#))
        let id = try XCTUnwrap(decode(reply)?["notificationId"] as? String)
        XCTAssertEqual(manager.latestTaskId, id)
        XCTAssertTrue(messenger.agentEvents.isEmpty)

        let published = expectation(description: "agent card published")
        DispatchQueue.main.async {
            guard let card = manager.latestCard else {
                XCTFail("Expected an agent card")
                published.fulfill()
                return
            }
            XCTAssertEqual(card.title, "Ready")
            XCTAssertEqual(card.message, "Review the result")
            XCTAssertEqual(card.buttonTitle, "Review")
            XCTAssertEqual(card.expiresAt, 61_000)
            manager.decide(card: card, decision: .accept)
            manager.decide(card: card, decision: .reject)
            XCTAssertEqual(messenger.agentEvents.count, 1)
            XCTAssertEqual(messenger.agentEvents.first?.principalId, "agent-a")
            XCTAssertEqual(messenger.agentEvents.first?.type, "notification.response")
            XCTAssertEqual(self.decode(messenger.agentEvents[0].payload)?["notificationId"] as? String, id)
            XCTAssertEqual(self.decode(messenger.agentEvents[0].payload)?["decision"] as? String, "accept")
            XCTAssertTrue(messenger.broadcasts.isEmpty)
            XCTAssertEqual(manager.count, 0)
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }

    func testAgentNotificationsHaveUniqueIDsAndEvictionNotifiesOriginalOwner() throws {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 1, now: { 1000 }, messenger: messenger)
        let first = manager.handleAgentRequest(context: agentContext())
        let second = manager.handleAgentRequest(context: agentContext(principalId: "agent-b"))
        let firstId = try XCTUnwrap(decode(first)?["notificationId"] as? String)
        let secondId = try XCTUnwrap(decode(second)?["notificationId"] as? String)
        XCTAssertNotEqual(firstId, secondId)
        XCTAssertEqual(manager.latestTaskId, secondId)
        XCTAssertEqual(messenger.agentEvents.count, 1)
        XCTAssertEqual(messenger.agentEvents.first?.principalId, "agent-a")
        XCTAssertEqual(decode(messenger.agentEvents[0].payload)?["notificationId"] as? String, firstId)
        XCTAssertEqual(decode(messenger.agentEvents[0].payload)?["decision"] as? String, "timeout")
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }

    func testHidingAgentCardDoesNotDecideAndRejectUsesScopedEvent() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(now: { 1000 }, messenger: messenger)
        _ = manager.handleAgentRequest(context: agentContext())
        let published = expectation(description: "agent card published")
        DispatchQueue.main.async {
            guard let card = manager.latestCard else {
                XCTFail("Expected an agent card")
                published.fulfill()
                return
            }
            XCTAssertEqual(card.buttonTitle, "Run")
            XCTAssertEqual(card.expiresAt, 301_000)
            manager.hideCard()
            XCTAssertTrue(messenger.agentEvents.isEmpty)
            XCTAssertEqual(manager.count, 1)
            manager.decide(card: card, decision: .reject)
            XCTAssertEqual(messenger.agentEvents.count, 1)
            XCTAssertEqual(self.decode(messenger.agentEvents[0].payload)?["decision"] as? String, "reject")
            XCTAssertTrue(messenger.broadcasts.isEmpty)
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }

    private func agentContext(
        payload: String = #"{"title":"Title","message":"Body"}"#,
        senderId: String = "cdp",
        principalId: String? = "agent-a"
    ) -> ExtensionMessageContext {
        ExtensionMessageContext(type: "notification.show", payload: payload,
                                requestId: "agent-test", senderId: senderId,
                                driverPrincipalId: principalId)
    }

    private func decode(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    private func makeEnvelope(
        taskID: String,
        expiresAt: String,
        buttonTitle: String? = nil
    ) -> [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "task_id": .string(taskID),
            "expires_at": .string(expiresAt)
        ]
        if let buttonTitle {
            payload["button_title"] = .string(buttonTitle)
        }

        return [
            "messageId": .string("message-\(taskID)"),
            "payload": .init(payload)
        ]
    }
}
