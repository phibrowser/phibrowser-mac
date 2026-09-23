# Sync settings and resumable setup

Last updated: 2026-09-23

Status: Design accepted on 2026-09-23; implementation present on `feat/sync-ux`.
Source baseline: refreshed `origin/dev` at `1b4e7305`. Automated build/regression
evidence and outstanding manual acceptance are recorded in `docs/sync-e2e-test-cases.md`.
Matched-framework runtime and two-Mac acceptance are not yet signed off.

## Intent and accepted direction

Users must be able to understand what sync covers, whether this Mac needs
attention, and how to join or recover without losing access to local browsing.

The owner accepted these product decisions:

- Name the settings pane **Sync**, replacing the visible Devices title.
- Organize it into status, devices, and recovery/removal. Omit the Sync contents
  card in every setup state, per the owner's follow-up UI review.
- Make device verification and Profile/Space pairing one continuous setup flow.
- Show the consequences of matching existing data before applying changes.
- Allow users to finish pairing later and continue using the browser.
- Treat unfinished pairing as **Not paired**: all data sync remains not started,
  including settings and Chromium Profile data, until pairing completes.
- Fetch current server data on every entry to pairing. Previously fetched
  account data must not supply the new pairing session.

The detailed lifecycle and acceptance requirements below describe the agreed
target, not claims about shipped behavior. English labels here are
source-copy proposals; translations must follow the localization guidelines.

## Scope

This design covers the Sync pane, initial setup, joining another device,
Profile/Space matching, recoverable errors, and deferred pairing. It preserves
existing encryption, authentication, identity, and merge boundaries.

No master on/off toggle, per-category toggles, recovery-code replacement,
remote-device removal, cloud-data deletion, or new conflict-resolution policy is
included. Removing this Mac remains distinct from postponing setup and from
deleting browsing data. Existing last-active-device removal restrictions remain.

## Sync pane

Keep the existing settings layout and visual components. The following regions
are ordered vertically, with secondary details expandable.

### Account and status

Show the current account so users can identify where their data belongs. Keep
the status region in a stable position; routine background rounds should not
make the entire pane flash between states.

| State | Information | Primary action |
| --- | --- | --- |
| Signed out | Sign in to sync across devices | Sign in |
| Not set up | This Mac has not joined sync | Set up sync |
| Waiting for approval | Verification is pending on an authorized device | View request |
| Not paired | Sync has not started; finish Profile/Space matching | Continue setup |
| Initial sync | This Mac is receiving account data | View details |
| Up to date | Last successful local sync time | No required action |
| Offline | Local changes remain available and will sync when connected, for eligible content | No required action |
| Needs attention | Explain the affected content and a specific failure | Sign in again, Retry, or View details |

Do not infer success from account sign-in, key unlock, an SSE connection, or
device registration. An unavailable status remains unknown/checking; it must
not appear as Up to date. The success timestamp refers to this Mac's work,
not proof that every other device received it.

Before pairing completes, the top status explicitly says sync has not started.
Authorization or partially applied mappings must not appear as partial sync.
The top status otherwise prioritizes required user action over ordinary background work.
Keep additional conditions visible in its details: for example, incomplete
pairing and offline connectivity can both be true. An isolated Profile/domain
failure must produce a partial-failure explanation rather than global success.

Clicking either the Details label or its disclosure arrow toggles the status
details. Both use the same expansion state and preserve the native disclosure
control's keyboard and accessibility behavior.

### Devices

The target design lists joined devices with name, type, and a This Mac marker.
Show recent activity only when the service supplies trustworthy evidence. It is
not a last-successful-sync timestamp or an inferred online indicator.

Show pending requests above the list only when they exist, with requesting
device, verification code, expiration, Approve, and Deny. During an approval
mutation, disable that request's conflicting actions and show progress.

The inspected client supports pending requests and self-removal, but has no
joined-device list call. Implementation planning verified the existing service
`GET /keys/v1/devices` at sync-service `d49cf41`: it returns device identity,
name, platform, status, creation time, and optional revocation time. Integrate
that contract in the existing client. It supplies no recent-activity timestamp;
omit that field rather than substitute creation time. Never populate the list
from pending requests or present an unavailable list as zero devices. Remote
revocation is outside scope.

### Recovery and removal

Explain the two joining methods: approval by an authorized device or the saved
recovery code. There is no View recovery code action: the current flow displays
the code at creation and cannot retrieve it later from the service.

Place Remove this device from sync at the bottom with a confirmation describing
three consequences: this Mac stops participating, local browsing data stays,
and rejoining requires approval or recovery. Keep key rotation and cursor
details out of the primary product copy. Surface the existing last-device
restriction without implying that postponing setup has the same restriction.

## Setup flows

### First device

1. Set up sync opens an explanation of scope, verification, and recovery.
   Merely opening this introduction does not initialize the account.
2. Continue starts initialization and displays the generated recovery code.
3. Offer Copy and I've saved it, continue. Explain that the code is needed when
   authorized devices are unavailable, and should be stored safely outside this
   Mac. Preserve the existing acknowledgment protection; Later is not a way to
   bypass saving a newly generated recovery code.
4. Skip empty decision pages where identity resolution is unambiguous and no
   overwrite requires review. Complete and persist the full pairing obligation
   before starting any data sync, even when no manual choices are necessary.
   If another device initialized the account during setup, enter the joining
   flow rather than create another account key.
5. Return to Sync with setup complete and initial sync in progress. Declare
   completion only from the actual data status.

### Joining another device

1. Prefer Request approval from another device, with Use a recovery code as the
   alternative. Keep the distinction between signed-in and authorized devices.
2. Waiting shows Settings > Sync instructions, a comparison code, time remaining,
   and options to cancel or use recovery. Network failure is different from
   waiting for human approval. Leaving a waiting screen must not allow a late
   completion to advance a different setup session or account.
3. Invalid recovery input stays editable on the input page. Network, service,
   and authentication failures are not all reported as an invalid code. Preserve
   input in the current flow, but do not persist recovery codes in setup storage.
4. Successful verification advances in the same visible setup flow to matching.
   It does not claim that all data has finished syncing.
5. Load the pairing candidates from the server for this entry; do not reuse a
   previous session's response or account preview. With no manual decisions,
   show an account-content summary. With existing
   local data, show matching choices. Classify by actual data and decisions,
   not merely by whether the app was freshly installed.
6. Finish applies the reviewed choices and returns to Sync. Initial catch-up
   proceeds while the user can browse.

### Matching and review

Keep the Profile then Space order. Present existing-account matching versus
keeping a separate item in outcome-oriented language. Name-based suggestions
remain suggestions, not identity proof or silent authorization.

Use the existing two-column local/account Space presentation and list account
Spaces that will be added automatically. Show meaningful result summaries such
as how many Spaces will be added and which existing local attributes will change.

Only show the extra overwrite review when supported fields actually differ.
Preserve its explicit account-versus-local values and conservative keyboard
default. Primary labels should explain the operation, such as Confirm and start
syncing. No unreviewed overwrite is authorized by Later, closing a window, or
restarting the application.

## Finish later

### User-visible behavior

- Offer Finish later on pairing loading, Profile, Space, overwrite-review, and
  recoverable-error pages. A slow preview must not trap the user in the browser.
- Closing the pairing window or pressing Escape has the same defer semantics
  on those pages. An explicit user dismissal does not require a second alert.
- Disable defer and closing while an already-confirmed apply operation is
  mutating mappings. Keep that operation bounded and recoverable; after failure,
  the user can retry or defer. Do not imply that closing rolls back applied work.
- Defer dismisses setup and restores normal browser interaction. It does not
  revoke this device, sign out, remove local data, or apply unconfirmed selections.
- Sync shows Not paired, Sync has not started, and Continue setup. This is an
  informational state, not a red generic error. All categories are not started.
- Persist the unfinished pairing state for this account on this device. That
  same state represents both a new unfinished enrollment and Finish later;
  there is no separate deferred-sync mode. Presentation is transient.
- App restart, foregrounding, mapping refreshes, and the existing stalled-pairing
  safety net must not force an unpaired device back into a modal. The user can
  enter pairing through the active setup flow or explicitly from Settings > Sync.
- Continue setup starts a fresh pairing session and fetches current server data.
  Completing the full pairing obligation starts sync. A later explicit new
  enrollment starts again as unpaired.

### Data boundary

Unpaired means data sync has not started. This is an account/device enrollment
prerequisite shared by every sync path, not a per-Space restriction or a UI-only
dismissal flag. Settings, Spaces, bookmarks, pinned tabs, URL rules, and all
Chromium Profile sync contexts must wait for successful pairing completion.
An unlocked account key, an approved device, or one resolved Profile is not
sufficient to start any of them.

While unpaired, permit local browsing and local changes, authentication, device
approval/recovery, and setup-specific requests needed to retrieve current pairing
metadata and prepare confirmed mappings. A read-only pairing preview may fetch
the account data needed for that review, but it must not land remote browsing
data, publish local browsing data, advance live sync cursors, or activate a
normal background sync schedule. This exception is for setup, not hidden sync.

The current implementation lets settings sync and already-ready Chromium
Profiles run independently of the Space gate. That behavior is explicitly
rejected for unfinished enrollment by the owner's latest decision. Extend the
existing enrollment gate to cover both native and Chromium sync start paths.
Do not simply hide the window or reuse only the current Space-section gate.

Establish the unpaired prerequisite before key unlock or mapping callbacks can
start an engine. After all Profile and Space decisions have been successfully
validated and durably applied, record pairing completion, then start eligible
sync contexts and request initial catch-up. Failed or partially persisted setup
must leave the entire sync lifecycle not started. Normal sign-in restoration
for an already-paired device may resume sync under its existing auth/key rules.

Unconfirmed matching choices must not become live mappings or unlock new contexts
before confirmation. Once a user has confirmed an apply, partial durable results
remain real; retries reuse them idempotently instead of minting duplicate
identities. Defer after a failed apply does not undo those confirmed results,
but no data sync starts until the complete pairing obligation succeeds.

Local browsing and edits continue while deferred. Resuming must account for
Profiles/Spaces created, deleted, renamed, or changed in either place during the
interval. Background identity resolution must not silently discharge unresolved
user choices simply because the window is hidden. In particular, no remaining
actionable Profile choices does not prove that pending Space decisions finished.
Conversely, an unreadable remote object alone must not create an impossible
mandatory decision; preserve the existing non-actionable classification.

### Fresh entry and resume

Persist the unfinished pairing lifecycle through the existing account-scoped
storage path. Do not persist an old preview, unsubmitted choice draft, or
overwrite approval for use on a later entry. Back/Continue within a live session
can retain that session's choices; leaving it discards unsubmitted selections.
Confirmed durable mapping results remain real and are read during reconciliation.

Every entry from Settings > Sync initiates new server requests for the current
Profile candidates and Space preview, and reads current local candidates. Do
not reuse a previous response, completed request, sync snapshot, or preview cache
as that session's account data. This also applies after relaunch, returning from
an error after leaving, or closing and reopening the wizard in the same process.

Display Loading while those requests complete. If offline or a fetch fails, show
Retry and Finish later; do not fall back to stale account data or enable
confirmation on it. Retry starts fresh requests. Build recommendations and
overwrite differences from the new responses and current local values, using
stable IDs rather than names for identity. A previous overwrite review grants no
approval in the new session. Revalidate the relevant snapshot before mutation;
changes during the live session require updated choices/review where appropriate.

Account switches must fence in-flight callbacks and never expose one account's
pairing data under another. Sign-out clears active presentation and in-memory
choices, while retaining the account-scoped pairing lifecycle needed for a later
return. Self-removal invalidates that enrollment. A late load after leaving the
wizard cannot reopen it, advance setup, or populate a newer pairing session.

Unpaired status must already be durable before entering the pairing UI; Finish
later does not need a new draft write to be safe. A completion persistence failure
must leave sync not started and display a recoverable error. Missing or uncertain
completion evidence must never default to paired. An upgrade must distinguish
verified existing enrollment from unfinished setup without discarding valid
identities, replay state, or forcing destructive re-pairing of established devices.

## Architectural impact and ownership

This intentionally replaces two product invariants: completing pairing or
self-revoking are no longer the only ways to regain browser access, and
settings/ready Profile sync may no longer start while enrollment pairing is
unfinished. Preserve identity and data integrity while strengthening the
enrollment prerequisite. Implementation must update the old modal-only and
partial-start documentation and tests together with the behavior.

Keep responsibility in the current modules:

| Owner | Responsibility |
| --- | --- |
| Existing Devices settings controllers/views | Present the Sync pane; preserve existing pane routing compatibility |
| KeyLayerViewModel | Initialization, approval/recovery routing, and recoverable input errors |
| PairingWizardViewModel | Fresh candidate loading, in-session choices, validation, review, and serialized submission |
| ProfilePairingGate and its host | Account-scoped pairing lifecycle and explicit window presentation |
| SyncKeyController | Profile/key eligibility and idempotent mapping operations |
| PhiChromiumCoordinator and existing engine adapters | Enforce eligibility and report actual domain/context progress |
| KeyEnvelopeAPIClient | Existing key-backend transport and verified device-list integration |

Separate pairing completion from transient window presentation within the existing ownership;
do not create another global state container or a parallel sync coordinator.
UI must not infer domain correctness from window visibility, write persistence
directly, inspect Chromium internals, or start a parallel polling engine.

Full status reporting requires observable, account-scoped facts from Phi and
Chromium integration. Expose them through the existing boundaries. Until facts
are available, present unknown/checking rather than fabricate success. A details
view may report domains separately, but the top card must account for partial
failures and unresolved setup. Neither existing key unlock nor a settings-only
successful round is sufficient for global success.

Keep the native run-loop safety rules while the current host still uses modal
sessions. Unified setup should have one active visible owner; adapting that
existing host is preferable to introducing a competing wizard/window manager.

## Acceptance requirements

1. First-device setup preserves recovery-code acknowledgment, skips only truly
   unnecessary choices, and ends with accurate initial-sync status.
2. Approval and recovery join converge on the same matching flow. Wrong input is
   editable; network failure is retryable and does not masquerade as wrong input.
3. Defer works from loading, either decision step, overwrite review, and errors.
   Each case restores browser use without applying unconfirmed selections.
4. Repeated mapping notifications, stalled-pairing safety-net callbacks, wake,
   and relaunch do not force unpaired setup open or start any data sync.
5. Every entry makes fresh server requests, including same-process reopen.
   Change server Profiles/Spaces between entries and verify that only the new
   response supplies the next page. Failed/offline fetches never use cached data
   or allow confirmation. IDs never fall back to an unrelated Profile or Space.
6. A delayed preview result after dismissal cannot reopen/advance setup. A stale
   apply/load response after account switching cannot mutate the new account.
7. Deferred local edits survive until successful pairing and subsequent merge.
   Neither Phi nor Chromium starts data sync while unpaired, including settings
   and Profiles with ready keys. Verify key-unlock, mapping-notification, app
   startup, and partial-apply paths, not only wizard dismissal. Setup previews
   remain read-only and do not start schedules or advance live cursors.
8. Partial confirmed apply, failure, defer, restart, and retry do not create
   duplicate identities or silently approve a new overwrite. Profile completion
   alone never releases pending Space choices.
9. Loading and completion persistence failures cannot trap the browser indefinitely
   or incorrectly report completion/start sync. Applying is serialized, bounded,
   and recoverable before defer is enabled again. Verified already-paired devices
   retain their enrollment on upgrade; unknown state never defaults to paired.
10. The last active device can defer despite being unable to self-remove. Actual
    removal still retains local data and invalidates the old enrollment.
11. Status covers offline, authentication failure, partial Profile/domain failure,
    checking, initial catch-up, and success without conflating authorization with
    completed synchronization. No unsupported device facts or sync categories
    are displayed as available.
12. Keyboard navigation, Escape/close semantics, focus on resume, VoiceOver state
    announcements, and narrow/long localized labels remain usable. Recovery-code
    acknowledgment and destructive-review keyboard defaults remain protected.

Use focused lifecycle/model tests for these state boundaries, existing sync
convergence tests for affected eligibility changes, and manual native UI/two-Mac
acceptance for real engine status and setup transitions. This document is not a
test execution report.

## Source references

- [Sync behavior](../../sync.md)
- [Sync acceptance scope and cases](../../sync-e2e-test-cases.md)
- [Localization guidelines](../../i18n/localization-guidelines.md)
- [Pairing gate and window host](../../../Sources/Sync/Keys/UI/ProfilePairingGate.swift)
- [Pairing wizard model](../../../Sources/Sync/Keys/UI/PairingWizardViewModel.swift)
- [Key setup model](../../../Sources/Sync/Keys/UI/KeyLayerViewModel.swift)
- [Devices pane](../../../Sources/UserInterface/Preferences/Devices/DevicesSettingView.swift)

## Implementation plans

1. [Pairing prerequisite and setup flow](../plans/2026-09-23-sync-pairing-implementation.md)
2. [Sync status and devices](../plans/2026-09-23-sync-status-devices-implementation.md)
