# Native Tab Search Data Layer Design

## Context

Phi needs a native data layer for tab search. The search UI will combine Chromium search-tab data with native pinned-tab and bookmark data. The data scope is profile-level, not window-level, but the current window still affects ranking and action targets.

Chromium exposes a bridge snapshot with open tabs and recently closed tabs. Native pinned tabs and bookmarks already live in `LocalStore` and are reflected by `BrowserState` for live opened state, split bindings, and activation behavior.

## Goals

- Provide one typed, UI-ready search snapshot for future tab search UI.
- Combine two providers:
  - Chromium provider: open tabs and recently closed tabs.
  - Native provider: pinned tabs, bookmarks, and the empty-query bookmark root entry.
- Preserve source and kind on every result.
- Match and sort results for a user query in native code.
- Make split entries renderable by UI without requiring UI to rediscover split relationships.
- Keep data ownership clear: providers collect data, aggregator ranks and shapes it, UI only renders and invokes action targets.

## Non-Goals

- Build the search panel UI.
- Change pinned-tab, bookmark, or split persistence behavior.
- Rebuild recently closed windows or groups into composite UI entries.
- Add new global state containers.
- Add query support to the Chromium bridge.

## Result Model

The data layer returns a `SearchTabsSnapshot` containing ordered `SearchTabsItem` values.

```swift
struct SearchTabsSnapshot {
    let query: String
    let profileId: String
    let windowId: Int
    let generatedAt: Date
    let items: [SearchTabsItem]
}

struct SearchTabsItem {
    let id: String
    let source: SearchTabsSource
    let kind: SearchTabsKind
    let displayMode: SearchTabsDisplayMode
    let primary: SearchTabsPane
    let secondary: SearchTabsPane?
    let splitRelation: SearchTabsSplitRelation?
    let state: SearchTabsItemState
    let ranking: SearchTabsRankingMetadata
    let action: SearchTabsActionTarget
    let secondaryAction: SearchTabsActionTarget?
}

enum SearchTabsSource {
    case chromium
    case native
}

enum SearchTabsKind {
    case openedtab
    case closedtab
    case pin
    case bookmark
    case bookmarkRoot
}

enum SearchTabsDisplayMode {
    case single
    case split
    case bookmarkMenuRoot
}
```

`source` and `kind` are separate on purpose. A split pinned tab is still `source = native`, `kind = pin`, `displayMode = split`; it is not a new source or kind.

## UI-Ready Pane Data

Each renderable pane carries the information the UI needs to draw the row.

```swift
struct SearchTabsPane {
    let title: String
    let url: String?
    let faviconData: Data?
    let faviconURL: String?
    let localGuid: String?
    let chromiumTabId: Int?
    let windowId: Int?
}
```

Ranking metadata is exposed for diagnostics and UI debugging, not for UI to re-sort.

```swift
struct SearchTabsRankingMetadata {
    let matchScore: Int
    let matchedFields: Set<SearchTabsMatchedField>
    let providerOrder: Int
}

enum SearchTabsMatchedField {
    case title
    case url
    case host
    case secondaryTitle
    case secondaryURL
}
```

For native split `pin` and `bookmark` entries:

- `displayMode = .split`
- `primary` describes the primary/left pane.
- `secondary` describes the secondary/right pane.
- `action` opens or focuses the whole native split entry.
- `secondaryAction` may target the secondary pane in a future UI, but the first UI can ignore it.

For live Chromium split tabs:

- Each pane remains its own `openedtab` item.
- The item stays `displayMode = .single`.
- `splitRelation` describes the live partner so UI can show a badge, partner hint, or visual association.

```swift
struct SearchTabsSplitRelation {
    enum Role {
        case primary
        case secondary
    }

    let splitId: String
    let layout: SplitLayout?
    let role: Role
    let partnerTabId: Int
    let partnerTitle: String
    let partnerURL: String?
}
```

The UI must not need to call `pinnedSplitDBPair`, inspect `splitPartnerGuid`, or read `splitBookmarkBindings` to render a native split result.

## State And Actions

```swift
struct SearchTabsItemState {
    let isOpen: Bool
    let isActive: Bool
    let isHostWindow: Bool
    let isPinnedInChromium: Bool
    let isSplit: Bool
    let lastSeen: Date?
    let lastActiveElapsedMs: Int64?
    let lastActiveElapsedText: String?
}

enum SearchTabsActionTarget {
    case activateChromiumTab(tabId: Int, windowId: Int)
    case restoreClosedTab(sessionId: Int, sourceEntrySessionId: Int, sourceEntryType: String)
    case openPinned(localGuid: String, preferredPaneGuid: String?)
    case openBookmark(localGuid: String, preferredPaneGuid: String?)
    case showBookmarkMenuRoot(profileId: String)
}
```

The data layer only describes actions. Existing `BrowserState` and Chromium bridge methods execute them when UI invokes the selected action.

## Providers

### ChromiumSearchTabsProvider

Responsibilities:

- Call `getSearchTabsDataWithWindowId:` once when the panel opens or refreshes.
- Parse `openTabs` into typed Chromium open-tab snapshots.
- Parse `recentlyClosedTabs` into typed recently closed snapshots.
- Defensively skip malformed items.
- Preserve bridge fields used for sorting and actions:
  - `tabId`
  - `windowId`
  - `index`
  - `title`
  - `url`
  - `groupIdHex`
  - `active`
  - `pinned`
  - `split`
  - `hostWindow`
  - `lastActiveElapsedMs`
  - `lastActiveElapsedText`
  - `sessionId`
  - `sourceEntrySessionId`
  - `sourceEntryType`
  - `lastActiveTimeMs`

Missing bridge/proxy data returns empty Chromium results.

### NativeSearchTabsProvider

Responsibilities:

- Read pinned tabs for `profileId` from `LocalStore.getAllPinnedTabs(for:)`.
- Read bookmarks for `profileId` from `BrowserState.bookmarkManager.getAllBookmarks()` in the first implementation, because the bookmark manager already maps store rows into UI-ready bookmark objects and carries live opened state.
- Use `BrowserState` only to enrich live state:
  - whether a native entry is open
  - active state
  - live tab id
  - live split binding
  - pinned split pairing
- Return no native results for incognito windows.
- Return a single bookmark root entry for empty query.

Native provider does not rank results and does not execute actions.

## Aggregation Rules

The aggregator converts provider snapshots into `SearchTabsItem` values, then filters and sorts them.

Open Chromium tabs are never suppressed by native identity. If an open Chromium tab is backed by a pinned tab or bookmark, the result list may contain both:

- an `openedtab` item for switching to the live Chromium tab
- a `pin` or `bookmark` item for the native entry, marked `isOpen = true`

This duplicate-looking output is intentional because the entries represent different source semantics and actions. `openedtab` is always ranked above native entries.

## Empty Query Behavior

When the normalized query is empty:

- Include all `openedtab` items.
- Include pinned entries.
- Include native bookmark entries only when they are open.
- Include exactly one `bookmarkRoot` entry for browsing the bookmark tree from UI hover/menu.
- Do not flatten all bookmarks.
- Include `closedtab` items after native entries.

Default ordering:

1. `openedtab`
2. open native `pin` and `bookmark`
3. unopened `pin`
4. `bookmarkRoot`
5. `closedtab`

## Non-Empty Query Behavior

When the normalized query is not empty:

- Search `openedtab`, `closedtab`, `pin`, and bookmark leaf entries.
- Search bookmark leaf entries only.
- Do not return bookmark folders.
- Do not include bookmark folder names or paths in the item.
- Do not include the `bookmarkRoot` entry.
- A split bookmark may match either primary or secondary title/URL and returns one split item.
- A split pinned tab may match either primary or secondary title/URL and returns one split item.

Matching fields:

- title
- URL string
- URL host
- secondary title and URL for native split entries

Match scoring:

1. Title prefix
2. Title contains
3. URL host contains
4. URL path or full URL contains

The first implementation should keep scoring deterministic and easy to test. Fuzzy matching is outside this scope and needs a separate design if the UI needs it.

## Sorting Rules

Kind priority always starts with open Chromium tabs:

1. `openedtab`
2. open native `pin` or `bookmark`
3. unopened `pin`
4. `bookmark`
5. `bookmarkRoot`
6. `closedtab`

Within `openedtab`:

1. Host/current window first.
2. Active tab first.
3. `lastActiveElapsedMs` ascending. Smaller elapsed values are more recent.
4. `windowId` ascending.
5. Tab `index` ascending.

Within native pinned entries:

1. Open entries first.
2. Active entries first.
3. `lastSeen` descending.
4. Persisted pinned index ascending.

Within bookmark entries for non-empty query:

1. Match score.
2. Open entries first.
3. Active entries first.
4. `lastSeen` descending.
5. Stable bookmark order from the existing bookmark tree.

Within `closedtab`:

1. Match score for non-empty query.
2. `lastActiveElapsedMs` ascending when available.
3. `lastActiveTimeMs` descending when elapsed is unavailable.
4. Bridge order as stable fallback.

## Split Handling

### Open Chromium Split Tabs

Chromium open split panes remain separate `openedtab` items. This preserves precise pane switching and keeps open tabs at the top of results.

Each item should include `splitRelation` when `BrowserState` can resolve the live `SplitGroup`. The item remains `displayMode = .single`.

### Pinned Split Entries

Pinned split pairs produce one native `pin` item with `displayMode = .split`.

The item includes:

- primary pane title, URL, favicon, local guid, live tab id if open
- secondary pane title, URL, favicon, local guid, live tab id if open
- `isOpen` if either side is live as the persisted split entry
- `isActive` if either side is focused
- default action targeting the whole pinned split entry
- optional secondary action targeting the secondary pane

### Bookmark Split Entries

Split-view bookmarks produce one native `bookmark` item with `displayMode = .split`.

The item includes:

- primary title/URL from `Bookmark.title` and `Bookmark.url`
- secondary title/URL from `Bookmark.secondaryTitle` and `Bookmark.secondaryUrl`
- favicon data when available
- live tab ids when the split bookmark is open through `splitBookmarkBindings`
- default action targeting the whole bookmark split entry
- optional secondary action targeting the secondary pane

### Recently Closed Split Tabs

Recently closed results stay as individual Chromium `closedtab` items in the first version. The data layer does not reconstruct closed split, group, or window composites.

## Bookmark Root Entry

For empty query, the native provider returns one `bookmarkRoot` item.

The item exists only to let UI show a hover/menu bookmark tree. It should carry:

- `source = native`
- `kind = bookmarkRoot`
- `displayMode = bookmarkMenuRoot`
- `action = showBookmarkMenuRoot(profileId:)`
- `primary.title` set to the localized bookmark root display title
- `state.isOpen = false`

It must not include flattened bookmark children in `SearchTabsSnapshot.items`.

## Error Handling

- Missing Chromium bridge returns empty Chromium results.
- Malformed bridge entries are skipped individually.
- Invalid or missing tab/session ids produce non-actionable skipped entries.
- Missing `LocalStore` context returns empty native results.
- Incognito returns Chromium results only.
- Query normalization trims whitespace and compares case-insensitively.
- URL parsing failures do not prevent string matching against raw URL values.

## Test Plan

Add focused unit tests under `Tests/PhiBrowserTests`.

Required tests:

- Parses valid Chromium open-tab and recently-closed dictionaries into typed provider models.
- Skips malformed Chromium items without failing the full snapshot.
- Keeps `openedtab` results when matching native `pin` or `bookmark` entries also exist.
- Ranks `openedtab` before native entries.
- Sorts `openedtab` by host window, active state, then `lastActiveElapsedMs` ascending.
- Empty query returns one `bookmarkRoot` entry instead of flattened bookmark leaves.
- Non-empty query searches bookmark leaves and excludes folders.
- Bookmark search does not include folder path text.
- Native pinned split builds one `displayMode = split` item with primary and secondary pane data.
- Native split bookmark builds one `displayMode = split` item with primary and secondary pane data.
- Open native entries set `isOpen = true` and keep their native kind.
- Incognito excludes native provider results.
- Closed-tab sorting uses `lastActiveElapsedMs` ascending when available.

## Implementation Notes

- Keep new code in a focused data-layer location, for example `Sources/UserInterface/SearchTabs/` or a similarly existing UI-adjacent module if one is introduced by nearby code.
- Avoid adding a new global state container.
- Avoid moving bookmark or pinned-tab ownership out of `LocalStore` and `BrowserState`.
- Keep provider protocols small and concrete. Do not introduce broad abstractions beyond the two providers and the aggregator needed for tests.
- Add the bridge method declarations to the local Chromium header only if they are not already present in this checkout.
- Tests can be added under `Tests/PhiBrowserTests` without editing `project.pbxproj` because this test root uses synchronized project groups.
