# Save for Later — Implementation Plan (Phases 1–2)

> **Product name: Folio** (renamed 2026-09-03). Memory is what Phi remembers about you, Folio is what you chose to keep. User-facing strings, string keys, and the default folder (`~/Documents/PhiFolio`) carry the new name; internal identifiers (`SaveForLaterService`, `saveForLater.*` bridge types, the Mirage `save-for-later` module, the PostHog flag) keep the working name.

Date: 2026-08-31
Status: Phases 1–3 implemented and verified end to end — article save
(Wikipedia), video save (YouTube → generated article with timestamp
links), and site-action auto-save (YouTube Like → saved pair with
`trigger: youtube-like`)
Design: [2026-08-31-save-for-later-design.md](2026-08-31-save-for-later-design.md)

Phase 1 ships article saves end to end: File menu / shortcut → background
job → markdown + MHTML pair in the configured folder. Video saves (Phase 2)
and site-action auto-save (Phase 3) come later.

## Mirage (`phi-ai/ai-extension/mirage`)

1. `public/extraction/turndown.js` — vendored Turndown 7.2.1 browser UMD
   (from the workspace's pinned dependency), alongside the existing vendored
   extraction scripts.
2. `public/extraction/ReaderMarkdown.js` — defines
   `window.__phiReaderMarkdown(contentHtml, codeBlocks)`: DOMParser →
   restore `pre[data-phi-code]` sources from `codeBlocks` → Turndown
   (config copied from `show-current-page-as-markdown`) → collapse blank
   runs. Runs in the extension's isolated world, injected on demand like
   `EXTRACT_FILES` (the background is a service worker with no DOM).
3. `src/reader-view/messages.ts` — `ExtractedArticle.contentMarkdown?:
   string`; `reader.extract` payload gains `includeMarkdown`.
4. `src/reader-view/background.ts` — `extractForTab` gains
   `includeMarkdown`; after the winner is assembled it injects the two
   files and converts. The reader-open path never asks; conversion failure
   degrades to no markdown, never to a failed extraction.

## Swift (`phibrowser-mac`)

1. `PhiPreferences.SaveForLater` — global folder (default
   `~/Documents/Phi Saved`), per-profile overrides (dictionary keyed by
   profileId), `effectiveFolderPath(forProfile:)`.
2. `ReaderExportService` — `sanitizedBaseName(title:)` promoted out of
   `suggestedFileName` for the writer to share.
3. `ReaderArticle.contentMarkdown` (optional) +
   `ReaderExtensionBridge.extractArticle(includeMarkdown:)` + wire field.
4. `ReaderAccessibilityExtractor.markdown(fromBlocksHTML:)` — direct
   rendering of the extractor's own constrained grammar (h2–h6, p, figure
   placeholders) for the AX fallback rung.
5. `SaveForLaterService` (new, `Sources/States/`) — the background job:
   in-flight registry by tab guid, immediate capture legs (extension
   extract with markdown / AX fallback / stub + MHTML via
   `ReaderExportService.captureOriginalPage`), basename reserved at start
   with collision suffixes, frontmatter writer, completion toasts via
   `OverlayToastCenter`. Guest Mode refuses.
6. Entry points — `PHI_SAVE_FOR_LATER = 90023` (default ⌥⌘S): File menu
   item in `installOrUpdateFileMenuItems`, `AppController.saveTabForLater`,
   validation clause, `CommandDispatcher` intercept + dispatch,
   `Shortcuts+Custom` listing/search entries, `ShortcutsViewModel` title.
7. Settings — General pane `SaveForLaterSectionView` (folder picker row);
   `ProfileDetailSettingsView` override row ("Same as General" until set,
   clearable).

## Phase 2 — Video saves (implemented 2026-08-31)

phi-ai:
- `phi-agent/api/routes/video-gist.ts` — `POST /api/video-gist`, registered
  in `api/router.ts`. Wraps `runVideoGist` with a fixed article-mode prompt
  (opening `# Title` heading, per-section timestamp deep links). Deps (`ai`,
  `config`, `telemetry`) come from the existing `RouterDeps`; the raw
  `Authorization` header is forwarded downstream, matching the telegram
  route. Honors the `VIDEO_GIST_ENABLED` kill switch (503
  `video_gist_disabled`). Stable error codes: 400 `invalid_payload` /
  `video_gist_invalid_url`, 401, 422 `video_gist_video_too_long`, 503
  `video_gist_not_configured`, 504 `video_gist_timeout` (180 s budget),
  502 `video_gist_failed`.

phibrowser-mac:
- `PhiAgentHTTPRequest` gained an optional per-request `timeout`, honored on
  both routes (loopback `timeoutInterval`; broker client built with the
  request's I/O budget — factory signature now carries it, tests updated).
  Default budgets (60 s / 30 s) were too short for minutes-long generation.
- `APIClient.generateVideoGistArticle(videoURL:)` — 200 s budget, decodes
  `VideoGistArticle {markdown, truncated}`, surfaces the endpoint's stable
  code as `APIClient.VideoGistError`.
- `SaveForLaterService`: `isYouTubeVideoURL` (anchored mirror of
  `shared-types/video-urls.ts` plus the video-id check) routes the job;
  video saves write MHTML + a placeholder markdown immediately (creation is
  the basename reservation), replace the body when the gist returns, and
  promote the article's `# Title` into frontmatter and filenames (pair
  rename) when the page yielded no title. Gist calls are gated on AI
  enabled + signed in; refusal or failure degrades to the stub with the
  original-video link and a noted reason. bilibili stays on the article
  path by design.

Phase 2 verification: phi-ai type-check/lint/format clean; endpoint
contract smoke-tested (401 / 400 invalid_payload / 400
video_gist_invalid_url incl. id-less watch URLs / 404 on GET).
**Runtime-verified end to end 2026-08-31**: a manual save of a real
YouTube video through a source-built phi-agent produced the full pair —
`type: video` frontmatter, site suffix stripped from the title, the
Original video link, and a generated article whose section headings carry
working timestamp deep links; browser log shows `video gist ok`.

Dev-loop note discovered on the way: Sentinel prescribes the broker
transport (`uds`), and its broker only serves the **bundled** phi-agent —
a source-built instance is unreachable through it regardless of what
`phi-agent.api_base` exports say. DEBUG builds therefore accept a
`-PhiAgentLoopbackOverride http://127.0.0.1:8788` launch argument
(`PhiAgentEndpointResolver.currentRoute`) that pins the route to a local
instance; without it a dev video save degrades to the stub with the
transport error logged.

## Phase 3 — Site-action auto-save (implemented 2026-08-31)

Mirage (`src/save-for-later/`):
- `rules.ts` — bundled trigger-rule baseline (YouTube like/save, X bookmark/
  like on tweet detail pages, Reddit upvote/save on comment pages, Stack
  Overflow bookmark), JSON-shaped so the phi-reader-rules manifest can carry
  a `triggers` section later. Page-context only (`pathPattern` gate).
- `content-script.ts` — capture-phase click detection, armed only on hosts
  with a rule; `aria-pressed` transition check so un-liking never fires;
  reports `sfl:trigger` to the background.
- `background.ts` — relay to the app (`saveForLater.trigger`), gated by the
  armed state pulled on boot (`saveForLater.getArmed`) and pushed on change
  (`saveForLater.armedChanged`). The app re-checks on every trigger — the
  extension cache is an optimization, not the gate.

phibrowser-mac:
- `OverlayToastItem` gained an optional action button (first consumer:
  the auto-save toast's **Undo**, which trashes the pair; 6 s duration).
- `SaveForLaterService`: `autoTriggerFlagEnabled` (PostHog
  `save-for-later-auto-trigger`), `autoTriggerArmed` (flag && opt-in &&
  not guest), armed broadcast/pull handlers, trigger handler with sender
  check, tab-URL match, and a 10-minute per-URL dedup window; saves carry
  `SaveTrigger` provenance into the frontmatter.
- `PhiPreferences.SaveForLater.autoSaveOnSiteActions` (default off) with a
  General-pane toggle row shown only while the flag is on.

**Phase 3 runtime-verified 2026-08-31** (driven end to end via the
phi-browser agent skill): a real Like click on a YouTube watch page
produced the pair with `trigger: youtube-like` frontmatter and, because
the page is a video, a generated article. Verified along the way: the
transition check refuses un-like clicks, and the armed gate reflects
flag && opt-in on every trigger.

Hard-won dev-loop facts:
- **Relaunching Canary with `--load-extension` does NOT refresh an
  already-registered extension SERVICE WORKER — even across manifest
  version changes.** Content scripts update per launch; the worker keeps
  running stale bytes until the extension is explicitly reloaded
  (chrome://extensions ▸ reload, or `chrome.developerPrivate.reload`).
  This masqueraded as "listener not registered" for hours. After an
  extension reload, content scripts in ALREADY-OPEN tabs are dead until
  those pages reload.
- The Mirage relay therefore queries the armed state fresh per trigger
  (no caching): a worker can boot before the app bridge is ready, and
  broadcasts can miss a sleeping worker — a cached `false` silently
  swallows every click. The listener acks synchronously (`sfl-ack`) so a
  missing registration is distinguishable from a lost async reply.
- DEBUG builds accept `-SaveForLaterAutoTriggerFlag YES/NO` standing in
  for the PostHog flag; production rollout still needs
  `save-for-later-auto-trigger` created in the PostHog project.

Remaining future work: publishing trigger rules through the
phi-reader-rules manifest (bundled baseline only today), and the Phase 4
items (feed-item triggers via background capture, bilibili, library
view).

## Phase H — Highlights & annotations (implemented 2026-09-01)

First knowledge-library layer on top of the saved items: select text on
any page → right-click → **Save Highlight for Later**.

- Mirage `src/save-for-later/highlights.ts`: `chrome.contextMenus` entry
  on selections (http/https + the reader surface). The selection's HTML is
  captured in-page, rendered to markdown by the same injected Turndown
  wrapper Reader View uses, paired with a `#:~:text=` text-fragment deep
  link back to the passage, and reported as `saveForLater.highlight`.
  Registration is guarded (`if (chrome.contextMenus)`): a registration
  without the permission must cost this feature only — an unguarded
  top-level throw kills the whole worker module graph, reader view
  included. A `sfl:debugHighlight {tabId}` runtime message (accepted only
  from this extension's own pages) drives the exact menu-click path for
  automation, since native context menus are out of automation's reach.
- Reader surface (`reader-view/page/main.ts`): answers `sfl:getSelection`
  with the selection plus the origin tab and article URL from its
  fragment, so a highlight made in Reader View lands on the article's
  item, not a `chrome-extension://` one.
- Swift `SaveForLaterService`: `handleHighlight` appends a quoted block
  under a structural `## Highlights` heading in the item whose
  frontmatter `source` matches the URL (most recent snapshot wins). Each
  block sits under its own numbered heading — `### Highlight`,
  `### Highlight 2`, … (the next number is derived by counting these, so
  like the section heading they are not localized). A highlight-caused
  save carries a ` highlight` marker in the pair's basename
  (`YYYY-MM-DD <title> highlight.md/.mhtml`), and an item saved another
  way is renamed to gain the marker when its first highlight lands. No
  item yet → a full save runs with the highlight embedded
  (`trigger: highlight`); no saveable tab either (origin closed behind a
  reader surface) → a frontmatter+link stub is written around the quote —
  a highlight is never dropped. Highlights arriving while a save is in
  flight queue per-URL and append after the job's final write
  (placeholder-replace safe); all file mutations chain through one
  serialized task. The completion toast carries **Add Note**: a small
  sheet whose text lands as `**Note:** …` anchored under that highlight's
  block.
- `canSave` now requires an http(s) URL (a synthetic trigger could
  previously save a `chrome-extension://` page), and the site-action
  relay ignores trigger-shaped messages from non-web senders.

### Version skew: a stale worker fails loudly now (2026-09-03)

Deleting the app's highlight path made one skew silent: an older Mirage
still sends `saveForLater.highlight`, the app no longer answers it, and
the user's right-click did nothing. Seen in practice on this machine --
`[CommonMessage] Unhandled message type: saveForLater.highlight` -- where
the REGISTERED extension was current but the running MV3 service worker
was still executing pre-3.7 code. (Registration version and running code
are different things; only an explicit extension reload swaps the latter,
which is the same dev-loop trap noted above.)

The app registers `saveForLater.highlight` again, not to do the work but
to say so: `handleLegacyHighlight` logs and shows a "Folio needs a browser
restart" toast. The two halves normally ship together, so this covers the
update window rather than a supported configuration -- but a user action
must never be a silent no-op.

### Phase 3: the library reads through the broker (2026-09-03)

The app's side of the library is now content-agnostic. Two primitives
replace the three handlers that understood Folio's file format:

- `saveForLater.fs.list` reports names, sizes, timestamps and a bounded
  head (4 KB per markdown, 600 KB of heads per listing) — enough for the
  extension to parse frontmatter without a round trip per item.
- `saveForLater.fs.read { name, offset, length }` returns base64 bytes with
  an `eof` flag, so one primitive serves both a markdown file and a
  multi-megabyte archive. 512 KiB chunks, the same cap the write path uses.

Deleted from Swift: `handleLibraryList`, `handleLibraryRead`,
`handleLibraryReadWebpage`, the `LibraryItem` shape, `frontmatterFields`,
`libraryListJSON`, `mhtmlMainDocument` and `decodeQuotedPrintable`.
Deletion and Reveal stay app-side, where Trash and Finder semantics live.

`src/save-for-later/library-data.ts` now owns item identity: frontmatter
parsing, the item list (markdown paired with its archive, newest first),
chunked reads, and the MHTML unpacking. Nine more unit tests came with it
(28 total) covering the quoted-printable and base64 archive shapes,
frontmatter quoting, and pairing — none of which was testable in Swift.

One deliberate approximation: the highlight count now comes from the
listing head rather than the whole file, so a document whose
`## Highlights` section falls beyond the first 4 KB reports 0 in the
sidebar badge. The item itself is unaffected.

Runtime-verified: 9 items listed with frontmatter-derived metadata, the
newest auto-opened and rendered, an archive unpacked into the webpage view
through chunked reads, and a highlight save plus append through the same
read layer.

### One save path: the native fallback deleted (2026-09-03)

Keeping both implementations made the Swift side GROW during the
migration (+290/-12 across phases 1-2), which is the opposite of the
point. The duplicate is gone: ~1,060 lines removed from
`SaveForLaterService.swift` (2113 -> ~1,050) plus the now-dead
`ReaderAccessibilityExtractor.markdown(fromBlocksHTML:)`.

Deleted: `runNatively` / `runArticleSave` / `runVideoSave`, the markdown
and video document builders, the Swift highlight engine (append, note
insert, item matching, source normalization), the app-side extraction
ladder and CDP capture legs, and the write helpers. The
`saveForLater.highlight` and `saveForLater.captureResult` message types
went with them, as did the extension's fallback branches.

What the app keeps: the folder and the jailed broker, the library
handlers, the toast, the flag and prefs, the menu/shortcut entry points,
the site-action gate, and the authenticated video-gist relay. A save is
now `requestExtensionSave` and nothing else — if no extension answers,
the user gets the failure toast rather than a silently different code
path. The safety net is the feature flag, not a second implementation.

The **Add Note** action, which the phase-2 move had quietly dropped from
the highlight toast, is back on the honest split: the app prompts
(the toast is native chrome, so the dialog must be) and hands the text to
Mirage via `saveForLater.addNote`, keeping the extension the only writer
of a saved item.

Verified after the cut: two highlights on one page produced a single
marked pair with `### Highlight` / `### Highlight 2`. A backup branch
`backup/folio-with-native-fallback` holds the two-implementation state in
both repos.

### Moving logic into Mirage — phase 2 (2026-09-03)

Mirage now owns the save itself; the app keeps the folder, the native
chrome, the toast, and its own path as the fallback.

- `src/save-for-later/document.ts` is the document model ported from Swift
  — frontmatter dialect, basename rules, highlight numbering, the append
  and note-insert edits, source normalization. It is pure, so it finally
  has unit tests (`document.test.ts`, 19 cases, `pnpm test` in mirage);
  the Swift equivalents were only ever runtime-verifiable.
- `src/save-for-later/save.ts` orchestrates: extraction now runs
  IN-PROCESS via `extractForTab` (no bridge round trip for the body),
  then document, broker write, capture, video gist, toast. Highlights go
  through the same module — find the item by normalized source, append,
  or save the page around the quote.
- New broker primitives: `saveForLater.fs.writeText` (whole small file),
  `saveForLater.fs.rename` (the video title promotion). Listing and
  reading reuse `saveForLater.list` / `.read`.
- The app relays and falls back: `saveForLater.save` broadcast, then
  `runNatively` when nothing answers (verified: a profile whose worker was
  asleep produced "extension save unavailable; native path" and a correct
  pair).

**The ack is acceptance, not completion.** A video save waits minutes on
the gist; an app waiting for the finished pair would time out mid-flight
and write the item a SECOND time. Mirage therefore acks as soon as it
claims the request (after the tab-ownership check), and the app's budget
is 12 s — long enough to hear "mine", short enough that a stale extension
does not stall the save. If the ack itself fails to send, Mirage stands
down so only one writer proceeds.

Both paths also now name files from the article title rather than the tab
title (which carries the site suffix), so a fallback save is named like an
extension one.

Runtime-verified: highlight save (Mirage end to end), app-driven
site-action save ("saved via extension"), and the native fallback.
A real YouTube Like save then produced a `type: video` item with a
generated article through the relayed gist call.

Error fidelity: the relay must not borrow the endpoint's vocabulary
for a failure that never reached it. `video_gist_failed` means
generation failed server-side; a backend that cannot be reached now
reports `video_gist_unreachable` (the dev-stack-down case, which is
what the note in a saved file will say).

Localization note: strings that moved into the extension (the no-article
note, the video notes, toast titles) are hardcoded English there, outside
the xcstrings pipeline. Worth an extension-side i18n pass before this
ships to non-English users.

### Moving logic into Mirage — phase 1 (2026-09-03)

Folio's logic is migrating from Swift into the extension, so fixes ship
through the extension-updater instead of an app release. The app keeps what
an extension cannot do: the folder, the native chrome, and the flag.

Phase 1 moved the **webpage-capture leg** and added the **file broker**:

- `src/save-for-later/capture.ts` (Mirage) answers
  `saveForLater.captureWebpage {tabId, requestId, name}` with
  `chrome.pageCapture.saveAsMHTML` (new `pageCapture` permission) and
  streams the archive into the broker, reporting via
  `saveForLater.captureResult` — `reader.extract`'s RPC shape.
- The broker (`saveForLater.fs.writeBegin/writeChunk/writeEnd`) is
  deliberately dumb: jailed to the configured folder, bare
  `<basename>.md|.mhtml` names only, chunks appended to a hidden part file
  that lands atomically on `writeEnd`. An abandoned upload is swept after
  180 s (verified in practice — every orphan self-cleaned).
- `runArticleSave` now reserves the markdown basename FIRST so the capture
  can stream straight into `<basename>.mhtml`; the app-side CDP snapshot
  stays as the fallback for a stale or unloaded extension.
- A broadcast reaches every profile's worker, so `capture()` returns early
  unless `chrome.tabs.get` sees the tab — a foreign worker must not race
  the owner's report or strand a part file.

**Chunk size is load-bearing**: the bridge rejects any non-`broker.` message
whose serialized payload exceeds 1 MiB
(`kDefaultPhinomenonPrivateMessageBytes`). base64 costs 4 bytes per 3, so
768 KiB chunks failed as "Message too large for native bridge" and silently
lost every capture to the CDP fallback; 512 KiB (~683 KiB on the wire) is
the shipped value. Runtime-verified: a 1.28 MB Wikipedia archive captured
via the extension in 3 chunks, no fallback, no orphan, and the library's
webpage view renders it identically to a CDP-captured one.

Remaining phases: document building + save orchestration, library reads,
then the video-gist call. The open risk is MV3 worker lifetime across a
~3-minute gist call.

### Master feature flag (2026-09-03)

The whole feature sits behind `SaveForLaterService.featureEnabled` — the
PostHog flag `folio` in release builds; DEBUG builds default to on with
`-FolioFeatureFlag NO` to rehearse the disabled state. Off means gone:
the File-menu rows are not reinserted on rebuild, the shortcut leaves the
settings listing, both settings sections hide, `canSave` (and with it the
shortcut, dispatcher, and auto-save paths) refuses, the library bridge
replies `unavailable` (never a silent drop — a pending bridge promise
would hang the page for 30 s), and Mirage removes the highlight context
menu after reading `enabled` from the `saveForLater.getArmed` reply
(fail-open for older apps; the app gates every write regardless).
Runtime-verified in both states.

### Library page (2026-09-03)

The saved items got a face: `library.html` in Mirage (built as an extra
Rollup input like `reader.html`), opened from File ▸ "Save for Later
Library" (`SaveForLaterService.openLibrary()` creates a tab on the
extension URL). The page lists the folder's items (title, site, date,
type/trigger/highlight badges, newest first), renders a selected item's
markdown via `marked` + the shared `sanitizeAndResolve` pass (extracted to
`reader-view/page/sanitize.ts`), styled by the reader surface's own
`buildStylesheet` and the user's reader style preferences — and manages
them: Open Original, Webpage Copy (an in-page view: Chromium renders MHTML
only in an outermost main frame — a file:// iframe stays blank even with
file access — so `saveForLater.readWebpage` unpacks the archive's primary
HTML document app-side, quoted-printable/base64 decoded, and the page shows
it in a fully sandboxed srcdoc iframe with a `<base>` on the source URL;
the button toggles back with "Show Article"), Show in Finder, and
a two-step Delete (armed "Move to Trash?" instead of `confirm()`: the shell
renders JS dialogs natively, which wedges when the page sits in a hidden
window).

The page cannot touch the filesystem; the app serves it over the bridge —
`saveForLater.list/read/delete/reveal/openWebpage`, all sender-gated to
Mirage, basenames validated against path escape, replies async via
`ExtensionMessaging`. The folder is the active window profile's effective
destination. A focus refresh keeps the list current, skipping the re-render
when the listing is unchanged so it never rebuilds under a click.

Runtime-verified: list, open/render (screenshot-checked against the reader
look), Webpage Copy, two-step delete to Trash. Not exercised: Show in
Finder (same validation path as delete; plain `activateFileViewerSelecting`)
and the File-menu item itself (native menus are out of automation's reach —
it follows the existing Save for Later item's pattern verbatim).

### Review fixes (2026-09-01)

A review pass over the feature found and fixed:

- **Junk items from a failed reader capture.** A right-click on the reader
  surface whose `sfl:getSelection` leg failed fell back to
  `info.selectionText` with the `chrome-extension://` page URL, producing a
  stub item with an unusable `source` and a dead deep link. Both sides now
  require an http(s) URL (`saveHighlight` and `handleHighlight`).
- **Rename race dropping highlights.** `ensureHighlightMarker`'s rename ran
  outside `appendChain`, so a second highlight arriving during the first
  one's rename could resolve the pre-rename path, fail its own rename, and
  throw on append — the highlight lost to a log line. Resolution, marker
  rename and append are now ONE serialized link: `appendHighlights(_:source:
  folder:preferred:)` re-resolves inside the chain (`resolveItem`), so a
  caller's URL is a hint, never an address. Notes take the same path, which
  also fixes a note saved after a rename landing nowhere.
- **Fragment URLs duplicating items.** Item identity compared `source`
  exactly, so highlighting `…/Baguette#History` created a second item beside
  `…/Baguette`. `normalizedSource` strips a plain `#anchor` for matching
  (a position inside one document) while keeping `#/route` and `#!/route`,
  where the fragment identifies the document.
- **Undo vs. highlights.** Undo on an automatic save's toast no longer
  trashes a pair the user has since highlighted.
- **Numbering/marker heuristics.** The next highlight number is counted
  within the `## Highlights` section only (an article body containing
  "### Highlight" no longer skews it), and the basename marker is matched as
  a suffix (a title mentioning "highlight" no longer reads as marked).
- **Deep links keep the page's own fragment** (`#/route:~:text=…`), so
  hash-routed SPAs survive; an existing `:~:` directive is replaced.
- **Highlight timestamps are ISO-8601 UTC**, the frontmatter's dialect.

Known and deliberately left: back-to-back highlight toasts replace each
other (shared `OverlayToastCenter` behavior, so only the latest highlight is
note-able from the toast; the file is always editable).

### Cross-profile extraction routing (bug found on the way)

`ReaderExtensionBridge.extractArticle` broadcasts `reader.extract`, and
the bridge (`PhiBrowserProxy::RouteBroadcast`) routes a broadcast by the
payload's `windowId` — without one it goes to the ACTIVE window's
profile. For a tab in a background or hidden window (agent Spaces) that
is the wrong profile, whose Mirage answered `no_target` in ~3 ms and won
the reply race; every such save silently degraded to the no-article stub.
Fixed on both sides: the payload now carries the owning window's id, and
a Mirage worker that cannot `tabs.get` the tab stays silent instead of
replying.

### MV3 dev-loop trap #2: the manifest is cached in prefs

Follow-up to the stale-service-worker trap: for an installed (including
`--load-extension`-registered) extension, `developerPrivate.reload`
refreshes worker *code* from disk but NOT the manifest —
`ChromeExtensionRegistrarDelegate::DoLoadExtensionForReload` prefers the
prefs-cached manifest (`Secure Preferences` →
`extensions.settings.<id>.manifest`) whenever one exists, and observed
relaunches did not re-read it either, even with a changed dist version.
Symptom here: a `permissions` addition (`contextMenus`) never took
effect (`chrome.contextMenus` undefined) while code changes kept
applying. The reliable refresh: remove the registration
(`chrome.management.uninstall` evaluated on `chrome://extensions` with
`Runtime.evaluate {userGesture: true}`), relaunch with
`--load-extension`, then `developerPrivate.reload` once for the worker.

## Verification

Mirage: `pnpm build` + repo type-check/lint/format parity — all clean.
Swift: Canary build (`PhiBrowser-canary`, Debug-Canary) succeeded; the 16
new strings were added to `Localizable.xcstrings` (en only, per the
localization guidelines).

Runtime-verified 2026-08-31 in Phi Canary with the unpacked Mirage dist
loaded: ⌥⌘S on a Wikipedia article wrote
`2026-08-31 Music Box (album) - Wikipedia.md` (frontmatter + full Turndown
body, 205 KB) and the matching `.mhtml` (Blink snapshot, 2 MB) into
`~/Documents/Phi Saved`. Caveat: the `load:phi-canary` script resolves the
app by bundle id, which can relaunch a stale DerivedData copy — launch the
intended build's path directly when the two diverge.

Highlights runtime-verified 2026-09-01 via the `sfl:debugHighlight` hook
(the pipeline behind the context-menu item): a highlight on an unsaved
Wikipedia article produced the full pair with the reader-extracted body
and a `## Highlights` section (quote as markdown with links intact, plus
a working `#:~:text=` attribution link); a second highlight on the same
page appended a second block into the same file. Not runtime-exercised:
the native rendering of the context-menu entry itself (needs a human
right-click), the reader-surface `sfl:getSelection` capture leg, and the
Add Note dialog (toast action + sheet) — all build-verified only.
