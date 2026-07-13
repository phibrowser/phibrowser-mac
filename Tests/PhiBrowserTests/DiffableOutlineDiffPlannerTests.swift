import XCTest
@testable import Phi

private final class PlannerItem: NSObject {
    let name: String

    init(_ name: String) {
        self.name = name
        super.init()
    }
}

private func item(_ id: String) -> PlannerItem {
    PlannerItem(id)
}

private func snapshot(
    _ roots: [String],
    _ nodes: [String: (String?, [String])],
    items: [String: PlannerItem] = [:]
) -> DiffableOutlineSnapshot<String> {
    var snapshotNodes: [String: DiffableOutlineSnapshot<String>.Node] = [:]
    for (id, value) in nodes {
        snapshotNodes[id] = .init(id: id, item: items[id] ?? item(id), parentID: value.0, childIDs: value.1)
    }
    return DiffableOutlineSnapshot(rootIDs: roots, nodes: snapshotNodes)
}

final class DiffableOutlineDiffPlannerTests: XCTestCase {
    func testRootInsertProducesInsertOperation() {
        let a = item("a")
        let old = snapshot(["a"], ["a": (nil, [])], items: ["a": a])
        let new = snapshot(["a", "b"], ["a": (nil, []), "b": (nil, [])], items: ["a": a])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.insert(id: "b", parentID: nil, index: 1)])
        XCTAssertTrue(plan.isSafe)
    }

    func testChildDeleteProducesRemoveOperationAtOldIndex() {
        let folder = item("folder")
        let a = item("a")
        let old = snapshot(["folder"], [
            "folder": (nil, ["a", "b"]),
            "a": ("folder", []),
            "b": ("folder", []),
        ], items: ["folder": folder, "a": a])
        let new = snapshot(["folder"], [
            "folder": (nil, ["a"]),
            "a": ("folder", []),
        ], items: ["folder": folder, "a": a])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.remove(id: "b", parentID: "folder", index: 1)])
    }

    func testSubtreeDeleteOnlyRemovesHighestDeletedNode() {
        let old = snapshot(["folder"], [
            "folder": (nil, ["child"]),
            "child": ("folder", ["grandchild"]),
            "grandchild": ("child", []),
        ])
        let new = DiffableOutlineSnapshot<String>(rootIDs: [], nodes: [:])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.remove(id: "folder", parentID: nil, index: 0)])
    }

    func testSubtreeInsertOnlyInsertsHighestInsertedNode() {
        let old = DiffableOutlineSnapshot<String>(rootIDs: [], nodes: [:])
        let new = snapshot(["folder"], [
            "folder": (nil, ["child"]),
            "child": ("folder", ["grandchild"]),
            "grandchild": ("child", []),
        ])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.insert(id: "folder", parentID: nil, index: 0)])
    }

    func testSameParentReorderProducesMoveUsingCollectionDifference() {
        let a = item("a")
        let b = item("b")
        let c = item("c")
        let items = ["a": a, "b": b, "c": c]
        let old = snapshot(["a", "b", "c"], ["a": (nil, []), "b": (nil, []), "c": (nil, [])], items: items)
        let new = snapshot(["b", "a", "c"], ["a": (nil, []), "b": (nil, []), "c": (nil, [])], items: items)

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.move(id: "b", parentID: nil, from: 1, to: 0)])
    }

    func testMovingFirstRootToEndUsesForwardMovesCompatibleWithOutlineView() {
        let group = item("group")
        let a = item("a")
        let b = item("b")
        let c = item("c")
        let items = ["group": group, "a": a, "b": b, "c": c]
        let nodes: [String: (String?, [String])] = [
            "group": (nil, []),
            "a": (nil, []),
            "b": (nil, []),
            "c": (nil, []),
        ]
        let old = snapshot(["group", "a", "b", "c"], nodes, items: items)
        let new = snapshot(["a", "b", "c", "group"], nodes, items: items)

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [
            .move(id: "a", parentID: nil, from: 1, to: 0),
            .move(id: "b", parentID: nil, from: 2, to: 1),
            .move(id: "c", parentID: nil, from: 3, to: 2),
        ])
        XCTAssertTrue(plan.isSafe)
    }

    func testStableParentChildReorderProducesMove() {
        let folder = item("folder")
        let a = item("a")
        let b = item("b")
        let old = snapshot(["folder"], [
            "folder": (nil, ["a", "b"]),
            "a": ("folder", []),
            "b": ("folder", []),
        ], items: ["folder": folder, "a": a, "b": b])
        let new = snapshot(["folder"], [
            "folder": (nil, ["b", "a"]),
            "a": ("folder", []),
            "b": ("folder", []),
        ], items: ["folder": folder, "a": a, "b": b])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.move(id: "b", parentID: "folder", from: 1, to: 0)])
    }

    func testCrossParentMoveUsesRemoveAndInsert() {
        let left = item("left")
        let right = item("right")
        let movingItem = item("item")
        let items = ["left": left, "right": right, "item": movingItem]
        let old = snapshot(["left", "right"], [
            "left": (nil, ["item"]),
            "right": (nil, []),
            "item": ("left", []),
        ], items: items)
        let new = snapshot(["left", "right"], [
            "left": (nil, []),
            "right": (nil, ["item"]),
            "item": ("right", []),
        ], items: items)

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [
            .remove(id: "item", parentID: "left", index: 0),
            .insert(id: "item", parentID: "right", index: 0),
        ])
    }

    func testIdentityReplacementUsesHighestChangedNode() {
        let oldRoot = item("old-root")
        let oldChild = item("old-child")
        let newRoot = item("new-root")
        let newChild = item("new-child")
        let old = DiffableOutlineSnapshot(
            rootIDs: ["root"],
            nodes: [
                "root": .init(id: "root", item: oldRoot, parentID: nil, childIDs: ["child"]),
                "child": .init(id: "child", item: oldChild, parentID: "root", childIDs: []),
            ]
        )
        let new = DiffableOutlineSnapshot(
            rootIDs: ["root"],
            nodes: [
                "root": .init(id: "root", item: newRoot, parentID: nil, childIDs: ["child"]),
                "child": .init(id: "child", item: newChild, parentID: "root", childIDs: []),
            ]
        )

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.replace(id: "root", parentID: nil, index: 0)])
    }

    func testParentReplacementSuppressesChildReorderMove() {
        let oldFolder = item("old-folder")
        let newFolder = item("new-folder")
        let a = item("a")
        let b = item("b")
        let old = snapshot(["folder"], [
            "folder": (nil, ["a", "b"]),
            "a": ("folder", []),
            "b": ("folder", []),
        ], items: ["folder": oldFolder, "a": a, "b": b])
        let new = snapshot(["folder"], [
            "folder": (nil, ["b", "a"]),
            "a": ("folder", []),
            "b": ("folder", []),
        ], items: ["folder": newFolder, "a": a, "b": b])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.replace(id: "folder", parentID: nil, index: 0)])
    }

    func testReplacementSiblingWithSameParentMoveIsUnsafe() {
        let oldProxy = item("old-proxy")
        let newProxy = item("new-proxy")
        let a = item("a")
        let b = item("b")
        let old = snapshot(["proxy", "a", "b"], [
            "proxy": (nil, []),
            "a": (nil, []),
            "b": (nil, []),
        ], items: ["proxy": oldProxy, "a": a, "b": b])
        let new = snapshot(["proxy", "b", "a"], [
            "proxy": (nil, []),
            "a": (nil, []),
            "b": (nil, []),
        ], items: ["proxy": newProxy, "a": a, "b": b])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertFalse(plan.isSafe)
        XCTAssertTrue(plan.operations.isEmpty)
    }

    func testReplacementThatAlsoChangesSiblingIndexIsUnsafe() {
        let oldGroup = item("old-group")
        let newGroup = item("new-group")
        let tab = item("tab")
        let old = snapshot(["group", "tab"], [
            "group": (nil, []),
            "tab": (nil, []),
        ], items: ["group": oldGroup, "tab": tab])
        let new = snapshot(["tab", "group"], [
            "group": (nil, []),
            "tab": (nil, []),
        ], items: ["group": newGroup, "tab": tab])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertFalse(plan.isSafe)
        XCTAssertTrue(plan.operations.isEmpty)
    }

    func testParentReplacementSuppressesChildInsert() {
        let oldFolder = item("old-folder")
        let newFolder = item("new-folder")
        let child = item("child")
        let old = snapshot(["folder"], [
            "folder": (nil, []),
        ], items: ["folder": oldFolder])
        let new = snapshot(["folder"], [
            "folder": (nil, ["child"]),
            "child": ("folder", []),
        ], items: ["folder": newFolder, "child": child])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.replace(id: "folder", parentID: nil, index: 0)])
    }

    func testExplicitReloadMarkerProducesReload() {
        let base = ["a": (Optional<String>.none, [String]())]
        let old = snapshot(["a"], base)
        let new = DiffableOutlineSnapshot(
            rootIDs: ["a"],
            nodes: ["a": .init(id: "a", item: item("a"), parentID: nil, childIDs: [])],
            reloadIDs: ["a"]
        )

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.replace(id: "a", parentID: nil, index: 0), .reload(id: "a")])
    }

    func testInvalidSnapshotProducesUnsafePlan() {
        let old = DiffableOutlineSnapshot<String>(rootIDs: [], nodes: [:])
        let invalid = DiffableOutlineSnapshot(
            rootIDs: ["missing"],
            nodes: [:]
        )

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: invalid)

        XCTAssertFalse(plan.isSafe)
        XCTAssertTrue(plan.operations.isEmpty)
    }
}
