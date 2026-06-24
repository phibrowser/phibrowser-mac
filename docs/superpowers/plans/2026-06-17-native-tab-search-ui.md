# Native Tab Search UI Plan

## Task 1: Action Execution

- Add `SearchTabsActionExecutor`.
- Inject Chromium bridge closures for tests.
- Route Chromium actions with the current window id.
- Route native pin/bookmark actions through `BrowserState`.
- Add executor unit tests.

## Task 2: Panel UI

- Add a Search Tabs view model, text field, result table, cell view, and view controller.
- Render rows from `SearchTabsItem` without re-sorting.
- Support query updates, keyboard selection, Return, Escape, and mouse clicks.
- Add a bookmark menu presenter for the bookmark root row.

## Task 3: Window Integration

- Add a dedicated Search Tabs overlay container.
- Add `toggleSearchTabs` and close handling to `MainBrowserWindowController+Actions`.
- Add controller/background ownership to `MainBrowserWindowController`.
- Intercept `IDC_TAB_SEARCH` in `CommandDispatcher`.

## Task 4: Verification

- Run focused Search Tabs tests.
- Run `git diff --check`.
- Run build-for-testing for the canary scheme.
