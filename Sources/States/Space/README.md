# Space window close behavior

Defines what happens when a Space's NSWindow closes, depending on how the close was triggered. Owner: `SpaceWindowSlot.unregisterWindow(for:)` in `SpaceManager.swift`. Every Chromium-side `[NSWindow close]` and AppKit-side `performClose:` funnels into `windowWillClose` → `unregisterWindow`, so this is the single decision point.

## Why two paths exist

A `SpaceWindowSlot` is the user-perceived window. It hosts one `MainBrowserWindowController` per Space ever surfaced from this slot; exactly one is visible at a time. Two close triggers map to different user intent:

- **Tab-driven close** — the user just closed the last tab in the active Space (⌘W on tab, tab-row X button). Chromium auto-closes the Browser, which closes the NSWindow. The user is saying "I'm done with this Space," not "I'm done with this window."
- **Window-driven close** — the user explicitly closed the window itself (red ✕, ⇧⌘W via the Close Window menu item's `performClose:` action, Chromium's internal `BrowserWindowCocoa::Close`). The user is saying "I'm done with this whole window."

By the time `windowWillClose` fires, tab strip state is identical in both cases (Chromium has torn the tabs down already), so the slot needs an out-of-band signal to tell them apart.

## How tab-driven close is tagged

Two entry points dispatch `IDC_CLOSE_TAB` for the active tab:

- `CommandDispatcher.dispatchCommand(.IDC_CLOSE_TAB, …)` — keyboard ⌘W.
- `Tab.close()` — UI X button (`Sources/UserInterface/Common/Tabs/Tab.swift`).

Both check `browserState.tabs.count <= 1` and, if true, call `slot.markTabDrivenClose(for: spaceId)`. The marker is a spaceId → expiration-deadline entry in `pendingTabDrivenCloseDeadlines` on the slot. Any close path that does NOT tag the slot is treated as window-driven by default.

Two robustness rules apply to the tag:

1. **The CommandDispatcher tag is gated on `handleCloseTab()` returning `false`.** `handleCloseTab` swallows ⌘W when the omnibox is open and returns `true` without dispatching anything to Chromium. Tagging in that case would leave a stale marker that the user's next window-driven close would misclassify as tab-driven and route into switch-to-sibling instead of cascade-and-terminate.

2. **Markers have a TTL (`tabDrivenCloseTTL`, currently 2s).** When a dispatched `IDC_CLOSE_TAB` is vetoed — typically an `onbeforeunload` prompt the user cancels — no `unregisterWindow` fires to drain the marker. The TTL caps the stale window so a later window-driven close on the same Space is still correctly classified.

`unregisterWindow` reads `Date() < deadline` to decide `isTabDriven`. Expired markers are drained but not honored.

## Decision matrix

`unregisterWindow(for: spaceId)` only branches when `visibleController === controller` (the closed window was the visible one). Otherwise it just drops the controller from the map. When `wasVisible`:

| `isTabDriven` | sibling Space with tabs? | result |
|---|---|---|
| true | yes | `activate(spaceId: sibling)` — slot stays alive on the sibling. `visibleController` is left pointing at the closing controller so `activate` captures its frame as the inherited frame for the target. |
| true | no | cascade — every remaining sibling gets `NSWindow.close()`. |
| false | (ignored) | cascade. |

After the body, if `windowsBySpaceId.isEmpty` the slot removes itself from `SpaceManager.slots`. If `SpaceManager.slots` is then empty, the slot calls `NSApp.terminate(nil)` — the user asked for "close all spaces and exit" on window-driven close, and the cleanup path through `applicationShouldTerminate` → `applicationWillTerminate` (see `AppController`) gives Chromium a clean shutdown for SessionService state.

## Why cascade uses `NSWindow.close()` (not `performClose:`)

Cascade is invoked only after the user has already decided to close the window. A sibling Space's delegate (e.g. an `onbeforeunload` prompt) should not be allowed to veto. `close()` skips `windowShouldClose:`; `performClose:` does not.

## Sequence (matching log tags)

Window-driven close of a slot with N Spaces:

```
[SpaceWindowSlot] window-driven close of <visibleSpaceId>; cascading N-1 sibling(s)
  → each sibling triggers its own windowWillClose:
    [SpaceWindowSlot] window-driven close of <siblingSpaceId>; cascading 0 sibling(s)
[SpaceManager] last slot removed; calling NSApp.terminate(nil)
```

Tab-driven close with a viable sibling:

```
[SpaceWindowSlot] tab-driven close of <visibleSpaceId>; switching to sibling <siblingSpaceId>
```

(Slot stays alive; no further log line, no terminate.)
