# Browser management — operating the USER's browser

Full semantics for the app-level surface: Spaces, profiles, URL rules, pinned
tabs, bookmarks, working in a user Space, tab groups, split view, and
downloads. Read this before your FIRST call into any of them.

These helpers operate the USER's real browser data — their Spaces, profiles,
URL rules, pinned tabs, and bookmarks — immediately and app-wide, not some
agent-private sandbox. They need no agent Space (callable before
`enterContext`) and ignore control ownership, since they don't touch the
agent window.

The data model, in one breath: a **Space** is a workspace bound to exactly one
**profile** (fixed at creation; one profile can back many Spaces).
**Bookmarks** are per-Space; **pinned tabs** are per-profile (shared by all of
that profile's Spaces); **URL rules** route matching navigations into a target
Space.

- References: every `space` parameter takes a spaceId or a Space name
  (case-insensitive; ambiguous names are refused); `profile` takes a
  profileId or display name. Enumerate with `listSpaces()` / `listProfiles()`.
  A Space open in SEVERAL windows resolves to its key (focused) window by
  default; the window-taking helpers (`enterContext({kind:'user', window})`,
  `openSpaceTab({window})`, `listSpaceTabs({window})`) accept a windowId to
  pick one exactly — ids come from `listSpaces()`'s per-Space `windowIds`
  (empty when the Space has no open window), `userFocus()`, or an earlier
  binding's return. A windowId that doesn't show the Space fails
  `window_not_open` — re-list rather than retrying.
- `createSpace(name, {profile, colorHex, iconName, activate})` — `iconName`
  is `"phi:phi-icon-N"` or `"emoji:<hex codepoint>"` (e.g. `"emoji:1F977"`),
  `colorHex` is `"#RRGGBB"`. `{activate: true}` also surfaces the new Space
  in the user's focused window — leave it off unless the user asked to switch.
- `deleteSpace` closes the Space's windows and cascade-deletes its bookmarks
  and URL rules. It is refused for the default Space. DESTRUCTIVE — call it
  only on the user's explicit ask, never as cleanup. `removeBookmark` on a
  folder deletes the whole subtree — same rule.
- Profiles can be created and renamed, not deleted (deliberate — profile
  deletion stays a user-driven UI flow).
- URL rules: `host` matches exact (`"github.com"`), subdomain wildcard
  (`"*.figma.com"`), or contains (`"*git*"`); optional `pathPrefix` narrows to
  a path subtree; `{ask: true}` prompts instead of auto-routing; `space` may
  be `'incognito'` to route into an Incognito Space. Rule `id`s are
  REGENERATED on every rule write — always call `listUrlRules()` fresh in the
  same round before `updateUrlRule`/`deleteUrlRule`, never reuse ids from an
  earlier round (`addUrlRule` returns the new rule row, id included).
- `addPinnedTab` creates the pinned entry as a closed pinned tab (it opens
  when clicked). Mutation helpers settle before returning — they poll until
  their own write is readable — so a list right after a mutation reflects
  it. On a slow write the poll can lapse: the return then carries
  `settled: false` (or `deleted`/`closed`/`removed`/`ungrouped: false`) —
  the operation was SENT but unconfirmed, not failed; re-list to check
  before assuming either way.
- `openSpaceTab(space, url, {activate, window})` — open a URL as a new tab
  in a user Space's open window ("open X in my space"), returning the new
  tab row `{tabId, targetId, url, title, active, windowId}`. `activate`
  defaults true (the tab is selected — the user asked to see it); pass
  `{activate: false}` for background bulk opens; `{window}` (a windowId)
  targets one specific window when several show the Space. Fails with
  `space_not_open` when the Space has no open window (`window_not_open` for
  a `{window}` mismatch). This changes the user's visible window — do it on
  their ask, not as a side effect.
- `userFocus()` — where the user is right now: `{spaceId, spaceName,
  isAgentSpace, isIncognito, windowId?, tab?}`, `tab` being the selected tab
  `{tabId, targetId, url, title}` of the active Space's window. Use it to
  resolve asks like "my current space" / "this page" before acting; `tab` is
  absent when the Space has no open window or is Incognito (deliberately
  not exposed).

Management changes are visible to the user instantly (sidebar, Space
switcher). For bulk edits the user didn't spell out — reorganizing their
bookmarks, rewriting their rule table — confirm first; for additive
single-item asks ("pin this", "bookmark that") just do it.

This whole surface (and the `{space}` tab-layout path) sits behind a user
permission: Settings ▸ Developer ▸ "Allow agents to operate your Spaces".
When it's off, these helpers fail with `user_space_operations_disabled` —
don't retry or work around it; tell the user to flip the toggle if they want
the operation, and continue inside the agent Space otherwise. Agent-Space
work is never affected.

## Working in a user Space

`enterContext({kind:'user', space, profile, create, activate})` binds the round to a
USER Space so every page helper (observe, click, fillInput, goto, openTab,
switchTab, closeTab, …) drives its window instead of an agent window.

**The agent Space stays the default.** Bind to a user Space ONLY when the
user explicitly asks for work in their own Space ("go to my space 1 and …",
"open X in my space") — never as a convenience, and switch back to
`enterContext` for the next ordinary task. Everything you do there
happens in the user's REAL, visible window: tabs open, navigate, and close
before their eyes. Driving is still non-intrusive: binding and
`attachTab`/`switchTab` never change which tab is selected on screen and
never raise or focus the window — the agent drives its tab silently, even
as a background tab, so the user's own browsing is not yanked around.
(`openTab` surfaces its NEW tab in the strip; that is the one deliberate
on-screen change.)

Semantics and differences from a task Space:

- Resolution: `space` is a Space name or spaceId. An unknown name is
  created as a new Space when `create` is true (default); a Space with no
  open window is opened by activating it in the user's focused window;
  `{activate: true}` also surfaces an already-open Space. It attaches to
  the Space's currently selected tab and returns `{spaceId, name, windowId,
  created, tabs}`.
- Window pinning: with the Space open in several windows the binding
  defaults to the key window; `{window}` (a windowId — see the References
  bullet above for where ids come from) binds that exact window instead,
  and `openTab`, tab layout, and downloads then stay on it. `window` also
  stands alone: `enterContext({kind:'user', window})` with no `space`
  derives the Space from the window. The pinned window must already be
  open: `create`/`activate` fallbacks don't apply (`activate` alongside
  `window` is refused — activation targets the focused window), and a
  mismatch fails `window_not_open`.
- No ownership model: there is no handoff/takeover and no "user is
  controlling" stop — the user is inherently in control of their own
  window. Expect their clicks and yours to interleave; act in small steps,
  re-observe often, and stop when the page state says the user intervened.
- No task lifecycle: no keep-alive, no `complete()` (just stop driving),
  no overlay pill or transcript console — `setStatus`/`narrate`/`markError`
  are quiet no-ops; report progress in chat instead.
- No viewport emulation: the window is visible and sized for real, so
  layout is exactly what the user sees. `setViewport` and `diffUrls` refuse
  in this mode (the first would visibly reshape the user's tab, the second
  churns a temporary tab through their strip) — use an agent Space for
  both.
- Background-tab driving: navigation, `observe`, `js`, and input all work
  in a tab that is not the one selected on screen — but its renderer does
  not paint (user windows have no agent-mode visibility forcing), so
  `screenshot()`/`annotatedScreenshot()` of a non-selected tab TIME OUT.
  Screenshot only the tab the user has selected, or do visual checks in an
  agent Space.
- `openTab(url)` in this mode routes through `openSpaceTab` into the bound
  Space's window and returns once the document is ready (no blank-tab
  reuse). Neither `openTab` nor `goto` runs the automatic cookie-consent
  pass here — consent in the user's own window is the user's choice;
  an explicit `acceptCookies()` call still works.
- Tab layout and downloads helpers (`listTabGroups`, `createSplitView`,
  `listDownloads`, …) target the bound Space's window automatically, same
  as they target the task window in agent mode; `{space}` still overrides.
- Same gate as the rest of this surface: everything fails with
  `user_space_operations_disabled` until the user enables agent Space
  operations.

Credentials, downloads, exports and the observation stack all work
unchanged — they are tab-scoped, not Space-scoped.

## Tab groups and split view

Arrange tabs inside a window: group related tabs, or show two pages side by
side. By default these operate on the current agent Space's window — they
take the CDP `targetId`s from `listTabs()`/`enterContext`, map them to
Phi's internal tab ids automatically, follow control ownership like every
other action (hard stop while the user is controlling), and need the usual
`enterContext` first.

Every helper also takes a `{space}` option (Space name or id) to target a
USER Space's open window instead — app-level like the rest of browser
management: no agent Space and no control ownership involved. Enumerate that
Space's tabs first with `listSpaceTabs(space)` → `[{tabId, targetId, url,
title, active, kind}]` — the window's FULL inventory: `kind` is `normal`,
`pinned` (an open pinned tab), or `bookmark` (a tab opened from a bookmark
or a bookmark-bound split), so pinned/bookmark tabs the sidebar projects
outside the normal list are still listed. The integer `tabId`s work
directly as tab references (a user tab may have no CDP target —
`targetId: null` — its `tabId` still works). Needs the Space to have an
open window (`space_not_open` otherwise; `window_not_ready` means the
window exists but its state is still attaching — transient, retry).
Arranging the user's visible window is an on-screen change they'll see
immediately — do it only when asked.

- Groups: `createTabGroup([targets], {title, color, space})` → `{token}`;
  `updateTabGroup(token, {title, color, collapsed, space})`;
  `addTabsToGroup(token, targets, {space})`;
  `removeTabsFromGroup(targets, {space})`;
  `ungroupTabGroup(token, {space})` dissolves the group but KEEPS its tabs;
  `closeTabGroup(token, {space})` closes the group AND its tabs. Colors:
  grey, blue, red, yellow, green, pink, purple, cyan, orange.
- Split view: `createSplitView(target1, target2, {layout, space})` →
  `{splitId}` — `'vertical'` (side by side, default) or `'horizontal'`
  (stacked); `updateSplitView(splitId, {ratio, layout, space})` (`ratio` 0–1
  is the first pane's share); `swapSplitView(splitId, {space})`;
  `removeSplitView(splitId, {space})` ends the split, keeping both tabs.
- `listTabGroups({space})` / `listSplitViews({space})` return members as
  `{tabId, targetId}` pairs (`targetId` null for a tab that has no live CDP
  target). Membership state flows back from the browser asynchronously —
  re-list to confirm after a mutation rather than assuming.
- A split's panes and a group's members must be tabs of the targeted window;
  resolving a target from another window fails.

## Downloads

Observe and control the browser's downloads. Unlike `savePdf`/`scrapeMedia`
(which fetch content the agent chose), these cover REAL downloads — a file
that started because a page or a click triggered it — so the agent can tell
the user where a file went, whether it finished, or pause/cancel a large one.

Downloads are **per-profile**, not per-tab: `listDownloads()` returns every
download of the target window's profile, newest first. The default target is
the current agent Space's window (a file the agent just triggered appears
here, since the agent Space shares the user's profile). `{space}` targets a
USER Space's open window instead — app-level, and gated by the same "operate
your Spaces" setting as the rest of browser management.

- `listDownloads({space})` → rows of `{guid, url, filename, mimeType, state,
  paused, done, canResume, totalBytes, receivedBytes, percentComplete,
  currentSpeed, startTime, endTime, targetPath, currentPath, dangerous,
  insecure}`. `state` is `in_progress | complete | cancelled | interrupted`;
  times are ms-epoch (`endTime` 0 until finished); `percentComplete` is -1
  when the total size is unknown; `targetPath` is where the file lands.
- `getDownload(guid, {space})` → one row (throws if the guid is unknown in
  that profile).
- `pauseDownload(guid)`, `resumeDownload(guid)` (see `canResume`),
  `cancelDownload(guid)` — control an in-progress download.
- `removeDownload(guid)` drops the record from the list; it does NOT delete
  the file on disk.

Controls are asynchronous inside the browser — after a pause/resume/cancel,
re-read `getDownload(guid)` to confirm the new state rather than assuming it.
To watch a download finish, poll `getDownload` until `done` (or `state` is no
longer `in_progress`). The agent can observe and control downloads but cannot
open a downloaded file or reveal it in Finder — those stay user actions.
