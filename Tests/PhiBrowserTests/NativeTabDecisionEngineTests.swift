import XCTest
@testable import Phi

final class NativeTabDecisionEngineTests: XCTestCase {
    func testCreationContextParsesExtendedBridgePayload() {
        let context = NativeTabCreationContext(dictionary: [
            "isActiveAtCreation": true,
            "creationKind": "linkBackground",
            "openerTabId": 10,
            "insertAfterTabId": 12,
            "sourceTabId": 10,
            "resetOpenerOnActiveTabChange": true,
            "didForgetAllOpenersBeforeCreate": false,
        ])

        XCTAssertEqual(context.creationKind, .linkBackground)
        XCTAssertEqual(context.openerTabId, 10)
        XCTAssertEqual(context.insertAfterTabId, 12)
        XCTAssertEqual(context.sourceTabId, 10)
        XCTAssertTrue(context.isActiveAtCreation)
        XCTAssertTrue(context.resetOpenerOnActiveTabChange)
        XCTAssertFalse(context.didForgetAllOpenersBeforeCreate)
    }

    func testRelationshipSnapshotParsesNSNumberAndStringKeys() {
        let snapshot = NativeTabRelationshipSnapshot(
            dictionary: [
                "windowId": 7,
                "version": 42,
                "openerByTabId": [
                    "10": 1,
                    NSNumber(value: 11): NSNull(),
                    "12": NSNumber(value: 10),
                ],
                "resetOnActiveChangeTabIds": [12, NSNumber(value: 13)],
            ],
            fallbackWindowId: 7
        )

        XCTAssertEqual(snapshot?.windowId, 7)
        XCTAssertEqual(snapshot?.version, 42)
        XCTAssertEqual(snapshot?.allTabIds, [10, 11, 12])
        XCTAssertEqual(snapshot?.tabsWithExplicitNilOpener, [11])
        XCTAssertEqual(snapshot?.openerByTabId[10], 1)
        XCTAssertNil(snapshot?.openerByTabId[11])
        XCTAssertEqual(snapshot?.openerByTabId[12], 10)
        XCTAssertEqual(snapshot?.resetOnActiveChangeTabIds, [12, 13])
    }

    func testForegroundLinkInsertionUsesOpenerRightNeighbor() {
        let context = NativeTabCreationContext(
            isActiveAtCreation: true,
            creationKind: .linkForeground,
            openerTabId: 1,
            insertAfterTabId: nil,
            sourceTabId: 1,
            resetOpenerOnActiveTabChange: false,
            didForgetAllOpenersBeforeCreate: false
        )

        let index = NativeTabDecisionEngine.insertionIndex(
            visibleNormalTabIds: [1, 2, 3],
            context: context,
            relationGraph: .empty
        )

        XCTAssertEqual(index, 1)
    }

    func testBackgroundLinkInsertionUsesLastVisibleDescendant() {
        let context = NativeTabCreationContext(
            isActiveAtCreation: false,
            creationKind: .linkBackground,
            openerTabId: 1,
            insertAfterTabId: nil,
            sourceTabId: 1,
            resetOpenerOnActiveTabChange: false,
            didForgetAllOpenersBeforeCreate: false
        )
        let relationGraph = NativeTabRelationGraph(
            openerByTabId: [
                11: 1,
                12: 11,
            ],
            resetOnActiveChangeTabIds: [],
            version: 3
        )

        let index = NativeTabDecisionEngine.insertionIndex(
            visibleNormalTabIds: [1, 11, 12, 2],
            context: context,
            relationGraph: relationGraph
        )

        XCTAssertEqual(index, 3)
    }

    func testBackgroundLinkInsertionPrefersOpenerChainOverInsertAfterHint() {
        let context = NativeTabCreationContext(
            isActiveAtCreation: false,
            creationKind: .linkBackground,
            openerTabId: 1,
            insertAfterTabId: 11,
            sourceTabId: 1,
            resetOpenerOnActiveTabChange: false,
            didForgetAllOpenersBeforeCreate: false
        )

        let index = NativeTabDecisionEngine.insertionIndex(
            visibleNormalTabIds: [1, 11],
            context: context,
            relationGraph: .empty
        )

        XCTAssertEqual(index, 1)
    }

    func testTypedNewTabFallsBackToAppend() {
        let context = NativeTabCreationContext(
            isActiveAtCreation: true,
            creationKind: .typedNewTab,
            openerTabId: 2,
            insertAfterTabId: nil,
            sourceTabId: 2,
            resetOpenerOnActiveTabChange: true,
            didForgetAllOpenersBeforeCreate: true
        )

        let index = NativeTabDecisionEngine.insertionIndex(
            visibleNormalTabIds: [1, 2, 3],
            context: context,
            relationGraph: .empty
        )

        XCTAssertEqual(index, 3)
    }

    func testCloseSelectionPrefersChildThenSiblingThenOpenerThenNeighbor() {
        let relationGraph = NativeTabRelationGraph(
            openerByTabId: [
                2: 1,
                3: 2,
                4: 1,
            ],
            resetOnActiveChangeTabIds: [],
            version: 10
        )

        XCTAssertEqual(
            NativeTabDecisionEngine.selectionTarget(
                visibleNormalTabIds: [1, 2, 3, 4],
                closingTabId: 2,
                relationGraph: relationGraph
            ),
            3
        )

        XCTAssertEqual(
            NativeTabDecisionEngine.selectionTarget(
                visibleNormalTabIds: [1, 2, 4],
                closingTabId: 2,
                relationGraph: relationGraph
            ),
            4
        )

        XCTAssertEqual(
            NativeTabDecisionEngine.selectionTarget(
                visibleNormalTabIds: [1, 2],
                closingTabId: 2,
                relationGraph: relationGraph
            ),
            1
        )

        XCTAssertEqual(
            NativeTabDecisionEngine.selectionTarget(
                visibleNormalTabIds: [7, 8, 9],
                closingTabId: 8,
                relationGraph: .empty
            ),
            9
        )
    }

    func testFixOpenersAfterMovingTabRehangsDirectChildrenToMovedTabOpener() {
        let relationGraph = NativeTabRelationGraph(
            openerByTabId: [
                2: 1,
                3: 2,
                4: 2,
                5: 4,
            ],
            resetOnActiveChangeTabIds: [],
            version: 8
        )

        let updated = relationGraph.fixingOpenersAfterMovingTab(2)

        XCTAssertEqual(updated.openerByTabId[2], 1)
        XCTAssertEqual(updated.openerByTabId[3], 1)
        XCTAssertEqual(updated.openerByTabId[4], 1)
        XCTAssertEqual(updated.openerByTabId[5], 4)
        XCTAssertTrue(updated.locallyFixedOpenerTabIds.isEmpty)
    }

    func testFixOpenersAfterMovingRootTabClearsDirectChildrenOpeners() {
        let relationGraph = NativeTabRelationGraph(
            openerByTabId: [
                2: 1,
                3: 2,
                4: 2,
            ],
            resetOnActiveChangeTabIds: [],
            version: 9
        )

        let updated = relationGraph.fixingOpenersAfterMovingTab(1)

        XCTAssertNil(updated.openerByTabId[2])
        XCTAssertEqual(updated.openerByTabId[3], 2)
        XCTAssertEqual(updated.openerByTabId[4], 2)
        XCTAssertTrue(updated.locallyFixedOpenerTabIds.isEmpty)
    }

    func testFixOpenersAfterMovingTabAvoidsSelfReferentialOpener() {
        let relationGraph = NativeTabRelationGraph(
            openerByTabId: [
                2: 3,
                3: 2,
            ],
            resetOnActiveChangeTabIds: [],
            version: 10
        )

        let updated = relationGraph.fixingOpenersAfterMovingTab(2)

        XCTAssertEqual(updated.openerByTabId[2], 3)
        XCTAssertNil(updated.openerByTabId[3])
        XCTAssertTrue(updated.locallyFixedOpenerTabIds.isEmpty)
    }

    func testApplyingSnapshotPreservesLocalMoveFixupsWhileAcceptingNewTabs() throws {
        var relationGraph = NativeTabRelationGraph(
            knownTabIds: Set([1, 2, 3]),
            openerByTabId: [
                2: 1,
                3: 2,
            ],
            resetOnActiveChangeTabIds: [],
            version: 1
        )
        let children = relationGraph.directChildren(of: 2)
        relationGraph.fixOpenersAfterMovingTab(2)
        for child in children {
            relationGraph.locallyFixedOpenerTabIds.insert(child)
        }

        let snapshot = NativeTabRelationshipSnapshot(
            dictionary: [
                "windowId": 7,
                "version": 2,
                "openerByTabId": [
                    1: NSNull(),
                    2: 1,
                    3: 2,
                    4: 2,
                ],
                "resetOnActiveChangeTabIds": [],
            ],
            fallbackWindowId: 7
        )

        relationGraph.apply(snapshot: try XCTUnwrap(snapshot))

        XCTAssertEqual(relationGraph.openerByTabId[2], 1)
        XCTAssertEqual(relationGraph.openerByTabId[3], 1)
        XCTAssertEqual(relationGraph.openerByTabId[4], 2)
        XCTAssertEqual(relationGraph.locallyFixedOpenerTabIds, [3])
    }

    func testSnapshotExplicitNilClearsLocallyFixedOpener() throws {
        var relationGraph = NativeTabRelationGraph(
            knownTabIds: Set([1, 2, 3]),
            openerByTabId: [
                2: 1,
                3: 2,
            ],
            resetOnActiveChangeTabIds: [],
            version: 1
        )
        let children = relationGraph.directChildren(of: 2)
        relationGraph.fixOpenersAfterMovingTab(2)
        for child in children {
            relationGraph.locallyFixedOpenerTabIds.insert(child)
        }
        XCTAssertEqual(relationGraph.locallyFixedOpenerTabIds, [3])

        let snapshot = try XCTUnwrap(
            NativeTabRelationshipSnapshot(
                dictionary: [
                    "windowId": 7,
                    "version": 3,
                    "openerByTabId": [
                        "1": NSNull(),
                        "2": NSNull(),
                        "3": NSNull(),
                    ],
                    "resetOnActiveChangeTabIds": [],
                ],
                fallbackWindowId: 7
            )
        )

        relationGraph.apply(snapshot: snapshot)

        XCTAssertNil(relationGraph.openerByTabId[3])
        XCTAssertTrue(relationGraph.locallyFixedOpenerTabIds.isEmpty)
    }

    func testRemoveTabClearsLocallyFixedOpener() {
        var relationGraph = NativeTabRelationGraph(
            knownTabIds: Set([1, 2, 3]),
            openerByTabId: [
                2: 1,
                3: 2,
            ],
            resetOnActiveChangeTabIds: [],
            version: 1
        )
        let children = relationGraph.directChildren(of: 2)
        relationGraph.fixOpenersAfterMovingTab(2)
        for child in children {
            relationGraph.locallyFixedOpenerTabIds.insert(child)
        }
        XCTAssertEqual(relationGraph.locallyFixedOpenerTabIds, [3])

        relationGraph.removeTab(3)

        XCTAssertTrue(relationGraph.locallyFixedOpenerTabIds.isEmpty)
    }

    func testCloseTabClearsLocalOverridesSoSnapshotCanUpdate() throws {
        var relationGraph = NativeTabRelationGraph(
            knownTabIds: Set([1, 2, 3]),
            openerByTabId: [
                2: 1,
                3: 2,
            ],
            resetOnActiveChangeTabIds: [],
            version: 1
        )

        // Simulate drag of tab 2: C's opener changes from 2 to 1
        let dragChildren = relationGraph.directChildren(of: 2)
        relationGraph.fixOpenersAfterMovingTab(2)
        for child in dragChildren {
            relationGraph.locallyFixedOpenerTabIds.insert(child)
        }
        XCTAssertEqual(relationGraph.openerByTabId[3], 1)
        XCTAssertEqual(relationGraph.locallyFixedOpenerTabIds, [3])

        // Simulate close of tab 1 (root): clears local overrides for children
        let closeChildren = relationGraph.directChildren(of: 1)
        relationGraph.fixOpenersAfterMovingTab(1)
        for child in closeChildren {
            relationGraph.locallyFixedOpenerTabIds.remove(child)
        }
        relationGraph.removeTab(1)

        // Tab 3's local override is cleared; snapshot can now update it
        XCTAssertTrue(relationGraph.locallyFixedOpenerTabIds.isEmpty)

        let snapshot = try XCTUnwrap(
            NativeTabRelationshipSnapshot(
                dictionary: [
                    "windowId": 7,
                    "version": 5,
                    "openerByTabId": [
                        "2": NSNull(),
                        "3": 2,
                    ],
                    "resetOnActiveChangeTabIds": [],
                ],
                fallbackWindowId: 7
            )
        )

        relationGraph.apply(snapshot: snapshot)

        XCTAssertEqual(relationGraph.openerByTabId[3], 2)
    }

    func testActiveTabChangeForgetsOpenerForResettingTypedTab() {
        var relationGraph = NativeTabRelationGraph(
            knownTabIds: Set([1, 2]),
            openerByTabId: [
                2: 1,
            ],
            resetOnActiveChangeTabIds: [2],
            version: 3
        )

        relationGraph.forgetOpenerOnActiveTabChange(from: 2, to: 1)

        XCTAssertNil(relationGraph.openerByTabId[2])
    }

    func testApplyingSnapshotPreservesExistingResetOnActiveChangeFlagsForKnownTabs() throws {
        var relationGraph = NativeTabRelationGraph(
            knownTabIds: Set([1, 2]),
            openerByTabId: [
                2: 1,
            ],
            resetOnActiveChangeTabIds: [2],
            version: 1
        )

        let snapshot = try XCTUnwrap(
            NativeTabRelationshipSnapshot(
                dictionary: [
                    "windowId": 7,
                    "version": 2,
                    "openerByTabId": [
                        1: NSNull(),
                        2: 1,
                    ],
                    "resetOnActiveChangeTabIds": [],
                ],
                fallbackWindowId: 7
            )
        )

        relationGraph.apply(snapshot: snapshot)

        XCTAssertEqual(relationGraph.resetOnActiveChangeTabIds, [2])
    }

    func testApplyingSnapshotHonorsExplicitNilOpenerForKnownTab() throws {
        var relationGraph = NativeTabRelationGraph(
            knownTabIds: Set([1, 2]),
            openerByTabId: [
                2: 1,
            ],
            resetOnActiveChangeTabIds: [2],
            version: 2
        )

        let snapshot = try XCTUnwrap(
            NativeTabRelationshipSnapshot(
                dictionary: [
                    "windowId": 7,
                    "version": 3,
                    "openerByTabId": [
                        1: NSNull(),
                        2: NSNull(),
                    ],
                    "resetOnActiveChangeTabIds": [2],
                ],
                fallbackWindowId: 7
            )
        )

        relationGraph.apply(snapshot: snapshot)

        XCTAssertNil(relationGraph.openerByTabId[2])
        XCTAssertEqual(relationGraph.resetOnActiveChangeTabIds, [2])
    }
}
