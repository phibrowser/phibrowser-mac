import Combine
import XCTest
@testable import Phi

/// 向导的状态机（§5.2 / §5.5）。**第 1–8 条一律用「被映射的行与账户 Space 六个字段
/// 全等」的 fixture**，于是 Finish 不出确认页、这些用例描述的路径与 D7 之前逐字相同；
/// D7 自己的路径是第 9–13 条。
@MainActor
final class PairingWizardViewModelTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    /// 顺序记录假件：每次写映射时把「此刻 `joinPairingPending` 还是不是真」一起记下
    /// 来。这比一串事件名更结实——它直接钉住「门在所有映射写完之前不许开」（§5.5 的
    /// 第 3 步为什么排在第 2 步之后）。
    final class LedgerSpaceMappingStore: SpaceSyncMappingStore {
        var map: [String: String] = [:]
        private(set) var writes: [(spaceId: String, uuid: String, pendingWhenWritten: Bool)] = []
        func syncUuid(forSpaceId spaceId: String) -> String? { map[spaceId] }
        func setSyncUuid(_ uuid: String, forSpaceId spaceId: String) {
            map[spaceId] = uuid
            // 嵌套类型不继承外层的 `@MainActor`，而 `joinPairingPending` 是主 actor 上的。
            // 写入口 `SpaceSyncMappingManager` 本身就是 `@MainActor`，所以这里断言而非
            // 跳板——跳板会把这条记录挪到写之后，顺序断言就不成立了。
            let pending = MainActor.assumeIsolated { ProfilePairingGate.joinPairingPending }
            writes.append((spaceId, uuid, pending))
        }
        func allMappings() -> [String: String] { map }
        func removeMapping(forSpaceId spaceId: String) { map.removeValue(forKey: spaceId) }
        func removeAllMappings() { map = [:] }
    }

    /// 一个可以被用例**按住**的预览。`enter()` 只按住第 1 次调用，之后的调用直接放行，
    /// 于是「第一趟加载还悬着、第二趟已经落地」这个交叠可以被确定性地摆出来。
    actor PreviewHold {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private(set) var calls = 0

        func enter() async {
            calls += 1
            guard calls == 1, !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    private var resolveCount = 0
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        ProfilePairingGate.staticPendingOverride = true
        resolveCount = 0
        observer = NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.resolveCount += 1 } }
    }

    override func tearDown() {
        ProfilePairingGate.staticPendingOverride = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        super.tearDown()
    }

    private func local(_ id: String, name: String, profile: String = "Default") -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: profile, name: name, colorHex: "#3AA4D5",
                      iconName: "phi:a", sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1),
                      themeId: nil, opacityLight: nil, opacityDark: nil)
    }

    private func account(_ uuid: String, name: String,
                         profileUuid: String = "uuid-a") -> PhiAccountSpaceSummary {
        PhiAccountSpaceSummary(syncUuid: uuid, name: name, iconName: "phi:a", colorHex: "#3AA4D5",
                               profileUuid: profileUuid, isDefault: false, themeId: "",
                               overlayOpacityLightMilli: -1, overlayOpacityDarkMilli: -1)
    }

    /// 一台已经 bootstrap 过账户的机器 + 一个可编程的预览。
    private func makeWizard(
        locals: [PhiLocalSpace],
        accountSpaces: [PhiAccountSpaceSummary],
        preview: (() async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>)? = nil,
        loadDeadline: Duration = .seconds(45)
    ) async throws -> (PairingWizardViewModel, SyncKeyController, LedgerSpaceMappingStore, FakeAPI) {
        let api = FakeAPI()
        let manager = AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
        _ = try await manager.bootstrap()
        let profileKeys = ProfileKeyManager(api: api, keyManager: manager,
                                            mappingStore: MemoryMappingStore())
        let spaceStore = LedgerSpaceMappingStore()
        let controller = SyncKeyController(
            manager: manager,
            approvals: DeviceApprovalService(api: api, keyManager: manager,
                                             deviceKeyProvider: FakeDeviceKeyProvider()),
            profileKeys: profileKeys,
            spaceKeys: SpaceSyncMappingManager(store: spaceStore),
            localProfilesProvider: { [(profileId: "Default", displayName: "Personal")] },
            notifyChromium: {})
        let wizard = PairingWizardViewModel(
            keyLayer: KeyLayerViewModel(manager: manager),
            previewAccountSpaces: preview ?? { .success(accountSpaces) },
            pairableLocalSpaces: { locals },
            themeDisplayName: { _ in nil },
            loadDeadline: loadDeadline)
        return (wizard, controller, spaceStore, api)
    }

    // MARK: - 1. 状态机正向

    func testTheHappyPathWalksLoadingProfilesSpacesSubmittingDone() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local(LocalStore.defaultSpaceId, name: "Default"), local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "Work")])

        await wizard.start(controller: controller)
        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles") }
        XCTAssertEqual(wizard.step, .profiles)

        wizard.continueToSpaces()
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        XCTAssertEqual(wizard.step, .spaces)

        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        XCTAssertTrue(wizard.spaceModel.allRowsDecided)
        await wizard.finish(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(store.map, ["LOCAL-1": "acct-1"])
    }

    // MARK: - 2. Continue 只做校验

    func testContinueWritesNothingAndTouchesNeitherTheFlagNorTheMappings() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        resolveCount = 0

        wizard.continueToSpaces()
        XCTAssertTrue(store.map.isEmpty, "映射表零写入")
        XCTAssertTrue(ProfilePairingGate.joinPairingPending, "`joinPairingPending` 未被改")
        XCTAssertEqual(resolveCount, 0, "`resolveMappings()` 零调用")
    }

    // MARK: - 3. Finish 的顺序

    func testTheApplySequenceIsProfilesThenMappingsThenTheFlagThenResolve() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        resolveCount = 0

        await wizard.finish(controller: controller)

        XCTAssertEqual(api.profileEnvelopes.count, 1, "第 1 步：Profile 决定先应用")
        XCTAssertEqual(store.writes.map(\.pendingWhenWritten), [true],
                       "第 3 步在第 2 步之后：所有映射写完之前，门必须还关着")
        XCTAssertFalse(ProfilePairingGate.joinPairingPending)
        XCTAssertGreaterThan(resolveCount, 0, "第 4 步：resolveMappings() 在最后")
        XCTAssertEqual(wizard.phase, .done)
    }

    // MARK: - 4. 幂等

    /// 失败是**真实语义**造出来的，不是一个注入点：盘上留着上一轮的一行残缺映射
    /// （`STALE -> acct-2`），于是第二条决定撞 `.syncUuidAlreadyClaimed`。清掉那一行
    /// 再 Retry，第一条映射**不被重复写**，最终表与一次成功的 Finish 完全一致。
    ///
    /// **Profile 侧的幂等也在这一条里**（§10.6 第 4 条的前半句）：第一次 Finish 已经
    /// 把 `Default` 注册进账户，Retry 之后的第二次 Finish 会拿着同一份冻结的
    /// `profileDecisions` 再跑一遍，`registerLocalProfile` 因此抛
    /// `ProfileKeyManagerError.alreadyMapped`。Task 7 Step 2 (c) 那条 catch 把它当成
    /// 「已完成」，所以 `wizard.phase == .done` 成立；少了那条 catch，这里会停在
    /// `.profiles`——这就是那条 catch 的回归网。
    func testASecondFinishAfterAFailureConvergesOnTheSameTable() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work"), account("acct-2", name: "Reading")])
        store.map["STALE"] = "acct-2"
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")

        await wizard.finish(controller: controller)
        guard case .error(_, let resume) = wizard.phase else { return XCTFail("expected .error") }
        XCTAssertEqual(resume, .backToSpaces)
        XCTAssertTrue(ProfilePairingGate.joinPairingPending, "失败时门必须还关着")
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1", "第一条已经写下了")

        store.map.removeValue(forKey: "STALE")
        await wizard.retry(controller: controller)
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        await wizard.finish(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1")
        XCTAssertEqual(store.map["LOCAL-2"], "acct-2")
        XCTAssertEqual(store.writes.filter { $0.spaceId == "LOCAL-1" }.count, 1,
                       "`alreadyMapped` 且既有值等于期望值 ⇒ 视为已完成，不重复写")
        XCTAssertEqual(api.profileEnvelopes.count, 1,
                       "Profile 侧同理：第二次 Finish 的 `alreadyMapped` 不是失败，也没有铸第二个信封")
    }

    // MARK: - 4b. `.addAsNew` 的幂等判据

    /// 一次部分应用之后**改选** `.addAsNew` 必须被拒绝，不许静默沿用旧映射。
    ///
    /// `ensureSpaceMapped` 只保证「不铸第二个」，对一个已经绑到账户 Space 的本地行会
    /// 静默成功。于是：第一次 Finish 写下 `LOCAL-1 -> acct-1` 后在 `LOCAL-2` 上抛错；
    /// 用户回到第 2 步，把 `LOCAL-1` 改成 Add as new——他要的正是保住本机的名字/图标/
    /// 颜色；D7 的差异跳过 `.addAsNew` 行，确认页不出现；旧代码里 `apply` 是个空操作，
    /// 映射原封不动，首次同步走 A1「无基线 ⇒ 整条采纳」，恰好覆盖掉他想保住的东西。
    func testAnAddAsNewRowStillBoundToAnAccountSpaceIsRefusedRatherThanSilentlyKept() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work"), account("acct-2", name: "Reading")])
        store.map["STALE"] = "acct-2"      // 第二条决定撞 `.syncUuidAlreadyClaimed`
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")

        await wizard.finish(controller: controller)
        guard case .error(_, .backToSpaces) = wizard.phase else { return XCTFail("expected .error") }
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1")

        await wizard.retry(controller: controller)
        wizard.assign(.addAsNew, to: "LOCAL-1")
        await wizard.finish(controller: controller)

        guard case .error(_, .backToSpaces) = wizard.phase else {
            return XCTFail("一个已被撤销的决定绝不能被静默执行")
        }
        XCTAssertEqual(store.map["LOCAL-1"], "acct-1", "既没有铸新的，也没有悄悄沿用")
        XCTAssertEqual(store.writes.filter { $0.spaceId == "LOCAL-1" }.count, 1)
        XCTAssertTrue(ProfilePairingGate.joinPairingPending, "门必须还关着")
    }

    /// 另一半：映射是**本机自己早先铸的**（那个 uuid 不在账户列表里）⇒ 重放视为已完成，
    /// 不铸第二个、也不报错。没有这一条，上面那条判据就会把正常的 Retry 变成死路。
    func testAnAddAsNewRowBoundToThisDevicesOwnEarlierMintReplaysAsDone() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work"), account("acct-2", name: "Reading")])
        store.map["STALE"] = "acct-2"
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.addAsNew, to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")

        await wizard.finish(controller: controller)
        guard case .error(_, .backToSpaces) = wizard.phase else { return XCTFail("expected .error") }
        let minted = try XCTUnwrap(store.map["LOCAL-1"])

        store.map.removeValue(forKey: "STALE")
        await wizard.retry(controller: controller)
        await wizard.finish(controller: controller)

        XCTAssertEqual(wizard.phase, .done)
        XCTAssertEqual(store.map["LOCAL-1"], minted, "同一个 uuid，没有铸第二个")
        XCTAssertEqual(store.writes.filter { $0.spaceId == "LOCAL-1" }.count, 1)
        XCTAssertEqual(store.map["LOCAL-2"], "acct-2")
    }

    // MARK: - 5. Finish 第 1 步失败

    /// 载荷断言的是**重读**而不是一份固定值：`applyPairingDecisions` 失败时自己调
    /// `startPairing` 重载了候选表，向导渲染的必须是**新**的那一张（§5.5）。
    ///
    /// 第 1 步的决定是 `.registerNew(Default)`（本机唯一的本地 profile、账户里空无
    /// 一物），让它的 PUT 失败**一次**，并在重载之前给账户加一个 Profile，于是重载
    /// 回来的候选表与第一次不同。
    func testAFailedProfileStepGoesBackToStepOneWithTheReloadedCandidates() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        guard case .profiles(let firstLocals, let firstRemotes) = wizard.phase else {
            return XCTFail("expected .profiles")
        }
        XCTAssertEqual(firstLocals.map(\.profileId), ["Default"])
        XCTAssertTrue(firstRemotes.isEmpty)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        api.profileEndpointErrorOnce = KeyAPIError.http(500, "boom")
        api.profileEnvelopes["uuid-remote"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Home",
            ark: try XCTUnwrap(controller.manager.currentARK))
        await wizard.finish(controller: controller)

        guard case .profiles(_, let reloaded) = wizard.phase else {
            return XCTFail("expected to land back on step 1")
        }
        XCTAssertEqual(reloaded.map(\.uuid), ["uuid-remote"], "渲染的是**重载后**的那一张表")
        XCTAssertEqual(wizard.step, .profiles)
        XCTAssertTrue(ProfilePairingGate.joinPairingPending, "门必须还关着")
        XCTAssertTrue(store.map.isEmpty, "Space 映射零写入")
    }

    /// 重载本身也失败 ⇒ 落到 `.error(_, .reload)`，而不是拿着旧载荷继续。
    func testAFailedProfileStepWhoseReloadAlsoFailsLandsOnErrorReload() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        api.profileEndpointError = KeyAPIError.http(500, "boom")   // 决定失败
        api.listProfilesError = KeyAPIError.http(500, "boom")      // 重载也失败
        await wizard.finish(controller: controller)

        guard case .error(_, let resume) = wizard.phase else { return XCTFail("expected .error") }
        XCTAssertEqual(resume, .reload)
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertTrue(ProfilePairingGate.joinPairingPending)
    }

    // MARK: - 5b. 第 2 步的选择跨 Back / 失败保留

    func testStepTwoSelectionsSurviveBackAndAFailedApply() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work"), local("LOCAL-2", name: "Reading")],
            accountSpaces: [account("acct-1", name: "Work"), account("acct-2", name: "Reading")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        wizard.assign(.existing(syncUuid: "acct-2"), to: "LOCAL-2")

        wizard.backToProfiles()
        wizard.continueToSpaces()
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"))
        XCTAssertEqual(wizard.spaceSelections["LOCAL-2"], .existing(syncUuid: "acct-2"))

        store.map["STALE"] = "acct-2"      // 第二条决定撞 `.syncUuidAlreadyClaimed`
        await wizard.finish(controller: controller)
        await wizard.retry(controller: controller)
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"))
        XCTAssertEqual(wizard.spaceSelections["LOCAL-2"], .existing(syncUuid: "acct-2"),
                       "`spaceSelections` 活在 VM 上，不是 step view 的 @State")
    }

    // MARK: - 5c. 左列含 profile 尚未映射的 Space

    /// §10.9 第 3 步能否成立的单测投影：用 `currentSpaces()` 口径的假件跑同一条用例
    /// 必须红（那个口径下这一行会被整体藏掉）。
    func testARowWhoseProfileIsStillUnmappedIsListedInStepTwo() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-7", name: "Work", profile: "Profile 7")],
            accountSpaces: [])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        XCTAssertEqual(wizard.spaceModel.rows.map(\.spaceId), ["LOCAL-7"])
    }

    // MARK: - 6. 加载失败与重驱

    func testAFailedPreviewStopsAtErrorReloadAndKeepsStepOne() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [],
            preview: { .failure(.truncated) })
        await wizard.start(controller: controller)
        guard case .error(_, let resume) = wizard.phase else { return XCTFail("expected .error") }
        XCTAssertEqual(resume, .reload)
        XCTAssertEqual(wizard.step, .profiles)
    }

    /// §4.5 的期限必须真的**让加载页停下来**，不是只改变报什么。
    ///
    /// 注入的预览刻意做成**取消不掉**的——一个非结构化 `Task` 加上
    /// `await task.value`，正是 `PhiSyncEngine.serialized(_:)` 的形状。`withTaskGroup`
    /// 在这种载荷下是个陷阱：它在返回前必然等待每一个子任务，`cancelAll()` 对这段工作
    /// 是空操作，于是期限那一支永远走不到，模态就停在没有 Retry 按钮的 `.loading` 页
    /// 上。所以断言的是**时间**，不只是 phase。
    func testTheLoadDeadlineReturnsWhileAnUncancellablePreviewIsStillRunning() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [],
            preview: {
                let work = Task { () -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError> in
                    try? await Task.sleep(for: .seconds(2))
                    return .success([])
                }
                return await work.value
            },
            loadDeadline: .milliseconds(50))

        let startedAt = Date()
        await wizard.start(controller: controller)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 1.0, "期限到了就得返回，不许等那个取消不掉的预览")
        guard case .error(let message, let resume) = wizard.phase else {
            return XCTFail("expected .error")
        }
        XCTAssertEqual(message, PairingWizardStrings.previewTimedOut)
        XCTAssertEqual(resume, .reload, "Retry 重跑 start()")
    }

    /// `reloadAllowed` 对 `.loading` **故意**放行，所以两趟 `start()` 交叠是设计内的
    /// 常态。一趟被取代的加载落地时必须**什么都不写**：否则它要么把一个 `.error` 盖在
    /// 一次其实没问题的加载上，要么把用户已经做完的两步选择连同 `step` 一起冲掉。
    func testASupersededStartWritesNothingWhenItFinallyLands() async throws {
        let hold = PreviewHold()
        let spaces = [account("acct-1", name: "Work")]
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: spaces,
            preview: { await hold.enter(); return .success(spaces) })

        // 第 1 趟：预览被按住。
        let first = Task { await wizard.start(controller: controller) }
        var spins = 0
        while await hold.calls == 0, spins < 10_000 { spins += 1; await Task.yield() }
        let calls = await hold.calls
        XCTAssertEqual(calls, 1, "第 1 趟已经停在预览里")

        // 第 2 趟（gate 的 re-drive 走的就是这条路）：它的预览直接放行并落地。
        await wizard.start(controller: controller)
        guard case .profiles = wizard.phase else { return XCTFail("expected .profiles") }
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        // 第 1 趟这才回来。
        await hold.release()
        await first.value

        XCTAssertEqual(wizard.step, .spaces, "被取代的那一趟不许把 step 拽回第 1 步")
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"),
                       "也不许把第 2 步的指派清掉")
        guard case .spaces = wizard.phase else { return XCTFail("phase 也不许被改写") }
    }

    // MARK: - 7. 不写 `KeyLayerPhase`

    func testTheWizardIsNeverASecondWriterOfKeyLayerPhase() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")], accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        let afterLoad = wizard.keyLayer.phase
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        XCTAssertEqual(wizard.keyLayer.phase, afterLoad,
                       "整条交互路径上向导只**读** keyLayer.phase")
    }

    // MARK: - 8. 第 2 步的 Profile 标签解析（§5.2 的三级取名）

    /// 三条一起断言（三份材料按序取第一个命中的）：未认领的账户 Profile 取 `remotes`
    /// 里解开的注册名；已映射的取本地显示名；两者都不命中 ⇒ `accountProfileNames` 里
    /// **没有这一项**（视图渲染成 `—`，且不影响任何判据）。
    func testAccountProfileNamesComeFromRemotesThenTheMappingThenNothing() async throws {
        // 三条账户 Space，各自落在三种解析上。
        let (wizard, controller, _, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "A", profileUuid: "uuid-unclaimed"),
                            account("acct-2", name: "B", profileUuid: "uuid-claimed"),
                            account("acct-3", name: "C", profileUuid: "uuid-nowhere")])
        let ark = try XCTUnwrap(controller.manager.currentARK)
        // 1) 未认领：账户里有它的信封、本机没有映射 ⇒ 它会出现在 `remotes` 里。
        api.profileEnvelopes["uuid-unclaimed"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Home", ark: ark)
        // 2) 已映射：本机的 `Default` 已经认领了它 ⇒ `startPairing` 的
        //    `filter { !claimedUuids.contains($0.uuid) }` 把它挡在 `remotes` 之外，
        //    只能靠 `localProfileId(forGlobalUuid:)` + 本地显示名解析。
        api.profileEnvelopes["uuid-claimed"] = try ProfileKeyManager.sealProfilePayload(
            key: Data(count: 32), name: "Ignored on the wire", ark: ark)
        _ = try await controller.profileKeys.adoptRemoteProfile(
            uuid: "uuid-claimed", forLocalProfile: "Default")
        // 3) `uuid-nowhere` 两边都没有。

        await wizard.start(controller: controller)
        let names = wizard.spaceModel.input.accountProfileNames
        XCTAssertEqual(names["uuid-unclaimed"], "Home", "未认领的取 remotes 里解开的注册名")
        XCTAssertEqual(names["uuid-claimed"], "Personal",
                       "已映射的取**本地**显示名（`localProfilesProvider` 给的那个）")
        XCTAssertNil(names["uuid-nowhere"], "都不命中 ⇒ 没有这一项；视图渲染成 `—`")
    }

    // MARK: - D7（§10.6 的 9–13）

    /// 9. 有差异 ⇒ Finish 停在确认页，**确认之前一个字节都没写**。
    func testADifferingFieldStopsFinishAtTheConfirmationWithNothingWritten() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Job")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        resolveCount = 0

        await wizard.finish(controller: controller)

        guard case .confirmOverwrite(let items) = wizard.phase else {
            return XCTFail("expected .confirmOverwrite")
        }
        XCTAssertEqual(items.map(\.localSpaceId), ["LOCAL-1"])
        XCTAssertEqual(items.first?.changes.map(\.field), [.name])
        XCTAssertTrue(store.map.isEmpty, "映射表零写入")
        XCTAssertTrue(ProfilePairingGate.joinPairingPending)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(api.profileEnvelopes.count, 0, "`applyPairingDecisions` 零调用")
        XCTAssertEqual(wizard.step, .spaces, "确认页不是第三个步骤：步骤条上 ② 仍是 current")
    }

    /// 10. Back 保留选择，再按 Finish 又是同一张确认页（因为它是重算的）。
    func testBackFromTheConfirmationKeepsEverySelection() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Job")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        await wizard.finish(controller: controller)
        guard case .confirmOverwrite(let first) = wizard.phase else { return XCTFail("expected page") }

        wizard.backFromConfirmation()
        guard case .spaces = wizard.phase else { return XCTFail("expected .spaces") }
        XCTAssertEqual(wizard.step, .spaces)
        XCTAssertEqual(wizard.spaceSelections["LOCAL-1"], .existing(syncUuid: "acct-1"))

        await wizard.finish(controller: controller)
        guard case .confirmOverwrite(let second) = wizard.phase else { return XCTFail("expected page") }
        XCTAssertEqual(first, second)
    }

    /// 11. Apply 走的是**同一条**提交序列（同一个顺序断言，不给确认页开第二条路）。
    func testApplyFromTheConfirmationRunsTheSameSequence() async throws {
        let (wizard, controller, store, api) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Job")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        await wizard.finish(controller: controller)
        resolveCount = 0

        await wizard.applyConfirmedOverwrite(controller: controller)

        XCTAssertEqual(api.profileEnvelopes.count, 1)
        XCTAssertEqual(store.writes.map(\.pendingWhenWritten), [true])
        XCTAssertFalse(ProfilePairingGate.joinPairingPending)
        XCTAssertGreaterThan(resolveCount, 0)
        XCTAssertEqual(wizard.phase, .done)
    }

    /// 12. 无差异不出页——对 `phase` 的**写入序列**做断言，不是只看终态。
    func testNoDifferenceMeansTheConfirmationNeverAppears() async throws {
        let (wizard, controller, _, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Work")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")

        var seen: [PairingWizardPhase] = []
        let cancellable = wizard.$phase.sink { seen.append($0) }
        await wizard.finish(controller: controller)
        cancellable.cancel()

        XCTAssertFalse(seen.contains { if case .confirmOverwrite = $0 { return true }; return false })
        XCTAssertTrue(seen.contains { if case .submitting = $0 { return true }; return false })
        XCTAssertEqual(wizard.phase, .done)
    }

    /// 13. 差异是**重算**的，不是冻结的：Back → 把那一行改选 `.addAsNew` → Finish ⇒
    ///     不再出现确认页，直接提交。
    func testChangingTheRowToAddAsNewMakesTheConfirmationDisappear() async throws {
        let (wizard, controller, store, _) = try await makeWizard(
            locals: [local("LOCAL-1", name: "Job")],
            accountSpaces: [account("acct-1", name: "Work")])
        await wizard.start(controller: controller)
        wizard.continueToSpaces()
        wizard.assign(.existing(syncUuid: "acct-1"), to: "LOCAL-1")
        await wizard.finish(controller: controller)
        wizard.backFromConfirmation()
        wizard.assign(.addAsNew, to: "LOCAL-1")

        await wizard.finish(controller: controller)
        XCTAssertEqual(wizard.phase, .done)
        XCTAssertNotEqual(store.map["LOCAL-1"], "acct-1", "改成 Add as new ⇒ 铸新 uuid，本地值一个不动")
    }
}
