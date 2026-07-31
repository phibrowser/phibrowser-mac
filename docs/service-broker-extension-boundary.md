# Service Broker Extension Boundary

Phi Browser exposes the Sentinel service broker to the packaged Canary Sidecar through a pinned native-extension boundary. The browser, rather than the extension, discovers the account-scoped Unix domain socket and negotiates broker limits.

## Trust and transport invariants

- Only the exact Canary Sidecar extension ID `fenmfiepnpdlhplemgijlimpbebebljo` is authorized. Empty, debug, CDP, differently cased, and other extension senders are rejected before transport access.
- Extensions select only an allowed relative request path and method. They cannot supply a socket path, host, port, service name, or extension identity header.
- Phi Browser resolves the account-scoped broker socket from shared authentication state. There is no TCP host/port fallback.
- The browser enforces the broker's negotiated request, response, streaming, and WebSocket limits.

## Native image previews

The Sidecar may send a normalized relative phi-agent file address, under `/api/v1/files/` or `/v1/files/`, to the existing native image-preview message. This address is privileged only when the message sender exactly matches the pinned Canary Sidecar ID.

For an authorized file address, `ImagePreviewLoader` asks `ServiceBrokerExtensionProtocol` to fetch the bytes from phi-agent through the negotiated service-broker UDS. The browser supplies the current shared access token as a Bearer credential and pins `X-Phi-Extension-ID` to the authorized sender. Path validation and the negotiated non-streaming response-size limit are applied before image decoding.

Other image-preview sources preserve their existing behavior: `http` and `https` use the image preview's URL session, `data:` is decoded inline, and local/file addresses read from disk. Unauthorized senders do not gain broker file access; a matching-looking relative path retains the prior local-file interpretation and fails normally if it does not exist.

Image bytes are never base64-encoded through the extension bridge. Blob object URLs remain renderer-local and therefore are not sent to the native preview.
