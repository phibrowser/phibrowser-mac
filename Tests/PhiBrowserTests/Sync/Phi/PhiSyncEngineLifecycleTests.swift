import XCTest
@testable import Phi

/// Mount-time lifecycle rules for the phi settings sync engine (M3-1 Task 9).
///
/// The mount itself is not reachable from a unit test: `buildSyncKeyControllerIfNeeded`
/// goes through `AccountController.shared`, `SyncKeyStack.make()` (real /keys/v1 client +
/// Keychain), `ProfileManager.shared.$profiles` and `ChromiumLauncher.sharedInstance()`,
/// and this bundle is compile-verified only (never `xcodebuild test`). What *is* pure — and
/// what carries the account-isolation invariant — is the decision the mount makes about the
/// engine's persisted cursor when the signed-in account changes, so that is what is pinned
/// here. The rest of Task 9 (timer / observer / debounce wiring and its teardown) is covered
/// by the manual E2E in Task 10.
final class PhiSyncEngineLifecycleTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "phi.sync.lifecycle.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A full account-scoped cursor as a signed-in device would leave it.
    private func seedCursor() {
        defaults.set("entity-1", forKey: PhiSyncEngine.entityIdStateKey)
        defaults.set(7, forKey: PhiSyncEngine.versionStateKey)
        defaults.set("birthday-1", forKey: PhiSyncEngine.storeBirthdayStateKey)
        defaults.set(Data([0x01, 0x02]), forKey: PhiSyncEngine.markerStateKey)
        defaults.set(Data([0x03, 0x04]), forKey: PhiSyncEngine.lastEntityStateKey)
        defaults.set(2, forKey: PhiSyncEngine.tombstoneRoundsStateKey)
        defaults.set(true, forKey: PhiSyncEngine.hasAdoptedStateKey)
    }

    private func cursorIsEmpty() -> Bool {
        PhiSyncEngine.stateKeys.allSatisfy { defaults.object(forKey: $0) == nil }
    }

    /// First mount ever: nothing to drop, but the owner is recorded so the next mount can
    /// tell "same account" from "switched account".
    func testFirstMountRecordsTheOwnerAndDropsNothing() {
        let dropped = PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(
            accountId: "auth0|alice", defaults: defaults)

        XCTAssertFalse(dropped)
        XCTAssertTrue(cursorIsEmpty())
        XCTAssertEqual(defaults.string(forKey: PhiChromiumCoordinator.phiSyncCursorOwnerKey),
                       "auth0|alice")
    }

    /// Re-login as the same account (`.mainAccountChanged` fires on every assignment, so
    /// this runs on ordinary app launches). The cursor must survive: dropping it would
    /// re-adopt the server's entity wholesale and lose settings edited while signed out.
    func testSameAccountKeepsTheCursor() {
        PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(
            accountId: "auth0|alice", defaults: defaults)
        seedCursor()

        let dropped = PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(
            accountId: "auth0|alice", defaults: defaults)

        XCTAssertFalse(dropped)
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "entity-1")
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data([0x01, 0x02]))
        XCTAssertTrue(defaults.bool(forKey: PhiSyncEngine.hasAdoptedStateKey))
    }

    /// Account switch. The cursor lives in `UserDefaults.standard`, which is NOT
    /// account-scoped, so account A's progress marker, entity id and version would be
    /// replayed against account B's namespace — and `hasAdopted` would make B's first pull
    /// merge against A's timestamps instead of adopting B's settings.
    func testAccountSwitchDropsTheWholeCursor() {
        PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(
            accountId: "auth0|alice", defaults: defaults)
        seedCursor()

        let dropped = PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(
            accountId: "auth0|bob", defaults: defaults)

        XCTAssertTrue(dropped)
        XCTAssertTrue(cursorIsEmpty())
        XCTAssertEqual(defaults.string(forKey: PhiChromiumCoordinator.phiSyncCursorOwnerKey),
                       "auth0|bob")
    }

    /// The ownership record must not be one of the engine's own state keys: the engine wipes
    /// those on NOT_MY_BIRTHDAY, and forgetting the owner there would make the very next
    /// mount look like an account switch.
    func testOwnerKeyIsNotPartOfTheEnginesResettableState() {
        XCTAssertFalse(PhiSyncEngine.stateKeys.contains(PhiChromiumCoordinator.phiSyncCursorOwnerKey))
    }
}
