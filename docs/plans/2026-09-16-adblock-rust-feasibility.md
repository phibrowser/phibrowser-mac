# Adblock-rust integration feasibility

Date: 2026-09-16. Status: research proposal, not an approved implementation plan.
Scope: native Phi Browser ad blocking with minimal Chromium uplift coupling.
No browser code was changed or compiled for this investigation.

## Decision summary

Use adblock-rust as a pinned filtering dependency, not as a complete browser
feature. Keep a small Phi-owned engine facade, a Chromium adapter, and a
separate renderer execution layer. Reuse the existing native bridge for settings.
Maintain registration and build wiring as a small quilt patch series.

The achievable goal is isolated upgrade work, not zero upgrade work. A patch
that applies cleanly can still miss requests after Chromium changes routing.
Do not fork net/Blink internals, transplant Brave Shields, or route every request
through Swift, Sentinel, a localhost server, or a native-messaging extension.

## Inspected baselines

| Repository | Revision | Observation |
| --- | --- | --- |
| chromium/src | a493fbcf57fb529071cce26d41af066d34bc4d32 | phi-r152; chrome/VERSION is 152.0.7977.76 |
| phibrowser-mac | 61caa362d0c69311433f180b8a38e59979e9cd28 | Native shell with an existing per-profile framework bridge |
| adblock-rust | 1c0740d27d531a2389c808212a8702592bb74138 | Cargo package 0.13.3; edition 2024; repository toolchain 1.98 |

The configured Rust toolchain is not proof of the minimum supported Rust version.
Check the selected commit against Chromium's pinned toolchain before choosing it.
Do not assume this checkout is identical to the published 0.13.3 crate.
Company knowledge synchronization fetched successfully but could not fast-forward
because local and remote histories diverged. Local source was authoritative.

## What the library provides

Local source references below are relative to the sibling repositories.

| Capability | Source | Host responsibility |
| --- | --- | --- |
| Network rule evaluation | adblock-rust/src/engine.rs:254 | Supply URL, initiator/source, method, and resource type; execute result |
| Block, exception, important, redirect, URL rewrite | adblock-rust/src/blocker.rs:20 | Use should_block(); redirect alone is not a block decision |
| CSP directives | adblock-rust/src/engine.rs:287 | Apply through response handling without weakening existing security policy |
| Site cosmetic resources | adblock-rust/src/engine.rs:381 | CSS injection, scriptlet execution, procedural filtering |
| Generic class/id selectors | adblock-rust/src/engine.rs:367 | Observe DOM changes, batch queries, honor exceptions/generichide |
| Serialized compiled rules | adblock-rust/src/engine.rs:435 | Versioned cache, source retention, resource installation, rollback |
| Resource permission masks | adblock-rust/src/resources/mod.rs:26 | Assign trust; do not let a subscription self-authorize privileged scriptlets |

It does not provide request interception, subscription distribution, automatic
updates, native controls, renderer lifecycle integration, or a complete scriptlet
resource bundle. Its JS package is a Node binding, not a browser integration.
The Apple content-blocking conversion feature is not a Chromium content blocker.

## Proposed ownership

```text
Swift settings / per-site toggle / aggregate counts
                  |
       existing PhiChromiumBridge
                  |
Phi browser service (Profile-owned policy, lifetime and update orchestration)
          |                                |
URLLoaderFactory proxy              frame-scoped renderer adapter
          |                         CSS / procedural / scriptlets
          +---------------+----------------+
                          |
               Phi filtering facade (cxx)
                          |
                  pinned adblock-rust
```

The diagram shows responsibilities, not one shared cross-process object.
Browser/renderer communication must use narrow, validated Mojo interfaces.
Keep browser-specific objects and native UI types out of the Rust facade.

Suggested placement: reusable facade and IPC definitions under
`components/phinomenon/adblock/`; browser service and proxy under
`chrome/browser/phinomenon/adblock/`; renderer adapter under a Phi-owned
renderer subtree. These are proposed directories, not existing components.
Third-party crates should follow Chromium's vendoring/GN conventions, with
locked revisions and license metadata. A separate source repository is optional;
clean ownership and independent tests matter more than a git boundary.

Settings and site exceptions belong to the existing Profile model. Define guest,
off-the-record and dedicated PhiChat behavior explicitly. Immutable public rule
data may be reused; private browsing history and statistics must not be persisted
or shared across profiles. Swift must not become the matching authority.

## Network integration

Preferred proof-of-concept: register a Phi URLLoaderFactory proxy from
`ChromeContentBrowserClient::WillCreateURLLoaderFactory`, currently
`chrome/browser/chrome_content_browser_client.cc:6680`.
The existing method already composes extension, enterprise-header and sign-in
proxies through `network::URLLoaderFactoryBuilder`. Reuse this composition
pattern rather than replacing the underlying factory.
The builder processes appended proxies in order; Chromium explicitly keeps a
network-bound interceptor last (`chrome_content_browser_client.cc:6758`). Place
Phi before that terminal interceptor and test rewritten URLs from other proxies.

`content/public/browser/content_browser_client.h:1846` enumerates document,
worker, service-worker, navigation, download, prefetch and early-hints factory
types. This is a substantially better starting point than a navigation-only
hook, but does not establish complete interception coverage.

In particular, `CreateURLLoaderThrottles` is documented as browser-initiated
requests (`content_browser_client.h:1735`). Adding only that hook does not cover
ordinary renderer subresources. Keepalive has a separate hook, and prefetch
explicitly has paths outside the ordinary throttle chain (same header:3329).

The proxy must handle redirects before following them, Clone, disconnect,
cancellation, request priority, body streaming, and lifetime/shutdown. Define
ordering with existing extensions and sign-in proxies. Preserve CORS, CORB,
redirect validation and origin checks; do not copy another proxy's bypass flags.
Use Chromium's normal blocked-request error for an ordinary block.

Do not derive the page source from the request URL. Distinguish initiating frame,
top-level site, opaque/inherited origins, worker ownership and current document.
Some factories have no RenderFrameHost. Missing context requires a documented
conservative policy, not arbitrary attachment to the active tab. Explicitly map
resource types: the local engine does not recognize the string "fetch" as XHR.

WebSocket uses a separate browser path. Service-worker CacheStorage/generated
responses, renderer memory cache, blob/data/local frames and speculative loads
need explicit tests; a network-bound proxy cannot be assumed to see all of them.
WebTransport and other non-URLLoader paths must be declared in or out of scope.
Add only the smallest additional hooks justified by tested requirements.

## Renderer integration

Use Chromium embedder/render-frame hooks and a Phi-owned observer, not edits to
Blink's DOM/style machinery. Site CSS should be available early to limit flicker.
The concrete registration candidate is `ChromeContentRendererClient::
RenderFrameCreated` (`chrome/renderer/chrome_content_renderer_client.cc:618`).
Follow the existing reviewed interface registration path rather than adding
arbitrary binders (`chrome_content_renderer_client.cc:610`). If tests require
renderer request interception, append to the existing throttle provider at
`chrome/renderer/url_loader_throttle_provider_impl.cc:168`, preserving its
worker and Clone behavior. This is additional scope, not part of the initial
network-only claim.
Dynamic pages need bounded, batched DOM observation rather than repeated full
document scans or one IPC per node. Procedural filters require a host executor;
the Rust engine returning a procedural description does not execute it.

Scriptlets require an explicit execution-world and timing policy. Some must run
in the page world before page scripts; putting everything in an isolated world
will not reproduce those behaviors. Support frame lifecycle, cross-origin frames,
inherited origins, prerender activation and BFCache restoration. Navigation must
invalidate stale document results and tear down obsolete observers.
Never expose privileged native bridge APIs to injected page code.

## FFI, threading and builds

Use a narrow cxx bridge with explicit error/status values, owned buffers, typed
request decisions and bounded inputs. Do not expose Rust layout as a stable ABI.
Avoid a boolean-only interface that loses replacement/rewrite/exception data.
Do not assume Rust panic or C++ exceptions can safely cross the boundary.

Chromium currently recommends cxx (`docs/rust/ffi.md:7`) and its
`rust_static_library` template (`docs/rust/README.md:89`). Brave's current
[bridge](https://github.com/brave/brave-core/blob/master/components/brave_shields/core/common/adblock/rs/src/lib.rs)
and [GN target](https://github.com/brave/brave-core/blob/master/components/brave_shields/core/common/adblock/rs/BUILD.gn)
use that model. The old [adblock-rust-ffi](https://github.com/brave/adblock-rust-ffi)
repository is archived. Reference current architecture, but validate all copied
API assumptions against the pinned engine revision.

The local Cargo default enables `single-thread`: Engine is not Send/Sync.
A fixed-thread owner must create, use and destroy the engine on that thread;
an ordinary sequenced task runner can migrate across physical threads and is
not sufficient evidence of Rust thread safety. Alternatively, disable the
feature explicitly and re-enable the desired resolver/regex features. The local
code then asserts Send + Sync, but mutable updates still need synchronization.

Keep parsing and compilation off the browser UI thread. Publish complete rule
generations without racing active checks. Benchmark matching, task-hop latency,
contention and memory before choosing the production placement; do not promise
that a dedicated task hop or synchronous UI-thread match is free.
Prefer source-linked GN integration over an independently downloaded dylib.
This isolates source ownership without adding ABI, signing and loader risks.

## Rules, resources and release safety

Start by evaluating EasyList plus the product's required regional lists;
EasyPrivacy is a separate tracker-blocking product decision. List inclusion
requires license, provenance, syntax-compatibility and breakage review.
Do not assume Brave's hosted component service is a reusable Phi distribution API.

Distribute authenticated, bounded rule/resource packages independently of browser
releases. Stage, validate, compile and atomically publish a complete generation;
retain the last known-good generation and a bundled offline baseline. Expensive
or malformed rules must not stall page loading. If no usable engine exists,
fail open with visible degraded status, not a browser-wide network outage.

Keep text lists as source of truth. Engine serialization is explicitly only a
cache and is not guaranteed compatible across minor versions. Local data format
is v7 even though the changelog mentions v6. Cache identity should include the
engine revision, features, list hashes and resource generation. Resources are
not included in the serialized engine and must be installed separately.
The cache's SeaHash checksum is not signature verification.

Build/update parsing diagnostics into tests: unsupported rules and unavailable
resources can otherwise silently reduce effectiveness. Treat scriptlet/resource
updates as code-bearing supply-chain changes, not harmless text downloads.
Do not upload page URLs or matched rules for routine aggregate statistics.

## Licensing

The crate is MPL-2.0. Mozilla's [official FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)
explains file-level copyleft and permits combination/static linking with
proprietary code. Distribution still requires the applicable notices and access
to the covered source, including modifications. It does not automatically require
publishing all Phi engine code. Review the exact artifact with legal counsel.
Filter lists, scriptlets, replacement resources and transitive crates have their
own licenses; an engine license does not clear those assets. Avoid copying GPL
extension code under the assumption that the Rust engine's MPL applies to it.

## Alternatives

| Approach | Assessment |
| --- | --- |
| Native engine plus thin adapter | Recommended balance of capability, ownership and uplift cost |
| Built-in MV3/DNR extension | Lower Chromium coupling; valid if extension-level behavior suffices; not a drop-in runtime for arbitrary Rust decisions |
| Preserve MV2 plus an existing blocker | Moves maintenance into deprecated extension infrastructure; poor long-term default |
| Fork Brave Shields wholesale | Imports browser policy, services and patch assumptions beyond the requested feature |
| External proxy/DNS service | Lacks reliable document/DOM context; HTTPS inspection introduces unacceptable extra complexity for this objective |

Chrome's [DNR documentation](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)
also distinguishes network requests from service-worker generated/CacheStorage
responses. Extension isolation does not imply identical filtering semantics.

## Phased validation and upgrade contract

1. Build spike: pin an engine commit, resolve GN dependencies, exercise the cxx
   facade on the actual Chromium/macOS toolchain. Verify licensing inventory.
2. Network prototype: basic blocking/allow rules, per-site off switch, correct
   frame context, redirects and factory lifetime. Test before adding cosmetics.
3. Initial product: network filtering plus ordinary CSS hiding, profile policy,
   reliable updates, rollback and observable degraded mode. Do not label this
   Brave-equivalent; missing scriptlets/replacements can cause site breakage.
4. Advanced compatibility: trusted scriptlets, resource replacement, procedural
   filters, CSP and URL rewrites, each with explicit semantic and security tests.

Keep vendoring/build changes, network registration, renderer registration/IPC,
and bridge/settings changes in separately understandable patches. All upstream
Phi hunks follow IS_PHI_BROWSER gating and existing buildflag dependency rules.
Do not commit to a fixed patch/file count before the coverage spike.

Every milestone uplift must replay patches and run behavioral tests, not just
compile. Include scripts/images/XHR/fetch; redirects; same/cross-origin frames;
workers and service workers; HTTP/memory/CacheStorage caches; keepalive/beacon;
prefetch/prerender/BFCache; WebSocket if supported; profile/private mode; extension
coexistence; rule swaps mid-navigation; corrupted cache; startup/shutdown; and
feature-disabled/non-Phi configurations. Check server-side request counters so
DOM hiding is not mistaken for network blocking.

Measure startup compilation, idle/per-tab RSS, p50/p95 matching and end-to-end
request overhead, main-thread stalls and representative site breakage. Targets
need baseline measurements rather than borrowed Brave benchmark claims.
Server-side stitched video ads and rapidly changing anti-adblock schemes are not
guaranteed solved merely by adopting this engine.

Approval needed before implementation: initial compatibility tier, tracker scope,
default lists/regions, private-profile policy and acceptable fallback behavior.
