import Combine
import XCTest
@testable import Phi

/// Wizard state machine (§5.2 / §5.5). Cases 1–8 use fixtures where all six fields
/// of mapped local and account Spaces match, so Finish skips confirmation and retains
/// the pre-D7 paths. Cases 9–13 cover D7 itself.
@MainActor
final class PairingWizardViewModelTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    /// Ordering fake: record joinPairingPending during each mapping write. This directly
    /// asserts that the gate stays closed until every mapping is written, rather than
    /// merely checking event names (§5.5 step 3 must follow step 2).
    final class LedgerSpaceMappingStore: SpaceSyncMappingStore {
        var map: [String: String] = [:]
        private(set) var writes: [(spaceId: String, uuid: String, pendingWhenWritten: Bool)] = []
        func syncUuid(forSpaceId spaceId: String) -> String? { map[spaceId] }
        /// Persistence is outside these cases; satisfy the signature with true and no failure control.
        func setSyncUuid(_ uuid: String, forSpaceId spaceId: String) -> Bool {
            map[spaceId] = uuid
            // Nested types do not inherit MainActor, while joinPairingPending is main-actor state.
            // SpaceSyncMappingManager's write API already runs there, so assert isolation.
            // Scheduling a hop would record after the write and invalidate the ordering check.
            let pending = MainActor.assumeIsolated { !ProfilePairingGate.shared.isPaired }
            writes.append((spaceId, uuid, pending))
            return true
        }
        func allMappings() -> [String: String] { map }
        func removeMapping(forSpaceId spaceId: String) { map.removeValue(forKey: spaceId) }
        func removeAllMappings() { map = [:] }
    }

    /// Controllable preview: enter() blocks only the first call, passing subsequent calls
    /// immediately to deterministically overlap an unfinished first load with a completed second load.
    actor PreviewHold {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private(set) var calls = 0

        func enter() async {
            calls += 1
            guard calls == 1, !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    private var resolveCount = 0
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        try? ProfilePairingGate.shared.configureEnrollment(deviceKeyID: "test-device", recordData: nil, saveRecord: { _ in true })
        resolveCount = 0
        observer = NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.resolveCount += 1 } }
    }

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        super.tearDown()
    }

    private func local(_ id: String, name: String, profile: String = "Default") -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: profile, name: name, colorHex: "#3AA4D5",
                      iconName: "phi:a", sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1),
                      themeId: nil, opacityLight: nil, opacityDark: nil)
    }

    private func account(_ uuid: String, name: String,
                         profileUuid: String = "uuid-a") -> PhiAccountSpaceSummary {
        PhiAccountSpaceSummary(syncUuid: uuid, name: name, iconName: "phi:a", colorHex: "#3AA4D5",
                               profileUuid: profileUuid, isDefault: false, themeId: "",
                               overlayOpacityLightMilli: -1, overlayOpacityDarkMilli: -1)
    }

    /// A machine with a bootstrapped account and a programmable preview.
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

    func testPreparingReviewFreezesSelectionsAndNavigation() async throws {
        let hold = PreviewHold()
        var previews = 0
        let remote = account("acct-1", name: "Remote")
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Local")], accountSpaces: [remote], preview: {
                previews += 1
                if previews > 1 { await hold.enter() }
                return .success([remote])
            })
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.addAllAsNew()
        let before = wizard.spaceSelections
        let phase = wizard.phase
        let submit = Task { await wizard.finish(controller: controller) }
        while await hold.calls == 0 { await Task.yield() }
        XCTAssertTrue(wizard.isPreparing)
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.backToProfiles()
        wizard.backFromConfirmation()
        XCTAssertEqual(wizard.spaceSelections, before)
        XCTAssertEqual(wizard.phase, phase)
        XCTAssertTrue(wizard.leaveWithoutApplying(), "Later remains available during refresh")
        await hold.release()
        await submit.value
        XCTAssertTrue(store.map.isEmpty)
    }

    private func makeWizard(
        locals: [PhiLocalSpace],
        accountSpaces: [PhiAccountSpaceSummary],
        preview: (() async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>)? = nil,
        loadDeadline: Duration = PairingWizardViewModel.defaultLoadDeadline
    ) async throws -> (PairingWizardViewModel, SyncKeyController, LedgerSpaceMappingStore, FakeAPI) {
        let api = FakeAPI()
        let manager = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await manager.bootstrap()
        let profileKeys = ProfileKeyManager(api: api, keyManager: manager,
                                            mappingStore: MemoryMappingStore())
        let spaceStore = LedgerSpaceMappingStore()
        let controller = SyncKeyController(
            manager: manager,
            approvals: DeviceApprovalService(api: api, keyManager: manager,
                                             deviceKeyProvider: FakeDeviceKeyProvider()),
            profileKeys: profileKeys,
            spaceKeys: SpaceSyncMappingManager(store: spaceStore),
            localProfilesProvider: { [(profileId: "Default", displayName: "Personal")] },
            notifyChromium: {})
        let wizard = PairingWizardViewModel(
            keyLayer: KeyLayerViewModel(manager: manager),
            previewAccountSpaces: preview ?? { .success(accountSpaces) },
            pairableLocalSpaces: { locals },
            themeDisplayName: { _ in nil },
            loadDeadline: loadDeadline)
        return (wizard, controller, spaceStore, api)
    }

    // MARK: - 1. Successful state-machine path

    func testTheHappyPathWalksLoadingProfilesSpacesSubmittingDone() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "Work")])

        await wizard.start(controller: controller)
        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles") }
        XCTAssertEqual(wizard.step, .profiles)

        wizard.continueToSpaces()
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        XCTAssertEqual(wizard.step, .spaces)

        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        XCTAssertTrue(wizard.spaceModel.allRowsDecided)
        await wizard.finish(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(store.map, ["LOCAL-1": "acct-1"])
    }

    // MARK: - 2. Continue validates only

    func testContinueWritesNothingAndTouchesNeitherTheFlagNorTheMappings() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        resolveCount = 0

        wizard.continueToSpaces()
        XCTAssertTrue(store.map.isEmpty, "No mapping writes")
        XCTAssertTrue(!ProfilePairingGate.shared.isPaired, "joinPairingPending remains unchanged")
        XCTAssertEqual(resolveCount, 0, "resolveMappings() is not called")
    }

    // MARK: - 3. Finish ordering

    func testTheApplySequenceIsProfilesThenMappingsThenTheFlagThenResolve() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        resolveCount = 0

        await wizard.finish(controller: controller)

        XCTAssertEqual(api.profileEnvelopes.count, 1, "Step 1 applies Profile decisions first")
        XCTAssertEqual(store.writes.map(\.pendingWhenWritten), [true],
                       "Step 3 follows step 2: the gate stays closed until all mappings are written")
        XCTAssertFalse(!ProfilePairingGate.shared.isPaired)
        XCTAssertGreaterThan(resolveCount, 0, "Step 4 calls resolveMappings() last")
        XCTAssertEqual(wizard.phase, .done)
    }

    // MARK: - 4. Idempotence

    /// Use a real semantic failure: a stale STALE -> acct-2 mapping makes the second
    /// decision throw syncUuidAlreadyClaimed. Remove it and retry; the first mapping
    /// is not rewritten, and the final table matches one successful Finish.
    ///
    /// This also tests Profile idempotence (§10.6 rule 4, first half). The first Finish
    /// registers Default; retry replays frozen profileDecisions and registerLocalProfile
    /// throws alreadyMapped. Task 7 Step 2(c) treats this as complete, reaching done.
    /// Without that catch, the wizard remains in profiles, so this is its regression test.
    func testASecondFinishAfterAFailureConvergesOnTheSameTable() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work"), account("acct-2", name: "Reading")])
        store.map["STALE"] = "acct-2"
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")

        await wizard.finish(controller: controller)
        guard case .error(_, let resume) = wizard.phase else { return XCTFail("expected .error") }
        XCTAssertEqual(resume, .backToSpaces)
        XCTAssertTrue(!ProfilePairingGate.shared.isPaired, "The gate stays closed on failure")
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1", "The first mapping has already been written")

        store.map.removeValue(forKey: "STALE")
        await wizard.retry(controller: controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        await wizard.finish(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1")
        XCTAssertEqual(store.map["LOCAL-2"], "acct-2")
        XCTAssertEqual(store.writes.filter { $0.spaceId == "LOCAL-1" }.count, 1,
                       "alreadyMapped with the expected value is complete and requires no rewrite")
        XCTAssertEqual(api.profileEnvelopes.count, 1,
                       "Profile alreadyMapped on retry is successful without minting another envelope")
    }

    // MARK: - 4b. addAsNew idempotence criteria

    /// Changing a partially applied decision to addAsNew must be rejected, never silently
    /// reuse the old mapping. ensureSpaceMapped only prevents a second mint and silently
    /// accepts a row already linked to an account Space. If Finish maps LOCAL-1 to acct-1
    /// then fails on LOCAL-2, the user can return and select Add as new to preserve local
    /// name/icon/color. D7 skips addAsNew differences, so no confirmation appears. The old
    /// apply no-op retained the mapping, and A1's initial no-baseline adoption overwrote
    /// exactly what the user intended to preserve.
    func testAnAddAsNewRowStillBoundToAnAccountSpaceIsRefusedRatherThanSilentlyKept() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work"), account("acct-2", name: "Reading")])
        store.map["STALE"] = "acct-2"      // The second decision collides with syncUuidAlreadyClaimed
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")

        await wizard.finish(controller: controller)
        guard case .error(_, .backToSpaces) = wizard.phase else { return XCTFail("expected .error") }
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1")

        await wizard.retry(controller: controller)
        wizard.assign(.addAsNew, to: "LOCAL-1")
        await wizard.finish(controller: controller)

        guard case .error(_, .backToSpaces) = wizard.phase else {
            return XCTFail("A withdrawn decision must never execute silently")
        }
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1", "Neither mint a new identity nor silently reuse the old mapping")
        XCTAssertEqual(store.writes.filter { $0.spaceId == "LOCAL-1" }.count, 1)
        XCTAssertTrue(!ProfilePairingGate.shared.isPaired, "The gate must stay closed")
    }

    /// Conversely, a mapping minted locally earlier has a UUID absent from the account list.
    /// Replay treats it as completed, without another mint or error; otherwise the preceding
    /// criterion makes ordinary Retry impossible.
    func testAnAddAsNewRowBoundToThisDevicesOwnEarlierMintReplaysAsDone() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work"), account("acct-2", name: "Reading")])
        store.map["STALE"] = "acct-2"
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.addAsNew, to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")

        await wizard.finish(controller: controller)
        guard case .error(_, .backToSpaces) = wizard.phase else { return XCTFail("expected .error") }
        let minted = try XCTUnwrap(store.map["LOCAL-1"])

        store.map.removeValue(forKey: "STALE")
        await wizard.retry(controller: controller)
        await wizard.finish(controller: controller)

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(store.map["LOCAL-1"], minted, "Reuse the same UUID without minting another")
        XCTAssertEqual(store.writes.filter { $0.spaceId == "LOCAL-1" }.count, 1)
        XCTAssertEqual(store.map["LOCAL-2"], "acct-2")
    }

    // MARK: - 5. Finish fails at step 1

    /// Assert a reread, not a fixed value. On failure, applyPairingDecisions calls startPairing
    /// to reload candidates; the wizard must display that new table (§5.5).
    /// Start with registerNew(Default), the sole local Profile and an empty account. Fail
    /// its PUT once, then add an account Profile before reload so the candidate table changes.
    func testAFailedProfileStepGoesBackToStepOneWithTheReloadedCandidates() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        guard case .profiles(let firstLocals, let firstRemotes) = wizard.phase else {
            return XCTFail("expected .profiles")
        }
        XCTAssertEqual(firstLocals.map(\.profileId), ["Default"])
        XCTAssertTrue(firstRemotes.isEmpty)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        api.profileEndpointErrorOnce = KeyAPIError.http(500, "boom")
        api.profileEnvelopes["uuid-remote"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Home",
            ark: try XCTUnwrap(controller.manager.currentARK))
        await wizard.finish(controller: controller)

        guard case .profiles(_, let reloaded) = wizard.phase else {
            return XCTFail("expected to land back on step 1")
        }
        XCTAssertEqual(reloaded.map(\.uuid), ["uuid-remote"], "Render the reloaded candidate table")
        XCTAssertEqual(wizard.step, .profiles)
        XCTAssertTrue(!ProfilePairingGate.shared.isPaired, "The gate must stay closed")
        XCTAssertTrue(store.map.isEmpty, "No Space mapping writes")
    }

    /// If reload also fails, enter error(_, .reload) instead of continuing with stale data.
    func testAFailedProfileStepWhoseReloadAlsoFailsLandsOnErrorReload() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        api.profileEndpointError = KeyAPIError.http(500, "boom")   // The decision fails
        api.listProfilesError = KeyAPIError.http(500, "boom")      // Reload also fails
        await wizard.finish(controller: controller)

        guard case .error(_, let resume) = wizard.phase else { return XCTFail("expected .error") }
        XCTAssertEqual(resume, .reload)
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertTrue(!ProfilePairingGate.shared.isPaired)
    }

    // MARK: - 5b. Step 2 selections survive Back and failures

    func testStepTwoSelectionsSurviveBackAndAFailedApply() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work"), account("acct-2", name: "Reading")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")

        wizard.backToProfiles()
        wizard.continueToSpaces()
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"))
        XCTAssertEqual(wizard.spaceSelections["LOCAL-2"], .existing(syncUuid: "acct-2"))

        store.map["STALE"] = "acct-2"      // The second decision collides with syncUuidAlreadyClaimed
        await wizard.finish(controller: controller)
        await wizard.retry(controller: controller)
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"))
        XCTAssertEqual(wizard.spaceSelections["LOCAL-2"], .existing(syncUuid: "acct-2"),
                       "spaceSelections belongs to the view model, not step-view State")
    }

    // MARK: - 5c. Left column includes Spaces with unmapped Profiles

    /// Unit-test projection of §10.9 step 3: using a currentSpaces() fake must fail
    /// because that source hides this entire row.
    func testARowWhoseProfileIsStillUnmappedIsListedInStepTwo() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-7", name: "Work", profile: "Profile 7")],
            accountSpaces: [])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        XCTAssertEqual(wizard.spaceModel.rows.map(\.spaceId), ["LOCAL-7"])
    }

    // MARK: - 6. Load failure and re-drive

    func testAFailedPreviewStopsAtErrorReloadAndKeepsStepOne() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [],
            preview: { .failure(.truncated) })
        await wizard.start(controller: controller)
        guard case .error(_, let resume) = wizard.phase else { return XCTFail("expected .error") }
        XCTAssertEqual(resume, .reload)
        XCTAssertEqual(wizard.step, .profiles)
    }

    /// Equal deadlines are an existing invariant documented by both PhiSyncEngine.previewDeadlineMs
    /// and PairingWizardViewModel.loadAccountSpaces. M3-3 §5.8 raised both from 45 to 120 seconds
    /// because previews must traverse bookmarks and pins across the account to count Spaces.
    /// Updating only one lets the UI give up at 45 seconds while preview occupies the round
    /// queue until 120, and breaks the loading page's two-minute promise. The helper above
    /// always passes loadDeadline explicitly; only this case observes the production default.
    func testTheWizardsLoadDeadlineIsTwoMinutesAndMatchesTheEngines() {
        XCTAssertEqual(PairingWizardViewModel.defaultLoadDeadline, .seconds(120))
        XCTAssertEqual(PairingWizardViewModel.defaultLoadDeadline,
                       .milliseconds(PhiSyncEngine.previewDeadlineMs),
                       "Both deadlines have the same value")
    }

    /// §4.5's deadline must stop the loading page, not merely change its eventual error.
    /// The injected preview deliberately resists cancellation: an unstructured Task awaited
    /// through task.value, as in PhiSyncEngine.serialized. withTaskGroup waits for every
    /// child before returning, and cancelAll cannot stop this work, so its deadline branch
    /// would never complete and the modal would remain loading without Retry. Assert
    /// elapsed time as well as phase.
    func testTheLoadDeadlineReturnsWhileAnUncancellablePreviewIsStillRunning() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [],
            preview: {
                let work = Task { () -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError> in
                    try? await Task.sleep(for: .seconds(2))
                    return .success([])
                }
                return await work.value
            },
            loadDeadline: .milliseconds(50))

        let startedAt = Date()
        await wizard.start(controller: controller)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 1.0, "Return at the deadline without waiting for the uncancellable preview")
        guard case .error(let message, let resume) = wizard.phase else {
            return XCTFail("expected .error")
        }
        XCTAssertEqual(message, PairingWizardStrings.previewTimedOut)
        XCTAssertEqual(resume, .reload, "Retry reruns start()")
    }

    /// A Profile load failure reports immediately without awaiting preview. Both loads
    /// start concurrently; awaiting a preview lasting up to 120 seconds before checking
    /// Profile failure strands users on a loading page without Retry or close controls
    /// for an error known in the second second. The abandoned preview resists cancellation
    /// (see PreviewRace), so assert error phase while it is still blocked, not start() return time.
    func testAFailedProfileLoadReportsItsErrorWithoutWaitingForThePreview() async throws {
        let hold = PreviewHold()
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [],
            preview: { await hold.enter(); return .success([]) })
        api.listProfilesError = KeyAPIError.http(500, "boom")

        let run = Task { await wizard.start(controller: controller) }
        var spins = 0
        while await hold.calls == 0, spins < 10_000 { spins += 1; await Task.yield() }
        let entered = await hold.calls
        XCTAssertEqual(entered, 1, "Preview has started and is blocked")
        spins = 0
        while case .loading = wizard.phase, spins < 10_000 { spins += 1; await Task.yield() }

        // The preview remains blocked after the UI reports the error.
        guard case .error(_, let resume) = wizard.phase else {
            return XCTFail("expected .error while the preview is still parked")
        }
        XCTAssertEqual(resume, .reload, "Retry reruns start()")
        let stillParked = await hold.calls
        XCTAssertEqual(stillParked, 1, "The preview has not returned")
        XCTAssertTrue(store.map.isEmpty, "No Space mapping writes")

        await hold.release()
        await run.value
        guard case .error = wizard.phase else {
            return XCTFail("The abandoned preview must not overwrite phase when it returns")
        }
    }

    /// reloadAllowed intentionally accepts loading, so overlapping start() calls are
    /// expected. A superseded load must write nothing on completion: otherwise it can
    /// overwrite a successful load with an error or erase completed selections and reset step.
    func testASupersededStartWritesNothingWhenItFinallyLands() async throws {
        let hold = PreviewHold()
        let spaces = [account("acct-1", name: "Work")]
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: spaces,
            preview: { await hold.enter(); return .success(spaces) })

        // First load: block preview.
        let first = Task { await wizard.start(controller: controller) }
        var spins = 0
        while await hold.calls == 0, spins < 10_000 { spins += 1; await Task.yield() }
        let calls = await hold.calls
        XCTAssertEqual(calls, 1, "The first load is blocked in preview")

        // Second load, as used by gate re-drive: preview passes and the load completes.
        await wizard.start(controller: controller)
        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles") }
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        // Only now let the first load return.
        await hold.release()
        await first.value

        XCTAssertEqual(wizard.step, .spaces, "The superseded load must not reset step to Profiles")
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"),
                       "It must also preserve step 2 assignments")
        guard case .spaces = wizard.phase else { return XCTFail("It must not overwrite phase") }
    }

    // MARK: - 7. No KeyLayerPhase writes

    func testTheWizardIsNeverASecondWriterOfKeyLayerPhase() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        let afterLoad = wizard.keyLayer.phase
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        XCTAssertEqual(wizard.keyLayer.phase, afterLoad,
                       "The wizard only reads keyLayer.phase throughout the interaction")
    }

    // MARK: - 8. Step 2 Profile labels (§5.2 three-level resolution)

    /// Assert all three ordered lookup outcomes: an unclaimed account Profile uses its
    /// decrypted registration name from remotes; a mapped Profile uses its local display
    /// name; no match leaves accountProfileNames without an entry, displayed as an em dash
    /// without affecting any decision criteria.
    func testAccountProfileNamesComeFromRemotesThenTheMappingThenNothing() async throws {
        // Three account Spaces cover the three resolution outcomes.
        let (wizard, controller, _, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "A", profileUuid: "uuid-unclaimed"),
                            account("acct-2", name: "B", profileUuid: "uuid-claimed"),
                            account("acct-3", name: "C", profileUuid: "uuid-nowhere")])
        let ark = try XCTUnwrap(controller.manager.currentARK)
        // 1) Unclaimed: account envelope exists without a local mapping, so it appears in remotes.
        api.profileEnvelopes["uuid-unclaimed"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Home", ark: ark)
        // 2) Mapped: local Default already claims it, so startPairing's claimedUuids filter
        // excludes it from remotes. Resolve through localProfileId(forGlobalUuid:) and the local display name.
        api.profileEnvelopes["uuid-claimed"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Ignored on the wire", ark: ark)
        _ = try await controller.profileKeys.adoptRemoteProfile(
            uuid: "uuid-claimed", forLocalProfile: "Default")
        // 3) uuid-nowhere exists in neither source.

        await wizard.start(controller: controller)
        let names = wizard.spaceModel.input.accountProfileNames
        XCTAssertEqual(names["uuid-unclaimed"], "Home", "An unclaimed Profile uses its decrypted registration name from remotes")
        XCTAssertEqual(names["uuid-claimed"], "Personal",
                       "A mapped Profile uses the local display name from localProfilesProvider")
        XCTAssertNil(names["uuid-nowhere"], "No match leaves no entry; the view displays an em dash")
    }

    // MARK: - D7 (§10.6 cases 9–13)

    /// 9. Differences stop Finish at confirmation, with no writes before confirmation.
    func testADifferingFieldStopsFinishAtTheConfirmationWithNothingWritten() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Job")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        resolveCount = 0

        await wizard.finish(controller: controller)

        guard case .confirmOverwrite(let items) = wizard.phase else {
            return XCTFail("expected .confirmOverwrite")
        }
        XCTAssertEqual(items.map(\.localSpaceId), ["LOCAL-1"])
        XCTAssertEqual(items.first?.changes.map(\.field), [.name])
        XCTAssertTrue(store.map.isEmpty, "No mapping writes")
        XCTAssertTrue(!ProfilePairingGate.shared.isPaired)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(api.profileEnvelopes.count, 0, "applyPairingDecisions is not called")
        XCTAssertEqual(wizard.step, .spaces, "Confirmation is not a third step: step ② remains current")
    }

    /// 10. Back preserves selections; Finish recomputes and displays the same confirmation.
    func testBackFromTheConfirmationKeepsEverySelection() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Job")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        await wizard.finish(controller: controller)
        guard case .confirmOverwrite(let first) = wizard.phase else { return XCTFail("expected page") }

        wizard.backFromConfirmation()
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        XCTAssertEqual(wizard.step, .spaces)
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"))

        await wizard.finish(controller: controller)
        guard case .confirmOverwrite(let second) = wizard.phase else { return XCTFail("expected page") }
        XCTAssertEqual(first, second)
    }

    /// 11. Apply follows the same commit sequence and ordering assertion; confirmation has no separate path.
    func testApplyFromTheConfirmationRunsTheSameSequence() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Job")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        await wizard.finish(controller: controller)
        resolveCount = 0

        await wizard.applyConfirmedOverwrite(controller: controller)

        XCTAssertEqual(api.profileEnvelopes.count, 1)
        XCTAssertEqual(store.writes.map(\.pendingWhenWritten), [true])
        XCTAssertFalse(!ProfilePairingGate.shared.isPaired)
        XCTAssertGreaterThan(resolveCount, 0)
        XCTAssertEqual(wizard.phase, .done)
    }

    /// 12. No differences skip confirmation; assert the phase write sequence, not only the final phase.
    func testNoDifferenceMeansTheConfirmationNeverAppears() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        var seen: [PairingWizardPhase] = []
        let cancellable = wizard.$phase.sink { seen.append($0) }
        await wizard.finish(controller: controller)
        cancellable.cancel()

        XCTAssertFalse(seen.contains { if case .confirmOverwrite = $0 { return true }; return false })
        XCTAssertTrue(seen.contains { if case .submitting = $0 { return true }; return false })
        XCTAssertEqual(wizard.phase, .done)
    }

    /// 13. Differences are recomputed, not frozen: Back, select addAsNew for that row, then
    /// Finish skips confirmation and commits directly.
    func testChangingTheRowToAddAsNewMakesTheConfirmationDisappear() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Job")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        await wizard.finish(controller: controller)
        wizard.backFromConfirmation()
        wizard.assign(.addAsNew, to: "LOCAL-1")

        await wizard.finish(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertNotEqual(store.map["LOCAL-1"], "acct-1", "Add as new mints a new UUID and preserves every local value")
    }
}
