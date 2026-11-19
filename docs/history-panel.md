# Floating history panel

Settings > General > Browsing > "Show history in a floating panel" (off by
default) makes Show History (Cmd-Y) toggle a panel at the right edge of the
browser window instead of opening `chrome://history` in a tab.

## Ownership

| Owner | Responsibility |
| --- | --- |
| `CommandDispatcher` | Routes `IDC_SHOW_HISTORY` to the panel while the setting is on |
| `HistoryPanelController` | One panel per browser window: child window, slide in and out, opening entries, live refresh |
| `HistoryPanelModel` / `HistoryPanelView` | Search, Today / Yesterday / Week filters, day sections, paging, keyboard selection |
| `HistoryPanelService` | History queries and favicons for one window's profile |

## Reading history

Phi Framework publishes no history query, and Chromium holds the profile's
History database under an exclusive lock while it runs. `HistoryPanelService`
therefore keeps one hidden, detached `chrome://history` WebContents per window
(created with `newWebContentsForUrl:windowId:`, never in a tab strip) and calls
that page's own handler over the app's in-process DevTools session
(`AppDevToolsPageSession`):

```js
const m = await import('chrome://history/history.js');
const h = m.BrowserProxyImpl.getInstance().handler;
h.queryHistory(text, max, begin, true, true);   // first page
h.queryHistoryContinuation();                   // each further page
```

- This is the same Mojo call the history page makes. Its shape is Chromium's
  WebUI internals, not a public API: a Chromium update that changes
  `history.js` or `queryHistory` breaks the panel's results. The query fails
  softly (empty list, one warning in the log) rather than crashing.
- Paging follows the history page: the first page is a `queryHistory` call,
  and each later page is `queryHistoryContinuation()`, so a page costs about
  the same however far the list has been scrolled (about 20 ms warm).
  `max_count` counts raw visits before Chromium merges repeat visits to a
  page, so fewer rows than asked for come back; the response's
  `info.finished`, not the row count, says whether history goes on.
- Yesterday's filter queries from the start of yesterday and skips today's
  visits, which come first, reading further pages until yesterday's rows
  arrive.
- Queries are serialized because a session runs one command at a time. A
  failed query closes the hidden page and retries once on a fresh one.
- Nothing listens on a port; history never leaves the process.
- Favicons come from the profile's favicon database through
  `getFaviconForURL:profileId:`, cached per window.

## Lifetime

The hidden page stays warm while the panel is closed so reopening is instant,
and is released after 10 minutes without use or when its window closes. The
last opening view (no search, Week filter) is cached and painted immediately on
the next open while it refreshes.

## Behavior notes

- The panel is a child window at `.normal` level, so it stays with its browser
  window, other apps cover it, and it survives app switches.
- While the panel has key focus, the Show History shortcut is intercepted with
  a local key monitor: the panel is not a browser window, so the menu would
  otherwise hand the command to Chromium, which opens an empty window.
- Chromium dispatches commands with its hidden widget window; the controller
  resolves the visible session window through `SpaceSessionControllersManager`
  so it never attaches to (and reveals) the hidden one.
- Click opens in the current tab, Cmd-click in a background tab, Cmd-Shift-click
  in a new foreground tab. With no tab to navigate (placeholder mode) entries
  open in a new tab.
