import Foundation

// The build script inserts the production coordinator method below. Only its
// application-owned dependencies are replaced; scheduling uses the real type.
@MainActor
final class SpaceGateEngine {
    var enabled = false
    var transitions = 0
    var hold = false
    var release: CheckedContinuation<Void, Never>?

    func setSpaceSyncEnabled(_ value: Bool) async {
        transitions += 1
        if hold { await withCheckedContinuation { release = $0 } }
        enabled = value
    }
}

@MainActor
private final class AccountController {
    static let shared = AccountController()
    var account: Bool? = true
}

@MainActor
final class ProfilePairingGate {
    static let shared = ProfilePairingGate()
    var isPaired: Bool { !Self.joinPairingPending }
    static var joinPairingPending = true
}

@MainActor
final class SpaceGateFixture {
    struct KeyManager { var currentARK: Bool? = true }
    struct KeyController { var manager = KeyManager() }
    var syncKeyController: KeyController? = KeyController()
    var phiSyncEngine: SpaceGateEngine?
    var phiInvalidationCoordinator: PhiSyncInvalidationCoordinator?
    var lastSpaceGateEnabled: Bool?

    func refresh() { refreshSpaceSyncGate() }

    /* PRODUCTION_SPACE_GATE */
}
