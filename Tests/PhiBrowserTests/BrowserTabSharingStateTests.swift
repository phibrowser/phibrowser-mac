// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BrowserTabSharingStateTests: XCTestCase {
    private let windowId = 7
    private let meetingTabId = 1
    private let sharedTabId = 2
    private let candidateTabId = 3

    private var availability = TabSharingSwitchResult(status: .success, reason: nil)
    private var currentSnapshot: TabSharingSnapshot?
    private var switchRequests: [(sessionId: String, tabId: Int)] = []
    private var pendingCompletion: ((TabSharingSwitchResult) -> Void)?

    private func makeClient() -> TabSharingClient {
        TabSharingClient(
            snapshot: { [unowned self] _ in currentSnapshot },
            availability: { [unowned self] _, _, _ in availability },
            switchSharedTab: { [unowned self] sessionId, _, tabId, completion in
                switchRequests.append((sessionId, tabId))
                pendingCompletion = completion
            }
        )
    }

    private func makeSnapshot(revision: UInt64,
                              sessionId: String = "session-a",
                              sharedTabId: Int? = nil,
                              surfaceType: TabSharingSnapshot.Session.SurfaceType = .tab,
                              isSwitching: Bool = false,
                              canSwitch: Bool = true) -> TabSharingSnapshot {
        TabSharingSnapshot(
            revision: revision,
            selectedSession: .init(
                sessionId: sessionId,
                capturerTabId: meetingTabId,
                capturerWindowId: windowId,
                surfaceType: surfaceType,
                sharedTabId: sharedTabId ?? self.sharedTabId,
                sharedWindowId: windowId,
                isSwitching: isSwitching,
                canSwitch: canSwitch
            )
        )
    }

    private func makeState() -> BrowserTabSharingState {
        let state = BrowserTabSharingState(windowId: windowId, client: makeClient())
        state.start()
        return state
    }

    func test_offersUnsharedTab() {
        let state = makeState()
        XCTAssertNil(state.shareInsteadOffer(for: candidateTabId))

        state.apply(makeSnapshot(revision: 1))
        XCTAssertNotNil(state.shareInsteadOffer(for: candidateTabId))
    }

    func test_startPicksUpRunningShare() {
        currentSnapshot = makeSnapshot(revision: 1)
        let state = makeState()

        XCTAssertNotNil(state.shareInsteadOffer(for: candidateTabId))
    }

    func test_noOfferForSharedOrPresentingTab() {
        let state = makeState()
        state.apply(makeSnapshot(revision: 1))

        XCTAssertNil(state.shareInsteadOffer(for: sharedTabId))
        XCTAssertNil(state.shareInsteadOffer(for: meetingTabId))
    }

    func test_noOfferWhenSessionCannotSwitch() {
        let state = makeState()

        state.apply(makeSnapshot(revision: 1, surfaceType: .window))
        XCTAssertNil(state.shareInsteadOffer(for: candidateTabId))
        state.apply(makeSnapshot(revision: 2, canSwitch: false))
        XCTAssertNil(state.shareInsteadOffer(for: candidateTabId))
        state.apply(makeSnapshot(revision: 3, isSwitching: true))
        XCTAssertNil(state.shareInsteadOffer(for: candidateTabId))
    }

    func test_noOfferWhenFrameworkRejectsTarget() {
        availability = TabSharingSwitchResult(status: .notAllowed, reason: "policyBlocked")
        let state = makeState()
        state.apply(makeSnapshot(revision: 1))

        XCTAssertNil(state.shareInsteadOffer(for: candidateTabId))
    }

    func test_olderSnapshotIsIgnored() {
        let state = makeState()
        state.apply(makeSnapshot(revision: 5))
        state.apply(.init(revision: 4, selectedSession: nil))

        XCTAssertNotNil(state.shareInsteadOffer(for: candidateTabId))
    }

    func test_switchHidesOfferUntilCompletion() throws {
        let state = makeState()
        state.apply(makeSnapshot(revision: 1))

        let offer = try XCTUnwrap(state.shareInsteadOffer(for: candidateTabId))
        state.shareInstead(offer)
        XCTAssertNil(state.replaceableSession)
        XCTAssertEqual(switchRequests.count, 1)
        XCTAssertEqual(switchRequests.first?.tabId, candidateTabId)

        // A second click while in flight sends nothing.
        state.shareInstead(offer)
        XCTAssertEqual(switchRequests.count, 1)

        // The framework now shares the candidate tab.
        currentSnapshot = makeSnapshot(revision: 2, sharedTabId: candidateTabId)
        pendingCompletion?(TabSharingSwitchResult(status: .success, reason: nil))
        XCTAssertNil(state.shareInsteadOffer(for: candidateTabId))
        XCTAssertNotNil(state.shareInsteadOffer(for: sharedTabId))
        XCTAssertEqual(state.snapshot.selectedSession?.sharedTabId, candidateTabId)
    }

    func test_failedSwitchRestoresOffer() throws {
        let state = makeState()
        state.apply(makeSnapshot(revision: 1))

        let offer = try XCTUnwrap(state.shareInsteadOffer(for: candidateTabId))
        state.shareInstead(offer)
        pendingCompletion?(TabSharingSwitchResult(status: .failed, reason: "busy"))

        XCTAssertNotNil(state.shareInsteadOffer(for: candidateTabId))
    }

    func test_shareInsteadIgnoresIneligibleTab() {
        let state = makeState()
        state.apply(makeSnapshot(revision: 1))

        state.shareInstead(.init(sessionId: "session-a", tabId: sharedTabId))
        XCTAssertTrue(switchRequests.isEmpty)
    }

    func test_clickFromAnEarlierSessionDoesNotSwitchTheNewSession() throws {
        let state = makeState()
        state.apply(makeSnapshot(revision: 1))
        let oldOffer = try XCTUnwrap(state.shareInsteadOffer(for: candidateTabId))

        state.apply(makeSnapshot(revision: 2, sessionId: "session-b"))
        state.shareInstead(oldOffer)
        XCTAssertTrue(switchRequests.isEmpty)

        let newOffer = try XCTUnwrap(state.shareInsteadOffer(for: candidateTabId))
        state.shareInstead(newOffer)
        XCTAssertEqual(switchRequests.map(\.sessionId), ["session-b"])
    }

    func test_snapshotParsing() {
        let snapshot = TabSharingSnapshot(dictionary: [
            "revision": NSNumber(value: 9),
            "selectedSession": [
                "sessionId": "abc",
                "capturerTabId": NSNumber(value: 1),
                "capturerWindowId": NSNumber(value: 7),
                "surfaceType": "tab",
                "sharedTabId": NSNumber(value: 2),
                "state": "switching",
                "canSwitch": NSNumber(value: true),
            ] as [String: Any],
        ])

        XCTAssertEqual(snapshot.revision, 9)
        XCTAssertEqual(snapshot.selectedSession?.sessionId, "abc")
        XCTAssertEqual(snapshot.selectedSession?.sharedTabId, 2)
        XCTAssertNil(snapshot.selectedSession?.sharedWindowId)
        XCTAssertEqual(snapshot.selectedSession?.isSwitching, true)
        XCTAssertEqual(TabSharingSnapshot(dictionary: ["revision": NSNumber(value: 1)]).selectedSession, nil)
        XCTAssertEqual(TabSharingSwitchResult(dictionary: ["status": "unknown"]).status, .failed)
    }
}
