# Native Tab Order & Selection — Technical Guide

> Overall design of Phi tab order, creation, and close selection.
> User-visible rules are defined in [the tab-order specification](tab-order-spec.md).

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

Visible order is a projection, not a second physical strip. Phi mirrors normal-tab moves through live-tab anchors so Chromium and native order converge, while retaining native close-selection policy for the visible projection.

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
| `NativeTabDecisionEngine.swift` | Data models, insertion/selection algorithms, opener graph, placement reconciler |
| `BrowserState.swift` | Integration point: new tab insertion, close handling, drag fix, snapshot merge |
| `PhiChromiumCoordinator.swift` | Parses `NativeTabCreationContext` and `NativeTabRelationshipSnapshot` from bridge callbacks |
| `PhiChromiumBridgeHeader.h` | Bridge protocol: snapshot callback, `createQuickLookupTab` |
| `EventBus.swift` | Events: `.newTabWithContext`, `.updateTabRelationships` |
| `Tab.swift` | `close()` calls `prepareForActiveTabClose` before sending `IDC_CLOSE_TAB` |
| `SpaceSessionController+Actions.swift` | Cmd+T routed to `createQuickLookupTab` |

## 3. Chromium Integration Design

### Bulk tab changes

Chromium separates pre-removal lifetime work from the actual model delta.
`tabWillDetach` runs synchronously before recently-closed history is written:
Phi detaches hosted views and transfers split AI Chat records there. The later
`tabsRemovedSnapshot` payload contains the actual removals, final indices and optional
active tab. `BrowserState.applyTabsRemoved` performs source-window cleanup,
then publishes `tabs` and its visible projection once. A move out of a window
also removes its source-side state; Chromium retains ownership of the moved
WebContents. Tabs awaiting or cancelling beforeunload are absent from the delta.
Group-membership callbacks for tabs already detached from the source model are
not forwarded to Phi: the removal snapshot updates membership through the
surviving tab list. In-model ungrouping and group moves still emit membership
events, and closing the last member still emits the group-closed event.
The snapshot uses its own selector; both native and Swift declarations require
a dictionary. Rebuild the app and native framework together after bridge changes.

Explicit multi-tab duplication reuses the bridge's restored-window insertion
buffer and the Mac insertion transaction. Native duplication preserves history,
pinning, groups and split visual data, inserts clones in the background, then
activates the final clone once. `tabsInsertedSnapshot` carries the new tabs,
split events, full-strip indices and final relationships/selection. Unlike
session restoration, it applies through EventBus after Chromium's stack unwinds.
Neither path defers Chromium's WebContents destruction to a worker thread.

### 3.1 `NativeTabCreationContext` (via bridge)

When Chromium creates a new tab, `buildCreationContextForWebContents` in `PhiChromiumBridge.mm` constructs a dictionary carrying:

| Field | Type | Description |
|-------|------|-------------|
| `isActiveAtCreation` | Bool | Whether the new tab is foreground |
| `creationKind` | String | `linkForeground`, `linkBackground`, `typedNewTab`, `typedNavigation`, `restore`, etc. |
| `openerTabId` | Int? | The opener tab's custom guid |
| `insertAfterTabId` | Int? | Chromium's insertion anchor (for fallback) |
| `sourceTabId` | Int? | The source tab that initiated the creation |
| `resetOpenerOnActiveTabChange` | Bool | Whether this tab's opener should clear when the user switches away |
| `didForgetAllOpenersBeforeCreate` | Bool | Whether `ForgetAllOpeners` was called during this creation |

The `creationKind` classification honors explicit ordinary-creation intent and quick-lookup state before generic bridge or link classification. `resetOpenerOnActiveTabChange` distinguishes typed quick-lookup lifecycle from ordinary link creation.

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

### 3.4 `bridgeCreate`

Generic client-created tabs use `creationKind = bridgeCreate`, distinct from
page-originated link creation even when Chromium assigns the active tab as opener.
Restore, promotion, external opens, and cross-profile transfer must not inherit
ordinary user-new-tab placement solely because they share a bridge API.

Explicit ordinary creation carries a one-shot intent to the final WebContents.
Cmd+T and address-bar new-tab submissions can therefore use typed creation
semantics without reclassifying generic bridge calls. URL routing carries this
intent through automatic and Ask-every-time destinations; the destination
BrowserState decides position using its own layout. Existing-tab navigation is
not a request to reorder that tab. Eligible new-NTP navigation can carry the
intent when routing creates a replacement tab in another Space.

Routing inserts the destination tab before loading its URL and exempts that
initial destination navigation from repeat routing. Hidden windows are not
activated merely by background creation. A missing or closing destination fails
closed with native feedback rather than opening in an unspecified profile.
Internal URLs disallowed in incognito retain the existing regular-profile
rehome behavior.

## 4. Native Ordering Design

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

`NativeTabDecisionEngine.insertionIndex(visibleNormalTabIds:context:relationGraph:splitPartnerByTabId:hiddenOpenerTabIds:)` computes the insertion position:

| `creationKind` | Logic |
|----------------|-------|
| `linkForeground` | Right after opener in visible order; fallback to `insertAfterTabId` |
| `linkBackground` | After the opener's last visible descendant; fallback to `insertAfterTabId` |
| `typedNewTab` / `typedNavigation` | Top-placement helper returns the first normal position. BrowserState applies `newTabsAtTop` and destination layout first: bottom/Comfortable appends without a move; structural/restore arrivals stay excluded |
| `restore` | `insertAfterTabId` + 1 when the anchor resolves in the visible list. No anchor at all → `0`, because that payload is the strip's first restored tab and belongs ahead of any placeholder the window already shows. Anchor present but **absent from the visible list** → nil (caller appends) |
| `explicitInsert` / `moveFromOtherWindow` / `bridgeCreate` / `unknown` | Use `insertAfterTabId` if present; otherwise nil (caller appends) |

A `restore` anchor can be missing from the visible list while still existing in Chromium's strip: the Mac side hides tabs bound to a pinned tab or an open bookmark, split-bookmark members, AI chat payloads (never added to `tabs`), and duplicate-guid payloads the restored-window transaction drops. Appending in that case keeps the surviving tabs in strip order — returning `0` would throw this tab, and every tab restored after it, ahead of the ones already placed.

Whole-split adjustment: if the opener belongs to a split, the insertion anchor advances to the last member of that split. The split may have two, three, or four panes; pane order and the physical strip indices, not a fixed pair offset, determine the boundary. Link clicks land after the complete split.

Integration in `BrowserState.handleNewTabFromChromium`:

1. Parse `NativeTabCreationContext` from bridge payload
2. Optimistically update `nativeRelationGraph` via `applyOptimisticCreation`
3. If `didForgetAllOpenersBeforeCreate`, clear all openers in the graph
4. Resolve structural/explicit insertion ownership before ordinary placement
5. Apply the destination new-tab policy or the creation-kind insertion rule
6. Publish normal order and synchronize physical placement where required

### 4.3 Close Selection Override

When the active normal tab is closed, the Mac side pre-computes the next selection target **before** the opener graph is modified.

**Selection priority** (`NativeTabDecisionEngine.selectionTarget`):

0. **Split pane** — when the closing tab is a pane of a split that stays up (two or more other panes remain), the nearest remaining pane in slot order (right-first), via `splitPaneSelectionTarget`; it skips the rules below and the pinned/bookmark-ancestor redirect
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
| `moveNormalTabLocally` (drag reorder) | **Yes** | Phi mirrors relative normal-tab order to Chromium, but keeps local opener protection for snapshot races |
| `closeTab` | **Yes** | Protect prior drag fixes from being reverted by stale snapshots |
| `moveNormalTab(toPinnd:)` | **Yes** | Chromium unaware of Phi's pin operation |
| `moveNormalTab(toBookmark:)` | **Yes** | Chromium unaware of Phi's bookmark operation |

#### `forgetOpenerOnActiveTabChange`

When the active tab changes, if the previously active tab has `resetOnActiveChangeTabIds`, its opener is cleared. This mirrors Chromium's `reset_opener_on_active_tab_change` behavior (used for Cmd+T NTP tabs).

#### `removeTab`

Cleans up all graph state for a removed tab: `knownTabIds`, `openerByTabId`, `resetOnActiveChangeTabIds`, `locallyFixedOpenerTabIds`.

### 4.5 Normal-Order Sync

When a tab is drag-reordered in the native UI (`moveNormalTabLocally`):

1. Capture `directChildren(of: movedTabId)` **before** the fix
2. Call `fixOpenersAfterMovingTab(movedTabId)` — re-parents children to moved tab's opener
3. Add affected children to `locallyFixedOpenerTabIds`
4. Reorder `normalTabOrder`
5. Notify Chromium of the moved tab's relative normal-tab anchor so restore sees the same normal-tab order

When an existing pinned/bookmark-backed tab is moved into normal tabs, or a closed pinned/bookmark item creates a new Chromium tab for the normal list, Phi inserts the tab into `normalTabOrder` and uses the same relative-anchor notification path.

This ensures that subsequent Chromium snapshots will not overwrite the Mac-side corrections, while Chromium still receives enough ordering information for normal-tab restore.

### 4.6 Ordinary New-Tab Policy and Sidebar Button

`newTabsAtTop` is a synchronized global Boolean under General → Browsing,
defaulting to false. `BrowserState.opensNewTabsAtTop` combines this preference
with the destination layout. Comfortable always appends without changing the
stored choice. Toggling the preference does not reorder existing tabs.

Only ordinary typed creation is eligible. Pending explicit/group insertion,
persisted custom IDs, existing group/split membership, and synchronous restore
replay take precedence. Link children retain opener/descendant placement.
Bottom mode appends in both native and Chromium order without an extra manual
move. Top mode uses the initial-placement transaction described below.

The sidebar uses the same effective policy and one stable New Tab item. Top
mode places it before normal rows and preserves top-edge sticking. Bottom mode
places it after normal rows, sticking at the viewport bottom only while that
row overflows. Short lists keep the button in flow. The default preserves tail
creation but intentionally moves the historical top button to the bottom.

Preference and layout changes update projection, sticky geometry, content masks,
and scroll insets together. Preference notifications deduplicate the raw Boolean,
not the layout-derived policy; layout has its own subscription. This avoids a
stale derived-value cache when destination layout changes first. Focus scrolling
excludes the overlay so a newly selected tab remains visible. Dragging suppresses
the floating overlay; drop positions use actual projected items rather than a
fixed New Tab row offset. Before-button and end-of-list drops append in bottom
mode; direct drop-on-button remains an unsupported, non-mutating action.

### 4.7 Dynamic Boundaries and Physical Placement

A normal-list index is never a Chromium strip index. Opened pin/bookmark tabs
can be interleaved with normal tabs, while closed persistent items have no
WebContents. Physical `[hidden A, normal B, hidden C, normal D]` projects to
`[B, D]`; adding a hidden-tab count to a normal index cannot locate B or D.

Top placement names the first eligible live normal tab with
`placeNewTabWithWindowId:tabId:beforeTabId:`. Chromium resolves IDs against the
current destination strip, treating an anchor's split or foreign group as a
whole unit. Two-, three-, and four-pane boundaries use actual membership and
pane order, never a fixed pair offset. Pin/bookmark promotion and pane reordering
therefore change the next anchor naturally. A missing/moved anchor or structural
constraint does not authorize splitting or moving unrelated tabs.

With no existing normal tab, no relative move is needed: the new tab is the sole
normal entry even if hidden live tabs precede it physically.

### 4.8 Placement Transaction and Convergence

EventBus delivers window events FIFO on the main dispatch queue after the
Chromium mutation stack unwinds. `NativeTabPlacementReconciler` protects only
an in-flight tab's native slot, not the entire strip:

1. Publish its intended normal position and record a per-tab request token.
2. Invoke synchronous initial placement. Chromium emits a final full-strip index
   map even for a no-op or rejected placement.
3. Drain older queued maps without overwriting protected slots; other tabs still
   follow authoritative Chromium order.
4. Queue completion behind the operation's callbacks on the same main queue.
5. Release only the matching token and reconcile using the latest full-strip map.

An old completion cannot release a newer request. Closed or transferred tabs
are not reintroduced by a delayed completion. Rejected placement eventually
converges rather than leaving a permanently protected native position.

This is an ordered in-process contract, not an unordered transport protocol.
Asynchronous transport or nested run loops within mutation/snapshot-suppression
scopes would require explicit acknowledgement or revision ordering. Synchronous
restore replay never invokes ordinary placement. Frameworks without the selector
retain existing physical order rather than receiving an unsupported call.

### 4.9 Quick-Lookup Opener Preservation

Initial placement is not a user reorder. It must preserve opener children instead
of invoking the ordinary move's `FixOpeners` semantics. A narrow Chromium marker
preserves first-navigation eligibility for a newly placed quick-lookup NTP even
when it is no longer physically last. This requires the eligible NTP/history and
opener/reset state; it is not a blanket exception for every NTP or drag.

Navigation, activation changes, subsequent manual moves, and detach clear or
consume eligibility according to the opener lifecycle. Placement never invents
an opener or permanently suppresses resets. Close-selection policy remains the
same regardless of whether the new tab was inserted at the top or bottom.

## 5. Chromium Opener Change Scenarios

Understanding when Chromium modifies opener relationships is critical for debugging.

### 5.1 `ForgetAllOpeners` — clears ALL openers in the strip

Triggered by:
- **Foreground tab creation with `ADD_INHERIT_OPENER`**: link-open foreground, Cmd+T, `AppendWebContents(foreground=true)`
- **Non-link navigation**: user types URL in address bar, clicks bookmark, etc. (eligible first-navigation NTPs retain their quick-lookup exemption)
- **User gesture switching to a different task chain**: clicking a tab unrelated to the current opener chain

### 5.2 `ForgetOpener` — clears a SINGLE tab's opener

Triggered by:
- **`reset_opener_on_active_tab_change`**: when a Cmd+T NTP tab loses focus (user switches away), its opener is cleared

### 5.3 `FixOpeners` — re-parents children to grandparent

Triggered by:
- User same-window move (`MoveTabToIndexImpl`), excluding initial new-tab placement
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

### Native range closing

Tab and group context menus resolve directional close targets from `normalTabs`,
the native strip projection. Horizontal bars present left/right actions; vertical
bars present above/below actions. The clicked tab is the anchor, and a group-header
anchor protects the full member range. Collapsed members still participate.
Splits are complete units for range closing: all anchor panes survive and all
target panes are submitted. A split containing a protected pane is excluded.

Range closing and Close Other Tabs exclude pins and bookmark-bound pages outside
the ordinary strip. Comfortable opens bookmarks as ordinary unbound tabs, which
participate normally without deleting saved bookmarks. Explicit Close remains
available for persistent surfaces and retains their saved records.

`BrowserState` computes eligibility and targets; menus only supply anchors and
direction. Existing Close Other / Close Tabs to Right shortcut commands use the
same native policy (the latter means following tabs in vertical layouts). All
targets go through the existing batch bridge and removal snapshots. Beforeunload
and group confirmation remain framework-owned; a batch can complete partially.
Invocation recomputes targets so disappeared anchors do not close unrelated tabs.

Advanced settings groups the existing double-click preference and positional
closing in one untitled card. Positional closing defaults on; disabling it hides
both tab and group menu entries and suppresses directional shortcut execution.
Close Other Tabs remains independently available. Double-click closing keeps its
existing preference key and default-off behavior. Both preferences apply without
restarting the application.
