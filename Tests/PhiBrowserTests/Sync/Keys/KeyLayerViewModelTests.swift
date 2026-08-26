import XCTest
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
}
