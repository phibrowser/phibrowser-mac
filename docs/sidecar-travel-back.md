# Sidecar browser-scene restoration

Date: 2026-09-09. Updated: 2026-09-14. Status: Profile-scoped chat and standalone
Phi Chat restoration implemented locally, pending paired-browser acceptance.
Earlier Hello/Default cross-Profile live/closed Tab acceptance passed; the
broader isolated-chat matrix remains pending.

## Profile-isolation integration (2026-09-14)

Ongoing work now lives in `phibrowser-mac-chat-profile-isolation` on
`feature/chat-profile-isolation`, based on current dev `ab39c60b`. Only the
Profile feature delta was ported from the old `sidecar-travel-back` worktree;
that worktree remains unchanged. Current dev's Folio translations, message
reassembly, addressed Phi Chat source collapse and SiteMemory cleanup remain
intact. Profile deletion keeps both memory cleanup and conversation archival;
import rollback opts out of both. This is not an installed browser update.

Installed Canary 827 (`2026.9.14.1540`) contains the basic restoration message
names but not `sidecar.chat.profiles`. Loading a newer Sidecar alone cannot
provide that native handler. Testing the global Profile chooser requires this
native feature build and the matching Sidecar/backend, not merely a larger
Canary build number.

## Earlier same-Profile integration (2026-09-14)

The owner approved publishing the committed same-Profile stage without taking
ongoing cross-Profile/isolation changes from either source worktree. This replays
`b04a028a` onto dev `2621fb7a`, paired with phi-ai `f7a19df42` integrated onto
staging `b0dd0f8b7`. The Xcode project retains dev's SiteMemory router registration
alongside the new Travel Back files. Cross-Profile handoff, Space-identity
reopening, runtime-identity hints and standalone Phi Chat restoration were not
part of that earlier stage; the Profile-isolation integration above adds them.

The integrated Canary `build-for-testing` passed with signing disabled and a
command-local Xcode developer directory. All eight pure policy tests passed in
an isolated SwiftPM fixture linked to the actual policy/test files. The paired
Sidecar passed 962 tests, 10 metadata tests, 37 root type-check tasks, changed-file
lint/format and its build. No browser was launched or installed. Coordinate
native, Sidecar and phi-agent registry-v2 delivery; do not replace a local
Profile-isolation/registry-v3 setup with this earlier stage. Full lifecycle and
first-paint acceptance remain outstanding.

## Decision and ownership

Travel Back continues a conversation at its last recorded reopenable browser scene:
Profile, Space, page and two-pane split (order, divider, ratio and active pane).
On the owner's 2026-09-10 follow-up, Sidecar skips new-tab/internal-page captures
rather than clearing that snapshot, and resumes recording on the next HTTP(S)
page. This includes a split dissolving onto an NTP survivor. Native capture still
reports the actual current scene without inventing a page; persistence policy
belongs to Sidecar. Strict arrival cannot acknowledge a non-reopenable capture.
The owner chose preserving conflicting work rather than dismantling another
split. Equal URLs count as already there only in the same Profile AND Space.
Tab groups, scroll/form state, pins and bookmarks are not restored.

`ExtensionMessageRouter` authenticates and translates trusted UI requests;
`TravelBackMessageHandler` resolves the addressed destination and delegates
activation to existing `SpaceWindowSlot.activate`. That owner handles Profile
loading, parked-window materialization, fullscreen grouping and source-window
hiding. `BrowserState+TravelBack` owns tab/split/sidebar lifecycle; the pure
`TravelBackScene` policy validates scene data and chooses anchors/windows.
Existing `aiChatTabs` and `chatIdentifier(for:)` remain the only sidebar ownership
model. In-flight creation keys participate in shared split binding resolution.

The 2026-09-10 cross-Profile change deliberately replaces profile-local extension
session notes with transient native handoffs. Destination `BrowserState` owns
one bounded envelope per receiving Sidecar; it holds a conversation ID and
source/recipient/operation/expiry metadata, never messages or credentials.
Sidecar owns conversation access, selection and metadata writes; phi-agent owns
durable chat data. There is no new backend handoff service or global window-state
registry. Native and Sidecar ship together, without an old-browser mutation
fallback. The bundled phi-agent must carry phi-ai's shared metadata registry v3.
General metadata read compatibility is retained, but no historical-location
migration is designed for this unreleased feature.

## Target policy

1. Require recorded Profile and Space identity. Both must still exist and the
   Space must still belong to that Profile. Deletion or rebinding stops with
   `target_unavailable`; do not recreate identities or fall back to another one.
2. Prefer the current sidebar page's exact URL only in that same Profile/Space.
   Otherwise reuse the recorded live Tab within that scope. Never search
   unrelated tabs by URL; full-page Sidecar does not borrow a current web Tab.
   Native snapshots carry `runtimeId`, an immutable process incarnation: stored
   numeric Tab/window IDs are hints only when that value matches this process.
3. A live anchor determines its window. With no anchor, prefer the still-valid
   recorded window, then an already-open window of the Space (source if eligible,
   otherwise lowest window ID for deterministic selection). Only when none exists
   activate the Space in the source window group's slot. Ordinary Spaces can
   have windows in multiple slots; Space ID is not a unique window address.
4. Activate that explicit slot, await completion, and recheck Profile/Space/window
   identity. Reuse the existing switch guard during animations rather than
   overriding another user switch. Target changes during later waits stop the
   continuation instead of selecting whatever window is now focused.
5. Reuse a matching ordered split; complete a safe standalone anchor with a new
   partner. Conflicting split/pinned/bookmark bindings get a fresh pair without
   detaching existing work. A single-page record does not dismantle a live split.

## Wire and trust boundary

Messages use existing `sendMessageToApp(type, payload, {timeout})` with one
request-scoped reply through `ExtensionMessaging`. Common caller fields are
`profileId`, `windowId`, optional fixed `boundTabId`. Standalone Phi Chat instead
sends `sourceKind: "phi-chat"` and a page-lifetime UUID `sourceId`, with no source
window or binding. Its restore lands while the shim owns the foreground, so the
destination window is fronted with `NSApp.activate(ignoringOtherApps:)`: cooperative
activation is declined on macOS 26 and `makeKeyAndOrderFront` alone leaves Phi behind
the shim (2026-09-21). Replies are
`{ok:true,result:...}` or `{ok:false,error:<known code>}`; errors never echo URLs.

A sidebar reference is `{profileId, windowId, chatTabId, boundTabId}`. `chatTabId`
is the actual sidebar WebContents ID; the fixed URL binding can still name a
closed pane after migration to the survivor. Capture resolves through existing
`aiChatTabs` ownership and records the focused split member, not blindly that
old URL-bound pane. Identical source/destination references never close or
release themselves.

| Type suffix (`sidecar.travelBack.`) | Additional input | Success result |
| --- | --- | --- |
| `snapshot` | none | page, Tab, window/Space/Profile/runtime, optional split, transient `relatedTabIds` |
| `restore` | `snapshot` | destination Tab/window, actual `sidebar`, optional `sourceSidebar`, `sameSidecar` |
| `offer` | `destinationSidebar`, UUID `operationId`, `conversationId` | `{}`; store one envelope, refuse overlap |
| `claim` | caller has `boundTabId` | `{handoff:null}` or `{handoff:{operationId,conversationId,acceptBefore}}`; offered becomes claimed |
| `ack` | `operationId`, `success` | `{}`; exact claimed recipient becomes accepted/rejected |
| `wait` | `destinationSidebar`, `operationId` | `{accepted:boolean}`; claim or missing record is never acceptance |
| `closeSource` | `sourceSidebar`, `destinationSidebar`, `operationId` | `{}` after exact source collapse; requires matching accepted receipt |
| `cancel` | `destinationSidebar`, `operationId` | `{}`; remove only that source's matching operation |

Only the exact built-in Sidecar extension ID is accepted. The caller must name
an existing, authenticated, AI-enabled ordinary window of its declared Profile;
incognito, kiosk, agent and source placeholder windows are excluded. An empty
target Space may be activated through its normal native lifecycle before restore.
Payloads are capped at 64 KiB, conversation IDs at 512 UTF-8 bytes, URLs at
16 KiB with valid HTTP(S) hosts. Split geometry uses divider orientation
`vertical` (left/right) or `horizontal` (top/bottom), primary ratio strictly
between zero and one, and active index 0/1. Legacy missing geometry defaults to
vertical/0.5 and the matching page or first pane; capture never persists a
filtered partial split.

**The bridge authenticates extension identity, not the source Profile/frame.**
Declared context and exact recipient consistency remain the owner-approved
trusted-Sidecar model, not protection against a compromised built-in extension.
An operation UUID is correlation, not proof of authenticated Chromium sender
context. This does not grant external CDP agents a UI-command authorization bypass.
The owner explicitly chose this product-level logical isolation on 2026-09-11;
no Chromium caller-attribution change is required. Standalone Phi Chat now uses
its source ID for receipt correlation, never window enumeration. Native reuses
the destination's slot or an eligible ordinary window group, creating one when
none exists. Sidecar keeps the global viewer open and does not record another
window's scene. `view=chat` in an ordinary Profile grants no global chat access.

## Explicit Tab moves (2026-09-11)

Cross-Profile menu moves with an existing Sidecar use `moveCarriedConversation`;
page-only moves retain the existing path. Native prepares the target page or
whole split and its Sidecar, reserves one operation per source sidebar, then
broadcasts only its fixed binding in `profileMoveAvailable`. The source claims
`claimProfileMove` and identifies its current saved conversation; native never
reads chat storage or chooses historical chats referencing that Tab.

The source commits ownership/scene through phi-agent's explicit migration API,
then offers an addressed handoff with `profileMove: true`. The receiver verifies
access and selects the chat. Its capture is best-effort because the server has
already committed the relocated scene and an internal-page destination is valid.
Normal Travel Back still requires strict HTTP(S) arrival capture. Source
`finishProfileMove` reports acceptance; only success with both native sidebar
bindings still valid closes the source Tabs. An unsaved/new Sidecar reports a
page-only success. The native finish budget is 20 seconds after preparation.

Failure before commit keeps ownership and source Tabs. After commit, ownership
stays at the target even if arrival fails; Sidecar releases the source chat but
native retains its page. Already-created target Tabs are not rolled back. No
other historical chats migrate. Since the 2026-09-14 category revision, account-wide
categories remain assigned when chat ownership moves. Shared split order, divider,
ratio and focused member are preserved. The backend remains responsible for
chat isolation, in-flight access revocation and move idempotency; see phi-ai
`docs/chat-profile-isolation.md`. The 2026-09-11 native build-for-testing passed;
this is not live acceptance of new isolated-chat or Phi Chat flows.

## Profile deletion and chat organization (2026-09-14)

Deleting a user Profile retains its conversations in Phi Chat's protected,
localized Uncategorized category. The same-day owner follow-up merged With Phi
into this view, so it also contains ordinary unfiled chats within their existing
access scope. Deleted-Profile chats' backend owner becomes global; messages and
last-scene evidence remain intact. The merge does not change native delivery. Deleted browser
identities are not silently recreated by Travel Back. User categories now belong
to the account and category movement never changes conversation ownership.

`ProfileManager` persists `ProfileChatArchiveJournal` under the current account's
`userDataStorage/chat-profile-archive/pending.json` before native deletion. A local
write failure blocks deletion; backend failure does not. Successful deletion
confirms the UUID operation; failed deletion removes the intent. After a crash,
an unconfirmed operation is eligible only when a complete native Profile list
shows the Profile absent. Backup/restore's temporary deletion explicitly opts out.

AI-off leaves delivery on disk without requests, service launch or implicit AI
enabling. Account/settings changes, Profile refresh and app activation wake the
queue. Delivery is current-account-only, single-flight, with a five-second request
and 30-second retry. `APIClient.archiveProfileConversations` rechecks the expected
account and AI state, then uses the existing authenticated local transport and
global scope. Only success removes the entry. A request already dispatched cannot
be undone by disabling AI. The backend's transactional operation receipt prevents
retry from overwriting a user's subsequent category choice. Journals contain no
messages or credentials and use private directory/file permissions.

`sidecar.chat.profiles` returns `{profiles: [{profileId, displayName}]}` to the
built-in Sidecar only when authenticated, AI-enabled and a complete Profile list
is available; otherwise it returns an unavailable error. Phi Chat uses it for
peer Profile/category filters, never to infer deletion from network failure.
Native deletion confirmations distinguish removed browser data from retained
chats and deferred delivery; new catalog entries are English-only pending the
normal localization pipeline. Backend and UI details belong to companion phi-ai
`docs/chat-profile-isolation.md`.

Pure journal tests cover crash/reload, account separation, failed intent cleanup
and AI/account eligibility (5/5). Native build-for-testing is the compile gate;
never launch app-hosted XCTest beside a live browser. This revision has not
replaced the running Canary automatically. Paired acceptance must exercise AI-off,
backend failure/restart, account switches, retry after recategorization and both
live/closed-Tab restoration.

## Handoff, latency and recovery

The content-free events `sceneChanged` and `handoffAvailable` contain only
`{boundTabIds}`. Sidecar filters by its fixed binding and pulls through an
addressed request; conversation IDs and operation tokens are not broadcast.
Cold receivers claim on mount, so an event sent before JavaScript startup is
not the delivery mechanism. Warm receivers claim on invalidation. There is no
continuous per-sidebar polling.

Claiming is not success. The receiving Sidecar verifies conversation access
using its own authenticated backend API, checks its selection has not changed
during that read, selects idempotently, suppresses the arrival reminder, and
strictly persists its actual new scene before acknowledging. Arrival bypasses
local successful-key deduplication because another Sidecar may have changed the
server anchor. Ordinary navigation/send capture remains best-effort and per-chat
serialized. This is not a cross-instance ownership lease or a multi-client
transaction; unrelated concurrent writers remain last-writer-wins.

Only explicit acceptance permits addressed source collapse and guarded source
chat release. Departure drafts do not auto-attach the now-focused destination.
Access/save failure, unmount or unconfirmed handoff leaves the source available.
A failed source close also retains it. Native state readiness is not React paint
or message-stream hydration; acknowledgement confirms the agreed application
steps, not a first-paint measurement.

One monotonic 8 s budget covers activation and native restoration, with source/
target window overlap guards. Native `wait` has a 7.5 s acceptance budget;
Offers allow claim/ack for 7.5 s, separate from cleanup TTL. Claim replies include
an absolute wall-clock `acceptBefore` in milliseconds; Sidecar caps access/save
at the smaller of its 6.5 s budget and that remaining time, rejecting delayed
claim replies. An independent abort race settles non-cooperative callbacks;
the application checks the signal before selection/writes. Native monotonic
checks remain authoritative if the wall clock changes. Bridge requests
have a 10 s deadline and ordinary Sidecar steps 11 s. The sender cancels its
handoff on completion/failure; 60 s native expiry is orphan cleanup, not a promise
that manually opening a sidebar after failure will replay the chat.

Timeout does not cancel dispatched Chromium operations. A late activation or
page creation can still finish, but expired restore continuations cannot create
splits/sidebars afterwards. No automatic page deletion or focus rollback is
attempted. JS retains its instance lock until raw calls settle. New pages use
transient custom GUID correlation, stripped from Swift and Chromium before
normal binding; late pages remain ordinary tabs rather than rollback targets.

`createAIChatTab` is requested directly using existing deduplication, bypassing
the view's historical 300 ms timer. Expand must still wait for `aiChatEnabled`:
a new content Tab can initially report NTP, and the view ignores an expand while
disabled without replaying it on enable. This is capability readiness, not full
page load. Split creation/focus uses existing ordered helpers and lifecycle
completion on the next main turn, not inside Chromium's mutation stack.

## Verification and acceptance

Final cross-Profile implementation checks (2026-09-10): Xcode 26.6
`build-for-testing` passed; 11 pure native policy tests passed in an isolated
SwiftPM fixture using the actual scene policy and test files. The companion
passed 918 Sidecar tests, 11 metadata tests, root type check (36 tasks), changed-file
lint/format and Sidecar build. Validation includes the final independent acceptance
deadline and delayed/non-cooperative receiver regressions. No installed app was
replaced or launched. Prior same-Profile owner acceptance does not validate this
new cross-Profile path. Companion evidence and coordinated registry-v3 requirement:
phi-ai `docs/chat-metadata-store.md`.

Owner follow-up (2026-09-10): after matching-backend preparation, restoring from
Default to Hello reused the still-open Tab without duplication. Closing the Tab
then restoring correctly switched Space and created a replacement. No native Tab
lookup change was needed for this follow-up. These two owner-reported scenarios
support the mixed-version diagnosis. The owner clarified that Hello and Default
belong to different Profiles, so both cross-Space and cross-Profile live-Tab reuse
and closed-Tab recreation are accepted. The remaining split/window and failure
matrix below is not thereby accepted.

Use existing project checks plus paired-browser acceptance for:

- Live/closed Tab across Spaces of one Profile and across two Profiles; identical
  URLs in different identities must not prevent switching.
- Existing target windows in this and other window groups, no target window,
  cold/unloaded Profile, parked session window, empty target, fullscreen/minimized.
- Cold/warm Sidecars, both split orientations/ratios and active panes, migrated
  binding after pane close, same shared instance and conflicting split preservation.
- Deleted/rebound target, switch/close/move mid-restore, duplicate actions, stale
  acknowledgement/cancellation, access/save failure, timeout and late arrival.
- Messages and streaming state preserved; no arrival reminder; departure creates
  no automatic destination attachment; subsequent restoration reuses the saved Tab.

`build-for-testing` must not launch the app-hosted XCTest runner beside live user
browsers. The fixture is policy execution, not independent lifecycle review.
The original intermittent white-sidebar rendering incident remains unproven;
no first-paint speedup or complete browser acceptance is claimed by compilation.
