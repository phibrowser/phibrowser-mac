# Native Tab Order & Selection — Technical Guide

> For Mac-side engineers working on Phi tab management.

## 1. Background

Phi maintains its own **visible tab order** (`normalTabOrder`) independently from Chromium's internal `TabStripModel` index. This creates a fundamental architectural split:

| Aspect | Authority |
|--------|-----------|
| WebContents lifecycle | Chromium |
| `TabStripModel` index | Chromium |
| Visible tab order (sidebar / tab strip) | **Mac** |
| Opener relationship source-of-truth | Chromium (snapshots) |
| New tab insertion position | **Mac** |
| Active tab after close | **Mac** (overrides Chromium) |
| Active tab for all other scenarios | Chromium (Mac accepts) |

The core challenge: when the user reorders tabs via drag-and-drop in the native UI, Chromium knows nothing about the change. Its own close-selection algorithm (`DetermineNewSelectedIndex`) still operates on the old strip order, producing results that conflict with the user's visual expectation.

## 2. Architecture Overview

```
┌────────────────────────────────────────────────────────────────┐
│                       Mac-native (Swift)                       │
│                                                                │
│  normalTabOrder      NativeTabDecisionEngine   selectionTarget │
│  NativeTabRelationGraph   locallyFixedOpenerTabIds             │
│  pendingSelectionOverride                                      │
├────────────────── Bridge (OC/Swift) ──────────────────────────┤
│  NativeTabCreationContext    NativeTabRelationshipSnapshot     │
│  activeTabChanged            tabWillBeRemove                  │
├────────────────────────────────────────────────────────────────┤
│                       Chromium (C++)                           │
│  TabStripModel    FixOpeners    ForgetAllOpeners               │
│  DetermineInsertionIndex    DetermineNewSelectedIndex          │
└────────────────────────────────────────────────────────────────┘
```

### Key Files

| File | Purpose |
|------|---------|
| `NativeTabDecisionEngine.swift` | Data models, insertion/selection algorithms, opener graph |
| `BrowserState.swift` | Integration point: new tab insertion, close handling, drag fix, snapshot merge |
| `PhiChromiumCoordinator.swift` | Parses `NativeTabCreationContext` and `NativeTabRelationshipSnapshot` from bridge callbacks |
| `PhiChromiumBridgeHeader.h` | Bridge protocol: snapshot callback, `createQuickLookupTab` |
| `EventBus.swift` | Events: `.newTabWithContext`, `.updateTabRelationships` |
| `Tab.swift` | `close()` calls `prepareForActiveTabClose` before sending `IDC_CLOSE_TAB` |
| `MainBrowserWindowController+Actions.swift` | Cmd+T routed to `createQuickLookupTab` |

## 3. Chromium-Side Modifications

### 3.1 `NativeTabCreationContext` (via bridge)

When Chromium creates a new tab, `buildCreationContextForWebContents` in `tabs_proxy` constructs a dictionary carrying:

| Field | Type | Description |
|-------|------|-------------|
| `isActiveAtCreation` | Bool | Whether the new tab is foreground |
| `creationKind` | String | `linkForeground`, `linkBackground`, `typedNewTab`, `typedNavigation`, `restore`, etc. |
| `openerTabId` | Int? | The opener tab's custom guid |
| `insertAfterTabId` | Int? | Chromium's insertion anchor (for fallback) |
| `sourceTabId` | Int? | The source tab that initiated the creation |
| `resetOpenerOnActiveTabChange` | Bool | Whether this tab's opener should clear when the user switches away |
| `didForgetAllOpenersBeforeCreate` | Bool | Whether `ForgetAllOpeners` was called during this creation |

The `creationKind` classification logic checks `resetOpenerOnActiveTabChange` to distinguish `typedNewTab` (Cmd+T) from `linkForeground`.

### 3.2 `NativeTabRelationshipSnapshot` (via bridge)

Chromium periodically pushes the full opener graph via `tabRelationshipSnapshotChanged`. The snapshot contains:

| Field | Type | Description |
|-------|------|-------------|
| `windowId` | Int | Target window |
| `version` | Int64 | Monotonically increasing version for ordering |
| `openerByTabId` | `[Int: Int?]` | Full opener mapping (tabId → openerTabId or null) |
| `tabsWithExplicitNilOpener` | `Set<Int>` | Tabs whose opener was explicitly cleared (e.g. `ForgetAllOpeners`) |
| `resetOnActiveChangeTabIds` | `Set<Int>` | Tabs with `reset_opener_on_active_tab_change` flag |

### 3.3 `createQuickLookupTab`

Cmd+T now routes through `createQuickLookupTab(windowId:)` → `chrome::NewTab(kNewTabCommand)` instead of the generic `createTab("chrome://newtab")`. This ensures Chromium applies its typed-new-tab semantics (inheriting opener, setting `reset_opener_on_active_tab_change`).

## 4. Mac-Side Implementation

### 4.1 Data Models

#### `NativeTabCreationKind`

Enum classifying how a tab was created:

```
linkForeground | linkBackground | typedNewTab | typedNavigation
explicitInsert | moveFromOtherWindow | restore | bridgeCreate | unknown
```

#### `NativeTabRelationGraph`

The Mac-side opener relationship graph. Key fields:

- `openerByTabId: [Int: Int]` — the opener map
- `locallyFixedOpenerTabIds: Set<Int>` — tabs whose opener was re-parented by a Mac-only operation (drag reorder, pin, bookmark); protected from snapshot overwrites
- `resetOnActiveChangeTabIds: Set<Int>` — mirrors Chromium's `reset_opener_on_active_tab_change` flag
- `version: Int64` — tracks the latest snapshot version

#### `NativePendingSelectionOverride`

Stores the Mac-side computed selection target before a close operation:

- `closingTabId` — the tab about to close
- `targetTabId` — the Mac-computed next selection
- `relationVersion` — snapshot version at computation time

### 4.2 New Tab Insertion

`NativeTabDecisionEngine.insertionIndex(visibleNormalTabIds:context:relationGraph:)` computes the insertion position:

| `creationKind` | Logic |
|----------------|-------|
| `linkForeground` | Right after opener in visible order; fallback to `insertAfterTabId` |
| `linkBackground` | After the opener's last visible descendant; fallback to `insertAfterTabId` |
| `typedNewTab` / `typedNavigation` | Append to end |
| `explicitInsert` / `restore` / others | Use `insertAfterTabId` if present; otherwise nil (caller appends) |

Integration in `BrowserState.handleNewTabFromChromium`:

1. Parse `NativeTabCreationContext` from bridge payload
2. Optimistically update `nativeRelationGraph` via `applyOptimisticCreation`
3. If `didForgetAllOpenersBeforeCreate`, clear all openers in the graph
4. Call `insertionIndex` to get the position
5. Insert into `normalTabOrder` at the computed index

### 4.3 Close Selection Override

When the active normal tab is closed, the Mac side pre-computes the next selection target **before** the opener graph is modified.

**Selection priority** (`NativeTabDecisionEngine.selectionTarget`):

1. **Child** — a tab whose opener is the closing tab (right-first)
2. **Sibling** — a tab sharing the same opener (right-first)
3. **Opener** — the closing tab's opener itself
4. **Right neighbor** — next tab in visible order
5. **Left neighbor** — previous tab in visible order

**Flow**:

1. `prepareForActiveTabClose(tabId:)` is called. It invokes `selectionTarget` and stores the result as `pendingSelectionOverride`.
2. Chromium performs the actual close and sends `activeTabChanged`.
3. `handleChromiumActiveTabChanged` checks `pendingSelectionOverride`:
   - If `closingTabStillExists` in `tabs` → discard (stale override from unrelated focus change)
   - If `targetTabId == tabId` → override matches, accept
   - If target tab exists → call `setAsActiveTab()` to override Chromium
   - Otherwise → fall through to Chromium's choice

**Dual-path guarantee**: `prepareForActiveTabClose` is called in both:
- `Tab.close()` (Mac UI initiated) — before `IDC_CLOSE_TAB`
- `BrowserState.closeTab()` (Chromium initiated) — at method start

The call is idempotent; double invocation is harmless.

### 4.4 Opener Graph Maintenance

#### Snapshot merge (`NativeTabRelationGraph.apply(snapshot:)`)

| Condition | Behavior |
|-----------|----------|
| Tab in `locallyFixedOpenerTabIds` + snapshot has non-nil opener | **Keep local value** (Mac-side fix protected) |
| Tab in `locallyFixedOpenerTabIds` + snapshot has explicit nil | **Accept nil** and remove from `locallyFixedOpenerTabIds` |
| Tab not locally fixed + snapshot has non-nil opener | **Accept Chromium value** |
| Snapshot has explicit nil | **Clear opener** |
| No info in snapshot + local value exists | **Keep local value** |

#### `fixOpenersAfterMovingTab`

Re-parents children of a moved/closed tab to the tab's own opener (grandparent inheritance). This mirrors Chromium's `FixOpeners()` semantics.

The method is a **pure graph operation** — it does not modify `locallyFixedOpenerTabIds`. Callers decide whether to protect the fix:

| Call site | After fix: add children to `locallyFixedOpenerTabIds`? | Reason |
|-----------|-------------------------------------------------------|--------|
| `moveNormalTabLocally` (drag reorder) | **Yes** | Chromium unaware of the move; protect from snapshot |
| `closeTab` | **Yes** | Protect prior drag fixes from being reverted by stale snapshots |
| `moveNormalTab(toPinnd:)` | **Yes** | Chromium unaware of Phi's pin operation |
| `moveNormalTab(toBookmark:)` | **Yes** | Chromium unaware of Phi's bookmark operation |

#### `forgetOpenerOnActiveTabChange`

When the active tab changes, if the previously active tab has `resetOnActiveChangeTabIds`, its opener is cleared. This mirrors Chromium's `reset_opener_on_active_tab_change` behavior (used for Cmd+T NTP tabs).

#### `removeTab`

Cleans up all graph state for a removed tab: `knownTabIds`, `openerByTabId`, `resetOnActiveChangeTabIds`, `locallyFixedOpenerTabIds`.

### 4.5 Drag Reorder Handling

When a tab is drag-reordered in the native UI (`moveNormalTabLocally`):

1. Capture `directChildren(of: movedTabId)` **before** the fix
2. Call `fixOpenersAfterMovingTab(movedTabId)` — re-parents children to moved tab's opener
3. Add affected children to `locallyFixedOpenerTabIds`
4. Reorder `normalTabOrder` — this is purely a Mac-side operation; Chromium is not notified

This ensures that subsequent Chromium snapshots (which still contain the pre-drag opener relationships) will not overwrite the Mac-side corrections.

## 5. Chromium Opener Change Scenarios

Understanding when Chromium modifies opener relationships is critical for debugging.

### 5.1 `ForgetAllOpeners` — clears ALL openers in the strip

Triggered by:
- **Foreground tab creation with `ADD_INHERIT_OPENER`**: link-open foreground, Cmd+T, `AppendWebContents(foreground=true)`
- **Non-link navigation**: user types URL in address bar, clicks bookmark, etc. (NTP-at-end is exempt)
- **User gesture switching to a different task chain**: clicking a tab unrelated to the current opener chain

### 5.2 `ForgetOpener` — clears a SINGLE tab's opener

Triggered by:
- **`reset_opener_on_active_tab_change`**: when a Cmd+T NTP tab loses focus (user switches away), its opener is cleared

### 5.3 `FixOpeners` — re-parents children to grandparent

Triggered by:
- Same-window move (`MoveTabToIndexImpl`)
- Batch move (`PrepareTabsToMoveToIndex`)
- Close/remove (`DetachTabImpl`)
- Cross-window detach (`ProcessTabsForDetach`)
- WebContents replace (`DiscardWebContentsAt`)

### 5.4 `OnRemovedFromModel` — clears detached tab's own opener

When a tab is detached to another window, its own opener and reset flag are cleared.

## 6. Boundary of Responsibilities

### What Chromium handles

- WebContents creation and destruction
- Internal strip index management
- Opener relationship source-of-truth (via snapshots)
- `FixOpeners` on its own move/close/detach operations
- `DetermineNewSelectedIndex` (Mac may override)
- `activeTabChanged` notification

### What Mac handles

- Visible tab order (`normalTabOrder`)
- New tab insertion position calculation
- Close-selection target computation and override
- Local opener graph corrections for Mac-only operations (drag, pin, bookmark)
- Snapshot merge with local-fix protection
- `forgetOpenerOnActiveTabChange` simulation

### What neither side handles (known gaps)

- `Close Tabs to Right` has not been implemented with native order semantics
- `pinned/bookmark → normal` opener policy is not finalized
- Dangling window (pre-login tabs) loses `creationContext` during replay — negligible impact as those tabs use `restore`/`typedNewTab` which append to end

## 7. Debugging

All native tab order logs use the `[NativeTab]` prefix. Key log points:

| Location | Log content |
|----------|-------------|
| `insertionIndex` | Full context, graph state, computed index |
| `prepareForActiveTabClose` | Visible order, closing tab, computed target |
| `handleChromiumActiveTabChanged` | Override state, chromium choice, final decision |
| `apply(snapshot:)` | Snapshot version, merge decisions |
| `fixOpenersAfterMovingTab` | Affected children, new openers |
| `moveNormalTabLocally` | Children added to `locallyFixedOpenerTabIds` |
| `closeTab` | Children state, graph before/after |

Filter logs with:
```
[NativeTab]
```
