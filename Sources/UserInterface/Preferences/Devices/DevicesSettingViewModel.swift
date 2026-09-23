import Foundation

/// Drives the Settings → Sync pane: unlocks this device, polls pending join requests
/// while the pane is open, and approves/denies them. Presentation stays in the view.
@MainActor
final class DevicesSettingViewModel: ObservableObject {
    enum UnlockState: Equatable { case loading, unlocked, needsJoin, notSignedIn, failed(String) }

    @Published private(set) var unlockState: UnlockState = .loading
    @Published private(set) var pending: [PendingApproval] = []
    @Published private(set) var actionError: String?
    @Published private(set) var devices: [AccountDeviceDTO] = []
    @Published private(set) var devicesLoadError: String?
    @Published private(set) var busyRequestIDs: Set<String> = []
    @Published private(set) var contextSnapshots: [String: SyncContextSnapshot] = [:]
    @Published private(set) var requiredIDs: Set<String> = []
    @Published private(set) var chromiumCategories: Set<String> = []
    @Published private(set) var paired = false
    @Published private(set) var requiresReconfiguration = false
    @Published var reconfigurationError: String?
    @Published var isReconfiguring = false
    var reconfigurationRequired: () -> Bool = { false }
    private var loadGeneration: UInt64 = 0
    private var deviceGeneration: UInt64 = 0
    private var pendingGeneration: UInt64 = 0
    private var refreshInFlight = false
    private let chromiumStatus = ChromiumSyncStatus()
    var nativeStatus: () -> SyncContextSnapshot? = { nil }
    var profileIDs: () -> [String] = { [] }
    var pairingComplete: () -> Bool = { ProfilePairingGate.shared.isPaired }
    var isCurrentAccount: () -> Bool = { true }
    var accountName: String = ""
    var profileNames: () -> [String: String] = { [:] }
    func contextTitle(_ id: String) -> String {
        if id == "phi" { return NSLocalizedString("sync.status.phiData", value: "Phi data", comment: "Native sync context display name") }
        return profileNames()[id] ?? NSLocalizedString("sync.status.profile", value: "Profile", comment: "Unknown profile display name")
    }
    var currentDeviceID: String? { try? manager.deviceKeyProviderForTesting.deviceKeyId() }
    var summary: SyncStatusSummary {
        SyncStatusSummary.reduce(paired: paired, requiredIDs: requiredIDs, snapshots: Array(contextSnapshots.values))
    }
    static let requestFailed = NSLocalizedString("sync.settings.requestFailed", value: "Couldn’t load sync information. Check your connection and retry.", comment: "Sync settings request failed")

    func acceptStatus(_ snapshot: SyncContextSnapshot, generation: UInt64) {
        guard generation == loadGeneration, isCurrentAccount() else { return }
        if let old = contextSnapshots[snapshot.id], old.revision > snapshot.revision { return }
        contextSnapshots[snapshot.id] = snapshot
    }

    func refreshStatus() async {
        guard isCurrentAccount() else { return }
        let generation = loadGeneration
        requiresReconfiguration = reconfigurationRequired()
        paired = pairingComplete()
        let profiles = profileIDs()
        requiredIDs = profiles.isEmpty ? [] : Set(["phi"] + profiles)
        guard paired else { contextSnapshots = [:]; chromiumCategories = []; return }
        if let native = nativeStatus() { acceptStatus(native, generation: generation) }
        else { contextSnapshots.removeValue(forKey: "phi") }
        var categories: Set<String> = []
        for id in profiles {
            let result = await chromiumStatus.read(profileID: id)
            guard generation == loadGeneration, isCurrentAccount() else { return }
            acceptStatus(result.status, generation: generation)
            categories.formUnion(result.enabledCategories)
        }
        chromiumCategories = categories
    }

    func refreshDevices() async {
        deviceGeneration &+= 1
        let generation = deviceGeneration
        do {
            let rows = try await approvals.listDevices()
            guard generation == deviceGeneration, isCurrentAccount() else { return }
            devices = rows.filter { $0.status == "active" && $0.revokedAt == nil }
            devicesLoadError = nil
        } catch {
            guard generation == deviceGeneration, isCurrentAccount() else { return }
            devices = []
            devicesLoadError = Self.requestFailed
        }
    }

    private func refresh() async {
        guard !refreshInFlight, isCurrentAccount() else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        async let pendingLoad: Void = refreshPending()
        async let deviceLoad: Void = refreshDevices()
        await refreshStatus()
        await pendingLoad
        await deviceLoad
    }

    private let manager: AccountKeyManager
    private let approvals: DeviceApprovalService
    private var pollTimer: Timer?

    init(manager: AccountKeyManager, approvals: DeviceApprovalService) {
        self.manager = manager
        self.approvals = approvals
    }

    var isUnlocked: Bool { unlockState == .unlocked }

    func loadAll() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        unlockState = .loading
        requiresReconfiguration = reconfigurationRequired()
        do {
            let result = try await manager.unlockAtStartup()
            guard generation == loadGeneration, isCurrentAccount() else { return }
            switch result {
            case .unlocked:
                unlockState = .unlocked
                await refresh()
                guard generation == loadGeneration, isCurrentAccount() else { return }
                startPolling()
            case .needsJoin:    unlockState = .needsJoin
            case .notSignedIn:  unlockState = .notSignedIn
            }
        } catch {
            guard generation == loadGeneration, isCurrentAccount() else { return }
            unlockState = .failed(Self.requestFailed)
        }
    }

    func refreshPending() async {
        pendingGeneration &+= 1
        let generation = pendingGeneration
        do {
            let rows = try await approvals.listPendingApprovals()
            guard generation == pendingGeneration, isCurrentAccount() else { return }
            pending = rows
        } catch {
            guard generation == pendingGeneration, isCurrentAccount() else { return }
            actionError = Self.requestFailed
        }
    }

    func approve(_ item: PendingApproval) async {
        guard !busyRequestIDs.contains(item.id), isCurrentAccount() else { return }
        busyRequestIDs.insert(item.id)
        defer { busyRequestIDs.remove(item.id) }
        actionError = nil
        do {
            try await approvals.approve(item)
            await refreshPending()
            await refreshDevices()
        } catch DeviceApprovalError.notUnlocked {
            actionError = NSLocalizedString("This device isn’t unlocked yet.",
                comment: "Devices - approve blocked when locked")
        } catch let e as JoinRequestError where e == .notPending {
            actionError = NSLocalizedString("That request already expired.",
                comment: "Devices - approve stale request")
            await refreshPending()
        } catch {
            actionError = Self.requestFailed
        }
    }

    func deny(_ item: PendingApproval) async {
        guard !busyRequestIDs.contains(item.id), isCurrentAccount() else { return }
        busyRequestIDs.insert(item.id)
        defer { busyRequestIDs.remove(item.id) }
        actionError = nil
        do { try await approvals.deny(item); await refreshPending() }
        catch { actionError = Self.requestFailed }
    }

    func stopPolling() async {
        loadGeneration &+= 1
        deviceGeneration &+= 1
        pendingGeneration &+= 1
        doStopPolling()
    }

    private func startPolling() {
        doStopPolling()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func doStopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
