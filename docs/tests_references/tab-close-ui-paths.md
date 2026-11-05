# Native tab closing UI verification

Verify these behaviors through Computer Use in the exact locally built app.
Use a separate temporary Space and disposable pages. Pins can be shared across
Spaces, so preserve existing pins and unpin any temporary fixtures afterward.

## Entry points

- Settings: Command-comma, General, Layout Mode. Comfortable has horizontal tabs;
  Balanced and Performance have vertical tabs. Restore the original mode afterward.
- Closing preferences: Command-comma, Advanced, second settings card. It has no
  heading and contains independent double-click and positional-close switches.
  Positional closing defaults on; double-click closing defaults off. Verify
  immediate menu hiding/restoration for both tabs and group headers, independent
  double-click behavior, and persistence after restarting the app. Close Other
  Tabs stays available when positional closing is off.
- Tab menu: right-click the tab itself, including an inactive tab. Directional
  actions use the clicked tab, without first changing the active page.
- Group menu: right-click the group title. These directional actions preserve
  every member of the group, including collapsed members and split pairs.
- Group member menu: right-click the member inside the group. A member's range
  can include other members and tabs outside the group.
- Multi-selection: click one ordinary tab, Command-click another, then right-click
  a selected tab. Close Other Tabs must retain every selected split unit.

## Required observations

1. Build A, B, C in order. Keep C active and right-click B. Closing before B
   removes A; closing after B removes C. The first/last tab's empty direction is
   disabled. Repeat with the layout-appropriate direction labels.
2. Drag tabs to a different visible order, wait for the resulting list to settle,
   and close a direction from that new order. Verify the actual survivors.
3. For A, split B/C, D, use either pane of the split as the anchor. Both panes
   survive. When the split is a target, both pages close.
4. Put three members in a group. Close before the middle member; the remaining
   members retain their group. Collapse it and close tabs after its header;
   the group and its hidden members survive.
5. Target an entire collapsed group from a neighboring tab. Verify that the
   framework presents its existing group-deletion confirmation. Cancel it and
   verify that the group survives. Confirming permanent deletion is a separate
   consequential action; cancellation coverage does not establish that path.
6. With a live pin and a live pinned split, close other ordinary tabs. Both
   persistent surfaces remain open and lack directional menu items. Explicitly
   closing the pinned split retains its saved pair; reopening shows both panes.
7. In a vertical layout, open a single bookmark and a split bookmark. Close other
   ordinary tabs, verifying that bookmark surfaces survive. In Comfortable,
   bookmark-opened ordinary tabs participate in directional closing, while saved
   bookmarks remain available.
8. Type into a disposable page that registers beforeunload after input. Include
   it in a directional close. Cancel the leave dialog and verify that page stays;
   other targets may already have closed. Repeat and accept leaving, verifying
   that the page closes only after confirmation.
9. Undo an ordinary directional close with Command-Shift-T and verify restoration.
10. Multi-select two ordinary tabs and close others. Both selected tabs survive;
    with only those ordinary tabs remaining, Close Other Tabs is disabled even
    when protected pins or bookmark pages are still open.

AppKit/Chromium changes can settle after the first accessibility observation.
Verify the final list before deriving new element identifiers or asserting a
result. Screenshots are required when accessibility does not expose the relevant
pane contents or drag coordinates. Do not replace these checks with backing-state
mutation or direct bridge calls.
