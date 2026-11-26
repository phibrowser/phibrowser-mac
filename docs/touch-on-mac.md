# Touch on Mac

Scope: how Phi's native UI responds to direct touch on a Mac with a touch
display or a Sidecar-connected iPad (macOS 27). Web content is out of scope
until Chromium handles direct touch; it relies on AppKit's mouse emulation.

## Platform rules Phi depends on

- Direct touches reach AppKit only through gesture recognizers. Event
  monitors, `sendEvent(_:)` and the responder chain never see them.
- Views that override `mouseDown(with:)` get single-finger mouse emulation:
  a tap is a click, touch-hold-then-move is a drag, and touch and hold is a
  right click (seen on the sidebar list and tab strip tabs, 2026-11-16).
  Non-AppKit content (Chromium) also gets one-finger momentum scroll and
  two-finger pinch/rotate as trackpad magnify/rotate.
- Emulated mouse events reach local event monitors: tapping another split
  pane moves focus (monitor in `SplitPaneHostView`) and tapping the page
  closes the omnibox dropdown (device test 2026-11-16, I4/I5; inference
  from those results).
- Touch has no hover. `NSTrackingArea`, `mouseEntered` and `.onHover` are
  pointer-only.
- `NSGestureRecognizer.allowedTouchTypes` defaults to `.direct` from macOS 27.
- Phi does not set `NSIsTouchNative`; that would turn off the extra emulation
  Chromium content depends on.
- Never add a direct-touch recognizer to an ancestor of the web content (for
  example the window's content view). Doing so made taps on web pages stop
  working (TOUCH-011).
- A direct-touch recognizer that begins on touch-down (for example an
  `NSPressGestureRecognizer` with `minimumPressDuration = 0`) stops mouse
  emulation for its view: click, double-click, drag and touch-and-hold
  right-click all go missing, and each would have to be rebuilt by hand
  (TOUCH-001, TOUCH-012). Recognizers that only observe, or recognize on
  touch-up and simultaneously with others, have not caused this. Inferred
  from device tests, not stated by Apple.
- Touch and hold is emulated as a left mouse down at touch-down, then a
  right mouse down about 0.7 s later. Each is hit-tested with
  `NSApp.currentEvent` set to it (the left mouse down has pressure 0). If
  the view hit for the left mouse down hands it to the system titlebar, the
  titlebar takes the touch and no right mouse down follows (probe logs,
  2026-11-16). No `NSEvent` property marks a mouse event as coming from
  touch.

References: Adopting gesture recognizers in your app, Handling AppKit
gestures, TN3212, TN3216, HIG Pointing devices ("Touch support for hidden
controls") and Gestures.

## Shared helpers

`Sources/UserInterface/Common/TouchInteraction.swift`

- `TouchTapObserver` — touch-only tap recognizer (`buttonMask = 0`) that
  recognizes simultaneously with everything else, so mouse input and the
  view's own click handling are untouched. Its optional `onTouchBegan` runs
  when a finger lands, before that touch's tap or emulated click is handled.
- `TouchPressObserver` — reports a direct touch landing and lifting off (or
  moving more than 5 pt) for press feedback. It never begins; it fails when
  the touch lifts, moves or is cancelled, so the view keeps mouse emulation.
  It ignores mouse input.
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
| TOUCH-001 | Sidebar tab and bookmark rows | Press-scale recognizer sets `allowedTouchTypes = []`; both rows animate on touch through `TouchPressObserver` | Tab rows verified with touch; bookmark animation not yet |
| TOUCH-002 | Common | Added `TouchTapObserver`, `TouchPressObserver`, `PointerMotionObserver` and `revealsOnTouchTap` | Covered by the entries that use them |
| TOUCH-003 | Sidebar | A tap reveals the tapped row's close control and the sidebar hover controls | Verified with touch (B6, C2, D1); D3–D6 not checked |
| TOUCH-004 | Tab strip (Comfortable) | Touch input shows the active tab's close button | Tab taps, drags and menus unaffected (E1–E3); close reveal (E4) not checked |
| TOUCH-005 | Sidebar tab group header | Tap reveals the group close button; it closes only once revealed; 36 pt close target under touch | Verified with touch (D2) |
| TOUCH-006 | Sidebar Peek indicator | Touch-revealed rows show the indicator's minus glyph | Built, not verified with touch |
| TOUCH-007 | Downloads list rows | Direct-touch tap reveals the row's action buttons for 4 s | Built, not verified with touch |
| TOUCH-008 | Split pane move grip | Grip pill shows while a finger is on it, hides after 3 s unless dragging | Not verified; see Known issues |
| TOUCH-009 | Sidebar bookmark context menu | Added "Close Tab" for opened bookmarks | Verified with touch (C3) |
| TOUCH-010 | Extensions list | Touch and hold opens the extension context menu (pin/unpin) | Built, not verified with touch |
| TOUCH-011 | Sidebar, tab strip | Fix: removed the window-level tap recognizers that broke taps on web content | Verified with touch (A1, A3) |
| TOUCH-012 | Sidebar tab rows | Replaced PR #324's touch handling with TOUCH-001; touch and hold opens the menu again | Verified with touch |
| TOUCH-013 | Top address bar (Balanced, Comfortable) | A tap on the trailing controls' area puts the bar in its hover state for 4 s | Verified with touch |
| TOUCH-014 | Edge-to-edge window drag notch (Performance) | Tap anywhere in the top 20 pt of the page to reveal the handle for 4 s. Drag or double-tap the visible handle using the native titlebar gestures. | Hit routing and timeout covered by XCTest; pending device verification |

### TOUCH-001 — Keep press-scale recognizers off direct touch

- Files: `BookmarkCellView.swift` and `SidebarCellViews.swift`
  (`setupPressAnimation`), `TouchInteraction.swift` (`TouchPressObserver`).
- Problem: both rows add an `NSPressGestureRecognizer` with
  `minimumPressDuration = 0` purely for the press-scale animation. From
  macOS 27 it also accepts direct touches and begins on touch-down, where it
  can win against the row's click emulation and against sidebar scrolling.
- Change: `allowedTouchTypes = []`, the pre-macOS 27 default. Mouse behavior
  is unchanged. Both rows get the press-scale animation under touch from a
  `TouchPressObserver`, which does not take the touch. A touch press on a
  bookmark row also closes its folder preview, as a mouse press does; folder
  rows do not scale, as with the mouse.
- Verified with touch (2026-11-16, tab rows): tap selects with the press
  animation, panning scrolls, hold-then-move reorders, touch and hold opens
  the menu. Bookmark row animation: built, not yet verified.

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
  - A tab row drops its reveal when its tab stops being active, so a link
    tapped on the page that opens a new tab hides the old row's close
    button (device test 2026-11-16, B6).
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
- 36 pt target: the close zone is 24 pt. While the close is armed for
  touch, `TabGroupHeaderHitTargetResolver` expands it to 36 pt around the
  button (device test 2026-11-16, D2: "hard to hit"). The pointer keeps the
  24 pt zone.
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

### TOUCH-010 — Extensions list: touch and hold opens the context menu

- Files: `ExtensionList.swift` (`ExtensionGridItem`).
- The pin button in the extensions popover appears only on hover, but a tap
  on an extension runs it and dismisses the popover, so a reveal tap cannot
  work there. Pin/Unpin is in the extension's context menu.
- Problem (device test 2026-11-16, H1): touch and hold opened no menu. The
  right-click overlay `SecondaryClickPassthroughNSView` only claims a hit
  test while `NSApp.currentEvent` is a right mouse event, and the item is
  SwiftUI, which takes touch natively instead of through mouse emulation.
- Change: on macOS 27 a high-priority `LongPressGesture(inputKinds:
  .directTouch)` calls the same `onSecondaryTap` as a right-click.
- Open: the menu is placed at `ExtensionPopupAnchor.mouseFallback()`, the
  cursor location; check where it appears after a touch.
- Verify: touch and hold an extension (menu with Pin/Unpin), tap it (runs as
  before), tap the pin badge of a pinned extension (unpins).

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

### TOUCH-012 — Sidebar tab rows: replace PR #324's touch handling

- Files: `SidebarCellViews.swift` (`SidebarTabCellView`, `TabCellDelegate`),
  `SidebarTabListViewController.swift`, `TabGroupCellView.swift`.
- PR #324 (issue #323) fixed tab activation and sidebar scrolling under
  touch by keeping the press recognizer on direct touch
  (`isCancellableByScrollGesture = true`) and adding a touch-only
  `NSClickGestureRecognizer` that activated the tab through
  `TabCellDelegate.tabCellDidRequestActivation`.
- Problem (device test 2026-11-16): with the PR, touch and hold on a tab row
  opened no menu (B5), and double-click-to-close did not work by touch.
  Bookmark rows, which use TOUCH-001, opened the menu (C3).
- Cause (inference): the press recognizer begins on touch-down and stops
  mouse emulation for the row. The PR rebuilt activation and scrolling by
  hand; the right-click and double-click that emulation also provided were
  not rebuilt. A touch-only long press that popped the menu by hand did not
  help either (cause unknown).
- Change: tab rows use TOUCH-001. The PR's tap recognizer, gesture delegate
  methods and both `tabCellDidRequestActivation` implementations are removed.
- Verified with touch (2026-11-16): tap selects (with press animation, see
  TOUCH-001), panning scrolls, a tab in a group selects, hold-then-move
  reorders, touch and hold opens the menu. Double-click-to-close by touch is
  not yet checked.

### TOUCH-013 — Top address bar trailing controls

- File: `WebContentAddressBar.swift`.
- Problem (device test 2026-11-16, I1): Reader, Site Memory, Copy URL and
  the "…" menu button show only while the pointer hovers the bar. Site
  Memory and the "…" menu have no other entry point in these layouts.
- Rule (HIG, "Touch support for hidden controls"): a tap on a hidden
  control's general location reveals it without activating it; hide it when
  the person finishes or after a few seconds.
- Change (macOS 27): a transparent surface over the trailing controls takes
  a direct-touch tap while they are hidden and sets `isTouchRevealed`. The
  bar's hover state is `isHovering || isTouchRevealed`, so the whole bar
  highlights and the controls appear. Once shown, the surface stops hit
  testing and taps reach the controls. The reveal ends after 4 s; while the
  Site Memory or "…" menu is open the bar stays in hover state, and the
  countdown restarts when the menu closes.
- Known: with Reader View active its button is visible, yet the first tap on
  it only reveals the others.
- Verify: tap the trailing area (bar highlights, buttons appear, nothing
  runs); tap "…" within 4 s (menu opens, bar stays highlighted until it
  closes, then hides after 4 s); tap Copy URL (copies); with a mouse, hover
  and click behave as before, also in a background window.

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

## Known issues

### Split pane drag by touch (F2): left as is

- Decision (2026-11-16): no change to split pane dragging for now.
- Device test (F2): resizing with the 4 pt divider is hard by touch.
- Incident (2026-11-16, Sidecar, while testing split drags; no repro steps):
  the Phi Canary window stopped responding to touch and clicks, and clicks
  did not make it key.
  - Facts from the logs: after the split was created (15:11:40) and panes
    were tapped (15:12:16–18), key left the window at 15:12:27. No click made
    it key again for about seven minutes. At 15:19:44 a Dock reopen
    (`applicationShouldHandleReopen`, `_handleActivatedEvent`) made it key
    and it recovered. The main thread was idle the whole time (no modal or
    tracking loop). No pane-to-sidebar drag session (`beginDraggingPaneAsTab`)
    was logged. No gesture recognizer errors were logged.
  - Inference (unconfirmed): a stuck gesture recognizer holding its exclusive
    view matches the symptom (macOS 27 release notes). It does not match
    AppKit's automatic cancel of stuck gestures after a few seconds.
    Candidates near the split: `TouchTapObserver` on `PaneMoveHandle`
    (TOUCH-008) and `TouchPressObserver` (TOUCH-001), which never reaches a
    terminal state for mouse input.
  - To diagnose a recurrence, set these before relaunching, then remove
    them:
    `defaults write com.phibrowser.canary.Mac NSCrashOnStuckGestureTimeout -int 2`
    and
    `defaults write com.phibrowser.canary.Mac NSGestureRecognizerCrashOnMissingOverrides -bool YES`.

### Tab strip empty area: no touch-and-hold menu (Comfortable)

- Symptom (2026-11-16): touch and hold opens the strip context menu over the
  right-button cluster and the Space chip, but not over the empty strip next
  to the New Tab button.
- Cause: the empty strip hands a left mouse down to the system titlebar
  (`TabStrip.shouldConsumeHitTest`) so it can drag and zoom the window. Touch
  and hold starts with a left mouse down, so the titlebar takes it and the
  right mouse down never comes (see Platform rules).
- Decision (2026-11-16): keep it. Dragging the window from the strip matters
  more; the same menu opens from the right-button cluster and the Space chip.
  Claiming the area for touch would need a touch marker on the event, which
  AppKit does not provide, and would lose touch window drag and double-tap
  zoom there.

## Pending, needs on-device facts first

- `hitTest` overrides gated on `NSApp.currentEvent?.type`. A touch is
  hit-tested with the emulated left mouse down, then, for touch and hold,
  the right mouse down (see Platform rules). Checked on device: Space chip
  and strip, pinned extension icons (I2), titlebar drag and double-tap zoom
  (I3), top address bar (TOUCH-013). Not checked: `HoverableButton`
  secondary-click containers (touch-and-hold menus) and `EventBlockBgView`.
- Outside-tap handling for Peek, Reader View and the theme editor (I6).
- Space swipe and media-card swipe driven by `scrollWheel` (I8).
  Back/forward swipe on web content works (I7).

## Pending, needs a design decision

- TODO: floating sidebar under touch (collapsed sidebar, Balanced and
  Performance). It shows only when the pointer enters the 10 pt edge strip
  (`FloatingSidebarHostViewController.floatingSidebarTriggerView`, an
  `NSTrackingArea`) and hides when the pointer leaves, so touch can neither
  open nor close it. A tried and reverted approach (2026-11-16, not tested
  on device):
  - Show: a `TouchTapObserver` on the edge strip. The strip sits in the
    overlay beside the page, so this is safe for the page's mouse emulation
    (TOUCH-011). Keep the strip at 10 pt; a wider one would take page clicks
    at the edge from the mouse.
  - While touch keeps it open (a `PointerMotionObserver`), skip the
    pointer-driven hide. Close it on a tap outside the panel (the overlay
    takes that click so it does not reach the page; only the overlay's own
    hits, since strip and panel-inset clicks reach it through the responder
    chain), on a focused-tab change, or on pointer motion.
  - Later, maybe an inward swipe from the edge; check first that the system
    takes no edge gesture there.
- Custom traffic lights: glyphs only on hover, 16 pt targets; the right-side
  sidebar's hover-revealed window-controls bar (dev #308) has the same issue.
- 36 pt touch targets for 24 pt and smaller controls: touch only, or larger
  for the pointer too. Group header close is done for touch (TOUCH-005).
- Split divider (4 pt, `DividerHandle`): device test 2026-11-16 (F2) found it
  hard to resize by touch. A touch-only wider target needs a recognizer on
  the divider or a wider divider for the pointer too. On hold, see Known
  issues.
