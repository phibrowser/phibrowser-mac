# Sidebar selection and refresh

## Selection ownership

`BrowserState` owns temporary multi-selection. `TabMultiSelection` stores tab IDs
and bookmark GUIDs; ordering comes from authoritative tab/bookmark lists, not
the order of clicks. Selection is separate from the actual focused browser tab.
The focused normal tab can participate implicitly in an action without being a
separate toggled member.

This is a temporary operation set, not a replacement for the browser's active
tab or anchor selection. Selecting another member must not activate it; an empty
set returns to ordinary single-tab interaction. Reusing Chromium selection would
couple batch-action highlighting to different focus/selection semantics. Route
mutations through `BrowserState` intent methods so every native surface shares
one policy and any future bridge integration has one ownership boundary.

The sidebar supports mixed normal-tab and bookmark selection, including folders.
Do not apply the historical tabs-only restriction to current code. Batch actions
and drags must use the owning state's selection helpers: split partners, opened
bookmarks and folder-containing selections need action-specific handling. The
horizontal strip also has range-selection behavior; its tests define that
surface independently of sidebar row interpretation.

Window-local event handlers must not clear another window's selection. Stale
members are removed as authoritative items disappear. Group overview and other
presentation transitions can disable or clear selection through the owner.

## Group rows and refresh ownership

`SidebarTabListViewController` owns the logical tree, row presentation, menu and
drag/drop semantics. Group cells derive their member list from native tab state;
they do not create a second authoritative membership store. Keep model-change
handling distinct from cell reconfiguration so unrelated content updates do not
force structural replacement of the outline.

The outer outline treats a group as one leaf row with a dynamic height. Its
embedded `NSTableView` has no `NSScrollView`, so the outer outline remains the
scroll owner. The inner table identifies the member under the pointer, while
the outer outline/controller starts the grouped-tab drag session. This keeps
hit-testing local without creating competing nested scrolling or drag owners.

## Tab-section refresh boundary

Tab-only updates previously rebuilt the combined outline tree even when its
root rows were unchanged. That work unnecessarily revisited the bookmark tree
and could disturb AppKit's retained row identity. `TabSectionController` now
compares the ordered root item IDs **and object identities**. A matching ID
with a replacement object still needs the structural path; stable IDs alone
are not enough to skip it.

When the root items are unchanged, `SidebarTabListViewController` skips the
whole-tree snapshot and updates the dependent presentation instead: active-tab
and focus selection, visible bookmark tabs, floating new-tab visibility,
affected group members and row heights, affected split-pair cells, cleanup
visibility and a closed floating proxy. Structural root changes still run the
full refresh. Keep these dependent updates in the fast path; skipping the
snapshot must not leave group height, split or bookmark presentation stale.

The reusable `DiffableOutlineView` knows stable IDs, object payloads and tree
mutations, not bookmark business rules. Its snapshot represents the same tree
that the external data source will answer during AppKit callbacks.

## Snapshot invariants

- IDs are unique, parent relationships exist, sibling order is explicit and
  cycles are invalid.
- Stable identity does not imply stable object identity. When an existing ID
  receives a different item object, replace the highest affected node through
  remove/insert. A visual row reload alone does not rebind AppKit's retained
  item identity; ancestor replacement already covers its descendants.
- Validate and plan before switching the data source. Invalid snapshots leave
  the current data source and baseline untouched.
- Update the backing data source before applying structural mutations, so
  AppKit can query inserted nodes and child counts safely.
- First snapshots and unsafe plans use full reload. A safe incremental update
  is an optimization, not a correctness requirement.
- Reentrant reloads are queued while an apply is active. Snapshot reset
  generations prevent an in-progress apply from restoring an obsolete baseline.
- Incremental completion is deferred to the main queue. Full-reload and invalid
  paths can complete immediately; callers must not assume every path is async.

Mutation APIs take parent objects, not IDs. Resolve removal parents from the old
snapshot and insertion parents from the new snapshot. Same-parent moves use the
old parent still recognized by AppKit. If the required identity cannot be used
safely, fall back to a full reload.

Matching old/new replacement indexes is not sufficient: earlier structural
operations can move the live row. For example, changing `[a, proxy, b]` to
`[b, proxy]` keeps `proxy` at index 1 in both snapshots, but removing `a` first
produces `[proxy, b]`; replacing index 1 would affect `b`. The planner replays
structural operations and verifies the affected sibling lists before allowing
replacement. A conflicting sibling move or a failed replay makes the plan
unsafe. Keep this check even when stable IDs and final indexes appear correct.

Avoid redundant publications and repeated tree traversal when the model has not
changed. Optimization must preserve editing, expansion, selection and the
focused bookmark/split presentation, not only reduce the number of operations.

Menu rebuilds must also be idempotent: remove all owned item tags and separators
before re-adding them. A refresh should not accumulate duplicate commands.

## Source and checks

- [Selection value](../../Sources/States/TabMultiSelection.swift)
- [State owner](../../Sources/States/BrowserState.swift)
- [Sidebar controller](../../Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift)
- [Tab-section change detection](../../Sources/UserInterface/Sidebar/TabList/TabSectionController.swift)
- [Group cell](../../Sources/UserInterface/Sidebar/TabList/Views/TabGroupCellView.swift)
- [Snapshot](../../Sources/UserInterface/Common/DiffableOutlineSnapshot.swift),
  [planner](../../Sources/UserInterface/Common/DiffableOutlineDiffPlanner.swift)
  and [view](../../Sources/UserInterface/Common/DiffableOutlineView.swift)
- [Menu construction](../../Sources/Application/AppController+Menu.swift)
- [Replacement and sibling-mutation tests](../../Tests/PhiBrowserTests/DiffableOutlineDiffPlannerTests.swift)

`BrowserStateMultiSelectionTests`, `TabStripMultiSelectionRangeTests` and the
`DiffableOutline*Tests` suites cover model and mutation behavior. Manual acceptance
must additionally exercise editing, mixed drags, folder actions, split rows,
collapse/expansion and focus across windows. See [testing](../testing.md).
