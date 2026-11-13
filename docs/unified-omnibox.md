# Unified Omnibox

The unified Omnibox (PHI-1817) ranks Phi pins, bookmarks and commands together
with Chromium's own autocomplete results. It serves two surfaces:

- the Mac Omnibox (Cmd+T, Cmd+L, the address bar);
- the Sidecar NTP search box (`phi-ai`, `ai-extension/sidecar`).

Chromium owns the query session and the ranking. Phi owns the pin and bookmark
data, the authority over which data a window may see, and the execution of pins,
bookmarks and commands. Neither side ranks or opens what the other owns.

Code and protocol names still say "V2" (`performOmniboxV2Operation`,
`omniboxBeginSessionV2`, `[OmniboxV2]` logs). They refer to this feature.

## Switch

Phi decides whether the feature is on. Nothing else does.

| Where | What |
| --- | --- |
| Phi | `UnifiedOmnibox.isEnabled` in [PhiChromiumCoordinator+OmniboxV2.swift](../Sources/ChromiumBridge/PhiChromiumCoordinator+OmniboxV2.swift). On in Nightly builds whose bundle ID is `com.phibrowser.canary.Mac`; off everywhere else. Plain Debug also defines `NIGHTLY_BUILD`, so the bundle ID is what tells Canary apart. |
| Bridge | `PhiChromiumBridgeDelegate.isUnifiedOmniboxEnabled` (optional). Phi returns `UnifiedOmnibox.isEnabled`. |
| Chromium | `phi::IsUnifiedOmniboxEnabled()` → `PhiBridgeWrapper::IsUnifiedOmniboxEnabled()`. False when the delegate lacks the selector and on non-Mac builds (stub). There is no Chromium feature flag. |
| Sidecar | The NTP always calls `begin` and follows its capabilities. It has no switch of its own. |

Chromium checks the switch when a session begins:

- the native `begin` operation in `PhiChromiumBridge.mm`;
- `phinomenonPrivate.omniboxBeginSessionV2` in `omnibox_v2_api.cc`;
- `OmniboxSessionController::Create`.

When it is off, `begin` returns capabilities with `protocolVersion: 0`. The Mac
client (`OmniboxNativeUIClient`) and the Sidecar client both treat that as
"use legacy" for the whole presentation. A missing bridge API (`missing_api`)
falls back the same way. Any other failure closes the session instead.

Phi also uses the switch locally: `OmniBoxViewModel(enableUnifiedOmnibox:)`
routes the Mac Omnibox to the unified session only when it is on.

## Architecture

```text
Mac Omnibox                                    Sidecar NTP
OmniBoxViewModel                               UnifiedSearchBox / use-omnibox-v2-adapter
  └ OmniboxNativeUIClient                        └ omnibox-v2-client
      │ performOmniboxV2Operation(op, json)          │ phinomenonPrivate.omnibox*V2
      ▼                                              ▼
PhiChromiumBridge (one session per window)     OmniboxDocumentSession (one per NTP document)
      └──────────────┬───────────────────────────────┘
                     ▼
            OmniboxSearchSession          snapshots, requests, revisions, selection
            OmniboxSessionController      runtime for one session
              ├ AutocompleteController    stock, without kBookmark
              ├ NativeIndex + NativeMatcher   Phi pins/bookmarks
              ├ ResultComposer            the only Phi ranking layer
              └ FrozenNavigation          ordinary row execution
                     │ PhiBridgeWrapper (begin/query/stop/end/advance/execute)
                     ▼
            PhiChromiumCoordinator+OmniboxV2
              └ BrowserState.omniboxNativeSearchAdapter (one per window)
                  ├ OmniboxNativeContextAuthority   scope binding, revoke tokens
                  ├ LocalStore FIFO                 snapshot reads, entity validation
                  ├ OmniboxLearningStore            last choice per input
                  └ BrowserState                    entity dispatch, commands
```

### Source map

| Responsibility | Phi | Chromium (`chrome/browser/`) |
| --- | --- | --- |
| Switch | `PhiChromiumCoordinator+OmniboxV2.swift` | `phinomenon/omnibox_session_controller.*` (`IsUnifiedOmniboxEnabled`) |
| Mac transport | `ChromiumBridge/OmniboxNativeUIClient.swift` | `phinomenon/phi_app_bridge/PhiChromiumBridge.mm` (`performOmniboxV2Operation`) |
| NTP transport | — | `extensions/api/phinomenon_private/omnibox_v2_api.cc`, `omnibox_document_session.*` |
| Session | — | `phinomenon/omnibox_search_session.*` |
| Runtime and ranking | — | `phinomenon/omnibox_session_controller.*`, `omnibox_native_matcher.*`, `omnibox_result_composer.*`, `omnibox_match_quality.*`, `omnibox_native_snapshot.*`, `omnibox_provider_client.*`, `omnibox_frozen_navigation.*` |
| Native data authority | `ChromiumBridge/OmniboxNativeSearchAdapter.swift`, `OmniboxNativeSearchAuthority.swift` | `phinomenon/phi_app_bridge/phi_bridge_wrapper.*` |
| Native data | `LocalStorage/LocalStore+Omnibox.swift`, `OmniboxNativeSearchSnapshot.swift`, `OmniboxLearningStore.swift` | — |
| Execution | `States/BrowserState+Omnibox.swift`, `BrowserState+OmniboxCommand.swift` | bridge `createOmniboxEntityTab` / `activateOmniboxEntityTab` |
| Mac UI | `UserInterface/AddressBar/OmniBoxViewModel.swift`, `OmniBoxContainerViewController.swift` | — |

Sidecar: `src/components/unified-search/omnibox-v2-*.ts`,
`use-omnibox-v2-adapter.ts` and `docs/sidecar-omnibox-v2.md` in `phi-ai`.

## Session protocol

Both surfaces use the same operations. The Mac sends them as JSON through
`performOmniboxV2Operation`; the NTP calls one Promise API per operation.

| Operation | Contract |
| --- | --- |
| `begin` | Owner (window, or NTP document) is derived by the browser, never from the caller. Returns a random session handle and capabilities. A new `begin` supersedes the owner's previous session. |
| `start` | `request` is a strictly increasing integer. Returns the first complete snapshot. |
| `watch` | Returns the next revision of the current request, or `no_change` after 2 s. Not allowed after `done`. |
| `invalidation` | One-shot waiter that returns only a close reason. Registered right after `begin`. |
| `stop` | Stops the current request only. |
| `select` | Executes a row by `(request, revision, resultId)` with an intent. Never by URL, line or GUID. |
| `delete` | Mac only. Deletes a deletable ordinary row through `AutocompleteController::DeleteMatch`. |
| `end` | Closes the given handle. Idempotent. |

Snapshot envelope: request, revision, rows (at most 8), default row and its
state (`ready` / `pending` / `unavailable`), `done`, per-provider status and
capabilities. The envelope is at most 128 KiB.

- `resultId` is bound to the request and the row's action. It is the only value
  accepted by `select`.
- `rowKey` is an HMAC of the row identity with the session key. It is stable
  across keystrokes and is used for display only (matching a held Enter).
- The session keeps the last 3 snapshots of the current request for 30 s. An
  older reference is `stale`.
- An idle session closes after 60 s. The Mac client treats a snapshot older
  than 25 s as not selectable and re-queries first.

Close reasons: `ended`, `superseded`, `context_changed`, `store_closed`,
`surface_hidden`, `document_gone`, `window_closed`, `idle_expired`,
`feature_disabled`, `invalid_session`, `unsupported_context`.

A selection consumes the request before dispatching, so a duplicate `select`
returns `already_consumed` and does nothing.

## Native data

### Scope

Phi serves native data only for the window's current context
(`BrowserState.currentOmniboxNativeScope()`):

- not incognito, Kiosk or Agent Space; no backup import in progress; browser
  access is Guest or signed in; no account or Guest transition in progress;
- the window is presented (not dormant or hidden) and its LocalStore is open and
  accepted by `SpaceManager`;
- no group overview, split preview or visible Peek; the focused tab is not
  grouped or waiting to become a split.

Bookmarks come from the current profile and Space. Pins come from the current
pin scope (Space, profile or app). The scope, account, store, profile, Space and
target tab form a binding. Each binding carries a token that Chromium stores;
a revoke with an old token cannot close a newer binding.

When the focused tab is in a split, bookmarks and pins are reported as
`unavailable`; commands are still offered.

### Split pins and bookmarks

A split pin or bookmark is one row. Phi sends its panes (two to four
`{title, url}`, in layout order) as `panes`; the entity title is the pane titles
joined by ` | ` and the entity URL is the first pane's.

- A pinned split is offered by its first member in sidebar order (`index`);
  the other members are left out. Membership comes from the persisted
  `splitPaneGuids` (on any member) or `splitPartnerGuid` (either direction).
- A split bookmark reads `secondaryUrl`, `secondaryTitle` and
  `splitExtraPanes`. A pane without a title shows its host.
- A damaged split (a missing member, more than four panes, a non-HTTP pane)
  leaves out that row only.
- Chromium indexes one node per pane, so any pane's title or URL finds the row,
  and keeps the best pane per entity. A split is never inline, its quality is
  at most Q2 (a URL alone never takes the top slot), and it never hides an
  ordinary row of one of its pages.
- Execution opens or focuses the split through the sidebar paths
  (`openPinnedSplit`, `openBookmark`) and focuses the first pane. A split that
  is still being created or recreated, or has a grouped member, is refused.

### Snapshot

Chromium reads one snapshot per session, on the session's first `start`, and
matches every keystroke against an in-memory `TitledUrlIndex`.

- The read is a read-only LocalStore FIFO job. Each session has at most one job
  in the FIFO plus one latest slot; the read deadline is 300 ms.
- Budgets per kind: 1024 candidates and 512 KiB. Exceeding either fails that
  kind (`limit_exceeded`), not the other. The whole packet is at most
  1 MiB + 16 KiB.
- Phi decorates the snapshot with runtime state: whether a pin or bookmark is
  open and its current URL (for a split, whether its split view is live), the
  command catalog and the learning entries. The focused tab's own entity is
  excluded.
- 300 ms after a LocalStore write is submitted while sessions are live, Phi
  calls `refreshOmniboxNativeData(windowId:expectedBindingToken:)`. Chromium
  re-reads, swaps the index and recomposes the current result.

Execution validates the chosen entity by ID, title and URL. An unrelated write
does not make displayed rows stale.

## Ranking

### Principles

- No file under `components/omnibox` is modified. Ordinary rows go through the
  stock `AutocompleteController`, with `kBookmark` removed from the provider
  mask because Phi bookmarks come from the native snapshot.
- Phi ranking is one layer, `ResultComposer`, run on `controller->result()`
  after each Chromium publish. It is pure functions over plain structs.
- Ordinary rows keep their Chromium order. The composer may put one native row
  on top, insert one block of native rows, append commands, hide plain history
  duplicates and trim the tail.
- Native rows are compared only with native rows.

### Native matching

`NativeMatcher` matches the input against each kind with prefix search and keeps
at most 16 candidates. Each candidate gets a quality
(`omnibox_match_quality.cc`):

| Quality | Condition |
| --- | --- |
| Q4 | URL input whose canonical URL equals the entity URL |
| Q3 | Normalized input equals the normalized title |
| Q2 | Title word prefix, structured URL prefix or host prefix (`phi` → `phibrowser.com`) |
| Q1 | Any other match |

Pins match on their pinned URL and title, not on the page currently open in the
pin.

Order among natives:
`(last chosen, quality, recency bucket, pin before bookmark, lexical score, key)`.

### Composition

`ComposeParams` defaults: `rank_mode = full`, `native_budget = 3`,
`max_rows = 8`, strong-match length 3 Latin or 2 CJK characters,
`command_budget = 2`, `min_command_chars = 2` (1 with CJK).

1. **Gate.** `rank_mode = off`, keyword mode, `@` input or zero suggest: return
   Chromium's result unchanged.
2. **Top slot.** Let `D` be Chromium's default and `E` the first native.
   - Forced query (`?text`): never.
   - The last choice for this input was an ordinary row: never.
   - `E` was the last choice for this input: always.
   - `E` is strong when it is Q4 or Q3, or Q2 with enough characters.

   | `D` | `E` takes the top when |
   | --- | --- |
   | none, or a search row | `E` is strong |
   | `kUrlWhatYouTyped` | `E` is Q4 or can inline |
   | other navigation (history, shortcut, navsuggest) | `E` is Q4 |
   | anything else | never |

3. **Select.** Up to `native_budget` natives in order. In `fill_only` mode,
   step 2 is skipped and natives only fill vacant slots.
4. **Dedupe.** Hide an ordinary navigation row that is not row 0, has no actions
   and has the same stripped URL as a shown native.
5. **Insert.** The remaining natives go as one block before the first ordinary
   navigation row at index ≥ 1 (after the search group), never directly before
   a split action row.
6. **Trim** to `max_rows` from the ordinary tail. Row 0 and the verbatim row
   are kept; Q1 natives only fill vacant slots.
7. **Commands.** Up to `command_budget` commands go after the rows. When the
   list is full, a command of Q2 or better replaces the last plain search
   suggestion that is not row 0, not verbatim and not a split action parent.
8. **Default.** Row 0 is the default when allowed. A native top uses its
   inline completion unless inline is prevented or the open pin's current URL
   differs from its pinned URL.

### Stability

Chromium publishes several passes per keystroke. The composer adds no movement
of its own:

- the native candidate list is computed once per request;
- within one input text, a native top stays on top while it is a candidate,
  and an ordinary top cannot be taken later (late snapshot, refresh);
- the native block keeps its position within a request, and later ordinary
  rows go below it;
- commands shown earlier in a request keep their slot;
- a pass whose rows, default, inline text and display fields equal the last
  publish is not published.

## Learning

[OmniboxLearningStore](../Sources/LocalStorage/OmniboxLearningStore.swift) keeps
the last choice per normalized input (at most 256 bytes), in one JSON file per
account and profile. It is outside SwiftData and the FIFO, so a write never makes
results stale, and it is not synced.

- Phi records the chosen native entity, or an ordinary row chosen while native
  rows were shown.
- The snapshot carries the entries for the current candidates, within a
  256 KiB budget. If they do not fit, they are dropped; the snapshot is not.
- Chromium uses the most recent entry from the last 90 days whose text starts
  with the input.
- At most 2000 entries, 90-day expiry. Deleting browsing history removes entries
  in the same time range (`omniboxHistoryDeleted`).

## Commands

The Mac Omnibox offers Phi commands
([BrowserState+OmniboxCommand.swift](../Sources/States/BrowserState+OmniboxCommand.swift)):
Manage extensions, the split commands (add, vertical, left, top, remove) and the
appearance and layout switches. Each has a localized title and English keywords,
so it matches in any language. Only commands that can run in the current state
are sent.

A command is never the default and never inline. Selecting it closes the
Omnibox; Phi validates it again and runs it on a later main-actor turn. The NTP
offers the same commands; they act on the NTP tab.

## Selection and execution

| Row | Path |
| --- | --- |
| Ordinary | `FrozenNavigation` saved with the snapshot: URL, input, transition and dispositions. Selection never reads the live controller. |
| Pin or bookmark | Chromium calls `executeNativeOmniboxSession` with the frozen entity. Phi validates it in the FIFO, then `BrowserState.dispatchOmniboxEntity` revalidates the binding and scope and focuses the bound tab or creates a tab bound to the entity (`createOmniboxEntityTab` / `activateOmniboxEntityTab`). A split goes through `openPinnedSplit` or `openBookmark` instead. |
| Command | `executeNativeOmniboxCommand` → `BrowserState.scheduleOmniboxCommand`. |

`accepted` means the action was submitted once, not that it completed. A pin is
always open-or-focus: it is never navigated back to its pinned URL. Grouped
targets are rejected as unsupported.

**Switch or open.** A pin or bookmark switches like an open tab: ⌘-Enter or
⌘-click switches, the plain choice opens a new page. For a single-page pin or
bookmark, Chromium also offers the row's ordinary intents from a
`FrozenNavigation` of its URL; the client sends `openEntity` for ⌘ and the
ordinary intent otherwise, which opens an unbound page like any ordinary row. A
split offers only `openEntity`, and commands only `runCommand`; modifiers change
neither. The Mac Omnibox opens a split chosen without ⌘ as a new, unbound split
itself (`duplicateOmniboxSplit`, as Duplicate Split does) instead of selecting
the row.

## Mac Omnibox

The unified session is a data source and an execution route. Selection, inline
completion, temporary text, arrow keys and keyword search stay in the legacy
Omnibox code; unified rows go through the same `handleSearchResults` path as
legacy rows. A row that carries a unified token is selected through the
session instead of `selectSuggestion(atLine:)`.

**Routing.** `OmniBoxViewModel` uses the unified session only where a
submission opens a new tab or replaces a blank one: Cmd+T and other
non-address-bar opens, and Cmd+L on an NTP or `about:blank`. Cmd+L on a page,
a presented Peek, the split pane picker and group overview use legacy
suggestions. The route is re-evaluated when the Omnibox target changes.

**Split rows.** A row with `panes` shows the joined title without a URL, a
composed favicon (two panes side by side; three as panes 1 and 2 stacked beside
pane 3; four in a grid).

**Hints.** Open tabs show "Hold ⌘ to switch →", pins and bookmarks, single or
split, "Hold ⌘ to switch to Pin/Bookmark →".

**Enter before rows are selectable.** If the chosen row belongs to an older
request, or the current request has no settled default, Enter is held. When the
current rows arrive it runs once against the default, the row with the same
`rowKey`, or the typed text. Typing drops it.

**Recovery.** A session closed for `idle_expired`, `context_changed` or
`store_closed` is restarted, at most three times per presentation. Any other
close, `protocolVersion: 0` or a missing API falls back to legacy suggestions
for the presentation.

**Closing.** The Omnibox hides immediately after a selection. The session ends
only after the select reply, because ending earlier cancels Phi's dispatch.

## Sidecar NTP

The NTP is the Sidecar extension's `chrome://newtab` override. Chromium accepts
the API only from that extension's registered `index.html`, as the active
primary main frame of an activated tab in a normal, non-incognito window. The
session is bound to the document: navigation, deactivation, renderer loss or
destruction closes it, and a BFCache restore needs a new `begin`.

NTP sessions get pins, bookmarks and commands from Phi but offer no row
deletion. Like the legacy NTP, they get no site-search rows or Tab-to-search
hints; those stay in the Mac Omnibox. Pin and bookmark rows show the same hints as the Mac Omnibox; split
rows show the joined title and the pane favicons. The NTP keeps its own
selection state; see `docs/sidecar-omnibox-v2.md` in `phi-ai`.

After an accepted pin or bookmark selection that did not open a split, Chromium
closes the NTP tab when it has no back history and is not bound to a Phi entity,
like Chromium's own switch-to-tab closes an orphaned NTP.

## Lifecycle

`OmniboxNativeSearchAdapter.beginContextTransition(reason:)` revokes every
Chromium session of the window, cancels pending reads and posts
`omniboxNativeContextInvalidated` so the Mac Omnibox drops its session. It is
called when:

- the account, browser access or Guest promotion/recovery changes
  (`ApplicationState.performOmniboxAuthorityChange`);
- Guest transition blocks interaction, or a Space store is rebound;
- the window is concealed or leaves the shell (`surface_hidden`);
- the focused tab, its group, splits, split preview, group overview or Peeks
  change, or the window controller is replaced;
- a backup import replaces the data directory (`store_closed`).

`close(reason:)` is final and is used when the window closes, the controller is
rebound to another account or the LocalStore closes. A new session needs a new
`begin` after the new context is ready; nothing renews automatically.

## Debugging

- Logs: `[OmniboxV2]` (Mac session routing), `[OmniboxNative]` (Phi data and
  dispatch), `[PhiOmniboxRank]` (Chromium composer trace at `VLOG(1)`: gate,
  top decision code, shown natives with quality, block position).
- `--phi-omnibox-rank-params=key=value,...` overrides `ComposeParams`. Use
  `rank_mode=off` to get stock Chromium rows and `rank_mode=fill_only` to keep
  natives out of the top slot.

## Tests

- Phi standalone tests (`Tests/Omnibox*/main.swift`), run by
  `build-scripts/test-omnibox-*.sh`: access transition, entity dispatch,
  learning store, local store, native adapter, search authority. Also
  `Tests/OmniboxNativeUIClient`.
- Phi XCTest: `LocalStoreOmniboxTests`, `OmniBoxKeywordSearchTests`,
  `OmniBoxPeekTargetTests`.
- Chromium unit tests next to each `phinomenon/omnibox_*` file: composer,
  matcher, match quality, snapshot, session, frozen navigation, proxy.

## Known gaps

- An open pin is not matched on its current page's URL or title.
- `dispatchOmniboxEntity` does not reuse `openBookmark` or
  `openOrFocusPinnedTab` for a single page; grouped targets are rejected.
- The NTP list keys rows by `resultId`, so rows remount on every keystroke.
- `searchbox_stats` positions and controller metrics see only the ordinary
  result.
- Split rows never inline. Inlining one when the input's last choice is that
  split is a possible improvement; the inline text would still name only one
  pane while Enter focuses the first.
- No browser test covers the glue between the stock controller, the composer
  and publication. The Mac view model's unified paths (held Enter, restart)
  have no automated test.
