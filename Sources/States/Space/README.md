# Space window close behavior

Defines what happens when a Space's NSWindow closes, depending on how the close was triggered. Owner: `SpaceWindowSlot.unregisterWindow(for:)` in `SpaceManager.swift`. Every Chromium-side `[NSWindow close]` and AppKit-side `performClose:` funnels into `windowWillClose` → `unregisterWindow`, so this is the single decision point.

## Why two paths exist

A `SpaceWindowSlot` is the user-perceived window. It hosts one `MainBrowserWindowController` per Space ever surfaced from this slot; exactly one is visible at a time. Two close triggers map to different user intent:

- **Tab-driven close** — the user closed the last tab in the active Space through the tab UI. Chromium used to auto-close the Browser, which closed the NSWindow; today it enters placeholder mode instead and the window stays (see "The tag is cancelled…" below). The user is saying "I'm done with this Space," not "I'm done with this window."
- **Window-driven close** — the user explicitly closed the window itself (red ✕, ⇧⌘W via the Close Window menu item's `performClose:` action, ⌘W on the last tab, Chromium's internal `BrowserWindowCocoa::Close`). The user is saying "I'm done with this whole window."

⌘W on the last tab is deliberately window-driven, not tab-driven: closing a Space's last tab with the keyboard tears the whole slot down like ⇧⌘W / the red ✕, rather than switching to a sibling Space.

By the time `windowWillClose` fires, tab strip state is identical in both cases (Chromium has torn the tabs down already), so the slot needs an out-of-band signal to tell them apart.

## How tab-driven close is tagged

Only one entry point tags a tab-driven close:

- `Tab.close()` (`Sources/UserInterface/Common/Tabs/Tab.swift`) — reached from the tab-row ✕ button and every other UI path that closes a tab through the `Tab` object: the tab context menu's Close, the split-pane close, the sidebar tab list, the tab-search palette, the group overview, AppleScript.

It checks `browserState.tabs.count <= 1` and, if true, calls `slot.markTabDrivenClose(for: spaceId)`. The marker is a spaceId → expiration-deadline entry in `pendingTabDrivenCloseDeadlines` on the slot. Any close path that does NOT tag the slot is treated as window-driven by default.

**The tag is cancelled when the window survives the last-tab close — on any of three signals.** Closing a Space's last tab in a normal, non-Incognito window no longer closes the window: Chromium keeps it alive showing the placeholder page (`Browser::TabStripEmpty` → `ShouldEnterPlaceholderMode` → `ShowPlaceholder`) and reports that over the bridge, which `PhiChromiumCoordinator.windowDidEnterPlaceholderMode` turns into `slot.cancelTabDrivenClose(for: spaceId)` — dropping the marker and the pre-captured composite together, before any fallible work in that callback. The second signal is the Space's tab list going from **empty back to non-empty**: `BrowserState.handleNewTabFromChromium` (and its peek-adoption twin, `adoptPeekTabIntoStrip`) runs the same cancel just before appending a tab to an emptied list. Today that transition is a tab opened into a placeholder window or a peek adopted after its sole opener closed; the signal is deliberately source-agnostic, so any flow that re-fills the strip in place of placeholder entry — such as a refill quota absorbing the clear — cancels through the same path. The third signal is a pending peek candidate settling: `resolvePeekCandidate` and `finishPeekCandidate` cancel in their prologs — before the outcome branches (presented, adopted, or discarded) and before `peekCandidate` is cleared — because settlement proves the armed close resolved against the candidate machinery while the window stays alive, and cancelling pre-outcome makes it independent of whether the async URL/timeout resolve or the queued close event applies first (a resolve that wins the race and presents would otherwise route the later close through the presented-peek cleanup branch, past every other signal). `adoptPeekTabIntoStrip` additionally cancels on every adoption, covering non-candidate adoptions such as expanding a presented peek. (The empty → non-empty judgment lives where the Mac-side list actually mutates — at event-apply time in `BrowserState` — not at bridge-callback time: inside Chromium's synchronous close→insert turn the queued close event has not been applied yet, so the coordinator would still see the closing tab in the list.) The auto-close the marker predicts never happens, so leaving it armed would make the user's *next* close of that same window — the one they mean as "close this window" — read as a tab-driven hand-off and switch to a sibling Space instead of closing the slot.

Consequence: **no user gesture reaches `unregisterWindow` with a live tab-driven marker**, so the hand-off row of the matrix below is currently unreachable, as are the helpers only it uses (`firstSiblingWithTabs`, `pendingTabDrivenCloseSnapshots`, `activate`'s `leavingSnapshotOverride`). The one remaining way in is the vetoed-close residual below — a known defect, not a behavior.

Keyboard ⌘W (`CommandDispatcher.dispatchCommand(.IDC_CLOSE_TAB, …)`) deliberately does **not** tag. Closing a Space's last tab with ⌘W is intended to tear the whole slot down like ⇧⌘W, so it dispatches `IDC_CLOSE_TAB` untagged and reaches `unregisterWindow` as a window-driven close. (⌘W is still swallowed by `handleCloseTab()` when the omnibox is open, which returns `true` without dispatching anything — no tag is involved either way.)

**Incognito Spaces bypass the tag entirely on a last-tab close.** Both `Tab.close()` and the ⌘W dispatch intercept it up front and route into `SpaceManager.requestCloseIncognitoSpace(spaceId:)`: a confirmation ("This will also close this Incognito Space, are you sure?", suppressible via "Do not ask again") followed by `closeIncognitoSpace(spaceId:)`, which closes the Space's windows in every slot retreat-first (evict-then-close, like `deleteSpace`) and removes the runtime Space itself. Close paths that never reach the interception — a window-driven slot cascade, a scripted `window.close()` — are mopped up by `reapIncognitoSpaceIfWindowless(_:)`, called one turn deferred from `unregisterWindow`, which retires an Incognito Space once no slot holds a window for it.

One robustness rule applies to the tag:

- **Markers have a TTL (`tabDrivenCloseTTL`, currently 2s).** When a dispatched `IDC_CLOSE_TAB` is vetoed — typically an `onbeforeunload` prompt the user cancels — the tab stays put: the window enters no placeholder, no insertion re-fills an emptied strip, and no `unregisterWindow` fires, so nothing cancels or drains the marker. The TTL caps the stale window so a later window-driven close on the same Space is still correctly classified; inside that window it is still misclassified.

`unregisterWindow` reads `Date() < deadline` to decide `isTabDriven`. Expired markers are drained but not honored.

## Decision matrix

`unregisterWindow(for: spaceId)` decides between three outcomes from `wasVisible` (`visibleController === controller`) and `isTabDriven`:

| `wasVisible` | `isTabDriven` | sibling Space with tabs? | result |
|---|---|---|---|
| true | true | yes | `activate(spaceId: sibling)` — slot stays alive on the sibling. `visibleController` is left pointing at the closing controller so `activate` captures its frame as the inherited frame for the target. **Currently unreachable** except through the vetoed-close residual above. |
| true | true | no | cascade — `cascadeCloseRemainingWindows` closes every remaining sibling through Chromium. |
| true | false | (ignored) | cascade. |
| false | false | (ignored) | cascade. |
| false | true | (ignored) | drop only — the controller leaves the map with no side effects. |

The `wasVisible == false && isTabDriven == false` row is why the cascade is **not** gated on `wasVisible` alone: in the slot's native tab group `visibleController` can lag AppKit's actually-selected tab, so a real window-driven close can arrive on a controller that isn't the tracked visible one. Gating the cascade on `wasVisible` only let that close slip through and strand the slot's other Spaces with live tabs. Background closes that must NOT cascade (`deleteSpace` / `changeProfile` / `respawnWindow`) evict the controller first, so they early-return on the identity guard and never reach this branch.

After the body, if `windowsBySpaceId.isEmpty` the slot removes itself from `SpaceManager.slots`. Emptying the last slot does **not** quit the app: it stays alive with no windows on screen, so the Dock icon can reopen the group. `removeSlot` shrinks the restore snapshot on its way out, and that write is a no-op when this was the last slot — `persistSlotsSnapshot` never overwrites a saved snapshot with an empty one, which is exactly what freezes the final layout for the reopen to restore from.

Because that final write is a no-op, the snapshot a reopen restores from is whichever one landed *before* the close — which is why `unregisterWindow` opens with `flushPendingSlotsSnapshotPersist()`, before it touches the window map. Window moves and resizes persist on a debounce (they fire far too often to write per event), and this is the last moment such a pending write can still describe a whole, live slot. It is a no-op unless a frame change is actually outstanding, and mid-cascade it writes nothing at all — `persistSlotsSnapshot` refuses while any slot is tearing down, and likewise while quitting or while a windowless reopen is still replaying its session (`mayPersistSlotsSnapshot` holds all three). A refused flush leaves the frame change on record for the next write rather than dropping it, so the only case that really loses one is closing a window inside the debounce *during* a reopen replay — where keeping the last complete snapshot is the deliberate trade.

## How the cascade closes windows (`cascadeCloseRemainingWindows`)

The cascade closes each remaining window **through Chromium**, via
`bridge.executeCommand(IDC_CLOSE_WINDOW, windowId:)` →
`chrome::FindBrowserWithID` → `chrome::ExecuteCommand` →
`BrowserWindow::Close`. This is the same path the user's own window close
takes, and it is the fix for the flaky teardown:

- **Why not `NSWindow.close()`.** An earlier version poked each sibling's
  `NSWindow.close()` directly. The slot's windows live in one native tab
  group, and closing several of them — even serialized one per runloop turn —
  raced AppKit's tab-bar selection promotion, dropping some programmatic
  closes and stranding background Spaces with live tabs (with 7 Spaces, ~2
  routinely survived). Driving the close through Chromium tears each `Browser`
  down deterministically and independently of the AppKit tab group.
- **Re-entrancy.** The `isCascadingSlotClose` flag makes each window's later
  `unregisterWindow` (fired when Chromium finishes its teardown) just drop
  from the map instead of re-running a hand-off/cascade; the last drop clears
  the flag and removes the slot.
- **Trade-off: `beforeunload` is honored.** Unlike `NSWindow.close()`,
  `IDC_CLOSE_WINDOW` runs `beforeunload`, so a background Space with unsaved
  changes *and* prior user interaction can surface a dialog — the same
  behavior the visible window already has. (Chrome suppresses the dialog for
  pages with no user gesture, so untouched background Spaces close silently.)
- **Siblings on the placeholder page depend on a Chromium-side whitelist.** A
  window parked on the placeholder page has an empty tab strip, and
  `BrowserCommandController::ExecuteCommandWithDisposition` drops every command
  that is not on the placeholder whitelist it keeps for that state.
  `IDC_CLOSE_WINDOW` sits on that list for this cascade's sake; take it off and
  placeholder siblings silently survive the cascade, which the slot then reads
  as a vetoed close and puts back on screen seconds later.

## Sequence (matching log tags)

Window-driven close of a slot with N Spaces:

```
[SpaceWindowSlot] window-driven close of <visibleSpaceId>; cascading N-1 sibling(s) via Chromium
  → cascadeCloseRemainingWindows issues IDC_CLOSE_WINDOW for each remaining sibling;
    each closing sibling drains via the isCascadingSlotClose guard (no further log line),
    and the last drop removes the slot.
```

Tab-driven close with a viable sibling (currently unreachable — this line appearing after a plain last-tab close means the marker was not cancelled):

```
[SpaceWindowSlot] tab-driven close of <visibleSpaceId>; switching to sibling <siblingSpaceId>
```

(Slot stays alive; no further log line.)
