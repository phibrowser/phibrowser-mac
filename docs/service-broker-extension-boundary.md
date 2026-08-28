# Service Broker Extension Boundary

Phi Browser exposes the Sentinel service broker to the packaged Sidecar,
Lexington, and Kensington extensions through a pinned native-extension
boundary. The browser, rather than an extension, discovers the account-scoped
Unix domain socket and negotiates broker limits.

```text
Sidecar request-scoped adapter
  -> chrome.phinomenonPrivate.sendMessageToApp
  -> Phi Browser service-broker extension protocol
  -> account-scoped Sentinel broker UDS
  -> phi-agent
```

Replies use the request-scoped `sendMessageToApp` return value because the existing native-to-extension event is broadcast to every extension context. Authenticated bodies, headers, credentials, stream chunks, and WebSocket frames must never cross that broadcast channel.

## Trust and transport invariants

- Only the exact pinned Sidecar (`fenmfiepnpdlhplemgijlimpbebebljo`),
  Lexington (`pjgdkljlcbjgedgeppodjijjphfcplno`), and Kensington
  (`pjlnhbfabokjejbhmgghmjiaknfhnima`) extension IDs are authorized. These IDs
  derive from the manifest keys shared by internal dev, Canary, and Stable
  deployment variants; the `allowedCanary...` source names are historical, not
  channel-specific identities. Standalone keyless builds, empty/debug/CDP
  senders, differently cased IDs, and all other extensions are rejected before
  transport access.
- Service requests use `/<service>/<upstream-path>`. The native boundary
  consumes one exact known service prefix before validating and forwarding the
  upstream path; lookalike prefixes are rejected. The legacy unprefixed
  phi-agent `/api`, `/v1`, and `/ws` shape remains available only to Sidecar.
- Release-Canary Swift sources must compile with the `NIGHTLY_BUILD` condition. This keeps shared authentication, locks, heartbeats, API endpoints, and Auth0 configuration on Canary-specific accounts and endpoints; a C/Objective-C preprocessor definition alone does not affect Swift `#if` branches.
- Extensions select only an allowed relative request path and method. They cannot supply a socket path, host, port, service name, or extension identity header.
- Phi Browser resolves the account-scoped broker socket from shared authentication state. The preferred `/tmp/phi-sentinel-<hash>/sockets` path is used only when each existing short-path component is a real directory owned by the current uid; otherwise both Sentinel and the browser select `<storage>/state/sockets`. There is no TCP host/port fallback.
- Sentinel reports the transport mode it currently applies to clients (`legacy`, `uds`, or `full_uds`) as an additive `transport_mode` string on the response of the `getComponentExports` IPC the browser already makes; no IPC method is added for it. The browser accepts the field at the response envelope root or inside the exports object, and reads an absent, non-string, or unrecognised value as `uds` — the behaviour of every Sentinel released before the field existed. Removing that one key from the exports object is the single deliberate exception to forwarding exports verbatim: `transport_mode` is a browser-facing routing signal, not a component export, so extensions and `PhiAgentEndpointResolver` never see a bare string among the component-ID objects. Every other entry is forwarded unchanged.
- A successful UDS connect is not proof of broker identity. Before sending a request, credential, or WebSocket handshake byte, the browser requires the peer uid to match its effective uid and validates the `LOCAL_PEERPID` process against the signed `service-broker` code requirement for Team ID `87DQ3HMK5G`. Failure is terminal and never falls back to another transport.
- The browser enforces the broker's negotiated request, response, streaming, and WebSocket limits.
- Chromium keeps the legacy 1 MiB native-message JSON limit for non-broker traffic. `broker.*` envelopes admit exactly `ceil(16 MiB / 3) * 4 + 64 KiB` bytes so a negotiated 16 MiB raw request plus bounded base64/JSON overhead reaches the browser protocol; the Mac layer remains the semantic and decoded-size enforcement point.
- Each HTTP connect/write/response-head sequence, and each WebSocket handshake, send, and close, has one monotonic 30-second I/O budget. The WebSocket receive budget is 30 seconds since the last inbound frame of any kind — data, continuation, ping, or pong — and after 10 seconds of read silence the browser sends its own WebSocket ping, so an idle-but-alive channel stays open while a dead peer is still detected within 30 seconds. The Sentinel broker answers these bridge-side pings itself, so keepalive never depends on the upstream service. Streaming HTTP body reads have no per-read deadline, matching Chromium fetch semantics; they are bounded only by cancellation, EOF, and the channel idle timer. Swift task cancellation closes the UDS descriptor so a stalled peer cannot leave a detached poll/read/write running indefinitely.
- `/broker` is reserved for broker-owned management routes. Only `broker.http.request` admits exact `GET /broker/healthz` with no body and maps it to broker service path `/healthz`. Query suffixes, encoded spellings, path variations, other methods, bodies, streaming attempts, `/broker/version`, and every other extension-supplied `/broker` path are rejected.
- `broker.capabilities` is the explicit bridge handshake. After exact sender
  authorization and payload validation, the browser reads Sentinel's current
  `transport_mode` and answers `unsupported_message` when — and only when — that
  mode is exactly `legacy`; for `uds`, `full_uds`, an absent field, an
  unrecognised value, a failed lookup, or a lookup that outruns its budget it
  returns `protocolVersion: 1` without requiring account auth or Sentinel
  runtime resolution. The mode read carries its own browser-local 500 ms
  budget, well inside the extension's 1_500 ms per-attempt capability probe:
  a hung-but-connectable Sentinel must never stall the handshake until the
  extension's probe ladder gives up, because an exhausted ladder is cached as
  "unsupported" — the opposite of what a failed lookup must mean. The budget
  bounds the answer but not the work — the IPC blocks in `connect`, which no
  socket timeout covers — so two further limits bound the work itself:
  genuinely concurrent handshakes are **coalesced onto one lookup**, and after
  a lookup expires the browser **stops asking Sentinel for 5 seconds** and
  answers from the fallback without starting new IPC. Neither is a cache of the
  mode: the shared lookup is released as it completes, and the first handshake
  after the pause pays for a fresh read, so a `uds` to `legacy` switch still
  converges. This lets newer
  extensions distinguish an older browser from a supported broker before
  selecting a business transport, and lets Sentinel's staged rollout withdraw
  the broker path from every maintained extension at once. The mode is re-read
  on every handshake and is never cached with the negotiated runtime, so a
  `uds` to `legacy` switch converges on the next handshake. The legacy answer is
  recorded as `ServiceBrokerFallbackReason.protocolUnsupported`, whose
  `allowsLoopback` is true; no other transport-mode value permits fallback.

### Transport-mode compatibility

| Sentinel reports | Browser answer to `broker.capabilities` | Extension transport |
| --- | --- | --- |
| `transport_mode` absent (every Sentinel released before the staged rollout) | `protocolVersion: 1` | Native broker, unchanged |
| `transport_mode: "uds"` | `protocolVersion: 1` | Native broker |
| `transport_mode: "full_uds"` | `protocolVersion: 1` | Native broker |
| `transport_mode: "legacy"` | `unsupported_message` | `getServiceExports` plus direct loopback HTTP and WebSocket |
| an unrecognised `transport_mode` value | `protocolVersion: 1` | Native broker |
| the `getComponentExports` lookup failed (Sentinel not running, socket missing) | `protocolVersion: 1` | Native broker, which then fails on its own terms |
| nobody is signed in (no Auth0 subject ⇒ no account-scoped socket path ⇒ `socketNotFound`, thrown before any IPC) | `protocolVersion: 1` | Native broker; the extension's 30 s capability TTL re-probes and converges once auth lands |
| the lookup outran its browser-local 500 ms budget (hung-but-connectable Sentinel) | `protocolVersion: 1` | Native broker, which then fails on its own terms |

An older browser, which never reads `transport_mode`, keeps answering
`protocolVersion: 1` against a `legacy` Sentinel; that stays correct because a
`legacy` Sentinel still runs the broker and every managed service still listens
on both its socket and loopback. Browser and Sentinel therefore ship
independently in either order.

## Native in-app broker clients

Extensions are not the only broker clients. Every in-app Swift caller of
phi-agent — the Phi Link settings page (`IMChannelAPIClient`) and `APIClient`'s
agent-persona avatar and agent-space presence/handoff calls — goes through
`PhiAgentTransport`, which sends over the same account-scoped broker socket the
extension bridge uses. No in-app code resolves a phi-agent loopback URL
directly.

- `PhiAgentEndpointResolver` maps Sentinel's `transport_mode` to a route with
  the same table semantics as the capability handshake above: `legacy` selects
  direct loopback HTTP against `phi-agent.api_base`; `uds`, `full_uds`, an
  absent field, an unrecognised value, and a failed lookup all select the
  account-scoped broker socket. With no signed-in account there is no socket to
  scope, and the request fails as "session expired" rather than falling back to
  loopback.
- Peer authentication, the negotiated broker limits, and the 30-second I/O
  budget documented above apply unchanged; in-app callers use the
  `ServiceBrokerClient` defaults (16 MiB non-streaming cap, 30-second budget,
  production peer authenticator).
- There is no `/broker/version` negotiation for in-app callers. These are small
  JSON exchanges well inside the default cap, the broker enforces its own limits
  regardless, and broker-level failures such as `E_BROKER_SERVICE_UNAVAILABLE`
  arrive as HTTP 5xx JSON bodies that the settings page already reports as a
  service issue. A handshake round trip would buy nothing and add a failure mode.
- A transport-level failure (connection closed, timeout, peer authentication,
  malformed response; the loopback equivalents for the `legacy` route)
  invalidates the resolver cache and re-resolves the route exactly once. The
  request is retried only if the route actually changed, so a request is never
  attempted more than twice. Every other error — a broker size or validation
  failure, a decoding failure — reaches the caller unchanged.

## Request and channel lifecycle

Ordinary readiness and bounded HTTP calls use `broker.http.request`. Streaming HTTP and WebSocket calls use sender-owned opaque channels with one outstanding long-pull at a time. A pull waits for data, a terminal event, an error, or a bounded timeout; timeout keeps the channel alive and permits the next pull.

Every generic request captures one nonempty immutable shared-auth snapshot before runtime resolution. The runtime account must match that snapshot, and channel ownership includes the exact extension ID, account ID, and opaque auth revision. After every asynchronous transport or channel operation, the protocol revalidates the complete snapshot before returning the request-scoped reply. Logout, account change, or same-account token rotation therefore rejects an in-flight result; a channel created by an older revision cannot be reused by the newer revision. The current Chromium sender API does not expose a distinct browser profile identity, so the owner profile field remains unset until that identity is carried across the bridge.

End, close, failure, explicit cancel/close, idle expiry, UDS loss, and browser shutdown are terminal. Once the terminal event has been delivered, the channel is removed. Later pull, send, cancel, or close requests return `channel_not_found`; they cannot resurrect the channel.

Terminal HTTP and WebSocket events are not ordinary queued data: EOF, close,
and failure remain enqueueable when the 128-event data window is full. This
preserves the actual terminal reason instead of replacing it with a synthetic
flow-control timeout.

The exact stable extension error set is `unauthorized_sender`, `unsupported_message`, `invalid_payload`, `invalid_path`, `unsupported_method`, `invalid_base64`, `request_too_large`, `response_too_large`, `channel_not_found`, `owner_mismatch`, `pull_already_pending`, `flow_control_timeout`, `upstream_error`, and `protocol_error`. These codes are protocol failures, including transport failures normalized as `upstream_error` and malformed upstream/protocol state normalized as `protocol_error`. HTTP statuses such as `401` remain successful broker envelopes so Sidecar can perform its normal token refresh. Only the capability handshake may select legacy discovery. After protocol support is confirmed, a bridge or business error is terminal for transport selection and must never fall back to loopback TCP.

## Development and packet capture

Standalone, build-time, and explicit test/debug overrides may use direct networking. An explicitly empty WebSocket base is also a debug seam: it creates a relative URL, which is not guaranteed to connect from a `chrome-extension://` origin. Packaged production always uses the native logical WebSocket channel.

Packet-capture verification must identify the Stable and Canary phi-agent ports separately. Traffic on Stable does not prove Canary Sidecar used the broker, and a Canary capture must show no Sidecar connection to Canary's loopback phi-agent port.

## Native image previews

The Sidecar may send a normalized relative phi-agent file address, under `/api/v1/files/` or `/v1/files/`, to the existing native image-preview message. This address is privileged only when the message sender exactly matches the pinned Canary Sidecar ID.

For an authorized file address, `ImagePreviewLoader` asks `ServiceBrokerExtensionProtocol` to fetch the bytes from phi-agent through the negotiated service-broker UDS. The loader passes an opaque authenticated scope containing the account identity and auth revision. The protocol requires the current immutable shared-auth snapshot to match that exact scope, derives the socket/runtime from that snapshot's account, supplies that snapshot's access token as a Bearer credential, and pins `X-Phi-Extension-ID` to the authorized sender. Path validation and the negotiated non-streaming response-size limit are applied before image decoding.

Every browser shared-token upsert persists a fresh opaque revision in the same Keychain payload as `auth0Sub` and the access token. Legacy payloads written without a revision receive a process-local opaque revision that remains stable only while the exact raw payload is unchanged. This preserves mixed-version compatibility without using the wall-clock `updatedAt` value as a security generation.

Privileged preview cache and preload keys include the current nonempty account identity and opaque auth revision. Cache hits are revalidated immediately before return. Runtime negotiation and broker requests use the expected account rather than independently resolving a later current account, and the protocol revalidates the full authenticated snapshot after each awaited boundary. The loader validates the scope again after loading and decoding, before bytes may be cached or returned. Logout, account changes, same-account token rotation, and A-to-B-to-A transitions therefore fail closed; bearer tokens and legacy raw-payload digests are never included in cache keys or logs. Non-privileged preview cache keys and auth-read behavior are unchanged.

Other image-preview sources preserve their existing behavior: `http` and `https` use the image preview's URL session, `data:` is decoded inline, and local/file addresses read from disk. Unauthorized senders do not gain broker file access; a matching-looking relative path retains the prior local-file interpretation and fails normally if it does not exist.

Image bytes are never base64-encoded through the extension bridge. Blob object URLs remain renderer-local and therefore are not sent to the native preview.
