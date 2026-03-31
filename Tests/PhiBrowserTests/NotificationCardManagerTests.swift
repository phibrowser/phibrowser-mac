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

        func sendResponse(_ response: String, requestId: String) {
            responses.append((response, requestId))
        }

        func sendError(_ error: String, requestId: String) {
            errors.append((error, requestId))
        }

        func broadcast(type: String, payload: String) {
            broadcasts.append((type, payload))
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
        XCTAssertEqual(messenger.responses.first?.requestId, "r1")
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
