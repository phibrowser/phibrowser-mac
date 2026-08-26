import Foundation

/// Drives the Settings → Devices pane: unlocks this device, polls pending join requests
/// while the pane is open, and approves/denies them. Presentation stays in the view.
@MainActor
final class DevicesSettingViewModel: ObservableObject {
    enum UnlockState: Equatable { case loading, unlocked, needsJoin, notSignedIn, failed(String) }

    @Published private(set) var unlockState: UnlockState = .loading
    @Published private(set) var pending: [PendingApproval] = []
    @Published private(set) var actionError: String?

    private let manager: AccountKeyManager
    private let approvals: DeviceApprovalService
    private var pollTimer: Timer?

    init(manager: AccountKeyManager, approvals: DeviceApprovalService) {
        self.manager = manager
        self.approvals = approvals
    }

    var isUnlocked: Bool { unlockState == .unlocked }

    func loadAll() async {
        unlockState = .loading
        do {
            switch try await manager.unlockAtStartup() {
            case .unlocked:
                unlockState = .unlocked
                await refreshPending()
                startPolling()
            case .needsJoin:    unlockState = .needsJoin
            case .notSignedIn:  unlockState = .notSignedIn
            }
        } catch {
            unlockState = .failed("\(error)")
        }
    }

    func refreshPending() async {
        do { pending = try await approvals.listPendingApprovals() }
        catch { actionError = "\(error)" }
    }

    func approve(_ item: PendingApproval) async {
        actionError = nil
        do {
            try await approvals.approve(item)
            await refreshPending()
        } catch DeviceApprovalError.notUnlocked {
            actionError = NSLocalizedString("This device isn’t unlocked yet.",
                comment: "Devices - approve blocked when locked")
        } catch let e as JoinRequestError where e == .notPending {
            actionError = NSLocalizedString("That request already expired.",
                comment: "Devices - approve stale request")
            await refreshPending()
        } catch {
            actionError = "\(error)"
        }
    }

    func deny(_ item: PendingApproval) async {
        actionError = nil
        do { try await approvals.deny(item); await refreshPending() }
        catch { actionError = "\(error)" }
    }

    func stopPolling() async { doStopPolling() }

    private func startPolling() {
        doStopPolling()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshPending() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func doStopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
