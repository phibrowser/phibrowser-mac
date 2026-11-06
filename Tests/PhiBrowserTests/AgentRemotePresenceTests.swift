// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The wire contract between two Macs showing each other's agent Spaces, and
/// the page input a remote controller turns into.
final class AgentRemotePresenceTests: XCTestCase {

    private func task(ownedByUser: Bool = false,
                      status: AgentRemoteTask.Status = .running,
                      remoteController: String? = nil) -> AgentRemoteTask {
        AgentRemoteTask(
            spaceId: "space-1", taskId: "orbit-export", number: 1,
            agentName: "Claude Code", isPhiAgent: false, ownedByUser: ownedByUser,
            status: status, caption: "Waiting for sign-in",
            remoteController: remoteController, handoffMessage: "Sign in, then hand back",
            tabs: [AgentRemoteTab(id: 7, title: "Orbit Console", url: "http://127.0.0.1/", isActive: true)])
    }

    // MARK: - Wire format

    func testSnapshotSurvivesTheWire() throws {
        let sent = AgentRemoteMessage.snapshot(
            AgentRemoteSnapshot(deviceName: "Mac Server",
                                tasks: [task(status: .failed("Timed out"))]))
        let received = try JSONDecoder().decode(
            AgentRemoteMessage.self, from: JSONEncoder().encode(sent))
        guard case .snapshot(let snapshot) = received else {
            return XCTFail("expected a snapshot, got \(received)")
        }
        XCTAssertEqual(snapshot.deviceName, "Mac Server")
        XCTAssertEqual(snapshot.tasks, [task(status: .failed("Timed out"))])
    }

    func testCommandsSurviveTheWire() throws {
        let sent = AgentRemoteMessage.command(.activateTab(spaceId: "space-1", tabId: 7))
        let received = try JSONDecoder().decode(
            AgentRemoteMessage.self, from: JSONEncoder().encode(sent))
        guard case .command(.activateTab(let spaceId, let tabId)) = received else {
            return XCTFail("expected activateTab, got \(received)")
        }
        XCTAssertEqual(spaceId, "space-1")
        XCTAssertEqual(tabId, 7)
    }

    // MARK: - Pill record

    /// The pill reads the same record a local agent Space hands it.
    func testDisplayTaskCarriesOwnershipAndController() {
        let display = task(ownedByUser: true, remoteController: "MacBook Air").displayTask
        XCTAssertEqual(display.ownership, .user)
        XCTAssertEqual(display.remoteController, "MacBook Air")
        XCTAssertEqual(display.origin, .cdp)
        XCTAssertEqual(display.statusCaption, "Waiting for sign-in")
        XCTAssertEqual(task().displayTask.ownership, .agent)
        XCTAssertEqual(task(status: .failed("Timed out")).displayTask.status,
                       .failed(message: "Timed out"))
    }

    // MARK: - Remote input

    func testPressCarriesTheHeldButton() {
        let input = AgentRemoteInput(spaceId: "space-1", kind: .mousePressed,
                                     point: CGPoint(x: 12, y: 34), button: "left", clickCount: 1)
        let (method, params) = AgentRemotePresence.devToolsCommand(for: input)
        XCTAssertEqual(method, "Input.dispatchMouseEvent")
        XCTAssertEqual(params["type"] as? String, "mousePressed")
        XCTAssertEqual(params["buttons"] as? Int, 1)
        XCTAssertEqual(params["clickCount"] as? Int, 1)
        XCTAssertEqual(params["x"] as? Double, 12)
        XCTAssertEqual(params["y"] as? Double, 34)
    }

    func testReleaseHoldsNoButton() {
        let input = AgentRemoteInput(spaceId: "space-1", kind: .mouseReleased, button: "left", clickCount: 1)
        let (_, params) = AgentRemotePresence.devToolsCommand(for: input)
        XCTAssertEqual(params["buttons"] as? Int, 0)
    }

    /// Enter must type its text or a form never submits; arrows must not.
    func testKeysWithTextAreKeyDownAndOthersRawKeyDown() {
        let enter = AgentRemoteInput(spaceId: "space-1", kind: .keyDown, key: "Enter",
                                     code: "Enter", keyCode: 13, text: "\r")
        XCTAssertEqual(AgentRemotePresence.devToolsCommand(for: enter).1["type"] as? String, "keyDown")
        XCTAssertEqual(AgentRemotePresence.devToolsCommand(for: enter).1["text"] as? String, "\r")

        let left = AgentRemoteInput(spaceId: "space-1", kind: .keyDown, key: "ArrowLeft",
                                    code: "ArrowLeft", keyCode: 37)
        XCTAssertEqual(AgentRemotePresence.devToolsCommand(for: left).1["type"] as? String, "rawKeyDown")
        XCTAssertNil(AgentRemotePresence.devToolsCommand(for: left).1["text"])
    }

    func testTypedTextIsInserted() {
        let input = AgentRemoteInput(spaceId: "space-1", kind: .insertText, text: "é")
        let (method, params) = AgentRemotePresence.devToolsCommand(for: input)
        XCTAssertEqual(method, "Input.insertText")
        XCTAssertEqual(params["text"] as? String, "é")
    }
}
