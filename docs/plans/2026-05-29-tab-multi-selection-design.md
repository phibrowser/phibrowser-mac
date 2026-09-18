# Tab Multi-Selection — Design Document

- Date: 2026-05-29
- Branch: `release/1.4.0`
- Status: Approved (brainstorming complete)

## Goal

Add a lightweight multi-selection capability for tabs in both tab UIs:

- Vertical sidebar (`Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`)
- Horizontal tab strip (`Sources/UserInterface/HorizontalBar/TabStrip/TabStrip.swift`)

Users hold Cmd and click multiple tabs to build a temporary selection, then run
batch operations from a unified right-click menu (and Cmd+W for batch close).
Multi-selection is a **temporary visual state** that does **not** change the real
focused tab (`BrowserState.focusingTab`).

## Non-Goals

- Do **not** adopt Chromium's native `TabStripModel` selection model as the source
  of truth (see "Chromium Evaluation"). No bridge changes in this iteration.
- Do **not** support Shift+Click range selection (Cmd toggle only).
- Pinned tabs and bookmark tabs do **not** participate in multi-selection.
- Do **not** add batch Pin/Unpin or "Move to New Window".
- Do **not** persist multi-selection across sessions / window restore.

## Chromium Evaluation (why Mac-side, not Chromium reuse)

Chromium's `TabStripModel` already has a complete, authoritative multi-selection
model (`TabStripModelSelectionState` + `ListSelectionModel`: active / anchor /
selected_indices), deeply integrated with Cmd+W (`CloseSelectedTabs`), context
menu commands (`GetIndicesForCommand`), drag, split, group, session.

However, Phi's bridge currently syncs **only the active tab**
(`tabs_proxy::OnTabStripModelChanged` ignores `selection_changed()`); there is no
selection plumbing in either direction.

Reusing the Chromium model was rejected because the desired UX **diverges
fundamentally** from Chromium's native semantics:

| Requirement | Chromium native behavior | Conflict |
|---|---|---|
| Multi-select is temporary; must **not** change `focusingTab` | Active tab is always part of selection; Cmd+click switches the foreground active tab | Direct conflict |
| Pinned/bookmark tabs excluded | Pinned tabs can be multi-selected; Phi's pinned/bookmark are normal Chromium tabs tagged via `custom_value` / local DB | Would require Mac-side re-filtering anyway |
| Empty set = normal mode | Non-empty selection forces active+anchor in the set; cannot deselect the last tab | State-machine mismatch |

Other costs: `normalTabs` is a derived list (excludes pinned / opened bookmarks),
so Mac↔Chromium strip index mapping is indirect; bidirectional bridge sync plus
re-entrancy/loop prevention is non-trivial. The only concrete gain (native Cmd+W
batch close) is already achievable Mac-side.

**Conclusion:** Mac-side `BrowserState` owns the selection. A future Chromium
integration is kept cheap by an architectural seam (below), not by a speculative
protocol.

## Approved Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Selection state owned by `BrowserState` (window-scoped), single source of truth | Aligns with `focusingTab` ownership; shared by both layouts; AGENTS "BrowserState owns tab state" |
| 2 | `multiSelection.isActive` (non-empty) is the **only** signal for "multi-select mode" — no second flag | Solves the "hard to distinguish normal vs multi" risk |
| 3 | Cmd+click toggles membership (add if absent, remove if present) | Standard macOS behavior |
| 4 | The active tab (`focusingTab`) is **always implicitly** part of the operation set | Batch target = `multiSelection.guids ∪ {focusingTab.guid}` |
| 5 | Cmd+click on the active tab = no-op (cannot be deselected) | Active is always implicit |
| 6 | Membership stored as `Set<Int>`; **order derived from `normalTabs`** at action time | Tab relative order is correct regardless of click order; no parallel order to keep in sync |
| 7 | Cmd+click on pinned/bookmark = exit multi-select **and** activate it (normal click) | User-confirmed |
| 8 | All selection mutations go through `BrowserState` intent methods; consumers never mutate the set directly | This is the Chromium seam — intent methods can later delegate to the bridge |
| 9 | Sub-selection rendered with a **dedicated color** (slightly darker than the near-white selected color), distinct from hover | User must be able to see selection being toggled off |
| 10 | Batch ops scope: Close, Add to Bookmarks (existing/new folder), Copy Links, Duplicate, Create/Add Tab Group | User-confirmed |
| 11 | Cmd+W closes the multi-selection when active (intercepted Mac-side before Chromium `executeCommand`) | User-confirmed |
| 12 | Unified context-menu entry shared by both layouts | Requirements 1 & 7 |

## Exit Triggers (back to normal mode)

All converge to `clearMultiSelection()`:

- Plain click (no modifier) on any tab
- Cmd+click on a pinned/bookmark tab
- After any batch operation completes
- Set becomes empty (Cmd toggling off the last extra tab)
- Layout mode switch

(Esc and empty-area click are intentionally **not** exit triggers in this iteration.)

## Architecture

### Ownership + intent/state separation (the Chromium seam)

```
Consumers (Sidebar / TabStrip / Cmd+W)
   │  intent: toggleMultiSelection / clearMultiSelection / closeMultiSelectedTabs ...
   ▼
BrowserState (single owner)
   │  @Published private(set) var multiSelection: TabMultiSelection
   ▼
Mutation implementation
   - now:    update Set directly
   - future: call bridge → Chromium → observer callback updates Set   ← seam
```

This mirrors the existing `focusingTab` flow (Mac emits intent; on active-tab
close it routes through Chromium and `handleChromiumActiveTabChanged` updates
state). No new architectural pattern is introduced.

### State type

```swift
struct TabMultiSelection: Equatable {
    private(set) var guids: Set<Int>
    static let empty = TabMultiSelection(guids: [])
    var isActive: Bool { !guids.isEmpty }
    func contains(_ guid: Int) -> Bool { guids.contains(guid) }
}
```

### BrowserState surface

```swift
@Published private(set) var multiSelection: TabMultiSelection = .empty

// Intent (consumers call these; never mutate the set directly)
func toggleMultiSelection(for tab: Tab)
func clearMultiSelection()

// Order is always derived from the authoritative tab list
var orderedMultiSelectedTabs: [Tab] {
    let target = multiSelection.guids.union([focusingTab?.guid].compactMap { $0 })
    return normalTabs.filter { target.contains($0.guid) }
}

// Batch actions (operate on the current selection, source-agnostic)
func closeMultiSelectedTabs()
func bookmarkMultiSelectedTabs(into folder: BookmarkFolderRef?)
func duplicateMultiSelectedTabs()
func copyLinksOfMultiSelectedTabs()
func groupMultiSelectedTabs()                 // create new group
func addMultiSelectedTabs(toGroup token: String)  // add to existing group
```

### `toggleMultiSelection(for:)` rules (owner decides; UI does not branch on pinned/bookmark)

1. tab is pinned/bookmark → `clearMultiSelection()` + activate it normally.
2. tab.guid == focusingTab.guid → no-op.
3. guid already in set → remove (empty ⇒ normal mode).
4. guid not in set → add.

## State Machine

```
         ┌───────────────────────────────────────┐
         │  Normal mode  (multiSelection.isEmpty)  │
         └───────────────────────────────────────┘
            │                                ▲
 Cmd+click  │                                │ plain click any tab
 normal tab │                                │ / Cmd+click pinned|bookmark
 B (B≠active)│                               │ / after batch op
 → set={B}  │                                │ / layout switch
            ▼                                │
         ┌───────────────────────────────────────┐
         │  Multi-select  (multiSelection.isActive)│
         │  Cmd+click tab X:                       │
         │   · X in set    → remove (empty ⇒ exit) │
         │   · X not in set→ add                    │
         │   · X == active → no-op                  │
         └───────────────────────────────────────┘
```

### Click decision table (unified across both layouts)

| Click target | Modifier | Behavior |
|---|---|---|
| normal tab | none | exit multi-select + activate it |
| normal tab (≠active) | Cmd | toggle membership |
| active tab | Cmd | no-op |
| pinned/bookmark | Cmd | exit multi-select + activate it |
| pinned/bookmark | none | unchanged (normal activate) |

## Click Interception

UI reads `NSEvent.modifierFlags` at the click site and only emits intents.

### Vertical sidebar (`NSOutlineView`)

`outlineViewClicked(_:)` already accesses `NSApp.currentEvent` (for `clickCount`):

```swift
let isCmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
if let tab = item as? Tab, isCmd {
    browserState.toggleMultiSelection(for: tab)
    return
}
if browserState.multiSelection.isActive { browserState.clearMultiSelection() }
itemClicked(item)
```

Grouped-tab clicks go through `TabGroupCellView.innerTableClicked`; apply the
same "read Cmd → emit intent" split there.

Bookmark rows are `Bookmark`, not `Tab`: a Cmd+click there emits
`clearMultiSelection()` then proceeds with normal activation.

### Horizontal tab strip (`TabItemView`)

`onSelect` becomes `((NSEvent.ModifierFlags) -> Void)?`, fired from `mouseUp`
with `event.modifierFlags`:

```swift
view.onSelect = { [weak self] flags in
    guard let self, let tab = renderData.sourceTab else { return }
    if flags.contains(.command) {
        self.browserState.toggleMultiSelection(for: tab)
    } else {
        if self.browserState.multiSelection.isActive { self.browserState.clearMultiSelection() }
        self.handleTabSelection(tab: tab)
    }
}
```

Pinned tabs in `pinnedContainer` route the same way; the owner recognizes pinned
and exits + activates.

## Unified Context Menu

```swift
enum TabMultiSelectionMenu {
    @MainActor
    static func populateIfNeeded(_ menu: NSMenu, clickedTab: Tab, in state: BrowserState) -> Bool {
        guard state.multiSelection.isActive,
              state.multiSelection.contains(clickedTab.guid) || clickedTab.guid == state.focusingTab?.guid
        else { return false }
        // Close, Add to Bookmarks (existing/new folder), Copy Links, Duplicate, Create/Add Tab Group
        return true
    }
}
```

- Sidebar `menuNeedsUpdate`: call `populateIfNeeded` before `item.makeContextMenu(on:)`; return early if it handled the menu.
- TabStrip `TabItemView.menu(for:)`: same — fall back to existing single-tab `makeContextMenu` otherwise.
- Right-clicking a tab **not** in the set while multi-select is active → returns false → single-tab menu (selection preserved), matching macOS conventions.

## Batch Actions

All operate on `orderedMultiSelectedTabs` and call `clearMultiSelection()` when done.

| Menu item | Implementation | Notes |
|---|---|---|
| Close | loop `tab.close()` in order | reuses existing single-close path |
| Add to Bookmarks | reuse existing bookmark write | inserted in `orderedMultiSelectedTabs` order |
| Copy Links | join URLs in order → pasteboard | |
| Duplicate | reuse existing `duplicateTab` loop | |
| Create Tab Group | `createGroupFromTabs(ordered guids)` | already-grouped tabs are moved into the new group by Chromium (standard) |
| Add to existing Group X | filter out tabs already in X, then `addTabsToGroup` | dedup by `tab.groupToken` |

### Tab Group membership dedup

Selection may span in-group + out-of-group + different-group tabs.
`Tab.groupToken` lets us decide membership Mac-side:

```swift
func addMultiSelectedTabs(toGroup token: String) {
    let targets = orderedMultiSelectedTabs.filter { $0.groupToken != token }
    guard !targets.isEmpty else { clearMultiSelection(); return }
    bridge.addTabsToGroup(targets.map(\.guid), token: token, windowId: windowId)
    clearMultiSelection()
}
```

(Pinned/bookmark are already excluded from the selection, so group targets are
always normal tabs.)

## Cmd+W Interception

Today Cmd+W → Chromium `executeCommand(IDC_CLOSE_TAB)` closes only the active tab
(Chromium selection is always single). To batch-close the Mac selection, intercept
at the Mac command entry point before it reaches Chromium:

```swift
func closeCurrentTabCommand() {
    if browserState.multiSelection.isActive {
        browserState.closeMultiSelectedTabs()   // clears selection internally
        return
    }
    // existing single-tab close path
}
```

Implementation note: locate the exact Cmd+W entry (NSMenuItem action vs
`performKeyEquivalent`) during the implementation plan; the design is to insert
the multi-select check before the Chromium `executeCommand`.

## Rendering

Visual priority (both layouts): `selected (near-white) > sub-selection (slightly
darker) > hover > normal (clear)`. The active tab always wins, so sub-selection
never overrides the focused tab's highlight.

### New colors (light + dark variants required)

- Sidebar: new asset `sidebarTabSubSelected` — darker than `sidebarTabSelected`, clearly distinct from `sidebarTabHovered`.
- Tab strip: new `ThemedColor` case `tabSubSelected` — darker than the active `contentOverlayBackground`.

### Vertical sidebar

```swift
private var backgroundColor: Color {
    if model.isActive { return Color(nsColor: NSColor(resource: .sidebarTabSelected)) }
    if model.isMultiSelected { return Color(nsColor: NSColor(resource: .sidebarTabSubSelected)) }
    if model.isHovered { return Color(nsColor: NSColor(resource: .sidebarTabHovered)) }
    return .clear
}
```

`TabViewModel` gains `@Published var isMultiSelected` (subscribes to
`browserState.$multiSelection`, value = `contains(guid) && !isActive`, reusing the
`configuredTabGuid` guard against cell reuse). `isMultiSelected` and `isHovered`
stay independent so a hovered sub-selected tab keeps a stable color.

### Horizontal tab strip

`TabBackgroundLayer` gains a `.subSelected` state that uses the **normal rounded
path** (not the active reverse-rounded outline) with the sub-selection fill:

```swift
switch tabState {
case .active:      fillColor = ThemedColor.contentOverlayBackground.resolve(...).cgColor
case .subSelected: fillColor = ThemedColor.tabSubSelected.resolve(...).cgColor
case .hovered:     fillColor = ThemedColor.hover.resolve(...).cgColor
case .inactive:    fillColor = NSColor.clear.cgColor
}
```

```swift
// TabItemView.updateAppearance
switch (isActive, isMultiSelected, isHovered || isDragHighlighted) {
case (true, _, _):         backgroundLayer.tabState = .active
case (false, true, _):     backgroundLayer.tabState = .subSelected
case (false, false, true): backgroundLayer.tabState = .hovered
default:                    backgroundLayer.tabState = .inactive
}
```

`TabRenderData` gains `isMultiSelected`, written in `rebindData`. `$multiSelection`
is added to the existing `combineLatest($pinnedTabs, $normalTabs, $focusingTab)`
so selection changes re-render immediately.

## Files Touched (anticipated)

- `Sources/States/BrowserState.swift` — `multiSelection`, intent methods, batch actions, `orderedMultiSelectedTabs`, exit-on-layout-switch.
- New `TabMultiSelection` value type (state layer).
- New `TabMultiSelectionMenu` (unified menu builder).
- `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift` — click split, `menuNeedsUpdate` hook.
- `Sources/UserInterface/Sidebar/TabList/Views/TabGroupCellView.swift` — grouped-tab click split.
- `Sources/UserInterface/Sidebar/TabList/Views/SideTabView.swift` — sub-selection color.
- `Sources/UserInterface/Common/Tabs/TabViewModel.swift` — `isMultiSelected`.
- `Sources/UserInterface/HorizontalBar/TabStrip/TabStrip.swift` — `onSelect` flags, `$multiSelection` binding, render data.
- `Sources/UserInterface/HorizontalBar/TabStrip/Views/TabItemView.swift` — `onSelect` signature, `menu(for:)` hook, `isMultiSelected`.
- `Sources/UserInterface/HorizontalBar/TabStrip/Views/TabBackgroundLayer.swift` — `.subSelected` state.
- `Sources/UserInterface/HorizontalBar/TabStrip/Core/TabStripState.swift` — `TabRenderData.isMultiSelected`.
- `SpaceSessionController` (Cmd+W entry) — multi-select close interception.
- Asset catalog — `sidebarTabSubSelected`; `ThemedColor.tabSubSelected`.

## Risks / Notes

- Cell reuse: keep the `configuredTabGuid` guard when wiring `isMultiSelected` to avoid cross-binding.
- Tab removal while selected: `closeMultiSelectedTabs` snapshots `orderedMultiSelectedTabs` before closing; selection is cleared afterward.
- Layout switch must clear selection (it is an exit trigger) to avoid a stale set carrying across UIs.
- Keep UI layers thin: no pinned/bookmark branching in click handlers — the owner decides.
