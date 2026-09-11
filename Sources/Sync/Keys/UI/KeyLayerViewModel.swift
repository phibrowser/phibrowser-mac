import CryptoKit
import Foundation

/// A local (on-disk) Chromium profile as offered to the pairing UI: the local
/// identity half of a local-profile <-> remote-profile pairing decision.
struct PairingLocal: Equatable, Identifiable {
    let profileId: String
    let displayName: String
    var id: String { profileId }
}

/// State machine for the account key bootstrap / recovery-code join flow.
enum KeyLayerPhase: Equatable {
    case idle
    case showingRecoveryCode(String)
    case enteringRecoveryCode
    case chooseJoinMethod
    case waitingForApproval(code: String, deadline: Date)
    case joinDenied
    case joinExpired
    case working
    case done
    case error(String)
    /// Semi-automatic pairing (M2-4 Task 5): more than one unmapped local
    /// profile and more than one unclaimed remote profile — `resolveMappings()`
    /// can't disambiguate on its own, so the user picks.
    case pairingProfiles(locals: [PairingLocal], remotes: [RemoteProfile])
}

/// Thrown when the pairing load runs past its deadline. Deliberately private
/// and deliberately NOT an `Error` any caller can catch by type: the only thing
/// downstream of it is `runPairingLoad`'s own mapping to a localized `.error`.
private struct PairingLoadTimedOut: Error {}

/// Drives the recovery-code UI: owns all state transitions and error mapping
/// so the SwiftUI views underneath it stay purely presentational.
@MainActor
final class KeyLayerViewModel: ObservableObject {
    @Published private(set) var phase: KeyLayerPhase = .idle
    /// Set when a pairing decision fails to apply (surfaced by `ProfilePairingView`
    /// while `phase` stays `.pairingProfiles`); cleared at the start of the next
    /// `submitPairing` call.
    @Published private(set) var pairingError: String?

    /// True for the whole of `submitPairing`, from the first decision to the last.
    ///
    /// `.working` is not only the pairing load's phase: a submit holds it too,
    /// across every `adoptRemoteProfile` / `registerLocalProfile` /
    /// `createLocalProfileAndAdopt` await, while mutating the very mapping table
    /// a load reads to decide which locals are still unmapped. So the two flows
    /// are made MUTUALLY EXCLUSIVE, not merely load-versus-load: `startPairing`
    /// refuses while this is set, and the gate modal greys its retry button on it.
    ///
    /// Without that, the load's `.pairingProfiles` write would land on top of a
    /// submit -- offering "Register as new" for a local the submit is in the
    /// middle of adopting (whose next submit then throws `alreadyMapped`), or
    /// reverting a finished modal to a stale candidate list. And it needs no
    /// user at all to happen: the gate re-drives a presented modal on every
    /// `.measured` announcement, and a `.createLocal` decision provokes one
    /// itself by creating a profile.
    ///
    /// `@Published` because the modal's retry button reads it: a plain stored
    /// property would leave the button greyed until the next `phase` change.
    @Published private(set) var isSubmitting = false

    private let manager: AccountKeyManager
    private var currentRequestId: String?
    private var pollTimer: Timer?
    /// The shared controller for the duration of this setup flow, captured when
    /// the flow opens (`beginSetup(controller:)`). Every terminal transition to
    /// `.done` re-runs `resolveMappings()` on it so a profile established in
    /// this session (bootstrap, recovery-code join, or approval join) registers
    /// immediately, instead of only on the next app launch's startup resolve.
    /// Held only for the short life of the flow, so it cannot go stale against
    /// a sign-out/sign-in controller rebuild; nil in tests and when signed out.
    private var flowController: SyncKeyController?

    /// The pairing load currently in flight, so a second `startPairing` can
    /// CANCEL AND REPLACE it instead of running two loads at once. A cancelled
    /// load is forbidden to write `phase`, so only the newest one ever lands.
    private var pairingLoad: Task<Void, Never>?

    /// How long `startPairing` waits for the account's profiles before giving
    /// up. `URLSession.shared`'s default timeout is 60 s PER REQUEST, so an
    /// unbounded load could sit in `.working` for minutes; the modal needs an
    /// answer -- even a failure -- well inside a user's patience. Injectable so
    /// tests do not have to wait for it.
    private let loadDeadline: Duration

    init(manager: AccountKeyManager, loadDeadline: Duration = .seconds(45)) {
        self.manager = manager
        self.loadDeadline = loadDeadline
    }

    /// Entry point when opening the key-layer window: unlock if possible, otherwise route to
    /// first-device bootstrap or the join-method choice.
    func beginSetup(controller: SyncKeyController? = nil) async {
        flowController = controller
        phase = .working
        do {
            switch try await manager.unlockAtStartup() {
            case .unlocked:
                await flowController?.resolveMappings()
                phase = .done
            case .notSignedIn:
                phase = .error(NSLocalizedString("You’re not signed in.",
                    comment: "Key layer - not signed in"))
            case .needsJoin:
                phase = try await manager.accountExists() ? .chooseJoinMethod : .working
                if case .working = phase { await startBootstrap() }
            }
        } catch {
            phase = .error("\(error)")
        }
    }

    func showRecoveryEntry() { phase = .enteringRecoveryCode }
    func chooseJoinAgain() { phase = .chooseJoinMethod }

    /// Requests approval from another device, then begins polling for the outcome.
    func startJoinRequest() async {
        phase = .working
        do {
            let ticket = try await manager.requestJoinApproval()
            currentRequestId = ticket.requestId
            phase = .waitingForApproval(code: ticket.verificationCode, deadline: Date().addingTimeInterval(900))
            startPollTimer()
        } catch let e as JoinRequestError where e == .tooManyPending {
            phase = .error(NSLocalizedString("Too many pending requests. Try again later or use a recovery code.",
                comment: "Key layer - too many pending join requests"))
        } catch {
            phase = .error("\(error)")
        }
    }

    /// One poll iteration (also called directly by tests).
    func pollOnce() async {
        guard let id = currentRequestId else { return }
        do {
            switch try await manager.pollJoin(requestId: id) {
            case .approved:
                // The join is under way: from here until the pairing wraps up, the gate
                // may present. Always through the port, never a direct defaults write.
                ProfilePairingGate.joinPairingPending = true
                await flowController?.resolveMappings()
                stopPolling(); phase = .done
            case .denied:   stopPolling(); phase = .joinDenied
            case .expired:  stopPolling(); phase = .joinExpired
            case .pending(let deadline):
                if Date() > deadline { stopPolling(); phase = .joinExpired }
                else if case .waitingForApproval(let code, _) = phase {
                    phase = .waitingForApproval(code: code, deadline: deadline)
                }
            }
        } catch {
            // Transient poll failure: keep waiting; the next tick retries.
        }
    }

    func cancelJoin() {
        stopPolling()
        currentRequestId = nil
        phase = .chooseJoinMethod
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPollTimer() {
        stopPolling()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Starts account bootstrap, generating a new recovery code. If the account
    /// was already initialized by another device, routes to the join flow instead.
    func startBootstrap() async {
        phase = .working
        do {
            phase = .showingRecoveryCode(try await manager.bootstrap())
        } catch AccountKeyError.alreadyInitialized {
            phase = .enteringRecoveryCode
        } catch {
            phase = .error("\(error)")
        }
    }

    /// Confirms the user saved the displayed recovery code, completing bootstrap.
    func confirmSaved() async {
        guard case .showingRecoveryCode = phase else { return }
        // Leave the recovery-code screen *before* the network round trip: it
        // must not stay interactive while `resolveMappings()` is in flight, or
        // the phase change can land on a view the user is still touching.
        phase = .working
        // The join is under way: from here until the pairing wraps up, the gate
        // may present. Always through the port, never a direct defaults write.
        ProfilePairingGate.joinPairingPending = true
        await flowController?.resolveMappings()
        phase = .done
    }

    /// Joins the account using a recovery code entered by the user.
    func submitRecoveryCode(_ code: String) async {
        phase = .working
        do {
            try await manager.joinWithRecoveryCode(code)
            // The join is under way: from here until the pairing wraps up, the gate
            // may present. Always through the port, never a direct defaults write.
            ProfilePairingGate.joinPairingPending = true
            await flowController?.resolveMappings()
            phase = .done
        } catch {
            phase = .error(NSLocalizedString(
                "Invalid recovery code. Please check it and try again.",
                comment: "Key layer recovery code entry - error shown when the entered code is rejected"))
        }
    }

    // MARK: - Semi-automatic profile pairing (M2-4 Task 5)

    /// Loads the still-unmapped local profiles and the still-unclaimed remote
    /// (account-registered) profiles and moves to `.pairingProfiles` so the
    /// user can resolve the ambiguous mapping by hand.
    ///
    /// Both sides are filtered by the persisted mapping rather than shown
    /// whole. An already-mapped local must not appear here: every row offers
    /// "Register as new", which `ProfileKeyManager.registerLocalProfile` now
    /// refuses with `alreadyMapped` for a mapped profile — and rightly so,
    /// since minting a second UUID would orphan that profile's existing
    /// envelope. Excluding the remotes those locals already claim likewise
    /// keeps the "create on this Mac" toggle from duplicating a profile that
    /// is in fact already present.
    ///
    /// Pressing "retry" while a load is still in flight CANCELS AND REPLACES it:
    /// the modal's retry button is pressable in every phase now (it used to be
    /// disabled in exactly the `.working` phase a stalled load sits in), and the
    /// gate re-drives an already-presented modal, so this can be called again at
    /// any moment. The method still does not return until the load it installed
    /// has finished, because every caller -- `submitPairing`'s failure reload,
    /// the retry button, the modal host, the Devices pane -- reads `phase`
    /// straight after awaiting it.
    ///
    /// A load started while `submitPairing` is applying decisions would not be a
    /// replacement but a SECOND writer of `phase` and a reader of a half-written
    /// mapping table, so that one case is turned away instead (see
    /// `isSubmitting`). The submit's own reload is not affected: it clears the
    /// flag before reloading, because that reload is its continuation.
    func startPairing(controller: SyncKeyController) async {
        guard !isSubmitting else {
            // Metadata only (R12).
            AppLogInfo("[phi-sync] pairing load skipped; a submit is still applying decisions")
            return
        }
        pairingLoad?.cancel()
        phase = .working
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runPairingLoad(controller: controller)
        }
        pairingLoad = task
        await task.value
    }

    /// One pairing load, bounded by `loadDeadline` and safe to cancel.
    ///
    /// EVERY write of `phase` here is guarded by a cancellation check taken in
    /// the same synchronous stretch: a load that has been replaced must not
    /// land its (stale, or merely cancelled) result on top of its replacement's.
    private func runPairingLoad(controller: SyncKeyController) async {
        guard !Task.isCancelled else { return }
        let allLocals = controller.localProfiles()
        let claimedUuids = Set(allLocals.compactMap {
            controller.profileKeys.mappedGlobalUuid(forProfileId: $0.profileId)
        })
        let locals = allLocals
            .filter { controller.profileKeys.mappedGlobalUuid(forProfileId: $0.profileId) == nil }
            .map { PairingLocal(profileId: $0.profileId, displayName: $0.displayName) }
        // Metadata only (R12): counts, never a uuid, a display name or an
        // envelope.
        AppLogInfo("[phi-sync] pairing load starting; \(locals.count) unmapped local profiles")
        let profileKeys = controller.profileKeys
        do {
            let remotes = try await withDeadline(loadDeadline) {
                try await profileKeys.accountProfiles()
            }.filter { !claimedUuids.contains($0.uuid) }
            guard !Task.isCancelled else { return }
            // The modal is the second writer of the undecryptable set (§3.6's
            // per-round refresh is the first): a row whose envelope did not open
            // here is read-only and must not make the gate think there is
            // something the user could still decide.
            for remote in remotes where remote.name == nil {
                controller.noteUndecryptableRemote(remote.uuid)
            }
            for remote in remotes where remote.name != nil {
                controller.noteDecryptableRemote(remote.uuid)
            }
            AppLogInfo("[phi-sync] pairing load finished; \(locals.count) local, \(remotes.count) remote candidates")
            phase = .pairingProfiles(locals: locals, remotes: remotes)
        } catch is PairingLoadTimedOut {
            guard !Task.isCancelled else { return }
            AppLogWarn("[phi-sync] pairing load exceeded its \(loadDeadline) deadline")
            phase = .error(NSLocalizedString(
                "Couldn’t load the account’s profiles in time. Check your connection and retry.",
                comment: "Pairing - load timeout"))
        } catch {
            guard !Task.isCancelled else { return }
            // R12：具体错误只进日志，界面上不出现插值出来的 Swift 错误文本（它在
            // `Localizable.xcstrings` 里也根本没有 key）。
            AppLogWarn("[phi-sync] pairing load failed: \(PhiSyncLog.describe(error))")
            phase = .error(PairingWizardStrings.profileLoadFailed)
        }
    }

    /// Races `body` against `deadline`. The loser is cancelled either way, so a
    /// deadline that lands really does take the in-flight request down with it
    /// rather than leaving it running behind an error screen.
    private func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil   // the deadline landed first
            }
            // The first child to finish decides; `next()` rethrows a real
            // failure from `body` unchanged, which is what keeps every existing
            // error path (`notUnlocked`, transport, HTTP) reading as it did.
            while let result = try await group.next() {
                group.cancelAll()
                guard let result else { throw PairingLoadTimedOut() }
                return result
            }
            throw PairingLoadTimedOut()
        }
    }

    /// Applies the user's pairing decisions. Returns true on success; on failure
    /// it sets `pairingError`, reloads the candidate list and returns false.
    ///
    /// 从 `submitPairing` 抽出来的**前半段**：`isSubmitting` 的互斥语义（:45-64）随之
    /// 留在这里，因为它描述的正是「决定正在被应用」这段时间。
    ///
    /// `.createLocal` creates the on-disk profile first (via the bridge) and
    /// adopts the remote onto the resulting profileId; if that creation fails,
    /// the decision is skipped and its error is surfaced while staying on
    /// `.pairingProfiles` rather than moving to `.done`.
    ///
    /// For the whole of it, this is the ONLY writer of `phase`: `isSubmitting`
    /// turns away any load `startPairing` is asked for meanwhile, and the load
    /// already in flight (the gate re-drives a presented modal roughly once a
    /// minute, so there may well be one) is cancelled here, which forbids it
    /// from writing `phase` on its way out.
    ///
    /// **幂等（§5.1 / §10.6 第 4 条）：`ProfileKeyManagerError.alreadyMapped` 不是失败。**
    /// 向导的 Retry 会拿着 Continue 那一刻冻结的**同一份** `profileDecisions` 重跑这个
    /// 方法（Space 侧失败停在 `.error(_, .backToSpaces)`，Retry → `.spaces` → Finish →
    /// 又进来一次）。`registerLocalProfile` 在本地 profile 已有映射时**一律**抛
    /// `alreadyMapped`（ProfileKeyManager.swift:94-97），而 `initialSelections` 把每个
    /// 没匹配上的本地 profile 都种成 `.registerNew`（ProfilePairingView.swift:55-67），
    /// 所以「第一次 Finish 写成功、第二次 Finish 撞 alreadyMapped」是加入路径上的**常态**，
    /// 不是异常。照抄旧循环体就会把用户从第 2 步的错误横幅弹回第 1 步，永远到不了
    /// `.done`。这与 `PairingWizardViewModel.apply(_:controller:)` 对
    /// `SpaceSyncMappingError.alreadyMapped` 的处理是同一条规则：**已经是想要的值 ⇒
    /// 就算完成**。`adoptRemoteProfile`（:114-120）本来就是幂等的（直接覆写映射），
    /// 不需要这条 catch。
    ///
    /// **`.createLocal` 有它自己的那一条判据，写在分支里面**：它不抛 `alreadyMapped`，
    /// 所以这条 catch 接不住它；`createLocalProfileAndAdopt` 的
    /// `reusablePendingProfile(forUuid:)` 只覆盖「建好了但认领失败」那一种重入，认领
    /// 成功之后那一项就被清掉了，重放会再建一个 "X (2)"。判据见下面 `.createLocal`
    /// 分支的注释。
    @discardableResult
    func applyPairingDecisions(_ decisions: [PairingDecision],
                               controller: SyncKeyController) async -> Bool {
        isSubmitting = true
        defer { isSubmitting = false }
        pairingLoad?.cancel()
        phase = .working
        pairingError = nil
        for decision in decisions {
            do {
                switch decision {
                case .adopt(let localProfileId, let remoteUuid):
                    _ = try await controller.profileKeys.adoptRemoteProfile(
                        uuid: remoteUuid, forLocalProfile: localProfileId)
                case .registerNew(let localProfileId, let displayName):
                    _ = try await controller.profileKeys.registerLocalProfile(
                        profileId: localProfileId, displayName: displayName)
                case .createLocal(let remoteUuid, let displayName):
                    // 幂等（§5.1），与下面那条 `alreadyMapped` 是同一条规则的第二个
                    // 实例：**这个 uuid 已经有本地 profile 了 ⇒ 就算完成**。Retry 会
                    // 拿着 Continue 那一刻冻结的同一份 `profileDecisions` 重放（Space
                    // 侧失败停在 `.error(_, .backToSpaces)`，Retry → `.spaces` →
                    // Finish → 又进来一次），而 `createLocalProfileAndAdopt` 只认
                    // `reusablePendingProfile(forUuid:)`——那一项在第一次**成功**认领
                    // 之后就被清成了 nil，于是重放会走 `else` 分支、`uniqueDisplayName`
                    // 给出 "X (2)"，在盘上建出第二个空 profile。映射表仍然正确（那个
                    // 新 profile 撞上 :558 的「uuid 已被认领」提前返回），但那个多出来
                    // 的 profile 是永久且用户可见的。
                    //
                    // 判据放在**决定这一层**、不放进 `createLocalProfileAndAdopt`：
                    // §3.6 的自动创建按 `missing` 集合调用，那个集合的定义就是「账户里
                    // 有、本机没有映射」，所以它永远不会带着一个已映射的 uuid 进来；把
                    // 早退塞进共享实现只会让它多一条自动路径上不可达的分支，还会让
                    // `created` 计数把一次没发生的创建算进去。
                    if controller.localProfileId(forGlobalUuid: remoteUuid) != nil {
                        // R12：元数据，不记 profileId、不记 uuid。
                        AppLogInfo("[phi-sync] pairing decision already applied; treating as done")
                        continue
                    }
                    // One shared implementation with §3.6's auto-create
                    // (`createLocalProfileAndAdopt`); only the `phase` /
                    // `pairingError` state machine stays here, and the direct
                    // `ProfileManager` dependency moves back into the key layer.
                    do {
                        _ = try await controller.createLocalProfileAndAdopt(
                            uuid: remoteUuid, displayName: displayName)
                    } catch ProfileKeyManagerError.badEnvelope {
                        // The one throw that means "the bridge did not make a
                        // profile"; the generic catch below would render it as
                        // raw enum text in the modal.
                        pairingError = String(format: NSLocalizedString(
                            "Couldn’t create a profile named “%@” on this Mac.",
                            comment: "Pairing - local profile creation failed"), displayName)
                        continue
                    }
                }
            } catch ProfileKeyManagerError.alreadyMapped {
                // 唯一的新分支。R12：元数据，不记 profileId、不记 uuid。
                AppLogInfo("[phi-sync] pairing decision already applied; treating as done")
                continue
            } catch {
                AppLogWarn("[phi-sync] a pairing decision failed: \(PhiSyncLog.describe(error))")
                pairingError = PairingWizardStrings.profileDecisionFailed
            }
        }
        guard pairingError == nil else {
            // Reload so the view reflects whatever succeeded before the
            // failure, and stay in .pairingProfiles for another attempt.
            // Clear the flag FIRST: this reload is the submit's own tail, not a
            // competing load, and `startPairing` would otherwise turn it away
            // and leave the modal parked in `.working` for good.
            isSubmitting = false
            await startPairing(controller: controller)
            return false
        }
        return true
    }

    /// 结构不变：`applyPairingDecisions` + 置 `joinPairingPending` +
    /// `resolveMappings` + `.done`。Devices pane 那条路继续调它。
    ///
    /// **唯一的行为变化，有意为之**：上面那条 `alreadyMapped` 的 catch 也落在这条路上，
    /// 于是 Devices pane 里的一次「重复提交」（拿着一张已经提交过的候选表再按一次
    /// Confirm）从「报错并留在 `.pairingProfiles`」变成「幂等地成功」。渲染结果、文案、
    /// 按钮启用判据、`ProfilePairingModel` 的输入与 `decisions()` 输出**全都没变**——
    /// 变的只有这一条错误路径，而它在 Devices pane 的**产品路径**上本来就不可达
    /// （`runPairingLoad` 会把已映射的本地 profile 过滤出 `locals`，:277-280）。
    /// 它在**单测**里是可达的，所以
    /// `KeyLayerViewModelTests.testAFailedSubmitStillReloadsTheCandidatesInsteadOfParkingInWorking`
    /// 的失败源同批换成了一次性的 PUT 失败（见那条用例的注释）。
    func submitPairing(_ decisions: [PairingDecision], controller: SyncKeyController) async {
        guard await applyPairingDecisions(decisions, controller: controller) else { return }
        // `applyPairingDecisions` 自己的 `defer` 已经把标志清掉了；下面这段尾巴仍然写
        // `phase`、仍然改动 resolved 缓存，所以它需要与今天整条 `submitPairing` 相同的
        // 互斥窗口（:349-353 那条不变量）。
        isSubmitting = true
        defer { isSubmitting = false }
        // The join is under way: from here until the pairing wraps up, the gate
        // may present. Always through the port, never a direct defaults write.
        // Redundant when this submit came from the `.settings` context — the
        // `resolveMappings()` below then reports `needsPairing == false` and the
        // gate clears the flag again without ever presenting.
        ProfilePairingGate.joinPairingPending = true
        await controller.resolveMappings()
        phase = .done
    }

    /// Whether every row the user CAN decide has been decided. Rows whose remote
    /// envelope will not open (`name == nil`) are excluded: they are read-only,
    /// both of their decisions would throw inside `adoptRemoteProfile`, and
    /// counting them would leave a modal that can never be closed.
    ///
    /// It takes only the REMOTE rows: a local row always has a decision (the
    /// picker's `registerNew` is its default and `startPairing` seeds it), so
    /// `locals` would be an unused parameter -- and an unused parameter in an
    /// enable predicate reads like a check that is happening and is not.
    /// `claimedRemoteUuids` / `createLocalUuids` are the view's own
    /// `@State selections` / `remoteChoices`, projected to uuid sets.
    func allRowsDecided(remotes: [RemoteProfile],
                        claimedRemoteUuids: Set<String>,
                        createLocalUuids: Set<String>) -> Bool {
        let decidableRemotes = remotes.filter { $0.name != nil }
        return !decidableRemotes.contains {
            !claimedRemoteUuids.contains($0.uuid) && !createLocalUuids.contains($0.uuid)
        }
    }
}

#if DEBUG
// MARK: - Preview support

/// No-op `KeyEnvelopeAPI` fake used only to drive SwiftUI previews for the two
/// key-layer views without touching the network.
struct PreviewKeyEnvelopeAPI: KeyEnvelopeAPI {
    func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool { true }
    func getAccount() async throws -> AccountKeyStateDTO? { nil }
    func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {}
    func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? { nil }
    func revokeDevice(deviceKeyId: String) async throws {}
    func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String { "preview" }
    func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO] { [] }
    func getJoinRequest(id: String) async throws -> JoinRequestDTO {
        JoinRequestDTO(requestId: id, requestingPublicKey: Data(), name: "", platform: "macos",
                       status: "pending", grantedArkEnvelope: Data(), createdAt: Date(), resolvedByDeviceKeyId: nil)
    }
    func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws {}
    func denyJoinRequest(id: String) async throws {}
    func listProfiles() async throws -> [ProfileSummaryDTO] { [] }
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? { nil }
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool { true }
    func getDomainKey(domain: String) async throws -> Data? { nil }
    func putDomainKey(domain: String, envelope: Data) async throws -> Bool { true }
}

/// No-op `DeviceKeyProviding` fake used only to drive SwiftUI previews for the
/// two key-layer views without touching the Keychain.
struct PreviewDeviceKeyProvider: DeviceKeyProviding {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey { privateKey }
    func deviceKeyId() throws -> String { "preview-device" }
}

extension KeyLayerViewModel {
    /// A view model backed entirely by in-memory preview fakes, for `#Preview` use.
    static func preview() -> KeyLayerViewModel {
        KeyLayerViewModel(manager: AccountKeyManager(
            api: PreviewKeyEnvelopeAPI(),
            deviceKeyProvider: PreviewDeviceKeyProvider()))
    }
}
#endif
