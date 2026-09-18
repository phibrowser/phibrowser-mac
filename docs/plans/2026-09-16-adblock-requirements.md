# Phi Ad Blocking Requirements

Status: approved direction, pre-implementation
Date: 2026-09-16

## Purpose

Add native content blocking to Phi Browser using `adblock-rust` as an isolated
filtering engine. The first product surface contains three independently
controlled capabilities: block ads, block cookie banners, and block trackers.
The feature blocks supported requests in Chromium, hides residual elements in
the renderer, supports Profile-scoped policy, and updates rules independently
from browser releases.

Browser-specific logic belongs in Phi-owned modules. Chromium changes are
limited to small registration and build integration patches.

## Goals

- Block supported advertising requests before network dispatch.
- Block tracker requests before network dispatch.
- Hide common advertising and cookie-consent elements with cosmetic rules.
- Keep ads, cookie banners, and trackers as independent Profile settings.
- Isolate policy and runtime state by Profile, including private profiles.
- Compile rules away from the browser UI thread.
- Atomically activate complete rule generations.
- Retain and restore the last known-good generation.
- Update rules without requiring a browser binary release.
- Keep matching inside Chromium; Swift and remote services never decide a
  request.
- Provide local diagnostics without uploading browsing history.

## Non-goals for the first release

- Full Brave Shields parity.
- Video or server-side ad replacement.
- Arbitrary response-body rewriting.
- Fingerprinting protection or cookie partitioning.
- Automatically accepting or rejecting consent choices.
- Element picker, zapper, or user-authored advanced scriptlets.
- Trusted scriptlet execution and redirect resources.
- WebSocket filtering unless separately approved after MVP testing.
- Cross-device synchronization of policy or filtering statistics.

YouTube video-ad compatibility is explicitly reserved for a later project. It is
not part of the MVP, its acceptance criteria, or its release claim. The MVP may
block ordinary rules that happen to match YouTube-related requests, but must not
promise reliable YouTube pre-roll, mid-roll, or anti-adblock behavior.

## User-facing requirements

Each normal Profile has three persisted settings:

- Block ads.
- Block cookie banners.
- Block trackers.

The settings are independent. Disabling one category does not disable the other
two. The first release exposes the three controls and per-site exception controls
through the existing Phi settings and bridge boundaries. The UI may present the
three controls under one Content Blocking section, matching the supplied design.

Exceptions are keyed by registrable domain and apply to all three categories by
default. A future category-specific exception may be added without changing the
engine contract. Exceptions do not cross Profile boundaries. Invalid or opaque
origins cannot create persistent exceptions. Changes affect new requests and
documents; existing documents reload only on explicit user action.

Off-the-record Profiles inherit selected lists and bundled rules by default.
Private browsing does not persist visited URLs, matched rule text, or private
exception changes. Runtime engine state is destroyed with the Profile.

Filtering fails open. A failed update uses the last known-good generation or
the bundled baseline; general browsing remains functional and the UI reports a
degraded filtering state.

## Functional requirements

The network adapter supplies full URL, source and top-level site context when
available, HTTP method, explicit resource type, and third-party status derived
from Chromium origin/isolation context. Resource types distinguish document,
script, stylesheet, image, font, media, XHR, fetch, worker, and service worker.

The decision model preserves blocking, exception, `important`, redirect, and
rewritten URL results. The first release executes blocking and exceptions;
redirects and rewrites remain unsupported execution paths until a later phase.

The renderer supports host-specific CSS, generic class/ID selectors when
allowed, bounded dynamic DOM batches, and frame/navigation lifecycle cleanup.
Procedural filters and scriptlets are excluded from the first release.

The initial list set contains one bundled advertising list, one remotely
updateable advertising list, one tracker list, and one cookie-consent list. The
three settings select which category rules are active. Regional variants may be
added to each category through product configuration.

Each list has a stable identifier, source URL, content hash, version, update
timestamp, and license metadata.

## Rule package

The updater consumes a signed package containing package version, engine
revision, feature set, generation ID, timestamps, lists, resources, compiled
engine data, and signature.

The package is rejected when signature, size, format, engine revision, resource
references, or expiration policy is invalid. The compiled engine is a cache;
original list text remains available for rebuilding.

## Reliability, security, and privacy

- Compilation never runs on the browser UI thread.
- An active generation remains valid until all readers release it.
- A malformed update cannot replace the active generation.
- Startup does not wait for a remote update.
- Corrupt serialized data falls back to source lists or the bundled baseline.
- Matching adds no synchronous network or IPC round trip.
- Rule and resource packages are authenticated before activation.
- Package signature is separate from the adblock-rust serialization checksum.
- Remote lists cannot grant themselves privileged resource permissions.
- Injected code never receives Phi native bridge access.
- Routine filtering does not upload URLs, hostnames, raw rules, or page content.

## Acceptance criteria

1. A known advertising request is blocked in a document and iframe.
2. A known tracker request is blocked in a document and iframe.
3. A cookie-banner fixture is hidden without accepting or rejecting consent.
4. Each of the three settings can be disabled independently.
5. An exception allows a category that would otherwise be blocked.
6. An `important` rule is not incorrectly bypassed by an exception.
7. A rule generation can be built, activated, inspected, and rolled back.
8. A corrupt or unsigned update leaves browsing functional.
9. Normal and private Profiles do not leak policy or runtime state.
10. Workers, service workers, redirects, keepalive, prefetch, cache, and
   prerender behavior are tested and supported coverage is documented.
11. Non-Phi builds compile without the feature.
12. Performance budgets are met against the filtering-disabled baseline.
