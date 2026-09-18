# M4 Invalidation Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for independently owned tasks, followed by whole-change review. Do not commit or merge product branches without the owner's instruction.

**Goal:** Deliver authenticated cross-replica sync hints to both Phi and Chromium engines with reliable polling fallback.

**Architecture:** The service publishes metadata-only notifications to a PostgreSQL LISTEN fanout hub. One account-scoped native SSE connection dispatches coalesced refresh requests through existing engine and bridge boundaries.

**Tech Stack:** Go/pgx/Echo, Swift/Foundation, Objective-C++/Chromium.

**Spec:** `docs/superpowers/specs/2026-09-16-m4-invalidation-design.md`

## Global Constraints

- Preserve entity payload, merge, marker, auth and encryption boundaries.
- Never log tokens/content; authenticated account exclusively determines fanout.
- No production/staging deployment; no edits to Claude's M3-4 worktree.
- Product code/docs are English. New Swift sources require explicit Xcode registration.
- Use hostless Swift tests; Chromium sparse worktree avoids duplicating its large build/dependency tree.
- No product commits until requested. Record verified work and limitations in this plan.

## Task 1: Service notifications and streaming endpoint

**Workspace:** `/Users/elmer/workspace/phinomenon/sync-service-wt-m4`

**Files:** `internal/data/entities_write.go`, new `internal/data/invalidations.go`, new `internal/invalidation/`, `internal/transport/router.go`, new `internal/transport/invalidation_handler.go`, `internal/auth/`, `cmd/server/main.go`, `internal/config/config.go`, companion tests, `docs/architecture.md`, `docs/deployment.md`.

**Interfaces:** Produce `GET /sync/invalidations?client_id=...`, `ready` and `invalidate` events exactly as defined in the spec. Keep existing router/tests compatible through optional injected dependencies. SQL stays in data; application composition stays in main.

- [x] Exercise a subscriber for account A and account B; an applied A commit only wakes A.
- [x] Exercise matching/nonmatching/empty source IDs, conflict-only batch, rollback, two LISTEN connections, disconnect and slow consumers.
- [x] Implement transaction notification and dedicated listener, bounded hub, authenticated SSE route with per-write timeout, expiry, heartbeat and shutdown handling.
- [x] Run `go fmt ./...`, `go vet ./...`, `go build ./...`, `make test`, and relevant race tests. Preserve full command outcomes.
- [x] Document protocol and operational settings alongside implementation.

## Task 2: Native streaming transport and scheduler

**Workspace:** `/Users/elmer/workspace/phinomenon/phibrowser-wt-m4`

**Files:** new `Sources/Sync/Phi/PhiSyncInvalidation.swift`, `Sources/Sync/Phi/PhiSyncProtocolClient.swift`, `Sources/ChromiumBridge/PhiChromiumCoordinator.swift`, `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`, `Phi.xcodeproj/project.pbxproj`, hostless tests under `Tests/SyncInvalidation/`.

**Interfaces:** Consume Task 1's SSE wire format. Route type 2000 to `PhiSyncEngine.pullOnce()` and profile metadata to Task 3's optional bridge selector; retain account/generation fences.

- [x] Test fragmented LF/CRLF frames, invalid metadata, payload bounds and heartbeat detection using production parser code.
- [x] Test authenticated requests, rejection of redirects, retry/cancel, ready catch-up, single-flight coalescing, healthy/unhealthy poll intervals and teardown against injected closures.
- [x] Extend the existing HTTP backend client with streaming transport and implement lifecycle scheduling independently from entity handling.
- [x] Wire start/stop/auth/foreground/wake and fallback refresh, then register sources in the project.
- [x] Run hostless tests and compile checks; document all unavailable integration checks precisely.

## Task 3: Chromium refresh bridge

**Workspace:** `/Users/elmer/workspace/phinomenon/chromium-wt-m4/src`

**Files:** `components/sync/service/phi_sync_key_provider.h`, `components/sync/service/sync_service_impl.{h,cc}`, `components/sync/service/sync_service_impl_unittest.cc`, `chrome/browser/phinomenon/phi_sync_key_provider_impl.{h,cc}`, `chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge{.mm,Header.h}`.

**Interfaces:** Produce the optional selector in the spec; extend existing provider observers with a default no-op hint callback to preserve fake/provider compatibility. Consume account/profile/type/source metadata only.

- [x] Add tests that reject wrong account/profile, locked keys, unknown/inactive types, own commits and non-Phi providers; verify catch-up and a matching event call the existing engine refresh.
- [x] Implement provider fanout, C++ gates and Objective-C++ adapter, preserving upstream branches.
- [x] Verify both bridge header declarations match and run available targeted compilation/tests with isolated outputs.
- [x] Record build limitations without treating source inspection as runtime validation.

## Task 4: Integration, deployment artifact and review

- [x] Review server/client wire agreement and callback lifetime after account switch.
- [x] Add reviewable ingress settings for staging with no live deployment.
- [x] Run a local end-to-end SSE/commit test with PostgreSQL and test clients when available.
- [x] Review entire changes independently; resolve correctness findings and rerun affected checks. (Final independent three-repository review approved.)
- [x] Update source documentation and company knowledge with branch bases, contract, verification evidence and integration steps for M3-4.

## Progress

- Worktrees created from the above pinned sync branches; all started clean.
- Ruling: continue from the existing SSE design direction authorized in the conversation; no additional approval cycle.
- Ruling: one service implementation agent may work while the primary agent implements native integration in a separate repository. Never run overlapping implementation agents.
- Preflight: Tasks 1/2 share only the SSE contract (event names/JSON fields match). Tasks 2/3 share only the explicit bridge selector (matching argument order). Task 4 consumes all outputs. All tasks preserve the spec's account and lifecycle boundaries.

## Verification and integration handoff

- Server: fmt/vet/build; full PostgreSQL-backed `make -o db-up test` using the already-running local test database; targeted data/hub/transport/auth race suites. HTTP Commit -> transaction NOTIFY -> two LISTEN consumers -> SSE routing is exercised. The startup prerequisite was skipped because its port was already occupied by the existing test database. No deployment was performed.
- Server review regression: retain a finite write deadline after the SSE handler returns, including HTTP/1's final chunk. A real server with a non-reading peer must still shut down. Lifetime and listener-loss cases pass, as does the original independent reproducer.
- Native: `bash build-scripts/test-sync-invalidation.sh` passes production parser, scheduler and real loopback HTTP tests, including older-server fallback, wake, receiver cancellation and cancellation during token acquisition. `xcodebuild build-for-testing` passes for application and hosted test compilation. Hosted tests were never executed. Existing unrelated compiler warnings remain; the new observer captures use the main-actor scheduler directly.
- Chromium: all four changed implementation/test translation units pass the actual Chromium compiler using an overlay of the new worktree and isolated outputs. Both affected service/test objects compile. The rebuilt isolated `base::TestSuite` + Mojo runner passes all 12 `PhiSyncServiceImplTest.*` tests (two new invalidation cases plus ten existing startup/key cases). This runner reuses existing generated dependencies but recompiles the changed production service and its tests; it is not a new browser/framework binary.

M4a and M4b remain independently deliverable. An older server returns404 and keeps the native 60-second fallback. An older framework lacks the optional selector and retains its own existing Chromium scheduling. Build and distribute a new Chromium framework only for M4b acceptance.

Integrating M3-4 later should retain its engine construction and entity registrations, and then reapply M4's scheduler construction/start/stop seams in `PhiChromiumCoordinator.swift`. Resolve the Xcode project by retaining both sets of new source registrations. Neither branch should replace the other's entity or marker logic. The SSE channel only asks existing engines to pull.

Release checks still required: deploy the isolated ingress route with buffering disabled and heartbeat-compatible timeouts; run a new-framework two-device check for settings and Chromium preferences; test sleep/wake, JWT rotation, SSE disabled and a server/listener restart behind that ingress. Full framework packaging, live ingress checks and two-device acceptance are outside this local implementation run.

### Chromium runtime evidence

The full `components_unittests` link and a ContentTestSuite-based subset were
stopped after excessive link cost. A small test launcher using `base::TestSuite`
and `mojo::core::Init()` linked the updated `sync_service_impl.o` and
`sync_service_impl_unittest.o` with the existing dependencies, without Blink/GL
initialization. The first temporary launcher lacked Mojo initialization and
failed before the cases could run; adding the normal embedder initialization
resolved that harness error.

Final run: `PhiSyncServiceImplTest.*`, one worker, retries disabled: **12/12 PASS**.
The Objective-C++ adapter and provider fanout also compile with the real Chromium
compiler. The original source checkout and its build outputs were read-only
throughout this validation. Final independent review approved the three-repository
change with no unresolved findings.

Knowledge writeback: draft contract and evidence under
`30-projects/phinomenon/sync-service/design/2026-09-16-m4-invalidation-implementation.md`
in the company knowledge base, linked from its project/product entrypoints and
catalog. Product work remains uncommitted and undeployed.
