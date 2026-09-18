# Download profile scope

Chromium owns download records in a per-profile `DownloadManager`. Each browser
window's Swift `DownloadsManager` is a presentation cache for that profile.
`DownloadsListView` and Living Downloads keep using that window cache.

AppController retains the independent All Downloads window until it closes, so
closing the originating browser window does not discard it. The window owns a separate `DownloadsManager` configured with an
explicit array of regular profile IDs. Its filter lists registered profiles from
`ProfileManager`, including profiles without an open browser window. Off-the-record
sessions are excluded from this aggregate view.

Library embeds the same `AllDownloadsListView` in its Downloads section.
`LibraryViewModule` owns a separate aggregate cache for its lifetime, so filtering
Library downloads never changes the browser window's download cache. The embedded
view fills its container; minimum window dimensions belong to the standalone
All Downloads window.

## Bridge contract

`getDownloadItemsForProfileIds:completion:` accepts profile directory basenames:

- `nil` selects every registered regular profile.
- An empty array selects no profiles.
- Duplicate IDs are ignored.
- Unknown or unavailable IDs are reported in `failedProfileIds`, with successful
  profiles returned as partial results. There is no last-used-profile fallback.

The bridge loads requested profiles without opening windows, initializes their
download notifiers and history, and waits for history and manager initialization.
It takes a fresh combined snapshot after every profile is ready. Completion runs
on the Chromium UI thread. The Swift cache rejects superseded query completions
when a user changes filters while history is loading.

Every download wrapper carries `profileId` and `isOffTheRecord`. Every download
event also carries these fields, including removal events without an item wrapper.
Incognito Space uses its existing synthetic wire profile ID. The coordinator
routes events to matching browser windows and publishes them for the aggregate
cache, which accepts only its selected regular profiles.

Profile-addressed download operations accept `guid` and `profileId` and target
loaded regular profiles. Window-addressed operations remain available for the
existing browser lists and off-the-record sessions. The aggregate view identifies
rows by profile and GUID, so identical GUIDs in different profiles remain separate.

Both lists reuse the native download visibility rule: local-file attempts without
a target path are hidden while in progress or cancelled. Closing or dismissing a
Living Download toast does not remove the underlying record.

The native header and Chromium bridge must ship together: this change extends the
download wrapper and changes the download event delegate selector.
