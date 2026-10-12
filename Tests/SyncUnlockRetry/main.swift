// Production recovery entry points and real SyncHelper; only app, key API, and
// mapping side effects are stubbed. Hosted tests cover real Profile key publication.
import Foundation
func AppLogWarn(_ message: String) {}
enum PhiSyncLog { static func describe(_ error: Error) -> String { "fixture" } }
enum UnlockResult { case unlocked, needsJoin, notSignedIn }
enum Offline: Error { case unavailable }
@MainActor final class Manager {
    enum Outcome { case failure, unlocked, needsJoin, notSignedIn }
    var outcome: Outcome = .failure
    var currentARK: Bool?
    var calls = 0
    func unlockAtStartup() async throws -> UnlockResult {
        calls += 1
        await Task.yield()
        switch outcome {
        case .failure: throw Offline.unavailable
        case .unlocked: currentARK = true; return .unlocked
        case .needsJoin: return .needsJoin
        case .notSignedIn: return .notSignedIn
        }
    }
}
@MainActor final class SyncKeyController {
    let manager = Manager()
    var isRetired = false
    var resolutions = 0
    var clears = 0
    var resolveTask: Task<Void, Never>?
    var autoCreateTask: Task<Void, Never>?
    var silentUnlockTask: Task<Void, Never>?
    var silentUnlockPending = false
    var unlockRetryTask: Task<Void, Never>?
    var unlockRetryAttempt = 0
    var unlockRetryDelay: (Int) -> Duration = { _ in .milliseconds(1) }
    var onResolve: () async -> Void = {}
    func resolveMappings() async {
        guard !isRetired else { return }
        resolutions += 1
        await onResolve()
    }
    func clearResolved() { clears += 1 }
    /* CONTROLLER_METHODS */
}
@MainActor final class Account {}
@MainActor final class Engine {}
@MainActor final class AccountController {
    static let shared = AccountController()
    var account: Account?
}
@MainActor final class ProfilePairingGate {
    static let shared = ProfilePairingGate()
    var isPaired = true
}
@MainActor final class Loader { func loadNow() {} }
@MainActor final class CoordinatorFixture {
    var syncKeyController: SyncKeyController? = SyncKeyController()
    var phiSyncEngine: Engine? = Engine()
    var phiSyncPairingEnabled = true
    var syncProfileLoader: Loader?
    var syncHelper: SyncHelper?
    var enumerations = 0
    var requests = 0
    func buildHelper() {
        let account = Account()
        AccountController.shared.account = account
        let builtEngine = phiSyncEngine
        syncHelper = SyncHelper(
            /* ELIGIBILITY */,
            participants: { [weak self] in
                guard let self else { return [] }
                self.enumerations += 1
                return [SyncHelper.Participant(id: "phi", read: {
                    SyncContextSnapshot(id: "phi", phase: .offline, lastSuccess: nil, revision: 1)
                }, requestSync: { [weak self] _ in
                    self?.requests += 1
                    return self?.syncKeyController?.manager.currentARK != nil
                }, isNative: true)]
            }, lastSuccess: nil, saveSuccess: { _ in true })
    }
    /* REQUEST_SYNC_NOW */
}
@MainActor final class PaneFixture {
    enum UnlockState: Equatable { case loading, unlocked, needsJoin, notSignedIn, failed(String) }
    let manager: Manager
    var loadGeneration: UInt64 = 0
    var unlockState: UnlockState = .loading
    var unlockedAccountID: String??
    var requiresReconfiguration = false
    var actionError: String?
    var pendingLoadError: String?
    var isSignedIn = { true }
    var isCurrentAccount = { true }
    var accountID: () -> String? = { "account-a" }
    var reconfigurationRequired = { false }
    var resolveMappingsAfterUnlock: () async -> Void = {}
    var refreshes = 0
    var polls = 0
    var onRefresh: () -> Void = {}
    static let requestFailed = "Request failed"
    init(manager: Manager) { self.manager = manager }
    func stopObservingConnectivity() {}
    func observeConnectivity() {}
    func doStopPolling() { polls = 0 }
    func startPolling() { polls += 1 }
    func refresh(requestSync: Bool) async { refreshes += 1; onRefresh() }
    /* PANE_LOAD */
    /* PANE_SHOW */
}
@MainActor final class HostFixture {
    var syncKeyController: SyncKeyController?
    let viewModel: PaneFixture
    init(controller: SyncKeyController) {
        syncKeyController = controller
        viewModel = PaneFixture(manager: controller.manager)
        /* PANE_BINDING */
    }
}
@main struct UnlockRecoveryTests {
    @MainActor static func eventually(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(2)
        while !condition() && clock.now < end { try? await Task.sleep(for: .milliseconds(1)) }
        precondition(condition(), "Recovery did not complete")
    }
    @MainActor static func main() async throws {
        // The real helper's eligibility gate must not swallow the manual unlock,
        // and a refused sync must not enumerate or request any participant.
        let coordinator = CoordinatorFixture()
        let c = coordinator.syncKeyController!
        c.unlockRetryDelay = { _ in .seconds(60) }
        await c.silentUnlockAndResolve()
        coordinator.buildHelper()
        c.manager.outcome = .unlocked
        let report = await coordinator.requestSyncNow()
        precondition(report?.request == .idle)
        precondition(coordinator.enumerations == 0 && coordinator.requests == 0)
        await eventually { c.resolutions == 1 }
        precondition(c.manager.calls == 2 && c.unlockRetryTask == nil)
        coordinator.syncHelper?.stop()
        c.retire()
        print("PASS: locked manual request recovers before helper eligibility")

        let noHelper = CoordinatorFixture()
        let pending = noHelper.syncKeyController!
        pending.manager.outcome = .unlocked
        let missingReport = await noHelper.requestSyncNow()
        precondition(missingReport == nil)
        await eventually { pending.resolutions == 1 }
        let calls = pending.manager.calls
        _ = await noHelper.requestSyncNow()
        await Task.yield()
        precondition(pending.manager.calls == calls)
        pending.retire()
        pending.manager.currentARK = nil
        _ = await noHelper.requestSyncNow()
        await Task.yield()
        precondition(pending.manager.calls == calls)
        print("PASS: absent helper still recovers; held keys and retired controllers do not retry")

        let paneController = SyncKeyController()
        paneController.unlockRetryDelay = { _ in .seconds(60) }
        await paneController.silentUnlockAndResolve()
        let host = HostFixture(controller: paneController)
        let pane = host.viewModel
        await pane.loadAll()
        precondition(pane.unlockState == .failed(PaneFixture.requestFailed))
        precondition(paneController.resolutions == 0 && pane.refreshes == 0)
        paneController.manager.outcome = .unlocked
        pane.onRefresh = { precondition(paneController.resolutions == 1) }
        let beforeRetry = paneController.manager.calls
        await pane.loadAll() // The visible failure card calls this method.
        precondition(pane.unlockState == .unlocked && pane.polls == 1)
        precondition(paneController.manager.calls == beforeRetry + 1)
        precondition(paneController.resolutions == 1 && pane.refreshes == 1)
        precondition(paneController.unlockRetryTask != nil, "Did not need the pending timer")
        paneController.retire()
        print("PASS: pane Retry restores mappings before requesting sync, with one unlock")

        for accountChanges in [false, true] {
            let owner = SyncKeyController()
            owner.manager.outcome = .unlocked
            let host = HostFixture(controller: owner)
            let model = host.viewModel
            owner.onResolve = {
                if accountChanges { model.isCurrentAccount = { false } }
                else { model.loadGeneration += 1 }
            }
            await model.loadAll()
            precondition(model.refreshes == 0 && model.polls == 0 && model.unlockState == .loading)
            owner.retire()
        }
        print("PASS: stale pane/account cannot publish after awaited mapping recovery")

        let old = SyncKeyController()
        old.manager.outcome = .unlocked
        let rebound = HostFixture(controller: old)
        let replacement = SyncKeyController()
        rebound.syncKeyController = replacement
        await rebound.viewModel.loadAll()
        precondition(old.resolutions == 1 && replacement.resolutions == 0)
        old.retire()
        replacement.retire()
        print("PASS: pane recovery stays bound to its own controller")
    }
}
