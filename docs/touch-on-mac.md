# Touch on Mac

Scope: how Phi's native UI responds to direct touch on a Mac with a touch
display or a Sidecar-connected iPad (macOS 27). Web content is out of scope
until Chromium handles direct touch; it relies on AppKit's mouse emulation.

## Platform rules Phi depends on

- Direct touches reach AppKit only through gesture recognizers. Event
  monitors, `sendEvent(_:)` and the responder chain never see them.
- Views that override `mouseDown(with:)` get single-finger mouse emulation:
  a tap is a click, touch-hold-then-move is a drag. Non-AppKit content
  (Chromium) also gets one-finger momentum scroll, long press as right click,
  and two-finger pinch/rotate as trackpad magnify/rotate.
- Touch has no hover. `NSTrackingArea`, `mouseEntered` and `.onHover` are
  pointer-only.
- `NSGestureRecognizer.allowedTouchTypes` defaults to `.direct` from macOS 27.
- Phi does not set `NSIsTouchNative`; that would turn off the extra emulation
  Chromium content depends on.
- Never add a direct-touch recognizer to an ancestor of the web content (for
  example the window's content view). Doing so made taps on web pages stop
  working (TOUCH-011).

References: Adopting gesture recognizers in your app, Handling AppKit
gestures, TN3212, TN3216, HIG Pointing devices ("Touch support for hidden
controls") and Gestures.

## Shared helpers

`Sources/UserInterface/Common/TouchInteraction.swift`

- `TouchTapObserver` — touch-only tap recognizer (`buttonMask = 0`) that
  recognizes simultaneously with everything else, so mouse input and the
  view's own click handling are untouched. Its optional `onTouchBegan` runs
  when a finger lands, before that touch's tap or emulated click is handled.
- `PointerMotionObserver` — fires once when the physical pointer moves again;
  ends touch-revealed UI. Motion that stays at the last touch location is
  ignored in case AppKit places the cursor under the finger.
- `View.revealsOnTouchTap(_:)` — SwiftUI: a direct-touch tap (`TapGesture`
  with `inputKinds: .directTouch`, macOS 27) sets the binding, which clears
  itself after 4 seconds.

### Reveal without activating

A tap on the spot of a hidden control must only reveal it (HIG). The order in
which AppKit runs a tap recognizer's action and the emulated click for the
same tap is not documented, so a control that acts on the press snapshots, in
`onTouchBegan`, whether it was already revealed, and only acts if it was
(`SidebarCellView.touchWillBegin()`).

## Change log

Each entry: what changed, why, and what still needs on-device verification.
"Verified" means checked with touch (Sidecar or a touch display); a successful
build alone is not verification.

| ID | Area | Change | Status |
| --- | --- | --- | --- |
| TOUCH-001 | Sidebar bookmark rows | Press-scale recognizer sets `allowedTouchTypes = []`; tab rows use PR #324 instead | Built, not verified with touch |
| TOUCH-002 | Common | Added `TouchTapObserver` and `PointerMotionObserver` | Built, not verified with touch |
| TOUCH-003 | Sidebar | A tap reveals the tapped row's close control and the sidebar hover controls | Built, not verified with touch |
| TOUCH-004 | Tab strip (Comfortable) | Touch input shows the active tab's close button; a touch outside the strip unlocks the close layout | Built, not verified with touch |
| TOUCH-005 | Sidebar tab group header | Tap reveals the group close button; it closes only once revealed | Built, not verified with touch |
| TOUCH-006 | Sidebar Peek indicator | Touch-revealed rows show the indicator's minus glyph | Built, not verified with touch |
| TOUCH-007 | Downloads list rows | Direct-touch tap reveals the row's action buttons for 4 s | Built, not verified with touch |
| TOUCH-008 | Split pane move grip | Grip pill shows while a finger is on it, hides after 3 s unless dragging | Built, not verified with touch |
| TOUCH-009 | Sidebar bookmark context menu | Added "Close Tab" for opened bookmarks | Built, not verified |
| TOUCH-010 | Extensions list pin button | No change: pin/unpin is in the extension context menu | Reviewed |
| TOUCH-011 | Sidebar, tab strip | Fix: removed the window-level tap recognizers that broke taps on web content | Built, not verified with touch |

### TOUCH-001 — Keep press-scale recognizers off direct touch

- Files: `BookmarkCellView.swift` (`setupPressAnimation`). The tab row part
  (`SidebarTabCellView.setupPressAnimation`) was dropped in favor of PR #324,
  see below.
- Problem: both rows add an `NSPressGestureRecognizer` with
  `minimumPressDuration = 0` purely for the press-scale animation. From
  macOS 27 it also accepts direct touches and begins on touch-down, where it
  can win against the row's click emulation and against sidebar scrolling.
- Change: `allowedTouchTypes = []`, the pre-macOS 27 default. Mouse behavior
  is unchanged; under touch the row has no press-scale animation.
- Verify: tap a sidebar tab and a bookmark row (selects), pan the tab list
  (scrolls), touch-hold-drag a row (reorders).
- PR #324 (issue #323, verified on a touchscreen MacBook Pro by its author)
  fixes the same tab-row symptom differently: the press recognizer keeps
  direct touch with `isCancellableByScrollGesture = true`, and a touch-only
  `NSClickGestureRecognizer` on the row activates the tab through
  `TabCellDelegate.tabCellDidRequestActivation`. It was merged into this
  branch; the merge conflict in `setupPressAnimation` was resolved to the
  PR's code. Open: bookmark rows still use this entry's approach; check on
  device whether a tap opens a bookmark, and if not, give them the PR's
  touch tap.

### TOUCH-002 — Shared touch helpers

- File: `Sources/UserInterface/Common/TouchInteraction.swift` (added to the
  app target in `Phi.xcodeproj`).
- See "Shared helpers" above. All recognizers set every `delays*Events`
  flag to `false`.
- Verify: with a mouse, nothing in the sidebar or tab strip changes.

### TOUCH-003 — Sidebar: reveal hover-only controls on tap

- Files: `SidebarViewController.swift` (touch handling), `SidebarCellViews.swift`
  (`SidebarCellView.setTouchRevealed`, tab row, split row),
  `BookmarkCellView.swift`, `TabViewModel.swift` (`isTouchRevealed`),
  `SideTabView.swift`.
- Rule (HIG): a tap on a row reveals only that row's hidden controls and still
  performs the click; they stay until a touch lands outside the sidebar or the
  pointer is used again.
- Change:
  - A `TouchTapObserver` on the sidebar root finds the tapped
    `SidebarCellView` and calls `setTouchRevealed(true)`; the previously
    revealed row is cleared.
  - Tab rows show the close button, split rows show their per-pane close
    buttons, opened bookmark rows show the "minus" button.
  - The sidebar hover controls (address-bar accessory buttons, cleanup
    buttons) are shown, matching a pointer inside the sidebar.
  - While a touch reveal is active, pointer-driven updates
    (`mouseExited`, `updateHoverControlsForCurrentMouseLocation` on layout)
    do not hide them.
  - It ends on pointer motion or the sidebar leaving the window. A touch
    outside the sidebar no longer ends it (TOUCH-011).
- Tab group header close and the Peek indicator follow in TOUCH-005 and
  TOUCH-006.
- Verify: tap row A (selects, close appears), tap row B (A's close hides),
  move the mouse (hides).

### TOUCH-004 — Tab strip: active tab close button under touch

- Files: `TabStrip.swift`, `Views/TabItemView.swift`.
- Rule (HIG): in a tabbed window a tap anywhere shows the selected tab's close
  button until the pointer is used again; after closing it, the newly selected
  tab shows it. Phi only covers taps in the strip (TOUCH-011).
- Change:
  - `TabStrip` installs a `TouchTapObserver` on itself while it is in a
    window.
  - The first touch turns on `TabItemView.revealsCloseButtonForTouch` for
    every normal tab; `shouldShowCloseButton` adds `revealsCloseButtonForTouch
    && isActive`. Rebinding carries the flag, so the next active tab shows
    the button after a close.
  - Pointer motion turns it off.
- Known gap: after closing tabs by touch, tab widths stay locked until the
  pointer leaves the strip (`mouseExited`); a touch elsewhere does not unlock
  them (TOUCH-011).
- Verify (Comfortable layout): tap a tab (selects, close appears), tap close
  (next active tab shows close, widths stay locked), move the mouse (close
  hides unless hovered).

### TOUCH-005 — Tab group header close button

- Files: `TabGroupHeaderView.swift` (`TabGroupHeaderViewModel.isTouchRevealed`,
  `isCloseArmedForTouch`, `showsCloseButton`), `TabGroupCellView.swift`,
  `SidebarCellViews.swift` (`touchWillBegin()`), `SidebarViewController.swift`,
  `TouchInteraction.swift` (`onTouchBegan`).
- Problem: the close button has opacity 0 until the header is hovered, and
  `TabGroupHeaderHostingView.mouseDown` drops a close-zone press unless
  `isHeaderHovered`. Touch could never close a group from the header.
- Change: a sidebar tap on the group cell sets `isTouchRevealed` (button
  visible). When a touch begins, the revealed cell records
  `isCloseArmedForTouch`; the close-zone press is accepted when the header is
  hovered or the close was armed. The first tap on a hidden close button only
  reveals it; the header still gets that tap as before.
- Verify: tap a group header (reveals close, does not close), tap close
  (closes), tap a row elsewhere then this group's close spot (reveals only).

### TOUCH-006 — Peek indicator minus on touch-revealed rows

- Files: `BookmarkCellView.swift` (`SidebarPeekIndicatorView.isTouchRevealed`),
  `SideTabView.swift`.
- The indicator is a visible button that closes the Peek on click; hover only
  swaps the favicon for a minus. Touch-revealed tab and bookmark rows now show
  the minus too, so the tap's effect is visible beforehand.
- The pinned tab corner badge (`PinnedPeekBadgeView`) is also a visible
  button with a "Close Peek" tooltip; left unchanged.

### TOUCH-007 — Downloads list row actions

- Files: `DownloadItemRow.swift`, `TouchInteraction.swift`
  (`revealsOnTouchTap`).
- Problem: with `usesHoverAppearance` (All Downloads list) the action buttons
  are hidden and disabled until hover.
- Change: a direct-touch tap on a row reveals them for 4 seconds (HIG generic
  rule: reveal on tap, hide after a few seconds). A tap on a hidden button's
  spot does nothing because it is disabled while hidden.
- Verify: tap a row in All Downloads (buttons appear, nothing else happens),
  tap Show in Finder within 4 s, wait 4 s (buttons hide); double-tap still
  opens a completed file.

### TOUCH-008 — Split pane move grip

- File: `SplitPaneHostView.swift` (`PaneMoveHandle`).
- Problem: the grip pill only appears on hover, although the invisible 72×18
  grip already takes touches (touch-hold-then-move emulates the drag).
- Change: the pill shows when a finger lands on the grip and hides after
  3 seconds unless a drag started; `hideGrip()` cancels the pending hide.
  "Move Focused Pane …" stays available in the split's context menu.
- Verify: touch the top center of a split pane (pill appears), hold and move
  (pane moves), lift (pill hides).

### TOUCH-009 — "Close Tab" in the sidebar bookmark context menu

- Files: `BookmarkModel+Sidebar.swift`, `Resources/Localizable.xcstrings`
  (`sidebar.bookmarkContextMenu.closeOpenTabAction`, English only).
- The opened bookmark row's hover-only "minus" closes its tab
  (`BrowserState.closeBookmark`), and no menu item did. HIG asks for essential
  hidden controls in the context menu (touch and hold opens it). Shown only
  from the sidebar and only while the bookmark has an open tab or bound split.
- Product check: wording "Close Tab".

### TOUCH-010 — Extensions list pin button (no change)

- The pin button in the extensions popover appears only on hover, but a tap
  on an extension runs it and dismisses the popover, so a reveal tap cannot
  work there. Pin/Unpin is in the extension's context menu (touch and hold),
  which covers the HIG requirement.

### TOUCH-011 — Fix: taps on web content stopped working

- Files: `TabStrip.swift`, `SidebarViewController.swift`.
- Symptom (reported on device): after TOUCH-003/004, tapping a web page did
  nothing; mouse clicks still worked. Before these changes, taps worked.
- Cause (inference from the docs, not confirmed on device): TOUCH-004 added a
  `TouchTapObserver` to the window's content view, and TOUCH-003 added one
  there while a sidebar reveal was active. Both are ancestors of the
  Chromium view, so AppKit gathered them for every tap on the page. AppKit's
  touch-to-mouse emulation for non-AppKit frameworks is itself done by
  injected gesture recognizers, and TN3216 says a view handles touch directly
  once a direct-touch recognizer is attached. Returning `true` from
  `shouldRecognizeSimultaneouslyWith` did not prevent this.
- Change: the tab strip's observer is on the strip itself, and the sidebar no
  longer installs the window-level outside-touch observer. Remaining
  observers sit on the sidebar root, the tab strip and the split move grip,
  none of which contains web content.
- Cost: a tap on the page no longer shows the active tab's close button,
  no longer unlocks tab widths after a touch close, and no longer ends a
  sidebar reveal. Pointer motion still ends both.
- Verify: tap links, buttons and text fields on a web page in each layout,
  with and without a sidebar reveal showing.

## Context menu audit

Hidden actions and where touch reaches them (touch and hold opens the menu):

| Hidden control | Context menu item |
| --- | --- |
| Sidebar tab close | Close |
| Split row pane close | Close Split, Remove from Split |
| Tab group header close | Close Group |
| Opened bookmark "minus" | Close Tab (TOUCH-009) |
| Peek indicator / badge | None; the control itself is visible |
| Extension pin | Pin / Unpin (Chromium extension menu) |
| Split pane move grip | Move Focused Pane … |

## Pending, needs on-device facts first

- `hitTest` overrides gated on `NSApp.currentEvent?.type` (top address bar
  drag view, Spaces strip, pinned extensions, tab strip titlebar regions,
  `HoverableButton` secondary-click containers, `EventBlockBgView`). What
  `currentEvent` holds when a touch is hit-tested decides whether these
  become untappable. Widening the gate blindly risks drag-and-drop and
  titlebar behavior with the mouse.
- Mouse-down monitors and `sendEvent(_:)` logic: split-pane focus on click,
  taking key back from the omnibox/find child window
  (`ShellWindowController`, Chromium `browser_native_widget_window_mac.mm`),
  Peek/Reader/theme-editor outside-click handling. Needs to know whether
  emulated mouse events pass through `NSApp.sendEvent`.
- Back/forward swipe on web content (HistorySwiper, `PhiApplication`
  `NSEventTypeSwipe`), Space swipe and media-card swipe driven by
  `scrollWheel`.
- Top address bar hover buttons (memory, copy URL, `…`): hidden with
  `opacity(0)` but still hit-testable. Whether a touch reaches them or the
  `WebContentAddressBarDragView` above depends on the `currentEvent` gate.

## Pending, needs a design decision

- Collapsed sidebar reveal (10 pt hover strip).
- Custom traffic lights: glyphs only on hover, 16 pt targets; the right-side
  sidebar's hover-revealed window-controls bar (dev #308) has the same issue.
- 36 pt touch targets for 24 pt and smaller controls: touch only, or larger
  for the pointer too.
