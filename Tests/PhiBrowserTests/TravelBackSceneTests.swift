// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import XCTest
@testable import Phi

final class TravelBackSceneTests: XCTestCase {
    private let first = TravelBackPage(url: "https://a.test/page?query=1#section")
    private let second = TravelBackPage(url: "https://b.test/page")

    func testLegacySplitDefaultsWithoutChangingMemberOrder() throws {
        let split = try TravelBackSplit(members: [first, second]).validated(for: second)
        XCTAssertEqual(split.orientation, "vertical")
        XCTAssertEqual(split.ratio, 0.5)
        XCTAssertEqual(split.activeIndex, 1)
        XCTAssertEqual(split.members, [first, second])
    }

    func testFullGeometryRoundTrips() throws {
        let split = TravelBackSplit(members: [first, second], orientation: "horizontal", ratio: 0.35, activeIndex: 1)
        let decoded = try JSONDecoder().decode(TravelBackSplit.self, from: JSONEncoder().encode(split))
        XCTAssertEqual(try decoded.validated(for: second), split)
    }

    func testInvalidOrRestrictedPairsAreRejectedBeforeRestoration() {
        for split in [
            TravelBackSplit(members: [first]),
            TravelBackSplit(members: [first, second, first]),
            TravelBackSplit(members: [first, TravelBackPage(url: "file:///private/file")]),
            TravelBackSplit(members: [first, second], orientation: "diagonal"),
            TravelBackSplit(members: [first, second], ratio: 0),
            TravelBackSplit(members: [first, second], ratio: 1),
            TravelBackSplit(members: [first, second], ratio: .nan),
            TravelBackSplit(members: [first, second], activeIndex: 2)
        ] {
            XCTAssertThrowsError(try split.validated(for: first))
        }
        XCTAssertFalse(TravelBackPage(url: "https://").isReopenable)
        XCTAssertFalse(TravelBackPage(url: "javascript:alert(1)").isReopenable)
    }

    func testExistingMatchingPairIsReusedWithoutMergingSidecars() {
        let split = TravelBackSplit(members: [first, second])
        XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: [first.url, second.url],
                                                 hasAnchor: true, anchorCanJoin: false), .reuse)
    }

    func testDifferentExistingPairIsPreservedByCreatingANewPair() {
        let split = TravelBackSplit(members: [first, second])
        for urls in [[first.url, "https://unrelated.test"], [second.url, first.url]] {
            XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: urls,
                                                     hasAnchor: true, anchorCanJoin: true), .newPair)
        }
    }

    func testCurrentExactURLWinsEvenWhenRecordedTabStillExists() {
        let current = TravelBackTabRef(tabId: 42, windowId: 1, url: first.url, profileId: "P", spaceId: "S")
        let recorded = TravelBackTabRef(tabId: 7, windowId: 2, url: "https://moved.test", profileId: "P", spaceId: "S")
        let scene = TravelBackScene(page: first, tab: .init(tabId: 7), window: .init(windowId: 2, spaceId: "S"),
                                   profileId: "P", runtimeId: TravelBackScene.currentRuntimeId)
        XCTAssertEqual(TravelBackTabRef.anchor(for: scene, current: current, openTabs: [recorded, current]), current)
        XCTAssertEqual(TravelBackTabRef.anchor(for: scene, current: nil, openTabs: [recorded, current]), recorded)
    }

    func testOtherSameURLTabsNeverSubstituteForTheRecordedTab() {
        let matching = TravelBackTabRef(tabId: 42, windowId: 1, url: first.url, profileId: "P", spaceId: "S")
        let scene = TravelBackScene(page: first, tab: .init(tabId: 7), window: .init(windowId: 2, spaceId: "S"),
                                   profileId: "P", runtimeId: TravelBackScene.currentRuntimeId)
        XCTAssertNil(TravelBackTabRef.anchor(for: scene, current: nil, openTabs: [matching]))
        for suffix in ["?changed=1", "#changed"] {
            let current = TravelBackTabRef(tabId: 42, windowId: 1, url: first.url + suffix)
            XCTAssertNil(TravelBackTabRef.anchor(for: scene, current: current, openTabs: [current]))
        }
    }

    func testSameURLCannotCrossSpaceOrProfileAndRestartCannotReuseNumericID() {
        let scene = TravelBackScene(page: first, tab: .init(tabId: 7), window: .init(windowId: 2, spaceId: "S"),
                                   profileId: "P", runtimeId: TravelBackScene.currentRuntimeId)
        let target = TravelBackTabRef(tabId: 7, windowId: 2, url: first.url, profileId: "P", spaceId: "S")
        for source in [
            TravelBackTabRef(tabId: 42, windowId: 1, url: first.url, profileId: "Other", spaceId: "S"),
            TravelBackTabRef(tabId: 42, windowId: 1, url: first.url, profileId: "P", spaceId: "Other")
        ] {
            XCTAssertEqual(TravelBackTabRef.anchor(for: scene, current: source, openTabs: [target, source]), target)
        }
        var old = scene
        old.runtimeId = "previous-process"
        XCTAssertNil(TravelBackTabRef.anchor(for: old, current: nil, openTabs: [target]))
    }

    func testClosedTabWindowChoicePrefersRecordedThenExistingAndNeverStaleNumericID() {
        var scene = TravelBackScene(window: .init(windowId: 8, spaceId: "S"),
                                    profileId: "P", runtimeId: TravelBackScene.currentRuntimeId)
        XCTAssertEqual(TravelBackScene.destinationWindowId(for: scene, sourceWindowId: 1, availableWindowIds: [9, 8]), 8)
        XCTAssertEqual(TravelBackScene.destinationWindowId(for: scene, sourceWindowId: 1, availableWindowIds: [9, 3]), 3)
        XCTAssertNil(TravelBackScene.destinationWindowId(for: scene, sourceWindowId: 1, availableWindowIds: []))
        scene.runtimeId = "previous-process"
        XCTAssertEqual(TravelBackScene.destinationWindowId(for: scene, sourceWindowId: 1, availableWindowIds: [8, 3]), 3)
    }

    func testHandoffRequiresExactRecipientClaimAndExplicitSuccessBeforeExpiry() {
        let recipient = TravelBackSidebar(windowId: 2, chatTabId: 90, boundTabId: 7, profileId: "P")
        let wrongProfile = TravelBackSidebar(windowId: 2, chatTabId: 90, boundTabId: 7, profileId: "Other")
        var handoff = TravelBackHandoff(operationId: "operation", conversationId: "chat", sourceWindowId: 1,
                                        sourceProfileId: "Source", destination: recipient, expiresAt: 60,
                                        acceptBy: 7.5, acceptBefore: 7500)
        XCTAssertFalse(handoff.acknowledge(by: recipient, success: true, now: 1))
        XCTAssertFalse(handoff.claim(by: wrongProfile, now: 1))
        XCTAssertTrue(handoff.claim(by: recipient, now: 1))
        XCTAssertEqual(handoff.status, .claimed)
        XCTAssertFalse(handoff.claim(by: recipient, now: 2))
        XCTAssertFalse(handoff.acknowledge(by: wrongProfile, success: true, now: 2))
        XCTAssertTrue(handoff.acknowledge(by: recipient, success: true, now: 2))
        XCTAssertEqual(handoff.status, .accepted)
        XCTAssertFalse(handoff.acknowledge(by: recipient, success: false, now: 3))
        handoff.status = .claimed
        XCTAssertFalse(handoff.acknowledge(by: recipient, success: true, now: 8))
        XCTAssertTrue(handoff.acknowledge(by: recipient, success: false, now: 7))
        XCTAssertEqual(handoff.status, .rejected)
        handoff.status = .offered
        XCTAssertFalse(handoff.claim(by: recipient, now: 8), "Cleanup TTL must not extend the delivery window")
    }

    func testSafeStandaloneAnchorCanGainANewPartner() {
        let split = TravelBackSplit(members: [first, second])
        XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: nil,
                                                 hasAnchor: true, anchorCanJoin: true), .completeAnchor)
        XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: nil,
                                                 hasAnchor: true, anchorCanJoin: false), .newPair)
        XCTAssertEqual(TravelBackSplitPlan.choose(recorded: split, existingURLs: nil,
                                                 hasAnchor: false, anchorCanJoin: true), .newPair)
    }
}
