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
    @Published private(set) var paired = false
    @Published private(set) var requiresReconfiguration = false
    @Published var reconfigurationError: String?
    @Published var isReconfiguring = false
    var reconfigurationRequired: () -> Bool = { false }
    private var loadGeneration: UInt64 = 0
    private var deviceGeneration: UInt64 = 0
    private var pendingGeneration: UInt64 = 0
    private var refreshInFlight = false
    var syncReport: (_ requestSync: Bool) async -> SyncHelper.Report? = { _ in nil }
    /// Sync now: records an explicit request with the helper and returns its report.
    var syncNowReport: () async -> SyncHelper.Report? = { nil }
    @Published private(set) var summary = SyncStatusSummary(phase: .notStarted, lastSuccess: nil)
    @Published private(set) var requestState: SyncRequestState = .idle
    @Published private(set) var nativeDetail: SyncNativeDetail?
    /// The helper report's pause fields as last read; `statusPresentation` lays them over the
    /// summary on every read (docs/sync.md, "Sync status contract"), and nothing else interprets them.
    @Published private(set) var profileMappingPause: SyncProfileMappingPauseStatus = .none
    @Published private(set) var syncNowCancelledByPause = false
    @Published private(set) var profileListNotEnumeratedSince: Date?
    /// When the report was last read; the unread Profile list's age is measured against it.
    @Published private(set) var statusReadAt = Date()
    /// Bumped when a shown pause ends, so the view announces that sync resumed.
    @Published private(set) var pauseEndedSerial: UInt64 = 0
    /// The pause card's Retry: `PhiChromiumCoordinator.retryProfileMappingRepair()`.
    var retryProfileMappingRepair: () -> Void = {}
    /// From a Sync now tap until the helper answers, so the control never looks idle in between.
    @Published private(set) var isSubmittingSyncNow = false
    /// Set when a Sync now request the helper accepted or queued has ended, or when the helper
    /// refused it; the view announces it. `serial` makes repeated outcomes distinct.
    @Published private(set) var syncNowOutcome: SyncNowOutcome?
    struct SyncNowOutcome: Equatable {
        enum Result: Equatable {
            /// A common success newer than at the tap.
            case finished
            /// Ended without that success; the native last problem, if one was recorded after the tap.
            case failed(SyncProblemCategory?)
            case rejected
        }
        let serial: UInt64
        let result: Result
    }
    private var awaitingSyncNow = false
    /// The common success time when the tap was made; only a newer one means the sync finished.
    private var syncNowBaseline: Date?
    /// Only a problem recorded at or after the tap describes this request.
    private var syncNowTappedAt = Date.distantPast
    private var syncNowSerial: UInt64 = 0
    var pairingComplete: () -> Bool = { ProfilePairingGate.shared.isPaired }
    var isCurrentAccount: () -> Bool = { true }
    /// Whether an account is signed in. The key API refuses to send a request
    /// without a token and reports that as a transport failure, so a signed-out
    /// pane has to be recognised here or it would show a connection error.
    var isSignedIn: () -> Bool = { true }
    var profileNames: () -> [String: String] = { [:] }
    func contextTitle(_ id: String) -> String {
        if id == "phi" { return NSLocalizedString("sync.status.phiData", value: "Phi data", comment: "Native sync context display name") }
        return profileNames()[id] ?? NSLocalizedString("sync.status.profile", value: "Profile", comment: "Unknown profile display name")
    }
    var currentDeviceID: String? { try? manager.deviceKeyProviderForTesting.deviceKeyId() }
    static let requestFailed = NSLocalizedString("sync.settings.requestFailed", value: "Couldn’t load sync information. Check your connection and retry.", comment: "Sync settings request failed")

    func refreshStatus(requestSync: Bool = false) async {
        guard isCurrentAccount() else { return }
        let generation = loadGeneration
        requiresReconfiguration = reconfigurationRequired()
        paired = pairingComplete()
        guard paired else { clearStatus(); return }
        let report = await syncReport(requestSync)
        guard generation == loadGeneration, isCurrentAccount() else { return }
        paired = pairingComplete()
        guard paired else { clearStatus(); return }
        apply(report)
    }

    /// Sync now. Calls the helper directly instead of `refresh`, whose in-flight guard would
    /// drop a tap made during the 3 s poll.
    func syncNow() async {
        guard isUnlocked, !isSubmittingSyncNow, isCurrentAccount() else { return }
        let generation = loadGeneration
        syncNowBaseline = summary.lastSuccess
        syncNowTappedAt = Date()
        isSubmittingSyncNow = true
        defer { isSubmittingSyncNow = false }
        let report = await syncNowReport()
        guard generation == loadGeneration, isCurrentAccount() else { return }
        paired = pairingComplete()
        guard paired else { clearStatus(); return }
        apply(report)
        switch requestState {
        case .queued, .inFlight: awaitingSyncNow = true
        case .rejected: finishSyncNow(.rejected)
        case .idle: break // Nothing was recorded (helper stopped or ineligible).
        }
    }

    /// What the status row shows: the summary with the Profile mapping pause and the unread
    /// Profile list laid over it. Computed from the last report on every read, never stored.
    var statusPresentation: SyncStatusPresentation {
        SyncStatusPresentation.present(summary: summary.phase, request: requestState,
            profileMappingPause: profileMappingPause, syncNowCancelledByPause: syncNowCancelledByPause,
            profileListNotEnumeratedSince: profileListNotEnumeratedSince,
            resetRequired: resetRequired,
            profileNames: profileNames(), now: statusReadAt)
    }

    /// A reset or reconfiguration wins over the pause: Retry cannot fix it.
    private var resetRequired: Bool {
        requiresReconfiguration || nativeDetail?.lastProblem?.category == .resetRequired
    }

    /// The Sync now control: the helper's request state, the pane's own unlock and pairing
    /// checks, and progress while a tap is being submitted. Hidden while the pause shows Retry.
    var syncNowButton: SyncNowButtonState {
        guard isUnlocked, paired else {
            return SyncNowButtonState(isVisible: false, isEnabled: false, showsProgress: false, hint: .none)
        }
        let state = statusPresentation.syncNow
        guard isSubmittingSyncNow else { return state }
        return SyncNowButtonState(isVisible: state.isVisible, isEnabled: false, showsProgress: true, hint: .none)
    }

    private func apply(_ report: SyncHelper.Report?) {
        let wasPaused = statusPresentation.pause != nil
        contextSnapshots = report?.snapshots ?? [:]
        requiredIDs = report?.requiredIDs ?? []
        summary = report?.summary ?? SyncStatusSummary(phase: .checking, lastSuccess: nil)
        requestState = report?.request ?? .idle
        nativeDetail = report?.snapshots["phi"]?.detail
        profileMappingPause = report?.profileMappingPause ?? .none
        syncNowCancelledByPause = report?.syncNowCancelledByPause ?? false
        profileListNotEnumeratedSince = report?.profileListNotEnumeratedSince
        statusReadAt = Date()
        // The pause ended in the report; one that gives way to a reset has not resumed sync.
        if wasPaused, report != nil, profileMappingPause == .none, !resetRequired { pauseEndedSerial &+= 1 }
        guard awaitingSyncNow else { return }
        // A dropped request (no helper, ineligible, sync not started) ends without a word.
        guard report != nil, summary.phase != .notStarted else { awaitingSyncNow = false; return }
        // A request the pause cancelled returns the control to idle and is not announced.
        guard statusPresentation.announcesSyncNowOutcome else { awaitingSyncNow = false; return }
        switch requestState {
        case .queued, .inFlight: break
        case .rejected: finishSyncNow(.rejected)
        case .idle:
            // The helper moves `lastSuccess` only on a coordinated success, so a newer one is enough
            // even if a later local edit has already started another round.
            let succeeded = summary.lastSuccess.map { success in syncNowBaseline.map { success > $0 } ?? true } == true
            let problem = nativeDetail?.lastProblem.flatMap { $0.at >= syncNowTappedAt ? $0.category : nil }
            finishSyncNow(succeeded ? .finished : .failed(problem))
        }
    }

    private func finishSyncNow(_ result: SyncNowOutcome.Result) {
        awaitingSyncNow = false
        syncNowSerial &+= 1
        syncNowOutcome = SyncNowOutcome(serial: syncNowSerial, result: result)
    }

    private func clearStatus() {
        contextSnapshots = [:]; requiredIDs = []
        summary = SyncStatusSummary(phase: .notStarted, lastSuccess: nil)
        requestState = .idle
        nativeDetail = nil
        profileMappingPause = .none
        syncNowCancelledByPause = false
        profileListNotEnumeratedSince = nil
        awaitingSyncNow = false
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

    private func refresh(requestSync: Bool = false) async {
        guard !refreshInFlight, isCurrentAccount() else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        async let pendingLoad: Void = refreshPending()
        async let deviceLoad: Void = refreshDevices()
        await refreshStatus(requestSync: requestSync)
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
        guard isSignedIn() else {
            doStopPolling()
            actionError = nil
            requiresReconfiguration = false
            unlockState = .notSignedIn
            return
        }
        unlockState = .loading
        requiresReconfiguration = reconfigurationRequired()
        do {
            let result = try await manager.unlockAtStartup()
            guard generation == loadGeneration, isCurrentAccount() else { return }
            switch result {
            case .unlocked:
                unlockState = .unlocked
                await refresh(requestSync: true)
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
            actionError = NSLocalizedString("sync.devices.error.locked",
                value: "This device isn’t unlocked yet.",
                comment: "Devices settings - error shown when approving a device before this device is unlocked")
        } catch let e as JoinRequestError where e == .notPending {
            actionError = NSLocalizedString("sync.devices.error.requestExpired",
                value: "That request already expired.",
                comment: "Devices settings - error shown when approving a request that already expired")
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
        awaitingSyncNow = false
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
