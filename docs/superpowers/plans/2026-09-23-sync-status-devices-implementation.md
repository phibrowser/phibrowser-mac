# Sync Status and Devices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the Sync pane with trustworthy native/Chromium progress, supported-content details, joined devices, and actionable approval/recovery states.

**Architecture:** Report metadata-only status through the existing engine and Chromium adapter boundaries, then derive the pane's presentation in its existing view model. Add the already-shipped device-list API to KeyEnvelopeAPIClient. No status polling may initiate data sync or bypass the pairing prerequisite from Part 1.

**Tech Stack:** Swift/SwiftUI, XCTest, Objective-C++, Chromium SyncService, existing key REST backend.

**Spec:** [Sync settings and resumable setup](../specs/2026-09-23-sync-ux-design.md)

## Global Constraints

- Name the settings pane **Sync**, replacing the visible Devices title.
- Treat unfinished pairing as **Not paired**: all data sync remains not started, including settings and Chromium Profile data, until pairing completes.
- An unavailable status remains unknown/checking; it must not appear as Up to date.
- The success timestamp refers to this Mac's work, not proof that every other device received it.
- Profile mapping is not equivalent to full Profile metadata sync.
- No master on/off toggle, per-category toggles, recovery-code replacement, remote-device removal, cloud-data deletion, or new conflict-resolution policy is included.
- Do not create another global state container or a parallel sync coordinator.
- Keep existing AuthManager ownership, key-backend client ownership, semantic localization keys, and English-only new catalog entries.
- Chromium source/build work is restricted to `/Users/elmer/workspace/phinomenon/chromium/src` and its existing build directories.
- Product commits, pushing, packaging for distribution, and deployment require their applicable task authorization; this plan does not authorize production deployment.

## Review Focus

- Empty device response, failed request, and a response from the previous account are distinct states (Task 1).
- A pull succeeded but a later commit/cursor save failed: the top card must not say Up to date (Task 2).
- Full Chromium sync returns an empty result from an API intended for transport-only migration: it must not be mistaken for zero pending uploads (Task 3).
- A framework lacks the new optional status method, or a Profile unloads during a query: show Checking, never success or a crash (Tasks 3/4).
- A new local edit arrives during a status refresh/debounce: an older success snapshot cannot overwrite pending work (Tasks 2/4).

## Prerequisites and source evidence

Execute after [Part 1](2026-09-23-sync-pairing-implementation.md) establishes
durable enrollment and a working explicit setup flow. Part 1 provides
`ProfilePairingGate.isPaired`, fresh setup entry, and all-sync startup gating.

Inspected baselines: Mac `745d705b`, sync-service `d49cf41`, Chromium
`6444c953bfb97`. Server implementation already has `GET /keys/v1/devices` in
`internal/transport/keys_handler.go`, backed by account-scoped storage. No server
feature change is needed for the agreed list. The response has no last-seen time.

Chromium's `SyncService::GetTypesWithUnsyncedData` returns an empty result in
full-sync mode by design. Do not use it as proof that uploads completed. Its
underlying DataTypeManager count path supports querying controller work; Task 3
exposes a narrow Phi status method without changing the original API contract.

### File structure

| File | Responsibility |
| --- | --- |
| `Sources/Sync/SyncStatusSnapshot.swift` (new) | Immutable status facts and pure presentation reduction |
| `Sources/Sync/Phi/PhiSyncEngine.swift` | Native round completion and pending-work facts |
| `Sources/ChromiumBridge/ChromiumSyncStatus.swift` (new) | Optional bridge availability, payload decoding, account/generation fences |
| Existing Devices ViewModel/View/HostingController | Account-scoped status consumption, devices, and presentation |
| `Sources/Sync/Keys/KeyEnvelopeAPIClient.swift` | Device-list DTO/transport in the existing backend client |
| Chromium SyncService and PhiChromiumBridge | Full-sync pending-data query and metadata-only status translation |

Register new native files in `Phi.xcodeproj/project.pbxproj`; register new
Chromium test sources in their existing GN targets. Do not reorganize folders
or rename all Devices classes merely to change the visible title.

## Verification commands

Use the build-for-testing and isolated hosted-test rules in Part 1. New pure
status tests also run without the Phi host:

```sh
bash build-scripts/test-sync-status.sh
bash build-scripts/test-sync-invalidation.sh
```

For Chromium, reuse the existing build tree. Build the relevant target before
running it; an old unit_tests binary does not verify new source:

```sh
autoninja -C /Users/elmer/workspace/phinomenon/chromium/src/out/PhiRelease unit_tests
/Users/elmer/workspace/phinomenon/chromium/src/out/PhiRelease/unit_tests --gtest_filter='PhiSyncStatusTest.*:PhiSyncServiceImplTest.*:PhiSyncLifecycleTest.*'
```

Check the existing build configuration/available target at execution. If a full
target cannot be built, record the restriction and separately report compilation
and executed focused tests; do not call a translation-unit compile a test pass.
Framework/native integration and two-Mac acceptance require matched artifacts.

### Task 1: Read authorized devices from the existing backend

**Files:** Modify `Sources/Sync/Keys/AccountKeyManager.swift`, `KeyEnvelopeAPIClient.swift`, `DeviceApprovalService.swift`, `Sources/UserInterface/Preferences/Devices/DevicesSettingViewModel.swift`; tests `Tests/PhiBrowserTests/Sync/Keys/KeyEnvelopeAPIClientTests.swift`, `DevicesSettingViewModelTests.swift`, and all existing KeyEnvelopeAPI fakes including `AccountKeyManagerTests.FakeAPI` and the preview fake in `KeyLayerViewModel.swift`.

**Interfaces:**
- `KeyEnvelopeAPI.listDevices() async throws -> [AccountDeviceDTO]`.
- `DeviceApprovalService.listDevices() async throws -> [AccountDeviceDTO]` forwards to the same account-bound client.
- ViewModel adds `devices`, `devicesLoadError`, and a load generation; approved requests and known devices remain distinct collections.

- [ ] Add URLProtocol tests to the existing API test factory. Include active,
  revoked, fractional-date, unknown-field, empty-list, failed-request, and nil-token
  cases; the client should ignore unused public_key fields rather than expose them.

```swift
func testListDevicesUsesTheExistingAccountEndpoint() async throws {
    StubURLProtocol.handler = { req in
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/keys/v1/devices")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer stub-token")
        return (200, Data(#"[{"device_key_id":"dev-a","name":"Mac A","platform":"macos","status":"active","created_at":"2026-09-23T01:00:00Z"}]"#.utf8))
    }
    let rows = try await makeClient().listDevices()
    XCTAssertEqual(rows.map(\.deviceKeyID), ["dev-a"])
}
```

- [ ] Implement the DTO using the existing decoder conventions and
  `KeyEnvelopeAPIClient.parseRFC3339`, which handles the service's fractional
  timestamps. Required fields are identity/name/platform/status/created_at;
  revoked_at is optional. Unknown fields are ignored; malformed required fields
  fail the list rather than invent identities.

```swift
struct AccountDeviceDTO: Decodable, Equatable, Identifiable {
    let deviceKeyID: String
    let name: String
    let platform: String
    let status: String
    let createdAt: Date
    let revokedAt: Date?
    var id: String { deviceKeyID }
    private enum CodingKeys: String, CodingKey {
        case deviceKeyID = "device_key_id", name, platform, status
        case createdAt = "created_at", revokedAt = "revoked_at"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceKeyID = try c.decode(String.self, forKey: .deviceKeyID)
        name = try c.decode(String.self, forKey: .name)
        platform = try c.decode(String.self, forKey: .platform)
        status = try c.decode(String.self, forKey: .status)
        guard !deviceKeyID.isEmpty,
              let created = KeyEnvelopeAPIClient.parseRFC3339(
                try c.decode(String.self, forKey: .createdAt)) else {
            throw KeyAPIError.decode
        }
        createdAt = created
        if let raw = try c.decodeIfPresent(String.self, forKey: .revokedAt) {
            guard let date = KeyEnvelopeAPIClient.parseRFC3339(raw) else {
                throw KeyAPIError.decode
            }
            revokedAt = date
        } else {
            revokedAt = nil
        }
    }
}

func listDevices() async throws -> [AccountDeviceDTO] {
    let (status, data) = try await request("GET", "/keys/v1/devices")
    guard status == 200 else {
        throw KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
    }
    return try JSONDecoder().decode([AccountDeviceDTO].self, from: data)
}
```

- [ ] Forward through DeviceApprovalService and load in the existing pane
  lifecycle. Compare identity with the current device key ID, never its display
  name. Render active records as joined devices; exclude revoked records from
  that list. Treat unknown status values as unknown, not active. Keep the current
  device visible from local identity with a load-error explanation if the remote
  list is unavailable; do not invent an account device record.
- [ ] Refresh after approval/removal and pane appearance. Reuse the existing
  lifecycle-managed refresh cadence; do not add an independent global timer.
  Only the latest generation and bound account can update the list. Pending
  approval polling remains independently actionable and request-specific.
- [ ] Test failure versus empty, duplicate display names, revoked current ID,
  sign-out during load, rapid pane reopen, and independent approve/deny busy state.
  Compile all API conformers so a missing fake method cannot escape the test build.

### Task 2: Publish accurate native sync facts

**Files:** Create `Sources/Sync/SyncStatusSnapshot.swift`, `Tests/PhiBrowserTests/Sync/Phi/SyncStatusSnapshotTests.swift`, `Tests/SyncStatus/main.swift`, `build-scripts/test-sync-status.sh`. Modify `Sources/Sync/Phi/PhiSyncEngine.swift`, `Sources/ChromiumBridge/PhiChromiumCoordinator.swift`, `Tests/PhiBrowserTests/Sync/Phi/PhiSyncEngineLifecycleTests.swift`, `PhiSyncMarkerBoundaryTests.swift`, `PhiSyncEngineOwnedItemsTests.swift`, `Phi.xcodeproj/project.pbxproj`.

**Interfaces:**
- `SyncContextPhase: String, Codable, Sendable` cases `checking`, `initialSync`, `syncing`, `upToDate`, `offline`, `needsAttention`.
- `SyncContextSnapshot: Equatable, Sendable` fields `id: String`, `phase: SyncContextPhase`, `lastSuccess: Date?`, `revision: UInt64`.
- `SyncSummaryPhase` adds `notStarted` to the same display cases.
- `SyncStatusSummary.reduce(paired:requiredIDs:snapshots:) -> SyncStatusSummary`; result holds `phase` and `lastSuccess`.
- Engine takes `onStatus: @Sendable (SyncContextSnapshot) -> Void`, default no-op. Coordinator forwards on the main actor only if its captured engine/account is still current.

- [ ] Add pure truth-table assertions before wiring UI. All required contexts
  must be represented. Unpaired overrides any stale successful snapshot.

```swift
let ok = SyncContextSnapshot(id: "phi", phase: .upToDate,
                             lastSuccess: Date(timeIntervalSince1970: 100), revision: 1)
XCTAssertEqual(SyncStatusSummary.reduce(paired: false,
    requiredIDs: ["phi"], snapshots: [ok]).phase, .notStarted)
XCTAssertEqual(SyncStatusSummary.reduce(paired: true,
    requiredIDs: ["phi", "profile-a"], snapshots: [ok]).phase, .checking)
let bad = SyncContextSnapshot(id: "profile-a", phase: .needsAttention,
                              lastSuccess: nil, revision: 2)
XCTAssertEqual(SyncStatusSummary.reduce(paired: true,
    requiredIDs: ["phi", "profile-a"], snapshots: [ok, bad]).phase, .needsAttention)
```

  Implement reduction precedence: notStarted; any known needsAttention; missing
  or checking required contexts; offline; initialSync; syncing; then upToDate.
  Preserve each context's detail regardless of the top state. Show the minimum
  last-success time across required contexts only when all have one. Empty or
  absent requiredIDs means checking, never vacuous global success.

- [ ] Add a pure round-completion value and exact completion predicate:

```swift
struct SyncRoundCompletion: Equatable, Sendable {
    let pullDrained: Bool
    let outboundAccepted: Bool
    let persistenceSucceeded: Bool
    let pendingInbound: Bool
    let pendingOutbound: Bool
    let followupQueued: Bool
    var succeeded: Bool {
        pullDrained && outboundAccepted && persistenceSucceeded
            && !pendingInbound && !pendingOutbound && !followupQueued
    }
}
```

  The executable hostless runner compiles this production file and exercises
  every false predicate, a missing context, older revision, empty context set,
  and minimum timestamp. Do not duplicate the reducer implementation in tests.

- [ ] Instrument the existing serialized rounds and durable apply/commit results.
  A successful GetUpdates or `RoundOutcome.ok` alone cannot set lastSuccess:
  evaluate final accepted outbound work, write failures, unreadable/parked inbound
  content, pending projections and pagination continuation. A preview produces
  no sync-success event. Actual unreadable/failed content is needsAttention;
  work with a known continuation stays syncing/initialSync. Preserve the last
  historical success on a new failure while showing the failure phase.
- [ ] Track monotonically increasing status revision within the engine/account
  lifetime. Mark local work pending before a debounced operation can be presented
  as completed; use the existing local-change subscriptions to mark the pane's
  context dirty immediately, then let real engine completion clear it. An older
  callback cannot clear a newer pending change. Do not create a status-owned
  push loop or change merge/stamp ordering.
- [ ] Add behavioral tests using the current engine fakes for: successful pull
  plus rejected commit, cursor-save failure, paginated followup, parked unreadable
  entity, invalidation request without data completion, new edit after last
  success, and old-account completion. Assert status alongside actual writes.
  Run hostless status/invalidation checks and isolated focused engine suites.

### Task 3: Expose trustworthy Chromium Profile status

**Files:** In the sole Chromium checkout modify `components/sync/service/sync_service.h`, `sync_service.cc`, `sync_service_impl.h`, `sync_service_impl.cc`, `sync_service_impl_unittest.cc`; modify `chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.mm`, `PhiChromiumBridgeHeader.h`, `BUILD.gn`; create `phi_sync_status_unittest.mm` in that bridge directory and register it in `chrome/test/BUILD.gn`. In Mac modify `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h` and create `Sources/ChromiumBridge/ChromiumSyncStatus.swift` with its decoding tests under `Tests/PhiBrowserTests/Sync/Keys/ChromiumSyncStatusTests.swift`.

**Interfaces:**
- New optional bridge method `getProfileSyncStatus:completion:` takes local Profile ID and returns a dictionary or a fixed safe error code.
- Payload version 1: `version`, `phase`, `last_success_ms` (optional), `enabled_categories` (string array). Categories are product names derived from enabled controllers, never arbitrary UI claims.
- New virtual `SyncService::GetPendingDataTypesForPhiStatus(base::OnceCallback<void(std::optional<DataTypeSet>)>)`; default returns nullopt. SyncServiceImpl overrides it using the controller count path in full-sync mode.
- Swift adapter `ChromiumSyncStatus.read(profileID:) async -> ChromiumProfileSyncSnapshot` decodes known versions and maps absent selector/invalid payload to checking. `ChromiumProfileSyncSnapshot` has `status: SyncContextSnapshot` and `enabledCategories: [String]`; unavailable capability data uses an empty array with checking status. The adapter is owned by the pane/coordinator, not a new singleton.

- [ ] Add a SyncServiceImpl regression that runs in full-sync mode with one
  active datatype's controller reporting unsynced items. The new method must
  return that type. Existing GetTypesWithUnsyncedData must retain its transport-
  migration contract. Also cover controller shutdown and an unavailable manager.

```cpp
void SyncService::GetPendingDataTypesForPhiStatus(
    base::OnceCallback<void(std::optional<DataTypeSet>)> callback) {
  std::move(callback).Run(std::nullopt);
}
```

  Add `uint64_t phi_status_generation_ = 0` to SyncServiceImpl. Increment it in
  `ConfigureDataTypeManager`, `OnEngineInitialized`, `StopAndClear`, and `Shutdown`
  before their lifecycle transition. Use the existing weak_factory_ for lifetime:

```cpp
void SyncServiceImpl::GetPendingDataTypesForPhiStatus(
    base::OnceCallback<void(std::optional<DataTypeSet>)> callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (GetTransportState() != TransportState::ACTIVE || !data_type_manager_) {
    std::move(callback).Run(std::nullopt);
    return;
  }
  DataTypeSet types = GetActiveDataTypes();
  types.Remove(NIGORI);
  data_type_manager_->GetTypesWithUnsyncedData(
      types, base::BindOnce(
          [](base::WeakPtr<SyncServiceImpl> service, uint64_t generation,
             DataTypeSet queried_types,
             base::OnceCallback<void(std::optional<DataTypeSet>)> done,
             absl::flat_hash_map<DataType, size_t> counts) {
            if (!service || service->phi_status_generation_ != generation ||
                service->GetTransportState() != TransportState::ACTIVE) {
              std::move(done).Run(std::nullopt);
              return;
            }
            DataTypeSet current = service->GetActiveDataTypes();
            current.Remove(NIGORI);
            if (current != queried_types) {
              std::move(done).Run(std::nullopt);
              return;
            }
            DataTypeSet pending;
            for (const auto& [type, count] : counts) {
              if (count > 0) pending.Put(type);
            }
            std::move(done).Run(pending);
          }, weak_factory_.GetWeakPtr(), phi_status_generation_, types,
          std::move(callback)));
}
```

  NIGORI is handled by encryption/cycle state, not this controller query
  (DataTypeManager CHECKs on NIGORI). Missing/disabled expected controllers must
  not be treated as successfully synchronized; bridge phase reduction also checks
  initial downloads and configuration/crypto errors. Add a bounded native query
  timeout that returns checking if teardown prevents a framework callback.

- [ ] Derive a Profile status from live transport/auth/encryption state, the last
  initialized cycle, current initial-download state, detailed syncing/backoff/
  throttling facts, and the new pending-data query. Do not use last-cycle absence
  as an empty successful cycle. The success predicate must include:

```cpp
const bool clean_cycle = snapshot.is_initialized() &&
    !syncer::HasSyncerError(snapshot.model_neutral_state()) &&
    !snapshot.has_remaining_local_changes() &&
    !snapshot.is_silenced();
```

  It also requires active transport, no auth/crypto/controller failure, completed
  initial download, no current cycle/backoff/throttle, a known empty live pending
  set, and an actual success timestamp. Re-check current service/configuration
  after the async query. Unknown facts produce checking, not success. Observe
  current change/cycle revision so new work invalidates an older completion.

- [ ] Implement the bridge on the UI sequence. Resolve an existing loaded
  user-assignable Profile without creating a Profile or SyncService merely to
  display status. Exclude PhiChat and OTR. A missing/unloaded service returns
  checking. Never retain a raw Profile pointer across an asynchronous wait.
  Check `SyncServiceFactory::HasSyncService(profile)` before using
  `SyncServiceFactory::GetForProfile(profile)` on the same UI-sequence callout;
  GetForProfile by itself can create the service.
  Limit errors and payloads to status metadata; no URL, title, key, or account
  token leaves the integration layer.
- [ ] Keep native and framework header signatures identical. Guard the optional
  selector with `responds(to:)`. In the Swift adapter, validate version and phases,
  epoch-millisecond dates, and captured account/load generation. Add payload tests
  for absent selector, malformed/future payload, no timestamp, profile deletion,
  partial failure, and stale account callback.

```objc
- (void)getProfileSyncStatus:(NSString *)profileId
                 completion:(void (^)(NSDictionary<NSString *, id> * _Nullable status,
                                      NSString * _Nullable error))completion
    NS_SWIFT_NAME(getProfileSyncStatus(_:completion:));
```

  Assign increasing request revisions per Profile within the native adapter's
  account lifetime and discard older query responses. Return the enabled category
  list alongside status so the pane does not query or infer capabilities itself.
- [ ] Build and execute the named Chromium suites in the existing build tree.
  Compile native tests with the matching header; test an older framework path
  that reports checking. Document the bridge contract and do not claim runtime
  status works in a distributed build until a matching framework is loaded.

### Task 4: Compose the Sync pane from account-bound facts

**Files:** Modify `Sources/UserInterface/Preferences/Devices/DevicesSettingView.swift`, `DevicesSettingViewModel.swift`, `DevicesSettingHostingViewController.swift`, `DevicesRemoveDeviceModel.swift`; `Sources/ChromiumBridge/PhiChromiumCoordinator.swift`; `Resources/Localizable.xcstrings`; tests `DevicesSettingViewModelTests.swift`, `DevicesSettingRemoveDeviceTests.swift`, and `SyncStatusSnapshotTests.swift`.

**Interfaces:**
- Consumes Part 1's `isPaired`/setup actions, Task 1's devices, and Tasks 2/3 snapshots.
- Add `acceptStatus(_:generation:)` to the existing pane ViewModel. Snapshot IDs/revisions are scoped to its current account generation.
- The coordinator supplies existing native facts and user-assignable Profile IDs; UI does not query storage/Chromium internals to infer them.

- [ ] Add view-model tests that feed snapshots and device responses in adversarial
  order. Test previous-account response, missing Profile, a new Profile while
  pane is open, successful native context with failed Chromium context, older
  revision after a local edit, and an unpaired device carrying stale success.
  Use the pure reducer's truth table rather than duplicate status rules in View.
- [ ] Render the four agreed sections using current settings cards/spacing:
  account + status, read-only sync contents, devices with conditional requests,
  recovery/removal. Keep status position stable; routine work updates a small
  detail line instead of flashing the page. Show actionable errors next to the
  relevant context/request, plus a partial-status explanation at the top.
- [ ] Refresh status only while the pane is visible, on relevant native events,
  and through the existing pane refresh lifecycle. Cancel on disappear/account
  rebind. Queries are read-only and must not start engines. Do not let an
  unpaired device request ordinary status work that implicitly initializes a
  service; its summary is notStarted from enrollment.

```swift
func acceptStatus(_ snapshot: SyncContextSnapshot, generation: UInt64) {
    guard generation == loadGeneration else { return }
    if let old = contextSnapshots[snapshot.id], old.revision > snapshot.revision { return }
    contextSnapshots[snapshot.id] = snapshot
}
```

  The ViewModel owns `loadGeneration: UInt64` and
  `contextSnapshots: [String: SyncContextSnapshot]`. Increment/clear both on
  rebind. Revision ordering is per context; do not compare unrelated engines'
  revisions. Recompute required IDs when user-assignable Profiles change.
- [ ] Populate device name/type/This Mac from actual identities. Omit recent
  activity because the existing endpoint supplies only creation/revocation time.
  Do not label a registered device online. Keep request verification prominent,
  request-specific busy indicators, expiry, safe retry, and no empty request card.
- [ ] Present supported Phi categories and bridge-reported Chromium categories.
  Unknown framework support uses a disclosure instead of asserting sync. Explain
  current exclusions and ordinary-tabs versus pins. Add recovery method guidance
  without View code/Regenerate code actions. Keep removal separate from login,
  pairing deferral, and data deletion, with existing last-device refusal.
- [ ] Add English semantic catalog entries, preserve translations, and verify
  accessibility labels/focus. Use the existing synchronous removal confirmation
  safely; its copy says local data remains, rejoining needs verification, and
  this device stops participating. Do not introduce raw diagnostic errors.
- [ ] Execute focused view-model/removal/status tests and manually inspect all
  eight top-level spec states plus partial errors with long names and many devices.

### Task 5: Matched-build and two-Mac acceptance

**Files:** Modify `docs/sync.md`, `docs/sync-e2e-test-cases.md`; update both plan task checkboxes only as actual work is completed. Update the company sync product note with final implementation references when verified.

**Interfaces:** Uses the completed native app, matching framework, and existing service; no new deployment API or release authorization.

- [ ] Run hostless pairing/status/invalidation suites and the convergence harness
  once against the completed native changes. Run build-for-testing and inspect
  package-resolution changes before attributing any build diff to this task.
  Run the isolated hosted suites where available and the rebuilt Chromium tests.
- [ ] On disposable staging accounts and two isolated Macs, record native,
  framework, and service versions. Test the following sequence:

```text
A: initialize -> save recovery code -> complete pairing -> initial sync -> up to date
B: approve join -> defer pairing -> edit local settings/bookmark/history
A: change a Space name and create another Space
B: restart -> confirm not paired and no data sync -> open Sync -> fresh server data
B: disconnect network -> reopen pairing -> error and Later, no cached candidates
B: reconnect -> pair -> inspect updated overwrite review -> complete -> sync
A+B: verify correct identities/content and per-context status; remove B and rejoin
```

  While B is unpaired, verify no settings/Space/owned-data publication or landing
  and no Chromium sync requests, apart from explicit read-only setup preview.
  Verify approval/device lists independently of data-sync success.
- [ ] Inject an expired sign-in, one failed Chromium context, native commit
  failure, cursor-save failure, unreadable remote data, delayed preview, and a
  late previous-account response. The pane must explain action and scope without
  false global success, stale matching, a blocked browser, or account leakage.
- [ ] Check older-framework compatibility, last-device defer/removal refusal,
  keyboard/Escape/default-action behavior, VoiceOver, and visible status without
  opening settings on the other Mac. Do not claim manual cases passed merely
  because their automated counterparts compile.
- [ ] Review the final diff against spec coverage and all changed boundaries.
  Update sync docs with enrollment ordering, fresh preview semantics, the
  device-list contract, status definitions, and compatibility requirements.
  Keep accepted but unexecuted cases explicitly Not run. Do not push, merge,
  distribute, or deploy product artifacts without the corresponding instruction.

## Coverage and completion

Part 1 owns initial setup, fresh pairing, persistence, and all-sync gating.
Tasks 1/4 here implement Devices; Tasks 2/3/4 implement status and content scope;
Task 4 finishes recovery/removal presentation; Task 5 verifies spec acceptance
11-12 together with all cross-device invariants. The combined work is complete
only with honest evidence for both native and framework runtime behavior.
