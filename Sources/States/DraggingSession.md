# Dragging Session Notes

This document summarizes the drag-and-drop changes added today for cross-window
tab movement, drag previews, and TabStrip integration.

## Overview
- Support drag across windows for normal tabs, pinned tabs, and bookmarks.
- Allow dragging a tab out of a window to create a new window.
- Keep drag preview behavior consistent: tab snapshot inside any browser window,
  page snapshot outside all browser windows.
- Add TabStrip support for cross-window drop and external drag feedback (gap).

## Key Behavior
### Sidebar (vertical tab list)
- Writes source window id into the pasteboard for normal tabs, pinned tabs, and
  bookmarks (`.sourceWindowId`).
- Accepts cross-window drops by looking up the source `BrowserState` and
  moving tabs/bookmarks into the target window via `webContentWrapper`.
- Uses `BrowserState.scheduleNormalTabInsertion` to preserve drop position for
  normal tabs that move between windows.
- Fixes pasteboard usage by reading from `NSPasteboard` (not `NSPasteboardItem`).

### Favorites (pinned tab collection)
- Adds cross-window handling for pinned tabs, normal tabs, and bookmarks.
- When dropping into another window, updates the source state and moves the
  underlying `webContentWrapper` to the target window.
- Ensures drag end uses the new `dragOperation`-aware API.

### TabStrip (horizontal tabs)
- Dragging can leave the TabStrip bounds; the proxy view follows the cursor
  without clamping outside the combined pinned/normal region.
- Cross-window drop support:
  - Resolve target window and its TabStrip to compute drop zone/index.
  - Move pinned/normal tabs between windows with scheduling for normal tabs.
  - If dropped outside all windows, create a new window (existing flow).
- Floating drag preview:
  - Uses a transparent `NSPanel` to show the tab/page snapshot at the cursor.
  - Tab snapshot when inside any browser window; page snapshot outside all.
- External drag feedback:
  - While dragging from one window, the target window TabStrip shows a gap
    (placeholder) using `externalDragPreview`.

### Dragging session core
- `TabDraggingSession` now treats "inside" as any browser window, not just the
  source window.
- The drag image switch is guarded by `nativeSession` availability.
- `end(screenLocation:dragOperation:)` avoids tear-off behavior when the drop
  is successfully performed.
- Exposes `pageSnapshotImage(for:)` for TabStrip to reuse snapshot logic.

### BrowserState insert scheduling
- `PendingNormalTabInsertion` now tracks a `guid` for reliable matching.
- `scheduleNormalTabInsertion(tabGuid:at:)` supports cross-window inserts.

## Files Touched
- `Sources/States/BrowserState.swift`
- `Sources/States/TabDraggingSession.swift`
- `Sources/UserInterface/Sidebar/TabList/SidebarItem.swift`
- `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
- `Sources/UserInterface/Sidebar/Favorites/FavoriteTabViewController.swift`
- `Sources/UserInterface/HorizontalBar/TabStrip/TabStrip.swift`
- `Sources/UserInterface/HorizontalBar/TabStrip/TabStripDragController.swift`
- `Sources/UserInterface/WebContent/WebContentContainerViewController.swift`
- `Sources/UserInterface/MainBrowserWindow/MainBrowserWindowController.swift`

## Data Flow Summary
1. Drag start writes item identifiers + `.sourceWindowId` to pasteboard.
2. Drag updates:
   - `TabDraggingSession` tracks cursor across all windows.
   - `TabStrip` updates floating preview and target gap (other window).
3. Drop:
   - If over another window, move in source state and move the wrapper to the
     target window, scheduling normal tab insertion when needed.
   - If outside all windows, create a new window from the dragged tab.

## Notes / Follow-ups
- External gap preview only applies to TabStrip; Sidebar uses native outline view
  indicators.
- If future work needs drag hover UI in the window body, re-check the
  "inside any browser window" logic in `TabDraggingSession`.
