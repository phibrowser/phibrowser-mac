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

        vm.confirmSaved()
        guard case .done = vm.phase else { return XCTFail("expected done") }
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
}
