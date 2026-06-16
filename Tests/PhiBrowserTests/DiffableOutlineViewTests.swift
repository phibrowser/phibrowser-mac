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

    func record(_ event: String) {
        events.append(event)
    }

    func clearEvents() {
        events.removeAll()
    }

    override func reloadData() {
        events.append("reloadData")
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
    }

    override func applyMove(from fromIndex: Int, inParent oldParent: Any?, to toIndex: Int, inParent newParent: Any?) {
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
    func testFirstSnapshotUpdatesDataSourceBeforeReloadData() {
        let view = RecordingDiffableOutlineView()
        let snapshot = applySnapshot(["item0"], ["item0": (OutlineApplyItem("item0"), nil, [])])

        view.reloadWith(snapshot, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "reloadData"])
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
            "reloadRows:[1]",
            "endUpdates",
        ])
    }

    func testInvalidSnapshotDoesNotUpdateDataSource() {
        let view = RecordingDiffableOutlineView()
        let invalid = DiffableOutlineSnapshot<AnyHashable>(rootIDs: [AnyHashable("missing")], nodes: [:])

        view.reloadWith(invalid, animated: false) {
            view.record("updateDataSource")
        }

        XCTAssertTrue(view.events.isEmpty)
    }

    func testSideBarOutlineViewIsDiffableOutlineView() {
        let view = SideBarOutlineView()

        XCTAssertTrue(view is DiffableOutlineView)
    }
}
