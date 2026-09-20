# Content blocking

Phi blocks ads, trackers and cookie banners with filter lists compiled by the
adblock-rust engine (MPL-2.0) inside the Chromium framework. The Mac client
owns the settings surface and talks to the framework through the bridge. This
document is the summary of the design and the decisions as shipped on the
`feat/content-blocking` branch (2026-09-20); implementation details live in
the code and in `components/phinomenon/content_blocking/README.md` of the
Chromium fork.

## Behavior

- Three per-profile switches under Settings > Profiles: Block ads, Block
  cookie banners, Block trackers. All three start off.
- A switch turns on only with a usable rule set. Turning one on with nothing
  downloaded opens the rule set chooser first; the switch follows what the
  user picked there. When the last rule set of a switch is unchecked, the
  switch turns off.
- Filter lists are never shipped in the binary and never downloaded on the
  browser's own initiative. Every download is a user action: the chooser's
  Done (downloads the checked lists still missing), a list's download button,
  "Update Downloaded" in a chooser, or adding a custom URL list.
- Custom lists (a URL or pasted rules) belong to the profile and apply to all
  three switches. Catalog lists are downloaded once into the user data dir and
  shared by every profile; which lists a profile uses is per profile.
- Per site, the address bar menu offers "Content blocking on this site",
  keyed by the registrable domain; exceptions persist per profile and stay in
  memory only for private windows. Private windows show no such row because
  the bridge addresses regular profiles only.
- Nothing about blocking is written to disk beyond prefs and list files: no
  URLs, no per-site counters. A session blocked-request count exists in
  memory for diagnostics and is not shown.

## Settings model

| Concept | Where it lives | Scope |
| --- | --- | --- |
| Switches | Chromium prefs `phi.content_blocking.block_{ads,cookie_banners,trackers}` | profile |
| Which catalog lists a switch uses | `phi.content_blocking.list_overrides` (id → bool); a catalog default or language default counts only once the list is on disk | profile |
| Custom lists | `phi.content_blocking.custom_lists` (id, name, url, sha256, added_at); text under `<profile>/content_blocking/custom/` | profile |
| Site exceptions | `phi.content_blocking.site_exceptions` (registrable domains) | profile; memory only when off the record |
| Downloaded catalog lists | `<user data dir>/PhiContentBlocking/lists/<id>.txt` plus `manifest.json` (fetched time, ETag, sha256) | shared by all profiles |
| Compiled engine cache | `<profile>/content_blocking/<key>.bin`, keyed by the sha256 of every input | profile |

Catalog (`components/phinomenon/content_blocking/resources/catalog.json`):
EasyList (ads), EasyPrivacy (trackers), EasyList Cookie (cookie banners) and
six regional AdGuard lists (de, fr, nl, es/pt, ja, zh) matching the client's
localizations. Only the publishers' own distribution hosts are used; a catalog
test enforces that. A near-empty first-party list is the one bundled list.

Deleting a profile removes its custom lists and cache with the profile
directory; removing the user data dir removes the shared lists.

## Architecture

```
Mac client (SwiftUI)                    Chromium framework
ContentBlockingSettingsSection  ──┐
ContentBlockingRuleSetSheet       │ bridge   ContentBlockingService (per profile)
ContentBlockingCustomFilterSheet  ├────────▶   ListStore (per browser: downloads)
SiteContentBlockingToggle         │            Generation (immutable engine + list ids)
ContentBlockingSettings (facade) ─┘            UrlLoaderProxy (blocks requests)
                                               CosmeticsHost ──Mojo──▶ renderer FrameObserver (hides elements)
```

- `ContentBlockingSettings` is the only Mac-side accessor. Views never touch
  the bridge; writes are optimistic and revert when Chromium refuses. It
  re-reads state on `contentBlockingStatusChanged:`, which Chromium fires for
  generation, status and every list download event, so download progress and
  completion reach the UI even for lists no switch uses.
- The service recomputes the enabled list set on every pref or list-file
  change, compiles an engine on a thread-pool sequence from the files on disk
  (or restores it from the cache), warms it and publishes an immutable
  generation. Requests match synchronously on the UI thread (p95 about
  61 µs); cosmetic rules reach the renderer over Mojo. Status values:
  `active`, `building`, `degraded` (last build failed, previous rules stay),
  `disabled` (every switch off), `no_lists` (a switch is on with nothing
  downloaded; the detail carries the last download error).
- Downloads: conditional GET for single-source lists, a multi-source list is
  replaced only when every source succeeds, a failed refresh keeps the old
  file, retries back off (1, 5, 30 min), 60 s per source, 50 MB cap, progress
  reported every 250 ms.
- Not executed on purpose: scriptlets, `$redirect`, procedural cosmetic
  filters other than plain `:style()`, and cookie-consent clicking. Responses
  served from Cache Storage are not intercepted.

## Bridge surface

`getContentBlockingSettings:`, `setContentBlockingCategory:`,
`setContentBlockingList:`, `setContentBlockingSiteException:`,
`contentBlockingSiteExceptionDomainForURL:`, `addContentBlockingCustomList:`,
`removeContentBlockingCustomList:`, `downloadContentBlockingLists:`,
`deleteContentBlockingListDownload:` (kept, unused by the UI),
`refreshContentBlockingLists:` (kept, unused by the UI), and the delegate
callback `contentBlockingStatusChanged:`. Payload types are protocols because
the framework exports no ObjC class symbols; every call is guarded with
`responds(to:)` so an older framework degrades to "unavailable".

## Verification

- Mac: `ContentBlockingSettingsTests`, `ContentBlockingSettingsSectionTests`,
  `ContentBlockingRuleSetSheetTests`, `ContentBlockingListRowTests`,
  `ContentBlockingCustomFilterSheetTests`, `SiteContentBlockingToggleTests`.
  Run with `xcodebuild test-without-building -scheme PhiBrowser -destination
  'platform=macOS,arch=arm64' -only-testing:PhiBrowserTests/<Class>` after
  quitting Phi (the test host collides with a running instance).
- Chromium: `components_unittests`, `unit_tests` and `browser_tests` with
  `--gtest_filter='PhiContentBlocking*'` in a DCHECK build.
- Manual: turn a switch on, choose and download a rule set, reload a page
  with ads; add a custom rule that blocks a known resource; turn the switch
  off and confirm the page loads unblocked.

## Decisions worth remembering

- Nothing downloads without a user action, including refreshes. Chosen so
  the browser distributes no third-party list and makes no network request
  the user did not ask for.
- Downloaded catalog lists are not deleted from the UI. The files are shared,
  so deleting one would switch other profiles' blocking off; unchecking is
  enough and the files are a few megabytes.
- Lists that live only on GitHub raw or personal sites were dropped from the
  catalog (availability and licensing); users add them as custom lists.
- The Phi first-party list is hidden from the UI and follows any switch.
- The request proxy must outlive its factory receivers: renderers drop a
  factory pipe while loaders are still in flight, and deleting the proxy on
  the last receiver cancelled every request and left pages blank. A browser
  test covers this.
