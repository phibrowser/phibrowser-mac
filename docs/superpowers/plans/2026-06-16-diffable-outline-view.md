# Diffable Outline View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable `DiffableOutlineView` that applies stable-ID tree snapshots with safe incremental `NSOutlineView` mutations, then use it for sidebar tab/bookmark refreshes.

**Architecture:** Keep the existing sidebar controller as the data source and delegate. Add a small Common-layer snapshot model, tree-aware planner backed by `CollectionDifference`, and an `NSOutlineView` subclass that owns the current snapshot and mutation timing. Sidebar integration builds snapshots from the same tree used by `dataSourceChildren(of:)` and applies all structural refreshes through `reloadWith` so the view snapshot never drifts from the actual outline state.

**Tech Stack:** Swift, AppKit `NSOutlineView`, `CollectionDifference`, XCTest, `PhiBrowser-canary` Xcode scheme.

---

## File Structure

- Create `Sources/UserInterface/Common/DiffableOutlineSnapshot.swift`
  - Pure Swift tree snapshot, validation, lookup, subtree helpers, and explicit reload markers.
- Create `Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift`
  - Pure Swift planner that uses `CollectionDifference` per sibling list and emits safe outline operations.
- Create `Sources/UserInterface/Common/DiffableOutlineView.swift`
  - `NSOutlineView` subclass that stores the current snapshot, enforces apply timing, and calls AppKit mutation APIs through overridable hooks for tests.
- Modify `Sources/UserInterface/Sidebar/TabList/Views/SideBarOutlineView.swift`
  - Change inheritance from `NSOutlineView` to `DiffableOutlineView`.
- Create `Sources/UserInterface/Sidebar/TabList/SidebarDiffableSnapshotBuilder.swift`
  - Pure sidebar snapshot builder that accepts root `SidebarItem` values plus optional virtual insertion and hidden item state.
- Modify `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
  - Build sidebar snapshots, route structural refreshes through `reloadWith`, and keep existing delegate/data-source ownership.
- Modify `Phi.xcodeproj/project.pbxproj`
  - Register the three new Common Swift files and the sidebar snapshot builder in the app target.
- Create `Tests/PhiBrowserTests/DiffableOutlineSnapshotTests.swift`
  - Snapshot validation and lookup tests.
- Create `Tests/PhiBrowserTests/DiffableOutlineDiffPlannerTests.swift`
  - Planner tests for insert/delete/move/replace/order/fallback behavior.
- Create `Tests/PhiBrowserTests/DiffableOutlineViewTests.swift`
  - Apply timing and mutation sequencing tests using a recording subclass.
- Create `Tests/PhiBrowserTests/SidebarDiffableSnapshotTests.swift`
  - Focused tests for sidebar snapshot IDs, child ordering, hidden item filtering, and virtual focused-item insertion.

---

### Task 1: Add Snapshot Model

**Files:**
- Create: `Sources/UserInterface/Common/DiffableOutlineSnapshot.swift`
- Create: `Tests/PhiBrowserTests/DiffableOutlineSnapshotTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing snapshot tests**

Create `Tests/PhiBrowserTests/DiffableOutlineSnapshotTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineSnapshotTests
```

Expected: FAIL to compile with `Cannot find 'DiffableOutlineSnapshot' in scope`.

- [ ] **Step 3: Create snapshot implementation**

Create `Sources/UserInterface/Common/DiffableOutlineSnapshot.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct DiffableOutlineSnapshot<ItemID: Hashable> {
    struct Node {
        let id: ItemID
        let item: AnyObject
        let parentID: ItemID?
        let childIDs: [ItemID]
    }

    let rootIDs: [ItemID]
    let nodes: [ItemID: Node]
    let reloadIDs: Set<ItemID>

    init(rootIDs: [ItemID], nodes: [ItemID: Node], reloadIDs: Set<ItemID> = []) {
        self.rootIDs = rootIDs
        self.nodes = nodes
        self.reloadIDs = reloadIDs
    }

    var validationError: DiffableOutlineSnapshotValidationError<ItemID>? {
        validate()
    }

    func item(for id: ItemID) -> AnyObject? {
        nodes[id]?.item
    }

    func parentID(of id: ItemID) -> ItemID? {
        nodes[id]?.parentID
    }

    func childIDs(of parentID: ItemID?) -> [ItemID] {
        guard let parentID else { return rootIDs }
        return nodes[parentID]?.childIDs ?? []
    }

    func index(of id: ItemID) -> Int? {
        childIDs(of: parentID(of: id)).firstIndex(of: id)
    }

    func contains(_ id: ItemID) -> Bool {
        nodes[id] != nil
    }

    func depth(of id: ItemID) -> Int {
        var depth = 0
        var current = parentID(of: id)
        while let parent = current {
            depth += 1
            current = parentID(of: parent)
        }
        return depth
    }

    func descendants(of id: ItemID) -> [ItemID] {
        var result: [ItemID] = []
        func walk(_ current: ItemID) {
            for child in childIDs(of: current) {
                result.append(child)
                walk(child)
            }
        }
        walk(id)
        return result
    }

    func hasAncestor(of id: ItemID, in ids: Set<ItemID>) -> Bool {
        var current = parentID(of: id)
        while let parent = current {
            if ids.contains(parent) { return true }
            current = parentID(of: parent)
        }
        return false
    }

    private func validate() -> DiffableOutlineSnapshotValidationError<ItemID>? {
        var referencedIDs = Set<ItemID>()

        for rootID in rootIDs {
            guard nodes[rootID] != nil else { return .missingRoot(rootID) }
            if !referencedIDs.insert(rootID).inserted { return .duplicateChildID(rootID) }
            if nodes[rootID]?.parentID != nil { return .rootHasParent(rootID) }
        }

        for (id, node) in nodes {
            guard node.id == id else { return .nodeKeyMismatch(key: id, nodeID: node.id) }
            if let parentID = node.parentID, nodes[parentID] == nil {
                return .missingParent(id: id, parentID: parentID)
            }
            for childID in node.childIDs {
                guard let child = nodes[childID] else { return .missingChild(id: id, childID: childID) }
                if child.parentID != id { return .parentMismatch(id: childID, expectedParentID: id, actualParentID: child.parentID) }
                if !referencedIDs.insert(childID).inserted { return .duplicateChildID(childID) }
            }
        }

        for id in nodes.keys where !referencedIDs.contains(id) {
            if detectsCycle(startingAt: id) { return .cycleDetected(id) }
            if nodes[id]?.parentID == nil { return .unreachableNode(id) }
        }

        for id in nodes.keys {
            if detectsCycle(startingAt: id) { return .cycleDetected(id) }
        }

        if let missingReloadID = reloadIDs.first(where: { nodes[$0] == nil }) {
            return .missingReloadID(missingReloadID)
        }

        return nil
    }

    private func detectsCycle(startingAt id: ItemID) -> Bool {
        var seen = Set<ItemID>()
        var current: ItemID? = id
        while let next = current {
            if !seen.insert(next).inserted { return true }
            current = parentID(of: next)
        }
        return false
    }
}

enum DiffableOutlineSnapshotValidationError<ItemID: Hashable>: Error, Equatable {
    case missingRoot(ItemID)
    case rootHasParent(ItemID)
    case missingParent(id: ItemID, parentID: ItemID)
    case missingChild(id: ItemID, childID: ItemID)
    case parentMismatch(id: ItemID, expectedParentID: ItemID, actualParentID: ItemID?)
    case duplicateChildID(ItemID)
    case nodeKeyMismatch(key: ItemID, nodeID: ItemID)
    case unreachableNode(ItemID)
    case cycleDetected(ItemID)
    case missingReloadID(ItemID)
}
```

- [ ] **Step 4: Register snapshot source file in Xcode project**

Modify `Phi.xcodeproj/project.pbxproj`:

```pbxproj
D1F600022FD6000000000002 /* DiffableOutlineSnapshot.swift in Sources */ = {isa = PBXBuildFile; fileRef = D1F600012FD6000000000001 /* DiffableOutlineSnapshot.swift */; };
D1F600012FD6000000000001 /* DiffableOutlineSnapshot.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DiffableOutlineSnapshot.swift; sourceTree = "<group>"; };
```

Add `D1F600012FD6000000000001 /* DiffableOutlineSnapshot.swift */` to the `Common` group after `TabAreaContextMenuHelper.swift`.

Add `D1F600022FD6000000000002 /* DiffableOutlineSnapshot.swift in Sources */` to the app target `PBXSourcesBuildPhase` near `SideBarOutlineView.swift in Sources`.

- [ ] **Step 5: Run tests to verify GREEN**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineSnapshotTests
```

Expected: PASS for `DiffableOutlineSnapshotTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/UserInterface/Common/DiffableOutlineSnapshot.swift Tests/PhiBrowserTests/DiffableOutlineSnapshotTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: add diffable outline snapshot model"
```

---

### Task 2: Add Planner for Inserts, Deletes, and Subtrees

**Files:**
- Create: `Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift`
- Create: `Tests/PhiBrowserTests/DiffableOutlineDiffPlannerTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing planner tests for structural insert/delete**

Create `Tests/PhiBrowserTests/DiffableOutlineDiffPlannerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineDiffPlannerTests
```

Expected: FAIL to compile with `Cannot find 'DiffableOutlineDiffPlanner' in scope`.

- [ ] **Step 3: Create minimal planner implementation**

Create `Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum DiffableOutlineOperation<ItemID: Hashable>: Equatable {
    case remove(id: ItemID, parentID: ItemID?, index: Int)
    case move(id: ItemID, parentID: ItemID?, from: Int, to: Int)
    case insert(id: ItemID, parentID: ItemID?, index: Int)
    case replace(id: ItemID, parentID: ItemID?, index: Int)
    case reload(id: ItemID)
}

struct DiffableOutlinePlan<ItemID: Hashable> {
    let operations: [DiffableOutlineOperation<ItemID>]
    let isSafe: Bool

    static var unsafe: DiffableOutlinePlan {
        DiffableOutlinePlan(operations: [], isSafe: false)
    }
}

enum DiffableOutlineDiffPlanner {
    static func plan<ItemID: Hashable>(
        from old: DiffableOutlineSnapshot<ItemID>,
        to new: DiffableOutlineSnapshot<ItemID>
    ) -> DiffableOutlinePlan<ItemID> {
        guard old.validationError == nil, new.validationError == nil else {
            return .unsafe
        }

        let oldIDs = Set(old.nodes.keys)
        let newIDs = Set(new.nodes.keys)
        let removedIDs = oldIDs.subtracting(newIDs)
        let insertedIDs = newIDs.subtracting(oldIDs)

        let highestRemoved = removedIDs.filter { !old.hasAncestor(of: $0, in: removedIDs) }
        let highestInserted = insertedIDs.filter { !new.hasAncestor(of: $0, in: insertedIDs) }

        func removeSortKey(_ operation: DiffableOutlineOperation<ItemID>) -> (depth: Int, parent: String, index: Int) {
            guard case .remove(let id, let parentID, let index) = operation else {
                return (0, "", 0)
            }
            return (old.depth(of: id), String(describing: parentID), index)
        }

        func insertSortKey(_ operation: DiffableOutlineOperation<ItemID>) -> (depth: Int, parent: String, index: Int) {
            guard case .insert(let id, let parentID, let index) = operation else {
                return (0, "", 0)
            }
            return (new.depth(of: id), String(describing: parentID), index)
        }

        let removes = highestRemoved
            .compactMap { id -> DiffableOutlineOperation<ItemID>? in
                guard let index = old.index(of: id) else { return nil }
                return .remove(id: id, parentID: old.parentID(of: id), index: index)
            }
            .sorted { lhs, rhs in
                let left = removeSortKey(lhs)
                let right = removeSortKey(rhs)
                if left.depth != right.depth { return left.depth > right.depth }
                if left.parent != right.parent { return left.parent < right.parent }
                return left.index > right.index
            }

        let inserts = highestInserted
            .compactMap { id -> DiffableOutlineOperation<ItemID>? in
                guard let index = new.index(of: id) else { return nil }
                return .insert(id: id, parentID: new.parentID(of: id), index: index)
            }
            .sorted { lhs, rhs in
                let left = insertSortKey(lhs)
                let right = insertSortKey(rhs)
                if left.depth != right.depth { return left.depth < right.depth }
                if left.parent != right.parent { return left.parent < right.parent }
                return left.index < right.index
            }

        return DiffableOutlinePlan(operations: removes + inserts, isSafe: true)
    }
}
```

- [ ] **Step 4: Register planner source file**

Modify `Phi.xcodeproj/project.pbxproj`:

```pbxproj
D1F600042FD6000000000004 /* DiffableOutlineDiffPlanner.swift in Sources */ = {isa = PBXBuildFile; fileRef = D1F600032FD6000000000003 /* DiffableOutlineDiffPlanner.swift */; };
D1F600032FD6000000000003 /* DiffableOutlineDiffPlanner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DiffableOutlineDiffPlanner.swift; sourceTree = "<group>"; };
```

Add the file reference to the `Common` group after `DiffableOutlineSnapshot.swift`.

Add the build file to the app target source phase near `DiffableOutlineSnapshot.swift in Sources`.

- [ ] **Step 5: Run tests to verify GREEN**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineDiffPlannerTests
```

Expected: PASS for the four structural planner tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift Tests/PhiBrowserTests/DiffableOutlineDiffPlannerTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: plan diffable outline structural changes"
```

---

### Task 3: Add Planner Moves, Replacements, Reloads, and Ordering

**Files:**
- Modify: `Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift`
- Modify: `Tests/PhiBrowserTests/DiffableOutlineDiffPlannerTests.swift`

- [ ] **Step 1: Add failing tests for move, cross-parent move, replacement, reload, and invalid snapshots**

Append to `DiffableOutlineDiffPlannerTests`:

```swift
func testSameParentReorderProducesMoveUsingCollectionDifference() {
    let old = snapshot(["a", "b", "c"], ["a": (nil, []), "b": (nil, []), "c": (nil, [])])
    let new = snapshot(["b", "a", "c"], ["a": (nil, []), "b": (nil, []), "c": (nil, [])])

    let plan = DiffableOutlineDiffPlanner.plan(from: old, to: new)

    XCTAssertEqual(plan.operations, [.move(id: "b", parentID: nil, from: 1, to: 0)])
}

func testCrossParentMoveUsesRemoveAndInsert() {
    let old = snapshot(["left", "right"], [
        "left": (nil, ["item"]),
        "right": (nil, []),
        "item": ("left", []),
    ])
    let new = snapshot(["left", "right"], [
        "left": (nil, []),
        "right": (nil, ["item"]),
        "item": ("right", []),
    ])

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
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineDiffPlannerTests
```

Expected: FAIL because move, replace, reload, and unsafe handling are not implemented.

- [ ] **Step 3: Implement tree-aware move, replace, and reload planning**

Update `DiffableOutlineDiffPlanner.plan(from:to:)` to:

```swift
let oldIDs = Set(old.nodes.keys)
let newIDs = Set(new.nodes.keys)
let removedIDs = oldIDs.subtracting(newIDs)
let insertedIDs = newIDs.subtracting(oldIDs)
let commonIDs = oldIDs.intersection(newIDs)
let crossParentMovedIDs = Set(commonIDs.filter { old.parentID(of: $0) != new.parentID(of: $0) })

let structuralRemovedIDs = removedIDs.union(crossParentMovedIDs)
let structuralInsertedIDs = insertedIDs.union(crossParentMovedIDs)
let highestRemoved = structuralRemovedIDs.filter { !old.hasAncestor(of: $0, in: structuralRemovedIDs) }
let highestInserted = structuralInsertedIDs.filter { !new.hasAncestor(of: $0, in: structuralInsertedIDs) }
```

Add same-parent move planning using `CollectionDifference` as the sibling diff source:

```swift
private static func sameParentMoves<ItemID: Hashable>(
    old: DiffableOutlineSnapshot<ItemID>,
    new: DiffableOutlineSnapshot<ItemID>,
    excludedIDs: Set<ItemID>
) -> [DiffableOutlineOperation<ItemID>] {
    let parentIDs = Set(old.nodes.keys.map { Optional($0) } + [nil])
    var operations: [DiffableOutlineOperation<ItemID>] = []

    for parentID in parentIDs {
        let oldChildren = old.childIDs(of: parentID).filter { !excludedIDs.contains($0) && new.parentID(of: $0) == parentID }
        let newChildren = new.childIDs(of: parentID).filter { !excludedIDs.contains($0) && old.parentID(of: $0) == parentID }
        guard oldChildren != newChildren else { continue }

        let difference = newChildren.difference(from: oldChildren).inferringMoves()
        guard difference.containsAssociatedMove else { continue }

        var working = oldChildren
        for targetIndex in newChildren.indices {
            let targetID = newChildren[targetIndex]
            guard working.indices.contains(targetIndex), working[targetIndex] != targetID else { continue }
            guard let fromIndex = working.firstIndex(of: targetID) else { continue }
            working.remove(at: fromIndex)
            working.insert(targetID, at: targetIndex)
            operations.append(.move(id: targetID, parentID: parentID, from: fromIndex, to: targetIndex))
        }
    }

    return operations
}

private extension CollectionDifference {
    var containsAssociatedMove: Bool {
        contains { change in
            switch change {
            case .insert(_, _, let associatedWith), .remove(_, _, let associatedWith):
                return associatedWith != nil
            }
        }
    }
}
```

Add highest identity replacement planning:

```swift
private static func replacements<ItemID: Hashable>(
    old: DiffableOutlineSnapshot<ItemID>,
    new: DiffableOutlineSnapshot<ItemID>,
    excludedIDs: Set<ItemID>
) -> [DiffableOutlineOperation<ItemID>] {
    func replacementSortKey(_ operation: DiffableOutlineOperation<ItemID>) -> (depth: Int, parent: String, index: Int) {
        guard case .replace(let id, let parentID, let index) = operation else {
            return (0, "", 0)
        }
        return (new.depth(of: id), String(describing: parentID), index)
    }

    let replacedIDs = Set(old.nodes.keys).intersection(new.nodes.keys).filter { id in
        guard !excludedIDs.contains(id) else { return false }
        guard let oldItem = old.item(for: id), let newItem = new.item(for: id) else { return false }
        return oldItem !== newItem
    }

    let highestReplaced = replacedIDs.filter { !new.hasAncestor(of: $0, in: replacedIDs) }

    return highestReplaced
        .compactMap { id -> DiffableOutlineOperation<ItemID>? in
            guard let index = new.index(of: id) else { return nil }
            return .replace(id: id, parentID: new.parentID(of: id), index: index)
        }
        .sorted { lhs, rhs in
            let left = replacementSortKey(lhs)
            let right = replacementSortKey(rhs)
            if left.depth != right.depth { return left.depth < right.depth }
            if left.parent != right.parent { return left.parent < right.parent }
            return left.index < right.index
        }
}
```

Add reload planning:

```swift
let reloads = new.reloadIDs
    .filter { new.contains($0) }
    .sorted { String(describing: $0) < String(describing: $1) }
    .map { DiffableOutlineOperation.reload(id: $0) }
```

The final operation order is:

```swift
return DiffableOutlinePlan(
    operations: removes + moves + inserts + replacements + reloads,
    isSafe: true
)
```

- [ ] **Step 4: Run planner tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineDiffPlannerTests
```

Expected: PASS for all planner tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift Tests/PhiBrowserTests/DiffableOutlineDiffPlannerTests.swift
git commit -m "feat: plan diffable outline moves and replacements"
```

---

### Task 4: Add DiffableOutlineView Apply Engine

**Files:**
- Create: `Sources/UserInterface/Common/DiffableOutlineView.swift`
- Create: `Tests/PhiBrowserTests/DiffableOutlineViewTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing apply-order tests**

Create `Tests/PhiBrowserTests/DiffableOutlineViewTests.swift`:

```swift
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
        events.append("remove:\(Array(indexes)):\(parentID(parent))")
    }

    override func applyInsert(at indexes: IndexSet, inParent parent: Any?, animation: NSOutlineView.AnimationOptions) {
        events.append("insert:\(Array(indexes)):\(parentID(parent))")
    }

    override func applyMove(from fromIndex: Int, inParent oldParent: Any?, to toIndex: Int, inParent newParent: Any?) {
        events.append("move:\(fromIndex):\(parentID(oldParent))->\(toIndex):\(parentID(newParent))")
    }

    override func applyReload(rowIndexes: IndexSet) {
        events.append("reloadRows:\(Array(rowIndexes))")
    }

    override func row(forItem item: Any) -> Int {
        guard let item = item as? OutlineApplyItem else { return -1 }
        return Int(item.id.filter(\.isNumber)) ?? 0
    }

    private func parentID(_ parent: Any?) -> String {
        guard let parent = parent as? OutlineApplyItem else { return "root" }
        return parent.id
    }
}

private func applySnapshot(_ roots: [String], _ nodes: [String: (OutlineApplyItem, String?, [String])]) -> DiffableOutlineSnapshot<AnyHashable> {
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
            view.events.append("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "reloadData"])
    }

    func testInsertUpdatesDataSourceBeforeMutation() {
        let view = RecordingDiffableOutlineView()
        let old = applySnapshot(["item0"], ["item0": (OutlineApplyItem("item0"), nil, [])])
        let new = applySnapshot(["item0", "item1"], [
            "item0": (OutlineApplyItem("item0"), nil, []),
            "item1": (OutlineApplyItem("item1"), nil, []),
        ])
        view.reloadWith(old, animated: false) { view.events.append("initialData") }
        view.events.removeAll()

        view.reloadWith(new, animated: false) {
            view.events.append("updateDataSource")
        }

        XCTAssertEqual(view.events, ["updateDataSource", "beginUpdates", "insert:[1]:root", "endUpdates"])
    }

    func testInvalidSnapshotDoesNotUpdateDataSource() {
        let view = RecordingDiffableOutlineView()
        let invalid = DiffableOutlineSnapshot<AnyHashable>(rootIDs: [AnyHashable("missing")], nodes: [:])

        view.reloadWith(invalid, animated: false) {
            view.events.append("updateDataSource")
        }

        XCTAssertTrue(view.events.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineViewTests
```

Expected: FAIL to compile with `Cannot find type 'DiffableOutlineView' in scope`.

- [ ] **Step 3: Implement DiffableOutlineView**

Create `Sources/UserInterface/Common/DiffableOutlineView.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

class DiffableOutlineView: NSOutlineView {
    private var currentSnapshot: DiffableOutlineSnapshot<AnyHashable>?
    private var isApplyingSnapshot = false

    func reloadWith(
        _ snapshot: DiffableOutlineSnapshot<AnyHashable>,
        animated: Bool = true,
        updateDataSource: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reloadWith(snapshot, animated: animated, updateDataSource: updateDataSource, completion: completion)
            }
            return
        }

        guard !isApplyingSnapshot else {
            DispatchQueue.main.async { [weak self] in
                self?.reloadWith(snapshot, animated: animated, updateDataSource: updateDataSource, completion: completion)
            }
            return
        }

        guard snapshot.validationError == nil else {
            completion?()
            return
        }

        guard let oldSnapshot = currentSnapshot else {
            updateDataSource()
            reloadData()
            currentSnapshot = snapshot
            completion?()
            return
        }

        let plan = DiffableOutlineDiffPlanner.plan(from: oldSnapshot, to: snapshot)
        guard plan.isSafe else {
            updateDataSource()
            reloadData()
            currentSnapshot = snapshot
            completion?()
            return
        }

        isApplyingSnapshot = true
        updateDataSource()
        beginUpdates()
        apply(plan.operations, oldSnapshot: oldSnapshot, newSnapshot: snapshot, animated: animated)
        endUpdates()
        currentSnapshot = snapshot
        isApplyingSnapshot = false

        DispatchQueue.main.async {
            completion?()
        }
    }

    func applyRemove(at indexes: IndexSet, inParent parent: Any?, animation: NSOutlineView.AnimationOptions) {
        removeItems(at: indexes, inParent: parent, withAnimation: animation)
    }

    func applyInsert(at indexes: IndexSet, inParent parent: Any?, animation: NSOutlineView.AnimationOptions) {
        insertItems(at: indexes, inParent: parent, withAnimation: animation)
    }

    func applyMove(from fromIndex: Int, inParent oldParent: Any?, to toIndex: Int, inParent newParent: Any?) {
        moveItem(at: fromIndex, inParent: oldParent, to: toIndex, inParent: newParent)
    }

    func applyReload(rowIndexes: IndexSet) {
        guard rowIndexes.isEmpty == false else { return }
        reloadData(forRowIndexes: rowIndexes, columnIndexes: IndexSet(integersIn: 0..<numberOfColumns))
    }

    private func apply(
        _ operations: [DiffableOutlineOperation<AnyHashable>],
        oldSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        newSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        animated: Bool
    ) {
        let animation: NSOutlineView.AnimationOptions = animated ? [.effectFade, .effectGap] : []

        for operation in operations {
            switch operation {
            case .remove(let id, let parentID, let index):
                applyRemove(at: IndexSet(integer: index), inParent: oldSnapshot.item(for: parentID), animation: animation)
            case .move(_, let parentID, let from, let to):
                let parent = oldSnapshot.item(for: parentID)
                applyMove(from: from, inParent: parent, to: to, inParent: parent)
            case .insert(_, let parentID, let index):
                applyInsert(at: IndexSet(integer: index), inParent: newSnapshot.item(for: parentID), animation: animation)
            case .replace(let id, let parentID, let index):
                applyRemove(at: IndexSet(integer: index), inParent: oldSnapshot.item(for: parentID), animation: animation)
                applyInsert(at: IndexSet(integer: index), inParent: newSnapshot.item(for: parentID), animation: animation)
            case .reload(let id):
                guard let item = newSnapshot.item(for: id) else { continue }
                let row = row(forItem: item)
                guard row >= 0 else { continue }
                applyReload(rowIndexes: IndexSet(integer: row))
            }
        }
    }
}

private extension DiffableOutlineSnapshot where ItemID == AnyHashable {
    func item(for id: ItemID?) -> AnyObject? {
        guard let id else { return nil }
        return item(for: id)
    }
}
```

- [ ] **Step 4: Register view source file**

Modify `Phi.xcodeproj/project.pbxproj`:

```pbxproj
D1F600062FD6000000000006 /* DiffableOutlineView.swift in Sources */ = {isa = PBXBuildFile; fileRef = D1F600052FD6000000000005 /* DiffableOutlineView.swift */; };
D1F600052FD6000000000005 /* DiffableOutlineView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DiffableOutlineView.swift; sourceTree = "<group>"; };
```

Add the file reference to the `Common` group after `DiffableOutlineDiffPlanner.swift`.

Add the build file to the app target source phase near `DiffableOutlineDiffPlanner.swift in Sources`.

- [ ] **Step 5: Run view tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineViewTests
```

Expected: PASS for initial apply tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/UserInterface/Common/DiffableOutlineView.swift Tests/PhiBrowserTests/DiffableOutlineViewTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: add diffable outline apply engine"
```

---

### Task 5: Make SideBarOutlineView Inherit DiffableOutlineView

**Files:**
- Modify: `Sources/UserInterface/Sidebar/TabList/Views/SideBarOutlineView.swift`

- [ ] **Step 1: Write failing inheritance test**

Add to `DiffableOutlineViewTests`:

```swift
func testSideBarOutlineViewIsDiffableOutlineView() {
    let outlineView = SideBarOutlineView()

    XCTAssertTrue(outlineView is DiffableOutlineView)
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineViewTests/testSideBarOutlineViewIsDiffableOutlineView
```

Expected: FAIL because `SideBarOutlineView` still inherits directly from `NSOutlineView`.

- [ ] **Step 3: Change inheritance**

Update `Sources/UserInterface/Sidebar/TabList/Views/SideBarOutlineView.swift`:

```swift
class SideBarOutlineView: DiffableOutlineView {
```

Keep every existing override and property unchanged.

- [ ] **Step 4: Run test to verify GREEN**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineViewTests/testSideBarOutlineViewIsDiffableOutlineView
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/UserInterface/Sidebar/TabList/Views/SideBarOutlineView.swift Tests/PhiBrowserTests/DiffableOutlineViewTests.swift
git commit -m "feat: make sidebar outline view diffable"
```

---

### Task 6: Add Sidebar Snapshot Builder

**Files:**
- Create: `Sources/UserInterface/Sidebar/TabList/SidebarDiffableSnapshotBuilder.swift`
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
- Create: `Tests/PhiBrowserTests/SidebarDiffableSnapshotTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing snapshot builder tests**

Create `Tests/PhiBrowserTests/SidebarDiffableSnapshotTests.swift`:

```swift
import XCTest
@testable import Phi

private final class SnapshotSidebarItem: SidebarItem {
    let id: AnyHashable
    let title: String
    let childrenItems: [SidebarItem]

    init(id: String, title: String? = nil, children: [SidebarItem] = []) {
        self.id = AnyHashable(id)
        self.title = title ?? id
        self.childrenItems = children
    }

    var url: String? { nil }
    var iconName: String? { nil }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { !childrenItems.isEmpty }
    var hasChildren: Bool { !childrenItems.isEmpty }
    var depth: Int { 0 }
    var itemType: SidebarItemType { isExpandable ? .bookmarkFolder : .bookmark }
    var isActive: Bool { false }
    var isSelectable: Bool { true }
    var isBookmark: Bool { true }

    func performAction(with owner: SidebarTabListItemOwner?) {}
}

final class SidebarDiffableSnapshotTests: XCTestCase {
    func testSidebarSnapshotUsesStableItemIDs() {
        let child = SnapshotSidebarItem(id: "child")
        let parent = SnapshotSidebarItem(id: "parent", children: [child])

        let snapshot = SidebarDiffableSnapshotBuilder(rootItems: [parent]).makeSnapshot()

        XCTAssertEqual(snapshot.rootIDs, [AnyHashable("parent")])
        XCTAssertEqual(snapshot.childIDs(of: AnyHashable("parent")), [AnyHashable("child")])
        XCTAssertTrue(snapshot.item(for: AnyHashable("parent")) === parent)
        XCTAssertTrue(snapshot.item(for: AnyHashable("child")) === child)
    }

    func testSidebarSnapshotFiltersHiddenItem() {
        let hidden = SnapshotSidebarItem(id: "hidden")
        let visible = SnapshotSidebarItem(id: "visible")
        let parent = SnapshotSidebarItem(id: "parent", children: [hidden, visible])

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [parent],
            hiddenItemID: AnyHashable("hidden")
        ).makeSnapshot()

        XCTAssertEqual(snapshot.childIDs(of: AnyHashable("parent")), [AnyHashable("visible")])
        XCTAssertNil(snapshot.item(for: AnyHashable("hidden")))
    }

    func testSidebarSnapshotInsertsVirtualItemAtRoot() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let virtual = SnapshotSidebarItem(id: "virtual")

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [first, second],
            virtualInsertion: .init(item: virtual, parentID: nil, index: 1)
        ).makeSnapshot()

        XCTAssertEqual(snapshot.rootIDs, [AnyHashable("first"), AnyHashable("virtual"), AnyHashable("second")])
        XCTAssertTrue(snapshot.item(for: AnyHashable("virtual")) === virtual)
    }

    func testSidebarSnapshotInsertsVirtualItemInParent() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let virtual = SnapshotSidebarItem(id: "virtual")
        let parent = SnapshotSidebarItem(id: "parent", children: [first, second])

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [parent],
            virtualInsertion: .init(item: virtual, parentID: AnyHashable("parent"), index: 1)
        ).makeSnapshot()

        XCTAssertEqual(
            snapshot.childIDs(of: AnyHashable("parent")),
            [AnyHashable("first"), AnyHashable("virtual"), AnyHashable("second")]
        )
    }
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SidebarDiffableSnapshotTests
```

Expected: FAIL because `SidebarDiffableSnapshotBuilder` does not exist.

- [ ] **Step 3: Implement sidebar snapshot builder**

Create `Sources/UserInterface/Sidebar/TabList/SidebarDiffableSnapshotBuilder.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SidebarDiffableSnapshotBuilder {
    struct VirtualInsertion {
        let item: SidebarItem
        let parentID: AnyHashable?
        let index: Int
    }

    let rootItems: [SidebarItem]
    var virtualInsertion: VirtualInsertion?
    var hiddenItemID: AnyHashable?

    init(
        rootItems: [SidebarItem],
        virtualInsertion: VirtualInsertion? = nil,
        hiddenItemID: AnyHashable? = nil
    ) {
        self.rootItems = rootItems
        self.virtualInsertion = virtualInsertion
        self.hiddenItemID = hiddenItemID
    }

    func makeSnapshot() -> DiffableOutlineSnapshot<AnyHashable> {
        var nodes: [AnyHashable: DiffableOutlineSnapshot<AnyHashable>.Node] = [:]
        var visited = Set<AnyHashable>()

        func append(_ item: SidebarItem, parentID: AnyHashable?) {
            guard visited.insert(item.id).inserted else { return }
            let children = children(of: item)
            nodes[item.id] = .init(
                id: item.id,
                item: item as AnyObject,
                parentID: parentID,
                childIDs: children.map(\.id)
            )
            for child in children {
                append(child, parentID: item.id)
            }
        }

        let roots = children(of: nil)
        for root in roots {
            append(root, parentID: nil)
        }

        return DiffableOutlineSnapshot(rootIDs: roots.map(\.id), nodes: nodes)
    }

    private func children(of parent: SidebarItem?) -> [SidebarItem] {
        var children = parent?.childrenItems ?? rootItems
        if let hiddenItemID {
            children.removeAll { $0.id == hiddenItemID }
        }

        guard let virtualInsertion,
              virtualInsertion.parentID == parent?.id else {
            return children
        }

        let index = min(max(0, virtualInsertion.index), children.count)
        children.insert(virtualInsertion.item, at: index)
        return children
    }
}
```

- [ ] **Step 4: Register sidebar snapshot builder**

Modify `Phi.xcodeproj/project.pbxproj`:

```pbxproj
D1F600082FD6000000000008 /* SidebarDiffableSnapshotBuilder.swift in Sources */ = {isa = PBXBuildFile; fileRef = D1F600072FD6000000000007 /* SidebarDiffableSnapshotBuilder.swift */; };
D1F600072FD6000000000007 /* SidebarDiffableSnapshotBuilder.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SidebarDiffableSnapshotBuilder.swift; sourceTree = "<group>"; };
```

Add the file reference to the `TabList` group after `SidebarItem.swift`.

Add the build file to the app target source phase near `SidebarTabListViewController.swift in Sources`.

- [ ] **Step 5: Run builder tests to verify GREEN**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SidebarDiffableSnapshotTests
```

Expected: PASS for `SidebarDiffableSnapshotTests`.

- [ ] **Step 6: Add makeAllItems helper in the controller**

In `SidebarTabListViewController.swift`, extract the item assembly from `refreshAllItems()`:

```swift
private func makeAllItems() -> [SidebarItem] {
    var items: [SidebarItem] = []

    if showBookmarks {
        items.append(contentsOf: bookmarkSectionController.bookmarkItems)
        if !bookmarkSectionController.bookmarkItems.isEmpty && !tabSectionController.tabItems.isEmpty {
            items.append(separatorItem)
        }
    }

    items.append(contentsOf: tabSectionController.tabItems)
    return items
}
```

- [ ] **Step 7: Add controller snapshot adapter**

Add:

```swift
private func makeDiffableSnapshot(
    rootItems: [SidebarItem],
    focusedPresentation: (
        proxy: FocusedBookmarkSidebarItem,
        insertionParent: SidebarItem?,
        insertionIndex: Int
    )?
) -> DiffableOutlineSnapshot<AnyHashable> {
    let virtualInsertion: SidebarDiffableSnapshotBuilder.VirtualInsertion?
    if let focusedPresentation {
        virtualInsertion = .init(
            item: focusedPresentation.proxy,
            parentID: focusedPresentation.insertionParent?.id,
            index: focusedPresentation.insertionIndex
        )
    } else {
        virtualInsertion = nil
    }

    return SidebarDiffableSnapshotBuilder(
        rootItems: rootItems,
        virtualInsertion: virtualInsertion,
        hiddenItemID: temporarilyHiddenRealBookmarkGuid.map(AnyHashable.init)
    ).makeSnapshot()
}
```

- [ ] **Step 8: Run tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SidebarDiffableSnapshotTests
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/UserInterface/Sidebar/TabList/SidebarDiffableSnapshotBuilder.swift Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift Tests/PhiBrowserTests/SidebarDiffableSnapshotTests.swift Phi.xcodeproj/project.pbxproj
git commit -m "feat: build diffable snapshots for sidebar outline"
```

---

### Task 7: Route Sidebar Structural Refreshes Through reloadWith

**Files:**
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`

- [ ] **Step 1: Re-run existing diffable tests before wiring**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineSnapshotTests -only-testing:PhiBrowserTests/DiffableOutlineDiffPlannerTests -only-testing:PhiBrowserTests/DiffableOutlineViewTests -only-testing:PhiBrowserTests/SidebarDiffableSnapshotTests
```

Expected: PASS. This confirms the tested units that the controller wiring will call.

- [ ] **Step 2: Replace refreshAllItems with diffable apply**

Update `refreshAllItems()`:

```swift
private func refreshAllItems(animated: Bool = true) {
    guard isActive else { return }

    let items = makeAllItems()
    let oldPresentation = focusedBookmarkPresentation
    self.allItems = items
    rebuildFloatingBookmarkPresentationIfNeeded()
    let plannedPresentation = focusedBookmarkPresentation
    focusedBookmarkPresentation = oldPresentation

    let snapshot = makeDiffableSnapshot(rootItems: items, focusedPresentation: plannedPresentation)

    outlineView.reloadWith(snapshot, animated: animated) { [weak self] in
        guard let self else { return }
        self.allItems = items
        self.focusedBookmarkPresentation = plannedPresentation
        self.invalidateExistingTabCells()
    } completion: { [weak self] in
        guard let self else { return }
        self.selectActiveTab()
        self.applyFocusingSelection(for: self.browserState.focusingTab)
        self.updateVisibleBookmarkTabs()
        self.updateFloatingNewTabVisibility()
    }
}
```

- [ ] **Step 3: Update activation and inactive clearing**

Keep `clearInactiveUIState()` using `outlineView.reloadData()` because it intentionally clears state while inactive. Use `refreshAllItems(animated: false)` for first activation if animations are visually noisy:

```swift
refreshAllItems(animated: false)
```

- [ ] **Step 4: Remove or bypass manual tab incremental updater**

Update `tabSectionDidUpdate(with:)`:

```swift
func tabSectionDidUpdate(with change: TabSectionChange) {
    guard isActive else { return }
    refreshAllItems(animated: !change.needsFullReload)
    clearFloatingProxyIfTabClosed()
}
```

Leave `TabSectionChange` in place for now so `TabSectionController` stays small and existing semantics are not mixed into this task. Remove `applyIncrementalTabChange(_:)` only after verifying no callers remain.

- [ ] **Step 5: Keep selection and visible bookmark timing in completion**

Ensure no direct selection/scroll call runs between `updateDataSource` and `endUpdates`. The only post-apply work should live in the `completion` block or existing expansion callbacks.

- [ ] **Step 6: Run targeted tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineSnapshotTests -only-testing:PhiBrowserTests/DiffableOutlineDiffPlannerTests -only-testing:PhiBrowserTests/DiffableOutlineViewTests -only-testing:PhiBrowserTests/SidebarDiffableSnapshotTests
```

Expected: PASS.

- [ ] **Step 7: Build for testing**

Run:

```bash
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS'
```

Expected: build succeeds. If this hits a known runner/bootstrap/codesign issue unrelated to source, retry with a fresh derived data path:

```bash
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -derivedDataPath build/DerivedData-DiffableOutline
```

- [ ] **Step 8: Commit**

```bash
git add Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift
git commit -m "feat: apply sidebar outline updates with diffable snapshots"
```

---

### Task 8: Polish Safety Fallbacks and Final Verification

**Files:**
- Modify only the files touched by Tasks 1-7 when a verified edge case requires it:
  - `Sources/UserInterface/Common/DiffableOutlineSnapshot.swift`
  - `Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift`
  - `Sources/UserInterface/Common/DiffableOutlineView.swift`
  - `Sources/UserInterface/Sidebar/TabList/SidebarDiffableSnapshotBuilder.swift`
  - `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
  - `Tests/PhiBrowserTests/DiffableOutlineSnapshotTests.swift`
  - `Tests/PhiBrowserTests/DiffableOutlineDiffPlannerTests.swift`
  - `Tests/PhiBrowserTests/DiffableOutlineViewTests.swift`
  - `Tests/PhiBrowserTests/SidebarDiffableSnapshotTests.swift`

- [ ] **Step 1: Add any regression test for a discovered edge case**

If implementation uncovered an edge case, write a failing test first. Common examples:

```swift
func testReentrantReloadSchedulesLatestSnapshot() {
    let view = RecordingDiffableOutlineView()
    // Trigger reloadWith while updateDataSource is executing.
    // Assert the second apply runs after the first apply completes.
}
```

or:

```swift
func testReplacementUnderRemovedAncestorDoesNotEmitChildReplacement() {
    // Old parent and child removed, child object also changed.
    // Assert only parent remove is emitted.
}
```

- [ ] **Step 2: Implement the minimal safety fix**

Keep fixes inside the files listed for this task. Do not move sidebar ownership into the diffable view.

- [ ] **Step 3: Run all new diffable outline tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/DiffableOutlineSnapshotTests -only-testing:PhiBrowserTests/DiffableOutlineDiffPlannerTests -only-testing:PhiBrowserTests/DiffableOutlineViewTests -only-testing:PhiBrowserTests/SidebarDiffableSnapshotTests
```

Expected: PASS.

- [ ] **Step 4: Run nearby sidebar test**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SidebarNewTabStickyResolverTests
```

Expected: PASS.

- [ ] **Step 5: Build for testing**

Run:

```bash
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS'
```

Expected: build succeeds, or a clearly unrelated local test-host/bootstrap issue is documented with the exact failure lines.

- [ ] **Step 6: Final status check**

Run:

```bash
git status --short
```

Expected: only intentional files are modified before the final commit.

- [ ] **Step 7: Commit final polish**

If Task 8 changed files:

```bash
git add Sources/UserInterface/Common/DiffableOutlineSnapshot.swift Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift Sources/UserInterface/Common/DiffableOutlineView.swift Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift Tests/PhiBrowserTests
git commit -m "fix: harden diffable outline update sequencing"
```

If Task 8 only verified existing commits, do not create an empty commit.
