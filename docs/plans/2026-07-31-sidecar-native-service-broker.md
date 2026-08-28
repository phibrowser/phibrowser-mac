# Sidecar Native Service Broker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every packaged Sidecar HTTP, streaming HTTP, and WebSocket request to phi-agent through Phi Browser's native bridge and the Sentinel service broker UDS, then produce an ID-compatible CRX.

**Architecture:** Sidecar uses request-scoped native messages for complete HTTP responses and opaque long-pull channels for streams and WebSockets. Phi Browser validates the Sidecar sender, owns all channel state, and speaks HTTP/1.1 or WebSocket over Sentinel's service broker UDS. Existing direct networking remains available only for standalone mode and explicit test/debug base URL overrides.

**Follow-on scope:** The same native protocol now serves the pinned Canary
Sidecar, Lexington, and Kensington IDs. The first path segment selects one of
`phi-agent`, `phi-memory`, `pi-agent`, or `ai-gateway`; Phi Browser strips that
segment and Sentinel remains authoritative for each extension's allowed
service, method, and upstream path prefixes.

**Tech Stack:** Swift 6, Foundation networking and streams, XCTest, TypeScript, Chrome extension APIs, WHATWG `Response`/`ReadableStream`, RxJS, pnpm, Vite, CRX3.

## Global Constraints

- Preserve the pinned Sidecar, Lexington, and Kensington extension IDs derived
  from their packaged keys.
- Do not modify or rebuild Phi Framework.
- Do not change phi-agent HTTP or WebSocket payload protocols.
- Do not send broker response data through `onAppMessage` broadcasts.
- Accept `broker.*` messages only from the exact pinned Canary first-party IDs.
- Extensions must not supply a socket path, host, port, or separate service
  field; the service is selected only by the validated path prefix.
- Route maintained service requests by path prefix through Sentinel;
  `/broker` remains broker-owned.
- Preserve static test/debug URL overrides and standalone direct networking.
- Enforce the negotiated broker limits after accounting for base64 and JSON overhead.
- Write all code, comments, tests, and documentation in English.

---

### Task 1: Implement the Native UDS HTTP Client

**Files:**
- Modify: `Sources/Networking/ServiceBroker/ServiceBrokerTypes.swift`
- Modify: `Sources/Networking/ServiceBroker/ServiceBrokerClient.swift`
- Create: `Sources/Networking/ServiceBroker/ServiceBrokerHTTPConnection.swift`
- Modify: `Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerClientTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `ServiceBrokerClient.request(_:) async throws -> BrokerHTTPResponse`
- Produces: `ServiceBrokerClient.openStream(_:) async throws -> BrokerHTTPStream`
- Produces: `BrokerHTTPStream.response: BrokerHTTPResponseHead`
- Produces: `BrokerHTTPStream.read(maxBytes:) async throws -> Data?`
- Produces: `BrokerHTTPStream.cancel()`
- Consumes: `ServiceBrokerSocketPath.dataSocketPath(storagePath:)`

- [ ] **Step 1: Write failing HTTP serialization and parsing tests**

Add tests using a temporary Unix listener. Assert that a request for
`/api/v1/chats?limit=20` is written to the broker as
`/phi-agent/api/v1/chats?limit=20`, preserves method and headers, and parses
status, headers, fixed-length bodies, chunked bodies, and EOF-delimited bodies.

```swift
func testRequestRoutesPhiAgentPathOverUnixSocket() async throws {
    let server = UnixHTTPTestServer(response:
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
    let client = ServiceBrokerClient(socketPath: server.socketPath)
    let response = try await client.request(BrokerHTTPRequest(
        service: .phiAgent,
        path: "/api/v1/chats?limit=20",
        headers: ["Authorization": "Bearer token"]
    ))
    XCTAssertEqual(server.requestTarget, "/phi-agent/api/v1/chats?limit=20")
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.body, Data(#"{"ok":true}"#.utf8))
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme Phi-Canary \
  -destination 'platform=macOS' \
  -only-testing:PhiBrowserTests/ServiceBrokerClientTests
```

Expected: compilation fails because the injectable initializer and request
implementation do not exist.

- [ ] **Step 3: Implement HTTP/1.1 over UDS**

Implement a focused connection type that:

```swift
final class ServiceBrokerHTTPConnection: @unchecked Sendable {
    init(socketPath: String)
    func execute(_ request: BrokerHTTPRequest) async throws -> BrokerHTTPStream
    func close()
}
```

Use `AF_UNIX` and nonblocking reads, serialize origin-form HTTP/1.1 requests,
strip hop-by-hop headers, prepend `/<service.rawValue>` to the normalized path,
and parse one response per connection. Reject control characters, absolute
URLs, dot segments, `/broker`, invalid content lengths, conflicting framing,
and bodies beyond negotiated limits.

Make `request(_:)` consume `BrokerHTTPStream` to EOF while enforcing
`nonStreamingResponseBytes`.

- [ ] **Step 4: Run the focused native tests**

Run the Task 1 command again.

Expected: all `ServiceBrokerClientTests` pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/Networking/ServiceBroker Tests/PhiBrowserTests/ServiceBroker \
  Phi.xcodeproj/project.pbxproj
git commit -m "Implement native service broker HTTP client"
```

---

### Task 2: Add Native Stream and WebSocket Channel Management

**Files:**
- Create: `Sources/Networking/ServiceBroker/ServiceBrokerChannelStore.swift`
- Create: `Sources/Networking/ServiceBroker/ServiceBrokerWebSocket.swift`
- Modify: `Sources/Networking/ServiceBroker/ServiceBrokerTypes.swift`
- Create: `Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerChannelStoreTests.swift`
- Create: `Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerWebSocketTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `actor ServiceBrokerChannelStore`
- Produces: `openHTTPStream(owner:request:) async throws -> BrokerStreamOpenResponse`
- Produces: `pullHTTP(owner:channelID:) async throws -> BrokerStreamPullResponse`
- Produces: `openWebSocket(owner:path:headers:) async throws -> BrokerWebSocketOpenResponse`
- Produces: `sendWebSocket(owner:channelID:frame:) async throws`
- Produces: `pullWebSocket(owner:channelID:) async throws -> BrokerWebSocketPullResponse`
- Produces: `close(owner:channelID:code:reason:) async`

- [ ] **Step 1: Write failing channel lifecycle tests**

Cover:

```swift
func testChannelIsBoundToCreatingSender()
func testOnlyOnePullMayWaitPerChannel()
func testPullWaitsUntilChunkOrTimeout()
func testHTTPChunksHaveMonotonicSequenceNumbers()
func testCancelUnblocksPendingPullAndClosesUpstream()
func testIdleExpiryRemovesChannel()
func testBackpressureLimitClosesChannel()
func testWebSocketTextBinaryAndCloseFramesRoundTrip()
```

Use fake stream and WebSocket connections; tests must not depend on a running
Sentinel.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
xcodebuild test -project Phi.xcodeproj -scheme Phi-Canary \
  -destination 'platform=macOS' \
  -only-testing:PhiBrowserTests/ServiceBrokerChannelStoreTests \
  -only-testing:PhiBrowserTests/ServiceBrokerWebSocketTests
```

Expected: compilation fails because the channel store and WebSocket types do
not exist.

- [ ] **Step 3: Implement bounded logical channels**

Define response DTOs with explicit event variants:

```swift
enum BrokerPullEvent: Sendable {
    case data(sequence: UInt64, data: Data)
    case end
    case timeout
    case failure(code: NativeBrokerErrorCode, message: String)
}

struct BrokerWebSocketFrame: Sendable {
    enum Kind: String, Codable, Sendable { case text, binary }
    let kind: Kind
    let data: Data
}
```

Keep channel IDs random and owner-bound. Maintain one pending continuation per
channel, a bounded queue, sequence counters, terminal state, last activity,
and idempotent cleanup. A timeout returns `.timeout` without closing the
channel.

- [ ] **Step 4: Implement WebSocket over the broker UDS**

Perform the RFC 6455 upgrade against
`/phi-agent/ws/phi-agent/execute`, validate `101`, `Upgrade`,
`Connection`, and `Sec-WebSocket-Accept`, then encode masked client frames and
decode server frames. Handle continuation, ping/pong, text, binary, and close.
Reject oversized or malformed frames with `protocol_error`.

- [ ] **Step 5: Run focused tests**

Run the Task 2 command.

Expected: all channel and WebSocket tests pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/Networking/ServiceBroker Tests/PhiBrowserTests/ServiceBroker \
  Phi.xcodeproj/project.pbxproj
git commit -m "Add native broker stream and WebSocket channels"
```

---

### Task 3: Expose an Authorized Extension Broker Protocol

**Files:**
- Create: `Sources/Networking/ServiceBroker/ServiceBrokerExtensionProtocol.swift`
- Modify: `Sources/Notifications/MessageCard/ExtensionMessageRouter.swift`
- Modify: `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`
- Create: `Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerExtensionProtocolTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`
- Modify: `../phi-ai/ai-extension/types/phi-chromium/index.d.ts`

**Interfaces:**
- Consumes: `ServiceBrokerChannelStore`
- Produces native message types:
  `broker.http.request`, `broker.stream.open`, `broker.stream.pull`,
  `broker.stream.cancel`, `broker.ws.open`, `broker.ws.send`,
  `broker.ws.pull`, and `broker.ws.close`
- Produces TypeScript request/response declarations for every message type

- [ ] **Step 1: Determine and pin the Canary first-party broker extension IDs**

Run:

```bash
cd ../phi-ai/ai-extension/sidecar
pnpm exec crx3 id key.pem
```

Record the Sidecar, Lexington, and Kensington IDs as compile-time constants in
`ServiceBrokerExtensionProtocol` and assert them in a test. Only these pinned
first-party IDs may use the broker message types. Keep Sidecar-specific native
features, including staged file and image preview reads, guarded by the Sidecar
ID alone. Do not derive any allowed ID from an untrusted runtime payload.

- [ ] **Step 2: Write failing authorization and codec tests**

Cover exact sender acceptance, rejection of `cdp`, `debug-extension`, empty
sender, and other extension IDs. Cover invalid paths, unsupported methods,
bad base64, oversized bodies, unknown channels, cross-owner channel access,
and each stable error code.

```swift
func testRejectsNonSidecarSender() async {
    let result = await protocolHandler.handle(
        type: "broker.http.request",
        payload: validRequest,
        senderID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    XCTAssertEqual(result.error?.code, "unauthorized_sender")
}
```

- [ ] **Step 3: Run the focused protocol tests and verify failure**

```bash
xcodebuild test -project Phi.xcodeproj -scheme Phi-Canary \
  -destination 'platform=macOS' \
  -only-testing:PhiBrowserTests/ServiceBrokerExtensionProtocolTests
```

Expected: compilation fails because the protocol handler does not exist.

- [ ] **Step 4: Implement JSON codecs and router registration**

Keep `ExtensionMessageRouter` limited to registration and asynchronous reply:

```swift
for type in ServiceBrokerExtensionProtocol.messageTypes {
    register(type: type) { context in
        Task {
            let reply = await ServiceBrokerExtensionProtocol.shared.handle(context)
            await ExtensionMessaging.shared.sendResponse(
                reply, requestId: context.requestId)
        }
        return nil
    }
}
```

Encode every success and failure as a JSON envelope. HTTP status responses,
including `401`, remain successful bridge envelopes. Never call
`ExtensionMessaging.broadcast` for broker traffic.

- [ ] **Step 5: Add exact TypeScript declarations**

Declare discriminated request and response types plus overload-safe helpers for
the eight `broker.*` operations. Base64 fields are strings; sequences are
numbers within JavaScript's safe integer range; channel IDs are opaque strings.

- [ ] **Step 6: Run native tests and phi-ai type-check**

```bash
xcodebuild test -project Phi.xcodeproj -scheme Phi-Canary \
  -destination 'platform=macOS' \
  -only-testing:PhiBrowserTests/ServiceBrokerExtensionProtocolTests
cd ../phi-ai
pnpm type-check
```

Expected: both commands pass.

- [ ] **Step 7: Commit Task 3 in each repository**

```bash
git add Sources/Networking/ServiceBroker \
  Sources/Notifications/MessageCard/ExtensionMessageRouter.swift \
  Sources/ChromiumBridge/PhiChromiumBridgeHeader.h \
  Tests/PhiBrowserTests/ServiceBroker Phi.xcodeproj/project.pbxproj
git commit -m "Expose authorized native broker extension protocol"

cd ../phi-ai
git add ai-extension/types/phi-chromium/index.d.ts
git commit -m "Declare native service broker bridge messages"
```

---

### Task 4: Route Sidecar HTTP and Streaming Responses Through Native

**Files:**
- Create: `../phi-ai/ai-extension/sidecar/src/lib/native-broker.ts`
- Create: `../phi-ai/ai-extension/sidecar/src/lib/native-broker.test.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/lib/auth-fetch.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/lib/auth-fetch.test.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/services/api.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/hooks/use-api-client.ts`
- Modify: `../phi-ai/ai-extension/api-base/src/phi-agent.ts`

**Interfaces:**
- Produces: `nativeBrokerFetch(path: string, init?: RequestInit): Promise<Response>`
- Produces: `shouldUseNativePhiAgentTransport(options): boolean`
- Consumes: Task 3 `broker.http.*` and `broker.stream.*` messages

- [ ] **Step 1: Write failing fetch adapter tests**

Test method, relative path and query, repeated response headers, text and binary
bodies, request bodies, abort before open, abort during pull, stream ordering,
pull timeout retry, bridge errors, HTTP `401`, and non-native fallback.

```typescript
test("reconstructs a streaming Response in sequence order", async () => {
  native.reply("broker.stream.open", {
    channelId: "stream-1",
    status: 200,
    headers: [["content-type", "text/event-stream"]],
  });
  native.replySequence("broker.stream.pull", [
    { events: [{ type: "data", sequence: 0, data: b64("one") }] },
    { events: [{ type: "data", sequence: 1, data: b64("two") }, { type: "end" }] },
  ]);
  const response = await nativeBrokerFetch("/api/proactive-greeting", {});
  assert.equal(await response.text(), "onetwo");
});
```

- [ ] **Step 2: Run tests and verify failure**

```bash
cd ../phi-ai
pnpm --filter @phi-ai/sidecar test -- native-broker.test.ts auth-fetch.test.ts
```

Expected: test compilation fails because `nativeBrokerFetch` does not exist.

- [ ] **Step 3: Implement the native fetch adapter**

Use `broker.http.request` for non-streaming requests and
`broker.stream.open/pull/cancel` when the caller requests streaming. Rebuild a
standards-compatible `Response`, expose body chunks through
`ReadableStream<Uint8Array>`, enforce sequence continuity, and map
`AbortSignal` to stream cancellation.

Do not patch `globalThis.fetch`.

- [ ] **Step 4: Integrate authentication and APIClient**

Change `fetchWithAuthRetry` to accept an injectable fetch implementation:

```typescript
export type FetchLike = (
  input: string,
  init?: RequestInit,
) => Promise<Response>;

export async function fetchWithAuthRetry(
  url: string,
  init: RequestInit,
  token: string,
  refreshToken?: () => Promise<string>,
  fetchImpl: FetchLike = fetch,
): Promise<{ response: Response; token: string }>;
```

In packaged Phi Browser, `APIClient.authFetch` passes `nativeBrokerFetch` a
relative phi-agent path. Static base URL overrides and standalone mode continue
to pass browser `fetch`. Stop resolving `phi-agent.api_base` on the production
APIClient path.

- [ ] **Step 5: Migrate explicit phi-agent streaming call sites**

Route proactive greeting and any phi-agent file/blob fetches through the same
adapter. Leave `data:`, extension asset, internet, and AI Gateway fetches
unchanged. Add call-site tests proving the selected transport.

- [ ] **Step 6: Run Sidecar tests, type-check, lint, and build**

```bash
cd ../phi-ai
pnpm --filter @phi-ai/sidecar test
pnpm type-check
pnpm exec eslint --no-warn-ignored \
  ai-extension/sidecar/src/lib/native-broker.ts \
  ai-extension/sidecar/src/lib/native-broker.test.ts \
  ai-extension/sidecar/src/lib/auth-fetch.ts \
  ai-extension/sidecar/src/services/api.ts \
  ai-extension/sidecar/src/hooks/use-api-client.ts
pnpm --filter @phi-ai/sidecar build
```

Expected: all commands pass and the build emits a CRX with the existing ID.

- [ ] **Step 7: Commit Task 4**

```bash
git add ai-extension/sidecar ai-extension/api-base
git commit -m "Route Sidecar phi-agent HTTP through native broker"
```

---

### Task 5: Route Sidecar WebSocket Through Native

**Files:**
- Create: `../phi-ai/ai-extension/sidecar/src/lib/native-broker-websocket.ts`
- Create: `../phi-ai/ai-extension/sidecar/src/lib/native-broker-websocket.test.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/lib/ws-agent.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/lib/ws-agent.test.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/features/onboarding/use-onboarding-ws-chat.ts`

**Interfaces:**
- Produces: `class NativeBrokerWebSocket implements WebSocketLike`
- Produces: `createPhiAgentWebSocketFactory(options): WebSocketFactory`
- Consumes: Task 3 `broker.ws.*` messages

- [ ] **Step 1: Write failing browser-compatible WebSocket tests**

Cover open, queued send before open, text and binary messages, ordered pull
batches, pull timeout retry, close code/reason, bridge failure, explicit close,
and no pulls after terminal close.

```typescript
test("delivers native frames as WebSocket message events", async () => {
  const socket = new NativeBrokerWebSocket("/ws/phi-agent/execute", native);
  await opened(socket);
  native.reply("broker.ws.pull", {
    events: [{ type: "text", sequence: 0, data: b64('{"type":"event"}') }],
  });
  assert.equal((await nextMessage(socket)).data, '{"type":"event"}');
});
```

- [ ] **Step 2: Run the focused tests and verify failure**

```bash
cd ../phi-ai
pnpm --filter @phi-ai/sidecar test -- \
  native-broker-websocket.test.ts ws-agent.test.ts
```

Expected: compilation fails because `NativeBrokerWebSocket` does not exist.

- [ ] **Step 3: Implement the native WebSocket adapter**

Map `broker.ws.open/send/pull/close` to the existing `WebSocketLike` contract.
Use a single pull loop, preserve pre-open send buffering, decode text with
fatal UTF-8 validation, surface binary as `ArrayBuffer`, and make close
idempotent.

- [ ] **Step 4: Select native WebSocket in packaged Sidecar**

`WsAgent` continues to use its injected `WebSocketFactory`. Production
construction supplies `createPhiAgentWebSocketFactory`; explicit test/debug
base URLs and standalone mode use the global browser `WebSocket`.

The production factory passes only
`/ws/phi-agent/execute` and authorization headers through the bridge. It does
not construct a loopback `ws://host:port` URL.

- [ ] **Step 5: Migrate onboarding WebSocket**

Use the same factory for onboarding rather than constructing a direct
`WebSocket`. Preserve its current protocol and reconnect behavior.

- [ ] **Step 6: Run Sidecar verification**

```bash
cd ../phi-ai
pnpm --filter @phi-ai/sidecar test
pnpm type-check
pnpm exec eslint --no-warn-ignored \
  ai-extension/sidecar/src/lib/native-broker-websocket.ts \
  ai-extension/sidecar/src/lib/native-broker-websocket.test.ts \
  ai-extension/sidecar/src/lib/ws-agent.ts \
  ai-extension/sidecar/src/lib/ws-agent.test.ts \
  ai-extension/sidecar/src/features/onboarding/use-onboarding-ws-chat.ts
pnpm --filter @phi-ai/sidecar build
```

Expected: all commands pass.

- [ ] **Step 7: Commit Task 5**

```bash
git add ai-extension/sidecar
git commit -m "Route Sidecar WebSocket through native broker"
```

---

### Task 6: Remove Production phi-agent Export Discovery and Document the Boundary

**Files:**
- Modify: `../phi-ai/ai-extension/api-base/src/resolve-exports.ts`
- Modify: `../phi-ai/ai-extension/api-base/src/phi-agent.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/hooks/use-ai-infrastructure.ts`
- Modify: `../phi-ai/ai-extension/sidecar/src/hooks/use-private-ai-chat-status.ts`
- Modify: `../phi-ai/docs/sidecar-native-service-broker.md`
- Create: `docs/networking/service-broker.md`

**Interfaces:**
- Produces: production readiness probe through `broker.http.request`
- Preserves: non-phi-agent `getServiceExports` consumers

- [ ] **Step 1: Write failing discovery and readiness tests**

Assert packaged Sidecar readiness calls `/broker/healthz` or a permitted
phi-agent health path through native transport, never reads
`exports["phi-agent"].api_base`, and never falls back to loopback after
authorization, validation, or size failures.

- [ ] **Step 2: Run tests and verify failure**

```bash
cd ../phi-ai
pnpm --filter @phi-ai/sidecar test
pnpm --filter @phi-ai/api-base type-check
```

Expected: the new production-discovery assertions fail.

- [ ] **Step 3: Remove production phi-agent base URL discovery**

Keep `loadServiceExports` intact for other services. Move phi-agent transport
selection to native capability detection. Preserve build-time fallback only
for standalone mode and explicit debug/test overrides.

- [ ] **Step 4: Update architecture documentation**

Document:

- Sidecar → native bridge → broker UDS → phi-agent.
- Exact authorized extension ID and why responses use request-scoped pull.
- `/broker` reservation.
- Channel lifecycle and stable errors.
- Direct loopback is development-only and must never be an authorization
  fallback.
- Stable and Canary ports must be distinguished during packet-capture checks.

- [ ] **Step 5: Run repository verification and formatting**

```bash
cd ../phi-ai
pnpm type-check
pnpm --filter @phi-ai/sidecar test
pnpm --filter @phi-ai/sidecar build
pnpm format:changed

cd ../phibrowser-mac
xcodebuild test -project Phi.xcodeproj -scheme Phi-Canary \
  -destination 'platform=macOS' \
  -only-testing:PhiBrowserTests/ServiceBrokerClientTests \
  -only-testing:PhiBrowserTests/ServiceBrokerChannelStoreTests \
  -only-testing:PhiBrowserTests/ServiceBrokerWebSocketTests \
  -only-testing:PhiBrowserTests/ServiceBrokerExtensionProtocolTests
```

Expected: all commands pass.

- [ ] **Step 6: Commit Task 6 in each repository**

```bash
cd ../phi-ai
git add ai-extension/api-base ai-extension/sidecar \
  docs/sidecar-native-service-broker.md
git commit -m "Remove Sidecar production loopback discovery"

cd ../phibrowser-mac
git add docs/networking/service-broker.md
git commit -m "Document native service broker extension boundary"
```

---

### Task 7: Build, Install, and Verify the Canary Artifacts

**Files:**
- Output: `../phi-ai/ai-extension/sidecar/crx/sidebar-<version>.crx`
- Output: local Phi Canary application produced by the existing adhoc build
  workflow

**Interfaces:**
- Consumes: all prior tasks
- Produces: ID-compatible Sidecar CRX and locally installed Phi Canary

- [ ] **Step 1: Verify both worktrees contain only intentional changes**

```bash
git -C ../phi-ai status --short
git -C ../phibrowser-mac status --short
git -C ../sentinel status --short
```

Expected: no uncommitted task changes; existing framework artifacts remain
clearly separated from source commits.

- [ ] **Step 2: Build the Sidecar CRX**

```bash
cd ../phi-ai
pnpm --filter @phi-ai/sidecar build
pnpm exec crx3 id ai-extension/sidecar/key.pem
ls -lh ai-extension/sidecar/crx/sidebar-*.crx
```

Expected: one current CRX exists and its ID equals the pinned Canary Sidecar
extension ID.

- [ ] **Step 3: Build and replace Phi Canary**

Read
`/Users/fydeos/workspace/phinomenon/phibrowser-mac-builder/build-scripts/adhoc-build.sh`
and reproduce its archive inputs locally without running its upload steps:
use the `Release-Canary` configuration, the installed signing identity, the
current local Phi Framework, and the current phibrowser-mac worktree as the
source checkout. Copy the signed product over the local Phi Canary application
only after `codesign --verify --deep --strict` succeeds.

Expected: codesign verification succeeds for the app and nested framework, and
the launched app reports the local build version.

- [ ] **Step 4: Install the generated Sidecar CRX**

Replace the Canary Sidecar with the CRX from Step 2. Confirm the extension ID
did not change and reload the extension once.

- [ ] **Step 5: Verify HTTP, streaming, and WebSocket behavior**

Exercise:

- Conversation list and message history.
- File/image response retrieval.
- Proactive greeting stream.
- AI Chat over `/ws/phi-agent/execute`.
- Cancel and reconnect.

Expected: UI behavior matches the pre-migration behavior.

- [ ] **Step 6: Verify transport isolation**

Capture the actual Canary phi-agent loopback port from Canary exports only for
diagnostics, then observe both that port and the broker socket while exercising
Step 5.

Expected:

- No Sidecar TCP connection reaches the Canary phi-agent port.
- Stable-channel traffic is excluded from the conclusion.
- Sentinel and phi-agent logs show the same requests through the service broker.
- The broker socket is active for HTTP, stream, and WebSocket cases.

- [ ] **Step 7: Archive durable project knowledge**

Update the company knowledge base with the verified invariant:

```text
Packaged Sidecar phi-agent traffic is native-bridge-only. HTTP streams and
WebSockets use sender-bound logical long-pull channels; broadcast extension
messages never carry broker response data.
```

Include source and successful integration verification as evidence, mark the
entry `draft`, add it to `catalog.md`, then commit and push the knowledge-base
change as required by the coding-agent knowledge loop.
