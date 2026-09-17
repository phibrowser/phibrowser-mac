// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

private final class OutlineApplyItem: NSObject {
    let id: String

    init(_ id: String) {
        self.id = id
        super.init()
    }
}

private final class RecordingDiffableOutlineView: DiffableOutlineView {
    private(set) var events: [String] = []
    private(set) var invalidSnapshotErrors: [DiffableOutlineSnapshotValidationError<AnyHashable>] = []
    var onApplyInsert: (() -> Void)?
    private(set) var lastMoveAnimationDuration: TimeInterval?

    func record(_ event: String) {
        events.append(event)
    }

    func clearEvents() {
        events.removeAll()
    }

    override func reloadData() {
        events.append("reloadData")
    }

    override func reportInvalidSnapshot(_ error: DiffableOutlineSnapshotValidationError<AnyHashable>) {
        invalidSnapshotErrors.append(error)
    }

    override func beginUpdates() {
        events.append("beginUpdates")
    }

    override func endUpdates() {
        events.append("endUpdates")
    }

    override func applyRemove(at indexes: IndexSet, inParent parent: Any?, animation: NSOutlineView.AnimationOptions) {
        events.append("remove:\(Array(indexes)):\(parentID(parent)):\(animationDescription(animation))")
    }

    override func applyInsert(at indexes: IndexSet, inParent parent: Any?, animation: NSOutlineView.AnimationOptions) {
        events.append("insert:\(Array(indexes)):\(parentID(parent)):\(animationDescription(animation))")
        onApplyInsert?()
    }

    override func applyMove(from fromIndex: Int, inParent oldParent: Any?, to toIndex: Int, inParent newParent: Any?) {
        lastMoveAnimationDuration = NSAnimationContext.current.duration
        events.append("move:\(fromIndex):\(parentID(oldParent))->\(toIndex):\(parentID(newParent))")
    }

    override func applyReload(rowIndexes: IndexSet) {
        events.append("reloadRows:\(Array(rowIndexes))")
    }

    override func row(forItem item: Any?) -> Int {
        guard let item = item as? OutlineApplyItem else { return -1 }
        return Int(item.id.filter(\.isNumber)) ?? 0
    }

    private func parentID(_ parent: Any?) -> String {
        guard let parent = parent as? OutlineApplyItem else { return "root" }
        return parent.id
    }

    private func animationDescription(_ animation: NSOutlineView.AnimationOptions) -> String {
        animation.isEmpty ? "none" : "animated"
    }
}

private func applySnapshot(
    _ roots: [String],
    _ nodes: [String: (OutlineApplyItem, String?, [String])]
) -> DiffableOutlineSnapshot<AnyHashable> {
    var snapshotNodes: [AnyHashable: DiffableOutlineSnapshot<AnyHashable>.Node] = [:]
    for (id, value) in nodes {
        snapshotNodes[AnyHashable(id)] = .init(
            id: AnyHashable(id),
            item: value.0,
            parentID: value.1.map(AnyHashable.init),
            childIDs: value.2.map(AnyHashable.init)
        )
    }
    return DiffableOutlineSnapshot(rootIDs: roots.map(AnyHashable.init), nodes: snapshotNodes)
}

final class DiffableOutlineViewTests: XCTestCase {
    func testResetDuringFirstLoadForcesPendingRequestToReloadData() {
        let view = RecordingDiffableOutlineView()
        let snapshot = applySnapshot(["item0"], ["item0": (OutlineApplyItem("item0"), nil, [])])

        view.reloadWith(snapshot, animated: false) {
            view.resetDiffableSnapshot()
            view.reloadWith(snapshot, animated: false) { view.record("pendingDataSource") }
        }

        XCTAssertEqual(view.events, ["reloadData", "pendingDataSource", "reloadData"])
    }

    func testResetDuringFallbackPreparationForcesPendingRequestToReloadData() {
        let view = RecordingDiffableOutlineView()
        let snapshot = applySnapshot(["item0"], ["item0": (OutlineApplyItem("item0"), nil, [])])
        view.resetDiffableSnapshot(.init(rootIDs: [AnyHashable("missing")], nodes: [:]))

        view.reloadWith(snapshot, animated: false, updateDataSource: {}, prepareReloadData: {
            view.resetDiffableSnapshot()
            view.reloadWith(snapshot, animated: false) { view.record("pendingDataSource") }
        })

        XCTAssertEqual(view.events, ["reloadData", "pendingDataSource", "reloadData"])
    }

    func testResetDuringInsertForcesPendingRequestToReloadData() {
        let view = RecordingDiffableOutlineView()
        let item = OutlineApplyItem("item0")
        let snapshot = applySnapshot(["item0"], ["item0": (item, nil, [])])
        view.reloadWith(applySnapshot([], [:]), animated: false) {}
        view.clearEvents()
        view.onApplyInsert = {
            view.onApplyInsert = nil
            view.resetDiffableSnapshot()
            view.reloadWith(snapshot, animated: false) { view.record("pendingDataSource") }
        }

        view.reloadWith(snapshot, animated: false) {}

        XCTAssertEqual(view.events, [
            "beginUpdates", "insert:[0]:root:none", "endUpdates",
            "pendingDataSource", "reloadData",
        ])
    }

    func testExplicitResetBaselineDuringApplyRemainsUntrustedForNextRequest() {
        let view = RecordingDiffableOutlineView()
        let snapshot = applySnapshot(["item0"], ["item0": (OutlineApplyItem("item0"), nil, [])])

        view.reloadWith(snapshot, animated: false) {
            view.resetDiffableSnapshot(.init(rootIDs: [AnyHashable("missing")], nodes: [:]))
        }
        view.clearEvents()
        view.reloadWith(snapshot, animated: false) { view.record("nextDataSource") }

        XCTAssertEqual(view.events, ["nextDataSource", "reloadData"])
        XCTAssertTrue(view.invalidSnapshotErrors.isEmpty)
    }

    func testFirstSnapshotUpdatesDataSourceBeforeReloadData() {
        let view = RecordingDiffableOutlineView()
        let snapshot = applySnapshot(["item0"], ["item0": (OutlineApplyItem("item0"), nil, [])])

        view.reloadWith(snapshot, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "reloadData"])
    }

    func testPrepareReloadDataRunsBeforeReloadData() {
        let view = RecordingDiffableOutlineView()
        let snapshot = applySnapshot(["item0"], ["item0": (OutlineApplyItem("item0"), nil, [])])

        view.reloadWith(snapshot, animated: false) {
            view.record("updateDataSource")
        } prepareReloadData: {
            view.record("prepareReloadData")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "prepareReloadData", "reloadData"])
    }

    func testResetDiffableSnapshotForcesNextApplyToReloadData() {
        let view = RecordingDiffableOutlineView()
        let item0 = OutlineApplyItem("item0")
        let old = applySnapshot(["item0"], ["item0": (item0, nil, [])])
        let new = applySnapshot(["item0", "item1"], [
            "item0": (item0, nil, []),
            "item1": (OutlineApplyItem("item1"), nil, []),
        ])
        view.reloadWith(old, animated: false) {}
        view.resetDiffableSnapshot()
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "reloadData"])
    }

    func testResetToInvalidSnapshotKeepsCheckedPlannerFallback() {
        let view = RecordingDiffableOutlineView()
        let invalid = DiffableOutlineSnapshot<AnyHashable>(
            rootIDs: [AnyHashable("missing")],
            nodes: [:]
        )
        let valid = applySnapshot(
            ["item0"],
            ["item0": (OutlineApplyItem("item0"), nil, [])]
        )
        view.resetDiffableSnapshot(invalid)

        view.reloadWith(valid, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "reloadData"])
        XCTAssertTrue(view.invalidSnapshotErrors.isEmpty)
    }

    func testInsertUpdatesDataSourceBeforeMutation() {
        let view = RecordingDiffableOutlineView()
        let item0 = OutlineApplyItem("item0")
        let old = applySnapshot(["item0"], ["item0": (item0, nil, [])])
        let new = applySnapshot(["item0", "item1"], [
            "item0": (item0, nil, []),
            "item1": (OutlineApplyItem("item1"), nil, []),
        ])
        view.reloadWith(old, animated: false) {
            view.record("initialData")
        }
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "beginUpdates", "insert:[1]:root:none", "endUpdates"])
    }

    func testReentrantReloadAppliesOnlyLatestPendingSnapshot() {
        let view = RecordingDiffableOutlineView()
        let item0 = OutlineApplyItem("item0")
        let item1 = OutlineApplyItem("item1")
        let item2 = OutlineApplyItem("item2")
        let item3 = OutlineApplyItem("item3")
        let old = applySnapshot(["item0"], [
            "item0": (item0, nil, []),
        ])
        let first = applySnapshot(["item0", "item1"], [
            "item0": (item0, nil, []),
            "item1": (item1, nil, []),
        ])
        let stale = applySnapshot(["item0", "item1", "item2"], [
            "item0": (item0, nil, []),
            "item1": (item1, nil, []),
            "item2": (item2, nil, []),
        ])
        let latest = applySnapshot(["item0", "item1", "item3"], [
            "item0": (item0, nil, []),
            "item1": (item1, nil, []),
            "item3": (item3, nil, []),
        ])
        view.reloadWith(old, animated: false) {}
        view.clearEvents()

        view.onApplyInsert = { [weak view] in
            guard let view else { return }
            view.onApplyInsert = nil
            view.reloadWith(stale, animated: false) {
                view.record("staleData")
            }
            view.reloadWith(latest, animated: false) {
                view.record("latestData")
            }
        }

        view.reloadWith(first, animated: false) {
            view.record("firstData")
        }

        XCTAssertEqual(view.events, [
            "firstData",
            "beginUpdates",
            "insert:[1]:root:none",
            "endUpdates",
            "latestData",
            "beginUpdates",
            "insert:[2]:root:none",
            "endUpdates",
        ])
    }

    func testFirstLoadQueuesReentrantDataSourceUpdateUntilSnapshotIsCommitted() {
        let view = RecordingDiffableOutlineView()
        let item0 = OutlineApplyItem("item0")
        let item1 = OutlineApplyItem("item1")
        let first = applySnapshot(["item0"], ["item0": (item0, nil, [])])
        let latest = applySnapshot(["item0", "item1"], [
            "item0": (item0, nil, []),
            "item1": (item1, nil, []),
        ])

        view.reloadWith(first, animated: false) {
            view.record("firstData")
            view.reloadWith(latest, animated: false) {
                view.record("latestData")
            }
        }

        XCTAssertEqual(view.events, [
            "firstData", "reloadData", "latestData",
            "beginUpdates", "insert:[1]:root:none", "endUpdates",
        ])
        view.clearEvents()
        view.reloadWith(latest, animated: false) {}
        XCTAssertTrue(view.events.isEmpty, "The committed baseline must be the latest snapshot.")
    }

    func testFallbackQueuesReloadRequestedWhilePreparingCells() {
        let view = RecordingDiffableOutlineView()
        let item0 = OutlineApplyItem("item0")
        let item1 = OutlineApplyItem("item1")
        let first = applySnapshot(["item0"], ["item0": (item0, nil, [])])
        let latest = applySnapshot(["item0", "item1"], [
            "item0": (item0, nil, []),
            "item1": (item1, nil, []),
        ])
        view.resetDiffableSnapshot(.init(rootIDs: ["missing"], nodes: [:]))

        view.reloadWith(first, animated: false, updateDataSource: {
            view.record("firstData")
        }, prepareReloadData: {
            view.record("prepare")
            view.reloadWith(latest, animated: false) {
                view.record("latestData")
            }
        })

        XCTAssertEqual(view.events, [
            "firstData", "prepare", "reloadData", "latestData",
            "beginUpdates", "insert:[1]:root:none", "endUpdates",
        ])
    }

    func testReplaceUsesOldParentForRemoveAndNewParentForInsert() {
        let view = RecordingDiffableOutlineView()
        let oldFolder = OutlineApplyItem("oldFolder")
        let newFolder = OutlineApplyItem("newFolder")
        let oldChild = OutlineApplyItem("item1")
        let newChild = OutlineApplyItem("item1")
        let old = applySnapshot(["folder"], [
            "folder": (oldFolder, nil, ["item1"]),
            "item1": (oldChild, "folder", []),
        ])
        let new = applySnapshot(["folder"], [
            "folder": (newFolder, nil, ["item1"]),
            "item1": (newChild, "folder", []),
        ])
        view.reloadWith(old, animated: false) {}
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, [
            "updateDataSource",
            "beginUpdates",
            "remove:[0]:root:none",
            "insert:[0]:root:none",
            "endUpdates",
        ])
    }

    func testStableParentChildReorderAppliesMove() {
        let view = RecordingDiffableOutlineView()
        let folder = OutlineApplyItem("folder")
        let childA = OutlineApplyItem("item1")
        let childB = OutlineApplyItem("item2")
        let old = applySnapshot(["folder"], [
            "folder": (folder, nil, ["item1", "item2"]),
            "item1": (childA, "folder", []),
            "item2": (childB, "folder", []),
        ])
        let new = applySnapshot(["folder"], [
            "folder": (folder, nil, ["item2", "item1"]),
            "item1": (childA, "folder", []),
            "item2": (childB, "folder", []),
        ])
        view.reloadWith(old, animated: false) {}
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, [
            "updateDataSource",
            "beginUpdates",
            "move:1:folder->0:folder",
            "endUpdates",
        ])
        XCTAssertEqual(view.lastMoveAnimationDuration, 0)
    }

    func testParentReplacementDoesNotApplyChildMove() {
        let view = RecordingDiffableOutlineView()
        let oldFolder = OutlineApplyItem("folder")
        let newFolder = OutlineApplyItem("folder")
        let childA = OutlineApplyItem("item1")
        let childB = OutlineApplyItem("item2")
        let old = applySnapshot(["folder"], [
            "folder": (oldFolder, nil, ["item1", "item2"]),
            "item1": (childA, "folder", []),
            "item2": (childB, "folder", []),
        ])
        let new = applySnapshot(["folder"], [
            "folder": (newFolder, nil, ["item2", "item1"]),
            "item1": (childA, "folder", []),
            "item2": (childB, "folder", []),
        ])
        view.reloadWith(old, animated: false) {}
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, [
            "updateDataSource",
            "beginUpdates",
            "remove:[0]:root:none",
            "insert:[0]:root:none",
            "endUpdates",
        ])
    }

    func testReplacementSiblingMoveFallsBackToReloadData() {
        let view = RecordingDiffableOutlineView()
        let oldProxy = OutlineApplyItem("proxy")
        let newProxy = OutlineApplyItem("proxy")
        let item1 = OutlineApplyItem("item1")
        let item2 = OutlineApplyItem("item2")
        let old = applySnapshot(["proxy", "item1", "item2"], [
            "proxy": (oldProxy, nil, []),
            "item1": (item1, nil, []),
            "item2": (item2, nil, []),
        ])
        let new = applySnapshot(["proxy", "item2", "item1"], [
            "proxy": (newProxy, nil, []),
            "item1": (item1, nil, []),
            "item2": (item2, nil, []),
        ])
        view.reloadWith(old, animated: false) {}
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "reloadData"])
    }

    func testReplacementSiblingStructuralRemovalFallsBackToReloadData() {
        let view = RecordingDiffableOutlineView()
        let a = OutlineApplyItem("a")
        let oldProxy = OutlineApplyItem("proxy")
        let newProxy = OutlineApplyItem("proxy")
        let b = OutlineApplyItem("b")
        let old = applySnapshot(["a", "proxy", "b"], [
            "a": (a, nil, []),
            "proxy": (oldProxy, nil, []),
            "b": (b, nil, []),
        ])
        let new = applySnapshot(["b", "proxy"], [
            "b": (b, nil, []),
            "proxy": (newProxy, nil, []),
        ])
        view.reloadWith(old, animated: false) {}
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "reloadData"])
    }

    func testMovingReplacementFallsBackToReloadData() {
        let view = RecordingDiffableOutlineView()
        let oldGroup = OutlineApplyItem("group")
        let newGroup = OutlineApplyItem("group")
        let tab = OutlineApplyItem("item1")
        let old = applySnapshot(["group", "item1"], [
            "group": (oldGroup, nil, []),
            "item1": (tab, nil, []),
        ])
        let new = applySnapshot(["item1", "group"], [
            "group": (newGroup, nil, []),
            "item1": (tab, nil, []),
        ])
        view.reloadWith(old, animated: false) {}
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "reloadData"])
    }

    func testReloadOperationResolvesRowsAfterDataSourceUpdate() {
        let view = RecordingDiffableOutlineView()
        let item1 = OutlineApplyItem("item1")
        let old = applySnapshot(["item1"], ["item1": (item1, nil, [])])
        let new = DiffableOutlineSnapshot(
            rootIDs: [AnyHashable("item1")],
            nodes: [AnyHashable("item1"): .init(id: AnyHashable("item1"), item: item1, parentID: nil, childIDs: [])],
            reloadIDs: [AnyHashable("item1")]
        )
        view.reloadWith(old, animated: false) {}
        view.clearEvents()

        view.reloadWith(new, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, [
            "updateDataSource",
            "beginUpdates",
            "endUpdates",
            "reloadRows:[1]",
        ])
    }

    func testInvalidSnapshotReportsErrorWithoutUpdatingDataSource() {
        let view = RecordingDiffableOutlineView()
        let invalid = DiffableOutlineSnapshot<AnyHashable>(rootIDs: [AnyHashable("missing")], nodes: [:])

        view.reloadWith(invalid, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertTrue(view.events.isEmpty)
        XCTAssertEqual(
            view.invalidSnapshotErrors,
            [.missingRoot(AnyHashable("missing"))]
        )
    }

    func testOrphanSnapshotCannotBecomeValidatedBaselineForLinkedTransition() {
        let view = RecordingDiffableOutlineView()
        let parent = OutlineApplyItem("parent")
        let orphan = OutlineApplyItem("orphan")
        let orphanSnapshot = applySnapshot(["parent"], [
            "parent": (parent, nil, []),
            "orphan": (orphan, "parent", []),
        ])
        let linkedSnapshot = applySnapshot(["parent"], [
            "parent": (parent, nil, ["orphan"]),
            "orphan": (orphan, "parent", []),
        ])

        view.reloadWith(orphanSnapshot, animated: false) {
            view.record("orphanDataSource")
        }

        XCTAssertTrue(view.events.isEmpty)
        XCTAssertEqual(
            view.invalidSnapshotErrors,
            [.unreachableNode(AnyHashable("orphan"))]
        )

        view.reloadWith(linkedSnapshot, animated: false) {
            view.record("linkedDataSource")
        }

        XCTAssertEqual(view.events, ["linkedDataSource", "reloadData"])
        XCTAssertEqual(
            view.invalidSnapshotErrors,
            [.unreachableNode(AnyHashable("orphan"))]
        )
    }

    func testSideBarOutlineViewIsDiffableOutlineView() {
        let view = SideBarOutlineView()

        XCTAssertTrue(view is DiffableOutlineView)
    }
}
