# Native Tab Search Visual Contract

- Date: 2026-06-18
- Status: Approved visual target
- Audience: implementation agents
- Scope: visual structure, interaction affordances, and result presentation only

## Summary

Native Tab Search should feel like a focused Phi omnibox derivative, not like the
Chromium tab-search popup. The panel is a lightweight macOS command palette with
one search input area and grouped search results.

The final direction is the conservative omnibox-based shell:

- Preserve the Phi omnibox panel proportions, material, border, shadow, and
  top input layout.
- Use Phi theme gold for the selected row and query-match highlights.
- Keep the result list quiet: no row action buttons, no result counts, no
  section divider lines, and no extra feature labels.

## State Contract

### Empty Query

Show only these sections:

1. Open Tabs
2. Recently Closed

Do not show pinned tabs, bookmarks, bookmark folders, bookmark root rows, or
bookmark menus in the empty-query visual state.

### Non-Empty Query

Show these sections, in this order:

1. Open Tabs
2. Pinned Tabs
3. Bookmarks
4. Recently Closed

Sections with no results should be omitted.

## Panel Shell

- Width: about 900-960 px on a desktop window.
- Corner radius: about 18 px.
- Material: light macOS translucent material.
- Border: one subtle system border.
- Shadow: soft macOS floating-panel shadow, not a heavy card shadow.
- Position: centered horizontally, near the top of the browser window.
- Avoid nested cards. The entire result list reads as one continuous surface.

## Search Input Area

Match the existing Phi omnibox reference:

- No inner rounded text-field capsule.
- One large search icon on the left.
- Query text sits on the same baseline as the icon.
- Input height is about 88-96 px.
- A single thin divider line sits directly below the input area.
- The left search icon aligns optically with the result-row favicon column.

Do not show any right-side input action, shortcut hint, Return glyph, or `Open`
label in the input area.

## Sections

Each section has:

- A title-case header, for example `Open Tabs`.
- A small, quiet expand/collapse chevron button on the right.
- Vertical spacing before the next section.

Do not use:

- All-caps headers.
- Section result counts.
- Section divider lines.
- Section cards or tinted section backgrounds.

## Rows

Each row may contain:

- Favicon or native icon.
- Primary title.
- Secondary URL, host, or location text.
- One quiet right-side metadata field, when useful.

Allowed right-side metadata examples:

- `Active`
- `16 mins ago`
- `Seen 2h ago`
- `Yesterday`

Do not show far-right action controls:

- No open buttons.
- No Return glyphs.
- No reopen icons.
- No star icons.
- No pin icons.
- No close buttons.

The selected row uses the theme gold fill with a soft rounded rectangle. Query
matches inside titles or URLs may use a smaller translucent gold text highlight.

## Type-Specific Rules

### Open Tabs

- Right metadata may show `Active` or the last-active elapsed text.
- Clicking or pressing Return activates the selected tab, but the row does not
  advertise that action visually.

### Pinned Tabs

- Right metadata uses the pinned tab's own last-seen field.
- Do not show a pin icon at row end.

### Bookmarks

- Show bookmark title and URL or host.
- Do not show folder names or folder paths.
- Do not show a star icon at row end.

### Recently Closed

- Right metadata may show close time or elapsed text.
- Do not show a restore/reopen icon at row end.

## Interaction Contract

- Typing updates results in place.
- Up and Down move selection across visible rows.
- Return executes the selected row.
- Escape closes the panel.
- Clicking a row executes it.
- Clicking outside closes the panel.
- Section chevrons collapse or expand that section without changing the query.

These interactions should be discoverable through behavior, not through visible
keyboard shortcut labels inside the panel.

## Visual Do Not Add List

Agents should not add these during implementation unless the user explicitly
changes the visual contract:

- Result counts in headers.
- Row-level action buttons or action glyphs.
- Input-level shortcut hints.
- Bookmark folder labels.
- Pin/star/reopen icons at row end.
- Section divider lines.
- Individual row cards.
- A separate bordered search field inside the panel.
- Busy badges or type pills.
