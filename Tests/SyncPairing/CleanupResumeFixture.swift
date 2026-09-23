import Foundation
import Darwin

@MainActor
final class CleanupController {
    let accountID: String
    init(accountID: String) { self.accountID = accountID }
    func silentUnlockAndResolve() async {}
}

/// Runs the coordinator's production startup and cleanup-completion methods without an app host.
@MainActor
final class CleanupCoordinatorFixture {
    var nativeSyncCleanupInProgress = false
    var syncInitializationDeferred = false
    var pendingNativeCleanup: (accountID: String, removingDevice: Bool)?
    var currentAccountID: String?
    var controller: CleanupController?
    var builds = 0

    func syncKeyControllerCreatingIfNeeded() -> CleanupController? {
        guard !nativeSyncCleanupInProgress, let currentAccountID else { return nil }
        if controller == nil {
            controller = CleanupController(accountID: currentAccountID)
            builds += 1
        }
        return controller
    }
    func startPhiSyncIfReady() {}

    /* PRODUCTION_STARTUP */
    /* PRODUCTION_CLEANUP_COMPLETION */
}

enum CleanupResumeFailure: Error { case assertion(String) }

@main struct CleanupResumeTests {
    @MainActor
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CleanupResumeFailure.assertion(message) }
    }

    @MainActor
    static func main() {
        do {
            let switched = CleanupCoordinatorFixture()
            switched.nativeSyncCleanupInProgress = true
            switched.pendingNativeCleanup = ("A", true)
            switched.currentAccountID = "B"
            switched.ensureSyncKeyControllerAndUnlock()
            switched.ensureSyncKeyControllerAndUnlock()
            try expect(switched.controller == nil, "Cleanup must block startup until its writes finish")
            switched.finishNativeSyncCleanup(completed: false)
            try expect(switched.controller?.accountID == "B", "The login deferred by cleanup must initialize account B")
            try expect(switched.builds == 1, "Deferred login notifications must coalesce")
            try expect(switched.pendingNativeCleanup?.accountID == "A", "Account A must retain its failed cleanup intent")
            try expect(!switched.syncInitializationDeferred, "Completion must consume the deferred startup")

            let changedAgain = CleanupCoordinatorFixture()
            changedAgain.nativeSyncCleanupInProgress = true
            changedAgain.currentAccountID = "B"
            changedAgain.ensureSyncKeyControllerAndUnlock()
            changedAgain.currentAccountID = "C"
            changedAgain.finishNativeSyncCleanup(completed: false)
            try expect(changedAgain.controller?.accountID == "C", "Resume must use the current account, not the deferred one")

            let signedOut = CleanupCoordinatorFixture()
            signedOut.nativeSyncCleanupInProgress = true
            signedOut.currentAccountID = "B"
            signedOut.ensureSyncKeyControllerAndUnlock()
            signedOut.currentAccountID = nil
            signedOut.finishNativeSyncCleanup(completed: false)
            try expect(signedOut.controller == nil, "Sign-out must prevent a stale account restart")

            let ordinary = CleanupCoordinatorFixture()
            ordinary.nativeSyncCleanupInProgress = true
            ordinary.currentAccountID = "A"
            ordinary.pendingNativeCleanup = ("A", true)
            ordinary.finishNativeSyncCleanup(completed: true)
            try expect(ordinary.controller == nil, "Ordinary removal must not restart sync without a login request")
            try expect(ordinary.pendingNativeCleanup == nil, "Successful cleanup must retire its pending intent")
            print("PASS cleanup resume: deferred login, coalescing, account changes, sign-out, ordinary removal")
        } catch {
            fputs("FAIL cleanup resume: \(error)\n", stderr)
            exit(1)
        }
    }
}
