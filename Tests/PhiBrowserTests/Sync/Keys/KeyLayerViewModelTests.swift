import XCTest
import CryptoKit
@testable import Phi

@MainActor
final class KeyLayerViewModelTests: XCTestCase {
    func testBootstrapMovesToShowingCodeThenDone() async {
        let api = AccountKeyManagerTests.FakeAPI()
        let deviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let vm = KeyLayerViewModel(manager: AccountKeyManager(api: api, deviceKeyProvider: deviceKeyProvider))

        await vm.startBootstrap()
        guard case .showingRecoveryCode(let code) = vm.phase else { return XCTFail("expected code") }
        XCTAssertFalse(code.isEmpty)

        await vm.confirmSaved()
        guard case .done = vm.phase else { return XCTFail("expected done") }
    }

    /// Regression (registration-timing bug): a first-device bootstrap must
    /// register the local profile in the SAME session, not only on the next
    /// launch's startup resolve. Before the fix, `confirmSaved()` set `.done`
    /// without re-running `resolveMappings()`, so the profile's key envelope
    /// was never PUT until a restart — a synced-but-unescrowed profile whose
    /// data no other device could ever recover.
    func testBootstrapRegistersLocalProfileInSession() async {
        let api = AccountKeyManagerTests.FakeAPI()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let pkm = ProfileKeyManager(api: api, keyManager: mgr,
                                    mappingStore: ProfileKeyManagerTests.MemoryMappingStore())
        let approvals = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)
        let controller = SyncKeyController(
            manager: mgr, approvals: approvals, profileKeys: pkm,
            localProfilesProvider: { [(profileId: "Default", displayName: "Default")] },
            notifyChromium: {})
        let vm = KeyLayerViewModel(manager: mgr)

        // Fresh account: beginSetup routes to first-device bootstrap and shows
        // the recovery code. Nothing is registered yet.
        await vm.beginSetup(controller: controller)
        guard case .showingRecoveryCode = vm.phase else {
            return XCTFail("expected recovery code")
        }
        XCTAssertEqual(api.profileEnvelopes.count, 0)

        // Confirming the saved code completes bootstrap — and must register the
        // local profile in-session, without waiting for a restart.
        await vm.confirmSaved()
        guard case .done = vm.phase else { return XCTFail("expected done") }
        XCTAssertEqual(api.profileEnvelopes.count, 1)
    }

    func testBadCodeShowsError() async {
        let api = AccountKeyManagerTests.FakeAPI()
        let seedProvider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        _ = try? await AccountKeyManager(api: api, deviceKeyProvider: seedProvider).bootstrap()

        let joinerProvider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let vm = KeyLayerViewModel(manager: AccountKeyManager(api: api, deviceKeyProvider: joinerProvider))
        await vm.submitRecoveryCode("00000-00000-00000-00000-00000-00")
        guard case .error = vm.phase else { return XCTFail("expected error") }
    }

    func testBeginSetupFirstDeviceShowsRecoveryCode() async {
        let api = AccountKeyManagerTests.FakeAPI()               // never bootstrapped
        let vm = KeyLayerViewModel(manager: AccountKeyManager(api: api,
            deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider()))
        await vm.beginSetup()
        guard case .showingRecoveryCode = vm.phase else { return XCTFail("expected showingRecoveryCode") }
    }

    func testBeginSetupExistingAccountShowsChoice() async {
        let api = AccountKeyManagerTests.FakeAPI()
        _ = try? await AccountKeyManager(api: api,
            deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider()).bootstrap()
        let vm = KeyLayerViewModel(manager: AccountKeyManager(api: api,
            deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider()))   // different device
        await vm.beginSetup()
        XCTAssertEqual(vm.phase, .chooseJoinMethod)
    }

    func testBeginSetupAlreadyJoinedIsDone() async {
        let api = AccountKeyManagerTests.FakeAPI()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        _ = try? await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        let vm = KeyLayerViewModel(manager: AccountKeyManager(api: api, deviceKeyProvider: provider))
        await vm.beginSetup()
        XCTAssertEqual(vm.phase, .done)
    }

    func testStartJoinRequestThenApprovedPollBecomesDone() async throws {
        let api = AccountKeyManagerTests.FakeAPI()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let vm = KeyLayerViewModel(manager: AccountKeyManager(api: api, deviceKeyProvider: provider))
        await vm.startJoinRequest()
        guard case .waitingForApproval = vm.phase else { return XCTFail("expected waiting") }

        // Seal an ARK to this device's key and mark the request approved.
        let id = api.joinRequests.keys.first!
        let ark = SymmetricKey(size: .bits256)
        let arkBytes = ark.withUnsafeBytes { Data($0) }
        let pub = try provider.loadOrCreatePrivateKey().publicKey
        let sealed = try PhiKeyCrypto.sealToPublicKey(arkBytes, recipient: pub)
        try await api.approveJoinRequest(id: id, grantedArkEnvelope: sealed, resolvedByDeviceKeyId: "approver")

        await vm.pollOnce()
        XCTAssertEqual(vm.phase, .done)
    }

    func testPollDeniedShowsDenied() async {
        let api = AccountKeyManagerTests.FakeAPI()
        let vm = KeyLayerViewModel(manager: AccountKeyManager(api: api,
            deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider()))
        await vm.startJoinRequest()
        let id = api.joinRequests.keys.first!
        api.joinRequests[id] = JoinRequestDTO(requestId: id, requestingPublicKey: Data(), name: "", platform: "macos",
            status: "denied", grantedArkEnvelope: Data(), createdAt: AccountKeyManagerTests.FakeAPI.fixedCreatedAt,
            resolvedByDeviceKeyId: nil)
        await vm.pollOnce()
        XCTAssertEqual(vm.phase, .joinDenied)
    }

    func testStartPairingLoadsLocalsAndRemotes() async throws {
        let api = AccountKeyManagerTests.FakeAPI()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: ProfileKeyManagerTests.MemoryMappingStore())
        _ = try await pkm.registerLocalProfile(profileId: "Other", displayName: "Work")
        let controller = SyncKeyController(manager: mgr, approvals: DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider),
                                           profileKeys: pkm,
                                           localProfilesProvider: { [("Default", "Default"), ("Profile 1", "Home")] },
                                           notifyChromium: {})
        let vm = KeyLayerViewModel(manager: mgr)
        await vm.startPairing(controller: controller)
        guard case .pairingProfiles(let locals, let remotes) = vm.phase else { return XCTFail("expected pairing") }
        XCTAssertEqual(locals.map(\.profileId), ["Default", "Profile 1"])
        XCTAssertEqual(remotes.count, 1)
        XCTAssertEqual(remotes[0].name, "Work")
    }

    func testSubmitPairingAdoptAndRegisterResolves() async throws {
        let api = AccountKeyManagerTests.FakeAPI()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: ProfileKeyManagerTests.MemoryMappingStore())
        let remote = try await pkm.registerLocalProfile(profileId: "elsewhere", displayName: "Work")
        let store2 = ProfileKeyManagerTests.MemoryMappingStore() // fresh mapping = unmapped device state
        let pkm2 = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store2)
        let controller = SyncKeyController(manager: mgr, approvals: DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider),
                                           profileKeys: pkm2,
                                           localProfilesProvider: { [("Default", "Default"), ("Profile 1", "Home")] },
                                           notifyChromium: {})
        let vm = KeyLayerViewModel(manager: mgr)
        await vm.submitPairing([.adopt(localProfileId: "Default", remoteUuid: remote.uuid),
                                .registerNew(localProfileId: "Profile 1", displayName: "Home")],
                               controller: controller)
        XCTAssertEqual(vm.phase, .done)
        XCTAssertEqual(controller.profileSyncInfo(forProfileId: "Default")?.uuid, remote.uuid)
        XCTAssertNotNil(controller.profileSyncInfo(forProfileId: "Profile 1"))
        XCTAssertFalse(controller.needsPairing)
    }

    // MARK: - The pairing load is bounded, cancellable and replaceable (task 20)

    /// A `KeyEnvelopeAPI` whose profile LISTING never comes back on its own.
    ///
    /// This is the device-B stall the deadline exists for: the listing plus one
    /// envelope GET per profile, strictly serially, on `URLSession.shared`'s
    /// default 60 s timeout -- minutes of spinner in an app-modal window whose
    /// retry button was disabled for the whole of it.
    ///
    /// Composition rather than subclassing, because `AccountKeyManagerTests.FakeAPI`
    /// is `final`. Everything except `listProfiles()` forwards to a real one, so
    /// `bootstrap()` puts a real ARK up: `accountProfiles()` checks the ARK
    /// BEFORE any request, and a fake that failed that guard would land the load
    /// in `.error` instantly, passing the test without ever reaching the deadline.
    final class HangingListProfilesAPI: KeyEnvelopeAPI {
        let inner = AccountKeyManagerTests.FakeAPI()

        // Touched from the load's task-group children, i.e. off the main actor.
        private let lock = NSLock()
        private var _startedCalls = 0
        private var _cancelledCalls = 0
        private var _putStarts = 0
        private var _listingsHeld = true
        private var _putsHeld = false

        /// How many listing calls have suspended.
        var startedCalls: Int { withLock { $0._startedCalls } }
        /// How many of them were cancelled rather than answered.
        var cancelledCalls: Int { withLock { $0._cancelledCalls } }
        /// How many envelope PUTs have reached the hold point. The submit-in-flight
        /// case waits on this instead of guessing at a sleep.
        var putStarts: Int { withLock { $0._putStarts } }

        /// Lets a held listing finish, so a case that has made its assertions can
        /// drain the flow it parked instead of leaving a task suspended for an hour.
        func releaseListings() { withLock { $0._listingsHeld = false } }
        /// Parks `putProfileKey` -- i.e. `registerLocalProfile`, i.e. a `submitPairing`
        /// that is halfway through its decisions -- until released.
        func holdProfileKeyPuts() { withLock { $0._putsHeld = true } }
        func releaseProfileKeyPuts() { withLock { $0._putsHeld = false } }

        /// `NSLock.lock()` is unavailable from an async context, so every
        /// critical section is entered from a synchronous helper.
        private func withLock<T>(_ body: (HangingListProfilesAPI) -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body(self)
        }
        private func noteStarted() { withLock { $0._startedCalls += 1 } }
        private func noteCancelled() { withLock { $0._cancelledCalls += 1 } }
        private var listingsHeld: Bool { withLock { $0._listingsHeld } }
        private var putsHeld: Bool { withLock { $0._putsHeld } }

        func listProfiles() async throws -> [ProfileSummaryDTO] {
            noteStarted()
            try await withTaskCancellationHandler {
                // Far past any deadline these cases set: the only way out is
                // cancellation (which is exactly what is under test) or an
                // explicit `releaseListings()`.
                while listingsHeld { try await Task.sleep(for: .milliseconds(5)) }
            } onCancel: {
                self.noteCancelled()
            }
            return try await inner.listProfiles()
        }

        func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool {
            try await inner.putAccount(salt: salt, kdfVersion: kdfVersion,
                                       kdfParams: kdfParams, recoveryEnvelope: recoveryEnvelope)
        }
        func getAccount() async throws -> AccountKeyStateDTO? { try await inner.getAccount() }
        func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {
            try await inner.postDevice(deviceKeyId: deviceKeyId, publicKey: publicKey,
                                       name: name, platform: platform, arkEnvelope: arkEnvelope)
        }
        func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? {
            try await inner.getDeviceEnvelope(deviceKeyId: deviceKeyId)
        }
        func revokeDevice(deviceKeyId: String) async throws {
            try await inner.revokeDevice(deviceKeyId: deviceKeyId)
        }
        func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String {
            try await inner.postJoinRequest(publicKey: publicKey, name: name, platform: platform)
        }
        func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO] {
            try await inner.listPendingJoinRequests()
        }
        func getJoinRequest(id: String) async throws -> JoinRequestDTO {
            try await inner.getJoinRequest(id: id)
        }
        func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws {
            try await inner.approveJoinRequest(id: id, grantedArkEnvelope: grantedArkEnvelope,
                                               resolvedByDeviceKeyId: resolvedByDeviceKeyId)
        }
        func denyJoinRequest(id: String) async throws { try await inner.denyJoinRequest(id: id) }
        func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? {
            try await inner.getProfileKey(uuid: uuid)
        }
        func putProfileKey(uuid: String, envelope: Data) async throws -> Bool {
            withLock { $0._putStarts += 1 }
            while putsHeld { try await Task.sleep(for: .milliseconds(5)) }
            return try await inner.putProfileKey(uuid: uuid, envelope: envelope)
        }
        func getDomainKey(domain: String) async throws -> Data? { try await inner.getDomainKey(domain: domain) }
        func putDomainKey(domain: String, envelope: Data) async throws -> Bool {
            try await inner.putDomainKey(domain: domain, envelope: envelope)
        }
    }

    /// A key stack whose account listing hangs forever, with the ARK unlocked so
    /// the load really does reach the network step.
    private func hangingStack(loadDeadline: Duration) async throws
        -> (HangingListProfilesAPI, SyncKeyController, KeyLayerViewModel) {
        let api = HangingListProfilesAPI()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr,
                                    mappingStore: ProfileKeyManagerTests.MemoryMappingStore())
        let controller = SyncKeyController(
            manager: mgr,
            approvals: DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider),
            profileKeys: pkm,
            localProfilesProvider: { [("Default", "Default")] },
            notifyChromium: {})
        return (api, controller, KeyLayerViewModel(manager: mgr, loadDeadline: loadDeadline))
    }

    /// The load must be BOUNDED. Before this, a hung listing left the modal in
    /// `.working` for as long as the transport took to give up -- up to five
    /// serial 60 s round trips -- and `.working` was the one phase with retry
    /// disabled. The deadline has to land in `.error`, which does carry the
    /// exits, and it has to cancel the request it gave up on.
    func testStartPairingGivesUpOnAHungLoadAndLandsInError() async throws {
        let (api, controller, vm) = try await hangingStack(loadDeadline: .milliseconds(50))

        await vm.startPairing(controller: controller)

        guard case .error = vm.phase else {
            return XCTFail("a load past its deadline must land in .error, not stay in .working")
        }
        XCTAssertEqual(api.startedCalls, 1)
        XCTAssertEqual(api.cancelledCalls, 1, "the deadline must cancel the request it abandoned")
    }

    /// Retry is pressable during a load now, so pressing it must REPLACE the
    /// in-flight load rather than stack a second one behind it -- and the
    /// replaced load must not write `phase` on its way out.
    func testASecondStartPairingCancelsTheFirstLoadInsteadOfStackingIt() async throws {
        let (api, controller, vm) = try await hangingStack(loadDeadline: .milliseconds(300))

        let first = Task { await vm.startPairing(controller: controller) }
        // Let the first load reach the (hanging) listing before replacing it.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(api.startedCalls, 1)

        await vm.startPairing(controller: controller)
        await first.value

        XCTAssertEqual(api.startedCalls, 2, "each press starts exactly one load")
        XCTAssertEqual(api.cancelledCalls, 2,
                       "the replaced load is cancelled, and the replacement hits its deadline")
        guard case .error = vm.phase else { return XCTFail("expected the surviving load's error") }
    }

    /// Cancel-and-replace only coordinates one LOAD against another. `.working`
    /// is also `submitPairing`'s phase, held across every adopt / register /
    /// create await -- so a load started mid-submit would be a second,
    /// uncoordinated writer of `phase` AND a reader of the mapping table the
    /// submit is halfway through mutating. Now that retry is pressable in
    /// `.working` and the gate re-drives a presented modal on every `.measured`
    /// pass, that interleaving is reachable without the user doing anything, so
    /// the submit window has to turn the load away.
    func testStartPairingIsIgnoredWhileASubmitIsInFlight() async throws {
        let (api, controller, vm) = try await hangingStack(loadDeadline: .milliseconds(50))
        api.holdProfileKeyPuts()

        let submit = Task {
            await vm.submitPairing([.registerNew(localProfileId: "Default", displayName: "Default")],
                                   controller: controller)
        }
        // Wait for the submit to park inside the held PUT rather than guessing.
        var waited = 0
        while api.putStarts == 0, waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        XCTAssertEqual(api.putStarts, 1, "the submit must be in flight for this case to mean anything")
        XCTAssertTrue(vm.isSubmitting)

        // Exactly what `AppModalPairingHost.reloadPresented()` does on the next
        // `.measured` announcement, and what the retry button would do too.
        await vm.startPairing(controller: controller)

        XCTAssertEqual(api.startedCalls, 0, "no pairing load may run while a submit owns the phase")
        XCTAssertEqual(vm.phase, .working, "the submit's phase must survive the ignored re-drive")

        api.releaseProfileKeyPuts()
        api.releaseListings()
        await submit.value
        XCTAssertFalse(vm.isSubmitting, "the window closes when the submit finishes")
    }

    /// The other side of that guard: `submitPairing`'s OWN reload after a failed
    /// decision is not a competing load, so it must still run. If the guard
    /// turned it away, a failure would leave the modal parked in `.working` --
    /// the exact stuck-spinner shape task 20 exists to remove.
    func testAFailedSubmitStillReloadsTheCandidatesInsteadOfParkingInWorking() async throws {
        let api = AccountKeyManagerTests.FakeAPI()
        let provider = AccountKeyManagerTests.FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr,
                                    mappingStore: ProfileKeyManagerTests.MemoryMappingStore())
        // "Default" is already mapped, so registering it again is refused with
        // `alreadyMapped` -- a decision that fails without any network flakiness.
        _ = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Default")
        let controller = SyncKeyController(
            manager: mgr,
            approvals: DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider),
            profileKeys: pkm,
            localProfilesProvider: { [("Default", "Default"), ("Profile 1", "Home")] },
            notifyChromium: {})
        let vm = KeyLayerViewModel(manager: mgr)

        await vm.submitPairing([.registerNew(localProfileId: "Default", displayName: "Default")],
                               controller: controller)

        XCTAssertNotNil(vm.pairingError)
        guard case .pairingProfiles(let locals, _) = vm.phase else {
            return XCTFail("a failed submit must reload the candidates, not stay in .working")
        }
        XCTAssertEqual(locals.map(\.profileId), ["Profile 1"])
        XCTAssertFalse(vm.isSubmitting)
    }
}
