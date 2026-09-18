# M4 sync invalidation

Status: implementation in an isolated branch, authorized by the owner on 2026-09-16.

## Scope and bases

- Mac: `feature/phi-sync-m4-invalidation`, based on `feature/phi-sync` at `c549c4c5`.
- Service: `feature/m4-invalidation`, based on `main` at `cfb190b`.
- Chromium: `feature/phi-r150-m4-invalidation`, based on `feature/phi-r150-sync` at `4c45286aae41c`.
- Preserve staged delivery: M4a (server + Swift) works with the existing framework; M4b Chromium changes stay in their independent worktree until its framework build and acceptance are scheduled. The optional bridge makes the stages independently shippable.
- M3-4 entity/schema/marker changes remain in the other branch. M4 schedules existing pull operations; it never changes markers, merges, keys, or entity payloads.

## Transport contract

One account-scoped native connection uses `GET /sync/invalidations?client_id=<device-key-id>` with the existing Auth0 bearer header. The server derives the account exclusively from verified JWT claims. Tokens never enter URLs or logs. The existing backend client's transport owns this connection.

The response is `text/event-stream`, with `Cache-Control: no-cache, no-transform` and `X-Accel-Buffering: no`. Complete events are:

```text
event: ready
data: {}

event: invalidate
data: {"namespace":"chromium:phi","data_types":[2000],"source_client_id":"device-or-cache-guid"}

```

`ready` requests catch-up for both engines. `invalidate` carries routing metadata only, never content, entity identifiers, ciphertext, or keys. Namespace `chromium:phi` routes type 2000 to PhiSyncEngine; other `chromium:<profile-uuid>` namespaces route to the matching Chromium engine. Unknown event types/unsupported data types are ignored. Malformed or oversized frames close the stream and preserve fallback polling. No durable SSE event IDs or replay log: existing GetUpdates markers are the recovery mechanism.

The server excludes the stream's non-empty `client_id` for matching commit producers. Chromium producers use per-profile cache GUIDs, unlike Phi's device key ID, so the C++ receiving engine additionally excludes its own cache GUID. Empty or overlong exclusion identifiers must never suppress unrelated clients.

## Server

Applied commits issue bounded PostgreSQL notifications, grouped by account, namespace, and changed types; conflicts/invalid entries do not notify. SQL remains in `internal/data`. The existing entity transaction and type-version lock order remain intact. A dedicated LISTEN connection feeds a bounded in-process fanout hub; all replicas listen, including the submitting replica. LISTEN is established before the hub accepts subscriptions. After listener loss, disconnect existing streams; reconnect with bounded backoff and require fresh catch-up. No schema migration or durable message queue is needed.

Streams use a 15-second heartbeat and a bounded write deadline per frame (10 seconds), overriding the server's ordinary 30-second write deadline only for this route. Slow subscribers are disconnected, not buffered without bound. JWT expiry ends a stream; maximum stream lifetime is five minutes, followed by ordinary authenticated reconnection. Shutdown cancels listeners and streams. Bound per-account/total subscriptions, and return retryable errors when the listener is unavailable or admission is full.

## Mac lifecycle and recovery

The coordinator owns a single invalidation task with the same account/key-engine lifetime as Phi sync. It starts only when sync is ready and is cancelled before sign-out/account switch/self-revoke teardown. Every callback checks an account/generation fence. Authentication changes cancel and reopen the transport using AuthManager's current token. Reject redirects so credentials cannot move to another origin. Wake/foreground requests catch-up and reconnects as needed.

Retry failures with exponential backoff and jitter capped at 60 seconds. Require `ready` before considering the connection healthy. A heartbeat watchdog detects silent stalls. Use bounded frame parsing, including CRLF and fragmented input. A 250-ms coalescing window unions changed types per namespace; differing producer IDs clear the exclusion optimization. Catch-up supersedes individual pending hints. At most one async pull runs per scheduler with one follow-up demand, avoiding an unbounded engine round queue.

Fallback polling runs every 60 seconds while the transport is unhealthy and every 300 seconds while healthy. The same fallback also nudges eligible Chromium engines. Local writes retain their existing scheduling. Fallbacks work with older servers returning 404 and older frameworks lacking the optional bridge selector.

## Chromium bridge

Add the optional selector to BOTH manual bridge header copies:

```objc
- (void)notifyPhiSyncInvalidationForAccount:(NSString*)accountId
                              profileUUID:(NSString*)profileUUID
                              dataTypeIds:(NSArray<NSNumber*>*)dataTypeIds
                        excludingClientId:(NSString*)excludingClientId;
```

An empty profile UUID and empty type list mean catch-up for all currently eligible profiles/types; other empty type lists are ignored. Extend the existing key-provider observation boundary to carry hints into SyncServiceImpl. The receiver verifies current Phi account, origin-gated Phi providers, ready key/namespace, initialized engine, and active supported data types. A matching own cache GUID suppresses only that hint. Refresh uses the existing `TriggerRefresh` scheduler, preserving auth/backoff gates. All new behavior is guarded by `IS_PHI_BROWSER`; upstream behavior remains unchanged. No new histogram enum values.

## Validation and deployment

- Service: unit/race tests for routing, source exclusion, backpressure, cancellation, expiry and write lifetime; actual PostgreSQL tests for successful commit, conflict, rollback, multiple listeners and reconnect; `go fmt`, `go vet`, `go build`, `make test`.
- Mac: hostless executable tests using the production parser/scheduler with injected transport, time, token and callbacks; account switch, cancellation, silent stall, errors, coalescing and fallback tests; compile application integration when available. Never launch app-hosted XCTest against the user's browser.
- Chromium: source-level unit tests for correct account/profile/type gates and source exclusion; compile affected units with existing toolchain where feasible. Full framework/two-device acceptance is explicitly distinct from unit checks.
- Deployment: add an isolated ingress overlay/patch with buffering disabled and read timeout longer than heartbeat. Preserve ordinary endpoint timeout policy. Do not deploy, merge, or change the running cluster as part of local implementation.
- Acceptance: settings and Chromium preferences change on one awake Mac and reach the other promptly; listener/server restart, expired JWT, sleep/wake and disabled SSE recover through current markers without data loss. Run behind real ingress before release.

## Risks and integration

The source branches are intentionally not merged. M3-4 may touch coordinator lifecycle and project-file registration; integration should retain its entity construction and apply M4's minimal scheduling seams. Server LISTEN/NOTIFY is a lossy hint transport: no correctness argument may depend on a notification arriving. M3-4 owns shared-marker durability (B-2). The installed Chromium framework predates this selector and must safely remain on polling until replaced.
