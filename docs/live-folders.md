# Live folders

A live folder is a sidebar folder that fills itself from GitHub: the signed-in user's open
pull requests. Each Space can have one. There's no OAuth app and no token: Phi reads
github.com with the session the profile already has, so signing in to GitHub in a tab is all
the setup there is.

## Reading GitHub

`GitHubSessionFetcher` runs `fetch` inside a hidden github.com page in the profile's browser
context, over the in-process DevTools client (`AppDevToolsPageSession`). The framework has no
cookie-carrying request API. What was measured on framework v2.15.0, 2 Nov 2026:

- `Network.loadNetworkResource` from a page on another site sends no SameSite cookies
  (`Sec-Fetch-Site: cross-site`), so a request has to come from a github.com frame.
  It also can't set headers, and `chrome://` pages refuse it (CSP).
- `Target.createTarget` with `hidden: true` in the profile's `browserContextId` adds no tab
  and no window. The target closes after every refresh.
- `fetch` in that page sends the session cookies and GitHub's JSON headers.
- Signed out, `/pulls` answers 404 `{"error":"Couldn’t authenticate you"}`.

GitHub's JSON routes are private and can change without notice. `GitHubLiveClient` accepts
several shapes and falls back to the search route and then HTML; if every reader fails, the
folder shows "Failed to update" and keeps its rows.

The fetcher runs with the user's signed-in session, so `fetchExpression` refuses anything but
`https://github.com`. A framework API for this would replace the hidden page and leave
`GitHubSessionFetcher`'s interface as it is.

## State

`LiveFolderManager` owns the folders, keyed by Space id, in account preferences
(`AccountUserDefaults`). They're not in the bookmark store, so neither the folder nor its rows
sync. `LiveFolderData` holds the filter and rows, and all of the reconciliation rules.

Refreshes run every 120 s while Phi is active, when the active window changes, when a filter
changes, and from the folder's menu; a failing folder retries every 30 s. Only the active
window's Space refreshes, because a fetch needs a tab of that profile to find its browser
context.

## Rows and tabs

A row binds to its tab with a marker in the tab's custom value (`LiveFolderRow.tabMarker`), as
a bookmark does with its guid. While the row exists the tab is hidden from the normal tab list;
a marked tab with no row, such as one restored after its folder was deleted, is an ordinary tab.

- A pull request that leaves the results stays for 120 s, and for as long as its tab is open.
- "Remove from Folder" and the row's ✕ hide the pull request for good and close its tab.
  Closing the tab alone (⌘W) leaves the row, as with a bookmark.
- Deleting the folder turns its open tabs back into ordinary tabs in the window that deleted it.
  Another window of the Space keeps its marked tabs, which show as ordinary tabs once it sees
  the folder is gone.
- The folder is the last root item of `BookmarkSectionController.bookmarkItems`, because the
  outline derives root drop indices from that array's count. Nothing drops into it.

The folder appears in the vertical sidebar with bookmarks visible, and not in incognito.
