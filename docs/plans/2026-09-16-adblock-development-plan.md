# Phi Ad Blocking Development Plan

Status: approved direction, pre-implementation
Date: 2026-09-16
Related requirements: `2026-09-16-adblock-requirements.md`

## Chosen approach

Use `adblock-rust` behind a Phi-owned `cxx` facade. Add a Profile-owned browser
service, a Chromium URLLoaderFactory proxy for network decisions, and a renderer
observer for cosmetic filtering. Swift handles the three Content Blocking
settings and display only.

```text
Swift settings -> existing Phi bridge -> Profile adblock service
                                      -> URLLoaderFactory proxy
                                      -> Phi Rust facade -> adblock-rust
                                      -> renderer cosmetic adapter
```

This assumes URLLoaderFactory composition remains the supported Chromium
embedder extension point. If that extension point changes, revise the adapter
patch while keeping the engine facade and package contract unchanged.

## Ownership and proposed files

The following new directories are Phi-owned:

```text
chromium/src/components/phinomenon/adblock/
chromium/src/chrome/browser/phinomenon/adblock/
chromium/src/chrome/renderer/phinomenon/adblock/
```

| Area | Responsibility |
| --- | --- |
| components | FFI facade, typed decisions, generation metadata, shared IPC |
| browser | Profile service, policy, activation, factory proxy, diagnostics |
| renderer | Frame observer, CSS injection, DOM batching, lifecycle cleanup |
| phibrowser-mac | Settings presentation and existing bridge calls |
| update tooling | Signed lists/resources, validation, rollback artifacts |

This spans more than eight files and three runtime components. Each patch must
keep these boundaries explicit and remain independently reviewable.

## Patch series

### 1. Dependency and build foundation

- Pin the adblock-rust commit, dependencies, and features.
- Import it through Chromium's supported Rust GN mechanism.
- Add license and third-party metadata.
- Add a minimal Chromium-independent facade.
- Add construction, list loading, matching, serialization, and error tests.
- Verify compatibility with Chromium's pinned Rust toolchain.

Deliverable: a Chromium target compiles and runs facade tests.

### 2. Engine facade contract

Define an owned, typed C++ contract equivalent to:

```text
CreateEngine(config) -> EngineHandle
LoadLists(handle, list_bundle) -> Status
Match(handle, RequestContext) -> Decision
CosmeticResources(handle, DocumentContext) -> CosmeticResult
Serialize(handle) -> ByteBuffer
Deserialize(handle, ByteBuffer) -> Status
```

The contract preserves block, exception, important, redirect, rewrite, and
diagnostic fields. Rust layout does not cross the boundary. Panics and C++
exceptions become status values before crossing FFI.

Use a fixed-thread owner while `single-thread` is enabled. If profiling shows
that this is unsuitable, disable that feature explicitly and prove concurrency
behavior with tests.

### 3. Profile service and policy

- Create one service per Profile.
- Register independent `block_ads`, `block_cookie_banners`, and
  `block_trackers` preferences plus site exception preferences.
- Define normal, private, guest, and PhiChat behavior.
- Compile updates on a background sequence.
- Publish immutable engine generations atomically.
- Expose local status and generation metadata through the existing bridge.

No request path calls the macOS bridge or a remote service.

### 4. Browser network proxy

Register the Phi URLLoaderFactory proxy from
`ChromeContentBrowserClient::WillCreateURLLoaderFactory`.

The proxy preserves existing extension, enterprise-header, and sign-in proxies;
is inserted before Chromium's terminal network-bound interceptor; keeps redirect
checks enabled; handles Clone, disconnect, cancellation, priority, shutdown,
request forwarding, and redirect re-evaluation; and uses normal blocked-request
error semantics.

The first patch covers URLLoaderFactory requests only. It must not claim full
traffic coverage until worker, service-worker, cache, prefetch, keepalive, and
speculative paths are tested.

### 5. Renderer cosmetic filtering

Register a Phi renderer observer from `RenderFrameCreated`.

- Request document-specific cosmetic resources.
- Inject safe CSS early in the document lifecycle.
- Collect dynamic classes and IDs in bounded batches.
- Avoid one IPC call per DOM node.
- Remove observers and state on navigation/destruction.
- Handle frames, BFCache, prerender, and renderer shutdown.

Procedural filters and scriptlets are excluded from this patch.

### 6. macOS settings

- Add independent Block ads, Block cookie banners, and Block trackers controls.
- Add per-site exception controls.
- Add local status for active, updating, rolled back, and degraded states.
- Keep Chromium and Rust terminology behind the integration adapter.
- Add localized strings through the existing localization workflow.

### 7. Update and rollback pipeline

- Build signed packages from approved lists and resources.
- Validate signature, size, metadata, engine revision, permissions, and hashes.
- Compile in the background and atomically activate a complete generation.
- Retain the previous generation and bundled baseline.
- Support startup without network access.
- Record parse errors and unsupported-rule counts locally.

Scriptlet and redirect resources remain disabled until a separate execution
security review is complete.

## Reserved future work: YouTube compatibility

YouTube video-ad compatibility is deliberately excluded from the MVP. Do not
add YouTube-specific scriptlets, player JSON rewriting, media-stream rules, or
anti-adblock workarounds to the MVP patches. A later project may add a separate
compatibility track covering document-start injection, YouTube SPA navigation,
player configuration changes, playback regression tests, and rapid rule
rollback. Its scope and acceptance criteria require separate approval.

## Verification

### Unit tests

Test list combination, block/exception/important precedence, resource type and
third-party mapping, redirect result preservation, corrupt cache rejection,
generation rollback, Profile isolation, and FFI ownership/error handling.

### Browser tests

Cover documents, nested frames, common resource types, dedicated/shared workers,
service-worker scripts and subresources, generated and CacheStorage responses,
redirect chains, keepalive, prefetch, prerender, memory/HTTP cache, BFCache,
shutdown, extension proxy coexistence, generation swaps, guest, normal, and
private Profiles.

WebSocket is a separate handshake-provider scope and is not covered by the
URLLoaderFactory proxy.

### Renderer tests

Cover initial CSS, generic selector exceptions, dynamic DOM insertion, child
frames, navigation cleanup, BFCache restore, prerender activation, and renderer
disconnect.

### Manual acceptance

Use a local deterministic test site with server-side request counters. Verify
independently that the advertising request did not reach the server and that a
residual element is hidden when its request is allowed. Test a news, commerce,
media, and anti-adblock site. Record false positives and breakage.

## Verification commands

Initial Chromium verification runs `gn gen out/PhiDebug`, then
`autoninja -C out/PhiDebug phinomenon_adblock_unittests` and
`autoninja -C out/PhiDebug browser_tests` from
`/Users/corot2a/phi/chromium/src`. Run the focused browser filter with
`./out/PhiDebug/browser_tests --gtest_filter=PhiAdblock*`.

Release gates include all required tests, `git diff --check`, non-Phi build
compatibility, offline package verification and rollback, performance comparison,
license inventory, and a clean milestone patch replay.

## Rollback

Runtime rollback disables filtering or restores the previous signed generation
without changing browsing data. A bad browser patch is reverted as a Phi quilt
patch. New namespaced preferences use safe defaults and require no migration.

## Product decisions before Patch 3

- Private browsing inherits filtering by default: recommended yes.
- First list set includes tracker blocking: yes, as an independent category.
- First list set includes cookie-banner cosmetic rules: yes, without consent
  interaction.
- YouTube video-ad compatibility: reserved for a later project and excluded from
  the MVP.
- First release supports WebSocket filtering: recommended no; document the limit.
- List strategy: one base advertising list, one tracker list, and one cookie-banner
  list, each with an optional regional variant.
