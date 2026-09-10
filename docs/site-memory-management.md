# Native site memory management

`SiteMemoryService.currentAccount()` creates an account-bound native service.
It exposes `collectionEnabled(for:profileID:)`,
`setCollectionEnabled(_:for:profileID:)`, and async
`removeMemories(for:profileID:)`. Callers supply the Chromium profile basename
(e.g. `Default` or `Profile 2`), never a Space ID or a profile display name.
There is no fallback to the active window or another profile.

## Settings and locking

Settings live in `users/<account>/defaults/site_memory.json` under the browser's
account storage root. The JSON maps profile IDs to arrays of disabled hosts.
Missing hosts default to enabled. Enabling a host removes its override.
Hostname matching is exact except that a registrable domain and its `www.`
version share one entry: `v2ex.com` and `www.v2ex.com` use `v2ex.com`.
Other subdomains remain independent: `www.163.com`, `gov.163.com`, and
`www.gov.163.com` do not share settings. Legacy disabled entries under either
spelling are honored; updating the pair removes both spellings and stores at
most one override. Bare ASCII/punycode hosts are lowercased and a trailing dot
is removed. URLs, wildcard prefixes, ports and paths are rejected.

A shared concurrent dispatch queue is the in-process read/write lock across
all store instances. Reads use `sync`; complete read-modify-write operations
use `sync(flags: .barrier)` and atomic file replacement. No network operation
or async suspension holds the lock. A corrupt/unreadable store and failed
writes throw; they must not be presented as successful changes or enabled
collection. Account deletion removes this file with the account directory.

## Lexington query contract

Use the native message API, not `chrome.runtime.sendMessage`:

```javascript
const profile = await chrome.phinomenonPrivate.getProfileInfo();
const raw = await chrome.phinomenonPrivate.sendMessageToApp(
  "memory.getSiteCollectionEnabled",
  { profileId: profile.id, host: "example.com" }
);
const { profileId, host, enabled } = JSON.parse(raw);
```

The response is request-scoped. Only the pinned Lexington extension ID is
accepted; the private API supplies the authenticated sender ID. The trusted
extension supplies its profile ID explicitly, as in the existing memory uplink;
the bridge currently does not attach the sender's browser profile. Missing or
invalid profile IDs fail, and no setting mutation is exposed to extensions.
Failures reject the native message promise. The extension must not interpret a
failed query as permission to collect.

## Server deletion

Native deletion reads Sentinel's component exports for each removal. The default
route uses the existing Service Broker runtime, protocol negotiation, and
account-specific UDS. An explicit `transport_mode: "legacy"` instead uses local
HTTP through `APIClient` at `phi-memory.api_base`, including Sentinel's assigned
port. The export must be a valid loopback HTTP base URL; missing or invalid
legacy endpoints fail. Missing/unknown modes, failed IPC, or an exports lookup
exceeding the 500 ms budget retain UDS. The deadline does not wait for blocked
IPC to observe cancellation; late lookup results are discarded. A failed UDS
request is not retried over HTTP.

Both routes use the shared-auth snapshot and send
`POST /v1/clear/host` to `phi-memory`, with `{ "host": "example.com" }`,
`x-profile-id`, and the current bearer. It does not impersonate an extension.
The account must match the service's captured account and auth must remain
unchanged across suspension. HTTP errors, malformed/negative responses and a
mismatched response host fail. Successful responses return the backend's
observation, browser-memory, ingest-event, summary and galaxy deletion/update
counts. Removal includes subdomains and does not alter collection settings.

Native menu deletion requires confirmation. Its checkbox starts unchecked,
so the request retains the captured page host, including any `www.` prefix.
Checking it expands removal to the registrable domain and all its subdomains:
`gov.163.com` sends `163.com`, and `news.example.co.uk` sends `example.co.uk`.
The dialog shows both the page host and the broader domain. Cancel sends no
request. The backend always includes descendants of the submitted host.

Collection aliases and optional deletion expansion share the Swift helper
`SiteMemorySettingsStore.registrableDomain(for:)`. It matches the bundled
`Resources/PublicSuffixes.dat`, including private registries, wildcard rules,
and exceptions: `alice.github.io` stays scoped to that tenant. The data is a
snapshot of the Public Suffix List; refresh it from publicsuffix.org when
updating domain rules. IPv4 addresses and single-label hosts remain unchanged.
If the resource is unavailable, hosts retain exact matching and deletion scope.
The service's explicit-host deletion API does not expand its input.

## Integration boundary

All layouts have a Manage Site Memories button to the left of Copy URL in the
address bar (the sidebar address bar in Performance). Its standalone menu exposes
collection and removal actions when Phi AI is enabled in a regular window on an
HTTP(S) page with a supported host. Actions capture the page host and window's
Chromium profile ID when the menu opens. The collection checkmark reads the
account's settings store; unavailable settings disable the toggle instead of
defaulting to enabled. Removal calls the native service without changing the
collection setting. Failed mutations show an alert. Both address bars reuse the
same native menu and `SiteMemoryMenuActions` for eligibility, labels, settings
state, captured account/profile/host, and mutation/error handling. The extension
popover no longer includes memory management.

This integration does not change the Lexington observer or popup. Its current
`observationDisabledHosts` storage is not imported
or synchronized yet. The follow-up extension change must query native settings
on startup/page activation and arrange change notification or re-query after a
native update. No automatic enable/disable broadcast is added here.

End-to-end removal still requires coordination with Lexington to pause matching
capture, wait for uploads already on the wire, and discard queued old events;
after server success invalidate the extension's memory cache and resume according
to the persisted switch. This native API deletes server data only: it cannot
clear the extension's IndexedDB outbox, and a successful server response alone
does not guarantee old captures will never be uploaded again. No backend or
extension data is deleted during tests; broker requests use injected executors.
