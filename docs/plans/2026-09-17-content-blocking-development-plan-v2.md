# Phi Content Blocking Development Plan v2

Status: approved direction (owner decisions confirmed 2026-09-17), pre-implementation.
Supersedes `2026-09-16-adblock-development-plan.md`.
Date: 2026-09-17
Requirements: `2026-09-16-adblock-requirements.md` (still authoritative for
goals and non-goals). Execution tracker:
`2026-09-17-content-blocking-implementation-checklist.md` (task checkboxes
and the handoff log; update it every session). Evidence: `2026-09-16-adblock-rust-feasibility.md`,
`2026-09-17-content-blocking-handoff.md`.

## What changed since v1

v1 named the layers and the patch order but left the eight gaps in the handoff
open. v2 closes them with decisions backed by code inspection and list data,
and adds the product surface the reference design (Dia's Privacy pane) makes
explicit: an **Advanced Settings** sheet with per-list checkboxes grouped as
Ad Blockers, Trackers, Cookie Banners and Regional.

| Handoff gap | v2 decision (section) |
| --- | --- |
| 1. Toggle composition | One engine per Profile built from the union of enabled lists (§4) |
| 2. Cookie banners | EasyList Cookie only, plain hide + `:style()`; uBlock Cookie Notices deferred (§5) |
| 3. Policy defaults | Concrete defaults, private/guest/PhiChat behavior (§6) |
| 4. Rules/update contract | Bundled lists refreshed by the frequent browser release cadence; remote packages are a reserved extension point (§9) |
| 5. Threading | `single-thread` feature off, immutable generations, synchronous match (§7) |
| 6. FFI failures | No panic paths; every facade call returns a status (§7) |
| 7. Tests/build | Real targets and the `out/PhiTest` configuration (§11) |
| 8. Performance | Initial numeric budgets with a measurement gate in Phase A (§12) |

## 1. Reference design

Dia's Privacy pane, from the supplied screenshots:

```text
Privacy
  Content blocking
    [hand]   Block ads              (on)
    [cookie] Block cookie banners   (on)
    [mask]   Block trackers         (on)
                                     [Advanced Settings]
  Data
    Share content data to help improve Dia   (off)   <- not in Phi scope

Advanced Ad Block Settings (sheet)
  "Block common components found across the web by using additional rules
   and filters. Learn more"
  Ad Blockers      [x] EasyList (i)  [x] uBlock - Ads (i)  [ ] uBlock - Unbreak (i)
  Trackers         [x] EasyPrivacy (i)  [ ] uBlock - Privacy (i)
  Cookie Banners   [x] EasyList - Cookie Notices (i)  [ ] uBlock - Cookie Notices (i)
  Regional         [ ] EasyList - Polska lista ... [ ] AdGuard Chinese ...
                   [ ] Frellwit's Swedish ... [ ] ABPVN List (Vietnamese)
  BCNY             [x] BCNY Blocklists (i)
                                                                    [Done]
```

"BCNY" is The Browser Company of New York, Dia's vendor; "BCNY Blocklists"
is their first-party list of site fixes, the same role as Brave's
`brave-specific.txt` and `brave-unbreak.txt`. Phi gets the equivalent
(`phi-specific`, §5).

Phi reproduces the Content blocking group and the sheet. The "Data" group is
a separate concern (analytics consent already exists in Phi) and is out of
scope here.

Phi differences from Dia, all deliberate:

- Settings are per Profile (requirement). The pane shows a Profile picker when
  more than one user-assignable Profile exists, following the Profiles pane.
- The sheet omits lists Phi cannot execute honestly in the MVP (§5).
- "uBlock - Unbreak" defaults to on. It contains only exceptions and reduces
  breakage; Dia's default-off state is not worth copying.

## 2. Scope

Building:

- Network blocking (block, exception, `important`) for ads and trackers.
- Cosmetic hiding for residual ad elements and cookie banners: host-specific
  and generic CSS, plus the `:style()` action on plain selectors.
- Three independent per-Profile toggles and a per-list catalog with defaults.
- Per-site exception by registrable domain, all categories at once.
- Bundled offline rule baseline, background compilation, atomic generation
  swap, serialized cache, degraded-state reporting.
- Privacy pane in the macOS Settings window with the sheet above.

Not building (unchanged from requirements): scriptlets, redirects and
resource replacement, procedural filters other than `:style()`, consent
clicking, WebSocket filtering, YouTube video-ad compatibility, Brave Shields
parity, fingerprinting protection, cross-device sync of policy.

## 3. Architecture

```text
phibrowser-mac (Swift)                 chromium/src (C++, Rust)
------------------------------         ---------------------------------------------
PrivacySettingsView                    chrome/browser/phinomenon/content_blocking/
  |  ContentBlockingSettings (facade)     PhiContentBlockingService (Profile-keyed)
  v                                        | prefs, catalog, generation publisher
PhiChromiumBridge  <-- ObjC protocol -->   | PhiContentBlockingURLLoaderProxy
                                           | PhiContentBlockingCosmeticsHost (Mojo)
                                           v
                                       components/phinomenon/content_blocking/
                                         engine facade (cxx) -> pinned adblock-rust
                                         mojom, catalog schema, package verifier
                                           ^
                                       chrome/renderer/phinomenon/content_blocking/
                                         PhiContentBlockingFrameObserver
                                         (CSS injection, bounded DOM batches)
```

Data flow for one request: URLLoaderFactory proxy on the UI thread -> reads
the Profile's current generation (immutable, ref-counted) -> synchronous
`Match()` -> block with `net::ERR_BLOCKED_BY_CLIENT` or forward. No IPC, no
bridge, no task hop on the request path.

Data flow for one document: renderer frame observer -> Mojo
`GetDocumentResources(url)` to the browser -> injects one user stylesheet via
`blink::WebDocument::InsertStyleSheet` -> observes DOM mutations, batches new
class/id names -> Mojo `GetHiddenClassIdSelectors(classes, ids)` -> appends
selectors. No Blink modification.

Upstream files touched, each behind `#if BUILDFLAG(IS_PHI_BROWSER)`:

| File | Hunk |
| --- | --- |
| `chrome/browser/chrome_content_browser_client.cc` | Append the Phi proxy in `WillCreateURLLoaderFactory` before `MaybeProxyNetworkBoundRequest` (line 6761 on phi-r152) |
| `chrome/browser/prefs/browser_prefs.cc` | Register Profile prefs in the existing Phi hunk at 2283 |
| `chrome/renderer/chrome_content_renderer_client.cc` | Create the frame observer in `RenderFrameCreated`; register the Mojo binder through the existing reviewed path |
| `chrome/common/pref_names.h` | Pref name constants, `phi.content_blocking.*` |
| `chrome/browser/BUILD.gn`, `chrome/renderer/BUILD.gn` | Deps on the new Phi targets |

Everything else lives in Phi-owned directories and carries no uplift cost.
`chrome/renderer/phinomenon/` does not exist yet; this feature creates it.

## 4. Composition model: one engine, a list mask

The three toggles and the per-list checkboxes resolve to one set of enabled
lists per Profile:

```text
enabled_lists = { L in catalog | L.category is on AND L.checked }
```

One `adblock::Engine` per Profile is compiled from exactly that set. A
toggle or checkbox change recomputes the set, compiles a new generation on
the thread pool, and swaps it atomically. Nothing is enabled or disabled
inside a running engine.

Why one engine rather than one per category:

- Exception and `important` semantics are only correct inside one engine.
  "uBlock - Unbreak" is an exceptions-only list; split engines would apply
  its exceptions to nothing. Brave's multi-engine `important` short-circuit
  exists to work around exactly this and is not worth importing.
- adblock-rust `$tag=` only exists on network filters (`src/filters/network.rs:417`);
  cosmetic rules cannot be toggled by tag, so tag-based switching would
  leave cookie-banner rules always on.
- Toggle changes are rare. A rebuild costs seconds in the background; the
  old generation keeps serving until the new one is published.

Consequence to document in the UI copy and tests: with ads off and trackers
on, a URL matched by both EasyList and EasyPrivacy is still blocked. This is
the expected meaning of "Block trackers".

Site exceptions are not engine rules. The proxy and the cosmetics host check
the top-level site's registrable domain against the Profile's exception set
before consulting the engine, so adding an exception never triggers a
rebuild and applies to all three categories at once.

## 5. List catalog v1

The catalog is a JSON resource compiled into the browser
(`components/phinomenon/content_blocking/resources/catalog.json`) with the
bundled list texts. Each entry: `id`, `category`, `title_key`,
`description_key`, `sources[]`, `homepage`, `license`, `default_checked`,
`bundled`.

| id | Category | Sources | License | Default |
| --- | --- | --- | --- | --- |
| `easylist` | ads | https://easylist.to/easylist/easylist.txt | GPLv3 / CC BY-SA 3.0 (dual) | on |
| `ublock-ads` | ads | uAssets `filters/filters.txt`, `filters-2020.txt` … `filters-2026.txt`, `filters-general.txt`, `quick-fixes.txt` | GPLv3 | on |
| `ublock-unbreak` | ads | uAssets `filters/unbreak.txt` | GPLv3 | on |
| `easyprivacy` | trackers | https://easylist.to/easylist/easyprivacy.txt | GPLv3 / CC BY-SA 3.0 | on |
| `ublock-privacy` | trackers | uAssets `filters/privacy.txt` | GPLv3 | off |
| `easylist-cookie` | cookies | https://secure.fanboy.co.nz/fanboy-cookiemonster_ubo.txt | CC BY 3.0 (per list header) | on |
| `easylist-polish` | regional | https://raw.githubusercontent.com/MajkiIT/polish-ads-filter/master/polish-adblock-filters/adblock.txt | verify | off |
| `adguard-russian` | regional | https://filters.adtidy.org/extension/ublock/filters/1.txt | GPLv3 | off |
| `adguard-chinese` | regional | https://filters.adtidy.org/extension/ublock/filters/224.txt | GPLv3 | off |
| `adguard-japanese` | regional | https://filters.adtidy.org/extension/ublock/filters/7.txt | GPLv3 | on when a preferred language is `ja` |
| `bulgarian` | regional | https://stanev.org/abp/adblock_bg.txt | verify | off |
| `phi-specific` | phi | `resources/lists/phi-specific.txt` in this repo, no remote source | Phi | on |

uAssets base URL: `https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/`.
Source URLs for the non-regional entries come from Brave's
`adblock-resources/filter_lists/list_catalog.json` (`default` and cookie
entries) and were checked against the uAssets `filters/` directory listing on
2026-09-17. Regional entries come from the same catalog. Pin a commit of that
catalog when Phase A starts; licenses marked "verify" must be read from the
list header before the list ships. The owner confirmed this regional set for
v1 on 2026-09-17.

Deliberately excluded from v1, with the measurement behind each:

- **uBlock - Cookie Notices** (`annoyances-cookies.txt`, 5,756 lines): 2,156
  scriptlet rules, of which 949 `trusted-set-cookie` and 894
  `trusted-click-element`, and only 109 plain hide rules. It is a consent
  automation list. Shipping it under the MVP's no-scriptlet, no-consent rule
  would render a checkbox that does almost nothing. Revisit with scriptlets.
- **Albania** and other regional lists Dia shows but Brave's catalog does not
  carry: no verified source URL. Add when a source and license are confirmed.
- Malware/URLhaus lists in Brave's default set: a security feature, not
  content blocking; separate decision.

EasyList Cookie (29,053 lines) is viable: 22,727 plain hide rules, 161
`:style()` rules, 2,448 scriptlet rules (mostly `set-cookie`) that are
skipped and counted in diagnostics. The `:style()` rules are what unlock
scrolling on pages that set `overflow:hidden` while a banner is open; §8
executes them.

Regional lists are a fourth catalog group but count as the ads category:
they are active only while Block ads is on.

Regional defaults follow language, as Brave does: each regional entry has
`langs[]`, and its default is checked when any of the user's preferred
languages (`intl.accept_languages`, first two entries) matches. The user's
explicit choice in the sheet, stored in `list_overrides`, always wins over
the language default. Japan is a primary market for Phi, so
`adguard-japanese` (AdGuard Japanese filter, 12,746 lines: 2,246 network,
5,631 plain hide, 195 scriptlets skipped; checked 2026-09-16 build) is in
v1 and defaults on for `ja` users. Chinese, Russian, Polish and Bulgarian
follow the same rule.

`phi-specific` is the fifth group ("Phi" in the sheet) and Phi's own
first-party list, maintained in the Chromium fork and shipped with every
release. It holds site-specific fixes, unbreak exceptions for breakage
caused by the other lists, and rules Phi needs for its own surfaces. It
starts nearly empty. It belongs to no toggle category: it is active whenever
at least one category is on, because its exceptions exist to repair what
the other lists do. Users can uncheck it in the sheet.

## 6. Policy and defaults

Placement (2026-09-20): the toggles and the Advanced sheet live in the Profiles settings tab, in the selected profile's detail panel, with the other per-profile settings. There is no separate Privacy tab.

| Setting | Pref | Default |
| --- | --- | --- |
| Block ads | `phi.content_blocking.block_ads` | false |
| Block cookie banners | `phi.content_blocking.block_cookie_banners` | false |
| Block trackers | `phi.content_blocking.block_trackers` | false |
| List overrides | `phi.content_blocking.list_overrides` (dict id -> bool) | empty; catalog defaults apply |
| Site exceptions | `phi.content_blocking.site_exceptions` (list of registrable domains) | empty |

All three toggles start off; the user opts in from Privacy settings. The
feature flag stays on so a toggle takes effect without a restart. Decided
by the owner on 2026-09-20 (it replaces the 2026-09-17 decision to start
enabled).

Profile behavior:

- Normal Profiles: prefs above, persisted.
- Off-the-record Profiles: read the parent Profile's prefs and generation;
  exception changes made in a private window are kept in memory only and
  dropped with the Profile.
- Guest: catalog defaults, no persistence.
- PhiChat profile (`<user data dir>/PhiChat`, never user-visible): filtering
  off. The chat page is a Phi-owned extension origin and must not depend on
  third-party filter lists.
- Feature flag: `base::Feature kPhiContentBlocking`, default disabled until
  Phase D ships the pane, then default enabled. Non-Phi builds do not compile
  the feature.

Changes apply to new requests and new documents. Open pages are not reloaded.

## 7. Engine facade, threading and failures

Vendoring: pin adblock-rust `1c0740d27d531a2389c808212a8702592bb74138`
(Cargo 0.13.3) under `third_party/rust/adblock/v0_13/` following Chromium's
`cargo_crate`/`rust_static_library` conventions (reference:
`components/qr_code_generator/BUILD.gn`). Features:
`embedded-domain-resolver`, `full-regex-handling`. **`single-thread` off**,
so `Engine: Send + Sync`. `css-validation` on for the cosmetic path.
Toolchain: Chromium's pinned rustc 1.98.0 matches the crate's edition 2024
requirement; confirm in Phase A.

cxx bridge (`components/phinomenon/content_blocking/rs/lib.rs`), all calls
return a status enum, never panic:

```text
new_engine(lists: &[ListInput], debug: bool) -> Result<Box<Engine>, Status>
engine_from_cache(bytes: &[u8]) -> Result<Box<Engine>, Status>
engine_serialize(&Engine) -> Vec<u8>
engine_match(&Engine, req: &RequestInput) -> MatchResult
engine_document_resources(&Engine, url: &str) -> DocumentResources
engine_hidden_class_id_selectors(&Engine, classes, ids, exceptions) -> Vec<String>
engine_stats(&Engine) -> Stats   // rules loaded, rules skipped by kind
```

`MatchResult` carries `matched`, `exception`, `important`, and
`has_redirect` so the browser can log unsupported redirect/rewrite results
without acting on them. `RequestInput` carries the explicit resource type
enum (document, subdocument, script, stylesheet, image, font, media, xhr,
websocket-excluded, other), the top-level and initiator origins, and the
third-party bit computed by the browser from Chromium's origin data. The
facade maps `fetch` to `xhr`; adblock-rust only recognizes `xhr` and
`xmlhttprequest` (`src/request.rs:87`).

Threading model:

- A generation is `base::RefCountedThreadSafe`, holds a `Box<Engine>`, and is
  immutable after construction. Compilation and deserialization run on a
  `ThreadPool` sequence with `MayBlock()`.
- The service publishes a generation by swapping a `scoped_refptr` on the UI
  thread. Readers hold their own ref for the duration of one match. The
  previous generation dies when its last reader releases it.
- Matching is synchronous on the caller's thread. This is what makes the
  request path free of task hops. adblock-rust guards its regex cache with a
  lock when `single-thread` is off; contention is bounded by the first-use
  compile of lazily built regexes and is measured in §12.
- If the §12 match budget fails, the fallback is a dedicated
  `SequencedTaskRunner` per Profile and an asynchronous proxy continuation.
  The facade contract does not change in that case.

**Gate decision (2026-09-18, measured in Task A4):** synchronous matching
stays. Single-thread steady state is p50 51 µs / p95 61 µs / p99 65 µs,
under the 100 µs p95 gate. Two findings shape Phase B:

- adblock-rust takes a process-wide `Mutex<RegexManager>` for the whole of
  `check_network_request`, so concurrent callers are serialized and lock
  convoys produce multi-millisecond tails (4 threads: p99.9 52 ms, max
  287 ms). `Engine::Match()` is therefore called from one sequence only (the
  URLLoader proxy's sequence); it is never fanned out across threads.
- The first match against a rule set compiles its regexes lazily (cold pass
  p99 194 µs, max 3 ms). The service warms a new generation by matching a
  fixed set of representative requests on the thread-pool sequence before
  publishing it.

Implementation notes from Phase A: the facade reports failures through an
out-parameter `Status` instead of a cxx `Result` (Chromium builds without
C++ exceptions); the cxx namespace is `phi::content_blocking::ffi` and the
opaque type is `RustEngine`; `css-validation` is on. The vendored crate is
crates.io 0.13.3, which differs from the pinned master commit in
`data_format` (DAT version), `request.rs` and `utils.rs`.

Failure policy:

- Chromium builds Rust with `panic=abort`; `catch_unwind` is not a recovery
  mechanism. Inputs are validated on the C++ side (UTF-8, length caps) and the
  Rust side returns `Status` for every recoverable case (bad list text is
  tolerated by adblock-rust; bad cache bytes return
  `DeserializationError`).
- Any failure to build a generation keeps the previous one. If no generation
  exists, the Profile runs unfiltered and the service reports `degraded`.
- Serialized cache identity: engine revision, feature set, sorted list ids
  with content hashes. A mismatch skips the cache and rebuilds from text.

## 8. Renderer cosmetic execution

- On document start, request `DocumentResources` once per document; inject
  `hide_selectors` as one stylesheet (`{display:none !important}`), plus one
  rule per `:style()` action whose selector parses as a plain CSS selector.
  Other `procedural_actions` entries are dropped and counted.
- `generichide` true means no generic class/id queries for that document.
- MutationObserver batches: collect new class and id names, flush at most
  every 100 ms and at most 500 names per flush, ask the browser for matching
  generic selectors, append to the same stylesheet. Cap total selectors per
  document at 10,000.
- Cross-origin iframes get their own document resources by their own URL.
- Tear down on navigation, frame detach, BFCache eviction and renderer
  shutdown. Prerendered documents run the same path; activation does not
  re-request.
- `injected_script` from the engine is ignored in the MVP.

## 9. Rules and updates

Decision (owner, 2026-09-17): the MVP updates rules through browser
releases. Phi ships often enough that bundled lists stay fresh, and no rule
hosting or signing infrastructure is needed now. Remote packages remain a
reserved extension point; the design below is kept so the service, cache and
status reporting do not need to change when it is picked up.

Phase B ships the bundled baseline: catalog plus the text of every
`bundled: true` list, snapshotted at build time by a script in
`components/phinomenon/content_blocking/tools/snapshot_lists.py` that records
source URL, fetch time, SHA-256 and the license line from each list header.
The browser never needs the network to filter. The snapshot script runs as
part of release preparation so every release carries current lists; the
generation id is the build number.

What is reserved for remote updates, not built now:

- The service already loads generations from a directory of list texts
  plus a manifest, so a downloaded package uses the same loader as the
  bundled baseline.
- `PhiContentBlockingSettings.status` already carries generation id and
  timestamp, so the pane needs no new fields.
- The catalog entry keeps `sources[]` so a future updater knows what to
  fetch.

Reserved package contract (unimplemented):

```text
package.json   { format: 1, engine_revision, features, generation_id,
                 created_at, expires_at, lists: [{id, sha256, size, version}] }
lists/<id>.txt
package.sig    Ed25519 over package.json, public key compiled into the browser
```

Rules: a package is rejected if the signature fails, `engine_revision` is
not the running one, any hash or size mismatches, `expires_at` has passed,
or `generation_id` is not greater than the active one (anti-rollback,
except an explicit user reset to the bundled baseline). Only list text
travels; there is no compiled engine and no resources in the package, so a
package can never grant scriptlet permissions.

Hosting and key custody are decided when this extension point is picked up.

## 10. Bridge and macOS surface

Bridge additions to `PhiChromiumBridgeProtocol`, in the Profile-scoped block
near the search-engine and download-location methods, all main-thread,
completion-based, following `setDefaultSearchEngine:engineId:completion:`:

```text
- (void)getContentBlockingSettings:(NSString *)profileId
        completion:(void (^)(PhiContentBlockingSettings *settings, NSString *error))completion;
- (void)setContentBlockingCategory:(NSString *)profileId
        category:(PhiContentBlockingCategory)category enabled:(BOOL)enabled
        completion:(void (^)(BOOL ok, NSString *error))completion;
- (void)setContentBlockingList:(NSString *)profileId listId:(NSString *)listId
        enabled:(BOOL)enabled completion:(void (^)(BOOL ok, NSString *error))completion;
- (void)setContentBlockingSiteException:(NSString *)profileId
        domain:(NSString *)domain enabled:(BOOL)enabled
        completion:(void (^)(BOOL ok, NSString *error))completion;
```

`PhiContentBlockingSettings` carries the three flags, the catalog (id, category,
title, description, homepage, checked), site exceptions, and status
(`active`, `updating`, `degraded`, generation id and timestamp). One delegate
callback, `contentBlockingStatusChanged:profileId:`, refreshes the pane.

Swift:

- `Sources/ChromiumBridge/ContentBlockingSettings.swift`: the facade that
  owns the bridge calls (pattern: `ProfileManager`, `SessionRestorePreference`).
  Views never touch `bridge?` directly.
- `Sources/UserInterface/Preferences/Settings.swift`: add `privacy`.
- `Sources/UserInterface/Preferences/Privacy/PrivacySettingViewController.swift`,
  `PrivacySettingHostingViewController.swift`, `PrivacySettingsView.swift`:
  the pane trio, inserted in `AppController+Settings.swift` `panes()` after
  Account.
- `Sources/UserInterface/Preferences/Privacy/ContentBlockingAdvancedSheet.swift`:
  the sheet, presented with `.sheet(isPresented:)` as in
  `PasswordManagerSectionView.swift:64`. Sections: Ad Blockers, Trackers,
  Cookie Banners, Regional, Phi; each row is a checkbox, title, and an info
  button that shows description, source URL and license in a popover.
- Toggles bind optimistically and revert on bridge failure, as
  `ProfileDetailSettingsView.searchBinding` does.
- Strings: keys `settings.privacy.*` and `settings.privacy.contentBlocking.*`
  in `Resources/Localizable.xcstrings`, English only, per
  `docs/i18n/localization-guidelines.md`. List titles are catalog strings
  keyed `settings.privacy.contentBlocking.list.<id>.title`.
- Toolbar per-site control (page-level "Content blocking off for this site")
  is Phase E and reuses the site-exception bridge call.

## 11. Phases

Each phase merges on its own and leaves the product usable. The feature flag
stays off until D.

| Phase | Deliverable | Mergeable state |
| --- | --- | --- |
| A | Vendored engine, cxx facade, catalog schema, unit tests, benchmark harness | Builds in Phi and non-Phi configs; no runtime change |
| B | Profile service, prefs, bundled baseline, serialized cache, URLLoaderFactory proxy, feature flag | Network blocking works behind the flag; browser tests pass |
| C | Renderer observer, Mojo cosmetics host, `:style()` execution | Cosmetic hiding behind the flag; renderer tests pass |
| D | Bridge API, Privacy pane, Advanced sheet, flag on by default | User-visible MVP |
| E | Site-exception toolbar control, local diagnostics page | Per-site relief and support tooling |
| Reserved | Signed remote packages, updater, rollback UI | Not scheduled; see §9 |

Phase A is not an investigation: the design questions are settled above.
Its measurement gate (§12) decides between the two threading placements
that share one contract.

## 12. Performance budgets

Initial budgets, measured on an M-series laptop against a filtering-disabled
baseline in `out/PhiTest`. Tighten after the first measurement; do not ship
above them.

| Metric | Budget | Measured 2026-09-18 (Task A4, M-series, `out/PhiTest`) |
| --- | --- | --- |
| Compile the default enabled set (EasyList, uBlock Ads, Unbreak, EasyPrivacy, EasyList Cookie, phi-specific; 7.3 MB text, 119,883 network + 66,884 cosmetic rules) | < 3 s on the thread pool | 198 ms |
| Serialize the cache | - | 2.5 ms, 9.3 MB |
| Deserialize the cache for the same set | < 300 ms | 20 ms |
| `Match()` p50 / p95 / p99, single thread, warm | < 20 µs / < 100 µs / < 500 µs | 51 µs / 61 µs / 65 µs (p99.9 176 µs, max 0.8 ms) |
| `Match()` cold first pass (lazy regex compile) | - | p50 51 µs, p99 194 µs, max 3 ms over 200 requests |
| `Match()` from 4 threads concurrently | not a supported mode | p99.9 52 ms, max 287 ms: serialized by adblock-rust's regex mutex |
| Additional RSS per Profile with the default set | < 80 MB | 25 MB after compile, 48 MB after 100k matches (test process) |
| Cosmetic stylesheet build per document, main thread | < 5 ms | not yet measured (Phase C) |
| Page load delta (median over 20 sites, network cached) | not slower than baseline by more than 2% | not yet measured (Phase D) |

The p50 result is above its 20 µs budget; p95 and p99 are inside theirs.
The gate is p95, so synchronous matching stays (see §7). The p50 cost is
dominated by per-request URL parsing and public-suffix lookups inside the
facade (`parse_url` is called for the request URL and the source origin);
passing Chromium's already-parsed host names is the first optimization to
try if page-load measurements in Phase D need it.

Phase A ships a `rust_unit_test`-style benchmark that prints these numbers,
and the p95 result is the gate in §7.

## 13. Verification

Build configuration: `out/PhiTest`
(`is_phi_browser=true is_mac_phi=true is_component_build=false
is_official_build=false dcheck_always_on=true symbol_level=0`). `out/PhiDebug`
cannot link `browser_tests` (component-build symbol cycle through `phibridge`).
Neither directory exists on this checkout as of 2026-09-17; expect a multi-hour
first build.

Targets (added to existing suites, no new test binaries):

| Layer | Suite / filter | Coverage |
| --- | --- | --- |
| Rust facade | `components_unittests --gtest_filter=PhiContentBlockingEngine*` | list union, block/exception/important, resource type mapping, cache round-trip, corrupt cache, skipped rule counts |
| Browser service | `unit_tests --gtest_filter=PhiContentBlockingService*` | list mask from prefs (all eight toggle combinations plus overrides), generation swap, degraded fallback, Profile isolation, site exceptions |
| Network | `browser_tests --gtest_filter=PhiContentBlockingNetwork*` | document, iframe, script, image, XHR, fetch, redirect chain, keepalive, prefetch, dedicated/shared/service worker scripts, CacheStorage response (documented as not covered), extension proxy coexistence, private Profile |
| Renderer | `browser_tests --gtest_filter=PhiContentBlockingCosmetic*` | initial CSS, `:style()`, generichide, dynamic DOM, child frames, navigation cleanup, BFCache restore, prerender |
| Mac | `PhiBrowserTests` `ContentBlockingSettingsTests` | facade maps bridge results, optimistic revert, catalog grouping |

Manual acceptance uses a local fixture site with server-side request
counters (`tools/content_blocking_fixture/`): a blocked request must not
reach the server; a hidden element must still be requested when only
cosmetic rules match. Cookie-banner fixture: banner hidden, page scrolls,
no consent cookie set. Check five real sites per category and record
breakage.

Release gates: all suites above, `git diff --check`, non-Phi build byte
identity, milestone patch replay, license inventory, budgets in §12.

## 14. Owner decisions

Confirmed on 2026-09-17:

- All three categories default on (§6). Superseded on 2026-09-20: they
  default off, see §6.
- Regional list set for v1 is the five verified entries in §5, with
  language-based defaults; Japanese added 2026-09-17 because of the user
  base.
- Remote rule packages are deferred; rules ship with browser releases and
  the package contract stays reserved (§9).

Open, not blocking:

- Phase E toolbar placement for the per-site control. Decide once Phase D is
  visible.

## 15. Fragile assumption

This plan assumes `WillCreateURLLoaderFactory` proxy composition stays the
embedder's request interception point and that a proxy placed before
`MaybeProxyNetworkBoundRequest` sees renderer subresources, workers and
navigations. If a milestone moves interception, the proxy patch is rewritten
while the engine facade, service, prefs, bridge and UI are untouched. The
browser tests in §13 exist to detect the regression at replay time.

## 16. Rollback

- Runtime: turn the feature flag off or reset to the bundled baseline; no
  browsing data changes.
- Code: revert the upstream hunks listed in §3; Phi-owned directories can
  stay compiled out.
- Prefs: new namespaced keys with safe defaults; no migration.
