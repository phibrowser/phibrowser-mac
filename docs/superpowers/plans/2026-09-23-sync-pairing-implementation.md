# Sync Pairing and Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep every sync context stopped until durable pairing completion, with fresh, dismissible setup that users can resume from Sync settings.

**Architecture:** Extend the existing ProfilePairingGate enrollment lifecycle rather than add a global coordinator. Native sync scheduling and Chromium key availability consume the same completion prerequisite; the existing wizard owns fresh requests and confirmed mapping writes. Preserve the read-only account preview independently of ordinary sync rounds.

**Tech Stack:** Swift, SwiftUI, AppKit, AccountUserDefaults, XCTest, the existing Phi Chromium bridge.

**Spec:** [Sync settings and resumable setup](../specs/2026-09-23-sync-ux-design.md)

## Global Constraints

- Name the settings pane **Sync**, replacing the visible Devices title.
- Treat unfinished pairing as **Not paired**: all data sync remains not started, including settings and Chromium Profile data, until pairing completes.
- Fetch current server data on every entry to pairing. Previously fetched account data must not supply the new pairing session.
- Do not persist an old preview, unsubmitted choice draft, or overwrite approval for use on a later entry.
- No master on/off toggle, per-category toggles, recovery-code replacement, remote-device removal, cloud-data deletion, or new conflict-resolution policy is included.
- Do not create another global state container or a parallel sync coordinator.
- All repository code/comments/docs are English; production strings use semantic keys, English values, translator comments, and English-only new catalog entries.
- Preserve native run-loop safety and the existing pull-before-commit, account retirement, and identity boundaries.
- Follow repository commit approval rules: prepare reviewed changes, but do not create product-repository commits without explicit instruction.
- Work on Chromium only in `/Users/elmer/workspace/phinomenon/chromium/src`; no extra checkout, worktree, or copied build tree.

## Review Focus

- A restored account folder contains another device's completion marker: it must not authorize this device (Task 1).
- Key unlock arrives before the join UI advances: no native scheduling or Chromium key exposure can slip through (Task 2).
- The user closes a slow preview and reopens immediately: the old reply must not populate the new session (Task 3).
- Server/local Space attributes change while an overwrite review is visible: the previous review cannot authorize the new values (Task 4).
- Approval completes after the user switched to recovery or another account: exactly the active enrollment may advance (Task 5).

## Execution boundaries and source map

This is the first of two independently verifiable increments. The second plan
adds actual data status, the device list, and final pane presentation. This
increment exposes accurate Not paired/Continue setup and preserves existing
working settings content; it must not fabricate full sync status.

Source baseline: Mac `745d705b`; inspected framework source
`6444c953bfb97`. Refresh the Mac branch base from `origin/dev` at execution,
preserve the approved documents, and reconcile these sync-branch changes against
that base before editing product code. Do not drop sync prerequisites merely
because they are absent from a different base. Read both plans and the spec.

| File | Responsibility |
| --- | --- |
| `Sources/Sync/Keys/SyncPairingState.swift` (new) | Pure completion record, legacy-evidence classification, enrollment eligibility |
| `Sources/Sync/Keys/UI/ProfilePairingGate.swift` | Existing account-bound lifecycle and explicit presentation |
| `Sources/Sync/Keys/SyncKeyController.swift` | Withhold ready Profile keys until paired; preserve identity resolution |
| `Sources/ChromiumBridge/PhiChromiumCoordinator.swift` | Configure enrollment before unlock, activate schedules only after completion |
| `Sources/Sync/Phi/PhiSyncEngine.swift` | Reject ordinary work before pairing; preserve read-only preview |
| `Sources/Sync/Keys/UI/PairingWizardViewModel.swift` | Fresh sessions, stale-response fences, review/apply/completion ordering |
| `Sources/Sync/Keys/UI/KeyLayerViewModel.swift` | Unified setup transitions and operation-local errors |
| Existing Key UI and Devices view/controller files | Setup navigation, defer actions, and minimal Sync entry |

No new networking client, storage hierarchy, or window manager is introduced.

## Verification commands

Compile all affected hosted tests without launching the developer's browser:

```sh
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -configuration Debug-Canary -destination 'platform=macOS' -derivedDataPath /private/tmp/phi-sync-ux-derived CODE_SIGNING_ALLOWED=NO
```

On a dedicated QA login/machine with a correctly packaged test host, run the
focused suites using the same build settings:

```sh
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -configuration Debug-Canary -destination 'platform=macOS' -derivedDataPath /private/tmp/phi-sync-ux-derived -only-testing:PhiBrowserTests/SyncPairingStateTests -only-testing:PhiBrowserTests/ProfilePairingGateTests -only-testing:PhiBrowserTests/SyncKeyControllerTests -only-testing:PhiBrowserTests/PairingWizardViewModelTests -only-testing:PhiBrowserTests/KeyLayerViewModelTests -only-testing:PhiBrowserTests/PhiSyncEngineLifecycleTests
```

The existing hosted bundle can collide with a running Phi ProcessSingleton;
build-for-testing is not an execution pass. Do not stop the user's browser or
reset their data to obtain a test result. Use the production-source hostless
checks below locally and record unavailable hosted/manual runs explicitly.

```sh
bash build-scripts/test-sync-invalidation.sh
```

For every task: demonstrate the new behavioral assertion failing before its
implementation and passing afterwards in an executable harness where available.
Do not write tests that merely search for the new button text.

### Task 1: Persist an explicit device-bound pairing result

**Files:** Create `Sources/Sync/Keys/SyncPairingState.swift`, `Tests/PhiBrowserTests/Sync/Keys/SyncPairingStateTests.swift`, `Tests/SyncPairing/main.swift`, `build-scripts/test-sync-pairing.sh`. Modify `Sources/Sync/Keys/UI/ProfilePairingGate.swift`, `Sources/ChromiumBridge/PhiChromiumCoordinator.swift`, `Phi.xcodeproj/project.pbxproj`.

**Interfaces:**
- Produces `SyncPairingRecord`, `SyncPairingLegacyEvidence`, and `SyncPairingEligibility.isPaired(record:deviceKeyID:)`.
- Gate produces `isPaired: Bool`, `configureEnrollment(deviceKeyID:recordData:saveRecord:legacyEvidence:) throws`, `beginEnrollment() throws`, and `completeEnrollment() throws`.
- `saveRecord` has type `(Data) -> Bool`, bound to the captured account's existing `AccountUserDefaults.set(_:forKey:)`.
- Gate emits `.phiSyncPairingStateDidChange` only after durable state changes. No UI calls AccountUserDefaults directly.

- [ ] Add the pure record and regression assertions:

```swift
struct SyncPairingRecord: Codable, Equatable {
    let version: Int
    let deviceKeyID: String
    let paired: Bool
}

struct SyncPairingLegacyEvidence {
    let authorizedDeviceVerified: Bool
    let freshAccountMappingsVerified: Bool
    let explicitlyPending: Bool
    let spaceSectionEnabled: Bool
    let hasDrainedFullReplay: Bool
    let profileMappingsValid: Bool
    let spaceMappingsValid: Bool

    var provesCompletion: Bool {
        authorizedDeviceVerified && freshAccountMappingsVerified
            && !explicitlyPending && spaceSectionEnabled && hasDrainedFullReplay
            && profileMappingsValid && spaceMappingsValid
    }
}

enum SyncPairingEligibility {
    static func isPaired(record: SyncPairingRecord?, deviceKeyID: String) -> Bool {
        guard let record else { return false }
        return record.version == 1 && record.deviceKeyID == deviceKeyID && record.paired
    }
}

func testCompletionCannotMoveBetweenDevices() {
    let record = SyncPairingRecord(version: 1, deviceKeyID: "device-a", paired: true)
    XCTAssertFalse(SyncPairingEligibility.isPaired(record: record, deviceKeyID: "device-b"))
    XCTAssertTrue(SyncPairingEligibility.isPaired(record: record, deviceKeyID: "device-a"))
    XCTAssertFalse(SyncPairingEligibility.isPaired(record: nil, deviceKeyID: "device-a"))
}
```

- [ ] Create a hostless runner that compiles this production file and executes
  the same eligibility cases with `precondition`. Use a temporary build directory
  and module cache, as the existing invalidation script does:

```sh
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" Sources/Sync/Keys/SyncPairingState.swift Tests/SyncPairing/main.swift -o "$task_build/tests"
"$task_build/tests"
```

- [ ] Implement the gate methods with account-bound closures, record version 1,
  and the key `sync.pairingEnrollment`. Initialize memory fail-closed before any
  decode or migration. Each writer must encode/save successfully before updating
  memory or notifying. A failed save throws a typed persistence error and leaves
  keys/schedules unavailable. A new enrollment writes `paired: false` before
  bootstrap/recovery/approval can expose an ARK.

```swift
let candidate = SyncPairingRecord(version: 1, deviceKeyID: deviceKeyID, paired: true)
let data = try JSONEncoder().encode(candidate)
guard saveRecord(data) else { throw SyncPairingPersistenceError.writeFailed }
record = candidate
NotificationCenter.default.post(name: .phiSyncPairingStateDidChange, object: self)
```

  Define `enum SyncPairingPersistenceError: Error { case writeFailed }` in the
  pure state file. The gate retains `deviceKeyID`, `record`, and `saveRecord`
  from configuration; it does not resolve the current account again during a save.

- [ ] Migrate only demonstrably completed legacy enrollment. Read the old
  `sync.joinPairingPending` value and current-format Space table before engine
  construction. Require a drained, enabled Space state plus valid local mappings
  and an authorized current device envelope before persisting completion. Missing,
  corrupt, pending, wrong-device, unknown-version, and unresolved evidence stays
  unpaired. Do not treat an absent old Boolean as completion. Do not synthesize
  mappings or change IDs to make migration pass. Keep old data for diagnostics;
  the old Boolean is migration input only, not a second runtime authority.
  Only a genuinely absent enrollment record is eligible for legacy migration;
  a present invalid/mismatched record never falls through to the legacy branch.
  Configure fail-closed before unlock. For legacy candidates, verify the device
  envelope and fetch current Profile/Space metadata through the read-only setup
  paths before completing migration. A local table alone is not completion proof.
  No startup schedule runs while that verification is in flight. An unverified
  legacy device remains usable locally and can finish through normal setup.
- [ ] Extend state tests for every failed predicate, corrupt JSON, future version,
  restored folder on another key ID, rejected completion write, and a verified
  legacy device. Run `bash build-scripts/test-sync-pairing.sh`, compile hosted
  suites, and review the migration diff before proceeding.

### Task 2: Apply the prerequisite to both native and Chromium sync

**Files:** Modify `Sources/Sync/Keys/SyncKeyController.swift`, `Sources/Sync/Phi/PhiSyncEngine.swift`, `Sources/ChromiumBridge/PhiChromiumCoordinator.swift`, `Sources/Sync/Keys/UI/ProfilePairingGate.swift`, existing tests in `Tests/PhiBrowserTests/Sync/Keys/SyncKeyControllerTests.swift`, `Tests/PhiBrowserTests/Sync/Phi/PhiSyncEngineLifecycleTests.swift`, and `Tests/SyncInvalidation/SpaceGateFixture.swift`.

**Interfaces:**
- Consumes `ProfilePairingGate.isPaired` and `.phiSyncPairingStateDidChange`.
- Add `isPairingComplete: @MainActor () -> Bool` to SyncKeyController injection.
- Add `pairingComplete: Bool` to PhiSyncEngine initialization and actor method `enableAfterPairing()`; production defaults fail closed.
- Preserve the existing `profileSyncInfo(forProfileId:)` return type and Chromium delegate contract.

- [ ] Extend `makeController` in its existing test file with an injectable
  `isPairingComplete` closure. Existing ready-device tests explicitly inject
  `{ true }`. Add this race regression using its current FakeAPI/factory:

```swift
func testResolvedKeysStayHiddenUntilPairingCompletes() async throws {
    let api = FakeAPI()
    let provider = FakeDeviceKeyProvider()
    _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
    var paired = false
    let (controller, _) = makeController(
        api: api, provider: provider, locals: [("Default", "Default")],
        isPairingComplete: { paired })
    _ = try await controller.manager.unlockAtStartup()
    _ = try await controller.profileKeys.registerLocalProfile(
        profileId: "Default", displayName: "Default")
    await controller.silentUnlockAndResolve()
    XCTAssertNil(controller.profileSyncInfo(forProfileId: "Default"))
    paired = true
    XCTAssertNotNil(controller.profileSyncInfo(forProfileId: "Default"))
}
```

- [ ] Put the key guard on the synchronous bridge-facing accessor, not on
  account identity and not on bearer-token delivery:

```swift
func profileSyncInfo(forProfileId profileId: String) -> (uuid: String, passphrase: String)? {
    guard isPairingComplete() else { return nil }
    return resolved[profileId]
}
```

  Never forge sign-out to hold sync: the existing framework withdraws an
  unavailable key without clearing metadata. Verify the existing framework tests
  `PhiSyncServiceImplTest.GateBlocksSyncUntilTheKeyIsReady` and
  `PhiSyncLifecycleTest.KeyLossStopsEngineAndPreservesMetadata` on the matching
  build when executing; native tests alone cannot establish framework behavior.

- [ ] Guard all ordinary engine rounds, including direct calls that bypass
  scheduling. The existing preview remains read-only:

```swift
guard !isStopped else { return }
if !pairingComplete {
    guard case .preview = round else { return }
}
```

  Apply this before resetting round counters or invoking any projection/landing.
  Guard retention methods that can run outside `run(_:)` too. Add engine fixture
  tests that call pull, push, local-settings/Space/owned-change and retention paths
  while unpaired: assert zero getUpdates/commit for ordinary work, no landing,
  and unchanged marker/cursor bytes. Preview must issue a request and leave those
  bytes unchanged. Enabling then pulling must exercise the real initial round.

- [ ] Configure enrollment before constructing unlock observers or calling
  `silentUnlockAndResolve`. In `startPhiSyncIfReady` require the captured gate's
  paired result, account match, and ARK. On completion, await
  `engine.enableAfterPairing()`, refresh the Space gate, then start invalidation
  and subscriptions and notify Chromium. Re-check engine/controller identity
  after each await. Repeated completion notifications must start exactly one
  scheduler. Preview-only construction must not subscribe to wake/local changes.
- [ ] Remove runtime Boolean writes that previously cleared pending solely
  because Profile candidates disappeared. Only completeEnrollment after full
  validation can release startup. Keep paired-device runtime auto-discovery;
  runtime unreadable objects produce status, not forced reenrollment.
  While unpaired, background resolveMappings must resolve existing mappings
  without auto-registering/adopting new choices. Move those existing mutations
  behind the explicit, confirmed setup path, including its no-manual-choice
  first-device case. Tests for ordinary paired runtime resolution inject true.
- [ ] Run the hostless invalidation and pairing runners, compile all affected
  tests, and run the focused suites on the isolated test host. Update
  `docs/sync.md` to distinguish setup preview from all normal data sync.

### Task 3: Explicit presentation, fresh entry, and Finish later

**Files:** Modify `Sources/Sync/Keys/UI/ProfilePairingGate.swift`, `Sources/Sync/Keys/UI/PairingWizardViewModel.swift`, `Sources/Sync/Keys/UI/PairingWizardView.swift`, `Sources/Sync/Keys/UI/KeyLayerViewModel.swift`, `Sources/Sync/Keys/KeyEnvelopeAPIClient.swift`, `Sources/UserInterface/Preferences/Devices/DevicesSettingHostingViewController.swift`; tests `ProfilePairingGateTests.swift`, `PairingWizardViewModelTests.swift`, `KeyEnvelopeAPIClientTests.swift` under `Tests/PhiBrowserTests/Sync/Keys/`.

**Interfaces:**
- Gate produces `requestPresentation(controller: SyncKeyController)` and `finishLater()`.
- Wizard produces `leaveWithoutApplying() -> Bool`: false only while isApplying.
- `start(controller:)` remains the entry loader; each explicit entry creates a new VM and generation.
- Keep the existing `previewAccountSpaces()` and `ProfileKeyManager.accountProfiles()` paths; do not add a preview cache.

- [ ] In `PairingWizardViewModelTests`, use the existing `PreviewHold` and
  `makeWizard` fixture to add an executable stale-response regression:

```swift
func testLeavingInvalidatesAParkedPreview() async throws {
    let hold = PreviewHold()
    let (wizard, controller, _, _) = try await makeWizard(
        locals: [], accountSpaces: [], preview: {
            await hold.enter()
            return .success([])
        })
    let load = Task { await wizard.start(controller: controller) }
    while await hold.calls == 0 { await Task.yield() }
    XCTAssertTrue(wizard.leaveWithoutApplying())
    await hold.release()
    await load.value
    XCTAssertFalse(wizard.canSubmit)
}
```

  Add `canSubmit: Bool` to the wizard as the combined live-session and decided-row
  predicate used by its submit actions. The left session has no submit eligibility.
  Also test two separately constructed wizards against a counting preview that
  returns different account Spaces on calls 1 and 2: the second must contain only
  call 2's results and must make another Profile-list request.

- [ ] Implement leaveWithoutApplying by checking isApplying, advancing the
  existing generation, cancelling the load task, and clearing in-session
  choices/preview. Set its private session-active flag false before dismissal.
  `start` marks a new session active, clears stale selections, requests Profile
  and Space data anew, and accepts results only for the captured generation.
  All mutations after awaits also check the originating controller is not retired.
- [ ] Disable HTTP cache use for key-backend GET requests used in candidate
  loading; do not allow URLSession to substitute a previous response:

```swift
if method == "GET" {
    req.cachePolicy = .reloadIgnoringLocalCacheData
    req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
}
```

  Add URLProtocol assertions for these headers/policy and two fresh requests.
  Space preview already starts a local marker at nil; verify no previous response
  or live cursor supplies its candidate set. A failure displays only error/retry,
  not the previous successful candidates.
- [ ] Replace automatic modal presentation in mapping/idle-round callbacks with
  lifecycle/status updates. Present only from explicit setup continuation or
  the Sync pane. Add tests with a recording modal host: repeated mapping events,
  three idle callbacks, stop/start, and finishLater produce no new present call;
  requestPresentation produces one fresh session. Remove the obsolete hysteresis
  presentation behavior rather than retain two competing policies.
- [ ] Make the existing host closable and wire close, Escape, and Finish later
  through the same leaveWithoutApplying/finishLater path. Refuse these actions
  during confirmed application. Preserve the host's RunLoop scheduling and
  event-tracking-safe teardown; do not enter nested runModal from Task or the
  main dispatch queue. Do not reuse a hidden wizard VM on the next presentation.
- [ ] Run lifecycle/gate/wizard focused tests; manually verify close/Escape during
  a delayed preview restores browser input and reopening displays Loading.

### Task 4: Fresh review, serialized apply, and durable completion

**Files:** Modify `Sources/Sync/Keys/UI/PairingWizardViewModel.swift`, `Sources/Sync/Keys/UI/KeyLayerViewModel.swift`, `Sources/Sync/Keys/UI/SpaceOverwriteDiff.swift`; test `Tests/PhiBrowserTests/Sync/Keys/PairingWizardViewModelTests.swift`, `SpacePairingModelTests.swift`, `SelfRevokeTests.swift`.

**Interfaces:**
- Consumes gate `completeEnrollment() throws` and wizard session generation.
- Existing `finish(controller:)` and `applyConfirmedOverwrite(controller:)` remain the only submit entry points.
- Add `validateCurrentReview(controller:) async -> Bool`, which performs fresh candidate/local reads and compares the reviewed decisions and overwrite diff.

- [ ] Extend the current fixture with mutable local/remote snapshots and a
  completion-save recorder. Cover a rename, removed remote target, changed
  Profile binding, disk write failure, and partial Profile apply. Assertions:

```swift
XCTAssertTrue(store.writes.allSatisfy { $0.pending })
XCTAssertFalse(gate.isPaired)
XCTAssertEqual(completionWrites, 0)
XCTAssertFalse(wizard.leaveWithoutApplying()) // while confirmed apply is parked
```

  Here `gate` is the fixture's configured gate from Task 1; `completionWrites`
  is incremented by its injected save closure only for paired records. Replace
  the old global pending override in the ledger fixture with that gate's state.

- [ ] Before applying, call validateCurrentReview with the originating controller.
  Freshly reload candidates and local values, retaining choices only when stable
  IDs remain valid. Compare the resulting decisions and SpaceOverwriteDiff with
  the displayed review. If changed, replace the review/decision page and return
  false; do not recurse into apply. Fetch errors show retry and allow Later.
  Re-read local targets immediately before each mapping mutation after an await.
- [ ] Keep the existing serialized Profile-then-Space apply sequence and
  idempotency checks. At the end, check all actionable decisions are satisfied,
  then call completeEnrollment. Only after it succeeds resolve/publish readiness
  and mark done. Do not clear completion from a generic `needsPairing == false`
  notification, and never treat partial Profile success as full success.

```swift
do {
    try gate.completeEnrollment()
    await controller.resolveMappings()
    guard !controller.isRetired else { return }
    phase = .done
} catch {
    phase = .error(message: PairingWizardStrings.applyFailed, resume: .backToSpaces)
}
```

  Capture `gate` as a constructor dependency defaulting to the current existing
  gate; do not reach through AccountController in the view. Bound setup network
  operations using the existing deadlines; timeout exits must preserve completed
  writes and permit safe retry/Later rather than pretend rollback occurred.
- [ ] On self-removal retire engine/controller first, then invalidate the
  enrollment record along with existing cleanup. Failed removal leaves the record
  intact. Last-device refusal must still allow Finish later. Account switches
  cannot write completion through a replaced gate/account binding.
- [ ] Run the focused suites and `bash build-scripts/test-sync-convergence.sh`
  because changed review/eligibility can affect landing. Record a two-Mac check:
  defer, edit locally, change account data on the other Mac, reenter, review latest
  differences, complete, and verify convergence without duplicate identities.

### Task 5: One setup flow and recoverable authorization errors

**Files:** Modify `Sources/Sync/Keys/UI/KeyLayerViewModel.swift`, `KeyLayerView.swift`, `JoinMethodChoiceView.swift`, `WaitingForApprovalView.swift`, `RecoveryCodeEntryView.swift`, `RecoveryCodeDisplayView.swift` in the same directory; `Sources/Sync/Keys/UI/ProfilePairingGate.swift`; `Sources/UserInterface/Preferences/Devices/DevicesSettingHostingViewController.swift`; tests `KeyLayerViewModelTests.swift`, `KeyLayerFinishDeliveryTests.swift`, `SyncUITextSelectionTests.swift`.

**Interfaces:**
- Add KeyLayer phase `.introduction`; `beginSetup(controller:)` only loads/routes until explicit Continue.
- Add `continueSetup() async`, `inputError: String?`, `workingOperation` state, and an operation generation to KeyLayerViewModel.
- Successful bootstrap/recovery/approval invokes one injected `onVerified: @MainActor () -> Void`; final pairing dismissal invokes one `onSetupFinished` callback.
- The existing host owns the one active window/flow; do not create another singleton or window manager.

- [ ] Extend existing fake API tests: introduction sends no putAccount; Continue
  sends one; bad recovery input keeps `.enteringRecoveryCode`; a 503/URLError
  has retryable connection copy. Record approval completion, switch to recovery
  before releasing it, then assert the old generation never invokes onVerified.
- [ ] Classify recovery errors without losing the input page:

```swift
do {
    try await manager.joinWithRecoveryCode(code)
    guard operationGeneration == capturedGeneration else { return }
    onVerified()
} catch AccountKeyError.badRecoveryCode {
    guard operationGeneration == capturedGeneration else { return }
    inputError = KeyLayerStrings.invalidRecoveryCode
    phase = .enteringRecoveryCode
} catch {
    guard operationGeneration == capturedGeneration else { return }
    inputError = KeyLayerStrings.recoveryConnectionFailed
    phase = .enteringRecoveryCode
}
```

  Define these strings using semantic localization keys and fixed safe English
  copy; classify authentication/service errors separately when retry needs a
  different action. Do not stringify raw server errors or secrets into UI/logs.
  Clear busy state in a generation-aware defer. Keep code input in the active
  view/model so temporary working state does not discard it.
- [ ] Request beginEnrollment before starting a new bootstrap/join mutation.
  Preserve recovery-code acknowledgment and its existing safe Copy interaction.
  Change confirmed verification from `.done`/window close to the same host's
  pairing content. If already unlocked but unpaired, route to a fresh pairing
  load; if paired, return to the pane without starting another setup lifecycle.
- [ ] Waiting shows Settings > Sync, remaining time, recovery alternative, and
  cancellation. Cancellation invalidates the operation generation and stops
  polling; do not invent a server cancellation endpoint. Pending requests remain
  subject to the existing expiry, but no late response can advance the abandoned
  client flow. Distinguish transport failure from still waiting for approval.
- [ ] On fresh validated data, skip only empty decision steps. If both sets need
  no decision, first-device setup completes the full durable prerequisite; a
  joining device shows its account-content summary before applying. Do not use
  install age or a single Profile-count match as authorization for Space choices.
- [ ] Run the key-layer/finish-delivery/text-selection regressions and manually
  follow first-device, approval, recovery-error, expiry, and Later paths. There
  must be only one visible setup window and no blank intermediate window.

### Task 6: Minimal Sync entry, localization, and acceptance record

**Files:** Modify `Sources/UserInterface/Preferences/Devices/DevicesSettingViewController.swift`, `DevicesSettingView.swift`, `DevicesSettingViewModel.swift`, `DevicesSettingHostingViewController.swift`; `Resources/Localizable.xcstrings`; `docs/sync.md`, `docs/sync-e2e-test-cases.md`, and the modal-only explanation in `AGENTS.md`.

**Interfaces:** The visible name becomes Sync; keep `Settings.PaneIdentifier.devices` compatible. The pane derives Not paired from Task 1, and Continue setup calls Task 3's requestPresentation.

- [ ] Replace the visible title and pairing banner using explicit keys:

```swift
NSLocalizedString("sync.settings.title", value: "Sync", comment: "Settings pane title for cross-device synchronization")
NSLocalizedString("sync.setup.notPaired", value: "Not paired", comment: "Sync status before Profile and Space matching completes")
NSLocalizedString("sync.setup.notStarted", value: "Sync has not started. Finish pairing to sync this Mac.", comment: "Sync settings explanation shown while the device is unpaired")
NSLocalizedString("sync.setup.continue", value: "Continue setup", comment: "Sync settings action to load current account data and finish pairing")
NSLocalizedString("sync.setup.finishLater", value: "Finish later", comment: "Pairing action that leaves sync unstarted and returns to local browsing")
```

- [ ] Keep primary sync status separate from pending approvals. Do not show
  "No devices are waiting" as the principal success state. Until Part 2 provides
  actual engine facts, show a neutral checking/unknown data status after enrollment.
- [ ] Add only new English catalog entries; preserve existing translations.
  Update waiting-page routing text, Profile/Space result-oriented labels, the
  recovery explanation, and the removal confirmation's three product consequences.
  Do not localize debug previews. Run catalog JSON parsing and the source-language
  test; perform keyboard/VoiceOver checks on real views rather than string tests.
- [ ] Replace obsolete docs saying the user must finish or self-revoke and that
  settings can sync while pairing. Preserve the run-loop warning in AGENTS.md.
  Add manual cases for offline reentry, all-sync gating, late callbacks, partial
  apply, last-device defer, and account switching. Mark cases Not run until run.
- [ ] Run build-for-testing and executable hostless checks once for the completed
  increment. Review diff, unexpected package-resolution changes, and test results.
  Record runtime tests separately from compilation; leave product commits for
  explicit instruction. Continue with the linked Part 2 after plan approval.

## Coverage and handoff

Spec acceptance 1-2 maps to Task 5; 3-6 to Tasks 1/3/4; 7-10 to Tasks 1/2/4;
12 to Tasks 3/5/6. Acceptance 11 and the full page/device presentation are owned
by [Part 2](2026-09-23-sync-status-devices-implementation.md). No release is
complete until both increments and the listed runtime acceptance checks pass.
