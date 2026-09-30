# Guest mode and account migration

Guest mode is persistent local browser access without a Phi account. It is not
Chromium's temporary Guest Profile and should not be described as a fresh,
isolated browsing identity. Existing local browser Profiles, cookies and site
sessions remain relevant to the entry decision.

## Ownership and credential boundary

`LoginController` coordinates entry, sign-in and migration recovery.
`ApplicationState` exposes the application access mode; browser/tab state remains
window/session-scoped. Account-dependent capabilities must use the existing
capability and authentication gates rather than manufacture a guest bearer token.

Guest entry crosses the existing credential-cleanup and user-confirmation
boundary. Authentication failures do not silently switch to Guest storage.
Open-source builds use the explicit build capability policy to remain in Guest
mode; see [open-source build](../open-source-build.md).

Local data ownership and authenticated identity are separate contracts:

| State | `localDataAccount` | Authenticated capabilities |
| --- | --- | --- |
| Login required | None | Unavailable |
| Stable Guest | Stable `defaultAccount`; the real `account` remains nil | Unavailable |
| Guest promotion after local access resumes | Target account behind the promotion fence | Unavailable until commit |
| Signed in | Real account | Available, subject to recovery gates |

`canUseBrowser` allows Guest or signed-in browsing, except while migration
recovery blocks access. `isAuthenticated` additionally excludes promotion and
recovery. Never publish `defaultAccount` as a real identity just to enable local
browsing: doing so would mix local storage with account API, telemetry and other
identity-bound side effects. Local-data callers use `localDataAccount`; remote
identity callers require authenticated capabilities.

During promotion, target ownership and receipt-aware window rebinding precede
authenticated activation. Shared token publication, renewal and Sentinel startup
wait for the signed-in commit. The only staged-token exception is the onboarding
account-profile/Set Name channel, bounded by expected identity, onboarding phase
and credential expiry. It does not grant Chromium, AI or ordinary account APIs
access to an uncommitted session.

## Guest AI and Sentinel lifecycle

Guest entry disables the AI preference before Guest browsing begins. Startup
does the same when the resolved access mode is Guest or the build does not
support AI. Credential cleanup is a boundary before service launch and before
ordinary Guest entry. An explicit Guest-entry attempt fails if credential
cleanup fails; at startup, cleanup failure suppresses Sentinel launch.
Migration recovery retains only the credentials needed for its fenced
target-recovery path.

Sentinel is an authenticated capability, not a service started merely because
local Guest browsing is allowed. Its launch policy must check the signed-in
identity and AI setting, and Guest transition must not leave an authenticated
Sentinel session running under the local Guest owner. Authentication, shared
token publication and service startup resume only after promotion commits.

Choosing sign-in from Guest AI settings records a one-shot intent to enable AI
after successful login. Closing or abandoning that flow cancels the intent;
ordinary sign-in from account settings does not request it. Consume the intent
only after the signed-in transition succeeds, so an unsuccessful or unrelated
login cannot enable AI for Guest.

## Migration transaction

Guest-to-account migration uses a staged source, journal and durable receipt.
Identity mappings cover Profiles and Spaces so imported content and restored
windows refer to the intended destination. A retry reuses the receipt rather than
creating duplicate imported rows or switching to an unrelated target account.

Target verification precedes destructive source cleanup. A failure before target
import can restore writable Guest access; a failure after import may require
recovery against the same target with the source sealed. Do not treat all
migration failures as safe to restart from a fresh snapshot.

Do not equate signed-in commit with successful deletion of every source file.
Once target import and window rebinding are durable, a source-cleanup failure
can complete sign-in with deferred cleanup recorded in the identity-bound
journal. Keep that cleanup retryable rather than rolling the user back to Guest
after the destination has become authoritative.

Soft-deleted URL rules are excluded on both sides. They represent pending sync
tombstones in authenticated stores, not live Guest content to resurrect.

Publishing the destination account includes rebinding Space presentations and
remapping selection through the migration receipt. Retained UI objects must not
keep invalid SwiftData records from the closed Guest store. Delayed edits retain
their originating store identity; see [store lifetime](space-store-lifetime.md).

## Migration scope and conflicts

The migration copies native content while retaining the existing Chromium
Profiles. It is not an account-directory clone or a fresh browsing identity.

| Data | Migration rule |
| --- | --- |
| Native Profile references, Spaces, bookmarks/folders, active pin collections and split pairs, URL rules, Space themes | Import with durable identifier mappings |
| Chromium cookies, history, sessions, extensions and passwords | Remain in the existing Chromium Profile; do not copy them as native account data |
| Credentials, account/AI/connector caches, feedback outbox and attachments | Excluded |
| Stale normal-tab rows, window restore snapshots, account shortcuts and whole account-defaults files | Excluded; migrate only the explicit native snapshot fields |

Target content comes first and existing target settings and pinned scope win.
Reuse matching Profile identifiers; map the Guest default Space to the target
default Space and append custom Spaces with deterministic collision mappings.
Put Guest default-Space bookmarks in one **Imported from Guest** folder; preserve
custom-Space trees. Do not deduplicate bookmarks by URL or title. Pins use
lineage, content and split signatures under the destination scope rather than
URL-only deduplication. In Space scope, the snapshot also retains dormant
Profile-scope pins selected by the migration policy. Target URL rules win
conflicts for the same mapped destination, normalized host and path prefix;
other live rules append.

Quiesce excluded asynchronous writers during the transition. When there is no
local-data owner, falling back to `defaultAccount` could recreate the removed
Guest directory.

## Source and checks

- [Local-data owner and identity activation](../../Sources/AccountController/Account.swift)
- [Access and promotion gates](../../Sources/States/ApplicationState.swift)
- [Staged onboarding credentials](../../Sources/UserInterface/Onboarding/AuthManager.swift)
- [Login and recovery coordination](../../Sources/UserInterface/Onboarding/LoginController.swift)
- [Launch and service boundary](../../Sources/Application/AppController.swift)
- [Sentinel launch policy](../../Sources/Application/SentinelHelper.swift)
- [Guest confirmation](../../Sources/UserInterface/Onboarding/Login/GuestPrivacyConfirmationViewController.swift)
- [Migration, journal and receipt](../../Sources/LocalStorage/GuestDataMigration.swift)
- [Migration tests](../../Tests/PhiBrowserTests/GuestDataMigrationTests.swift)

Use disposable stores to verify colliding identities, interrupted import, retries,
target changes, source cleanup, soft-deleted rules and window selection after
rebinding. A successful row-copy test does not establish the credential cleanup
or real-window acceptance paths.
