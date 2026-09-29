# Bitwarden integration and credential boundaries

Scope: the native provider, helper transport, session custody, agent approval
boundary and app-bundle integration. The separate helper's SDK implementation
is outside this document. A compatible helper is required for live behavior.

## Ownership

| Owner | Responsibility |
| --- | --- |
| `CredentialProvider` | Native status, unlock, lookup and TOTP types |
| `BitwardenService` | Provider state, helper requests and session restoration |
| `BitwardenHelperClient` | Process launch, signature checks, framing and request/reply correlation |
| `BitwardenSessionStore` | App-owned Keychain persistence and verified cleanup |
| `CredentialAccessCoordinator` | User approval and scoped grants |
| Agent credential routes | Availability gates, request validation and result filtering |
| `CredentialAuditLog` | Audit metadata without credential values |

Keep vault cryptography and helper-specific SDK behavior behind the provider
boundary. The native app handles credentials while sending login/restore or
serving an approved request; it is not a process that never sees secrets.

## Transport and helper identity

The app creates an anonymous `socketpair` and launches the helper with the other
end inherited as its input descriptor. There is no named socket for another
process to claim. The client verifies the helper's signing identity and checks
the launched peer before sending the session. The challenge exchange is a
liveness/protocol-version check, not an independent authentication mechanism.

Requests use length-prefixed JSON and request IDs. Helper launch and restore
must complete before ordinary requests can use the connection. The helper is a
separate executable; spawning another copy must not itself grant access to the
app's persisted session. The app owns the Keychain record and sends a restore
only across its own verified connection.

## Session persistence

The app can persist the **account master password** in its data-protection
Keychain, depending on the helper's timeout/restore policy. Do not describe this
integration as never storing the master password.

`BitwardenPersistedSession` distinguishes two shapes:

- A record with `masterPassword` supports unlocked restoration by logging in
  again through the helper.
- A record without it preserves identity for locked restoration. A later unlock
  needs user input.

The record can also contain the server selection and a two-factor remember
token. The app writes helper `persist` events, loads the record on a later
launch and sends `restore` before other requests. A restore failure clears the
stored session. Logout and uninstall have explicit persistence cleanup paths;
uninstall fences later writes before deleting and verifying the Keychain item.

Persisting an account password has a larger impact if recovered than persisting
a device-scoped derived key. Keychain custody does not make a compromised Phi
process safe. The session shape is policy-dependent; do not infer that locking,
disabling the provider and logging out have identical deletion behavior.

## Timeout and session actions

The user-selectable timeout policies are one hour, four hours, on system lock,
on browser restart and never. The default is **on browser restart**. The
timeout action is either **lock** (default) or **sign out**. The app passes the
current timeout and action to the helper at login and restore, and updates a
running helper when settings change. The helper decides what session shape to
persist for its timeout policy; native code must preserve both locked and
unlocked restore shapes described above.

The helper cannot observe macOS screen-lock notifications, so the app applies
the selected lock or sign-out action when that timeout is configured. Locking
ends access to the live vault without equating it to account logout. Explicit
logout sends a separate helper request; the app updates Keychain custody from
the helper's subsequent `persist` event. Uninstall separately clears and
verifies the native Keychain record. Turning the provider off clears
session-scoped agent grants and locks the live vault; it does not itself perform
the explicit logout/Keychain cleanup path. Persistent grants are inert while
credential routes are disabled.

## Agent requests

The provider enablement setting and user-space agent-permission gate apply before
credential access. Approval is mediated by `CredentialAccessCoordinator`, with
scoped grants and a timeout for unanswered prompts. A locked vault may need a
separate unlock prompt after approval.

| Operation | Secret boundary |
| --- | --- |
| `credentials.status` | Availability/status only |
| `credentials.get` in reveal/run modes | Approved secret is released to the agent or its command |
| `credentials.getTotp` | Approved TOTP access through the provider |
| `credentials.autofill` | Native app fills the page and returns a result, not a secret value |

`credentials.get` refuses fill mode rather than silently returning plaintext.
Autofill must not fall back to reveal when its transport is unavailable.
Ambiguous lookups return candidate identities so a caller can narrow the query;
they must not release an arbitrary first match.

For native autofill, destination identity comes from the browser's own page
session, not the agent's claimed host. Field-type checks prevent a password fill
from being redirected into an unrelated text field. A cross-origin request uses
a destination-qualified approval scope rather than inheriting an ordinary
same-site fill grant. Secret wrapper types redact normal descriptions; plaintext
access should remain explicit and auditable.

## Security limits that must remain visible

- A compromised native app or a process able to read its memory can obtain
  credentials handled by the app.
- A filled value is present in the page DOM. Page script or an agent with page
  inspection access can potentially read it back. Autofill avoids returning a
  secret from the credential API; it does not make the DOM secret-proof.
- Unsigned CLI agent names and script paths are not authenticated identities.
  Same-user software can imitate them. Remembered grants keyed to those identities
  must not be described as protection from every same-user process.
- Audit logs record decisions and field-presence metadata, not passwords or TOTP
  values. Never add raw helper payloads to diagnostic logging.

## Bundle and artifact checks

The Xcode project copies `Vendor/PhiBitwardenHelper` into
`Phi.app/Contents/Helpers/` with signing on copy. It also copies the vendored
license and source-offer text into `Phi.app/Contents/Resources/`. A release
check must inspect the **built app**, not just the project settings: confirm
the helper exists, has the expected architecture and signing identity, and the
two notices are present in the shipped bundle.

Keep the source offer aligned with the actual vendored helper build, including
its source revision and SDK/patch references. A successful native compile does
not establish that this executable can launch, restore a session or serve
credential requests. Exercise those flows against the packaged helper before
claiming integration acceptance.

## Source and verification

- [Provider types](../Sources/States/CredentialProvider.swift)
- [Service and transport](../Sources/States/BitwardenService.swift)
- [Keychain custody](../Sources/States/BitwardenSessionStore.swift)
- [Approval coordinator](../Sources/States/CredentialAccessCoordinator.swift)
- [Agent routes](../Sources/States/AgentSpace/AgentSpaceRouter+Credentials.swift)
- [Audit logging](../Sources/States/CredentialAuditLog.swift)
- [Session policy](../Sources/States/BitwardenSessionSettings.swift)
- [Bundle copy phases](../Phi.xcodeproj/project.pbxproj)
- [Vendored license](../Vendor/PhiBitwardenHelper-LICENSE.txt) and
  [source offer](../Vendor/PhiBitwardenHelper-SOURCE-OFFER.txt)

Native lookup and TOTP request paths exist; their presence does not prove that a
particular bundled helper is functional. Live acceptance should identify the
helper artifact and exercise login, ambiguous lookup, locked/unlocked restart,
logout, rejected origins and permission revocation using disposable credentials.
Helper distribution must retain its applicable license and source-offer
materials; process separation alone is not a licensing determination.
