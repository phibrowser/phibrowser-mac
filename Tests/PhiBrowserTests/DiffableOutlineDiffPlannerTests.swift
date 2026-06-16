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

private func snapshot(_ roots: [String], _ nodes: [String: (String?, [String])]) -> DiffableOutlineSnapshot<String> {
    var snapshotNodes: [String: DiffableOutlineSnapshot<String>.Node] = [:]
    for (id, value) in nodes {
        snapshotNodes[id] = .init(id: id, item: item(id), parentID: value.0, childIDs: value.1)
    }
    return DiffableOutlineSnapshot(rootIDs: roots, nodes: snapshotNodes)
}

final class DiffableOutlineDiffPlannerTests: XCTestCase {
    func testRootInsertProducesInsertOperation() {
        let old = snapshot(["a"], ["a": (nil, [])])
        let new = snapshot(["a", "b"], ["a": (nil, []), "b": (nil, [])])

        let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

        XCTAssertEqual(plan.operations, [.insert(id: "b", parentID: nil, index: 1)])
        XCTAssertTrue(plan.isSafe)
    }

    func testChildDeleteProducesRemoveOperationAtOldIndex() {
        let old = snapshot(["folder"], [
            "folder": (nil, ["a", "b"]),
            "a": ("folder", []),
            "b": ("folder", []),
        ])
        let new = snapshot(["folder"], [
            "folder": (nil, ["a"]),
            "a": ("folder", []),
        ])

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
}
