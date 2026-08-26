# Transport Mode Fallback (phibrowser-mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Phi Browser's `broker.capabilities` handshake answer `unsupported_message` while Sentinel reports transport mode `legacy`, so Sentinel's staged rollout can turn the native Service Broker off for every maintained extension at once, with zero behaviour change on any Sentinel that does not report a mode.

**Architecture:** Sentinel adds an additive `transport_mode` (`legacy | uds | full_uds`) to the response of the IPC method the browser already calls, `getComponentExports`. `SentinelIPCClient` decodes that field into a typed Swift enum and returns it next to the exports JSON it already returns. `ServiceBrokerExtensionProtocol` reads the mode once per `broker.capabilities` handshake through an injected provider closure — the same injection pattern the file already uses for `socketPathProvider` and `authSnapshotProvider` — and answers `failure(unsupported_message, …)` only for the exact mode `legacy`. Everything else (`uds`, `full_uds`, absent field, unrecognised value, failed IPC) answers `protocolVersion: 1` exactly as today. No new IPC method, no new native message type, no new transport channel: this is a parameterization of the existing handshake.

**Tech Stack:** Swift 6 / Foundation, Swift actors and `@Sendable` closure providers, `JSONSerialization`, XCTest, `xcodebuild` (`Phi.xcodeproj`, scheme `PhiBrowser-canary`).

**Spec:** `/Users/elmer/workspace/phinomenon/sentinel-wt-rollout/docs/superpowers/specs/2026-08-25-staged-rollout-design.md`, section **"v2 (2026-08-26): legacy is the fallback, UDS is the rollout target"**, in particular the subsection **"Client signal contract"**. The plan argues from that section; read both.

**Branch:** `feat/transport-mode-fallback`, forked from `origin/release/2.8.0` (`3c4d927f`). The 2.8 release is unreleased, so this ships inside 2.8 rather than as a patch on a shipped browser.

## Wire-shape assumption (must be reconciled with the Sentinel plan)

Sentinel's plan is being written in parallel and picks the exact JSON placement of `transport_mode` in the `getComponentExports` IPC response. **This plan assumes only that `transport_mode` is a top-level JSON string, in one of these two places, and it decodes both:**

```jsonc
// (A) sibling of "result" in the IPC response envelope
{ "ok": true, "request_id": "…", "result": { "phi-agent": { "api_base": "…" }, … }, "transport_mode": "uds" }

// (B) sibling of the component IDs inside "result"
{ "ok": true, "request_id": "…", "result": { "phi-agent": { "api_base": "…" }, …, "transport_mode": "uds" } }
```

Decoder rule implemented in Task 1: **envelope root first, then the `result` object, first recognised value wins; absent, non-string, or unrecognised ⇒ `uds`.** The field is never assumed to be nested under a component ID, and the browser never rewrites the exports object it forwards to extensions. If the Sentinel plan chooses (A) or (B), no change is needed here. If it chooses anything else (a nested object, a different key name), this plan's Task 1 decoder is the single place to reconcile.

**Value rule and its justification:**

| Sentinel reports | Browser reads it as | Why |
| --- | --- | --- |
| `"legacy"` | `.legacy` | The only value that changes behaviour. It is the explicit kill switch. |
| `"uds"` / `"full_uds"` | `.uds` / `.fullUDS` | Broker-carrying modes; today's answer. |
| field absent | `.uds` | Every Sentinel released before staged-rollout v2 omits it, and every one of them runs the broker. Reading absence as `legacy` would disable the broker for every user on an older Sentinel — a mass regression triggered by shipping the browser alone. |
| unrecognised string (`"banana"`, `""`, a future mode name) | `.uds` | An unrecognised value can only come from a **newer** Sentinel that added a mode. `legacy` is the single named fallback and it is already spelled exactly; any mode added later is a variation of broker routing (as `full_uds` is a variation of `uds`). Choosing `uds` therefore never silently turns off a working transport, and if the broker really is gone the request path still fails safely on its own terms (`/version` negotiation fails ⇒ `protocol_error`). Choosing `legacy` would let one typo in a flag payload disable the broker fleet-wide. |
| IPC lookup failed (Sentinel down, socket missing, timeout, `ok: false`) | `.uds` (answer `protocolVersion: 1`, log) | Identical to today's behaviour when Sentinel is not reachable: the browser answers `1`, the extension tries the broker, and the broker socket connect fails on its own terms. Failing the handshake closed here would newly break Sidecar during every Sentinel restart. |

Only the exact string `legacy` turns the broker path off. That is a deliberate one-way switch.

## Global Constraints

- **No new IPC methods.** The mode is read from the existing `getComponentExports` call. No new native message type, no `serviceBroker.getStatus` client in the browser.
- **No behaviour change when Sentinel omits the field.** Absent ⇒ `uds` ⇒ `protocolVersion: 1`, byte-identical reply to today's.
- **The mode is re-read per handshake.** It must NOT be cached on `productionRuntime` (which is keyed by account + socket path and lives for the account's lifetime); a `uds → legacy` kill switch has to converge on the next handshake. One extra `getComponentExports` round trip per handshake is the accepted cost (extensions cache the handshake result for 30 s on their side).
- **Pattern Stability Rule (`AGENTS.md`).** Extend the existing handshake and the existing `@Sendable` provider-closure injection in `ServiceBrokerExtensionProtocol`; do not add a parallel enum, a parallel transport selector, or a second discovery path. Reuse `ServiceBrokerFallbackReason` rather than inventing a second fallback vocabulary.
- **Docs are co-updated in the same commit as the code they describe** (`AGENTS.md` Documentation Rules; shared agent rules). `docs/service-broker-extension-boundary.md` is the owner document for this boundary.
- **Commits: one single-line conventional commit per task. No body, no bullet list, no trailers** (`AGENTS.md` Git Rules) — this overrides any default co-author footer.
- **This plan is the explicit instruction to commit** that `AGENTS.md` "Commit Timing" asks for. Commit at the end of each task; do not wait for a further prompt.
- **Do not create new files under `Sources/`.** `Sources/` files are referenced individually in `Phi.xcodeproj/project.pbxproj` (4 entries each); a new source file needs manual pbxproj surgery. `Tests/PhiBrowserTests` **is** a `PBXFileSystemSynchronizedRootGroup`, so new **test** files are picked up automatically with no pbxproj change. `git status` must never show `Phi.xcodeproj/project.pbxproj` as modified.
- All code, comments and documentation in English (`AGENTS.md`).

## Out of scope

- The Sentinel half (emitting `transport_mode`, the rollout feature, `system.getBrokerAccess` returning `E_NOT_AVAILABLE` under `legacy`) — separate plan in the sentinel repo.
- The phi-ai half (`resolveTransportMode()`, mode-conditional `requireNative`, the 30 s TTL on the "supported" capability cache) — separate plan in the phi-ai repo. The browser answer alone already fixes Lexington and Kensington, which never pass `requireNative`.
- Knowledge-base write-back to `~/.agents/company-knowledge/30-projects/cross-project/phi-extension-native-service-broker.md`. The cross-project client-signal contract is owned by the Sentinel/KB write-back pass; do not edit the knowledge base from this repo's task.
- Sentinel.app's WebView (`BrokerAccessStore`, `APISchemeHandler`) — it already treats "no broker access" as loopback and needs no Swift change.

## File Structure

| File | Responsibility after this plan | Task |
| --- | --- | --- |
| `Sources/Application/SentinelIPCClient.swift` | Owns the browser side of the Sentinel IPC wire contract. Gains `SentinelTransportMode`, `SentinelComponentExports`, and the tolerant `transport_mode` decoder. Still the only place that speaks Sentinel IPC. | 1 |
| `Sources/Networking/PhiAgentEndpointResolver.swift` | Unchanged responsibility; updated for the new `getComponentExports()` return type. | 1 |
| `Sources/Notifications/MessageCard/ExtensionMessageRouter.swift` | Unchanged responsibility; updated for the new return type. Keeps forwarding the exports object verbatim to extensions. | 1 |
| `Sources/Networking/ServiceBroker/ServiceBrokerExtensionProtocol.swift` | Owns the extension boundary. Gains one provider closure and one branch in the existing `broker.capabilities` handler. | 2 |
| `docs/service-broker-extension-boundary.md` | Owner document for this boundary. Gains the transport-mode signal bullet (Task 1) and the legacy answer rule + compatibility matrix (Task 2). | 1, 2 |
| `Tests/PhiBrowserTests/SentinelTransportModeTests.swift` (new) | Fixture-JSON unit tests for the decoder. | 1 |
| `Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerExtensionProtocolTests.swift` | Handshake behaviour tests. | 2 |

No new source file, no file split: both changed source files are small and focused (285 and 884 lines) and the change is a few dozen lines in each.

**This repository keeps no changelog or release-notes file** (no `CHANGELOG*` anywhere in the tree, no what's-new resource; release notes for 2.8 live outside this repo). There is therefore no changelog entry to write, and the historical design documents under `docs/plans/` and `docs/superpowers/specs/` are records of past work and are not retro-edited. `docs/service-broker-extension-boundary.md` is the only document that owns this behaviour, and it is the only one this plan changes.

---

### Task 1: Decode Sentinel's `transport_mode` in the IPC client

**Files:**
- Modify: `Sources/Application/SentinelIPCClient.swift:22-38` (the `getComponentExports()` method and its doc comment) and append two types at the end of the file, after the closing brace of `final class SentinelIPCClient` (currently `:285`)
- Modify: `Sources/Networking/PhiAgentEndpointResolver.swift:71-83`
- Modify: `Sources/Notifications/MessageCard/ExtensionMessageRouter.swift:102-112`
- Modify: `docs/service-broker-extension-boundary.md` (insert one bullet after the existing socket-resolution bullet at `:34`)
- Test: `Tests/PhiBrowserTests/SentinelTransportModeTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks. Existing behaviour it must preserve: `getComponentExports()` throws `SentinelIPCClient.IPCError` on transport failure or `ok != true`, and serializes the response's `result` object verbatim.
- Produces, for Task 2:
  - `enum SentinelTransportMode: String, Sendable, Equatable { case legacy; case uds; case fullUDS }` with raw values `"legacy"`, `"uds"`, `"full_uds"`, and `static let fallback: SentinelTransportMode = .uds`
  - `struct SentinelComponentExports: Sendable, Equatable { let exportsJSON: String; let transportMode: SentinelTransportMode }`
  - `func getComponentExports() async throws -> SentinelComponentExports` (return type changed from `String`)
  - `static func transportMode(fromResponse response: [String: Any]) -> SentinelTransportMode`

- [ ] **Step 1: Write the failing test**

Create `Tests/PhiBrowserTests/SentinelTransportModeTests.swift`:

```swift
import Foundation
import XCTest
@testable import Phi

/// Fixture-driven tests for the additive `transport_mode` signal Sentinel
/// attaches to the `getComponentExports` IPC response. The exact placement is
/// chosen by Sentinel; the browser tolerates the envelope root and the exports
/// object, and treats anything it cannot recognise as `uds` (today's behaviour).
final class SentinelTransportModeTests: XCTestCase {
    func testWireValuesMatchTheSentinelContract() {
        XCTAssertEqual(SentinelTransportMode.legacy.rawValue, "legacy")
        XCTAssertEqual(SentinelTransportMode.uds.rawValue, "uds")
        XCTAssertEqual(SentinelTransportMode.fullUDS.rawValue, "full_uds")
        XCTAssertEqual(SentinelTransportMode.fallback, .uds)
    }

    func testReadsTransportModeFromTheEnvelopeRoot() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"}},"transport_mode":"legacy"}
        """#)

        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .legacy)
    }

    func testReadsTransportModeFromTheExportsObject() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"},"transport_mode":"legacy"}}
        """#)

        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .legacy)
    }

    func testReadsEveryDeclaredMode() throws {
        let cases: [(String, SentinelTransportMode)] = [
            ("legacy", .legacy),
            ("uds", .uds),
            ("full_uds", .fullUDS),
        ]

        for (raw, expected) in cases {
            let root = try envelope(#"{"ok":true,"result":{},"transport_mode":"\#(raw)"}"#)
            XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: root), expected, "root: \(raw)")

            let nested = try envelope(#"{"ok":true,"result":{"transport_mode":"\#(raw)"}}"#)
            XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: nested), expected, "result: \(raw)")
        }
    }

    func testAbsentTransportModeReadsAsUDS() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"},"phi-memory":{"api_base":"http://127.0.0.1:8790"}}}
        """#)

        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .uds)
    }

    func testUnrecognisedTransportModeReadsAsUDS() throws {
        for raw in ["banana", "", "LEGACY", "full-uds"] {
            let response = try envelope(#"{"ok":true,"result":{},"transport_mode":"\#(raw)"}"#)
            XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .uds, "raw: \(raw)")
        }
    }

    func testNonStringTransportModeReadsAsUDS() throws {
        let number = try envelope(#"{"ok":true,"result":{},"transport_mode":7}"#)
        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: number), .uds)

        let object = try envelope(#"{"ok":true,"result":{},"transport_mode":{"mode":"legacy"}}"#)
        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: object), .uds)

        let null = try envelope(#"{"ok":true,"result":{},"transport_mode":null}"#)
        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: null), .uds)
    }

    func testUnusableEnvelopeValueFallsThroughToTheExportsObject() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"transport_mode":"legacy"},"transport_mode":"banana"}
        """#)

        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .legacy)
    }

    func testExportsJSONIsUnaffectedByTheAddedField() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788/"},"transport_mode":"legacy"}}
        """#)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: result)
        let exportsJSON = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(
            PhiAgentEndpointResolver.parsePhiAgentApiBase(from: exportsJSON),
            "http://127.0.0.1:8788"
        )
    }

    private func envelope(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SentinelTransportModeTests
```

Expected: **compile failure**, `cannot find 'SentinelTransportMode' in scope` and `type 'SentinelIPCClient' has no member 'transportMode'`. A compile failure is the correct "red" here — do not proceed until you have seen it.

- [ ] **Step 3: Add the types and the decoder**

In `Sources/Application/SentinelIPCClient.swift`, append after the closing brace of `final class SentinelIPCClient` (end of file):

```swift
/// The client-routing policy Sentinel currently applies, reported as an
/// additive `transport_mode` field on the `getComponentExports` IPC response.
///
/// `legacy` means clients must not use the Service Broker at all and should use
/// the pre-broker direct loopback path; `uds` and `full_uds` both mean the
/// broker path is in use. Sentinel builds older than the staged-rollout change
/// omit the field entirely.
enum SentinelTransportMode: String, Sendable, Equatable {
    case legacy
    case uds
    case fullUDS = "full_uds"

    /// The mode assumed when Sentinel reports nothing usable: an absent field
    /// (any Sentinel released before the field existed, all of which run the
    /// broker) or an unrecognised value (only a newer Sentinel can produce one,
    /// and `legacy` is the single explicitly named opt-out). Reading either as
    /// `legacy` would disable a working transport for everyone; reading them as
    /// `uds` preserves today's behaviour and still fails safely if the broker is
    /// genuinely unavailable.
    static let fallback: SentinelTransportMode = .uds
}

/// A `getComponentExports` reply: the exports object exactly as Sentinel sent
/// it, plus the transport mode that came with it.
struct SentinelComponentExports: Sendable, Equatable {
    /// The response's `result` object, re-serialized verbatim. Forwarded to
    /// extensions unchanged; the browser never reshapes it.
    let exportsJSON: String
    let transportMode: SentinelTransportMode
}
```

Then replace `getComponentExports()` (`:22-38`) with:

```swift
    /// Fetches component exports from the Sentinel runner, together with the
    /// transport mode Sentinel reports alongside them.
    /// - Returns: The exports JSON string plus the decoded transport mode.
    func getComponentExports() async throws -> SentinelComponentExports {
        let response = try await sendRequest(method: "getComponentExports", params: [:])

        guard let ok = response["ok"] as? Bool, ok else {
            if let error = response["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw IPCError.runnerError(message: message)
            }
            throw IPCError.runnerError(message: "Failed to get component exports")
        }

        let result = response["result"] ?? [String: Any]()
        let data = try JSONSerialization.data(withJSONObject: result)
        return SentinelComponentExports(
            exportsJSON: String(data: data, encoding: .utf8) ?? "{}",
            transportMode: Self.transportMode(fromResponse: response)
        )
    }

    /// Extracts the additive `transport_mode` from a `getComponentExports`
    /// response. Sentinel may place the field at the envelope root (next to
    /// `result`) or inside the exports object (next to the component IDs); both
    /// are accepted, envelope root first, first recognised value wins. An
    /// absent, non-string, or unrecognised value reads as
    /// ``SentinelTransportMode/fallback``, so a Sentinel that never reports a
    /// mode behaves exactly as before the field existed.
    static func transportMode(fromResponse response: [String: Any]) -> SentinelTransportMode {
        if let raw = response[transportModeKey] as? String,
           let mode = SentinelTransportMode(rawValue: raw) {
            return mode
        }
        if let result = response["result"] as? [String: Any],
           let raw = result[transportModeKey] as? String,
           let mode = SentinelTransportMode(rawValue: raw) {
            return mode
        }
        return .fallback
    }
```

And add the wire key next to the other constants, directly under `private let protocolVersion = 1` (`:16`):

```swift
    /// Wire key of Sentinel's additive transport-mode signal.
    private static let transportModeKey = "transport_mode"
```

- [ ] **Step 4: Update the two callers**

`Sources/Networking/PhiAgentEndpointResolver.swift:71-83` — replace the body of `resolve(using:)`:

```swift
    private static func resolve(using ipcClient: SentinelIPCClient) async -> String {
        do {
            let exports = try await ipcClient.getComponentExports()
            if let url = parsePhiAgentApiBase(from: exports.exportsJSON) {
                AppLogDebug("[PhiAgentEndpoint] resolved via Sentinel: \(url)")
                return url
            }
            AppLogDebug("[PhiAgentEndpoint] phi-agent.api_base missing or invalid; using fallback")
        } catch {
            AppLogDebug("[PhiAgentEndpoint] IPC lookup failed (\(error.localizedDescription)); using fallback")
        }
        return fallbackBaseURL
    }
```

`Sources/Notifications/MessageCard/ExtensionMessageRouter.swift:102-112` — replace the `getServiceExports` handler body so the extension still receives the exports object verbatim:

```swift
        register(type: "getServiceExports") { context in
            Task {
                do {
                    let exports = try await SentinelIPCClient.shared.getComponentExports()
                    await ExtensionMessaging.shared.sendResponse(exports.exportsJSON, requestId: context.requestId)
                } catch {
                    await ExtensionMessaging.shared.sendError(error.localizedDescription, requestId: context.requestId)
                }
            }
            return nil
        }
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SentinelTransportModeTests
```

Expected: `** TEST SUCCEEDED **`, 9 tests executed, 0 failures.

- [ ] **Step 6: Confirm no caller was missed and the project file is untouched**

```bash
grep -rn "getComponentExports(" Sources
git status --short
```

Expected: exactly three hits (the declaration in `SentinelIPCClient.swift`, `PhiAgentEndpointResolver.swift`, `ExtensionMessageRouter.swift`), and `git status` shows only the four files this task touches plus the new test file — **no `Phi.xcodeproj/project.pbxproj`**.

- [ ] **Step 7: Co-update the boundary document**

In `docs/service-broker-extension-boundary.md`, insert this bullet immediately **after** the bullet that begins `- Phi Browser resolves the account-scoped broker socket from shared authentication state.` (`:34`):

```markdown
- Sentinel reports the transport mode it currently applies to clients (`legacy`, `uds`, or `full_uds`) as an additive `transport_mode` string on the response of the `getComponentExports` IPC the browser already makes; no IPC method is added for it. The browser accepts the field at the response envelope root or inside the exports object, and reads an absent, non-string, or unrecognised value as `uds` — the behaviour of every Sentinel released before the field existed. The exports object itself is forwarded to extensions unchanged; the browser never reshapes it.
```

- [ ] **Step 8: Commit**

```bash
git add Sources/Application/SentinelIPCClient.swift Sources/Networking/PhiAgentEndpointResolver.swift Sources/Notifications/MessageCard/ExtensionMessageRouter.swift Tests/PhiBrowserTests/SentinelTransportModeTests.swift docs/service-broker-extension-boundary.md
git commit -m "feat(sentinel-ipc): read Sentinel's additive transport_mode from component exports"
```

---

### Task 2: Answer `broker.capabilities` with `unsupported_message` in legacy transport mode

**Files:**
- Modify: `Sources/Networking/ServiceBroker/ServiceBrokerExtensionProtocol.swift:40` (typealias), `:121-153` (stored providers and both initialisers), `:174-186` (the `broker.capabilities` branch), and insert one private helper after `requireUnchangedAuth(_:)` (`:500-507`)
- Modify: `docs/service-broker-extension-boundary.md:40-43` (the `broker.capabilities` bullet) and add a compatibility-matrix subsection before `## Request and channel lifecycle` (`:45`)
- Test: `Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerExtensionProtocolTests.swift` (new tests, plus one new parameter on the existing `makeHandler` helper at `:1325-1366`, plus one new private actor next to `TestUpstreamError` at `:1769`)

**Interfaces:**
- Consumes, from Task 1:
  - `enum SentinelTransportMode: String, Sendable, Equatable { case legacy; case uds; case fullUDS }` — raw values `"legacy"`, `"uds"`, `"full_uds"` — with `static let fallback: SentinelTransportMode = .uds`
  - `struct SentinelComponentExports: Sendable, Equatable { let exportsJSON: String; let transportMode: SentinelTransportMode }`
  - `SentinelIPCClient.shared.getComponentExports() async throws -> SentinelComponentExports`
- Consumes, already in the repo:
  - `enum ServiceBrokerFallbackReason: Sendable` in `Sources/Networking/ServiceBroker/ServiceBrokerTypes.swift:231-247`, with cases `brokerUnavailable`, `protocolUnsupported`, `signedCompatibilityConfig`, `authorizationDenied`, `invalidRequest`, `sizeLimitExceeded` and `var allowsLoopback: Bool` (true for the first three). Note: this type sits at `:231` on `release/2.8.0`, not `:222` as on `origin/dev`.
  - `public func AppLogDebug(_ logText: @autoclosure () -> String, …)` from `Sources/Utilities/Logging/Logging.swift:119`
- Produces:
  - `ServiceBrokerExtensionProtocol.TransportModeProvider = @Sendable () async throws -> SentinelTransportMode`
  - a new trailing initialiser parameter `transportModeProvider: @escaping TransportModeProvider = { .uds }` on the test-facing `init(limits:channelStore:runtimeAccountID:requestExecutor:authSnapshotProvider:)`

- [ ] **Step 1: Write the failing tests**

First extend the existing `makeHandler` helper in `Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerExtensionProtocolTests.swift` (`:1325-1366`). Add these two parameters after `authSnapshotProvider` (`:1343`) and before `runtimeAccountID` (`:1344`):

```swift
        transportMode: SentinelTransportMode = .uds,
        transportModeProvider: (@Sendable () async throws -> SentinelTransportMode)? = nil,
```

then, next to `let resolvedAuthSnapshotProvider = …` (`:1358`), add:

```swift
        let resolvedTransportModeProvider = transportModeProvider ?? { transportMode }
```

and pass it as the last argument of the `ServiceBrokerExtensionProtocol(...)` call (`:1359-1365`):

```swift
        return ServiceBrokerExtensionProtocol(
            limits: resolvedLimits,
            channelStore: resolvedStore,
            runtimeAccountID: runtimeAccountID,
            requestExecutor: resolvedExecutor,
            authSnapshotProvider: resolvedAuthSnapshotProvider,
            transportModeProvider: resolvedTransportModeProvider
        )
```

Add this private actor at the end of the file, next to `private struct TestUpstreamError: Error {}` (`:1769`):

```swift
/// Serves a scripted sequence of transport modes and counts how many times the
/// handshake asked, so a test can prove the mode is re-read per handshake.
private actor TransportModeProbe {
    private let modes: [SentinelTransportMode]
    private(set) var callCount = 0

    init(_ modes: [SentinelTransportMode]) {
        precondition(!modes.isEmpty, "TransportModeProbe needs at least one mode")
        self.modes = modes
    }

    /// Returns the mode for this handshake, repeating the last entry once the
    /// scripted sequence is exhausted.
    func next() -> SentinelTransportMode {
        let mode = modes[min(callCount, modes.count - 1)]
        callCount += 1
        return mode
    }
}
```

Then add these tests to `ServiceBrokerExtensionProtocolTests`, directly after `testCapabilityHandshakeIsExplicitAndDoesNotRequireRuntimeAuth` (`:10-34`):

```swift
    func testCapabilityHandshakeIsUnsupportedInLegacyTransportMode() async throws {
        let handler = makeHandler(transportMode: .legacy)

        for sender in [allowedSender, lexingtonSender, kensingtonSender] {
            let reply = await handler.handle(
                type: "broker.capabilities",
                payload: "{}",
                senderID: sender
            )

            XCTAssertEqual(reply.error?.code, "unsupported_message", "sender: \(sender)")
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any]
            )
            XCTAssertEqual(root["ok"] as? Bool, false, "sender: \(sender)")
        }
    }

    func testCapabilityHandshakeAnswersProtocolVersionInBrokerTransportModes() async throws {
        // `.fallback` is what Task 1's decoder returns when Sentinel omits the
        // field entirely or reports a value this browser does not recognise.
        for mode in [SentinelTransportMode.uds, .fullUDS, .fallback] {
            let handler = makeHandler(transportMode: mode)
            let reply = await handler.handle(
                type: "broker.capabilities",
                payload: "{}",
                senderID: allowedSender
            )

            XCTAssertNil(reply.error, "mode: \(mode)")
            XCTAssertEqual(try successResult(reply)["protocolVersion"] as? Int, 1, "mode: \(mode)")
        }
    }

    func testCapabilityHandshakeAnswersProtocolVersionWhenTheTransportModeLookupFails() async throws {
        let handler = makeHandler(transportModeProvider: { throw TestUpstreamError() })

        let reply = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        XCTAssertEqual(try successResult(reply)["protocolVersion"] as? Int, 1)
    }

    func testCapabilityHandshakeRereadsTheTransportModeEveryTime() async throws {
        let probe = TransportModeProbe([.uds, .legacy, .uds])
        let handler = makeHandler(transportModeProvider: { await probe.next() })

        let first = await handler.handle(type: "broker.capabilities", payload: "{}", senderID: allowedSender)
        let second = await handler.handle(type: "broker.capabilities", payload: "{}", senderID: allowedSender)
        let third = await handler.handle(type: "broker.capabilities", payload: "{}", senderID: allowedSender)

        XCTAssertEqual(try successResult(first)["protocolVersion"] as? Int, 1)
        XCTAssertEqual(second.error?.code, "unsupported_message")
        XCTAssertEqual(try successResult(third)["protocolVersion"] as? Int, 1)
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 3)
    }

    func testLegacyTransportModeDoesNotChangeSenderOrPayloadRejections() async throws {
        let probe = TransportModeProbe([.legacy])
        let handler = makeHandler(transportModeProvider: { await probe.next() })

        let denied = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        XCTAssertEqual(denied.error?.code, "unauthorized_sender")

        let malformed = await handler.handle(
            type: "broker.capabilities",
            payload: #"{"unexpected":true}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(malformed.error?.code, "invalid_payload")

        // Neither rejection may cost a Sentinel IPC round trip: the mode is read
        // only once the sender and payload have been accepted.
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testLegacyTransportModeDoesNotAffectOtherBrokerMessages() async throws {
        let recorder = BrokerRequestRecorder()
        let handler = makeHandler(recorder: recorder, transportMode: .legacy)

        let reply = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/broker/healthz","method":"GET"}"#,
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        let recordedRequest = await recorder.lastRequest()
        XCTAssertNotNil(recordedRequest)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/ServiceBrokerExtensionProtocolTests
```

Expected: **compile failure**, `extra argument 'transportModeProvider' in call` on the `ServiceBrokerExtensionProtocol(...)` construction inside `makeHandler`.

- [ ] **Step 3: Add the provider to the protocol actor**

In `Sources/Networking/ServiceBroker/ServiceBrokerExtensionProtocol.swift`, add the typealias directly under `typealias RequestExecutor` (`:40`):

```swift
    /// Reads Sentinel's current client transport mode. Called once per
    /// capability handshake — never cached with the negotiated runtime, so a
    /// `uds -> legacy` kill switch converges on the next handshake.
    typealias TransportModeProvider = @Sendable () async throws -> SentinelTransportMode
```

Add the stored property under `private let authSnapshotProvider` (`:123`):

```swift
    private let transportModeProvider: TransportModeProvider
```

In `private init()` (`:126-130`), add the production wiring, which reuses the browser's only Sentinel IPC method:

```swift
    private init() {
        injectedRuntime = nil
        socketPathProvider = Self.currentSocketPath
        authSnapshotProvider = { SharedAuthTokenStore.shared.authenticatedSnapshot() }
        transportModeProvider = {
            try await SentinelIPCClient.shared.getComponentExports().transportMode
        }
    }
```

In the test-facing `init(...)` (`:132-153`), add the trailing parameter after `authSnapshotProvider` and assign it:

```swift
    init(
        limits: ServiceBrokerLimits,
        channelStore: ServiceBrokerChannelStore,
        runtimeAccountID: String? = nil,
        requestExecutor: @escaping RequestExecutor,
        authSnapshotProvider: @escaping @Sendable () -> SharedAuthTokenSnapshot? = {
            SharedAuthTokenStore.shared.authenticatedSnapshot()
        },
        transportModeProvider: @escaping TransportModeProvider = { .uds }
    ) {
```

and, after `self.authSnapshotProvider = authSnapshotProvider` (`:152`):

```swift
        self.transportModeProvider = transportModeProvider
```

- [ ] **Step 4: Add the mode read and the legacy answer**

Insert this private helper immediately after `requireUnchangedAuth(_:)` (`:500-507`):

> **Superseded by `43fa9250` (500 ms budget) and this commit (single-flight + cool-down).**
> The unbounded sketch below stalled the handshake past the extension's 1_500 ms
> capability probe against a hung Sentinel, and bounding only the answer still
> parked one blocked IPC thread per handshake. The shipped helper delegates to
> `TransportModeReader`; see `docs/service-broker-extension-boundary.md`.

```swift
    /// Sentinel's current transport mode, re-read on every capability
    /// handshake. A lookup failure keeps the pre-rollout answer: the extension
    /// is told the broker is supported and, if the broker really is gone, its
    /// own request fails on its own terms — exactly today's behaviour when
    /// Sentinel is not running.
    private func currentTransportMode() async -> SentinelTransportMode {
        do {
            return try await transportModeProvider()
        } catch {
            AppLogDebug(
                "[ServiceBroker] transport mode lookup failed (\(error.localizedDescription)); "
                    + "keeping the broker capability answer"
            )
            return .fallback
        }
    }
```

Then replace the `broker.capabilities` branch (`:174-186`) with:

```swift
        if type == "broker.capabilities" {
            do {
                guard payload.lengthOfBytes(using: .utf8) <= Self.maximumEnvelopeMetadataBytes else {
                    throw ProtocolFailure(code: .requestTooLarge, message: "The broker request is too large.")
                }
                _ = try decode(CapabilitiesPayload.self, payload: payload, allowedKeys: [])
                if await currentTransportMode() == .legacy {
                    // Telling the extension the broker path is unavailable is
                    // exactly ServiceBrokerFallbackReason.protocolUnsupported
                    // (allowsLoopback == true): the one documented case in which
                    // the capability handshake may select legacy discovery.
                    let reason = ServiceBrokerFallbackReason.protocolUnsupported
                    AppLogDebug(
                        "[ServiceBroker] Sentinel transport mode is legacy; answering unsupported_message "
                            + "(fallback: \(reason), allowsLoopback: \(reason.allowsLoopback))"
                    )
                    return failure(
                        .unsupportedMessage,
                        "The service broker is disabled for the current Sentinel transport mode."
                    )
                }
                return try success(["protocolVersion": 1])
            } catch let error as ProtocolFailure {
                return failure(error.code, error.message)
            } catch {
                return failure(.protocolError, "The broker capability response could not be encoded.")
            }
        }
```

The order matters and is asserted by the tests: sender authorization (`:168-170`) and message-type check (`:171-173`) run first, then the envelope-size guard and payload decode, and only then the Sentinel IPC. A rejected sender or a malformed payload never costs a round trip, and `unauthorized_sender` / `invalid_payload` / `request_too_large` keep their exact current precedence.

Cost and concurrency: this adds one Unix-socket round trip (5-second socket timeout, `SentinelIPCClient:180-187`) to a handshake that extensions perform at most once per 30-second capability-cache window per extension context. `handle(type:payload:senderID:)` is an actor method that already suspends on `await` elsewhere, so the new `await` releases the actor's executor and cannot head-of-line-block other broker messages. It also must not move above the payload decode: doing so would let an unauthorized or malformed message drive a Sentinel IPC.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/ServiceBrokerExtensionProtocolTests
```

Expected: `** TEST SUCCEEDED **`, 0 failures. In particular `testCapabilityHandshakeIsExplicitAndDoesNotRequireRuntimeAuth` (`:10-34`) must still pass **unchanged** — it uses the default `.uds` and is the regression guard for "no behaviour change when Sentinel omits the field".

- [ ] **Step 6: Co-update the boundary document**

In `docs/service-broker-extension-boundary.md`, replace the `broker.capabilities` bullet (`:40-43`) with:

```markdown
- `broker.capabilities` is the explicit bridge handshake. After exact sender
  authorization and payload validation, the browser reads Sentinel's current
  `transport_mode` and answers `unsupported_message` when — and only when — that
  mode is exactly `legacy`; for `uds`, `full_uds`, an absent field, an
  unrecognised value, or a failed lookup it returns `protocolVersion: 1` without
  requiring account auth or Sentinel runtime resolution. This lets newer
  extensions distinguish an older browser from a supported broker before
  selecting a business transport, and lets Sentinel's staged rollout withdraw
  the broker path from every maintained extension at once. The mode is re-read
  on every handshake and is never cached with the negotiated runtime, so a
  `uds` to `legacy` switch converges on the next handshake. The legacy answer is
  recorded as `ServiceBrokerFallbackReason.protocolUnsupported`, whose
  `allowsLoopback` is true; no other transport-mode value permits fallback.
```

Then insert this subsection immediately before `## Request and channel lifecycle` (`:45`):

```markdown
### Transport-mode compatibility

| Sentinel reports | Browser answer to `broker.capabilities` | Extension transport |
| --- | --- | --- |
| `transport_mode` absent (every Sentinel released before the staged rollout) | `protocolVersion: 1` | Native broker, unchanged |
| `transport_mode: "uds"` | `protocolVersion: 1` | Native broker |
| `transport_mode: "full_uds"` | `protocolVersion: 1` | Native broker |
| `transport_mode: "legacy"` | `unsupported_message` | `getServiceExports` plus direct loopback HTTP and WebSocket |
| an unrecognised `transport_mode` value | `protocolVersion: 1` | Native broker |
| the `getComponentExports` lookup failed (Sentinel not running, socket missing, timeout) | `protocolVersion: 1` | Native broker, which then fails on its own terms |

An older browser, which never reads `transport_mode`, keeps answering
`protocolVersion: 1` against a `legacy` Sentinel; that stays correct because a
`legacy` Sentinel still runs the broker and every managed service still listens
on both its socket and loopback. Browser and Sentinel therefore ship
independently in either order.
```

- [ ] **Step 7: Commit**

```bash
git add Sources/Networking/ServiceBroker/ServiceBrokerExtensionProtocol.swift Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerExtensionProtocolTests.swift docs/service-broker-extension-boundary.md
git commit -m "feat(service-broker): answer the capability handshake as unsupported in legacy transport mode"
```

---

### Task 3: Whole-target verification

**Files:** none modified. This task is a gate, not a change; it produces the evidence that nothing else in the app or the test target regressed.

**Interfaces:**
- Consumes: the committed state after Tasks 1 and 2.
- Produces: nothing. If any step fails, stop and report the failure rather than patching over it.

- [ ] **Step 1: Run every test that touches this boundary**

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' \
  -only-testing:PhiBrowserTests/SentinelTransportModeTests \
  -only-testing:PhiBrowserTests/ServiceBrokerExtensionProtocolTests \
  -only-testing:PhiBrowserTests/ServiceBrokerClientTests \
  -only-testing:PhiBrowserTests/ServiceBrokerChannelStoreTests \
  -only-testing:PhiBrowserTests/ServiceBrokerWebSocketTests \
  -only-testing:PhiBrowserTests/ServiceBrokerSocketPathTests
```

Expected: `** TEST SUCCEEDED **`, 0 failures. This is the narrowest command that both compiles the app target and runs these tests — `xcodebuild test` builds `Phi` and `PhiBrowserTests` before running, so it is also a compile check of every source file this plan touched.

- [ ] **Step 2: Build the whole app and test targets**

```bash
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS'
```

Expected: `** TEST BUILD SUCCEEDED **`. This catches any other caller of `getComponentExports()` or of the changed initialiser that lives outside the ServiceBroker tests.

- [ ] **Step 3: Confirm the change set is exactly what was intended**

```bash
git status --short
git log --oneline origin/release/2.8.0..HEAD
git diff --stat origin/release/2.8.0..HEAD
```

Expected: a clean working tree; exactly two commits, each a single conventional line with no body and no trailer; the diff touches only `Sources/Application/SentinelIPCClient.swift`, `Sources/Networking/PhiAgentEndpointResolver.swift`, `Sources/Networking/ServiceBroker/ServiceBrokerExtensionProtocol.swift`, `Sources/Notifications/MessageCard/ExtensionMessageRouter.swift`, `Tests/PhiBrowserTests/SentinelTransportModeTests.swift`, `Tests/PhiBrowserTests/ServiceBroker/ServiceBrokerExtensionProtocolTests.swift`, `docs/service-broker-extension-boundary.md`, and this plan. **`Phi.xcodeproj/project.pbxproj` must not appear.**

- [ ] **Step 4: Report the wire-shape assumption for reconciliation**

State in the completion report which placement(s) the decoder accepts (envelope root and exports object, absent ⇒ `uds`, unrecognised ⇒ `uds`) so the Sentinel plan's chosen placement can be checked against it. If Sentinel chose something neither branch reads, the fix is `SentinelIPCClient.transportMode(fromResponse:)` alone — one function, plus its fixtures in `Tests/PhiBrowserTests/SentinelTransportModeTests.swift`.

---

## Manual smoke check (optional, needs a local Sentinel)

Not part of the task gates; run it once before merging if a Canary build is available.

1. Build and run Canary (`PhiBrowser-canary`), signed in, with Sentinel running in `uds` mode. From a Sidecar extension context, send `broker.capabilities` and confirm `{"ok":true,"result":{"protocolVersion":1}}`.
2. Put Sentinel in `legacy` mode (its canary env override `SENTINEL_LOCAL_SERVICE_TRANSPORT_MODE=legacy`, or its local `state/local-service-transport.json`), restart Sentinel, and send `broker.capabilities` again **without restarting the browser**. Expect `{"ok":false,"error":{"code":"unsupported_message",…}}` on the very next handshake — this is the proof that the mode is not cached for the account lifetime.
3. Quit Sentinel entirely and send `broker.capabilities`. Expect `protocolVersion: 1` again (lookup failure keeps today's behaviour), and expect the following `broker.http.request` to fail with `upstream_error`, as it does today.
