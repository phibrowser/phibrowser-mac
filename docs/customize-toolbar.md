# Customize Toolbar

Balanced and Comfortable draw the page toolbar from one stored, app-wide
`ToolbarArrangement`: four zones (Left, address leading, address trailing,
Right), each an ordered list of items, plus the address bar style (Standard or
Minimal) and whether the address bar is shown. Performance has no such
toolbar. Its header draws the pinned extensions in Chromium's order with the
extensions button, and ignores the arrangement.

## Ownership

| Concern | Owner |
| --- | --- |
| Model, storage, migration | [ToolbarArrangement.swift](../Sources/UserInterface/WebContent/Header/ToolbarArrangement.swift) |
| Changes made while customizing, pin and unpin bookkeeping, the drag in flight | `ToolbarCustomizationController` in [ToolbarCustomization.swift](../Sources/UserInterface/WebContent/Header/ToolbarCustomization.swift) |
| Drawing, Escape, the sheet's lifetime | `WebContentHeader` and `WebContentHeaderView` |
| Whether an extension is pinned, and the pinned order | Chromium, through `ExtensionManager` |

## Arrangement and Chromium pins

The arrangement owns where each item sits and in what order. Chromium owns
whether an extension is pinned. A window draws an extension only while it is
pinned in that window's profile, at the slot the arrangement gives it.

Storage only ever gains extensions on its own (`addingNewPins`): a newly pinned
extension is added at the end of Right's extensions. Pins are per profile while
the arrangement is shared, so a window that drops what it does not see would
undo other windows. Removal goes through the customization controller only,
when the user drags an extension out (which also unpins it).

Chromium reports a pin or unpin some time after the request. The controller
keeps extensions placed while their pin is in flight drawn, keeps extensions
dragged out undrawn while their unpin is in flight, and settles a drag that
reverses one still in flight once Chromium reports it.

The header redraws from storage as it is when it applies a change, never from
an earlier snapshot. A stored arrangement this build cannot read is drawn as
the standard one but never written over on its own.

## Known deviations

Because storage keeps extensions it no longer sees, two cases differ from the
spec:

- An extension unpinned outside Customize Toolbar and pinned again returns to
  its old slot, not to the end of Right.
- A reinstalled extension returns to its old slot instead of starting unplaced.

## Downloads, Memory, Feedback and Toggle Sidebar in Balanced

In Balanced these three also sit in the sidebar's bottom bar. The toolbar
shows the default arrangement's copies only while the sidebar is collapsed,
as before Customize Toolbar. One the user placed while customizing (dropped
from the sheet, or moved within or between zones) shows with the sidebar
docked too; the bottom bar keeps its own copy, which its Bottom Buttons menu
hides. Each item's own conditions still apply: Memory needs Phi AI and not
incognito, Feedback a signed-in non-guest, none shows in the empty-window
placeholder. Comfortable shows all three wherever they are placed.

Toggle Sidebar follows the same rule (`WebContentHeaderState.layoutShowsSidebarToggle`):
the default copy shows only while the sidebar is collapsed, since the docked
sidebar's header has its own, and one the user placed shows with the sidebar
docked too. The sidebar header's copy can be hidden from its Top Buttons
menu. Comfortable has no sidebar, so it never shows Toggle Sidebar and the
sheet does not offer it.

The arrangement records the items the user placed (`isPlacedByUser`, stored
as `placedByUser`; missing reads as none). The default set has none, and
removing an item clears its mark. The migration and a newly pinned
extension's placement set none.
`WebContentHeaderState.layoutShowsBottomBarItem` applies the rule inside
`ToolbarItemView.isShownWhileBrowsing`, which the zones, the Right zone's
overflow fit and the address bar's reserve all read, so they agree on what is
drawn.

The sheet greys a tile out only while the toolbar draws its item
(`ToolbarItemView.isShown`, the rule the zones use). An item in the
arrangement that the view does not draw stays available: Toggle Sidebar with
the sidebar docked, and Downloads, Memory or Feedback the layout hides, which
are not drawn while customizing either. Dropping one places it, marks it as
placed by the user, and so draws it and greys its tile.

The sheet's default-set row previews what `ToolbarArrangement.standard` would
draw in the current view: its Phi items filtered by `ToolbarItemView.isShown`
with the header's state, evaluated as if the arrangement were `.standard`
(`ToolbarPalette.defaultSetItems`). Docked Balanced shows no Toggle Sidebar,
Downloads, Memory or Feedback; Phi AI off hides Memory, Chat and Site
Memories; a guest has no Feedback. It follows the header's state live. The
sheet's panel mirrors its parent window's appearance live (an Incognito
window stays dark whatever the app's appearance is).

## Migration and later builds

The first load converts the Comfortable switches `topBarShowsDownloads`,
`topBarShowsMemory` and `topBarShowsFeedback`: a button switched off is left
out. From then on the arrangement is the only source.

Unknown items and an unknown style decode leniently instead of failing: an
unknown item is dropped and an unknown style reads as Standard. Nothing is
written back while loading, but the next save from this build, the automatic
save of a newly pinned extension included, stores the result, so a build that
reads an arrangement written by a newer one loses what it did not understand.
An arrangement saved before the address bar could be removed shows it. A build
that predates the placed-by-user marks drops them when it saves, so Balanced
then hides those items again with the sidebar docked. The
stored arrangement cannot tell a removed item from one that did not exist when
it was saved. A later build that adds an item to the default toolbar needs a
record of the items each arrangement already knows about before it can add the
new one for existing users.

## The address bar

The address bar is not an item: it has no zone and only lives between Left
and Right, so it is `showsAddressBar` on the arrangement and its own drag
payload (`ToolbarDragPayload.addressBar`), not a `ToolbarItemID`. While
customizing, the whole bar is a drag source laid behind its buttons, which
stay draggable on their own. Dragged out of the toolbar it leaves under the
same rules as an item. The sheet's Address tile, greyed while the bar is
shown, puts it back from a drop anywhere over the toolbar, on a zone or not.

While it is removed, the address zones keep their placements and come back
with it. They are not drawn, so they take no drops, their buttons count as
unplaced in the sheet, and the Site Menu offers Site Memories when that
button sits in them. Left and Right sit at their edges. The empty-window
placeholder keeps its address bar.

Without the bar, `WebContentHeader.addressBarAnchorView` is a strip as wide as
an address bar, centered along the toolbar's bottom edge, so ⌘L and the share
picker drop down centered under the toolbar. A right-click anywhere on the
toolbar opens the Site Menu at the pointer, which ends with Customize
Toolbar…, in place of the menu that only offers Customize Toolbar….

Site Memories, which the Site Menu offers when its button is not drawn, opens
its menu where a right-click opened the Site Menu, not under the menu's
anchor (the invisible strip, or Minimal's slot-wide anchor).

While customizing, both styles draw one dashed outline around the bar (in
Minimal, around the centered unit) and a dashed divider at each end of the
address text, marking the leading section, the address and the trailing
section; the two sections take drops as zones, empty or not. Left and Right
keep their own outlines. All of them are overlays, so customizing moves
nothing, with one exception: every empty zone reserves real layout space, so
each shows as a place to drop and no two overlap. A zone with items is
unchanged; its outline hugs them.

- An empty Left or Right zone takes `ToolbarCustomizationLayout.emptyZoneWidth`
  (28pt) at its toolbar edge, which its outline fills.
- An empty address section takes `addressSectionReserve` next to the text,
  `emptyZoneVisibleWidth` less the divider's 1pt stroke (26pt), so that from
  the bar's outline to the far edge of its dashed divider it looks exactly as
  wide as an empty side zone's outline (27pt to the outer edges). In Standard
  the text makes room; in Minimal the reserve extends outward like a
  customize-only button (below), so the text stays put.

The padding between the address text and a section is the same in Standard and
Minimal, while browsing and while customizing, so entering or leaving
customization moves neither text nor buttons:

- Next to buttons: 8pt (`textPaddingBesideButtons`), Phi's default.
- On a side with no drawn buttons: 12pt (`textPaddingAtEnd`). That includes a
  section whose buttons draw nothing on this page or in this build, which
  `browsingRowWidths` measures while browsing.
- Between a section's outermost button and the bar's end: 0pt
  (`sectionPaddingAtEnd`).

Each dashed divider sits at the start of the text region, against the section,
so while customizing its 1pt line leaves 7pt to the text beside buttons and
11pt beside an empty side. Nothing is added for the divider, so the line fits
inside the padding browsing already has.

## Dragging while customizing

Every draggable thing (toolbar items, the address bar, the sheet's tiles and
default set) is a `ToolbarItemDragSourceView`. The toolbar sits in the
window's titlebar band, where the window server moves the window on a drag
unless AppKit leaves the pressed view out of the window's drag region, and
AppKit does that only for a view that answers `mouseDownCanMoveWindow` false
and also `acceptsFirstResponder` true. The drag source answers both, except
while AppKit dispatches a press on it (from its hit test to its `mouseDown`),
when it answers `acceptsFirstResponder` false so the window does not move
keyboard focus to it. Keying that answer to the current event alone would
also catch a drag region recomputed after a press, which lets the next press
move the window. Without the veto, only SwiftUI-drawn pixels under an item kept the window
still, so Lottie icons and every icon's margins moved the window. Empty
toolbar space still moves the window while customizing.

Over a drag source the cursor is an open hand, closed while pressed or
dragging. Leaving one source for another (an address button for the bar
around it, or the next item) keeps the hand, and a source removed under the
pointer (Done, Escape, a moved item) puts the arrow back. Toolbar items get
a hover fill in the toolbar buttons' hover color
(`ToolbarCustomizationHoverFill`), drawn behind them; the sheet's entries only
change the cursor. The Standard address bar has its own hover fill, which steps aside while
customizing when an inner button is hovered, so only one fill shows. The
Minimal unit, which has no background, draws Standard's hover color as a
capsule over the unit while browsing as well as while customizing.

### The drag in flight

A toolbar item or the address bar leaves the toolbar's layout as soon as its
drag starts, and the toolbar reflows as if it were removed: zones, address
bar, empty-zone reserves and the overflow. This is transient view state, not
an arrangement change: `ToolbarCustomizationController.draggedPayload`
(set by `dragBegan`, cleared by `dragEnded`), mirrored into
`WebContentHeaderState.draggedPayload` when the header applies the
arrangement. The view lays out `WebContentHeaderState.layoutArrangement`,
which is `arrangement` less the dragged item (or with `showsAddressBar` off)
while customizing, and `arrangement` itself otherwise. `arrangement` and
storage keep the item until the drag ends:

- Dropped on a zone: placed there. The drop clears the drag state before its
  save, so the item is drawn in its new place by the same redraw.
- Let go outside the toolbar: removed (`dragEndedOutside`,
  `addressBarDraggedOut`), which also clears the state before saving.
- The address bar let go anywhere over the toolbar it is dragged from, on a
  zone or not: taken as a drop that changes nothing stored
  (`isAcceptedOverToolbar(_:showsAddressBar:isDraggedFromToolbar:)`), which
  clears the drag state, so it is back at once.
- Anything else (Escape, an item let go over the toolbar off every zone or
  back where it started, a force-pinned extension, customizing ended
  mid-drag): nothing is saved and `dragEnded` puts it back where it was.

A drag from the toolbar never slides back
(`ToolbarItemDragSourceView.animatesBackOnCancel`): AppKit calls
`draggingSession(_:endedAt:operation:)` only after that animation, so the
item would only reappear once it finished. A cancelled or refused drag ends
at once and the item shows where it was. Let go outside the toolbar, it
vanishes as before. Sheet drags, entries and the default set, do not slide back
either.

SwiftUI drops the dragged item's view, drag source included, once it leaves
the layout, but AppKit messages the source until
`draggingSession(_:endedAt:operation:)`. The source holds itself
(`retainedForDrag`) from `beginDraggingSession` until the end of that call,
which runs the removal check and then `onDragEnded` exactly once. A cancelled
item comes back as a new view; the cursor is the arrow until the pointer
moves. The zones' drop index already counts without the dragged item, and the
zones read their drawn items again on every move, since the toolbar reflows
after the drag has entered them. Sheet drags hide nothing.

### Drag images

A toolbar item drags as itself on its round or capsule hover fill, on a clear
background. The image renders the toolbar's SwiftUI content (not the header,
whose layer paints the toolbar color) with the zone outlines and the live
hover fills hidden, then draws the fill itself
(`ToolbarItemDragSourceView.dragImageFill`) in the toolbar's color scheme. The
fill is an AppKit view (`ToolbarCustomizationHoverFillView`) so the render can
leave it out: a drag that starts before the fill shows, or while it fades,
looks the same.

The address bar does not drag as itself. The system shrinks a drag image as
wide as the bar (about 30:1) to a fixed small size, so it drags a compact
token instead (`ToolbarAddressBarDragToken`): a capsule 120 to 320pt wide
with the bar's leading section and the page's domain (what the
bar shows with Always Show URL Path off), or "Address" without a page, then
its trailing section, in the bar's resting fill under its hover color. The
domain truncates first; sections wider than the clamp widen the token.

The sections are the bar's own, captured as drawn when the drag starts
(`ToolbarItemDragSourceView.addressSectionRects`): each runs from the bar's
end (Minimal: the unit's) to its innermost button, the bar's full height, so
its rounded end and the bar's hover fill come along, and On Hover buttons
show since customizing shows them. The token lays its hover color only
between them, so nothing is doubled. The captures leave out the zones, the
address bar's outline, the buttons' hover fills and the visibility badge
(`isLeftOutOfDragImages`), all AppKit-drawn for this reason. `ImageRenderer`
draws the token offscreen in the toolbar's color scheme, and it starts under
the press, as far from its leading edge as the press was from the bar's,
clamped clear of its rounded ends. Standard and Minimal drag the same token.

A sheet tile shows its icon on a 24pt circle (a capsule for the Address
tile), and only that circle drags. The default set drags as a small symbol,
dots around a little address capsule on a solid fill
(`ToolbarDefaultSetDragToken`), not as an image of its row.

### Tracking areas

A drag source installs its tracking area itself, on entering a window and on
every size change, over its bounds. AppKit calls `updateTrackingAreas` only
when it invalidates a window's tracking areas (a resize, a scroll), not when
SwiftUI adds an overlay, so relying on it left the toolbar's sources without
one. `.inVisibleRect` is not used: a SwiftUI-hosted view's visible rect can
span its whole window.

### Always and On Hover

A button in an address section shows Always or On Hover. While customizing,
the right-click menu sets it, and an eye badge
(`ToolbarVisibilityBadge`) on the button under the pointer switches it with a
click: an open eye for Always, a crossed one for On Hover. Left and Right
always show their buttons, so theirs have neither. The badge is the only
on-toolbar mark of the setting; On Hover buttons get no other marker.

The badge is 14pt and sits at the button's top right: its right edge on the
button's, so it never reaches the next button 2pt away, and sticking out 4pt
above the button. The address bar
draws it as an overlay over everything it holds, outside Standard's capsule
clip, so it moves nothing: the hovered button publishes its bounds
(`ToolbarVisibilityBadgeKey`). It shows while the pointer is on the button or
on the badge (`ToolbarVisibilityBadge.item`), so moving onto the part that
sticks out keeps it, and the button keeps its hover fill meanwhile. It hides
while anything is dragged from the toolbar. The bar forgets which badge was
under the pointer whenever customizing starts or ends, so a session never
opens with a badge shown.

Its click surface is `ToolbarVisibilityBadgeView`, drawn above the button's
drag source. It is no drag source, so a press on it never drags the button.
It follows the drag source's titlebar rules: `mouseDownCanMoveWindow` false
and `acceptsFirstResponder` true except while its own press is dispatched, so
a press neither moves the window nor takes keyboard focus. The cursor over it
is the pointing hand; back on the button, the open hand. A drag source the
pointer enters under a badge (back from the part that sticks out) leaves the
pointing hand alone, and a press dragged off the badge settles its hover and
cursor on release, since the badge's tracking area reports nothing while the
button is held. A click toggles the
stored setting through `ToolbarCustomizationController.toggleVisibility(of:)`,
the same `setVisibility` the menu uses. Its accessibility label names what a
press does to which button ("Show Copy URL on Hover", "Always Show Copy
URL"; an extension by its own name), and its tooltip says both.

## Minimal style

Minimal draws the address as plain text, with the leading section's buttons
right before it and the trailing section's right after it. Each button keeps
its Always / On Hover setting; On Hover buttons show while the pointer is over
that unit or one of its menus is up, and keep their space while hidden, so the
text never jumps. No button is special: Copy URL shows wherever it is placed.

The unit (leading buttons, address, trailing buttons) is centered on the
window, not on the toolbar row, which spans only the page area. While the
window shows a split, it is centered on the toolbar row instead, over the
split's panes. The header tracks that center in its own coordinates in
`HeaderWindowCenter`, which only the Minimal address observes, so a sidebar
drag does not re-render the whole header. When the side zones leave too
little room, `MinimalAddressLayout.unit` slides the unit toward the free side
and then truncates the address text; the buttons never shrink.

Some buttons are drawn only while customizing: Reader View or Site Memories on
a page without them. Each reports itself through `ToolbarCustomizeOnlyItemsKey`, and
the centering leaves them out, so they extend outward and the text stays put
when customizing starts. A button that appears while browsing (Reader View
once a page offers it) does re-center the unit.

A click on the address text, or on the empty slot around the unit, opens the
location bar. The slot's click surface leaves the two sections' spans to their
buttons.
