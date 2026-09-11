// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

enum PairingWizardStep: Equatable { case profiles, spaces }

/// Retry 从 `.error` 出去的两条路。**没有 `.backToConfirm`**：`resume` 不是「来源
/// 页」，它只有两个取值，都指向一个**能被重新算出来的**落点（一次重新加载 / 第 2 步的
/// 那份选择），所以确认页不需要被记住。
enum ErrorResume: Equatable {
    /// 两个加载中至少一个失败（`start()` 自己置的）。Retry 重跑 `start()`。
    case reload
    /// 提交序列在**第 2 步的 Space 决定**上失败。Retry 直接回 `.spaces`，两步的选择
    /// 全留，用户再按一次 Finish——重来的安全由幂等规则负责，不由这个 case 负责。
    case backToSpaces
}

enum PairingWizardPhase: Equatable {
    case loading
    case profiles(locals: [PairingLocal], remotes: [RemoteProfile])
    case spaces(SpacePairingModel.Input)
    /// D7 / R-D7-1：第 2 步之后、提交序列之前的覆盖确认页。载荷是**算好的**差异，
    /// 不是选择——`spaceSelections` 仍然是唯一的可变状态，Back 什么都不用还原。
    /// 空数组在这里是**非法**的：无差异时 Finish 根本不进这个 case。
    case confirmOverwrite([SpaceOverwriteDiff])
    case submitting
    case done
    case error(message: String, resume: ErrorResume)
}

/// 向导的文案。集中在一处，于是 `KeyLayerViewModel` 的两条 R12 替换与向导用的是
/// **同一条目录项**（key 即英文原文，两份不同的 comment 会在重新生成时打架）。
enum PairingWizardStrings {
    static let profileLoadFailed = NSLocalizedString(
        "Couldn’t load your account’s profiles. Check your connection and retry.",
        comment: "Pairing wizard - profile load failed")
    static let profileDecisionFailed = NSLocalizedString(
        "Couldn’t apply one of your profile choices. Check your connection and retry.",
        comment: "Pairing wizard - a profile decision failed")
    static let previewUnavailable = NSLocalizedString(
        "Sync isn’t available right now, so your account’s Spaces couldn’t be loaded.",
        comment: "Pairing wizard - no engine for the Space preview")
    static let previewFailed = NSLocalizedString(
        "Couldn’t load your account’s Spaces. Check your connection and retry.",
        comment: "Pairing wizard - Space preview failed")
    static let previewTruncated = NSLocalizedString(
        "Couldn’t load all of your account’s Spaces. Check your connection and retry.",
        comment: "Pairing wizard - Space preview truncated")
    static let previewTimedOut = NSLocalizedString(
        "Couldn’t load your account’s Spaces in time. Check your connection and retry.",
        comment: "Pairing wizard - Space preview timed out")
    static let applyFailed = NSLocalizedString(
        "Couldn’t finish setting up sync. Nothing was lost — check your connection and retry.",
        comment: "Pairing wizard - applying the decisions failed")
}

/// `Result` 的 Failure 必须 conform `Error`，而 `String` 不 conform（树上也没有这样一条
/// extension）。载荷仍然就是要渲染的那句话，只是套了一层。
private struct PairingWizardLoadFailure: Error { let message: String }

/// 预览与期限之间的一次性闸门：谁先到谁交卷，续体只能被恢复一次，第二个到达者是空
/// 操作。
///
/// **为什么不是 `withTaskGroup`。** 任务组在返回之前**必然**等待每一个子任务，而预览
/// 那个子任务取消不掉：`PhiSyncEngine.serialized(_:)` 把轮体放进一个**非结构化**
/// `Task {}`（不继承取消），随后 `await task.value` 是个非 throwing 的 `Task`，调用方
/// 被取消它也不会提前返回；`runPreview` 自己也只看 `isStopped`，从不看
/// `Task.isCancelled`。于是 `group.cancelAll()` 对真正在跑的那段工作是空操作，期限只
/// 改变**报什么**，改变不了**什么时候报**——加载页（`.loading` 没有 Retry 按钮，窗口
/// 也没有关闭键）会一直停在那里。
///
/// 被放弃的那一轮预览留在引擎队列上跑完，无害：§4.3 保证它一个字节都不持久化；它自己
/// 的预算（`PhiSyncEngine.previewDeadlineMs`）负责让它真的停下来。
private final class PreviewRace: @unchecked Sendable {
    typealias Outcome = Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(_ continuation: CheckedContinuation<Outcome, Never>) {
        self.continuation = continuation
    }

    /// `nil` = 期限先到。
    func finish(_ outcome: Outcome) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: outcome)
    }
}

/// 两步（外加 D7 的覆盖确认页）配对向导的状态机（§5.2 / §5.5）。
///
/// **向导有自己的 phase 枚举，绝不写 `KeyLayerPhase`**（R-D6-11）：`phase` 的第二个
/// 写者正是那条把模态钉死在 `.working` 的缺陷。向导**读** `keyLayer.phase` 只在两处，
/// 且都是取载荷：`.loading` 结束时取 `.pairingProfiles` 的载荷，以及
/// `applyPairingDecisions` 返回 false 之后**重读**它刚重载过的候选表。
@MainActor
final class PairingWizardViewModel: ObservableObject {
    @Published private(set) var phase: PairingWizardPhase = .loading
    @Published private(set) var step: PairingWizardStep = .profiles

    /// 第 1 步的可变状态（§5.3 的上提）：`ProfilePairingView` 今天的两个 `private
    /// @State` 搬到这里，view 改收 `@Binding`。没有这一步，把主按钮搬进页脚之后页脚
    /// 既读不到 `allRowsDecided` 的入参，也读不到 `decisions()`。
    @Published var profileSelections: [String: ProfilePairingModel.Choice] = [:]
    @Published var profileRemoteChoices: [String: ProfilePairingModel.RemoteChoice] = [:]
    /// 第 2 步**唯一**的可变状态。Back / Continue 往返不清，`.error` → Retry 也不清。
    @Published private(set) var spaceSelections: [String: SpacePairingModel.Assignment] = [:]

    /// `keyLayer.isSubmitting` 在**这个**对象上的镜像。视图只 `@StateObject` 观察向导
    /// VM，跨对象读 `keyLayer.isSubmitting` 既不触发重画、在 `.error` 出现的那一刻也
    /// 早被 `applyPairingDecisions` 的 `defer` 清掉了——所以页脚一律读这一条，**不要
    /// 再把 `keyLayer.isSubmitting` 加回去**（§6.5 的判据见 `PairingWizardView.actions`）。
    @Published private(set) var isApplying = false

    /// 向导自己建的那一个（这一句从 `AppModalPairingHost.present` 搬进来），只读不写。
    let keyLayer: KeyLayerViewModel

    private let previewAccountSpaces: () async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>
    private let pairableLocalSpaces: () -> [PhiLocalSpace]
    private let themeDisplayName: (String) -> String?
    private let loadDeadline: Duration

    /// `start()` 的世代号。`AppModalPairingHost.reloadAllowed` 对 `.loading` **故意**
    /// 放行（一次卡住的加载要有第二次机会），所以两趟 `start()` 交叠是设计内的常态，
    /// 不是异常——`reloadPresented()` 直接调 `start()`，绕过 `retry()` 的
    /// `guard case .error`。没有这个守卫，两种坏结果都可达：
    ///  - 第二趟的 `keyLayer.startPairing` 取消掉第一趟的 profile 加载，于是第一趟
    ///    提前醒来、看见 `keyLayer.phase` 还是 `.working`，把一个 `.error(_, .reload)`
    ///    盖在一次其实没问题的加载上；
    ///  - 第一趟先落地、用户已经在第 1/2 步做完选择，第二趟的预览随后回来，重跑同一段
    ///    成功分支，把 `profileSelections` / `spaceSelections` 一起清掉并把 `step` 拽回
    ///    `.profiles`——正是 `reloadAllowed` 拒绝那四个交互态要防的输入丢失。
    ///
    /// 形状与 `KeyLayerViewModel.runPairingLoad` 的 `Task.isCancelled` 守卫同源：
    /// **两次 await 之后的每一次写，都要先确认自己还是最新的那一趟。**
    private var loadGeneration = 0

    private var loadedLocals: [PairingLocal] = []
    private var loadedRemotes: [RemoteProfile] = []
    private var profileDecisions: [PairingDecision] = []
    private var spacesInput = SpacePairingModel.Input(locals: [], accountSpaces: [],
                                                      localProfileNames: [:],
                                                      accountProfileNames: [:])

    init(keyLayer: KeyLayerViewModel,
         previewAccountSpaces: @escaping () async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>,
         pairableLocalSpaces: @escaping () -> [PhiLocalSpace],
         themeDisplayName: @escaping (String) -> String?,
         loadDeadline: Duration = .seconds(45)) {
        self.keyLayer = keyLayer
        self.previewAccountSpaces = previewAccountSpaces
        self.pairableLocalSpaces = pairableLocalSpaces
        self.themeDisplayName = themeDisplayName
        self.loadDeadline = loadDeadline
    }

    // MARK: - Derived models

    var profileModel: ProfilePairingModel {
        ProfilePairingModel(locals: loadedLocals, remotes: loadedRemotes,
                            selections: profileSelections, remoteChoices: profileRemoteChoices)
    }

    var spaceModel: SpacePairingModel {
        SpacePairingModel(input: spacesInput, selections: spaceSelections)
    }

    /// 第 1 步的启用判据，逐字复用既有的那一条（KeyLayerViewModel.allRowsDecided）。
    var profileRowsDecided: Bool {
        let live = profileModel
        return keyLayer.allRowsDecided(remotes: loadedRemotes,
                                       claimedRemoteUuids: live.claimedRemoteUuids,
                                       createLocalUuids: live.createLocalUuids)
    }

    // MARK: - 宿主的唯一驱动入口

    func start(controller: SyncKeyController) async {
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        // 两次加载**并发发起**（互不依赖），但**必须都成功**才进 `.profiles`：第 2 步
        // 的 Account 列没有数据源就没法渲染，而在第 1 步之后才发现这件事，等于让用户
        // 白做一遍决定。
        async let profileLoad: Void = keyLayer.startPairing(controller: controller)
        async let spaceLoad = loadAccountSpaces()
        await profileLoad
        let spaces = await spaceLoad

        // 两次 await 之后的**第一件事**：确认自己还是最新的那一趟。往下一个字节都不写
        // （见 `loadGeneration`）。
        guard generation == loadGeneration else {
            AppLogInfo("[phi-sync] pairing wizard: a superseded load finished; dropping its result")
            return
        }

        guard case .pairingProfiles(let locals, let remotes) = keyLayer.phase else {
            let message: String
            if case .error(let existing) = keyLayer.phase { message = existing }
            else { message = PairingWizardStrings.profileLoadFailed }
            phase = .error(message: message, resume: .reload)
            return
        }
        switch spaces {
        case .failure(let failure):
            phase = .error(message: failure.message, resume: .reload)
        case .success(let accountSpaces):
            loadedLocals = locals
            loadedRemotes = remotes
            reseedProfileSelections(locals: locals, remotes: remotes)
            spacesInput = makeSpacesInput(accountSpaces: accountSpaces, remotes: remotes,
                                          controller: controller)
            spaceSelections = [:]
            step = .profiles
            phase = .profiles(locals: locals, remotes: remotes)
            logStep()
        }
    }

    // MARK: - 第 1 步

    /// 「Continue」**只做校验**：把决定冻结、把 `step` 切到 `.spaces`。不发网络、不写
    /// 映射、不碰 `joinPairingPending`。
    func continueToSpaces() {
        guard profileRowsDecided else { return }
        profileDecisions = profileModel.decisions()
        step = .spaces
        phase = .spaces(spacesInput)
        logStep()
    }

    func backToProfiles() {
        step = .profiles
        phase = .profiles(locals: loadedLocals, remotes: loadedRemotes)
        logStep()
    }

    // MARK: - 第 2 步

    /// 仅有的两个 mutator。D7 的确认页**不新增第三个**：Back 只是把 phase 换回
    /// `.spaces`，选择从来没被动过。
    func assign(_ assignment: SpacePairingModel.Assignment?, to localSpaceId: String) {
        var updated = spaceSelections
        if let assignment { updated[localSpaceId] = assignment }
        else { updated.removeValue(forKey: localSpaceId) }
        spaceSelections = updated
    }

    func addAllAsNew() {
        spaceSelections = spaceModel.addAllAsNew()
    }

    // MARK: - Finish / 确认页 / 提交

    /// 第 2 步的「Finish」。**它不再是提交点**：先算 D7 的差异（纯本地），有差异就先
    /// 把确认页交出去，一个字节都不写。
    func finish(controller: SyncKeyController) async {
        let diffs = SpaceOverwriteDiff.diffs(decisions: spaceModel.decisions(),
                                             locals: spacesInput.locals,
                                             accountSpaces: spacesInput.accountSpaces,
                                             themeDisplayName: themeDisplayName)
        // §9.1 第三条：**空差异也记**——「这次 Finish 到底出没出确认页」只有这一条
        // 线索。所以它在守卫**之前**，不在 `.confirmOverwrite` 分支里面。只有两个计数，
        // 没有名称、字段名与新旧值（R12）。
        AppLogInfo("[phi-sync] pairing wizard overwrite: spaces=\(diffs.count) "
                   + "fields=\(diffs.reduce(0) { $0 + $1.changes.count })")
        guard diffs.isEmpty else { phase = .confirmOverwrite(diffs); return }
        await applyDecisions(controller: controller)
    }

    /// 确认页的两个出口。Back 不还原任何东西——`spaceSelections` 从来没被动过。
    func backFromConfirmation() { phase = .spaces(spacesInput) }

    func applyConfirmedOverwrite(controller: SyncKeyController) async {
        await applyDecisions(controller: controller)
    }

    /// Retry 的两条路（§6.5）。一个 Retry 两种动作，判据只有 `resume` 这一个。
    func retry(controller: SyncKeyController) async {
        guard case .error(_, let resume) = phase else { return }
        switch resume {
        case .reload:
            await start(controller: controller)
        case .backToSpaces:
            // 重跑 `start()` 会把 `spacesInput` 与用户在第 2 步的指派一起冲掉（幂等
            // 只保证重写映射安全，不保证选择还在）。
            phase = .spaces(spacesInput)
        }
    }

    /// R-D6-3 的提交序列，一字未变；两个入口（无差异的 Finish、确认页的 Apply）共用
    /// 它，**不许**出现第二条应用路径。
    private func applyDecisions(controller: SyncKeyController) async {
        // 再入闸。两个入口（无差异的 Finish、确认页的 Apply）都是 `Task { await … }`，
        // 一次双击就能让两趟提交交叠，而序列里的每一步都只在**顺序**重放下才是幂等的
        // （`.createLocal` 会建出第二个空 profile，`.addAsNew` 会铸第二个 uuid）。
        guard !isApplying else {
            AppLogInfo("[phi-sync] pairing wizard: a submit is already applying; ignoring the second one")
            return
        }
        phase = .submitting
        isApplying = true
        defer { isApplying = false }
        var spaceMaps = 0
        var spaceMints = 0

        // 1. Profile 决定。
        guard await keyLayer.applyPairingDecisions(profileDecisions, controller: controller) else {
            step = .profiles
            // 载荷只有一个来源：`applyPairingDecisions` 失败时自己调 `startPairing`
            // 重载了候选表，结果就在 `keyLayer.phase` 里。这是第二处「读 phase」，
            // 仍然只读不写。
            if case .pairingProfiles(let locals, let remotes) = keyLayer.phase {
                loadedLocals = locals
                loadedRemotes = remotes
                reseedProfileSelections(locals: locals, remotes: remotes)
                phase = .profiles(locals: locals, remotes: remotes)
            } else {
                // 重载本身也失败了；恢复目标是重跑两个加载。
                phase = .error(message: PairingWizardStrings.profileLoadFailed, resume: .reload)
            }
            logApplied(spaceMaps: spaceMaps, spaceMints: spaceMints, ok: false)
            return
        }

        // 2. Space 决定。写的是**映射表**（`sync.spaceGlobalUuids`），不是**同步表**
        //    （`sync.phiSpaces`），两张表没有交集，所以这里不需要排进引擎的 round
        //    队列；而且写映射的时刻 Space 段的门还关着（第 3 步才清标志），引擎不会
        //    同时在读这些映射做 snapshot。这就是「为什么这里可以在主 actor 上直接写」
        //    的全部理由（§5.6）。
        do {
            for decision in spaceModel.decisions() {
                if try apply(decision, controller: controller) { spaceMints += 1 }
                else { spaceMaps += 1 }
            }
        } catch {
            // 停在第 2 步。原地重来见 §5.1 的幂等规则。
            phase = .error(message: PairingWizardStrings.applyFailed, resume: .backToSpaces)
            logApplied(spaceMaps: spaceMaps, spaceMints: spaceMints, ok: false)
            return
        }

        // 3. 门。映射（Profile 与 Space 两张表）在门打开之前就已经全部写好。
        ProfilePairingGate.joinPairingPending = false
        // 4.
        await controller.resolveMappings()
        phase = .done
        logApplied(spaceMaps: spaceMaps, spaceMints: spaceMints, ok: true)
    }

    /// 返回 true 表示**这一次**真的铸了一个新 uuid（`.addAsNew` 的首次应用），false 表示
    /// 它是一次认领、或是一次「已经是想要的值」的重放。计数是元数据（§9.1），重放不该
    /// 被算成第二次铸造。
    ///
    /// 幂等（§5.1）：已写下的映射撞 `.alreadyMapped` 时，**若既有映射等于这一行想写的
    /// 值，视为已完成**；不等则是硬错误（用户在两次尝试之间改了选择而第一次已经写下
    /// ——不应该发生，但必须被看见）。两支决定各有各的「等于想写的值」判据：`.existing`
    /// 比的是选中的那个 uuid，`.addAsNew` 比的是「这个 uuid 是不是账户里的某一条」。
    private func apply(_ decision: (localSpaceId: String, assignment: SpacePairingModel.Assignment),
                       controller: SyncKeyController) throws -> Bool {
        switch decision.assignment {
        case .existing(let syncUuid):
            do {
                try controller.mapSpace(decision.localSpaceId, toSyncUuid: syncUuid)
            } catch SpaceSyncMappingError.alreadyMapped {
                guard controller.syncUuid(forSpaceId: decision.localSpaceId) == syncUuid else {
                    // R12：只记「不相等」这个事实，不记 uuid。
                    AppLogError("[phi-sync] pairing wizard: an existing Space mapping disagrees with the choice (expected != actual)")
                    throw SpaceSyncMappingError.alreadyMapped
                }
            }
            return false
        case .addAsNew:
            // `ensureSpaceMapped` 是「不铸第二个」意义上的幂等，**不是这一行想要的那种
            // 幂等**：它对一个已经映射到**账户某条 Space** 的本地行会静默成功并保留原
            // 值。于是一次部分应用之后，用户把那一行**改选**成 Add as new（他要的正是
            // 保住本机的名字/图标/颜色）、Finish——D7 的差异跳过 `.addAsNew` 行，确认页
            // 不出现，映射却原封不动，首次同步走 A1「无基线 ⇒ 整条采纳」，恰好覆盖掉他
            // 想保住的那些字段。所以这一支要和 `.existing` 一样**显式**判：
            //  - 没有映射 ⇒ 铸一个（真正的新身份）；
            //  - 有映射，但那个 uuid 不在账户列表里 ⇒ 是本机自己早先铸的，视为已完成；
            //  - 有映射，且那个 uuid 就是账户里的某条 ⇒ 硬错误，和 `.existing` 的
            //    「expected != actual」同一条理由：绝不静默执行一个已被用户撤销的决定。
            if let existing = controller.syncUuid(forSpaceId: decision.localSpaceId) {
                guard !spacesInput.accountSpaces.contains(where: { $0.syncUuid == existing }) else {
                    // R12：只记「这一行还绑在账户的某条 Space 上」这个事实，不记 uuid。
                    AppLogError("[phi-sync] pairing wizard: an \"add as new\" row is still bound to an account Space (expected != actual)")
                    throw SpaceSyncMappingError.alreadyMapped
                }
                return false            // 本机早先铸的那一个，没有新铸
            }
            _ = try controller.ensureSpaceMapped(spaceId: decision.localSpaceId)
            return true
        }
    }

    // MARK: - Loading helpers

    private func reseedProfileSelections(locals: [PairingLocal], remotes: [RemoteProfile]) {
        profileSelections = ProfilePairingModel.initialSelections(locals: locals, remotes: remotes)
        profileRemoteChoices = [:]
    }

    /// §5.2 的三级取名：`remotes`（未认领的账户 Profile，解开的注册名）→ 已映射的账户
    /// Profile 的本地显示名 → 都不命中就**没有名字**（视图渲染成 `—`，且不影响任何
    /// 判据）。两份材料合起来覆盖账户里的每一个 Profile，所以第 1 步不必提前提交。
    private func makeSpacesInput(accountSpaces: [PhiAccountSpaceSummary],
                                 remotes: [RemoteProfile],
                                 controller: SyncKeyController) -> SpacePairingModel.Input {
        var localNames: [String: String] = [:]
        for profile in controller.localProfiles() {
            localNames[profile.profileId] = profile.displayName
        }
        var accountNames: [String: String] = [:]
        for remote in remotes where remote.name != nil {
            accountNames[remote.uuid] = remote.name
        }
        for summary in accountSpaces where accountNames[summary.profileUuid] == nil {
            if let localId = controller.localProfileId(forGlobalUuid: summary.profileUuid),
               let name = localNames[localId] {
                accountNames[summary.profileUuid] = name
            }
        }
        return SpacePairingModel.Input(locals: pairableLocalSpaces(),
                                       accountSpaces: accountSpaces,
                                       localProfileNames: localNames,
                                       accountProfileNames: accountNames)
    }

    /// §4.5 的 45 s 期限 + §4.6 的错误映射，一处。`URLSession` 默认每请求 60 s，而
    /// 预览是一次**分页**拉取，不设期限就可能让加载页停几分钟。R12：具体错误只进日志。
    ///
    /// **期限一共两道，取值相同，职责不同**：这一道保证**界面**不卡（无论底下那一轮
    /// 怎么样，到点就返回），`PhiSyncEngine.previewDeadlineMs` 那一道保证**工作**真的
    /// 停下来（轮体自己不再往下翻页，round 队列随之让开）。少了任何一道都不够：这一道
    /// 管不了引擎队列，那一道管不了单次请求的 60 s。
    private func loadAccountSpaces() async -> Result<[PhiAccountSpaceSummary], PairingWizardLoadFailure> {
        let preview = previewAccountSpaces
        let deadline = loadDeadline
        // 两个赛跑者都是**非结构化**任务，交卷走一次性闸门（`PreviewRace` 的注释写了
        // 为什么任务组在这里不成立）。于是期限那一支**立刻**返回，界面不会等在一个
        // 取消不掉的子任务上。
        let outcome: Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>? =
            await withCheckedContinuation { continuation in
                let race = PreviewRace(continuation)
                Task { race.finish(await preview()) }
                Task {
                    try? await Task.sleep(for: deadline)
                    race.finish(nil)    // 期限先到
                }
            }
        guard let outcome else {
            AppLogWarn("[phi-sync] pairing wizard: the account Space preview exceeded its deadline")
            return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewTimedOut))
        }
        switch outcome {
        case .success(let summaries):
            return .success(summaries)
        case .failure(let error):
            AppLogWarn("[phi-sync] pairing wizard: space preview failed code=\(Self.code(for: error))")
            switch error {
            case .engineUnavailable, .retired:
                return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewUnavailable))
            case .timedOut:
                // 引擎那一侧的同一条期限（`PhiSyncEngine.previewDeadlineMs`）。文案与
                // 向导自己的期限**同一句**：对用户来说两者是同一件事。
                return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewTimedOut))
            case .truncated:
                return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewTruncated))
            case .transport:
                // `.transport("not_my_birthday")` **不是死路**：设置同步照常按 60 s
                // 跑，它自己的 birthday 重试会把 `storedBirthday` 修好，所以下一次
                // Retry 就能过——唯一出口不是自撤销。
                return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewFailed))
            }
        }
    }

    /// R12：日志里只出现这些固定 code，绝不是插值出来的错误文本。
    private static func code(for error: PhiSpacePreviewError) -> String {
        switch error {
        case .engineUnavailable: return "engine_unavailable"
        case .retired: return "retired"
        case .timedOut: return "timed_out"
        case .truncated: return "truncated"
        case .transport(let detail): return "transport:\(detail)"
        }
    }

    // MARK: - §9.1 的两条日志（只有计数与布尔）

    private func logStep() {
        let undecided: Int
        switch step {
        case .profiles:
            let live = profileModel
            undecided = loadedRemotes.filter {
                $0.name != nil && !live.claimedRemoteUuids.contains($0.uuid)
                    && !live.createLocalUuids.contains($0.uuid)
            }.count
        case .spaces:
            undecided = spaceModel.rows.count - spaceModel.decisions().count
        }
        AppLogInfo("[phi-sync] pairing wizard: step=\(step == .profiles ? "profiles" : "spaces") "
                   + "locals=\(spacesInput.locals.count) "
                   + "account_spaces=\(spacesInput.accountSpaces.count) undecided=\(undecided)")
    }

    private func logApplied(spaceMaps: Int, spaceMints: Int, ok: Bool) {
        AppLogInfo("[phi-sync] pairing wizard applied: "
                   + "profile_decisions=\(profileDecisions.count) space_maps=\(spaceMaps) "
                   + "space_mints=\(spaceMints) ok=\(ok)")
    }
}
