# Bitwarden Password Manager — Design

Status: **draft / in progress.** Login is implemented and verified; vault lookup
and TOTP are the next slice. This document describes the architecture, the
component layout across the Swift client and the Rust helper, the wire protocol,
the security model, and the remaining work.

---

## 1. Goals

Give Phi first-class access to a user's Bitwarden vault, serving **two**
consumers from one provider:

1. **The browser** — logins for the user (settings card, and eventually native
   autofill through Chromium's password surface).
2. **Code agents** — a `credentials.*` surface over the agent channel so an
   agent driving a Space can obtain a login (with the user's explicit approval)
   instead of asking the user to paste secrets.

Design constraints that shaped everything below:

- **Fine-grained, user-mediated, just-in-time** — the agent gets one credential
  per approved request, never the whole vault; secrets are requested at point of
  use, not stored long-term.
- **License hygiene** — Phi is Apache-2.0; the Bitwarden SDK is GPL-3.0. The two
  must not link into the same binary.
- **Provider-agnostic** — the app depends on a `CredentialProvider` protocol, not
  on Bitwarden. 1Password (`op`), a native store, etc. can be added later without
  touching the UI or the agent surface.

---

## 2. Architecture at a glance

```
┌──────────────────────────────────────────────┐        ┌───────────────────────────┐
│  Phi Browser  (Apache-2.0)                    │        │  PhiBitwardenHelper       │
│                                               │ socket │  (GPL-3.0, native Rust)   │
│  Settings card ─┐                             │ pair   │                           │
│  Login sheet  ──┤                             │ (fd 0, │  protocol server          │
│  Onboarding   ──┼─► BitwardenService ────────┼───────►│  ├─ challenge handshake   │
│                 │   (CredentialProvider)      │  JSON  │  └─ dispatch → Engine     │
│  Agent channel ─┘        │                    │ frames │        │                  │
│  credentials.* ──────────┘                    │        │  SdkEngine ──► Bitwarden  │
│      │ approval + audit                       │        │   (login/sync/lookup)  SDK│
│      ▼                                         │        │   sdk-internal rust-v3.0.0│
│  CredentialAccessCoordinator, AuditLog        │        └───────────────────────────┘
└──────────────────────────────────────────────┘                   ▲
        │                                                          │
        └── spawns on demand with one socketpair(2) end as stdin ──┘
```

Two processes, one inherited socketpair. The app links **none** of the Bitwarden
SDK; the helper links **all** of it. They speak a small JSON protocol over an
anonymous `socketpair(2)` the app creates at spawn — there is no filesystem
socket for any other process to find.

---

## 3. Why a separate process (the GPL boundary)

The obvious approach — link Bitwarden's `sdk-swift` into the macOS app — is a
dead end **and** a license problem:

1. **License:** `sdk-swift`/`sdk-internal` is GPL-3.0. Linking it into the
   Apache-2.0 app would place the combined binary under the GPL. Confining all
   SDK usage to a separate process that communicates only over a socket is
   designed to keep the two as separate works, so Phi can stay Apache-2.0.
   Caveat: the FSF's GPL FAQ treats separate programs talking over
   pipes/sockets as the customary separation, but **not** as solely
   determinative — the semantics of the communication also matter. Treat the
   aggregation position as design intent pending legal confirmation (a release
   blocker; see §9 and "Distributing binaries" in the helper README).
2. **Platform:** Bitwarden's published `BitwardenFFI.xcframework` ships **iOS
   slices only** (`ios-arm64`, `ios-arm64_x86_64-simulator`) — no macOS slice.
   It cannot link into a macOS target at all. Bitwarden publishes no macOS SDK
   binary.

Both problems dissolve with a **native Rust helper** that links the SDK's *Rust
crates* directly (no UniFFI, no xcframework, no slice problem), lives in its own
GPL-3.0 repo, and is driven by Phi over a socket.

> Helper repo: `~/Phi/phi-bitwarden-helper` (standalone, GPL-3.0).

---

## 4. Component layout

### 4.1 App side (Swift, Apache-2.0, in `phibrowser-mac`)

| Component | Path | Role |
|---|---|---|
| `CredentialProvider` protocol | `Sources/States/CredentialProvider.swift` | Vendor-agnostic surface: `status/unlock/lock/lookup/totp`. Types: `CredentialQuery` (`domain`/`itemId`/`search`), `CredentialItem`, `RedactedSecret`, `CredentialProviderStatus`, `CredentialFieldSet`, `CredentialProviderError`. |
| `BitwardenService` | `Sources/States/BitwardenService.swift` | App-scoped singleton (`shared`), `ObservableObject`, conforms to `CredentialProvider`. Publishes `currentStatus` for the UI. |
| `BitwardenHelperClient` | same file | Socketpair transport to the helper: spawn-on-demand, framing, handshake, and a reader thread demuxing replies to pending requests by `request_id`. |
| `PasswordManagerSectionView` | `Sources/UserInterface/Preferences/General/PasswordManagerSectionView.swift` | The Developer-tab card (with the other agent sections, behind the agent-access gate): master toggle, status row, **Log In / Unlock / Log Out** buttons. |
| `BitwardenLoginSheet` | `.../General/BitwardenLoginSheet.swift` | Login (email/password/2FA) and unlock (password + optional 2FA code) sheet. |
| Onboarding option | `Sources/UserInterface/Onboarding/PasswordManager/PasswordManagerViewController.swift` | Bitwarden as a first-class choice in the password-manager step. |
| Pref | `Sources/UserInterface/Preferences/PhiPreferences.swift` → `PasswordManagerSettings.bitwardenEnabled` | Master enable flag; OOBE choice mirrored to new profiles. |
| Extension id | `Sources/Utilities/DefaultExtensionManifestWriter.swift` → `PhiExtensionID.bitwarden` | `nngceckbapebfimnlniiiahkandclblb` (for future extension provisioning). |
| Agent surface | `Sources/States/AgentSpace/AgentSpaceRouter+Credentials.swift` | `credentials.status/get/getTotp/autofill`. |
| Approval | `Sources/States/CredentialAccessCoordinator.swift` | Per-request approve/deny prompt; 10-min remember; 60s auto-deny. |
| Audit | `Sources/States/CredentialAuditLog.swift` | Append-only, **values-free** record of agent credential activity. |
| Skill client | `tools/phi-browser-skill/scripts/lib/helpers.mjs` + `SKILL.md` | `credentialStatus()`, `getCredential()`, `getTotp()`. |

### 4.2 Helper side (Rust, GPL-3.0, `phi-bitwarden-helper`)

| Module | Role |
|---|---|
| `src/main.rs` | Claims the socketpair end from fd 0 (re-pointing fd 0 at `/dev/null`), engine selection, run server. |
| `src/protocol.rs` | Socketpair server: challenge handshake, length-prefixed JSON framing, method dispatch to the `Engine` (thread per request, `request_id` echoed so replies may complete out of order), and the **lifecycle monitor** (parent-death + idle exit). |
| `src/engine.rs` | `Engine` trait, `VaultStatus`/`Query`/`VaultItem`/`EngineError`, and `StubEngine` (used by the default, SDK-free build). |
| `src/bitwarden_engine.rs` | `SdkEngine` — the real backend, behind the `bitwarden-sdk` feature. Restores only from session material Phi sends after the handshake. |

The default `cargo build` uses `StubEngine` and links no SDK — fast, dependency-
light, good for exercising the protocol. `cargo build --features bitwarden-sdk`
links the SDK and uses `SdkEngine`.

---

## 5. Wire protocol

One inherited `socketpair(2)` connection, held for the helper's lifetime. Every
frame is a **4-byte big-endian length prefix** followed by a UTF-8 JSON object.

**Handshake** (liveness/version — *not* auth; the kernel authenticates the
peers, §7):

```
server → { "challenge": "<hex>" }
client → { "challenge_response": "<same>", "client_version": "1.0.0", "protocol_version": 1 }
```

**Request / response:**

```
client → { "protocol_version": 1, "request_id": "<uuid>", "method": "<m>", "params": { … } }
server → { "ok": true,  "result": { … }, "request_id": "<same>" }
       | { "ok": false, "error": { "message": "…", "code"?: "…" }, "request_id": "<same>" }
```

An error carries a `code` only when the client must *act* on it rather than
display it — `twoFactorRequired`, `newDeviceVerificationRequired`,
`invalidNewDeviceOtp` — each naming the credential the server is still waiting
for. Everything else is message-only.

The helper runs each request on its own thread and echoes the `request_id`, so
replies may complete out of order (a 60 s `login` never blocks a concurrent
`status`); the client's reader thread matches replies to pending requests by id.
A request that times out client-side is simply abandoned — its late reply has no
taker and is dropped, with no effect on the shared connection.

**Methods** and their result shapes:

| Method | Params | Result |
|---|---|---|
| `status` | — | `{ status: "notInstalled"\|"notConfigured"\|"loggedOut"\|"locked"\|"unlocked", account?: "…" }` |
| `login` | `{ email, masterPassword, twoFactor?, newDeviceOtp?, server?: { identityUrl, apiUrl }, timeout, action }` | `{}` on success |
| `unlock` | `{ masterPassword?, twoFactor?, newDeviceOtp? }` | `{}` (re-establishes a locked vault from the password; `twoFactor` is a fresh code for a 2FA account whose remember token is absent/expired) |
| `lock` | — | `{}` (→ `locked` state, account kept) |
| `logout` | — | `{}` |
| `setTimeout` | `{ timeout, action }` | `{}` (updates the session-timeout policy live) |
| `lookup` | `{ query: { domain \| id \| search } }` | `{ found: bool, item?: { credentialId, type, name, username?, password?, uri?, notes?, domain?, … } }` — `type` is `login`/`note`/`card`/`identity`/`sshKey`, and a card/identity/SSH-key item adds its type-specific fields flat and wire-named (`number`, `ssn`, `privateKey`, …). A domain query serves logins only (it matches through login URIs); `id`/`search` reach every type. An ambiguous query answers `{ found: false, ambiguous: true, matches, candidates: [{ credentialId, type?, name?, username?, uri?, domain? }] }` — non-secret identities only, no item |
| `getTotp` | `{ query }` | `{ totp: "…" }` |

The Swift `BitwardenHelperClient` and the Rust `protocol.rs` each implement this
independently (no shared source crosses the Apache/GPL boundary), the same way
`SentinelIPCClient` mirrors the Sentinel runner protocol.

---

## 6. The Bitwarden SDK integration

### 6.1 Pin

| | |
|---|---|
| SDK source | local clone `~/Phi/sdk-internal`, branch `phi/rust-v3.0.0-patched` (path deps) |
| Upstream base | `github.com/bitwarden/sdk-internal` tag `rust-v3.0.0` (commit `7fd530e`) |
| Matching Swift release | `sdk-swift` `v3.0.0-7165-e504886` |
| Crates | `bitwarden-core` (feature `internal`), `bitwarden-vault`, `bitwarden-pm`, `bitwarden-sync` |

The SDK is consumed as **path dependencies into a local patched clone** rather
than git dependencies, because the pinned tag needs Phi patches to work against
the current production server. Patches carried on `phi/rust-v3.0.0-patched`
(one commit each, on top of `7fd530e`):

- `identity_success_response.rs`: `#[serde(default)]` on `resetMasterPassword`
  — the 2026 server stopped sending it, which made the whole success-response
  deserialize fail, fall through to the `Refreshed` variant, and panic at an
  `unreachable!` in `PasswordLoginResponse::process_response`. Fixed upstream
  after our pin; drop the patch when the pin advances.
- `identity_success_response.rs` + `password.rs`: surface `two_factor_token`
  (the 2FA remember token issued when the login's `TwoFactorRequest` set
  `remember: true`) through `PasswordLoginResponse` — upstream parses it and
  then drops it in `process_response`, which strands 2FA accounts on every
  re-login (unlock/restore) that has no fresh code to offer (§7.6).
- `password_token_request.rs` + `password.rs` + `internal.rs`/`builder.rs` +
  `identity_token_response.rs`: new-device login protection (§7.7). Upstream
  can neither send the `newDeviceOtp` the server asks for nor put this
  install's own `deviceIdentifier` in the token body, so an account with the
  protection on could never sign in from Phi at all (§6.2).

**`Cargo.lock` is inherited verbatim from `sdk-internal` @ `rust-v3.0.0`.** This is
mandatory, not optional: the SDK depends on pre-release RustCrypto crates
(`ml-dsa`, `crypto-bigint`, `elliptic-curve`, `primefield`, `rsa 0.10.0-rc.17`, …)
whose APIs churn between RCs. Consuming the SDK's crates as git dependencies does
**not** inherit its lockfile, and cargo will otherwise resolve newer,
API-incompatible versions and the build fails with trait-bound errors in the
crypto stack. Rule: **never let cargo regenerate the lock**; update it in lockstep
with the SDK tag, and reset it from the tag if a dependency change perturbs it.

### 6.2 Login / sync flow

A headless Rust consumer of the SDK's async client:

```rust
// once, at process start (feeds the SDK's GlobalClient path only):
init_host_platform_info(HostPlatformInfo::from(&client_settings()));

// login (also initializes user crypto → unlocks the vault):
let client = PasswordManagerClient::new(Some(client_settings()));
let result = client.0.auth().login_password(&PasswordLoginRequest {
    email, password,
    // remember: true → the success response carries a remember token
    // (result.two_factor_token, Phi patch) to replay as provider `Remember`
    // on later logins from this device.
    two_factor: token.map(|t| TwoFactorRequest { token: t, provider: Authenticator, remember: true }),
    // Phi patch: the emailed new-device code, on the retry that carries one.
    new_device_otp: None,
}).await?;
if result.two_factor.is_some() { /* prompt for the 2FA code and retry */ }

// pull the vault:
client.0.sync().sync(SyncRequest { exclude_subdomains: None }).await?;
```

Note: `bitwarden-core`'s networked login is gated behind the **`internal`** feature
(the UniFFI mobile layer doesn't expose it because mobile apps do their own
networking). Enabling `internal` is what makes a self-contained login possible.

Two hard-won facts about client construction:

- **Headers come from `ClientSettings`, not `init_host_platform_info`.** The
  global only feeds the SDK's `GlobalClient`; `PasswordManagerClient::new`
  builds its HTTP headers from the settings you pass (`ClientBuilder::build` →
  `build_default_headers(&HostPlatformInfo::from(&settings))`). Passing `None`
  silently drops `Bitwarden-Client-Version` — and the identity server **rejects
  logins without that header** ("No client version header found, required to
  prevent encryption errors"). The rejection fires only *after* credentials
  validate, so a bad-credential smoke test does not catch it.
- **The version value is compared against per-account minimums**, so
  `client_settings()` reports a current official client release
  (`BITWARDEN_CLIENT_VERSION`), not the helper's own crate version. It also
  supplies a **stable `device_identifier`** persisted as `bitwarden-device-id`
  in the browser's data folder (`PHI_BROWSER_DATA_DIR`) — Bitwarden keys
  known-device tracking on it, so it must survive helper restarts.

**New-device login protection.** An account with it on (the default for
accounts without 2FA) makes the identity endpoint refuse any login whose
`deviceIdentifier` it does not recognize: it emails a one-time code and answers
`invalid_grant` with error model message `new device verification required`.
The next attempt must carry that code as `newDeviceOtp`; another attempt
*without* one is how a fresh code is requested. Two upstream gaps made this a
dead end, both patched:

- `PasswordTokenRequest` had no `newDeviceOtp` field, so the demand was
  unanswerable — and since a device only becomes known through a token grant it
  could never obtain, the account was locked out of Phi permanently rather than
  temporarily.
- `request_identity_tokens` sent a hardcoded `DeviceType::ChromeBrowser` and
  the constant identifier `b86dd6ab-…`, ignoring `ClientSettings`. The
  persisted `device_identifier` above reached the network only as a
  `Device-Identifier` header, which the identity endpoint does not use for
  device tracking, so it had no effect on anything.

The helper reports the two outcomes as the `newDeviceVerificationRequired` and
`invalidNewDeviceOtp` error codes (§5), which is what makes the sign-in sheet
show its verification-code field and its "email me a new code" action.

The `header_probe` example (`cargo run --example header_probe --features
bitwarden-sdk`, debug builds only) captures a login request against a local
listener and asserts the header is on the wire.

### 6.3 Lookup / TOTP (planned)

After `sync`, decrypt the synced ciphers (`client.vault().ciphers().decrypt_list`),
match by URI/domain, and extract `LoginView { username, password, uri, totp }`; TOTP
codes are generated from the item's `totp` field. Not yet implemented.

---

## 7. Security model

### 7.1 Trust boundary

- The app process holds **no** vault secrets except transiently in transit for a
  specific approved request. All vault crypto and the unlocked user key live in
  the helper.
- The channel is an anonymous `socketpair(2)` created by the app at spawn and
  inherited by the helper as fd 0. It has **no filesystem name** — there is
  nothing for any other process (same user or not) to connect to, squat, or
  race.

### 7.2 Peer isolation and session custody

The socketpair guarantees the two ends only ever talk to each other, so no
same-user process can connect to a *running* helper or impersonate the helper to
Phi. What it does **not** prove is the identity of the process that *spawned* the
helper: the helper's peer is whoever launched the binary, not necessarily Phi.
The helper is world-executable and Phi-signed, so a same-user attacker can spawn
their own copy with their own socketpair, and the helper cannot tell that
launcher apart from Phi.

That is only dangerous if the spawned helper can obtain the vault on its own — and
it cannot, because the helper holds **no** at-rest store. Session custody lives in
the *app's* Keychain (`BitwardenSessionStore`), whose item ACL binds to the
*app's* code signature, which the helper binary does not satisfy. A spawned
helper therefore cannot read it, and the master password an attacker would need
to log in is out of reach. A freshly spawned helper starts logged-out and stays
that way until Phi sends it a `restore` — over the pair Phi created — carrying the
session Phi just read from its own Keychain. An attacker's spawned helper is never
sent one.

This closes a real hole in the earlier design, where the *helper* read a Keychain
item scoped to the helper's own signature: a spawned copy shared that signature,
so it could silently restore the session and serve lookups (Apple TN2206 —
Keychain trust follows the signed program's designated requirement, not its
parent). See §7.7.

Further back, this whole model replaced a named-socket design
(`/tmp/phi-bw-<h>/helper.sock`) whose audit-token → `SecCode` checks
authenticated *clients* to the helper but not the *server* to the app, letting a
same-user process squat the path and harvest the login password. The socketpair
closed that; moving custody to the app closes the spawn vector.

### 7.3 The challenge handshake

The `{challenge}` → `{challenge_response}` exchange is a **liveness/version**
check, not authentication (the server issues the nonce and the client echoes it).
Peer isolation is the socketpair itself, §7.2; the vault is protected by custody,
not by trusting the launcher.

### 7.4 Agent access mediation

The `credentials.*` surface is gated four ways:

1. **Provider enable** — the Settings ▸ Developer Bitwarden toggle
   (`bitwardenEnabled`), checked per request in the route handlers: while off,
   `credentials.status` reports `disabled` (without spawning the helper) and
   `credentials.get` refuses with `not_ready`/`disabled` before any prompt, so
   no grant — including a persistent **Always Allow** — can be exercised.
2. **Master switch** — registered via `registerUserSpaceManaged`, so the
   Developer ▸ Agent-permissions toggle turns the whole family off at once.
3. **Per-request approval** — `CredentialAccessCoordinator` pops an approve/deny
   prompt naming the agent and the site (`Approve Once` / `Approve for 10 min` /
   `Deny`), with a **60-second auto-deny** so an unattended prompt can't hang an
   agent. Disabling the provider clears session grants ("Always" grants stay
   listed in Settings but are inert while disabled, per gate 1). If the
   session-timeout policy left the vault **locked**, an approved request then
   pops an **in-flow unlock prompt** (`promptForUnlock`) — the master password
   is typed there and passed straight to the helper (never stored), and a
   cancel returns a clean `not_ready: locked` to the agent.
4. **Audit** — `CredentialAuditLog` records `requested/approved/denied/served`
   with the agent, scope, and **field-presence booleans only — never values**.

Which routes release a secret **to the agent** is deliberate and enforced at the
boundary, not left to a cooperating runner:

- `credentials.get` serves only the modes whose secret inherently crosses to the
  agent: `reveal` (into the agent's context — the honest tradeoff, same as `aac
  connect`) and `run` (into a command's environment; the spawned command
  receives it, so it is agent-level exposure the app can't claw back). Both are
  prompted plainly — the wording does **not** pretend the agent won't see the
  value.
- A page `fill`, whose whole contract is that the secret must **not** reach the
  agent, is served **only** by `credentials.autofill`: Phi looks the credential
  up and performs the fill in-app (value → page), returning just `{filled}`.
  `credentials.get` hard-**refuses** `mode:"fill"` (returns `fill_requires_autofill`)
  so a fill can never be quietly satisfied by revealing the plaintext instead.
  A malicious or prompt-injected agent asking for a "fill" therefore gets no
  secret at all.
- **An ambiguous query releases nothing.** When several vault items fit a query,
  the helper refuses to pick one: it returns the candidates' non-secret
  identities (`credentialId`/`username`/`uri`/`domain`) and the app answers
  `ambiguous`, requiring a query narrowed to a single account (`{domain,
  username}` or `{id}`). Which account an agent gets is the user's call —
  serving "the first match" would release an arbitrary account's secret and
  only then report the ambiguity, after the wrong plaintext had already crossed
  the boundary. A served credential is therefore always the query's unique
  match.

The in-app fill is performed by the app acting as its own DevTools client
(`AppDevToolsPageSession`): a `socketpair()` handed to Chromium through the same
FD-injection transport agent connections use, upgraded onto the page's
`/devtools/page/<targetId>` endpoint. The skill resolves the element with its
own machinery and stamps it with a one-time `data-phi-autofill` marker; the app
finds the marker (top document + same-origin frames) and sets the value through
the native setter, so no selector scheme crosses the boundary and the secret's
only appearance outside the vault is the app's page-bound `Runtime.evaluate`.
Two enforcement details:

- **The destination host is browser truth.** The app reads the page's URL via
  `Target.getTargetInfo` on its own session — never from the agent — and
  refuses `origin_mismatch` when it doesn't belong to the credential's site
  (the item's own uri/domain; the query domain for domain queries, checked
  before the prompt so a misdirected fill costs no approval). The fill JS also
  insists the element really is the kind of field the approval named
  (`password` requires `type=password`), so a password can't be steered into a
  free-text field by re-typing the target.
- **Cross-origin fills can't ride a standing grant.** `allowCrossOrigin` (the
  SSO-portal escape hatch) switches the approval to a destination-qualified
  scope — `"site → page-host"` — which a plain same-site fill grant never
  covers, so a redirected fill always faces its own prompt naming both sides.

On a build without the dispatch (or before the DevTools transport is up)
`credentials.autofill` returns `autofill_not_available` — but it **never**
returns the secret, and the skill's `fillCredential` refuses to fall back to a
reveal. Secret fields are wrapped in `RedactedSecret` (prints `<redacted>`;
plaintext only via an explicit, greppable `.reveal()`).

### 7.5 What this does *not* defend against

- A **compromised Phi** — the helper serves whoever holds the socketpair Phi
  created and only ever restores a session Phi feeds it, so a malicious Phi owns
  the credential UI by construction. That's inherent. (A same-user process that
  merely *spawns* the helper is not Phi: it gets a logged-out helper with no path
  to the vault — §7.2.)
- A **root or debugger-entitled** process — anything that can read another
  process's memory can read the channel too. The socketpair defends against
  unprivileged same-user processes, which is the realistic threat.
- **Page readback of a filled value.** Once a fill lands, the plaintext is in
  the page's DOM — and an agent driving that page over CDP can read it back
  (`el.value`), same as Chromium's own autofill is readable by page script. So
  `credentials.autofill` does not make the secret unreachable to a *malicious*
  agent; what it enforces is that no API call returns the plaintext, an honest
  prompt gates every fill, the destination is origin-bound, and a
  *cooperative-but-careless* agent (the common case: prompt injection, sloppy
  logging) never has the value in its context to leak. The skill's
  output-scrubbing can't help here — the runner never sees the value, so it
  has nothing to scrub.
- **Agent-identity spoofing → grant reuse.** Remembered credential grants (§7.4)
  are keyed on the connecting agent's identity, which for an unsigned CLI agent
  is derived from `argv[0]` / the script path — attacker-controllable by a
  same-user process (see `AgentPeerIdentity`; that identity is an aid for the
  consent prompt, explicitly *not* a security boundary). A local process that
  brands itself as an agent holding a standing grant inherits that grant with no
  prompt. This is the same residual as launching a genuinely-signed agent to
  reuse its grant; the same-uid gate plus the revocable, scoped grants are the
  mitigation. Practical takeaway: an **Always Allow** / **all agents** `reveal`
  grant is a broad standing authority on a spoofable key — prefer narrow, timed
  grants, and revoke from Settings ▸ Developer ▸ Agent approvals when done.

### 7.6 Session timeout

Settings ▸ General ▸ *Session timeout*: a *Timeout* — `1 hour` / `4 hours`
(idle) / `On system lock` / `On browser restart` / `Never` — and an *action* —
`Lock` or `Log out`. `Lock` drops the in-memory key but keeps the account (a real
`locked` state; `unlock` re-establishes the vault from the master password the
user types — the app never stores it, per §7.1); `Log out` clears everything.
Unlock is a re-login under the hood, so for a 2FA account it replays the stored
**remember token** (requested with `remember: true` at login, provider `Remember`
on the re-login) — and when that token is absent or expired, the unlock sheet
offers a two-step-code field whose fresh code also mints a new remember token.
Locking keeps the token: it is device trust, not vault-key material.
Enforcement is split: the helper's monitor applies the idle timeouts and decides
the restart behavior in the record it emits for the app to persist (see §8); the
app watches `com.apple.screenIsLocked` for system-lock and forwards the action.
The policy rides the `login`/`restore` requests and a live `setTimeout`.

### 7.7 Persisted-session trade-off

Session persistence (§8) stores the **master password** in the macOS Keychain so
a restart restores the vault without a re-login. Two deliberate choices:

- **Custody is the app's, not the helper's.** The item lives under service
  `com.phibrowser.bitwarden.session`, created by the *app*, so its ACL binds to
  the app's code signature. The helper — a world-executable, Phi-signed binary a
  same-user attacker could spawn — cannot read it and receives its session only
  via a `restore` the app sends after the handshake (§7.2).
- **Password, not vault key.** Storing the master password reuses the verified
  login path. Be explicit about the blast radius: the persisted secret is the
  **account** master password, not a device-scoped derived key — so anyone who
  recovers it (a compromised Phi, or a user coaxed into an "Always Allow"
  keychain prompt) gains the whole Bitwarden *account* — password reset,
  new-device authorization, every vault — not merely this device's cached vault.
  The data-protection-keychain custody (§7.2) keeps it out of reach of the helper
  and other same-user apps, but the at-rest secret is still account-level. That
  is why persisting the decrypted **user key** and re-initializing crypto
  (biometric / "never lock" style) is the preferred design — it shrinks the
  at-rest exposure to a device-scoped key; it is deferred only because the pinned
  SDK exposes no public export of the account cryptographic state (see §11).

A signing-identity change orphans the item; the read then fails and the user logs
in again, which rewrites it. Any Keychain failure is treated as "no session". How
much is stored is gated by the timeout policy (§7.6): `On browser restart`
persists identity only (locked-restore) or nothing (log-out), so a restart never
silently returns unlocked.

The record also carries the 2FA **remember token** (§7.6) in both restore
shapes. That is deliberately weaker custody than Bitwarden's own clients give it
(plain local storage): it is device trust — it lets a login skip the second
factor, but is useless without the master password — and without persisting it a
2FA account could never restore or unlock at all.

---

## 8. Lifecycle

- **Spawn on demand.** `BitwardenHelperClient` spawns the helper on the first
  request, creating the socketpair and handing the far end to the child as
  stdin. The single connection then lives as long as the helper; a request that
  finds the helper dead (process gone or socket EOF) tears the connection down
  and respawns once.
- **Exit with the browser.** The helper exits when its socket end reaches EOF
  (the app closed it, quit, or crashed — the kernel closes the app's end in
  every case), with the monitor thread's parent-death check (`getppid() == 1`)
  as a backstop — so it never lingers holding an unlocked vault.
- **Session persistence across restarts.** On a successful login the helper
  decides what should survive a restart (per the timeout policy) and emits it as a
  `persist` event; the *app* writes that record — account credentials + chosen
  server, and the master password only for unlocked-restore — to its own Keychain
  (`BitwardenSessionStore`). On the next start the app reads it back and sends a
  `restore` right after the handshake, **before any other request**, so the vault
  is re-established (or comes back *locked* if only identity was stored) without a
  race; the helper re-runs the normal login + sync, replaying the stored 2FA
  remember token for accounts that need a second factor. So a restart shows
  *Signed in*, not a re-login prompt. The helper itself reads no store — a copy
  spawned by another process starts logged-out (§7.2). **Log Out** clears the
  stored session; toggling the provider off only locks the in-memory vault (the
  session survives, so re-enabling stays signed in). A restore that fails
  (password changed, revoked, remember token expired) is reported back so the app
  drops the stored session and falls back to a normal login. See §7.7 for the
  security trade-off.

---

## 9. Build & distribution

- The helper is built with `cargo build --release --features bitwarden-sdk` and
  **vendored** into `phibrowser-mac/Vendor/PhiBitwardenHelper`.
- Phi's Xcode project bundles it via a **"Copy Bitwarden Helper"** copy-files
  phase (`dstSubfolderSpec` = wrapper, `Contents/Helpers`), which **code-signs it
  with the app's team identity** (hardened runtime). This is a native copy phase,
  not a script phase, so it is unaffected by `ENABLE_USER_SCRIPT_SANDBOXING = YES`.
- `install-into-phi.sh` (in the helper repo) rebuilds + refreshes the vendored
  binary and, for quick iteration, hot-swaps it into the newest built app bundle
  and kills the stale helper process (the app respawns it on the next request).
- **Distribution (GPLv3 §6):** a companion "Copy Bitwarden GPL Notices" phase
  bundles `PhiBitwardenHelper-LICENSE.txt` (the complete GPLv3 text) and
  `PhiBitwardenHelper-SOURCE-OFFER.txt` (the Corresponding Source designation,
  generated from the helper repo's `dist/SOURCE-OFFER.txt` and stamped with the
  build commit by `install-into-phi.sh`) into `Contents/Resources/` — codesign
  rejects non-code files in `Contents/Helpers/`, so they cannot sit next to the
  binary. Release blockers remain: the helper repo must be public at the URL
  the offer designates, the shipped offer must carry a clean (non-`-dirty`)
  commit stamp, and the separate-process/aggregation analysis plus the offer
  text need legal sign-off — see "Distributing binaries (GPLv3 §6)" in the
  helper README.
- **Universal:** the vendored binary is currently arm64; a release build should
  `lipo` `aarch64-apple-darwin` + `x86_64-apple-darwin`.

There is intentionally **no** Swift helper target — an earlier design had one
(linking a Swift CLI engine), now retired in favor of the single Rust binary.

---

## 10. End-to-end flows

### 10.1 Settings login

1. User enables the Bitwarden card → `bitwardenEnabled = true`, extension install
   requested.
2. Card `.task` → `BitwardenService.status()` → helper `status` → `loggedOut` →
   card shows **Log In**.
3. **Log In** → sheet → `BitwardenService.login(email, password, 2FA)` → helper
   `login` → `login_password` (identity server) → `sync`.
4. `status` → `unlocked` → card shows **Signed in as …**.

### 10.2 Agent credential request

1. Agent calls `getCredential("github.com")` → `credentials.get` (gated by the
   Agent-permissions switch and the Bitwarden enable toggle).
2. `CredentialAccessCoordinator` prompts the user (or honors a live 10-min grant).
3. On approval → `BitwardenService.lookup(.domain("github.com"))` → helper
   `lookup` → decrypt + match → fields returned.
4. `CredentialAuditLog` records `served` with field-presence flags only.

---

## 11. Status & roadmap

**Done and verified**

- Provider protocol, service, UI (card, sheet, onboarding), prefs.
- Agent `credentials.*` surface + approval + audit + skill helpers.
- Rust helper: protocol, lifecycle, stub + SDK engines.
- SDK pin (native macOS build of the pinned SDK) with inherited lockfile.
- **Login / sync**: implemented against the real SDK and verified end-to-end
  with a real account (login → vault sync → `status: unlocked` with the account
  email). Requires the client-version header and the SDK patch described in
  §6.1/§6.2.
- **Session persistence** (§8): login is stored in the macOS Keychain and
  restored on startup, so a browser restart stays signed in. Keychain
  save/load/clear verified across process runs; restore reuses the verified
  login path.

**Next**

- **Vault lookup + TOTP** (`lookup`/`getTotp`) — decrypt synced ciphers, match by
  domain, extract fields. (Currently stubbed.)
- **User-key persistence + biometric unlock** — store the decrypted user key
  instead of the master password (see §7.7) and add biometric unlock; needs SDK
  surface to export the account cryptographic state. This shrinks the at-rest
  blast radius from account-level (a stored master password) to a device-scoped
  key, and is the mitigation for the §7.7 trade-off.
- **Native autofill** — plug the provider into Chromium's `PasswordStoreBackend`
  so Bitwarden becomes the browser's autofill source for the user's own
  browsing. (The agent-facing half — `credentials.autofill`, the in-app fill
  where the secret never crosses to the agent — is implemented, via the
  app-owned DevTools session in §7.4.)
- **Extension provisioning + shared unlock** — per-profile auto-install of the
  Bitwarden extension and a `com.8bit.bitwarden` native-messaging host so one
  unlock serves both the SDK provider and the extension.
- **Universal binary** in release builds.

**Resolved issues**

- *"The operation couldn't be completed. (…ClientError error N.)"* on login —
  `BitwardenHelperClient.ClientError` lacked `LocalizedError` conformance, so
  every failure (including the helper's real message in `helperError`) rendered
  as Foundation's opaque fallback. The earlier `ClientError error 0` known
  issue was this same rendering bug. Fixed; the sheet now shows the helper's
  message verbatim.
- *"No client version header found"* from the identity server on login — the
  helper passed `PasswordManagerClient::new(None)`, which drops the
  `Bitwarden-Client-Version` header (see §6.2). Fixed via `client_settings()`.
- SDK panic `unreachable: Got a refresh_token answer to a login request` on a
  *successful* login — server response-shape drift against the pinned SDK; see
  the patch note in §6.1. Login + sync verified end-to-end against a real
  account after the fix.
- Login could exceed the client's blanket 10 s socket timeout (it covers
  identity round trips + full vault sync); login/unlock now use 60 s.
- Only the US cloud was reachable — the login sheet now offers **bitwarden.com /
  bitwarden.eu / self-hosted** (with a URL field). The chosen region resolves to
  identity + api URLs in the sheet and rides an optional `server` block on the
  `login` request into `ClientSettings`; the SDK has no region switch of its own,
  so the client supplies the URLs (EU → `identity.bitwarden.eu` /
  `api.bitwarden.eu`; self-hosted → `{base}/identity` + `{base}/api`, the standard
  self-host endpoint layout). The self-hosted URL defaults to `https://` when no
  scheme is typed, but an explicit scheme (including `http://`) is honored as
  entered — the server choice, transport included, is deliberately the user's.

- **2FA accounts could not unlock or restore** — login sent `remember: false`,
  lock dropped the SDK client entirely, and unlock/restore performed a fresh
  login with no second factor, so a 2FA account locked once and stayed locked
  (and its persisted session died on the first restart, taking the Keychain
  record with it). Fixed: login asks the server to remember the device
  (`remember: true`; the SDK is patched to surface the returned token, §6.1),
  the token persists in both restore shapes (§7.7/§8) and is replayed as
  provider `Remember` on unlock/restore, and the unlock sheet gained a
  two-step-code field for when the token has expired (a fresh code mints a new
  one).
- **Ambiguous lookup released an arbitrary account's secret** — the helper
  served the first matching cipher and reported only a match count, so
  disambiguation could happen only after a (possibly wrong) secret had crossed
  the boundary. Fixed end-to-end: several matches now return non-secret
  candidates and an `ambiguous` error at every layer (helper → app routes →
  skill), and a served credential is always the query's unique match (§7.4).

**Known limitations**

- 2FA provider is hardcoded to `Authenticator` (plus the stored `Remember`
  token); email/Duo/YubiKey 2FA and Bitwarden's new-device email verification
  are not yet handled.
- Login is email + master password only; passkey and single sign-on are not
  offered (the SDK helper login path doesn't support them).

---

## 12. Design decisions & alternatives

| Decision | Alternatives considered | Why |
|---|---|---|
| Native **Rust** helper linking the SDK crates | Link `sdk-swift` xcframework into the app | The xcframework is iOS-only (no macOS slice) and GPL — a non-starter on both counts. |
| **Separate process** over a socket | Link the SDK into a GPL helper *library* in-process | Designed so the app can stay Apache-2.0 as a separate work; per the GPL FAQ, socket IPC is the customary separation but not solely determinative — legal confirmation is a release blocker (§3, §9). |
| **Bitwarden SDK** as the engine | Shell out to a separately-installed Bitwarden CLI | Linking the SDK's Rust crates avoids requiring the user to install and maintain a separate CLI binary, and keeps the vault entirely in-process behind the `Engine` seam. |
| **Inherited `socketpair(2)`**, no named socket | Named UDS + code-signature peer auth (the original design); XPC Service | The named socket authenticated clients but not the server — a same-user process could squat the path and harvest the `login` master password. The socketpair has no name to attack and the kernel pins both peers, deleting the peer-auth code entirely. An XPC Service gives the same guarantee plus launchd lifecycle, but requires restructuring the Rust binary into an `.xpc` bundle — deferred. |
| **Inherited `Cargo.lock`** | Pin individual crypto crates | The RC crypto stack is too interdependent for one-off `=` pins; the SDK's own lock is the only reliable pin set. |
| Provider **protocol** in the app | Bitwarden-specific code in the UI/agent layers | Lets 1Password/native store drop in without touching UI or the agent surface. |
