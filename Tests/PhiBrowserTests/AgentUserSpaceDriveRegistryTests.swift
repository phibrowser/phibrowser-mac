// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The operating mask for tabs in the user's own Spaces: what the browser's
/// drive reports turn into, and what a takeover does to them.
@MainActor
final class AgentUserSpaceDriveRegistryTests: XCTestCase {
    private let registry = AgentUserSpaceDriveRegistry.shared

    override func setUp() {
        super.setUp()
        registry.resetForTesting()
    }

    override func tearDown() {
        registry.resetForTesting()
        super.tearDown()
    }

    func testFirstReportArmsTheMask() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)

        XCTAssertTrue(registry.isDriven(tabId: 11))
        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testSessionNamingAnotherTabMovesItsMask() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.didOperate(tabId: 12, windowId: 1, sessionId: 100)

        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11),
                       "a driver wears one mask, not two")
        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 12))
    }

    func testMaskSurvivesUntilTheLastDriverOfATabLeaves() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 200)

        registry.didStop(tabId: 11, sessionId: 100)
        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))

        registry.didStop(tabId: 11, sessionId: 200)
        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testIdleDriverLosesTheMask() {
        registry.idleTimeout = -1  // everything already counts as idle
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)

        registry.sweep()

        XCTAssertFalse(registry.isDriven(tabId: 11))
        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testTakeControlDropsTheMaskAndReclaimsTheTab() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)

        registry.takeControl(tabId: 11)

        XCTAssertFalse(registry.isDriven(tabId: 11))
        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
        XCTAssertTrue(registry.isReclaimed(tabId: 11))
    }

    /// The trap worth pre-empting: a reclaimed tab must outlive the driver's
    /// session, or the agent's next run silently re-masks the tab the user just
    /// took back.
    func testAReclaimedTabIsNotReMaskedByALaterSession() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)

        registry.didOperate(tabId: 11, windowId: 1, sessionId: 300)

        XCTAssertFalse(registry.isDriven(tabId: 11))
        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testReclaimLapsesAfterItsGrace() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)
        registry.reclaimGrace = -1  // the grace has already run out

        XCTAssertFalse(registry.isReclaimed(tabId: 11))
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 300)
        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
    }

    /// The takeover has to leave something on screen to hand back FROM, so the
    /// driver's hold survives it — flagged, not deleted.
    func testTakeControlKeepsTheHoldSoTheUserCanHandItBack() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)

        XCTAssertNotNil(registry.record(forTabId: 11), "the pill needs a record")
        XCTAssertTrue(registry.isReclaimedWithDriver(tabId: 11))
    }

    /// No reports arrive while the browser is refusing the driver, so an idle
    /// rule would retire "Hand back" seconds after the user pressed Take
    /// control.
    func testAReclaimedHoldDoesNotIdleOut() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)
        registry.idleTimeout = -1

        registry.sweep()

        XCTAssertTrue(registry.isReclaimedWithDriver(tabId: 11))
    }

    func testHandBackUnblocksTheDriverAndRestoresTheMask() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)

        registry.handBack(tabId: 11)

        XCTAssertFalse(registry.isReclaimed(tabId: 11), "the browser must stop refusing")
        XCTAssertTrue(registry.isDriven(tabId: 11))
        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testTheAgentKeepsTheTabAfterAHandBack() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)
        registry.handBack(tabId: 11)

        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)

        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
    }

    /// Finish ends the episode without blocking anyone: taking control is the
    /// only thing that shuts an agent out.
    func testFinishDismissesThePillAndUnblocksTheAgent() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)

        registry.finish(tabId: 11)

        XCTAssertNil(registry.record(forTabId: 11), "the pill goes away")
        XCTAssertFalse(registry.isReclaimed(tabId: 11), "the agent is not shut out")
        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testTheAgentCanClaimTheTabAgainAfterFinish() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)
        registry.finish(tabId: 11)

        registry.didOperate(tabId: 11, windowId: 1, sessionId: 200)

        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
        XCTAssertTrue(registry.isDriven(tabId: 11))
    }

    /// A driver that detaches while the user holds its tab has nothing left to
    /// hand back to, so the pill retires with it — but the takeover stands.
    func testDriverLeavingWhileReclaimedRetiresThePill() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)

        registry.didStop(tabId: 11, sessionId: 100)

        XCTAssertNil(registry.record(forTabId: 11))
        XCTAssertTrue(registry.isReclaimed(tabId: 11))
    }

    // MARK: - Reading

    /// Reading is not claiming: an agent that only looks at a tab must never
    /// input-block the user out of it.
    func testObservingAloneNeverArmsTheMask() {
        registry.didObserve(tabId: 11, windowId: 1, sessionId: 100)

        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
        XCTAssertNil(registry.record(forTabId: 11))
    }

    /// The gap between an agent's rounds is longer than the gap between its
    /// commands, so reads have to hold the mask up or it blinks mid-task.
    func testObservingKeepsARaisedMaskAlive() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.idleTimeout = 0.2
        registry.didObserve(tabId: 11, windowId: 1, sessionId: 100)

        registry.sweep()

        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
    }

    /// A read from the agent's own CDP session refreshes the hold the APP
    /// armed when it opened the tab — different key, same tab.
    func testObservingRefreshesAnAppArmedHold() {
        registry.agentWillOpenTab(inWindow: 1, principalId: "p-1", driverName: "Claude Code")
        registry.noteTabCreated(tabId: 11, windowId: 1)
        registry.idleTimeout = 0.2
        registry.didObserve(tabId: 11, windowId: 1, sessionId: 100)

        registry.sweep()

        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testObservingDoesNotReviveATabTheUserTookBack() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)

        registry.didObserve(tabId: 11, windowId: 1, sessionId: 100)

        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
        XCTAssertTrue(registry.isReclaimed(tabId: 11))
    }

    // MARK: - Opening a tab in the user's Space (no CDP command is ever sent)

    func testAnAgentOpeningATabArmsTheMask() {
        registry.agentWillOpenTab(inWindow: 1, principalId: "p-1", driverName: "Claude Code")

        registry.noteTabCreated(tabId: 11, windowId: 1)

        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
        XCTAssertEqual(registry.record(forTabId: 11)?.driverName, "Claude Code",
                       "the app authenticated this caller — the pill can name it")
    }

    func testATabTheUserOpensIsNotMasked() {
        registry.noteTabCreated(tabId: 11, windowId: 1)

        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
        XCTAssertNil(registry.record(forTabId: 11))
    }

    /// One expectation, one tab: a second creation in that window is the
    /// user's, not the agent's.
    func testOneOpenClaimsOneTab() {
        registry.agentWillOpenTab(inWindow: 1, principalId: "p-1", driverName: "Claude Code")

        registry.noteTabCreated(tabId: 11, windowId: 1)
        registry.noteTabCreated(tabId: 12, windowId: 1)

        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 11))
        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 12))
    }

    func testASecondOpenMovesTheSameAgentsMask() {
        registry.agentWillOpenTab(inWindow: 1, principalId: "p-1", driverName: "Claude Code")
        registry.noteTabCreated(tabId: 11, windowId: 1)
        registry.agentWillOpenTab(inWindow: 1, principalId: "p-1", driverName: "Claude Code")
        registry.noteTabCreated(tabId: 12, windowId: 1)

        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
        XCTAssertTrue(AgentAnimationManager.shared.isActive(for: 12))
    }

    func testAnOpenInAnotherWindowIsNotClaimed() {
        registry.agentWillOpenTab(inWindow: 1, principalId: "p-1", driverName: "Claude Code")

        registry.noteTabCreated(tabId: 11, windowId: 2)

        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testOpeningDoesNotOverrideATakeover() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)

        registry.agentWillOpenTab(inWindow: 1, principalId: "p-1", driverName: "Claude Code")
        registry.noteTabCreated(tabId: 11, windowId: 1)

        XCTAssertFalse(AgentAnimationManager.shared.isActive(for: 11))
    }

    func testClosingATabDropsEveryHoldOnIt() {
        registry.didOperate(tabId: 11, windowId: 1, sessionId: 100)
        registry.takeControl(tabId: 11)

        registry.tabWasRemoved(tabId: 11)

        XCTAssertFalse(registry.isDriven(tabId: 11))
        XCTAssertFalse(registry.isReclaimed(tabId: 11),
                       "a new tab can reuse the id; the takeover must not")
    }
}
