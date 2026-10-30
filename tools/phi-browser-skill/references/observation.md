# Observation and page toolkit — detail

Deep semantics behind the observation stack in SKILL.md: scan options,
viewport control, the canvas-editor policy, console/network diagnostics, and
page export. Read the matching section before testing responsive layouts,
editing a canvas-like app (Google Docs/Sheets, Notion, Figma, …), auditing a
page's console/network health, or exporting PDFs/MHTML/media.

## Scan options

`observe()` and `snapshotText()` take the same options:

- `{diff: true}` — return only what changed since the previous scan of this
  tab+scope: `observe` gives `{added, removed, changed, unchanged}` keyed by
  ref, `snapshotText` gives `-`/`+` prefixed lines. EVERY scan (either helper)
  rotates the baseline, which lives on disk and survives heredoc rounds.
  Discipline: full scan once, then `{diff: true}` after each action — print
  the diff, not the whole page again.
- `{within: target}` — scan only that subtree (`'@ref'`, `'loc=…'`, CSS,
  xpath). Scoped scans keep their own diff baselines. Scoping to a
  currently-hidden subtree (a closed menu, a dialog) implies `showHidden`.
- `{showHidden: true}` — include hidden elements (display:none, collapsed
  menus, zero-size), flagged `hidden: true` in `observe()` and `(hidden)` in
  prose. Hidden plain text stays excluded — only controls are recorded.

## Viewport

The tab renders at the Agent Space's own **page area** — the window minus
Sidebar, Content Header, bookmark bar and AI Chat panel, the same size a
regular tab there would use — reported by the app and re-checked before each
action, so a Sidebar toggle, a bar, a panel or a window resize mid-task is
picked up at your next action.
**Do not change the viewport on normal sites.** To read more of a long page
(an article, a feed, search results), scroll and re-observe —
`observe({diff: true})` keeps that cheap — instead of growing the viewport.

`setViewport({width?, height?})` exists for the exceptions only:

- Testing responsive layouts at an explicit width (that IS the tool for it).
- A size the user explicitly asked for (e.g. capture a page at a given
  resolution).

Omitted dimensions keep tracking the page area, and `setViewport()` with
no args resets to it. Both dimensions clamp to 320–4096.

Notes:
- Per-tab: it never affects other tabs, even of the same site (unlike Chrome's
  Ctrl± zoom). Restored when you `switchTab` back; reset between heredoc
  rounds — re-apply after `enterContext` if still needed.
- A user surfacing the Space always sees the WHOLE viewport scaled to fit
  the page area, never a clipped slice.
- Screenshots capture the full viewport at full resolution; refs and
  click/hover/scroll coordinates keep working (the widget-space transform is
  handled internally).

## Canvas-like editors (Google Docs, Sheets, Notion, Figma, …)

Rich productivity apps — Google Docs/Sheets, Notion, Lark/Feishu Docs, Figma,
whiteboards, map UIs, heavily virtualized editors — do NOT expose their main
editing surface as honest DOM. The scan still finds elements there (toolbars,
title inputs, hidden textareas, offscreen iframes, a bare `<canvas>`), but
none of them is the document/grid you mean to edit: a `fillInput` can
"succeed" into the title bar or a hidden buffer while the real document stays
untouched.

Policy for the MAIN editing surface of such apps:

- Go visual first: `screenshot()` + view the PNG, then `click(x, y)` to place the
  caret/selection and REAL keystrokes — `typeText(...)`, `pressKey(...)`,
  `click(x, y, {clickCount: 2})` to select a word/cell. Refs/locators remain
  right for the app's chrome: menus, toolbars, dialogs, and search boxes are
  normal DOM.
- Before writing anything substantial, run a tiny WRITE PROBE: type a short
  marker, `screenshot()` and confirm it appeared at the intended spot — not
  in the title, a search box, or nowhere — then remove it and proceed. No
  probe, no bulk typing.
- If the probe lands wrong, stop using DOM helpers (`fillInput`, refs) on
  that surface entirely; switch to screenshot-guided coordinates + keyboard,
  and re-screenshot after each meaningful step.
- Verify the end state by READBACK, not by absence of errors: a fresh
  `screenshot()`, or an export/API path via `js(...)` when the app offers
  one (e.g. a document's export URL).

## Console, network, and page diffs

- `readConsole({errors, max})` — the tab's console messages as text, one per
  line. Chromium buffers console messages per tab (capped ~1000), so this
  includes history from BEFORE the current heredoc round. `{errors: true}`
  keeps only error/warning; repeated identical messages collapse to `(xN)`.
- `readNetwork({failedOnly, max})` — requests seen on the current tab as
  `status method url [type] size` lines. Capture starts when the round
  attaches to the tab, so it covers THIS round only — to audit a page load,
  `goto` and `readNetwork` in the same heredoc. `{failedOnly: true}` keeps
  network failures and 4xx/5xx responses.
- `diffUrls(url1, url2)` — loads both pages in a temporary tab (the current
  tab and its diff baselines are untouched) and returns `-`/`+` prefixed
  lines, same format as `snapshotText({diff: true})`. Good for
  staging-vs-production checks.

For QA tasks, check `readConsole({errors: true})` and
`readNetwork({failedOnly: true})` before declaring a page healthy — a page
can render fine over broken XHRs.

## Page export and media

- `savePdf(path?, opts?)` — print the current tab to PDF. Lengths are inches:
  `{format: 'a4'|'letter'|'legal'}` or `{width, height}`, `{margins}` or
  per-side `marginTop/Right/Bottom/Left`; plus `{landscape, scale,
  pageRanges, preferCSSPageSize}`. `{printBackground}` defaults true (match
  what the page looks like). Headers/footers: `{pageNumbers: true}` for a
  plain `N / M` footer, or raw Chromium `{headerTemplate, footerTemplate}`
  (spans classed `pageNumber`/`totalPages`/`date`/`title`/`url`).
  `{outline: true}` adds PDF bookmarks from the page's headings;
  `{tagged: true}` emits an accessible PDF; `{toc: true}` waits for Paged.js
  pagination to settle before printing (for pages that self-paginate; no-op
  otherwise). Returns `{file, bytes}`.
- `archivePage(path?)` — the complete page as one self-contained MHTML file.
  Returns `{file, bytes}`. A snapshot embeds only what the page has actually
  fetched, so on a page that defers images until they scroll into view,
  `scroll` through it first.
- `saveArticle(path?, {complete, inlineImages})` — the page distilled to its
  article as one standalone HTML file: Phi's own Reader View export, styled
  the way the reader renders it, not a re-render of a scrape. Images are
  inlined by default so the file opens with no network; `{inlineImages:
  false}` leaves them as origin URLs, which is smaller. `{complete: true}`
  waits for the whole of a paginated document (a long PDF) instead of the
  pages the reader opens with. Extraction walks the page first, so deferred
  images are already resolved — unlike `archivePage`, this needs no scrolling
  beforehand. Throws for pages that are not articles, exactly as
  `readerArticle` does. Returns `{file, bytes, title, rung, isComplete}`.
- `scrapeMedia({types, within, dir, limit, maxBytes})` — bulk-download the
  page's media and write a `manifest.json` beside the files. `types`
  defaults to `['image']` (add `'video'`/`'audio'`); collects `<img>`
  (srcset/`<picture>` resolved), `<video>`/`<audio>` — top document only,
  CSS backgrounds excluded. Each URL is fetched via the first route that
  works: renderer cache → in-page fetch → Node fetch carrying the profile's
  cookies, so session-protected media downloads too. Returned URLs and
  filenames are page-derived — SKILL.md's untrusted-content rules apply.
  Returns `{dir, manifest, saved, failed}`.

All three export the CURRENT document. Right after `openTab`/`goto` a heavy
page may not have committed yet (the seed document reads `complete`) — a
tiny PDF/MHTML or an empty scrape means you exported too early:
`waitForElement` a page-specific selector first, then export.
