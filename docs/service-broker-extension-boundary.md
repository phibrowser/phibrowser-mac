# Service Broker Extension Boundary

Phi Browser exposes the Sentinel service broker to the packaged Canary Sidecar through a pinned native-extension boundary. The browser, rather than the extension, discovers the account-scoped Unix domain socket and negotiates broker limits.

```text
Sidecar request-scoped adapter
  -> chrome.phinomenonPrivate.sendMessageToApp
  -> Phi Browser service-broker extension protocol
  -> account-scoped Sentinel broker UDS
  -> phi-agent
```

Replies use the request-scoped `sendMessageToApp` return value because the existing native-to-extension event is broadcast to every extension context. Authenticated bodies, headers, credentials, stream chunks, and WebSocket frames must never cross that broadcast channel.

## Trust and transport invariants

- Only the exact Canary Sidecar extension ID `fenmfiepnpdlhplemgijlimpbebebljo` is authorized. Empty, debug, CDP, differently cased, and other extension senders are rejected before transport access.
- Extensions select only an allowed relative request path and method. They cannot supply a socket path, host, port, service name, or extension identity header.
- Phi Browser resolves the account-scoped broker socket from shared authentication state. The preferred `/tmp/phi-sentinel-<hash>/sockets` path is used only when each existing short-path component is a real directory owned by the current uid; otherwise both Sentinel and the browser select `<storage>/state/sockets`. There is no TCP host/port fallback.
- A successful UDS connect is not proof of broker identity. Before sending a request, credential, or WebSocket handshake byte, the browser requires the peer uid to match its effective uid and validates the `LOCAL_PEERPID` process against the signed `service-broker` code requirement for Team ID `87DQ3HMK5G`. Failure is terminal and never falls back to another transport.
- The browser enforces the broker's negotiated request, response, streaming, and WebSocket limits.
- Chromium keeps the legacy 1 MiB native-message JSON limit for non-broker traffic. `broker.*` envelopes admit exactly `ceil(16 MiB / 3) * 4 + 64 KiB` bytes so a negotiated 16 MiB raw request plus bounded base64/JSON overhead reaches the browser protocol; the Mac layer remains the semantic and decoded-size enforcement point.
- Each HTTP connect/write/response-head sequence and each WebSocket operation has one monotonic 30-second I/O budget. HTTP body reads receive the same per-read budget. Swift task cancellation closes the UDS descriptor so a stalled peer cannot leave a detached poll/read/write running indefinitely.
- `/broker` is reserved for broker-owned management routes. Only `broker.http.request` admits exact `GET /broker/healthz` with no body and maps it to broker service path `/healthz`. Query suffixes, encoded spellings, path variations, other methods, bodies, streaming attempts, `/broker/version`, and every other extension-supplied `/broker` path are rejected.

## Request and channel lifecycle

Ordinary readiness and bounded HTTP calls use `broker.http.request`. Streaming HTTP and WebSocket calls use sender-owned opaque channels with one outstanding long-pull at a time. A pull waits for data, a terminal event, an error, or a bounded timeout; timeout keeps the channel alive and permits the next pull.

Every generic request captures one nonempty immutable shared-auth snapshot before runtime resolution. The runtime account must match that snapshot, and channel ownership includes the exact extension ID, account ID, and opaque auth revision. After every asynchronous transport or channel operation, the protocol revalidates the complete snapshot before returning the request-scoped reply. Logout, account change, or same-account token rotation therefore rejects an in-flight result; a channel created by an older revision cannot be reused by the newer revision. The current Chromium sender API does not expose a distinct browser profile identity, so the owner profile field remains unset until that identity is carried across the bridge.

End, close, failure, explicit cancel/close, idle expiry, UDS loss, and browser shutdown are terminal. Once the terminal event has been delivered, the channel is removed. Later pull, send, cancel, or close requests return `channel_not_found`; they cannot resurrect the channel.

The exact stable extension error set is `unauthorized_sender`, `unsupported_message`, `invalid_payload`, `invalid_path`, `unsupported_method`, `invalid_base64`, `request_too_large`, `response_too_large`, `channel_not_found`, `owner_mismatch`, `pull_already_pending`, `flow_control_timeout`, `upstream_error`, and `protocol_error`. These codes are protocol failures, including transport failures normalized as `upstream_error` and malformed upstream/protocol state normalized as `protocol_error`. HTTP statuses such as `401` remain successful broker envelopes so Sidecar can perform its normal token refresh. A bridge error is terminal for transport selection and must never fall back to loopback TCP.

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
