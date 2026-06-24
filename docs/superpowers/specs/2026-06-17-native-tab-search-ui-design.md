# Native Tab Search UI Design

## Context

The data layer now returns one profile-scoped `SearchTabsSnapshot` with Chromium open tabs, recently closed tabs, native pinned tabs, bookmarks, and a bookmark root entry for empty queries. The first UI should consume that snapshot directly and keep presentation logic separate from data collection.

The approved visual target is documented in
`docs/superpowers/specs/2026-06-18-native-tab-search-visual-contract.md`. That
visual contract supersedes earlier exploratory UI details in this document.

## Goals

- Intercept `IDC_TAB_SEARCH` and show a native AppKit search panel.
- Reuse the new `SearchTabsDataController` snapshot model without querying providers from view code.
- Keep Search Tabs UI in `Sources/UserInterface/SearchTabs/`.
- Do not modify OmniBox files; use them only as a local overlay style reference.
- Provide keyboard and mouse selection for results.
- Execute item actions through a small executor that knows which APIs own each action.
- Match the approved visual contract: empty query shows Open Tabs and Recently Closed only; non-empty query shows Open Tabs, Pinned Tabs, Bookmarks, and Recently Closed.

## Non-Goals

- Replace the omnibox.
- Add fuzzy ranking.
- Add a separate global tab-search state container.
- Reconstruct recently closed groups or windows as composite UI rows.
- Add editing, deleting, or context menus for search results.

## UI Behavior

- `IDC_TAB_SEARCH` toggles the panel.
- The panel opens centered near the top of the browser window.
- Typing updates the snapshot in memory through `SearchTabsDataController.snapshot(query:)`.
- Up and Down move selection.
- Return executes the selected result.
- Escape hides the panel.
- Clicking outside hides the panel and forwards the click to the underlying content.
- Clicking a result executes it.
- Section chevrons collapse and expand visible result sections without changing the query.

## Result Rendering

Rows render from `SearchTabsItem` only and follow the visual contract:

- Open Chromium tabs show title, URL, elapsed text, and split partner hint when `splitRelation` exists.
- Native pinned and bookmark split items render as one row with both pane titles.
- Native open pin/bookmark entries keep their native kind and show open state.
- Recently closed rows show title, URL, and elapsed text.
- Empty-query UI omits bookmark root rows even if the snapshot contains them.
- Non-empty bookmark rows show title and URL/host only; folder names and folder paths are not rendered.

The UI must not re-sort results. It also must not add row action buttons, header
result counts, section dividers, input shortcut hints, pin icons, star icons, or
restore icons unless the visual contract changes.

## Action Execution

The data layer describes actions; the UI executor performs them.

- `activateChromiumTab(tabId:windowId:)` calls Chromium with the selected tab id and the current `BrowserState.windowId`, not the target tab's window id.
- `restoreClosedTab(sessionId:...)` calls Chromium with the selected session id and the current `BrowserState.windowId`.
- `openPinned(localGuid:preferredPaneGuid:)` resolves the pinned tab through `BrowserState.pinnedTabs` and delegates to `openOrFocusPinnedTab`.
- `openBookmark(localGuid:preferredPaneGuid:)` resolves the bookmark through `BrowserState.bookmarkManager` and delegates to `openBookmark`.
- `showBookmarkMenuRoot(profileId:)` is handled by the UI menu presenter.

## Integration Points

- `MainBrowserWindowController` owns the overlay controller and background view.
- `MainBrowserWindowController+Actions` toggles and hides the panel.
- `CommandDispatcher` intercepts `IDC_TAB_SEARCH`.
- New UI files are added to the SearchTabs group in the app target.

## Test And Verification Plan

- Add focused unit tests for the action executor's Chromium current-window behavior and native pinned/bookmark dispatch.
- Run `PhiBrowserTests/SearchTabsDataTests`.
- Run `git diff --check`.
- Run `xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS'`.
