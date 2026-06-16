import XCTest
@testable import Phi

private final class DiffableOutlineTestItem: NSObject {
    let name: String

    init(_ name: String) {
        self.name = name
        super.init()
    }
}

final class DiffableOutlineSnapshotTests: XCTestCase {
    func testValidSnapshotPreservesRootAndChildOrder() {
        let folder = DiffableOutlineTestItem("folder")
        let childA = DiffableOutlineTestItem("child-a")
        let childB = DiffableOutlineTestItem("child-b")

        let snapshot = DiffableOutlineSnapshot(
            rootIDs: ["folder"],
            nodes: [
                "folder": .init(id: "folder", item: folder, parentID: nil, childIDs: ["child-a", "child-b"]),
                "child-a": .init(id: "child-a", item: childA, parentID: "folder", childIDs: []),
                "child-b": .init(id: "child-b", item: childB, parentID: "folder", childIDs: []),
            ]
        )

        XCTAssertNil(snapshot.validationError)
        XCTAssertEqual(snapshot.rootIDs, ["folder"])
        XCTAssertEqual(snapshot.childIDs(of: "folder"), ["child-a", "child-b"])
        XCTAssertEqual(snapshot.parentID(of: "child-a"), "folder")
        XCTAssertEqual(snapshot.index(of: "child-b"), 1)
        XCTAssertTrue(snapshot.item(for: "folder") === folder)
    }

    func testDuplicateChildReferenceFailsValidation() {
        let parent = DiffableOutlineTestItem("parent")
        let child = DiffableOutlineTestItem("child")

        let snapshot = DiffableOutlineSnapshot(
            rootIDs: ["parent"],
            nodes: [
                "parent": .init(id: "parent", item: parent, parentID: nil, childIDs: ["child", "child"]),
                "child": .init(id: "child", item: child, parentID: "parent", childIDs: []),
            ]
        )

        XCTAssertEqual(snapshot.validationError, .duplicateChildID("child"))
    }

    func testMissingParentFailsValidation() {
        let child = DiffableOutlineTestItem("child")

        let snapshot = DiffableOutlineSnapshot(
            rootIDs: [],
            nodes: [
                "child": .init(id: "child", item: child, parentID: "missing", childIDs: []),
            ]
        )

        XCTAssertEqual(snapshot.validationError, .missingParent(id: "child", parentID: "missing"))
    }

    func testCycleFailsValidation() {
        let a = DiffableOutlineTestItem("a")
        let b = DiffableOutlineTestItem("b")

        let snapshot = DiffableOutlineSnapshot(
            rootIDs: [],
            nodes: [
                "a": .init(id: "a", item: a, parentID: "b", childIDs: ["b"]),
                "b": .init(id: "b", item: b, parentID: "a", childIDs: ["a"]),
            ]
        )

        XCTAssertEqual(snapshot.validationError, .cycleDetected("a"))
    }

    func testSameIDCanUseDifferentItemInstanceAcrossSnapshots() {
        let first = DiffableOutlineTestItem("first")
        let second = DiffableOutlineTestItem("second")

        let old = DiffableOutlineSnapshot(
            rootIDs: ["item"],
            nodes: ["item": .init(id: "item", item: first, parentID: nil, childIDs: [])]
        )
        let new = DiffableOutlineSnapshot(
            rootIDs: ["item"],
            nodes: ["item": .init(id: "item", item: second, parentID: nil, childIDs: [])]
        )

        XCTAssertNil(old.validationError)
        XCTAssertNil(new.validationError)
        XCTAssertFalse(old.item(for: "item") === new.item(for: "item"))
    }
}
