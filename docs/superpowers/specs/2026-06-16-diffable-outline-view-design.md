# Diffable Outline View Design

## Context

`SidebarTabListViewController` currently has two refresh paths for the sidebar outline view:

- Normal tab changes can be applied incrementally with root-level `insertItems`, `removeItems`, and `moveItem`.
- Bookmark changes rebuild `allItems` and call `reloadData()`, which churns visible bookmark cells and can interrupt interaction state such as inline editing, hover state, selection, and focus presentation.

The sidebar is too complex to migrate directly to a standard diffable data source. Cell creation, selection, drag and drop, context menus, expansion behavior, focused bookmark proxy presentation, and visible bookmark bookkeeping should remain owned by the existing controller and delegate/data source methods.

This design adds a reusable `DiffableOutlineView` that applies tree snapshots with minimal structural mutations while leaving business behavior in the current owner.

## Goals

- Add a reusable `DiffableOutlineView: NSOutlineView` that can apply tree snapshots with incremental outline mutations.
- Keep `NSOutlineViewDataSource` and `NSOutlineViewDelegate` ownership external.
- Use stable item IDs for diff identity so reconstructed model objects do not become delete/insert churn.
- Use Swift `CollectionDifference` for sibling-list diffing instead of hand-writing a generic diff algorithm.
- Prefer stability over animation completeness. Same-parent reorders can use `moveItem`; cross-parent moves use remove plus insert in the first version.
- Provide strict tests for snapshot validation, tree-aware planning, and AppKit mutation ordering.

## Non-Goals

- Do not replace `SidebarTabListViewController` with `NSDiffableDataSource`.
- Do not move sidebar cell creation, drag/drop, context menu, click handling, or bookmark business rules into the diffable view.
- Do not implement a custom LCS or generic collection diff algorithm.
- Do not try to animate every possible tree transformation in the first version.
- Do not change bookmark storage, tab ordering, or sidebar interaction semantics.

## Public API

The first version should expose a narrow API:

```swift
class DiffableOutlineView<ItemID: Hashable>: NSOutlineView {
    func reloadWith(
        _ snapshot: DiffableOutlineSnapshot<ItemID>,
        animated: Bool = true,
        updateDataSource: () -> Void,
        completion: (() -> Void)? = nil
    )
}
```

`SideBarOutlineView` should inherit from this class and keep its existing sidebar-specific behavior:

```swift
class SideBarOutlineView: DiffableOutlineView<AnyHashable> {
    // Existing sizing, indentation, mouse, and drag forwarding behavior stays here.
}
```

If AppKit generic subclassing creates build friction, the implementation may keep the snapshot and planner generic while making the concrete view store `AnyHashable`. The external shape should still be a `DiffableOutlineView: NSOutlineView` with a stable-ID snapshot API.

## Snapshot Model

The snapshot describes the tree the outline view should display. It stores stable IDs for diffing and object payloads for AppKit parent/item calls.

```swift
struct DiffableOutlineSnapshot<ItemID: Hashable> {
    struct Node {
        let id: ItemID
        let item: AnyObject
        let parentID: ItemID?
        let childIDs: [ItemID]
    }

    let rootIDs: [ItemID]
}
```

Required behavior:

- Every ID appears once.
- Every non-root parent ID exists.
- Root IDs and child IDs preserve visual sibling order.
- A child can have only one parent.
- Cycles are invalid.
- The same stable ID can point at a different object instance in a later snapshot.
- Snapshot lookup must provide `item(for:)`, `parentID(of:)`, `childIDs(of:)`, `index(of:)`, and subtree traversal helpers.

The snapshot does not create cells and does not answer `NSOutlineViewDataSource` methods. The existing external data source remains authoritative during normal outline view queries.

## Diff Planning

Diff planning is a pure Swift layer that converts an old snapshot and a new snapshot into outline operations. It must use `CollectionDifference` for sibling-level changes:

```swift
let difference = newChildIDs.difference(from: oldChildIDs).inferringMoves()
```

The planner wraps `CollectionDifference` with tree semantics:

- For each parent, compare only direct child ID arrays.
- Same-parent associated remove/insert changes become a `move` operation.
- Cross-parent movement of the same ID becomes `remove` from the old parent plus `insert` into the new parent.
- Deleting a subtree emits only the highest removed node; descendants are removed by AppKit as part of that subtree.
- Inserting a subtree emits only the highest inserted node; descendants are supplied by the updated data source.
- Replaced payload objects for an existing ID produce a local identity replacement unless an ancestor is already being removed or inserted. `NSOutlineView` tracks concrete item objects internally, so a stable ID alone is not enough to make an unchanged row point at a reconstructed model object.

The operation model should be explicit:

```swift
enum DiffableOutlineOperation<ItemID: Hashable> {
    case remove(id: ItemID, parentID: ItemID?, index: Int)
    case move(id: ItemID, parentID: ItemID?, from: Int, to: Int)
    case insert(id: ItemID, parentID: ItemID?, index: Int)
    case replace(id: ItemID, parentID: ItemID?, index: Int)
    case reload(id: ItemID)
}
```

Operation order must be deterministic:

1. Remove operations, deepest first, higher indexes before lower indexes within the same parent.
2. Same-parent move operations.
3. Insert operations, shallowest first, lower indexes before higher indexes within the same parent.
4. Replace operations for visible existing IDs whose payload object changed and whose ancestors are not already structurally replaced.
5. Reload operations for existing IDs explicitly marked for visual reconfiguration without identity replacement.

If snapshot validation fails, `DiffableOutlineView` must not call `updateDataSource()` and must not mutate the outline view. If both snapshots are valid but the planner cannot produce a safe operation sequence, `DiffableOutlineView` must fall back to `updateDataSource()` plus `reloadData()`.

## Apply Timing

`reloadWith(snapshot:updateDataSource:completion:)` must use this timing:

1. Assert or dispatch to the main thread.
2. Read the current snapshot stored by `DiffableOutlineView`.
3. Validate the new snapshot.
4. Build a plan from old snapshot to new snapshot.
5. If validation fails, leave the current snapshot and backing data source untouched, then call completion.
6. If this is the first valid snapshot, call `updateDataSource()`, `reloadData()`, store the new snapshot, then call completion.
7. If the plan is unsafe, call `updateDataSource()`, `reloadData()`, store the new snapshot, then call completion.
8. For a safe plan, call `updateDataSource()` before any outline mutation.
9. Call `beginUpdates()`.
10. Apply remove, move, insert, replace, and reload operations.
11. Call `endUpdates()`.
12. Store the new snapshot.
13. Run completion on the next main run loop so selection, scrolling, and visible-item bookkeeping happen after AppKit has processed the structural update.

The key rule is that the external backing data source switches to the new tree after diff planning but before `NSOutlineView` structural mutations. Remove indexes come from the old snapshot. Insert indexes come from the new snapshot. During the mutation window, AppKit can query the data source for inserted nodes and child counts, so delaying the backing update until after animation would be unsafe.

## AppKit Parent Objects

`NSOutlineView` mutation APIs take parent objects, not IDs. The planner should store parent IDs, and `DiffableOutlineView` should resolve them to parent objects at apply time:

- Remove parent objects come from the old snapshot.
- Insert parent objects come from the new snapshot.
- Same-parent moves can use the old parent object when the parent object is still recognized by the outline view.
- If the needed parent object cannot be resolved safely, fall back to `reloadData()`.

The first sidebar integration should prefer stable parent objects where possible. Reconstructed bookmark objects are valid only when the plan includes local replacements for the highest changed objects, because unchanged rows otherwise remain associated with the old objects inside `NSOutlineView`.

## Sidebar Integration

`SidebarTabListViewController` should keep ownership of:

- `allItems`
- `focusedBookmarkPresentation`
- `dataSourceChildren(of:)`
- cell creation
- row view creation
- drag/drop validation and acceptance
- expansion/collapse behavior
- context menus
- selection and scroll bookkeeping

The controller should add a helper that builds a snapshot from the same logical tree used by `dataSourceChildren(of:)`. The snapshot must include:

- root bookmark items
- separator item when present
- new tab button and normal tabs
- visible bookmark descendants according to the model tree
- the focused bookmark proxy when present

Bookmark update handling should move from full `refreshAllItems()` reload to:

```swift
let newItems = makeAllItems()
let snapshot = makeSnapshot(from: newItems, focusedPresentation: plannedPresentation)
outlineView.reloadWith(snapshot, animated: true) {
    self.allItems = newItems
    self.focusedBookmarkPresentation = plannedPresentation
} completion: {
    self.selectActiveTab()
    self.applyFocusingSelection(for: self.browserState.focusingTab)
    self.updateVisibleBookmarkTabs()
    self.updateFloatingNewTabVisibility()
}
```

Exact helper names can follow the surrounding code during implementation. The important ownership boundary is that `DiffableOutlineView` does not know about bookmarks or tabs.

Existing hand-written tab incremental updates can remain initially. After the diffable reload path is proven for bookmarks, tab updates can be routed through the same snapshot method if doing so reduces duplication without changing behavior.

## Safety Rules

The implementation must prioritize crash resistance:

- All public apply work runs on the main thread.
- Invalid snapshots do not update the external backing data source and do not partially mutate the outline view.
- Duplicate IDs fail validation before mutation.
- Parent-child cycles fail validation before mutation.
- Mutations are wrapped in a single `beginUpdates()` / `endUpdates()` pair.
- No nested `reloadWith` should run while another apply is active; a reentrant call should queue the latest snapshot or fall back to reload after the current apply finishes.
- The first version should not animate cross-parent moves as `moveItem`.
- Existing IDs whose item objects changed should be locally replaced at the highest affected node, not merely reloaded by row.
- If an item involved in a structural operation is expanded or collapsed mid-apply, the apply should avoid extra expansion mutations and let the existing delegate behavior own expansion state.
- Fallback reload is acceptable when preserving safety is more important than animation.

## Testing Strategy

Development must use TDD. New production behavior requires a failing test first.

### Snapshot Validation Tests

Cover:

- empty snapshot
- root-only snapshot
- nested tree lookup
- duplicate IDs rejected
- missing parent rejected
- duplicate child ownership rejected
- cycles rejected
- payload object replacement for the same ID is allowed

### Planner Tests

Cover:

- root insert
- root delete
- child insert
- child delete
- same-parent reorder produces `move`
- cross-parent move produces `remove` plus `insert`
- subtree insert emits only the inserted subtree root
- subtree delete emits only the deleted subtree root
- object identity replacement emits only the highest replaced node
- mixed remove/move/insert operations have deterministic order
- explicit reload markers produce reload after structural operations
- invalid snapshot fails validation before planning

### View Apply Tests

Use a test double subclass that records calls to `reloadData`, `beginUpdates`, `endUpdates`, `insertItems`, `removeItems`, `moveItem`, and row reload/reconfigure calls. The tests should verify:

- first snapshot calls `updateDataSource` before `reloadData`
- normal update calls `updateDataSource` before structural mutations
- remove uses old parent and old index
- insert uses new parent and new index
- same-parent reorder calls `moveItem`
- cross-parent move calls remove and insert
- object identity replacement calls remove and insert at the same parent/index
- invalid snapshot does not call `updateDataSource`
- unsafe valid plan falls back to `reloadData`
- completion runs after apply

A lightweight real `NSOutlineView` smoke test can be added if it is stable in the local test environment, but the required coverage is the planner and recorded mutation sequence.

## Acceptance Criteria

- `DiffableOutlineView` exists as an `NSOutlineView` subclass.
- `SideBarOutlineView` can inherit from it without losing existing sidebar behavior.
- A caller can apply a new snapshot with `reloadWith`.
- Existing data source and delegate methods remain external and unchanged in responsibility.
- Bookmark updates can use the new method without full `reloadData()` when the diff plan is safe.
- Unsafe tree changes fall back to full reload instead of attempting risky partial mutations.
- Tests cover snapshot validation, planner behavior, and mutation ordering before production code is written.
