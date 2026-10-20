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
    typealias FakeProfileCreator = ProfileAutoCreateTests.FakeProfileCreator

    /// Ordering fake: record joinPairingPending during each mapping write. This directly
    /// asserts that the gate stays closed until every mapping is written, rather than
    /// merely checking event names (§5.5 step 3 must follow step 2).
    final class LedgerSpaceMappingStore: SpaceSyncMappingStore {
        var map: [String: String] = [:]
        private(set) var writes: [(spaceId: String, uuid: String, pendingWhenWritten: Bool)] = []
        /// The gate whose closed state each write records; nil reads `ProfilePairingGate.shared`.
        let gate: ProfilePairingGate?
        init(gate: ProfilePairingGate? = nil) { self.gate = gate }
        func syncUuid(forSpaceId spaceId: String) -> String? { map[spaceId] }
        /// Persistence is outside these cases; satisfy the signature with true and no failure control.
        func setSyncUuid(_ uuid: String, forSpaceId spaceId: String) -> Bool {
            map[spaceId] = uuid
            // Nested types do not inherit MainActor, while joinPairingPending is main-actor state.
            // SpaceSyncMappingManager's write API already runs there, so assert isolation.
            // Scheduling a hop would record after the write and invalidate the ordering check.
            let pending = MainActor.assumeIsolated { !(gate ?? .shared).isPaired }
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
    /// A gate private to each test. In the hosted test run the app's own coordinator
    /// configures `ProfilePairingGate.shared` (and so replaces its enrollment generation)
    /// once the signed-in account restores, at an unpredictable point mid-suite. A wizard
    /// bound to the shared gate then sees its session invalidated and drops its result.
    private var gate: ProfilePairingGate!

    override func setUp() {
        super.setUp()
        gate = ProfilePairingGate()
        try? gate.configureEnrollment(deviceKeyID: "test-device", recordData: nil, saveRecord: { _ in true })
        resolveCount = 0
        observer = NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.resolveCount += 1 } }
    }

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        gate = nil
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
                return .success(.init(spaces: [], skippedEntityCount: 0))
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
        // A second local Profile keeps the Profiles page in the plan, so Back below is refused by the
        // preflight, not by a hidden page.
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Local")], accountSpaces: [remote],
            profiles: Self.profilesWithExtra, preview: {
                previews += 1
                if previews > 1 { await hold.enter() }
                return .success(.init(spaces: [remote], skippedEntityCount: 0))
            })
        await wizard.start(controller: controller)
        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles") }
        wizard.continueToSpaces()
        wizard.addAllAsNew()
        XCTAssertTrue(wizard.canGoBackToProfiles)
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

    /// The only local Profile unless a case passes more. With just the Default and nothing to choose for it,
    /// the page plan hides the Profiles page.
    nonisolated private static let defaultOnlyProfiles: [(profileId: String, displayName: String)] =
        [(profileId: "Default", displayName: "Personal")]
    /// A second local Profile always needs a decision, so the Profiles page shows.
    nonisolated private static let profilesWithExtra: [(profileId: String, displayName: String)] =
        defaultOnlyProfiles + [(profileId: "Profile 2", displayName: "Reading")]

    /// The merge-path cases predate the sync method step and pin it off, so they keep entering the Profiles
    /// and Spaces pages directly; the method step and "use your account's data" have their own fixture
    /// (`makeReplaceWizard`) with the step enabled.
    private func makeWizard(
        locals: [PhiLocalSpace],
        accountSpaces: [PhiAccountSpaceSummary],
        profiles: [(profileId: String, displayName: String)] = PairingWizardViewModelTests.defaultOnlyProfiles,
        profileCreator: FakeProfileCreator? = nil,
        liveLocals: (() -> [PhiLocalSpace])? = nil,
        preview: (() async -> Result<PhiAccountSpacePreview, PhiSpacePreviewError>)? = nil,
        loadDeadline: Duration = PairingWizardViewModel.defaultLoadDeadline
    ) async throws -> (PairingWizardViewModel, SyncKeyController, LedgerSpaceMappingStore, FakeAPI) {
        let api = FakeAPI()
        let manager = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await manager.bootstrap()
        let profileKeys = ProfileKeyManager(api: api, keyManager: manager,
                                            mappingStore: MemoryMappingStore())
        let gate: ProfilePairingGate = self.gate
        let spaceStore = LedgerSpaceMappingStore(gate: gate)
        let controller = SyncKeyController(
            manager: manager,
            approvals: DeviceApprovalService(api: api, keyManager: manager,
                                             deviceKeyProvider: FakeDeviceKeyProvider()),
            profileKeys: profileKeys,
            spaceKeys: SpaceSyncMappingManager(store: spaceStore),
            localProfilesProvider: { profiles },
            notifyChromium: {},
            // Never the real ProfileManager: an automatic createLocal must not touch Chromium.
            profileCreator: profileCreator ?? FakeProfileCreator(),
            isPairingComplete: { gate.isPaired })
        let wizard = PairingWizardViewModel(
            keyLayer: KeyLayerViewModel(manager: manager),
            previewAccountSpaces: preview ?? { .success(.init(spaces: accountSpaces, skippedEntityCount: 0)) },
            pairableLocalSpaces: liveLocals ?? { locals },
            themeDisplayName: { _ in nil },
            loadDeadline: loadDeadline,
            gate: gate,
            methodStepEnabled: false)
        return (wizard, controller, spaceStore, api)
    }

    // MARK: - 1. Successful state-machine path

    func testTheHappyPathWalksLoadingProfilesSpacesSubmittingDone() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "Work")],
            profiles: Self.profilesWithExtra)

        await wizard.start(controller: controller)
        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles") }
        XCTAssertEqual(wizard.step, .profiles)
        XCTAssertEqual(wizard.visibleSteps, [.profiles, .spaces])

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
        XCTAssertTrue(!gate.isPaired, "joinPairingPending remains unchanged")
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
        XCTAssertFalse(!gate.isPaired)
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
        XCTAssertTrue(!gate.isPaired, "The gate stays closed on failure")
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1", "The first mapping has already been written")

        store.map.removeValue(forKey: "STALE")
        await wizard.retry(controller: controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        await wizard.finish(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(wizard.spaceSelections["LOCAL-2"], .existing(syncUuid: "acct-2"),
                       "Our own completed Profile registration must not invalidate the unapplied Space choice")
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1")
        XCTAssertEqual(store.map["LOCAL-2"], "acct-2")
        XCTAssertEqual(store.writes.filter { $0.spaceId == "LOCAL-1" }.count, 1,
                       "alreadyMapped with the expected value is complete and requires no rewrite")
        XCTAssertEqual(api.profileEnvelopes.count, 1,
                       "Profile alreadyMapped on retry is successful without minting another envelope")
    }

    func testRetryAfterProfileAdoptionPreservesSpaceChoices() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work", profileUuid: "remote-profile"),
                            account("acct-2", name: "Reading", profileUuid: "remote-profile")])
        api.profileEnvelopes["remote-profile"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Remote name", ark: try XCTUnwrap(controller.manager.currentARK))
        store.map["STALE"] = "acct-2"
        await wizard.start(controller: controller)
        wizard.profileSelections["Default"] = .remote("remote-profile")
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")
        await wizard.finish(controller: controller)
        guard case .error(_, .backToSpaces) = wizard.phase else { return XCTFail("Expected partial failure") }

        store.map.removeValue(forKey: "STALE")
        await wizard.retry(controller: controller)
        await wizard.finish(controller: controller)

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(store.map["LOCAL-2"], "acct-2")
        XCTAssertEqual(api.profileEnvelopes.count, 1)
    }

    func testRetryAfterPartialApplyStillRequiresReviewOfChangedAccountSpaces() async throws {
        var accountSpaces = [account("acct-1", name: "Work"), account("acct-2", name: "Reading")]
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: accountSpaces, preview: { .success(.init(spaces: accountSpaces, skippedEntityCount: 0)) })
        store.map["STALE"] = "acct-2"
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")
        await wizard.finish(controller: controller)
        guard case .error(_, .backToSpaces) = wizard.phase else { return XCTFail("Expected partial failure") }
        store.map.removeValue(forKey: "STALE")
        accountSpaces[1] = account("acct-2", name: "Changed on another device")

        await wizard.retry(controller: controller)
        await wizard.finish(controller: controller)

        guard case .profiles = wizard.phase else { return XCTFail("Changed server values require a fresh review") }
        XCTAssertNil(store.map["LOCAL-2"], "No unapplied choice may bypass the fresh-server check")
        XCTAssertFalse(gate.isPaired)
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
        XCTAssertTrue(!gate.isPaired, "The gate must stay closed")
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

    /// A stored identity the account no longer has (server reset, or an unpublished local
    /// mint) seeds `.addAsNew`, and a same-name suggestion may replace it. Finish must then
    /// replace the stale mapping instead of failing with `alreadyMapped`.
    func testASuggestionOverAStaleSpaceIdentityFinishesByReplacingTheMapping() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        api.profileEnvelopes["uuid-a"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Personal", ark: try XCTUnwrap(controller.manager.currentARK))
        _ = try await controller.profileKeys.adoptRemoteProfile(uuid: "uuid-a", forLocalProfile: "Default", isDefault: true)
        store.map["LOCAL-1"] = "stale-identity"
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"))

        await wizard.finish(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1")
    }

    // MARK: - 5. Finish fails at step 1

    /// Assert a reread, not a fixed value. On failure, applyPairingDecisions calls startPairing
    /// to reload candidates; the wizard must display that new table (§5.5).
    /// Start with registerNew(Default), the sole local Profile and an empty account. Finish
    /// first revalidates the reviewed candidates (validateCurrentReview), so the account change
    /// and the one-shot failure are both injected at the PUT itself: injected earlier, that
    /// revalidation would consume the failure on its own envelope GET and never reach the PUT.
    func testAFailedProfileStepGoesBackToStepOneWithTheReloadedCandidates() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        // Only the Default against an empty account: nothing to choose, so the Profiles page is hidden.
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        XCTAssertEqual(wizard.visibleSteps, [.spaces])
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        let remoteEnvelope = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Home",
            ark: try XCTUnwrap(controller.manager.currentARK))
        api.beforePutProfileKey = { [api] in
            api.beforePutProfileKey = nil
            api.profileEnvelopes["uuid-remote"] = remoteEnvelope
            api.profileEndpointErrorOnce = KeyAPIError.http(500, "boom")
        }
        await wizard.finish(controller: controller)

        XCTAssertNil(api.profileEndpointErrorOnce, "The registerNew PUT must consume the failure")
        guard case .profiles(_, let reloaded) = wizard.phase else {
            return XCTFail("expected to land back on step 1")
        }
        XCTAssertEqual(reloaded.map(\.uuid), ["uuid-remote"], "Render the reloaded candidate table")
        XCTAssertEqual(wizard.step, .profiles)
        XCTAssertEqual(wizard.visibleSteps, [.profiles, .spaces], "The step bar lists the page now shown")
        XCTAssertTrue(!gate.isPaired, "The gate must stay closed")
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
        XCTAssertTrue(!gate.isPaired)
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
                let work = Task { () -> Result<PhiAccountSpacePreview, PhiSpacePreviewError> in
                    try? await Task.sleep(for: .seconds(2))
                    return .success(.init(spaces: [], skippedEntityCount: 0))
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
            preview: { await hold.enter(); return .success(.init(spaces: [], skippedEntityCount: 0)) })
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
            preview: { await hold.enter(); return .success(.init(spaces: spaces, skippedEntityCount: 0)) })

        // First load: block preview.
        let first = Task { await wizard.start(controller: controller) }
        var spins = 0
        while await hold.calls == 0, spins < 10_000 { spins += 1; await Task.yield() }
        let calls = await hold.calls
        XCTAssertEqual(calls, 1, "The first load is blocked in preview")

        // Second load, as used by gate re-drive: preview passes and the load completes. Only the Default
        // exists, so the plan hides the Profiles page and the load lands on Spaces.
        await wizard.start(controller: controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
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
        // The page plan's navigation: Back to a hidden Profiles page is a no-op, not a reload.
        XCTAssertFalse(wizard.canGoBackToProfiles)
        wizard.backToProfiles()
        guard case .spaces = wizard.phase else { return XCTFail("Back never opens a hidden Profiles page") }
        XCTAssertEqual(wizard.visibleSteps, [.spaces])
        XCTAssertEqual(wizard.keyLayer.phase, afterLoad,
                       "The wizard only reads keyLayer.phase throughout the interaction")
    }

    /// The Profiles page's Continue reaches the same frozen decisions without touching keyLayer.phase.
    func testContinuingFromTheProfilesPageNeverWritesKeyLayerPhase() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")],
            profiles: Self.profilesWithExtra)
        await wizard.start(controller: controller)
        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles") }
        let afterLoad = wizard.keyLayer.phase
        await wizard.continueFromProfiles(controller: controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        wizard.backToProfiles()
        guard case .profiles = wizard.phase else { return XCTFail("Back returns to a shown Profiles page") }
        XCTAssertEqual(wizard.keyLayer.phase, afterLoad)
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
            uuid: "uuid-claimed", forLocalProfile: "Default", isDefault: true)
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
        XCTAssertTrue(!gate.isPaired)
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
        XCTAssertFalse(!gate.isPaired)
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

    // MARK: - Profile entity tombstones

    /// An account Profile deleted on another device keeps its registry row; the preview's
    /// tombstone for its `phi-profile:` tag keeps it out of the choices.
    func testAnAccountProfileWithATombstoneIsNotOffered() async throws {
        let deletedHash = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.profileClientTag("uuid-deleted"))
        let (wizard, controller, _, api) = try await makeWizard(
            locals: [], accountSpaces: [], preview: {
                .success(.init(spaces: [], skippedEntityCount: 0, deletedProfileTagHashes: [deletedHash]))
            })
        let ark = try XCTUnwrap(controller.manager.currentARK)
        for (uuid, name) in [("uuid-live", "Work"), ("uuid-deleted", "Old")] {
            api.profileEnvelopes[uuid] = try ProfileKeyManager.sealProfilePayload(
                key: Data(repeating: 7, count: 32), name: name, ark: ark)
        }

        await wizard.start(controller: controller)

        guard case .profiles(_, let remotes) = wizard.phase else { return XCTFail("expected .profiles, got \(wizard.phase)") }
        XCTAssertEqual(remotes.map(\.uuid), ["uuid-live"])
    }

    /// A rename travels through the Profile entity, never the registry envelope; the wizard
    /// shows the entity's name and keeps the registry name only where no entity was read.
    func testAnAccountProfileIsOfferedUnderItsEntityName() async throws {
        let (wizard, controller, _, api) = try await makeWizard(
            locals: [], accountSpaces: [], preview: {
                .success(.init(spaces: [], skippedEntityCount: 0, profileNames: ["uuid-renamed": "Alpha"]))
            })
        let ark = try XCTUnwrap(controller.manager.currentARK)
        for (uuid, name) in [("uuid-renamed", "P168-1"), ("uuid-plain", "Work")] {
            api.profileEnvelopes[uuid] = try ProfileKeyManager.sealProfilePayload(
                key: Data(repeating: 7, count: 32), name: name, ark: ark)
        }

        await wizard.start(controller: controller)

        guard case .profiles(_, let remotes) = wizard.phase else { return XCTFail("expected .profiles, got \(wizard.phase)") }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: remotes.map { ($0.uuid, $0.name) }),
                       ["uuid-renamed": "Alpha", "uuid-plain": "Work"])
    }

    /// The entity name replaces only the name: the envelope's default flag stays
    /// with the renamed Profile, so the local Default still preselects it (two
    /// Macs in different languages, 2026-10-14).
    func testAnEntityNamedAccountProfileKeepsItsDefaultFlag() async throws {
        // A second local Profile keeps the Profiles page in view; with only the Default this account would
        // auto-complete.
        let (wizard, controller, _, api) = try await makeWizard(
            locals: [], accountSpaces: [], profiles: Self.profilesWithExtra, preview: {
                .success(.init(spaces: [], skippedEntityCount: 0,
                               profileNames: ["uuid-default": "Mein Phi", "uuid-plain": "Work"]))
            })
        let ark = try XCTUnwrap(controller.manager.currentARK)
        for (uuid, name, isDefault) in [("uuid-default", "Your Phi", true), ("uuid-plain", "Work", false)] {
            api.profileEnvelopes[uuid] = try ProfileKeyManager.sealProfilePayload(
                key: Data(repeating: 7, count: 32), name: name, isDefault: isDefault, ark: ark)
        }

        await wizard.start(controller: controller)

        guard case .profiles(_, let remotes) = wizard.phase else { return XCTFail("expected .profiles, got \(wizard.phase)") }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: remotes.map { ($0.uuid, $0.isDefault) }),
                       ["uuid-default": true, "uuid-plain": false])
        XCTAssertEqual(remotes.first(where: { $0.uuid == "uuid-default" })?.name, "Mein Phi")
    }

    // MARK: - Page plan (docs/sync.md, "Pairing page plan")

    /// Seals the account's default Profile and one ordinary Profile into the fake registry.
    private func seedAccountWithDefaultAndWork(_ api: FakeAPI, controller: SyncKeyController) throws {
        let ark = try XCTUnwrap(controller.manager.currentARK)
        api.profileEnvelopes["uuid-default"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(repeating: 1, count: 32), name: "Your Phi", isDefault: true, ark: ark)
        api.profileEnvelopes["uuid-work"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(repeating: 2, count: 32), name: "Work", isDefault: false, ark: ark)
    }

    /// A Mac with only default data joins an account with data: no page is shown, the unclaimed account
    /// Profile is created on this Mac, and the wizard completes.
    func testADefaultOnlyMacAutoCompletesAndCreatesTheUnclaimedAccountProfiles() async throws {
        let creator = FakeProfileCreator()
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default")],
            accountSpaces: [account("acct-1", name: "Work", profileUuid: "uuid-work")],
            profileCreator: creator)
        try seedAccountWithDefaultAndWork(api, controller: controller)

        var seen: [PairingWizardPhase] = []
        let cancellable = wizard.$phase.sink { seen.append($0) }
        await wizard.start(controller: controller)
        cancellable.cancel()

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(wizard.plan?.autoCompletes, true)
        XCTAssertEqual(wizard.visibleSteps, [], "The step bar lists no page")
        XCTAssertFalse(seen.contains { phase in
            switch phase {
            case .profiles, .spaces, .confirmOverwrite: return true
            default: return false
            }
        }, "No decision page is shown")
        XCTAssertEqual(creator.createCalls, ["Work"], "The unclaimed account Profile is created on this Mac")
        XCTAssertEqual(controller.localProfileId(forGlobalUuid: "uuid-work"), "P1")
        XCTAssertEqual(controller.localProfileId(forGlobalUuid: "uuid-default"), "Default",
                       "The Default takes the account default")
        XCTAssertTrue(store.map.isEmpty, "The default Space needs no mapping")
        XCTAssertTrue(gate.isPaired)
    }

    /// The status page shows from the start of an automatic completion, including the preflight that
    /// re-reads the account before anything is written.
    func testAutoCompletionShowsTheStatusPageDuringItsPreflight() async throws {
        let hold = PreviewHold()
        var previews = 0
        let (wizard, controller, _, api) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default")], accountSpaces: [],
            preview: {
                previews += 1
                if previews > 1 { await hold.enter() }
                return .success(.init(spaces: [], skippedEntityCount: 0))
            })
        try seedAccountWithDefaultAndWork(api, controller: controller)

        let run = Task { await wizard.start(controller: controller) }
        var spins = 0
        while await hold.calls == 0, spins < 10_000 { spins += 1; await Task.yield() }
        let calls = await hold.calls
        XCTAssertEqual(calls, 1, "The preflight preview is parked")
        XCTAssertEqual(wizard.phase, .submitting, "The preflight runs behind the status page")
        XCTAssertTrue(wizard.isPreparing, "The preflight is kept, not skipped")
        XCTAssertFalse(gate.isPaired, "Nothing is committed before the preflight passes")

        await hold.release()
        await run.value
        XCTAssertEqual(wizard.phase, .done)
    }

    /// Only the Default here, nothing to choose for it, and a Space to decide: the Profiles page is skipped
    /// and Back is not offered.
    func testTheProfilesPageIsSkippedWhenOnlyTheDefaultProfileExists() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)

        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces, got \(wizard.phase)") }
        XCTAssertEqual(wizard.step, .spaces)
        XCTAssertEqual(wizard.visibleSteps, [.spaces])
        XCTAssertFalse(wizard.canGoBackToProfiles)
        wizard.backToProfiles()
        guard case .spaces = wizard.phase else { return XCTFail("Back never opens a hidden Profiles page") }
    }

    /// With the Spaces page hidden, the Profiles page's primary action submits directly.
    func testTheProfilesPageFinishesWhenTheSpacesPageIsHidden() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default")], accountSpaces: [],
            profiles: Self.profilesWithExtra)
        await wizard.start(controller: controller)
        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles") }
        XCTAssertEqual(wizard.visibleSteps, [.profiles])

        await wizard.continueFromProfiles(controller: controller)

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertTrue(gate.isPaired)
    }

    /// An incomplete preview never completes on its own, even when nothing else needs a decision.
    func testAnIncompletePreviewNeverAutoCompletes() async throws {
        let (wizard, controller, _, api) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default")], accountSpaces: [],
            preview: { .success(.init(spaces: [], skippedEntityCount: 1)) })
        try seedAccountWithDefaultAndWork(api, controller: controller)

        await wizard.start(controller: controller)

        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles, got \(wizard.phase)") }
        XCTAssertEqual(wizard.plan?.autoCompletes, false)
        XCTAssertTrue(wizard.profileRemoteChoices.isEmpty, "Nothing is decided automatically")
        XCTAssertFalse(gate.isPaired)
    }

    /// A brand-new account (created by this flow, nothing in it yet) shows no page: the status page, then
    /// done, with the Default registered and every local Space added as new.
    func testABrandNewAccountAutoCompletesEndToEnd() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Work")],
            accountSpaces: [])
        wizard.shouldCompleteNewAccount = true

        var seen: [PairingWizardPhase] = []
        let cancellable = wizard.$phase.sink { seen.append($0) }
        await wizard.start(controller: controller)
        cancellable.cancel()

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(wizard.visibleSteps, [])
        XCTAssertTrue(seen.contains(.submitting), "The status page shows")
        XCTAssertFalse(seen.contains { phase in
            switch phase {
            case .profiles, .spaces, .confirmOverwrite: return true
            default: return false
            }
        }, "No decision page is shown")
        XCTAssertEqual(api.profileEnvelopes.count, 1, "The Default is registered as a new account Profile")
        XCTAssertNotNil(store.map["LOCAL-1"], "The local Space is added as new")
        XCTAssertNil(store.map[LocalStore.defaultSpaceId], "The default Space keeps its constant identity")
        XCTAssertTrue(gate.isPaired)
    }

    /// A Space-step failure with the Spaces page hidden: Retry submits the same decisions again behind the
    /// status page and completes, instead of opening a Spaces page that is not in the plan.
    func testRetryWithTheSpacesPageHiddenSubmitsAgainAndCompletes() async throws {
        var locals = [local(LocalStore.defaultSpaceId, name: "Default")]
        let (wizard, controller, _, api) = try await makeWizard(
            locals: [], accountSpaces: [account("acct-1", name: "Work")], liveLocals: { locals })
        // The Default registers (a PUT); a local Space edit during it fails the Space step.
        api.beforePutProfileKey = { [api] in
            api.beforePutProfileKey = nil
            locals[0] = self.local(LocalStore.defaultSpaceId, name: "Renamed during apply")
        }

        await wizard.start(controller: controller)
        guard case .error(_, .backToSpaces) = wizard.phase else {
            return XCTFail("expected a Space-step failure, got \(wizard.phase)")
        }
        XCTAssertEqual(wizard.plan?.showsSpaces, false)
        XCTAssertFalse(gate.isPaired)

        locals[0] = local(LocalStore.defaultSpaceId, name: "Default")
        var seen: [PairingWizardPhase] = []
        let cancellable = wizard.$phase.sink { seen.append($0) }
        await wizard.retry(controller: controller)
        cancellable.cancel()

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertFalse(seen.contains { if case .spaces = $0 { return true }; return false },
                       "Retry never opens the hidden Spaces page")
        XCTAssertEqual(api.profileEnvelopes.count, 1, "The registration is reused, not minted again")
        XCTAssertTrue(gate.isPaired)
    }

    /// The account changes while an automatic completion re-reads it: the wizard lands on the Profiles page
    /// (added to the plan), whose primary action then finishes because the Spaces page stays hidden.
    func testAPreflightMismatchDuringAutoCompletionLandsOnTheProfilesPage() async throws {
        var previews = 0
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default")], accountSpaces: [],
            preview: {
                previews += 1
                // A Space appears on another device after the first load.
                let spaces = previews > 1 ? [self.account("acct-1", name: "Work")] : []
                return .success(.init(spaces: spaces, skippedEntityCount: 0))
            })

        await wizard.start(controller: controller)

        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles, got \(wizard.phase)") }
        XCTAssertEqual(wizard.plan?.showsProfiles, true)
        XCTAssertEqual(wizard.plan?.showsSpaces, false, "Primary action is Finish")
        XCTAssertEqual(wizard.visibleSteps, [.profiles])
        XCTAssertFalse(gate.isPaired)

        await wizard.continueFromProfiles(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertTrue(gate.isPaired)
    }

    /// A submission behind the status page that is refused without starting (here the enrollment changed
    /// during the preflight) falls back to the Profiles page instead of a status page with nothing behind it.
    func testARefusedAutomaticSubmissionFallsBackToTheProfilesPage() async throws {
        let hold = PreviewHold()
        var previews = 0
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default")], accountSpaces: [],
            preview: {
                previews += 1
                if previews > 1 { await hold.enter() }
                return .success(.init(spaces: [self.account("acct-1", name: "Work")], skippedEntityCount: 0))
            })

        let run = Task { await wizard.start(controller: controller) }
        var spins = 0
        while await hold.calls == 0, spins < 10_000 { spins += 1; await Task.yield() }
        XCTAssertEqual(wizard.phase, .submitting)
        try gate.beginEnrollment()      // Supersedes this session's enrollment generation.
        await hold.release()
        await run.value

        guard case .profiles = wizard.phase else {
            return XCTFail("expected .profiles, not a hanging status page; got \(wizard.phase)")
        }
        XCTAssertEqual(wizard.plan?.showsProfiles, true)
        XCTAssertFalse(wizard.isPreparing)
        XCTAssertFalse(gate.isPaired)
    }

    // MARK: - Sync method step and "use your account's data" (docs/sync.md, "Sync method and replacing this
    // Mac's data")

    /// Records the local reset the way `LedgerSpaceMappingStore` records mapping writes: what was requested,
    /// and the gate and marker state at each call. `clearFailures` makes that many calls throw.
    @MainActor final class FakeLocalReset: LocalPhiResetting {
        struct ClearCall: Equatable {
            let request: LocalResetRequest
            let pairedWhenCalled: Bool
            let markerSavedWhenCalled: Bool
        }
        var inventoryResult: Result<LocalPhiInventory, Error>
        var clearFailures = 0
        private(set) var clearCalls: [ClearCall] = []
        var markerSaved: () -> Bool = { false }
        var isPaired: () -> Bool = { false }
        var onCleared: (LocalResetRequest) -> Void = { _ in }
        /// Awaited at the start of each clear, to hold the replace on its status page.
        var onClearEntered: (() async -> Void)?

        init(inventory: LocalPhiInventory?) {
            inventoryResult = inventory.map { .success($0) } ?? .failure(PhiLocalDataResetError.inventoryUnavailable)
        }

        func inventory(deleting profileIds: Set<String>) throws -> LocalPhiInventory { try inventoryResult.get() }

        func clear(_ request: LocalResetRequest) async throws {
            clearCalls.append(ClearCall(request: request, pairedWhenCalled: isPaired(),
                                        markerSavedWhenCalled: markerSaved()))
            if let onClearEntered { await onClearEntered() }
            if clearFailures > 0 {
                clearFailures -= 1
                throw PhiLocalDataResetError.postconditionFailed("test")
            }
            onCleared(request)
            inventoryResult = .success(LocalPhiInventory())
        }
    }

    /// The account-scoped marker key's backing data, and the state at each marker write.
    final class MarkerBox {
        struct Write: Equatable {
            let pairedWhenWritten: Bool
            let clearsBefore: Int
            let accountProfilesBefore: Int
        }
        var data: Data?
        var writes: [Write] = []
        /// That many marker saves report failure and store nothing.
        var failSaves = 0
    }

    /// Whether the enrollment record can be persisted (completion fails while false).
    final class EnrollmentBox { var saves = true }

    /// This Mac's Profiles and pairable Spaces; the fake reset removes what a real one would.
    final class LocalBox {
        var profiles: [(profileId: String, displayName: String)]
        var spaces: [PhiLocalSpace]
        init(profiles: [(profileId: String, displayName: String)], spaces: [PhiLocalSpace]) {
            self.profiles = profiles
            self.spaces = spaces
        }
    }

    private struct ReplaceFixture {
        let wizard: PairingWizardViewModel
        let controller: SyncKeyController
        let store: LedgerSpaceMappingStore
        let api: FakeAPI
        let reset: FakeLocalReset
        let marker: MarkerBox
        let local: LocalBox
        let enrollment: EnrollmentBox
    }

    /// Default, a junk Profile the account has no Profile for, and a "Work" Profile that matches the
    /// account's "Work" Profile by name.
    nonisolated private static let profilesWithJunkAndWork: [(profileId: String, displayName: String)] =
        defaultOnlyProfiles + [(profileId: "Profile 2", displayName: "Junk"),
                               (profileId: "Profile 3", displayName: "Work")]

    /// A wizard with the method step enabled, a fake local reset and a marker store, bound to this test's
    /// gate, which clears the marker on completion as the coordinator wires it.
    private func makeReplaceWizard(
        spaces: [PhiLocalSpace],
        accountSpaces: [PhiAccountSpaceSummary],
        profiles: [(profileId: String, displayName: String)] = PairingWizardViewModelTests.defaultOnlyProfiles,
        inventory: LocalPhiInventory? = LocalPhiInventory(),
        resetAvailable: Bool = true,
        creator: FakeProfileCreator? = nil,
        preview: (() async -> Result<PhiAccountSpacePreview, PhiSpacePreviewError>)? = nil
    ) async throws -> ReplaceFixture {
        let api = FakeAPI()
        let manager = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await manager.bootstrap()
        let profileKeys = ProfileKeyManager(api: api, keyManager: manager,
                                            mappingStore: MemoryMappingStore())
        let gate: ProfilePairingGate = self.gate
        let spaceStore = LedgerSpaceMappingStore(gate: gate)
        let local = LocalBox(profiles: profiles, spaces: spaces)
        let marker = MarkerBox()
        let reset = FakeLocalReset(inventory: inventory)
        let markerStore = SyncPairingLocalResetMarkerStore(
            readData: { marker.data },
            writeData: { data in
                if data != nil, marker.failSaves > 0 {
                    marker.failSaves -= 1
                    return false
                }
                if data != nil {
                    MainActor.assumeIsolated {
                        marker.writes.append(MarkerBox.Write(pairedWhenWritten: gate.isPaired,
                                                             clearsBefore: reset.clearCalls.count,
                                                             accountProfilesBefore: api.profileEnvelopes.count))
                    }
                }
                marker.data = data
                return true
            })
        let enrollment = EnrollmentBox()
        try gate.configureEnrollment(deviceKeyID: "test-device", recordData: nil,
                                     saveRecord: { _ in enrollment.saves },
                                     clearLocalResetMarker: { markerStore.clear() })
        reset.isPaired = { gate.isPaired }
        reset.markerSaved = { marker.data != nil }
        reset.onCleared = { request in
            local.profiles.removeAll { request.deleteProfileIds.contains($0.profileId) }
            local.spaces.removeAll { $0.spaceId != LocalStore.defaultSpaceId }
        }
        let controller = SyncKeyController(
            manager: manager,
            approvals: DeviceApprovalService(api: api, keyManager: manager,
                                             deviceKeyProvider: FakeDeviceKeyProvider()),
            profileKeys: profileKeys,
            spaceKeys: SpaceSyncMappingManager(store: spaceStore),
            localProfilesProvider: { local.profiles },
            notifyChromium: {},
            profileCreator: creator ?? FakeProfileCreator(),
            isPairingComplete: { gate.isPaired },
            localResetMarker: markerStore)
        let wizard = PairingWizardViewModel(
            keyLayer: KeyLayerViewModel(manager: manager),
            previewAccountSpaces: preview ?? { .success(.init(spaces: accountSpaces, skippedEntityCount: 0)) },
            pairableLocalSpaces: { local.spaces },
            themeDisplayName: { _ in nil },
            gate: gate,
            localReset: { _ in resetAvailable ? reset : nil },
            methodStepEnabled: true)
        return ReplaceFixture(wizard: wizard, controller: controller, store: spaceStore, api: api,
                              reset: reset, marker: marker, local: local, enrollment: enrollment)
    }

    /// Starts the wizard, chooses "use your account's data" and lands on its confirmation page. Nothing is
    /// chosen there: every extra local Profile is deleted.
    private func startReplacing(_ fixture: ReplaceFixture) async throws -> ReplaceLocalReview {
        try seedAccountWithDefaultAndWork(fixture.api, controller: fixture.controller)
        await fixture.wizard.start(controller: fixture.controller)
        guard case .method = fixture.wizard.phase else {
            XCTFail("expected .method, got \(fixture.wizard.phase)")
            throw CancellationError()
        }
        fixture.wizard.selectedMethod = .useAccount
        await fixture.wizard.continueFromMethod(controller: fixture.controller)
        guard case .confirmReplaceLocal(let review) = fixture.wizard.phase else {
            XCTFail("expected .confirmReplaceLocal, got \(fixture.wizard.phase)")
            throw CancellationError()
        }
        return review
    }

    /// This Mac has a Space beyond the default: the method step shows first, merge continues to the
    /// Spaces page (the Profiles page is hidden), and Back from there returns to the method step.
    func testTheMethodStepComesFirstAndMergeContinuesToItsPages() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "Work")])
        let wizard = fixture.wizard
        await wizard.start(controller: fixture.controller)

        guard case .method(let summary) = wizard.phase else { return XCTFail("expected .method, got \(wizard.phase)") }
        XCTAssertEqual(wizard.step, .method)
        XCTAssertEqual(summary.local, PairingDataSummary.Counts(profiles: 1, spaces: 2, bookmarks: 0,
                                                                pinnedTabs: 0, urlRules: 0))
        XCTAssertEqual(summary.account.spaces, 2, "The account's Spaces plus its default Space")
        XCTAssertNil(summary.account.bookmarks, "A preview without counts names the account's bookmarks")
        XCTAssertEqual(wizard.visibleSteps, [.method, .spaces])
        XCTAssertFalse(wizard.methodStepFinishes)
        wizard.selectedMethod = .useAccount
        XCTAssertEqual(wizard.visibleSteps, [.method, .confirm], "The step bar follows the selected method")
        wizard.selectedMethod = .merge

        await wizard.continueFromMethod(controller: fixture.controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces, got \(wizard.phase)") }
        XCTAssertTrue(wizard.canGoBackFromSpaces)
        XCTAssertFalse(wizard.canGoBackToProfiles)
        wizard.backToProfiles()
        guard case .method = wizard.phase else { return XCTFail("Back from Spaces returns to the method step") }
        XCTAssertFalse(gate.isPaired)
    }

    /// PHI-1716 PR-4: the preview's bookmark, pinned tab and URL rule counts reach the account row of the
    /// method step and the confirmation's "Downloaded from your account" card; a nil count stays a name.
    func testTheAccountRowShowsThePreviewCountsAndNamesWhatItCannotCount() async throws {
        let accountSpaces = [account("acct-1", name: "Work")]
        var preview = PhiAccountSpacePreview(spaces: accountSpaces, skippedEntityCount: 0)
        preview.bookmarkCount = 12
        preview.pinnedTabCount = 0
        preview.urlRuleCount = nil
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Work")],
            accountSpaces: accountSpaces, preview: { .success(preview) })
        try seedAccountWithDefaultAndWork(fixture.api, controller: fixture.controller)
        let wizard = fixture.wizard
        await wizard.start(controller: fixture.controller)

        guard case .method(let summary) = wizard.phase else { return XCTFail("expected .method, got \(wizard.phase)") }
        XCTAssertEqual(summary.account.bookmarks, 12)
        XCTAssertEqual(summary.account.pinnedTabs, 0)
        XCTAssertNil(summary.account.urlRules)
        let line = PairingDataSummary.stripLine(label: "Account", counts: summary.account)
        XCTAssertTrue(line.contains(PairingDataSummary.phrase(.bookmarks, count: 12)), line)
        XCTAssertTrue(line.contains(PairingDataSummary.phrase(.pinnedTabs, count: 0)), line)
        XCTAssertTrue(line.contains(PairingDataSummary.phrase(.urlRules, count: nil)), line)
        XCTAssertNotEqual(PairingDataSummary.phrase(.bookmarks, count: 12),
                          PairingDataSummary.phrase(.bookmarks, count: nil), "A count is not the kind's name")

        wizard.selectedMethod = .useAccount
        await wizard.continueFromMethod(controller: fixture.controller)
        guard case .confirmReplaceLocal(let review) = wizard.phase else {
            return XCTFail("expected .confirmReplaceLocal, got \(wizard.phase)")
        }
        XCTAssertEqual(review.downloaded, summary.account)
        XCTAssertEqual(review.downloaded.listedKinds([.bookmarks, .pinnedTabs, .urlRules]), [.bookmarks, .urlRules],
                       "A zero count is hidden and an uncounted kind is listed by name")
        XCTAssertFalse(gate.isPaired)
    }

    /// The inventory cannot be read: emptiness cannot be proven, so a default-only Mac still sees the step.
    func testAnUnreadableInventoryShowsTheMethodStep() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default")], accountSpaces: [], inventory: nil)
        try seedAccountWithDefaultAndWork(fixture.api, controller: fixture.controller)
        await fixture.wizard.start(controller: fixture.controller)
        guard case .method(let summary) = fixture.wizard.phase else {
            return XCTFail("expected .method, got \(fixture.wizard.phase)")
        }
        XCTAssertNil(summary.local.bookmarks, "An unreadable count is named, never zero")
        XCTAssertFalse(gate.isPaired)
    }

    /// Bookmarks alone make a default-only Mac show the step; with nothing after it, merge's primary
    /// action is Finish and completes from the method step.
    func testMergeFinishesFromTheMethodStepWhenNoPageFollows() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default")], accountSpaces: [],
            inventory: LocalPhiInventory(bookmarks: 5))
        try seedAccountWithDefaultAndWork(fixture.api, controller: fixture.controller)
        let wizard = fixture.wizard
        await wizard.start(controller: fixture.controller)
        guard case .method = wizard.phase else { return XCTFail("expected .method, got \(wizard.phase)") }
        XCTAssertEqual(wizard.visibleSteps, [.method])
        XCTAssertTrue(wizard.methodStepFinishes, "Merge has no page after the method step")
        wizard.selectedMethod = .useAccount
        XCTAssertFalse(wizard.methodStepFinishes, "Use your account's data continues to its confirmation")
        wizard.selectedMethod = .merge

        await wizard.continueFromMethod(controller: fixture.controller)

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertTrue(gate.isPaired)
        XCTAssertNotNil(fixture.controller.localProfileId(forGlobalUuid: "uuid-work"),
                        "The unclaimed account Profile is created on this Mac")
        XCTAssertTrue(fixture.reset.clearCalls.isEmpty, "Merging never removes local data")
        XCTAssertNil(fixture.marker.data)
    }

    /// The replace sequence: Profile decisions, then the marker, then the local reset, then enrollment,
    /// then resolve. The extra Profile is deleted without any choice (no decision, straight to the reset);
    /// the same-name Profile adopts its account Profile and is never deleted.
    func testReplaceRunsProfilesThenMarkerThenClearThenEnrollmentThenResolve() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [account("acct-1", name: "Work", profileUuid: "uuid-work")],
            profiles: Self.profilesWithJunkAndWork,
            inventory: LocalPhiInventory(nonDefaultSpaceIds: ["LOCAL-1"], bookmarks: 3, pinnedTabs: 2))
        let review = try await startReplacing(fixture)
        XCTAssertEqual(review.extraLocals.map(\.profileId), ["Profile 2"],
                       "Only the extra Profile is listed; the same-name one is matched")
        XCTAssertEqual(review.removed, PairingDataSummary.Counts(profiles: 1, spaces: 1, bookmarks: 3,
                                                                 pinnedTabs: 2, urlRules: 0))
        XCTAssertFalse(review.defaultUnavailable)
        XCTAssertEqual(fixture.wizard.step, .confirm)
        let accountProfilesBefore = fixture.api.profileEnvelopes.count
        resolveCount = 0

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        XCTAssertEqual(fixture.wizard.phase, .done)
        XCTAssertEqual(fixture.marker.writes, [MarkerBox.Write(pairedWhenWritten: false, clearsBefore: 0,
                                                               accountProfilesBefore: accountProfilesBefore)],
                       "The marker precedes the reset, and no Profile was registered with the account")
        XCTAssertEqual(fixture.reset.clearCalls, [FakeLocalReset.ClearCall(
            request: LocalResetRequest(deleteProfileIds: ["Profile 2"]),
            pairedWhenCalled: false, markerSavedWhenCalled: true)])
        XCTAssertTrue(gate.isPaired, "Enrollment completes after the reset")
        XCTAssertNil(fixture.marker.data, "Completion clears the marker")
        XCTAssertGreaterThan(resolveCount, 0, "resolveMappings() runs last")
        XCTAssertEqual(fixture.controller.profileKeys.mappedGlobalUuid(forProfileId: "Profile 3"), "uuid-work",
                       "The same-name Profile adopts its account Profile")
        XCTAssertNil(fixture.controller.profileKeys.mappedGlobalUuid(forProfileId: "Profile 2"),
                     "The deleted Profile is never registered")
        XCTAssertEqual(fixture.controller.localProfileId(forGlobalUuid: "uuid-default"), "Default")
        XCTAssertEqual(fixture.api.profileEnvelopes.count, accountProfilesBefore, "The account gains no Profile")
        XCTAssertTrue(fixture.store.map.isEmpty, "Replacing maps no Space")
    }

    /// The reset stops part-way: the gate stays unpaired with the marker set, the method locks, and Retry
    /// runs the sequence again and converges.
    func testAClearFailureKeepsTheGateUnpairedWithTheMarkerAndRetryConverges() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [account("acct-1", name: "Work", profileUuid: "uuid-work")],
            profiles: Self.profilesWithJunkAndWork)
        _ = try await startReplacing(fixture)
        fixture.reset.clearFailures = 1

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        guard case .error(let message, .resumeReplace) = fixture.wizard.phase else {
            return XCTFail("expected .error(.resumeReplace), got \(fixture.wizard.phase)")
        }
        XCTAssertEqual(message, PairingWizardStrings.replaceLocalFailed)
        XCTAssertFalse(gate.isPaired)
        XCTAssertNotNil(fixture.marker.data, "The marker stays for the resume")
        XCTAssertTrue(fixture.wizard.methodLocked)
        XCTAssertFalse(AppModalPairingHost.reloadAllowed(for: fixture.wizard.phase))

        await fixture.wizard.retry(controller: fixture.controller)

        XCTAssertEqual(fixture.wizard.phase, .done)
        XCTAssertEqual(fixture.reset.clearCalls.count, 2, "Retry runs the reset again")
        XCTAssertTrue(fixture.reset.clearCalls.allSatisfy { !$0.pairedWhenCalled && $0.markerSavedWhenCalled })
        XCTAssertEqual(fixture.reset.clearCalls.map(\.request),
                       Array(repeating: LocalResetRequest(deleteProfileIds: ["Profile 2"]), count: 2))
        XCTAssertTrue(gate.isPaired)
        XCTAssertNil(fixture.marker.data)
    }

    /// The replace preflight compares only the account side: a new account Space returns to the
    /// confirmation with fresh data and writes nothing, while a new local Space does not stop it.
    func testAnAccountChangeReturnsToTheConfirmationButALocalSpaceChangeDoesNot() async throws {
        var previews = 0
        var accountSpaces = [account("acct-1", name: "Work", profileUuid: "uuid-work")]
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [], profiles: Self.profilesWithJunkAndWork,
            preview: {
                previews += 1
                return .success(.init(spaces: accountSpaces, skippedEntityCount: 0))
            })
        _ = try await startReplacing(fixture)
        accountSpaces.append(account("acct-2", name: "Reading", profileUuid: "uuid-work"))

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        guard case .confirmReplaceLocal(let review) = fixture.wizard.phase else {
            return XCTFail("expected .confirmReplaceLocal, got \(fixture.wizard.phase)")
        }
        XCTAssertEqual(review.downloaded.spaces, 3, "The fresh account data is shown")
        XCTAssertEqual(review.extraLocals.map(\.profileId), ["Profile 2"], "The deleted Profiles are listed again")
        XCTAssertTrue(fixture.reset.clearCalls.isEmpty)
        XCTAssertNil(fixture.marker.data)
        XCTAssertFalse(gate.isPaired)

        // A Space added on this Mac is not compared: it is removed like the rest.
        fixture.local.spaces.append(local("LOCAL-2", name: "Added meanwhile"))
        await fixture.wizard.replaceLocal(controller: fixture.controller)
        XCTAssertEqual(fixture.wizard.phase, .done)
        XCTAssertEqual(fixture.reset.clearCalls.count, 1)
    }

    /// Finish later on the confirmation, before anything was written: no marker, no reset, and the next
    /// load starts from merge.
    func testFinishLaterBeforeTheMarkerWritesNothingAndClearsTheSelection() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [], profiles: Self.profilesWithJunkAndWork)
        _ = try await startReplacing(fixture)
        let accountProfiles = fixture.api.profileEnvelopes.count

        XCTAssertTrue(fixture.wizard.leaveWithoutApplying())

        XCTAssertNil(fixture.marker.data)
        XCTAssertTrue(fixture.marker.writes.isEmpty)
        XCTAssertTrue(fixture.reset.clearCalls.isEmpty)
        XCTAssertEqual(fixture.api.profileEnvelopes.count, accountProfiles, "No Profile was registered")
        XCTAssertEqual(fixture.wizard.selectedMethod, .merge)
        XCTAssertNil(fixture.wizard.replaceReview)
        XCTAssertNil(fixture.wizard.plan)
        XCTAssertEqual(fixture.wizard.visibleSteps, [])

        await fixture.wizard.start(controller: fixture.controller)
        guard case .method = fixture.wizard.phase else { return XCTFail("A fresh load starts at the method step") }
        XCTAssertEqual(fixture.wizard.selectedMethod, .merge)
    }

    /// A marker from an earlier session (a replace that stopped, then Finish later): the next load lands on
    /// the confirmation, locked to "use your account's data" with Back unavailable, and Replace finishes
    /// with the saved deletions.
    func testARestartWithAMarkerLandsOnALockedConfirmation() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [account("acct-1", name: "Work", profileUuid: "uuid-work")],
            profiles: Self.profilesWithJunkAndWork)
        try seedAccountWithDefaultAndWork(fixture.api, controller: fixture.controller)
        try fixture.controller.savePairingLocalResetMarker(deleteProfileIds: ["Profile 2"])
        let wizard = fixture.wizard

        await wizard.start(controller: fixture.controller)

        guard case .confirmReplaceLocal(let review) = wizard.phase else {
            return XCTFail("expected .confirmReplaceLocal, got \(wizard.phase)")
        }
        XCTAssertEqual(review.extraLocals.map(\.profileId), ["Profile 2"], "The marker's Profiles are listed")
        XCTAssertEqual(review.removed.profiles, 1)
        XCTAssertTrue(wizard.methodLocked)
        XCTAssertFalse(wizard.canGoBackToMethod, "Back is not offered")
        XCTAssertEqual(wizard.selectedMethod, .useAccount)
        XCTAssertEqual(wizard.step, .confirm)
        XCTAssertEqual(wizard.visibleSteps, [.method, .confirm])
        wizard.backToMethod()
        guard case .confirmReplaceLocal = wizard.phase else { return XCTFail("Back is refused while locked") }
        XCTAssertFalse(AppModalPairingHost.reloadAllowed(for: wizard.phase))

        await wizard.replaceLocal(controller: fixture.controller)

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(fixture.reset.clearCalls.map(\.request), [LocalResetRequest(deleteProfileIds: ["Profile 2"])])
        XCTAssertTrue(gate.isPaired)
        XCTAssertNil(fixture.marker.data)
    }

    /// Replace deletes every extra local Profile without asking: the marker saves the full set, and after a
    /// stopped reset the locked page lists exactly the marker's Profiles. A Profile created after the
    /// marker was written is not listed and not deleted; it registers with the account.
    func testReplaceSavesEveryExtraInTheMarkerAndTheLockedPageListsOnlyTheMarkersProfiles() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [account("acct-1", name: "Work", profileUuid: "uuid-work")],
            profiles: Self.profilesWithJunkAndWork + [(profileId: "Profile 4", displayName: "Scratch")])
        let review = try await startReplacing(fixture)
        XCTAssertEqual(review.extraLocals.map(\.profileId), ["Profile 2", "Profile 4"])
        XCTAssertEqual(review.removed.profiles, 2)
        fixture.reset.clearFailures = 1

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        guard case .error(_, .resumeReplace) = fixture.wizard.phase else {
            return XCTFail("expected .error(.resumeReplace), got \(fixture.wizard.phase)")
        }
        XCTAssertEqual(fixture.controller.pairingLocalResetMarker()?.deleteProfileIds, ["Profile 2", "Profile 4"],
                       "The marker holds every extra local Profile")
        XCTAssertTrue(fixture.wizard.leaveWithoutApplying())
        fixture.local.profiles.append((profileId: "Profile 5", displayName: "Later"))

        await fixture.wizard.start(controller: fixture.controller)

        guard case .confirmReplaceLocal(let locked) = fixture.wizard.phase else {
            return XCTFail("expected the locked confirmation, got \(fixture.wizard.phase)")
        }
        XCTAssertTrue(fixture.wizard.methodLocked)
        XCTAssertEqual(locked.extraLocals.map(\.profileId), ["Profile 2", "Profile 4"],
                       "The locked page lists exactly the marker's Profiles")
        XCTAssertEqual(locked.removed.profiles, 2)

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        XCTAssertEqual(fixture.wizard.phase, .done)
        XCTAssertEqual(fixture.reset.clearCalls.map(\.request),
                       Array(repeating: LocalResetRequest(deleteProfileIds: ["Profile 2", "Profile 4"]), count: 2))
        XCTAssertNotNil(fixture.controller.profileKeys.mappedGlobalUuid(forProfileId: "Profile 5"),
                        "A Profile created after the marker registers instead of being deleted")
        XCTAssertEqual(fixture.controller.profileKeys.mappedGlobalUuid(forProfileId: "Profile 3"), "uuid-work")
        XCTAssertTrue(gate.isPaired)
        XCTAssertNil(fixture.marker.data)
    }

    /// The "Removed from this Mac" card names the deleted Profiles in one row with a caption.
    func testTheRemovedProfilesRowNamesEveryDeletedProfile() {
        let scratch = PairingLocal(profileId: "Profile 2", displayName: "Scratch", isDefault: false)
        let work2 = PairingLocal(profileId: "Profile 3", displayName: "Work2", isDefault: false)
        XCTAssertEqual(ReplaceLocalConfirmView.deletedProfilesText([scratch]), "1 profile: Scratch")
        XCTAssertEqual(ReplaceLocalConfirmView.deletedProfilesText([scratch, work2]), "2 profiles: Scratch, Work2")
        XCTAssertEqual(ReplaceLocalConfirmView.deletedProfilesCaption(count: 1),
                       "Its history, extensions and site data on this Mac are deleted too.")
        XCTAssertEqual(ReplaceLocalConfirmView.deletedProfilesCaption(count: 2),
                       "Their history, extensions and site data on this Mac are deleted too.")
    }

    /// Navigating the method step and the confirmation reads keyLayer.phase only.
    func testTheMethodStepAndConfirmationNeverWriteKeyLayerPhase() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [], profiles: Self.profilesWithJunkAndWork)
        try seedAccountWithDefaultAndWork(fixture.api, controller: fixture.controller)
        let wizard = fixture.wizard
        await wizard.start(controller: fixture.controller)
        let afterLoad = wizard.keyLayer.phase
        wizard.selectedMethod = .useAccount
        await wizard.continueFromMethod(controller: fixture.controller)
        wizard.backToMethod()
        guard case .method = wizard.phase else { return XCTFail("Back returns to the method step") }
        wizard.selectedMethod = .merge
        await wizard.continueFromMethod(controller: fixture.controller)
        guard case .profiles = wizard.phase else { return XCTFail("Merge continues to the Profiles page") }
        wizard.backToMethod()
        XCTAssertEqual(wizard.keyLayer.phase, afterLoad,
                       "The wizard only reads keyLayer.phase throughout the interaction")
    }

    // MARK: - Review follow-ups, at the real default (method step enabled)

    private static func isDecisionPage(_ phase: PairingWizardPhase) -> Bool {
        switch phase {
        case .method, .profiles, .spaces, .confirmOverwrite, .confirmReplaceLocal: return true
        default: return false
        }
    }

    /// (a) A default-only Mac with a readable, empty inventory has nothing to replace: no method step, and
    /// the wizard completes on its own.
    func testADefaultOnlyMacWithAnEmptyInventoryAutoCompletesWithoutTheMethodStep() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default")],
            accountSpaces: [account("acct-1", name: "Work", profileUuid: "uuid-work")])
        try seedAccountWithDefaultAndWork(fixture.api, controller: fixture.controller)
        var seen: [PairingWizardPhase] = []
        let cancellable = fixture.wizard.$phase.sink { seen.append($0) }
        await fixture.wizard.start(controller: fixture.controller)
        cancellable.cancel()

        XCTAssertEqual(fixture.wizard.phase, .done)
        XCTAssertEqual(fixture.wizard.plan?.showsMethod, false)
        XCTAssertFalse(seen.contains(where: Self.isDecisionPage), "No page is shown")
        XCTAssertTrue(fixture.reset.clearCalls.isEmpty)
        XCTAssertTrue(gate.isPaired)
    }

    /// (b) Merge through the method step; the account changes before Finish, so the preflight reveals the
    /// Profiles page, and Back from there returns to the method step with the refreshed counts.
    func testAMergePreflightMismatchRevealsProfilesAndBackShowsRefreshedCounts() async throws {
        var accountSpaces = [account("acct-1", name: "Work", profileUuid: "uuid-work")]
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Mine")],
            accountSpaces: [],
            preview: { .success(.init(spaces: accountSpaces, skippedEntityCount: 0)) })
        try seedAccountWithDefaultAndWork(fixture.api, controller: fixture.controller)
        let wizard = fixture.wizard
        await wizard.start(controller: fixture.controller)
        guard case .method(let before) = wizard.phase else { return XCTFail("expected .method, got \(wizard.phase)") }
        XCTAssertEqual(before.account.spaces, 2)
        await wizard.continueFromMethod(controller: fixture.controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces, got \(wizard.phase)") }
        wizard.addAllAsNew()
        accountSpaces.append(account("acct-2", name: "Reading", profileUuid: "uuid-work"))

        await wizard.finish(controller: fixture.controller)

        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles, got \(wizard.phase)") }
        XCTAssertEqual(wizard.visibleSteps, [.method, .profiles, .spaces])
        XCTAssertFalse(gate.isPaired)
        XCTAssertTrue(fixture.store.map.isEmpty, "Nothing is written on a mismatch")
        XCTAssertTrue(wizard.canGoBackToMethod)
        wizard.backToMethod()
        guard case .method(let after) = wizard.phase else { return XCTFail("expected .method, got \(wizard.phase)") }
        XCTAssertEqual(after.account.spaces, 3, "The method step shows the refreshed account")
    }

    /// (c) A Profile decision fails during the replace: nothing local was touched, no marker, the flow
    /// stays unlocked, and Retry reaches completion (through the confirmation again if the partial progress
    /// changed the candidates).
    func testAFailedProfileDecisionDuringReplaceWritesNoMarkerAndRetryWorks() async throws {
        // Creating the account's unclaimed "Work" Profile on this Mac fails once.
        let creator = FakeProfileCreator()
        creator.createResults = [nil]
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [],
            profiles: Self.defaultOnlyProfiles + [(profileId: "Profile 2", displayName: "Junk")],
            creator: creator)
        _ = try await startReplacing(fixture)

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        guard case .error(let message, .resumeReplace) = fixture.wizard.phase else {
            return XCTFail("expected .error(.resumeReplace), got \(fixture.wizard.phase)")
        }
        XCTAssertEqual(message, PairingWizardStrings.applyFailed, "Nothing was lost yet")
        XCTAssertNil(fixture.marker.data)
        XCTAssertTrue(fixture.marker.writes.isEmpty)
        XCTAssertTrue(fixture.reset.clearCalls.isEmpty)
        XCTAssertFalse(fixture.wizard.methodLocked)
        XCTAssertFalse(gate.isPaired)

        await fixture.wizard.retry(controller: fixture.controller)
        if case .confirmReplaceLocal = fixture.wizard.phase {
            XCTAssertTrue(fixture.wizard.canGoBackToMethod, "Still unlocked")
            await fixture.wizard.replaceLocal(controller: fixture.controller)
        }
        XCTAssertEqual(fixture.wizard.phase, .done)
        XCTAssertEqual(fixture.reset.clearCalls.map(\.request), [LocalResetRequest(deleteProfileIds: ["Profile 2"])])
        XCTAssertNil(fixture.controller.profileKeys.mappedGlobalUuid(forProfileId: "Profile 2"))
        XCTAssertTrue(gate.isPaired)
    }

    /// (d) The marker cannot be saved: the reset never starts, and Retry completes.
    func testAFailedMarkerSaveStopsBeforeTheResetAndRetryWorks() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [], profiles: Self.profilesWithJunkAndWork)
        _ = try await startReplacing(fixture)
        fixture.marker.failSaves = 1

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        guard case .error(let message, .resumeReplace) = fixture.wizard.phase else {
            return XCTFail("expected .error(.resumeReplace), got \(fixture.wizard.phase)")
        }
        XCTAssertEqual(message, PairingWizardStrings.applyFailed)
        XCTAssertNil(fixture.marker.data)
        XCTAssertTrue(fixture.reset.clearCalls.isEmpty, "No reset without the marker")
        XCTAssertFalse(fixture.wizard.methodLocked)

        await fixture.wizard.retry(controller: fixture.controller)

        XCTAssertEqual(fixture.wizard.phase, .done)
        XCTAssertEqual(fixture.reset.clearCalls.count, 1)
        XCTAssertTrue(fixture.reset.clearCalls.allSatisfy(\.markerSavedWhenCalled))
        XCTAssertTrue(gate.isPaired)
        XCTAssertNil(fixture.marker.data)
    }

    /// (e) Enrollment fails after a successful reset: the error says the replace is unfinished, the marker
    /// stays, and after Finish later the next load lands on the locked confirmation and completes.
    func testAnEnrollmentFailureAfterTheResetKeepsTheMarkerAndResumesLocked() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [account("acct-1", name: "Work", profileUuid: "uuid-work")],
            profiles: Self.profilesWithJunkAndWork)
        _ = try await startReplacing(fixture)
        fixture.enrollment.saves = false

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        guard case .error(let message, .resumeReplace) = fixture.wizard.phase else {
            return XCTFail("expected .error(.resumeReplace), got \(fixture.wizard.phase)")
        }
        XCTAssertEqual(message, PairingWizardStrings.replaceLocalFailed,
                       "After the reset ran, the error must not claim nothing was lost")
        XCTAssertEqual(fixture.reset.clearCalls.count, 1)
        XCTAssertNotNil(fixture.marker.data, "The marker stays for the resume")
        XCTAssertFalse(gate.isPaired)

        XCTAssertTrue(fixture.wizard.leaveWithoutApplying(), "Finish later is allowed on the error page")
        fixture.enrollment.saves = true
        await fixture.wizard.start(controller: fixture.controller)
        guard case .confirmReplaceLocal = fixture.wizard.phase else {
            return XCTFail("expected the locked confirmation, got \(fixture.wizard.phase)")
        }
        XCTAssertTrue(fixture.wizard.methodLocked)
        XCTAssertFalse(fixture.wizard.canGoBackToMethod)

        await fixture.wizard.replaceLocal(controller: fixture.controller)

        XCTAssertEqual(fixture.wizard.phase, .done)
        XCTAssertTrue(gate.isPaired)
        XCTAssertNil(fixture.marker.data)
    }

    /// (f) The account has Profiles but no readable default: Replace is unavailable and does nothing.
    func testAnUnavailableAccountDefaultDisablesReplace() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [])
        let ark = try XCTUnwrap(fixture.controller.manager.currentARK)
        fixture.api.profileEnvelopes["uuid-work"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(repeating: 2, count: 32), name: "Work", isDefault: false, ark: ark)
        let wizard = fixture.wizard
        await wizard.start(controller: fixture.controller)
        guard case .method = wizard.phase else { return XCTFail("expected .method, got \(wizard.phase)") }
        wizard.selectedMethod = .useAccount
        await wizard.continueFromMethod(controller: fixture.controller)
        guard case .confirmReplaceLocal(let review) = wizard.phase else {
            return XCTFail("expected .confirmReplaceLocal, got \(wizard.phase)")
        }
        XCTAssertTrue(review.defaultUnavailable)
        XCTAssertFalse(wizard.canReplace)
        let accountProfiles = fixture.api.profileEnvelopes.count

        await wizard.replaceLocal(controller: fixture.controller)

        guard case .confirmReplaceLocal = wizard.phase else { return XCTFail("Replace is a no-op") }
        XCTAssertTrue(fixture.reset.clearCalls.isEmpty)
        XCTAssertNil(fixture.marker.data)
        XCTAssertEqual(fixture.api.profileEnvelopes.count, accountProfiles)
        XCTAssertTrue(wizard.canGoBackToMethod, "Merge stays reachable")
    }

    /// (g) While the replace runs, leaving is refused and a re-drive is not allowed.
    func testLeavingIsRefusedWhileReplacing() async throws {
        let hold = PreviewHold()
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Junk")],
            accountSpaces: [], profiles: Self.profilesWithJunkAndWork)
        _ = try await startReplacing(fixture)
        fixture.reset.onClearEntered = { await hold.enter() }

        let run = Task { await fixture.wizard.replaceLocal(controller: fixture.controller) }
        var spins = 0
        while await hold.calls == 0, spins < 10_000 { spins += 1; await Task.yield() }
        XCTAssertEqual(fixture.wizard.phase, .replacingLocal)
        XCTAssertTrue(fixture.wizard.isApplying)
        XCTAssertFalse(fixture.wizard.leaveWithoutApplying(), "Finish later is refused while replacing")
        XCTAssertFalse(AppModalPairingHost.reloadAllowed(for: fixture.wizard.phase))

        await hold.release()
        await run.value
        XCTAssertEqual(fixture.wizard.phase, .done)
    }

    /// (h) Merge through the method step; a local Space edit during the Profile write fails the Space
    /// step; Retry returns to the Spaces page with the choices and Finish completes.
    func testMergeThroughTheMethodStepRecoversFromASpaceStepFailure() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Mine")],
            accountSpaces: [])
        let wizard = fixture.wizard
        await wizard.start(controller: fixture.controller)
        guard case .method = wizard.phase else { return XCTFail("expected .method, got \(wizard.phase)") }
        await wizard.continueFromMethod(controller: fixture.controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces, got \(wizard.phase)") }
        wizard.addAllAsNew()
        let local = fixture.local
        let original = local.spaces[1]
        // The Default registers (a PUT); a local Space edit during it fails the Space step.
        fixture.api.beforePutProfileKey = { [api = fixture.api] in
            api.beforePutProfileKey = nil
            local.spaces[1] = self.local("LOCAL-1", name: "Renamed during apply")
        }

        await wizard.finish(controller: fixture.controller)

        guard case .error(_, .backToSpaces) = wizard.phase else {
            return XCTFail("expected .error(.backToSpaces), got \(wizard.phase)")
        }
        XCTAssertFalse(gate.isPaired)
        local.spaces[1] = original

        await wizard.retry(controller: fixture.controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces, got \(wizard.phase)") }
        XCTAssertEqual(wizard.visibleSteps, [.method, .spaces])
        await wizard.finish(controller: fixture.controller)

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertNotNil(fixture.store.map["LOCAL-1"])
        XCTAssertTrue(fixture.reset.clearCalls.isEmpty, "Merging never removes local data")
        XCTAssertTrue(gate.isPaired)
    }

    /// Without the local data reset, "use your account's data" is never offered: the method step is not
    /// shown and the merge path runs as before.
    func testNoMethodStepWhenTheResetIsUnavailable() async throws {
        let fixture = try await makeReplaceWizard(
            spaces: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Mine")],
            accountSpaces: [account("acct-1", name: "Work")], resetAvailable: false)
        await fixture.wizard.start(controller: fixture.controller)

        guard case .spaces = fixture.wizard.phase else {
            return XCTFail("expected .spaces, got \(fixture.wizard.phase)")
        }
        XCTAssertEqual(fixture.wizard.plan?.showsMethod, false)
        XCTAssertFalse(fixture.wizard.replaceAvailable)
        XCTAssertFalse(fixture.wizard.canGoBackToMethod)
        XCTAssertEqual(fixture.wizard.visibleSteps, [.spaces])
    }
}
