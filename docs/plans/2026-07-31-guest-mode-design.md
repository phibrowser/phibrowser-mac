# Guest Mode Design

Date: 2026-07-31
Status: approved
Branch: `feat/guest-mode`

## Problem

Phi currently treats a completed Phi account session as a prerequisite for
showing and using the browser. Users who do not want to sign in cannot reach
the Chromium window, local Spaces, bookmarks, pinned tabs, or browser
settings.

Guest Mode allows a user to use Phi without a Phi account while preserving the
existing Chromium profile. It is a persistent local access mode, not
Chromium's isolated and ephemeral Guest Profile.

## Product Decisions

- The sign-in screen offers an unobtrusive **Explore Phi without signing in**
  action below the login button.
- Guest Mode persists across quit and relaunch after the user explicitly
  selects it.
- Guest Mode reuses the same Chromium profiles, cookies, site sessions,
  history, extensions, and password data before and after Phi account login.
- A sign-out, expired session, or account deletion returns to the sign-in screen.
  It does not silently enter Guest Mode.
- Guest-owned Phi data is stored under `AccountController.defaultAccount`.
- A successful Phi account login merges Guest-owned local data into the target
  account and then removes the migrated Guest data.
- A failure before any planned data reaches the target returns to a fresh,
  writable Guest session and presents a clear retryable error.
- A failure after the target may have been changed keeps the terminal Guest
  snapshot sealed and permits only identity-bound recovery for the same target
  account. It must never reopen Guest data for editing or offer a different
  account as an escape.
- Guest Mode forces the Phi AI master preference off before browser access is
  granted. AI remains unavailable throughout the Guest session. A login
  explicitly started from the AI settings prompt enables it only after the
  account transition completes successfully.
- Existing users return to the browser after login. New users complete any
  remaining account onboarding before the final account transition.

## State and Ownership

`ApplicationState` owns one application-scoped browser access state:

```swift
enum BrowserAccessState {
    case loginRequired
    case guest
    case signedIn
}
```

The state exposes two deliberately separate capabilities:

- `canUseBrowser`: `guest` or `signedIn`
- `isAuthenticated`: `signedIn` only

Only the user's explicit Guest choice is persisted. Signed-in state continues
to be derived from the authenticated account and completed onboarding. Auth0
credentials remain owned by `AuthManager`; Guest Mode must not be represented
as fake credentials or as a completed `LoginController` phase.

`AccountController.shared.account` continues to mean a real Phi account.
Stable Guest Mode leaves it `nil`. Local browser-data callers use a narrowly
scoped `localDataAccount`:

- signed in: the real account
- guest: the stable `AccountController.defaultAccount`
- Guest promotion: the target account, while authenticated capabilities remain
  fenced
- login required: no local-data account

This avoids the network, telemetry, shortcut, and profile-fetch side effects
of publishing the default account as a real account. During the short
promotion seam, publishing the target account establishes only Native
local-data ownership. `isAuthenticated` remains false until window rebinding
and source cleanup have reached a durable outcome.

State transitions send a dedicated
`Notification.Name.browserAccessStateDidChange`. Guest entry must not emit a
fake `loginCompleted` notification.

## Startup, Reopen, and External URLs

Startup resolves access in this order:

1. Active account-deletion or other destructive-auth fences.
2. A published authenticated account with completed onboarding.
3. The pending Guest-migration journal and its filesystem boundary.
4. A persisted explicit Guest choice.
5. Another recoverable authenticated session and its onboarding phase.
6. The sign-in screen.

The persisted Guest choice is loaded synchronously before Chromium first asks
whether browser UI is available.

Dock reopen, menu validation, Space reconciliation, and external URL routing
use `canUseBrowser`. Token renewal remains signed-in only. External URLs
received while browser access is unavailable stay queued and are forwarded
after either Guest entry or successful login.

A pending migration journal is classified synchronously before Chromium
creates its first window and before the Guest store is opened. A prepared or
unstaged imported source installs a recovery gate: the durable state remains
Guest, but browser access and local-store binding are temporarily unavailable.
Chromium windows remain hidden and dangling, and Dock reopen or cold-open URLs
do not proactively show the ordinary login UI.

Once the verified old source has crossed the atomic tombstone boundary,
cleanup may be deferred while a fresh Guest directory remains usable.
Matching staged credentials upgrade that launch to automatic account
recovery. Otherwise the next login remains bound to the original target
identity: Phi retires only the old tombstone before separately migrating the
new Guest data. An unreadable or inconsistent journal fails closed.

## Chromium Integration

Chromium continues to own profiles, cookies, site sessions, history,
extensions, and password data. Guest Mode does not create, delete, or switch a
Chromium profile.

The Chromium `canShowChromiumWindow` callback decides whether Phi browser
windows and the Tab, History, Window, and Dock menu items are available. Its
native implementation returns `canUseBrowser` and does not represent account
authentication. Chromium can independently query `isPhiGuestMode` when it
needs to distinguish Phi Guest Mode from signed-in browser access.

Real identity APIs remain strict:

- Auth0 access token is empty in Guest Mode.
- Phi account information is absent in Guest Mode.
- Account profile, connector, channel, deletion, and other server operations
  require `isAuthenticated`.
- Auth0 credentials obtained during Guest login remain local staging state.
  Shared-process token publication, renewal timers, and the Sentinel heartbeat
  begin only after the signed-in commit.
- The only pre-commit token exception is an identity-, phase-, and
  expiry-bound onboarding channel for reading the target account profile and
  submitting **Set Name**. It is unavailable to Chromium, Phi AI, connectors,
  channels, and other account APIs.
- Sentinel registration, launch, watchdog, backup export, and delayed version
  actions remain stopped until the signed-in commit. Entering Guest Mode uses
  the existing AI-disable lifecycle to unregister and terminate Sentinel after
  the shared authentication boundary is cleared. Login-required access without
  a Guest choice leaves an already running helper idle. If shared credential
  cleanup fails, Phi still requests termination as an exceptional fail-closed
  measure because Sentinel may retain the old token.

The Native coordinator remains responsible for hiding pre-access Chromium
windows and replaying buffered window/tab state. Entering Guest Mode grants
those dangling windows access through the dedicated browser-access
notification and rebuilds Chromium menus.

No Chromium source or bridge ABI change is required for the initial
implementation.

## User Interface

### Login

`LoginViewController` adds a secondary text-style button:

- Title: **Explore Phi without signing in**
- Placement: below the primary login button
- Visual priority: tertiary, but keyboard accessible

Selecting it persists Guest Mode, dismisses the login window, and grants
browser access.

### Account Settings

The Account pane must render an explicit Guest state instead of a loading or
empty account card:

- Title: **You’re using Phi without signing in**
- Primary action: **Sign in**

Authenticated-only profile editing and logout controls are hidden. Local
browser settings remain available.

### New Tab Behavior

The Native New Tab Page depends on Phi AI. Entering or restoring Guest Mode
therefore sets `GeneralSettings.openNewTabPageOnCmdT` to Omnibox before a
browser window is released. The New Tab Page option remains disabled while the
AI master preference is off.

### Account-Required Surfaces

A shared Native login-required presentation remains as a fail-closed boundary
for account-backed surfaces reached through a stale tab or direct internal URL:

- New Tab Page if a stale enabled state reaches it
- AI Chat
- Browser Memory (`phi://memory/`)
- AI Connectors
- IM Channels

The presentation contains:

- Title: **Sign in to use Phi AI**
- Detail: **This feature requires a Phi account.**
- Action: **Sign in**

The Phi AI master toggle and all subordinate AI controls are disabled in Guest
Mode. The AI settings pane shows a login prompt immediately above the master
toggle. Login started from this prompt records an in-memory, one-shot intent to
enable the AI master preference only after account onboarding and Guest data
migration complete successfully. Closing login, continuing as Guest, or
abandoning the account transition cancels the intent and leaves AI off.
Ordinary AI entry points are hidden by the off preference, and account-backed
content must not issue authenticated requests behind the fallback
presentation.

## Guest Data Merge

### Included

- Chromium profile references used by Phi local models
- Spaces
- Bookmark and bookmark-folder trees
- The logically active pinned-tab collections, including split pairs
- Space URL rules
- Space theme values needed by imported Spaces

Chromium-owned cookies, sessions, history, extensions, and password data are
already shared through the unchanged Chromium profile and are not copied.

### Excluded

- Credentials, cached account profile, login phase, and reauthentication state
- AI sidebar cache and server connector cache
- Feedback outbox and diagnostic attachments
- Stale normal-tab database rows
- Window-slot restore snapshots
- Account-specific custom shortcuts
- Whole-file or whole-directory copies of account defaults

Excluded asynchronous cache writers are quiesced during the ownership
transition. When no local-data account exists they must not fall back to
`defaultAccount`, because doing so could recreate the removed Guest directory.

### Conflict Rules

- Target-account content is ordered first and wins conflicting settings.
- A matching Chromium profile identifier reuses the target profile model.
- The Guest default Space maps to the target default Space.
- Guest custom Spaces append after target Spaces. Identifier collisions receive
  deterministic remapped identifiers.
- Guest default-Space bookmark content is added under one
  **Imported from Guest** folder. Custom-Space bookmark trees remain in their
  imported Spaces. Bookmarks are not deduplicated by URL or title.
- Existing target pinned scope configuration wins. Guest active pinned
  collections append using the existing lineage, content, and split-signature
  semantics rather than URL-only deduplication.
- Target URL rules win identical `(host, pathPrefix)` conflicts; other Guest
  rules append.
- Colliding model GUIDs receive persistent old-to-new mappings.

### Transaction and Recovery

The two account stores cannot participate in one database transaction. The
merge therefore uses a journaled, identity-bound operation:

1. Freeze Guest-facing interaction.
2. Submit one terminal FIFO operation that drains every previously queued
   Guest write, captures a pure-value snapshot, and closes the source store.
3. Persist a prepared journal bound to `operationID`, source ID, target user
   ID, the snapshot, and deterministic identifier mappings.
4. Import the snapshot in one throwing target-store transaction.
5. Persist and verify a target receipt and the mapped Space themes.
6. Publish the target only as the Native local-data owner behind the promotion
   fence.
7. Rebuild live and dangling Native browser controllers against the target,
   applying the receipt mappings before their first target-bound write.
8. Re-verify the target, atomically rename the complete Guest account directory
   to an operation-specific tombstone, delete the tombstone, and remove the
   journal.
9. Commit signed-in capabilities and shared authentication state.

If a failure occurs while the prepared journal can prove every planned target
identifier is absent, Phi removes that journal, installs a fresh default
account over the intact Guest directory, rebinds the existing windows, and
offers:

- Title: **Couldn’t finish setting up your account**
- Detail: **Phi couldn’t move your Guest data. Your data is safe, and you can
  try again.**
- Actions: **Try Again** and **Not Now**

If target content is complete, partial, or cannot be inspected, the coordinator
returns a recovery-required error instead. The source remains terminal and the
same target identity must resume the journal; **Not Now** is unavailable.

After target receipt verification and controller rebinding, a directory
cleanup failure no longer rolls back to Guest. Phi commits the account,
explains that old Guest cleanup is incomplete, and retries the identity-bound
cleanup on a later launch. A staged tombstone is deleted without instantiating
or recreating the absent Guest store. If a new Guest directory appears beside a
staged tombstone, only the old verified tombstone is retired and the new data
is handled by a same-target follow-up migration.

## Account Transition and Windows

`SpaceSessionController.account` and `BrowserState.localStore` are fixed
for the controller lifetime. A Guest-to-account transition therefore uses the
existing dangling-window lifecycle instead of adding a second live-store
binding architecture:

1. Freeze Native interaction and capture window/tab/selection/split state.
2. Seal and migrate the Guest snapshot.
3. Begin the promotion fence and publish the target as local-data owner only.
4. Rebuild Native browser controllers against the target account while
   retaining the existing Chromium browsers, tabs, profiles, cookies, and site
   sessions. Recovery-created dangling windows consume identifier mappings
   before their first controller construction.
5. Replay buffered Native state and restore window visibility/focus.
6. Stage and remove the complete Guest directory.
7. Clear the persisted Guest choice, expose authenticated capabilities, and
   publish shared authentication state.

The transition may cause a short Native UI refresh but must not intentionally
close Chromium tabs or lose split and selected-tab state.

Login cancellation, Auth0 failure, and onboarding cancellation leave the
current Guest windows unchanged. A target-untouched migration failure rebuilds
those windows against a fresh default-account store before restoring
interaction. A target-touched failure keeps the windows sealed until
identity-bound recovery completes.

## Security Boundaries

- Missing Auth0 subject identifiers fail closed. They must never fall back to
  the Guest account identifier.
- Guest Mode never returns a real token or Phi account payload.
- Authentication failure never silently changes the destination data store.
- Guest cleanup cannot begin until the target receipt is verified.
- A migration journal is identity-bound so Guest data cannot resume into a
  different later login.

## Testing

Focused automated tests cover the pure access policies, forced Guest AI and
New Tab preference behavior, shared login-required presentation policy,
Sentinel termination policy, local-store merge and
conflict rules, identifier mappings, terminal source handling, target-touched
recovery classification, startup journal/filesystem classification, staged
credential matching, receipt verification, directory staging, cache
no-recreation behavior, and idempotent retry.

The integration validation matrix additionally covers cold launch, Dock
reopen, external URL queueing, logout and expired-auth behavior,
recovery-specific login, strict Native/Chromium identity APIs, shared-token
publication timing, dangling-window receipt mapping, merge alerts, and
window/tab/split/selection/focus continuity. Chromium profile reuse is
validated by confirming that the transition never changes the Chromium
user-data directory or recreates Chromium browsers or WebContents.

Final verification follows the project-required external Xcode
`build-for-testing` and focused `test-without-building` workflow.

## Out of Scope

- Chromium's isolated or ephemeral Guest Profile.
- Clearing Chromium profile data when leaving Guest Mode.
- Live rebinding an existing `BrowserState` to another `LocalStore`.
- Migrating feedback, AI cache, window restore snapshots, or custom shortcuts.
