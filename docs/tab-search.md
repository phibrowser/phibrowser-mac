# Native tab search

Tab Search collects a Profile-scoped snapshot and presents actions in the current
browser session. The current window affects ranking and command routing; it does
not turn all results into current-window-only data.

## Data and presentation ownership

| Component | Responsibility |
| --- | --- |
| `SearchTabsChromiumProvider` | Parse open and recently closed entries from the framework bridge |
| `SearchTabsNativeProvider` | Collect native pins/bookmarks and enrich their live state |
| `SearchTabsAggregator` | Match, rank and shape UI-ready results |
| `SearchTabsDataController` | Own provider data and produce snapshots for the query |
| View model and controllers | Sections, visible selection and presentation |
| `SearchTabsActionExecutor` | Dispatch actions to their native or framework owner |

Source, kind and display mode are separate. A native pinned split stays a native
pin with a split presentation. Its result contains both panes; the UI must not
reconstruct persisted split relationships. Live framework split panes remain
separate open-tab results with partner metadata.

An open framework tab and its native bookmark/pin can both be present because
their actions and identity are different. Do not deduplicate solely by URL.
Malformed framework entries are skipped; unavailable framework data does not
authorize borrowing another Profile's results. Native provider behavior excludes
incognito data from regular native pin/bookmark results.

## Query presentation

An empty query shows Open Tabs and Recently Closed. A nonempty query can also
show Pinned Tabs and Bookmarks, in that section order between open and closed
results. Empty sections and bookmark-root pseudo-items are omitted. The
aggregator owns ordering; section collapse affects visible rows, not the query.

## Actions and host identity

Activation and recently closed restoration pass the **current**
`BrowserState.windowId` to the bridge with the chosen tab/session ID. The target
tab's recorded window ID is not a substitute for that calling context.
Native pins and bookmarks are resolved again through their owning state before
opening; stale identifiers can fail cleanly.

Closing an eligible open result is different: the executor resolves the result's
owning browser state and closes that tab. The current implementation supports this
action, so the old visual proposal's blanket ban on close controls is not a
current implementation rule.

The overlay must use the visible shell's coordinate space in hosted mode, while
actions retain the session's browser identity. Providers should not be queried
from row rendering, and views should not re-sort an already ranked snapshot.

## Source and verification

- [Search implementation](../Sources/UserInterface/SearchTabs)
- [Action executor](../Sources/UserInterface/SearchTabs/SearchTabsActionExecutor.swift)
- [Models](../Sources/UserInterface/SearchTabs/SearchTabsModels.swift)
- [Session integration](../Sources/UserInterface/MainBrowserWindow/SpaceSessionController+Actions.swift)
- [Data tests](../Tests/PhiBrowserTests/SearchTabsDataTests.swift)

Check empty and nonempty queries, missing providers, duplicate URLs with distinct
actions, native/live split results, cross-window activation, recently closed
restoration and closing a result owned by another session. Manual acceptance also
needs typing, Up/Down, Return, Escape, section collapse, outside-click dismissal
and placement in the visible shell. Old pixel targets or historical screenshots
do not substitute for the current implementation and GUI verification.
