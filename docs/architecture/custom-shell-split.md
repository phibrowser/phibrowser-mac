# Custom shell split

Status: built. The shell lays its split out itself, with the width model,
divider, sides, storage and toggle state described here, and the toggle
slides on the render server.

The shell window's sidebar | page split was an `NSSplitView` inside an
`NSSplitViewController`. Its collapse animation was main-thread layout: AppKit
laid the window out on every animation frame, and each pass resized the page
area, the presented page tree and the Chromium content surface. The custom
split places its views by frame, changes model geometry once per toggle, and
moves layers on the render server for the motion.

Standalone Incognito windows (`MainSplitViewController` with
`isHosted == false`) keep `PhiSplitViewController`. Chromium is not changed.

## What the NSSplitView shell did

Recorded by `ShellSplitCharacterizationTests` as of commit `7d301921`, before
the custom split. `W` is the window's content width, `S` the sidebar width.

Width and window width
- Limits: sidebar 193…500, page area at least 200.
- While the page fits, a window resize leaves `S` alone.
- When it does not, the sidebar is squeezed: `S = max(193, min(set width, W − 200))`.
  Growing the window gives the width back, as long as the shell stays open.
- The squeezed width replaced the remembered one: `lastExpandedSidebarWidth`,
  the floating panel's width and the stored frames all took it, so a relaunch
  in a wide window opened the sidebar at the squeezed width.
- The split's constraints stopped a programmatic resize at 393 (expanded) or
  200 (collapsed). `ShellWindowController` separately sets `minSize.width = 400`.
- Expanding where the page cannot give the column its width widened the window
  by the whole column (449 → 699 for a 250 column). At 450 it did not.
- The floating panel's width was `lastExpandedSidebarWidth`, whatever the
  window width: 500 in a 400 window.

Toggle
- Collapsed state and reported width change once, when the animation starts.
  `isSidebarExpanding` holds from an animated expansion's start to
  `sidebarExpansionDidFinish`, which fires once. A collapse reports neither, and
  a superseded expansion never reports its end.
- The column kept its width while it slid; the page area's frame changed on
  every frame (5–6 changes per toggle headless, more on a display).
- Reversing a collapse landed expanded at the same width. Reversing an
  expansion landed collapsed but lost the width: the sidebar next opened at the
  width it had reached, or at 193. (Defect.)

Divider
- Takes a press within 7pt of the column's inner edge, over the whole window
  height including the titlebar band. None while collapsed.
- A drag is live, keeps the pointer's offset, and stops at 193, 500 and
  `W − 200`. The width it ends on stays when the window grows.
- Below 96.5pt the column slides out over 0.22s with `cubic-bezier(0.1, 0.4, 0.6, 1)`,
  or closes immediately with Reduce Motion. Dragging back to 96.5pt in the
  same gesture reopens it and resumes live resizing. Releasing while collapsed
  preserves the previous preferred width.
- Double-click does nothing. Accessibility exposes one `AXSplitter` whose value
  is the divider's position.

Sides and layout modes
- A side switch keeps the collapsed state. Each side takes its own width from
  the account's defaults; with none stored the current width moves along.
- The comfortable layout keeps the column collapsed whatever asks. Leaving it
  always opens the column, even one the user had collapsed before.

Persistence
- Width and collapsed state came back through NSSplitView autosave:
  `NSSplitView Subview Frames phiMainBrowserSplitView` / `…Right` in standard
  defaults, two strings `"x, y, w, h, hidden, …"` in subview order (the column
  is entry 0 on the left, entry 1 on the right).
- Every shell window stored under the same name; the last to change won.
- The comfortable layout's forced collapse was stored like the user's own. A
  shell launched in the comfortable layout then restored the column at zero
  width, and the stored width was gone when it opened. (Defect.)
- `recordSidebarWidth` wrote the column's frame width to the account 0.3s
  after it settled, squeezed or not, and never wrote 193. (Read from the
  source; the test host has no local-data account.)

## View hierarchy

```
ShellSplitViewController.view            TitlebarTransparentView
├─ ShellSplitView                        placed by frame from ShellSplitGeometry
│   ├─ contentHost.view                  page area, at the back
│   ├─ sidebarHost.view                  column, above the page area
│   └─ ShellSplitDividerView             14pt strip, on top
├─ toast overlay
└─ floatingSidebarHost.view
```

`sidebarHost`, `contentHost` and `floatingSidebarHost` are the same
controllers with the same views as before, so the Space-switch band slide, the
hosted capture and the session install/conceal paths work on them unchanged.

The column sits above the page area because the two overlap while the column
is collapsed or a toggle is in flight. Both paint the same material.

## Who owns geometry

- `ShellSplitGeometry`, a value type: side, preferred width, and whether the
  column takes page space, in; effective width and the column, page and
  divider frames for a container size, out. Pure.
- `ShellSplitView` places its three subviews in `layout()` from that value.
  No constraint ties the column to the page, so a live window resize costs one
  frame assignment for the page area. Its frames are never implicitly
  animated, and each pane clips to its frame, as NSSplitView's did: without
  that a pane's `visibleRect`, and every `.inVisibleRect` tracking area in it,
  is the whole window. It also runs a toggle's slide. It knows nothing about
  Spaces or the shell; a standalone window can adopt it later.
- `SidebarTransitions`, a value type: the collapsed state and the toggle in
  flight. Pure.
- `ShellSplitViewController` keeps the state (preferred width per side, the
  transitions, a divider drag in progress), the publishers, storage and the
  hand-off. It is the only writer of sidebar geometry.

`sidebarCollapsedPublisher` and `sidebarWidthPublisher` are fed from that
state, not from frame notifications: one value per toggle, one per drag step,
one per window resize step that squeezes the column.

`isSidebarExpanding` and `sidebarExpansionDidFinish` are on
`ShellSplitViewController`; `MainSplitViewController` forwards them, to the
shell or to its own standalone split.

## Width model (D1, decided)

- `preferredWidth`, per side: the width the user chose. Set only by a divider
  drag, a floating panel resize, a step on the accessibility splitter, or
  `setSidebarGeometry`. A side that never had one takes the other side's
  along on the first switch.
- `effectiveWidth = max(193, min(preferredWidth, 500, W − 200))`.
- Window resizes, full screen, tiling and session restore change only the
  effective width. Only the preferred width is stored, 193 like any other.
- `lastExpandedSidebarWidth` is the effective width the column would open at
  in this window, which is the floating panel's width: the panel leaves the
  page its minimum as the column does, and a panel resize stops there.
- A drag that ends collapsed leaves the preferred width alone.
- The split sets no floor on its container. `minSize.width = 400` keeps the
  page at its minimum; below that the page gives way before the sidebar's
  minimum does.

Window widening (D2, decided: kept). Expanding where the page cannot give the
column its preferred width widens the window by the whole column, as the
NSSplitView did, and the column opens at its preferred width. Not in full
screen, where the column opens squeezed. Two expansions do not widen: one
that reopens the column within a divider drag, and a dock hand-off, which
opens the column where the floating panel is, at the panel's width.

## Transitions

`SidebarTransitions` holds the collapsed state as last asked for and at most
one flight. Requests:

| request | no flight up | flight to the same state | flight to the other state |
|---|---|---|---|
| animated, other state | state flips; new flight | n/a | state flips; old flight superseded; new flight starts from where the column shows |
| animated, same state | nothing | nothing | n/a |
| immediate, other state | state flips | n/a | state flips; old flight superseded |
| immediate, same state | nothing | flight lands now | n/a |

- The state flips when a toggle starts, once per toggle.
- A flight starts from the fraction of the column showing and takes that
  share of the toggle's duration (a reversal's duration is scaled to the
  distance left).
- `columnTakesPageSpace` is true only when expanded with no flight up. The
  page area has the container's full width otherwise, so a collapse changes
  the page area's size when it starts, an expansion when it lands, and a
  reversal not at all.
- A superseded flight's landing is ignored. Each call's completion runs
  exactly once: `true` when its state was reached (at once if there was
  nothing to do, or if an immediate request landed it), `false` when a
  request for the other state cut it short.
- `isSidebarExpanding` is "an expansion flight is up". A superseded expansion
  never sends `sidebarExpansionDidFinish`; one landed early by an immediate
  request or by a settle does.
- A change that is not a toggle settles the flight first: a divider drag, a
  side switch, a container width change, a step on the accessibility
  splitter.
- A toggle finishes a dock or undock hand-off at once, then starts from its
  end state.

Any number of rapid toggles therefore ends in the state the last one asked
for, with one flight up and no jump.

A flight is `ShellSplitView.slideColumn`'s to run: it adds the layer
animations and reports back when they end. The fraction showing comes from the
column's presentation layer. A flight with no distance to cover, or in a
window that is not on screen, is placed instead and reports back on the next
turn of the main queue.

### What a toggle costs its observers

`sidebarCollapsedPublisher` is not coalesced: its consumers have to see the
state at the start of the toggle it belongs to. They are the traffic lights
(`SpaceSessionController`, already delivered on the next main-queue turn),
the floating host's availability, the sidebar header, the page header's
borrowed buttons, the placeholder shell, the side address bar, the sidebar
and floating sidebar controllers, and the page tree's sidebar-side inset
(`WebContentViewController`, `WebContentContainerViewController`). Each does
bounded work per flip. The inset is the one that lays the page out, which is
why it follows `columnTakesPageSpace` instead (below).

Storage is coalesced: a burst of toggles writes the collapsed flag once,
`geometryPersistDelay` after the last one and never while a flight is up,
and not at all when the burst ends where it began.

## Animation

### Constraints that fix the timing

The page may be laid out a few times per toggle but not per frame, and
there is no way to snapshot a page (its pixels live in Chromium's CAContext).
`columnTakesPageSpace` is false for the whole flight: the page area's model
frame spans the container and stays there, and an expansion insets the page
in its card on the column side (`ShellSplitView.pageInsetInFlight`, applied
by `WebContentViewController.sidebarInsetInFlight`), following the column
(`stepPage`, below).

Chromium draws a width a few frames after AppKit lays it out, so the page is
never laid out short of what the card shows: the card between the column and
a page laid out ahead of it is bare, a strip in the card's color down the
whole page, toolbar included.

### Motion (D4, decided: reveal)

The column slides over a page area that stays put, and a mask on the page
draws the card's near edge beside the column. The page tree is laid out for
the page area's in-flight frame; the mask hides it up to where the card's
near edge is on screen, with the card's near corners rounded there.

- The page area's far side does not move: the card's far edge, the toolbar's
  trailing buttons and a docked chat panel stay where they are.
- The card's near edge and corners travel with the column, `m` (the card's
  margin, `WebContentLayout.edgeSpacing`) from the column's inner edge with
  the column away, at it with the column in.
- A collapse uncovers the page. It is laid out at the landing's width as
  the toggle starts, so Chromium draws that width once, the part still under
  the column included, and the column slides off a page already in place.
  Until that frame comes the card shows between the column and Chromium's
  last one (Content surface lag).
- An expansion covers the page. Every `ShellSplitView.pageStepInterval` (a
  fifth of the toggle) the page is laid out to where the column is on
  screen, read from its presentation layer, until the column is all in. The
  page's near side is at the column or under it, never ahead, and little or
  no width is left for the landing. The page trails the column by a step
  and the frames it takes to draw, and settles a few frames after the
  column stops.

Push, which this replaced, translated the page area's layer so its near edge
stayed under the column. It kept left-anchored content travelling with the
column and the stale frame's gutter off-window, but slid the far side, with
the toolbar's trailing buttons and a docked chat panel, off the window for
the whole slide.

### Frame by frame

`p` is the eased progress (0.11s, `SidebarToggleAnimation.timingFunction`).
Offsets are explicit `CABasicAnimation`s on `transform.translation.x` under
`ShellSplitView.slideAnimationKey`, on the column's layer and on the mask of
the presented page tree's layer (`ShellSplitView.SlidingPageCard`, supplied
by `ShellContentHostViewController.slidingPageCard`); model frames do not
move during the flight. `m` is the card's margin.

Left sidebar, collapse:

| when | model | on screen |
|---|---|---|
| start, one pass | collapsed flips; page area frame → `[0, W]`, the page `[m, W]` in it; column stays `[0, S]`, visible | column offset 0, card edge at `S` |
| in flight | nothing | column offset `−S·p`; card edge at `S − (S − m)·p` |
| end | column hidden; animation and mask removed | page at `[0, W]`, card edge at `m` |

Left sidebar, expand:

| when | model | on screen |
|---|---|---|
| start, one pass | collapsed flips, `isSidebarExpanding` on; column unhidden at `[0, S]` | column offset `−S`, card edge at `m` |
| every fifth of the duration, until the column is in | page inset → `(S − m)·p` as the column shows it then | |
| in flight | nothing else | column offset `−S·(1 − p)`; card edge at `m + (S − m)·p` |
| end | page area frame → `[S, W]`, page inset → 0, the page's width unchanged; animation and mask removed; `sidebarExpansionDidFinish` | column `[0, S]`, page `[S, W]` |

Right sidebar: the same with the signs reversed, and the page area ends at
`[0, W − S]`.

Two earlier versions laid the page out five times in both directions, each
a step ahead of the slide. On an expansion that put the page's near side
ahead of the card's edge, and up to a step of bare card showed between them
on every expansion (measured 12–188px wide, toolbar row included). On a
collapse each step was one more width for Chromium to draw, and its frames
ran behind the column for the whole slide; laid out once, its frame is
there in the slide's first frames. What the bare card shows is the page's
own background while the card holds one page and the separated frame's
color beside an AI Chat, which is why the strip read as white with the chat
closed and was hard to see with it open. The first of those versions stepped
the page area's own frame: what its lag uncovered was the window behind the
page area, with the card's 8pt margin beside it.

The animations hold their end value and are removed (`endSlide()`) in the
turn the frames take their end state, so a late main thread delays only the
final layout, never a frame. The landing is the animations' own completion;
a timer lands the flight 0.3s after its duration if that never comes.

The start of a toggle still waits for one pass: the state change, its
observers and a collapse's page layout land before the first frame commits.
An expansion's steps run on the main queue; a busy main thread delays a
step, which leaves the page further under the column, never the slide.

A reversal reads the column's offset from its presentation layer as the shown
fraction, and replaces the animations with ones from there. The presentation
layer only knows what Core Animation has committed, so for a slide added in
the current turn of the run loop the fraction is that slide's start instead
(`uncommittedSlideStart`, cleared after the turn's commit).

### The page's sidebar-side inset

The page tree insets its card by 8pt on the sidebar side when collapsed
(`WebContentLayout.pageInsets(sidebarCollapsed:)`). Keyed off the collapsed
flag, which flips at the start of both directions, an expand laid the page
out at the start (inset) and again at the end (width). The inset follows
`columnTakesPageSpace` instead, as `BrowserState.sidebarTakesPageSpace` and
its publisher: `WebContentViewController.updateSplitViewLeadingInset` (with
the card's edge shadow), `WebContentContainerViewController.pageAreaInsets`
and `PlaceholderShellViewController.contentInsets` read it, and their
observers run in the turn it changes, which is the turn the page area's
frame changes. Everything else keeps reading the collapsed flag.

### Interruptions beyond a toggle

- The window starting into or out of full screen settles the flight, as any
  change of the container's width does.
- Space switch: not an interruption. The band slide and the page slide animate
  descendants of the column and the page area; the split animates the
  column's own layer and the mask of the page tree presented when the toggle
  started, which the page slide's transform leaves alone. A page tree
  presented mid-flight is unmasked until the toggle lands.
- Window widening (D2) happens, and is laid out, before the flight starts, so
  it does not settle the flight it belongs to.

### Content surface

`ContentSurfaceHosting` keeps reporting model rects. The surface's view is
inside the masked page tree, so the mask cuts the page's pixels with the
card. The animations never touch `bounds`, so `clippingRect(of:)`'s
presented-width rule does not trigger.

The surface's view is pinned to the card on three sides and to the window's
edge on the sidebar's side, where the page area clips it
(`WebContentContainerViewController.pinContentSurfaceToPagePanel`), so the
sidebar never moves or resizes it. Pinned to the card it moved when the card
did, and Chromium's last frame, drawn where the surface was, moved with it:
a docked AI Chat shifted, and the page's wider frame ran over it, until
Chromium drew again. A clip to the card could not stop that; the chat is in
the same surface.

## Hand-off

`handOffSidebar(collapsing:completion:)` keeps its shape: the column change
and `floatingSidebarHost.animateSidebarHandOff()` in one animation group, the
residents at alpha 0 under the panel, the run counter guarding the group's
completion. The column's slide and the panel's glide are explicit animations
added in the same turn with one duration and one curve, so they begin on the
same commit and move as one.

A dock opens the column at the panel's width, which is the effective width,
and does not widen the window. With no `pendingDockWidth` any more (a panel
resize sets the preferred width directly), pinning from a panel that was just
resized hands off like any other pin; it used to expand without the hand-off.

There is no explicit begin time. One commit already gives both the same
start; a begin time taken before the commit would make both skip whatever the
main thread spent getting to it, on a curve that covers most of its distance
early.

The floating panel later reusing the docked resident view plugs in here: the
column is already a view above the page, so the panel would be a third
placement of it in `ShellSplitGeometry`, not a second sidebar tree.

## Divider (D5, decided)

`ShellSplitDividerView`, 14pt centred on the column's inner edge, hidden while
collapsed or in flight. It is a `FloatingSidebarResizeHandleView` (press, drag,
release, one-way cursor at a limit), so the panel's edge and the column's edge
are one control. `TitlebarTransparentView` returns a descendant hit, so the
titlebar band works.

- The drag is live and clamped to 193 … `min(500, W − 200)`; the width it ends
  on becomes the preferred width.
- Crossing below half the minimum starts the collapse. The divider keeps
  tracking until mouse-up, including while the column is hidden.
- No divider on a collapsed edge; the floating trigger owns it.
- Double-click does nothing.

Accessibility: the split view is an `AXSplitGroup`; the divider an `AXSplitter`
whose value, minimum and maximum are divider positions, with increment and
decrement moving it 10pt.

## Storage and migration (D3, decided)

- Width: `AccountUserDefaults.setLastKnownSidebarWidth(_:for:)`, per side,
  preferred width only.
- Collapsed: `PhiPreferences.GeneralSettings.sidebarCollapsedKey` in the app's
  standard defaults; one flag for both sides, every shell window and every
  account.
- Both are written `geometryPersistDelay` (0.3s) after the last change, never
  while a flight is up, and at once when the window closes or the app quits.
  A write to the app's defaults notifies every Space's observers, so the flag
  is written only when it differs from what is stored.
- The comfortable layout's collapse is an override and is never written.
  Leaving the comfortable layout always opens the column, and that is written.
- Migration, once, when the flag is absent: read the NSSplitView frames
  autosaved for the effective side; take `hidden` as the flag unless the
  layout is comfortable, where it is the layout's; take the width, if within
  the limits, as that side's preferred width. The flag is written at once so
  the frames are not read again: standalone windows still autosave under the
  same names, which is also why the old keys are left in place.
- The shell has no autosave name, so nothing is written during a toggle.
- `snapshotSidebarWidth()` and `ReopenLoadingWindow` keep reading
  `sidebarWidth`, the effective width. The first `layout()` computes it from
  the preferred width and the bounds, so a restored window does not step.
- Shell windows keep sharing one stored state, last writer wins.
- A closed shell window stops following the app's defaults
  (`windowWillClose()`), so it cannot store over the open windows' state.

## Residents

Residents keep `heldWidth`: a hidden one must not follow a divider drag. They
are pinned to the column and nothing else. The NSSplitView shell also pinned
hidden ones to the split view's edge, because AppKit slid the column's frame
on every animation frame; the column now slides by its layer and its frame
stays put. Page trees keep catching up in `install`.

## Measured

Time Profiler on a Debug build opened directly, one window 1311×812, 24 menu
toggles × 2 rounds, against the NSSplitView build `1626c8be` under the same
conditions.

| per toggle | NSSplitView | custom split |
|---|---|---|
| main thread | 182ms | 108ms (−41%) |
| `_layoutViewTree` | 100% | −89% |
| CA commit | 100% | −77% |
| `NSHostingView` | 100% | −92% |
| page `viewDidLayout` rounds | 5.9 | about 1.0 |

60fps screen recordings: collapse and expand advance on every frame, with no
gap or misplaced frame, and the Chromium page stays in its card.

What is left on the main thread is about 1.4 long stretches per toggle, at its
start and about 100ms after it, and none of it is the split's; see the
follow-ups.

## Follow-ups

- Traffic lights. Each toggle hides or shows them:
  `refreshTrafficLightVisibility` → `setTitlebarButtonsHidden` retiles the
  titlebar (about 11ms), `TrafficLightPositioner` runs its pre-flush pass
  (about 12.6ms), `SidebarTrafficLightsView.reinstall` (about 4.4ms).
- `ContentSurfaceHosting.update`, about 24ms per toggle in Debug.
- Content surface lag, below.
- Standalone Incognito windows still use `PhiSplitViewController`.
  `ShellSplitView`, `ShellSplitGeometry` and `SidebarTransitions` know nothing
  of the shell; moving `MainSplitViewController`'s own split onto them means
  giving it the state `ShellSplitViewController` keeps, and its own storage
  instead of the autosave names.
- The floating panel reusing the docked resident sidebar instead of a second
  tree per Space (see Hand-off).
- The column's and the page area's backdrops are tinted from the wallpaper
  behind them by position. While the column slides, it carries the tint of
  where its frame is, so the page's margin can read a shade off the column's
  until the toggle lands. Not measurable in the recordings' frames.

## Content surface lag

Chromium draws a resized page a few frames after AppKit commits, so a growing
page shows a backdrop gutter and a shrinking one overflows. Nothing here hides
it. With one resize per toggle instead of one per frame, the options later:

| option | hides | cost |
|---|---|---|
| Resize while the far side is off-window (push did this) | all but a far-edge strip on collapse; everything on expand | slides the far side, toolbar buttons and a docked chat panel off-window; dropped for the reveal |
| Hold the surface's view at its old frame until the new one is drawn (`isHeld` exists for the side panel) | overflow on shrink | cannot fill a gutter on grow; needs a drawn-at-size signal from Chromium |
| Snapshot the page for the transition | both | Chromium has to supply it; async, costs the frames it saves |
| Chromium-side resize sync: hold AppKit's commit for the surface's frame, with a timeout | both | Chromium change; one bounded wait per toggle, a stall if the timeout is long |
| Stretch the stale frame to the new size | gutter | Chromium change; a brief distortion |

The resize sync is the one to pursue: once per toggle it is a bounded cost.

While a toggle is in flight the backdrop takes the page's own background
(`PhiChromiumBridge.pageBackgroundColorForTabId:windowId:`, the primary
page's reported background), so a gutter past Chromium's last frame shows
the page's color, not the card's. That covers the surface's own gutter only,
and only for a card holding one page: a split's other pane or the AI Chat
shows the backdrop through its clear fill, and keeps the card's color.
A renderer's first frame at a new width often shows the page's root
background where its content has not been rasterized yet; that strip is
Chromium's, and on a page with a light root under a dark hero (What's New)
it stays light.

## Decisions

- D1: the width model above.
- D2: expanding in a window too narrow widens the window, as before.
- D3: collapsed flag in the app's defaults, one for both sides; never written
  by the comfortable layout; leaving that layout always expands; written only
  once settled.
- D4: reveal, the page area staying put with the card's near edge masked
  beside the column. Push was picked first from recordings of both, and
  replaced because it slid the far side off the window.
- D5: crossing the threshold during a drag slides the column out from its
  minimum width. Crossing back immediately restores live resizing. A new
  drag requires an expanded column. Double-click has no action.
- A reversal's duration is scaled to the distance left.

## Known limits

- Hit testing and the sidebar's hover check follow model frames for the 0.11s
  of a toggle.
- On an expansion the page follows the column in steps, not per frame, and
  settles a few frames after the column stops. On a collapse the card shows
  beside the column until Chromium draws the page at its new width.
- A window squeezed below `S + 200` resizes the column, and the presented
  sidebar with it, on each resize step, as before.
- Widening the window (D2) and the slide in the same toggle: the window jumps
  wider, then the column slides in, and the page is laid out for the wider
  window and again at the landing.
- The widths are read from the account when the shell loads; a shell created
  before the account is available opens at 193.

## Tests

- `ShellSplitGeometryTests`: the width model and the frames, both sides.
- `SidebarTransitionsTests`: requests, reversal from several fractions, rapid
  toggles, superseded landings, settling.
- `ShellSplitCharacterizationTests`: the behaviour above on a real shell in a
  window, both sides: resize sweeps, toggles and their completions, rapid
  toggles, divider drags with real mouse events, accessibility, sides, layout
  modes, storage, relaunch and migration.
- The same suite checks the slide on a shell that is on screen: the two
  animations' values, duration and curve, the page never laid out short
  of the column with the page area in place, a reversal from the
  presentation layer at several points, the page-space signal, and landing
  by the animations' own completion.
  `SidebarDockHandOffTests` checks the column's slide against the panel's
  glide.
- Existing suites unchanged in intent: `SidebarDockHandOffTests`,
  `FloatingSidebarResizeTests`, `FloatingSidebarSpringTests`,
  `ContentFullscreenFloatingSidebarTests`, `SidebarTrafficLightsTests`,
  `SpaceSwipeTransitionTests`, `HostedSidebarStateTests`.
- Not covered by any test, and checked by hand: the divider's cursor and its
  drag in the titlebar band, drag-to-collapse with a real pointer, the
  floating panel's hover and the look of a hand-off, VoiceOver.
