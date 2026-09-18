# M3-4a lane E — implementer deviation ledger

每个任务一节，只记**与 task brief / spec 不同**的地方，以及 brief 的「计划裁定」里要求
记档的那几条。相同的部分不记——差异表读起来才有意义。

## Task 2a

四类 store 的 `save -> Bool` 回传 + `AccountUserDefaults` 六个写入面的回滚（R-M3-4a-83）
+ `SpaceSyncMappingManager` 失败转抛错。

### brief 的「计划裁定」要求记档的

1. **六个写入面里只有四个自带 `queue.sync`。** `removeObject(forKey:)` 与
   `set(_:forCodableKey:)` 是转发面，**不各开一个 `queue.sync` 块**，快照与回滚发生在被
   转发的那个块里。spec §2.5 第 3 条「六个写入面在同一个 `queue.sync` 块内先
   `let previous = storage`」在转发形态下逐字成立，但字面读起来像是六个块都要自己写一遍。
   **措辞层面的偏离，语义无偏离**；理由是原子性——再套一层会让快照跨两次入队，中间可以
   插进另一个写者，回滚就会把别人的写一起抹掉。
2. **Profile 侧只接回传，不转抛错。** `ProfileSyncMappingStore.setGlobalUuid` 改成
   `-> Bool` 但**不带** `@discardableResult`，`ProfileKeyManager` 的两个写点写成
   `_ = mappingStore.setGlobalUuid(...)` 并各带一行注释。§13.3 只要求「必须单独接上回传」，
   §11 只把「失败转抛错」派给 `SpaceSyncMappingManager`；改成抛错会改掉
   `registerLocalProfile` / `adoptRemoteProfile` 的失败面与 `SyncKeyController` 的调用序。
3. **`removeMapping` / `removeAllMappings` 不加 `-> Bool`。** 回滚已经把它们保护住了
   （写盘失败 ⇒ 内存回到「映射还在」，内存与磁盘一致），两个消费者也都已经有收敛论证。

### 与 brief 不同的实现判断

4. **`PhiSyncEngine.writeState` 那一处「编译修正」没有做——brief 的前提不成立。**
   brief 说 `guard let value else { return defaults.removeObject(forKey: key) }` 会随
   `removeObject` 回 `Bool` 而变成编译断点。实际上 `PhiSyncEngine` 的 `defaults` 是
   **`UserDefaults`**（`PhiSyncEngine.swift` 的 `private let defaults: UserDefaults`），不是
   `AccountUserDefaults`：那一行调的是 `UserDefaults.removeObject(forKey:)`，返回值仍是
   `Void`，本任务一个字都没碰到它。按最小改动原则原样保留。
   （同族误判：brief 与 spec 把 `SentinelVersionGuard.swift:234-235` 与
   `PhiChromiumCoordinator.swift:188` 也算进「`AccountUserDefaults` 的非同步调用方」，这两
   处同样是纯 `UserDefaults`。结论不变——它们本来就不需要改。）
5. **CASE 2a.1 – 2a.6 的宿主文件 brief 没有指定**（Files 列表里没有任何
   `AccountUserDefaults` 的测试文件，仓库里也不存在一个）。新建
   `Tests/PhiBrowserTests/AccountUserDefaultsRollbackTests.swift`，一并进 `git add`。
   `Tests/PhiBrowserTests/` 下的文件不需要任何 `project.pbxproj` 改动。
6. **CASE 2a.7 – 2a.10 的宿主**：2a.7 → `PhiOwnedItemStateTests`；2a.8 →
   `PhiSpaceSyncStateTests`；2a.9 与 2a.10(a) → `PhiSyncEngineSpaceTests`；2a.10(b) →
   `PhiSyncEngineOwnedItemsTests`（脚手架在哪就写在哪，不复制一份 `private` 辅助）。
7. **B2-18 的变体 (b) 与 (c) 不在 `PhiSyncMarkerBoundaryTests.swift` 里。** (b) 与 CASE 2a.9
   是同一条用例（同一个接缝、同一份正向对照），写在 `PhiSyncEngineSpaceTests`；(c) 写在
   `SpaceSyncMappingManagerTests` 既有的「生产 store」一节里。新文件的头注释指名了这两处。
8. **CASE B2-10 的 `ownedStore.saveCalls == 1` 放宽成 `>= 1`。** `writeOwnedTable` 在一轮
   pull 里有不止一个调用点（落地段末尾一次，发布段 `publishOwnedKind` 至少一次——它在
   `work.isEmpty` 的早退分支里也写），所以一个精确的整数会把这条用例钉在与 R-M3-4a-83
   无关的引擎结构上。brief 想要的「没有内部重试」由 B2-4d 的 `setCalls == 1` 与 CASE 2a.7
   （文件 store 失败一次就回传、不重试）各自钉住；精确计数是 Task 2b 的事。
9. **CASE 2a.10 的「两个写口都回 `true`」在本任务不可观测**：两处返回值此刻在引擎里全部
   被 `@discardableResult` 丢弃。能钉住的是那条判据的前半句——退休 / 无 store 时 `save`
   **一次都没有被调用**，所以它不可能是一次失败。Bool 本身留给 Task 2b。
10. **`failNextSave` / `failNextSet` 实现成「粘滞」而不是一次性**：置真之后每一次调用都
    失败，直到用例自己置回 false。brief 的全部 case spec 都显式写了「放行（置 false）」，
    一次性语义会让同一轮里的第二个写入点悄悄成功。
11. **既有测试代码的四处小改动**（都是签名变化或新用例的直接后果，不是行为改动）：
    - `SpaceSyncMappingManagerTests` 里两处既有的 `store.setSyncUuid(...)` 包成
      `XCTAssertTrue(...)`——`setSyncUuid` 去掉 `@discardableResult` 之后它们会产生
      「未使用的结果」警告。
    - `PhiOwnedItemStateTests` / `PhiSpaceSyncStateTests` / `SpaceSyncMappingManagerTests`
      的 `tearDown` 各补一句「**先恢复目录权限再删**」——只读目录删不掉，残留会累积。
    - `PhiSyncEngineSpaceTests.tearDown` 补一句把 `PhiSpaceSyncState.shared.localSpaceIdLookup`
      还原成 `nil`（`shared` 是进程级单例）。
    - `PhiSpaceSyncStateTests` 多一个返回 `Account` 的 store 构造器；原来那个签名一字不改，
      既有三条用例不受影响。

### 验证口径

12. **本任务的验证是 compile-only**（`xcodebuild build-for-testing`，全局约束）。
    用 `chmod 0o500` 注入落盘失败的那七条用例（2a.1 – 2a.8、B2-18 主探针与变体 (a)/(c)）
    **没有在运行时跑过**。注入手法本身是确定的（测试进程不是 root，`.atomic` 写要在同目录
    建临时文件），但「断言的那个值」没有被实测。

## Task 3

`PhiSyncMarkerStore` / `marker.json`（§2.10 / R-M3-4a-18）+ 一次性迁移 + `stateKeys` 收缩
+ 引擎 init 参数 `markerStore` + 自撤销与 `resetSyncState()` 多删一个文件。

### brief 的「计划裁定」要求记档的

1. **`PhiSyncEngine.legacyMarkerStateKeys`（计划裁定 3，spec 未写）。** `stateKeys` 收缩成
   五项，但账户切换（`resetPhiSyncCursorIfAccountChanged`）与自撤销第 5 步的擦除面改成
   `stateKeys + legacyMarkerStateKeys`，`hadCursor` 的判据同样认它们；迁移调用点排在那次擦除
   **之后**。理由：一台迁移写失败的机器换账户之后，否则会把上一个账户的 `phi.sync.marker`
   迁进新账户的 `marker.json`。`DefaultsBackedPhiSyncMarkerStore.deleteFile()` 也是把这两个
   键去掉，所以回落实现上的 `resetSyncState()` 与收缩之前可观察行为一致。
2. **两个 spec §11 Task 3 行没列的文件各改一行注释（计划裁定 6）**：
   `PhiOwnedItemState.swift`（「marker 住在 `UserDefaults.standard`」→ 同目录的 `marker.json`）
   与 `SyncableSettings.swift`（`valueSignature` 去重的例子从 `phi.sync.marker` 换成
   `phi.sync.version` / `phi.sync.entityId`；去重本身照旧必要）。`PhiChromiumCoordinator`
   的 debounce 订阅注释同款改法。

### 与 brief 不同的实现判断

3. **`PhiSyncMarkerBoundaryTests.swift` 不是新建的**——Task 2a 已经建了它（B2-4d / B2-10 /
   B2-18）。本任务**追加** B2-11a…d、3.1、3.3、3.4、3.5，头注释补一段 Task 3 的清单。
4. **`SelfRevokeTests.makeController` 多了两个参数**，不是一个：`ownedItemStores`（默认 `[]`）
   与 `markerStore`（默认 nil）。CASE 3.2 的 spec 本身要传两张非空游标表，而原来的
   `makeController` 没有 `ownedItemStores` 这个口。既有三条用例一字不改。
5. **Step 1 的「红」没有单独编译一次。** 本机一次 `build-for-testing` 是多分钟级；红的结论
   由「类型不存在」保证（`cannot find type 'PhiSyncMarkerFile'`），不需要实测。最终只跑了
   一次绿的编译（两次：第一次全量、第二次增量取退出码 0）。
6. **`MemoryMarkerStore.saves` 记每一次调用，失败的那一次也记**（brief 只给了字段名）。与
   `MemoryOwnedItemStore.saveCalls` 同义：`saves.count` 就是调用计数，`failSaveOnCallNumber`
   数的正是它；「一次写都没有」断言 `saves.isEmpty`，两者不冲突。
7. **迁移先看两个旧键、再 `store.load()`**（brief 没定次序）：稳态（键早已清掉）零磁盘读。
   结论集合与 brief 逐字相同。
8. **用例比 case spec 多几条断言**，都是同一条判据的直接后果：
   - CASE 3.3 多断言 `getUpdatesCalls[0].marker == "4"`（读的是注入的文件）与
     `saves.contains(PhiSyncMarkerFile())`（`marker == nil` 是一次真正的写，钉的正是「防的是
     什么」的 ②）。
   - CASE 3.5B 多一个第二阶段：只剩 legacy 键时 `hadCursor` 也为真。
   - CASE 3.2 多断言第 5 步把两个 legacy 键也擦掉（那一行改动的唯一探针）。
   - CASE 3.1 拆出一条 `testAZeroLengthMarkerIsNotTheSameAsNoMarkerOnDisk`：store 层
     `Data()` 与 nil 分得开（brief「防的是什么」里的后半句）。
9. **`persistMarkerState` 对「没变化」早退**（brief 逐字给的形状）带来一个与 M3-4a 之前不同
   的可观察细节：回落实现上，birthday 逐页不变时两个旧键不再每页重写一次。没有任何既有断言
   看这一点（只有 `didChangeNotification` 能看到），生产上反而是少一次无意义的落盘。
10. **既有 marker 断言清单重 grep 过一遍**（Task 2a 之后行号已漂）：seed 两个键的十处里九处
    在建引擎**之前**，唯一在之后的一处（`PhiSyncEngineSpaceTests` 的预览用例）只断言键未被
    改动，而预览路径根本不读 `storedMarker`——镜像设计对它无影响。

### 验证口径

11. **compile-only**。新增的十三条用例（B2-11a…d、3.1 ×2、3.2、3.3、3.4、3.5A、3.5B）**没有
    在运行时跑过**；`FilePhiSyncMarkerStore` 的 `load` 不写回、`save` 的 `.atomic` 落盘、
    `Gate` 驱动的 3.5A，都是按既有同形用例（`FileOwnedItemStateStore` / CASE 2a.7、
    `PhiSyncEngineTests` 的 shutdown 用例）推断为确定的。

## Task 2b

B-2 逐页边界：`markerSuppression` / 轮级 `RemoteView` / guard 2 前移 / `ownedMapsThisRound`
每页失效 / `cursorSaveFailed` 四个置位点 / 结局行 / 两个 debug abort 开关 / 发布闸合取 /
per-kind 报损重放两步确认。

### brief 的「计划裁定」要求记档的

1. **裁定 3（R-M3-4a-89）**：guard 2 前移到 `recordsGatedMarkerMoves` 之后、`do {` 之前，判据只读
   `spaceTableAtEntry`；`c549c4c5` `:1690` 闩 / `:1691` marker 的相对次序**被颠倒**，两步之间加确认
   （① `persistStoredMarker(nil)` ② `mutateSpaceTable { 三个标志 }` ③ 才动内存）。R-M3-4a-47 的
   「闩与 marker 在同一个闭包」措辞按 R-89 改写；R-47 其余部分照旧。`hadRecords` 的维护跟着前移，
   但写成**独立的一次** `mutateSpaceTable`（第 ② 步的闭包只在 `cursors.isEmpty` 时才跑，放进去
   永远不会置真）。
2. **裁定 3b（R-M3-4a-103）**：`loadOwnedTable` 报损支的「闩先写、marker 后写」被颠倒，两步之间加
   确认，两个失败支回 `(table, false)` 并把**引擎属性** `roundOutcome` 收口成 `.cursorSaveFailed`；
   `AppLogWarn` 挪到第 ② 步成功之后；函数头注释「不需要第二个 `publishBlocked` 标志」的理由改成
   「发布闸在 `cursorSaveFailed` 那一轮已经关掉整个发布段」。探针留给 Task 6 的 CASE U-18。
3. **裁定 5**：置位点由三个变成**四个**——`applySpaces` create 支 `mapSpace` 的 catch 里错误恰为
   `SpaceSyncMappingError.persistFailed` 时计数，其余映射错误不计；Profile 映射（`refreshAccountProfiles`）
   按 §13.2 字面该计而**不计**，理由是它跑在页循环之前、不描述任何一页，失败仍由
   `spaceCounters.profileRefresh = "failed"` 报告。
4. **裁定 6**：§2.8 写的是 `serialized(_:)`，实际发射点在 `run(_:)` 的 `logSpaceRound()` 之前
   （`logRoundOutcome()`），`.preview` 不发；一轮多次 pull 时结局取最后一次，`pages` /
   `cursorSaveFailures` 全轮累加。优先级 2（`cursorSaveFailures > 0 ⇒ .cursorSaveFailed`）对
   `.notMyBirthday` 之外的**全部**结局生效（含 `.pageBudgetExhausted` / `.unusableSettings`），不只
   brief 点名的三个——任一游标写失败的一轮都该以它命名。
5. **裁定 8**：编译条件是 `#if DEBUG || PHI_SYNC_DEBUG_SWITCHES`，没有 `ADHOC`，`project.pbxproj`
   零改动；本仓库里只在 `DEBUG` 下编译。**签名偏离**：`abortIfRequested(_:)` 收的是
   `DebugAbortPoint`（`.afterApply` / `.betweenKinds`）而不是 `String` 键——两个键常量与函数体同在
   `#if` 段里（release 零字符串常量、零 `UserDefaults` 读），而调用点仍然不需要 `#if`；brief 的
   「键常量同段」与「调用点不需要 `#if`」用 `String` 参数无法同时成立。键名逐字不变。
6. **裁定 10**：catch 里 `if loadSpaceTable().drainInProgress { storedMarker = nil }` **保留**，注释
   按 §2.4 说明 4 改写；B2-8 拆成 B2-8(a)（增量轮，marker 停在第 3 页）与 B2-8(b)（drain 轮，
   整条重放）。
7. **裁定 11**：既有断言**一条不改**。改了注释与断言**消息**：`PhiSyncEngineSpaceTests.
   testADrainInterruptedMidWayReplaysFromScratchInsteadOfCompletingOverTheGap` 的文档注释与那条
   `XCTAssertNil` 的 message（「instead of counting page 1 as delivered」在逐页边界下不再成立）；
   引擎侧 guard 1 上方「shared marker is written page by page」段、`applySpaces` 前的次序注释
   （guard 2 不再需要那个次序理由）、门关记账的「persisted by the page that observed it」补
   「before that page's marker」、`mutateSpaceTable` 的 Durability 段补「and before that page's marker」。
8. **裁定 12（R-M3-4a-88 / 92）**：第三个合取项折进 `canPublishThisRound` 的**唯一一次赋值**，
   `if thenPush, canPublishThisRound` 与五个发布入口、`push(retryOnConflict:)` 与三条冲突重试的
   `guard await pull(…)` 一行不改。**偏离**：第三项写成 `cursorSaveFailures == 0`（计数）而不是
   brief Step 6 的 `roundOutcome != .cursorSaveFailed`——guard 1 / `hadRecords` / NOT_MY_BIRTHDAY
   复位那几次写失败时 `roundOutcome` 可能还不是 `.cursorSaveFailed`，而「本地这一轮落盘全成了吗」
   问的正是计数；伪码里的局部 `cursorSaveFailed` 与它同义。轮末 drain 收尾的写失败也收口成
   `.cursorSaveFailed`（CASE B2-4b）。

### 与 brief 不同的实现判断

9. **四个测试接缝读的是结局行发射时的快照**（`LoggedRound`），不是活的 `roundPages` /
   `roundMarkerAdvanced` / `cursorSaveFailures`：一轮 `page_budget_exhausted` 会把跟进轮排进队列，
   跟进轮的 `run(_:)` 一进门就清零活计数，断言那一刻读到的会是下一轮的残值。
10. **`FakePhiSyncClient.gateGetUpdatesFromCall`**（brief 之外的第二个假件旋钮）：让 `getUpdatesGate`
    只从第 N 次调用起生效，用来把引擎自己排进队列、不可 await 的跟进轮停在它的第一次请求里
    （B2-1c(c) / B2-8b / B2-9 另一半方向）；放行后再排一轮 `pullOnce()` 等它跑完。既有两种
    gate 用法语义不变（nil = 每次都生效）。
11. **B2-4d 的「本机 Space 行仍是 1 条」在 HEAD 上不断言**：今天的 create 支先建行、后写映射，
    `persistFailed` 留下一条无映射的行、重投再建一条——那正是 Task 3b 的映射先行（R-M3-4a-87）
    要消掉的形状，3b 的 CASE B2-4d-x 断言它。本任务的 B2-4d 断言第四个置位点、marker 不推、停放、
    第二轮映射写下并解析得出。
12. **B2-2b 住在 `PinnedTabScopeTests`**（真 `LocalStore` 的脚手架在那里），走生产的
    `AccountPhiPinnedTabAccess.apply(_:)` → `applyPinSyncBatchThrowing` 批次路径；该文件进 `git add`。
13. **B2-7c 不断言 `counters.tombstones == 0` 与 `applied == 1`**：`tombstones` 数的是**入站**远端
    tombstone（`applyOwnedKind` 头三行），一条入站 tombstone 的轮次它就是 1；「零出站 tombstone」
    用 `client.commits` 里零条 `deleted` 与 `pushed == 0` 钉。
14. **B2-13 的 fixture 预置 `drainInProgress = true`**（与 `hasDrainedFullReplay = true` 并存）：
    入口 marker 为 nil 时 guard 1 否则会把 `hasDrainedFullReplay` 置假，归属 kind 的发布段在
    guard ① 就返回，brief 要的 `hadRecordsSeen.count == 2` 观察不到。
15. **B2-5b 的「重投」用第二台引擎**：引擎持有 marker 的内存镜像，直接改 `markerStore.file` 对
    第一台不可见；第二台在回退后的文件上建，等价于重启后重投。
16. **B2-14 (d)** 按「第一台的第 2 次写从未发生（页 1 被抑制）、第二台在放行后的同一组 store 上
    从头重放并正常收尾」写；brief 那一句的字面读法（第二台带着 `failSaveOnCallNumber = 2`）会让
    第二台页 1 的 marker 写失败，与它自己的期望冲突。
17. **`pull` 的 catch 不再调 `flushSpaceObservations` / `flushOwnedObservations` /
    `parkUndeliveredOwnedEntities`**：逐页落地之后两个收集篮是页内局部量，抛错只可能发生在
    `getUpdates`，那一页根本没到；`parkUndeliveredOwnedEntities` 只剩 `applyOwnedKind` 的
    `ownedReadFailed` 那个调用点，头注释加一段说明。
18. 新增私有辅助 `persistStoredMarker(_:) -> Bool` 与 `normalizedMarker(_:)`：`storedMarker` setter
    经它写穿，页末 / guard 2 / 报损重放读它的 Bool。
19. **控制者交办的两条 2a 尾项**：`PhiSpaceSyncState.deliver` 无引擎路径 `directStore.save` 失败
    时不再 `refreshCaches`；`PhiSyncEngineSpaceTests` 的 `setUp` 捕获、`tearDown` 恢复
    `PhiSpaceSyncState.shared.localSpaceIdLookup`。2a 已知的「`ownedTables[label] = table` 先于
    save guard」按交办**不改**，写口注释说明理由。
20. `cursorSaveFailures` 在 `pull` 之外的写口失败（`.spaceGate` 轮的 `applySpaceGate`、reset 的
    表写）同样计数并在**那一轮**的结局行上报告——它是引擎属性、按 `run(_:)` 清零。

### 验证口径

21. **compile-only**（`xcodebuild build-for-testing`）。本任务新增的 31 条用例（B2-1 … B2-18 的引擎
    半边、B2-2b）**没有在运行时跑过**；跟进轮 / 冲突重试的写序号（B2-1e 的第 4 次、B2-4b 的
    `saveCalls + 2`）按代码推导，未实测。

### Fix round 1（review 的一条 Important）

22. **R-M3-4a-103 的控制者裁定**：报损重放的第 ① / ② 步任一写不成 ⇒ 那条 kind **本轮不发布**、
    报损检查下一轮再触发。`loadOwnedTable` 的两个 `(table, false)` 失败支不改、函数内不加闸；改在
    `publishOwnedKind` 的 `guard !loaded.lost` 之后加 `guard cursorSaveFailures == 0 else { return }`。
    理由：那两支回到的 `publishOwnedKind` 已经过了轮首的 `canPublishThisRound`，不拦的话发布段会对着
    **空的**游标表跑快照 → 差分 → commit，并用 `writeOwnedTable` 重建文件 ⇒ 下一轮不再报损、per-kind
    闩永不置位、整类型重放永久丢失——正是两步次序要防的那一格。探针 CASE 2b-L1
    （`PhiSyncMarkerBoundaryTests.testAFailedLossReplayArmDoesNotPublishAgainstTheLostTableNorRecreateItsFile`，
    设置半边靠预置空 `storedLastEntity` 早退、Space 半边靠 guard 3 的 `unreadableTagHashes` 跳过，
    于是「零 `commit` 调用」只说书签那一半）；Task 6 的 U-18 两条 R-103 变体为 urlrules 再钉。

## Task 3b

`applySpaces` create 支的映射先行（R-M3-4a-87）+ 死映射自愈的重投证明（CASE B2-17 / B2-17a /
B2-17neg / B2-4d-x）。

### brief 的「计划裁定」要求记档的

1. **既有用例里唯一一条断言方向被 R-87 翻转的**：
   `PhiSyncEngineSpaceTests.testAFailedCreateWritesNeitherAMappingNorABaseline` → 改名
   `testAFailedCreateLeavesADanglingMappingAndNoRowForTheNextRoundToHeal`，断言从
   「`spaceMappings.isEmpty`」翻成「映射恰一条（value 为 `sync-new`）、行零条、`reconciled` nil、
   `pendingApply` 非 nil」；用例 1 的头注释「落地成功之后才写映射」改成「先写映射、再建行」。
   其余 create 路径用例逐条核过不变（brief Step 4 列的那几条；
   `testAFailedLandingWritesNoBaselineAndParksTheEntity` 用 `errorOnNextWrite` 让 `create` 抛错，
   两轮断言在新次序下仍成立——第 2 轮由 A0 自愈接管）；全仓 `.mapSpace` 这个 `Call` case 零既有
   断言，`PhiSpaceLocalAccessTests:171` 的 exact-array 不受影响（两个新 knob 默认 nil）。
2. **裁定 7 的控制者裁定**：`mapSpace` 的 `persistFailed` 是第四个 `cursorSaveFailed` 置位点
   （§2.5 第 4 条待改成**四个**）。Task 2b 落地；本任务把那个 catch 连同新块搬到 `land` 之前，
   「`persistFailed` ⇒ 停放 + 计数、其余 `SpaceSyncMappingError` 只停放」的语义逐字保留，
   CASE B2-4d-x 验它。
3. **B2-17neg 不写成代码**：B2-17 上方的注释块 + 本条。旧次序（先建行、后写映射）下 B2-17 会红的
   三条断言：「行数 1」、「value 为 `sync-new` 的映射恰一条」、`.dropSpaceMapping` 的 `contains`。
4. **裁定 6 的第三条路径（自愈里 `dropSpaceMapping` 写失败 ⇒ 随后 `mapSpace` 撞
   `syncUuidAlreadyClaimed` ⇒ 停放 ⇒ 再下一轮）只是论证**，记在 B2-17 的注释里；假件的
   `dropSpaceMapping` 不可能失败。

### 与 brief 不同的实现判断

5. **新块插在 `// A2 + A3` 注释之前，不是 `merged` 求值的 `}` 之后**：`c9ab5806` 之后两者之间多了
   一段「按 `merged.profileUuid` 重解析 `profileId`」的块（`c549c4c5` 里没有）。新块只用
   `localSpaceId` / `isDefault` / `item` / `cursor` / `table` / `tag`，放在紧挨 `land` 之前更贴近
   「映射写在行之前那一刻」的意图，语义无差别。
6. **新块的 catch 带 Task 2b 的计数行**：brief 裁定 1 的逐字代码没有 `cursorSaveFailures += 1`
   （它写于 Task 2b 之前）；按任务交办与裁定 7 保留
   `if (error as? SpaceSyncMappingError) == .persistFailed { cursorSaveFailures += 1 }`。
7. **B2-17a 的「走 update 支」不用 `.update(id)` 断言**：`SyncableSpaces.land` 的 update 支只在
   名字 / 颜色 / 图标 / 创建时间有差异时才调 `access.update`，而重投的是同一页、行是上一轮照它建的，
   四个字段零差异 ⇒ `.update` **结构上不会出现**。改用第 2 轮调用切片里的 `.themeState(newId)`
   （update 支对非默认 Space 无条件调 `applyThemeState`）+ `.create` 总数仍 1 + `.dropSpaceMapping`
   不出现，钉「走了 update 支、没有再建行、没有自愈」。
8. **三条新用例的 fixture 用 `PhiSyncMarkerBoundaryTests` 自己的脚手架**（`makeSpaceAccess([:])` +
   `spaceCreateEntity` + `pagesByMarker` + `makeOwnedEngine` + `drainedSpaceStore` +
   `markerStore(marker:)`），不是 brief 写的 `PhiSyncEngineSpaceTests` 那一组（那些是 `private`，
   且 brief 自己要求追加进本文件）。profile uuid 因此是 `pu-1` 而不是 `uuid-a`，Space 名是 `S`
   而不是 `Reading`；两者都不进任何断言。
9. **B2-17 多钉了几条 brief 没写的**：第 1 轮 `markerStore.file.marker == "3"`（`land` 抛错不是
   持久化失败 ⇒ marker 照推，裁定 7 第三条的另一半）；第 2 轮 `getUpdatesCalls.last?.marker == "3"`
   （假 client 本轮零新页，重投确实来自停放）与 `rowId != newId`（自愈之后重铸，不复用悬空 id）。
   B2-17a / B2-4d-x 同理钉 `getUpdatesCalls.last?.marker == "0"`（同一 marker 重投同一页）。
10. **`spaceCommits` 在本文件按 `name == PhiSyncEntity.spaceEntityName` 过滤**
    （`PhiSyncEngineSpaceTests` 那份是 `!= settingsClientTagHash`，且 `private`）。

### 验证口径

11. **compile-only**（`xcodebuild build-for-testing`）。三条新用例与翻转的那条没有在运行时跑过；
    两轮的走向（A0 自愈触发、update 支的 `applyThemeState`、去重后的 `.create` 计数）按代码推导。

## Task 6

游标表 / 两个标志 / `OwnedKindFlags.urlRules` / 注册项 `.urlRules` 全部成员 / 协调器接线与订阅 /
`OwnedRoundCounters` 五字段 + `reportsRuleCounters` + `landsEmptyBatch` + 第二发射段 / B2 用例的
规则半边 / U-18 两条 R-103 变体 / CASE U-11。汇合段第一条，基点 `154b3f39`。

### brief 的「计划裁定」要求记档的

1. **协议第七个成员 `refreshRoutingTableAfterLanding()` 归本任务**（spec §5.6 的协议清单里没有它，
   Task 8 的 Produces 因此多一个成员）：`PhiURLRuleLocalAccess` + `AccountPhiURLRuleAccess`
   （一句 `SpaceManager.shared.reloadURLRulesFromStore()`）+ `FakeURLRuleAccess.Call.refreshRoutingTable`。
   引擎不直调 `SpaceManager`（`PhiSyncEngine.swift` 对它仍只有注释引用与 `URLRuleKind` 经由的
   两个 static）。Task 8 评审点名的那条运行期未验证前提（主上下文合并可见性紧跟在一次已 await 的
   后台保存之后）仍然成立：本任务的刷新调用在 `access.apply` 返回**之后**，经 access 成员进
   `reloadURLRulesFromStore()`，前提本身没有在本任务里得到运行期验证（compile-only）。
2. **`OwnedPlanOutput.normalized` 与 `OwnedLandingOutcome.ownerMoved`**：spec §11 没点名的两个字段。
   `owner_moved` 由落地数批次里真的留下来的 `.move`（`URLRuleApplyBatch.init` 降级之后），不在
   plan 里按 step 数；`normalized` 由 plan 闭包填。其余四个计数（`collapsed` / `transferred` /
   `yieldNoPartner` 与 `adopted` 的规则半边）本任务恒 0，发射段照印。
3. **spec §6.5 的 `Round` case 行号 `:684` 实为 `:687`（`c549c4c5`），入口名是
   `handleLocalOwnedChange(label:)` 不是 `(kind:)`**；本任务的协调器订阅与用例都按后者。
4. **U-27 ~ U-31 五个新 CASE 编号**（本计划新增，Task 12 写回 spec §12.1），全部落在
   `URLRuleKindTests.swift` 的 Task 6 段；U-11 由控制者补派到本任务，也在那里。
5. **`server = remote` 记归一化之前的字节**（计划裁定五）——`urlRulePlan` 在 `normalizeArrivals` 之前
   写 `out.serverBytes`。
6. **`tombstones` 闭包保持最小形**（计划裁定四）：一次 `allURLRulesIncludingDeleted()` + 一次
   `SyncableOwnedItems.tombstones(... pendingClaims: [])`；`explicitDeletions`（Task 9）与
   `deferredDeletions`（8b-3）的钩点是那个 `let rows = …` 绑定，注释里点名。
7. **`landsEmptyBatch`**（R-M3-4a-99）：`OwnedKindRegistration` 的 `let` 成员，`.urlRules` 传 `true`、
   `.bookmarks` / `.pins` 显式传 `false`；`applyOwnedKind` 那道空批次 guard 只加了
   `|| registration.landsEmptyBatch`，早退支的 `if replayedAfterDelete > 0 { writeOwnedTable }` 原样。
   用例在 8b-2 的 CASE M-35。**副作用**：规则每页都会走到 `applyOwnedKind` 末尾的
   `writeOwnedTable`，即每一页多一次 `urlrules-cursors.json` 的原子写（表没变也写）——书签与 pin
   的早退逐字不变，不受影响。

### 与 brief 不同的实现判断

8. **`localIdentities` 闭包读 `state.rows`，不再 fetch 第二次。** brief 写的是
   `try? access.allURLRulesIncludingDeleted()` 回退到 `state.rows`。`beginOwnedRound` 里它紧跟在
   `beginRound()` 之后、且只在 `beginRound` 没抛时才被调（同一个 `do` 块），`state.rows` 就是
   「本轮已经读到的那些身份」，含软删行；再读一次只多一次主上下文 fetch。
9. **`reloadAfterPage` 在生产实现上确实是一次 fetch。** brief 说「Task 8 的 `apply` 已经重建过 access
   自己那份页内缓存，所以不是第二次 fetch」——但协议没有 `cachedRows()` 这样的读口
   （pin 有 `cachedPins()`），`allURLRulesIncludingDeleted()` 在 `AccountPhiURLRuleAccess` 上必经
   `rebuildCache()`。每落地一页多一次 fetch；`FakeURLRuleAccess` 上零成本。加一个不 fetch 的读口
   属于 Task 8 的协议面，本任务不动。
10. **落地后复核排在 `reloadAfterPage` 之前。** 生产 `rebuildCache()` 失败时先 `invalidateCache()`
    再抛，之后 `isKnownLocalURLRule` 会 `assertionFailure`；`apply` 成功返回时缓存刚重建过，复核
    放在它后面、重读前面，重读失败也不会把已落地的行读成「不在」（`pageReloadFailed` 只影响下一页
    的投影）。同理 `siblings(inSpaceId:)` 在 `pageReloadFailed` 时退回 `state.live` 按 `spaceId` 分组。
11. **翻译表对「有行的 `.create`」发 `.update` / `.move`，不发 `.create`**（§4.5「先按身份找本机行，
    找不到才 create」，与 `landPins` 同一条）：定义域**含软删行**（R-M3-4a-42(a)），一次重放
    （游标丢失、marker 回退）或一次救回软删行都是 update；桶变了就是 `.move`，两者一起交给
    `URLRuleApplyBatch.init` 合并 / 降级。被触及的桶里其余兄弟各发一条 `.reorder`（只发下标真的
    变了的那些），让 §8.3 的投影而不是批次入口的 `(sortOrder, id)` 收尾决定次序。
12. **`logOwnedRounds` 的拼串拆成 `static func ownedRoundLogLine(_:counters:)`**（actor 的 static
    成员不隔离，纯函数）：brief 的 U-27 要「按 `logOwnedRounds` 的拼串规则核对三条行文本」，而
    `AppLogInfo` 没有测试面、全局约束又禁止新的驱动入口；一个纯格式化函数不是驱动入口。书签与
    pin 的行**逐字节不变**（U-27 同时钉了 `bookmarks` / `pins` 两条行的形状）。
13. **U-18 (f) 的第二轮不是「第 ① 步幂等零写 + 第 ② 步这次写成」。** 盘上 marker 已经是 nil，
    guard 1（R-M3-4a-89，`pull` 入口）在**轮首**就武装 drain 并从头重放；重放页里的 `r1` 按身份
    落地、游标在发布段那次 `loadOwnedTable(armsReplayOnLoss: true)` 之前已经重建 ⇒ 报损不再命中、
    闩不需要再置位。brief 写的那一格只在「重放页不带任何规则」时可观测，于是拆成两条：
    `testAFailedLatchWriteAfterAClearedMarkerStillEndsInAFullReplay`（(a) 形状，钉「可重来的落盘
    失败没有变成永久失效」）与 `testAFailedLatchWriteIsRetriedWithAnIdempotentMarkerClear`
    （空账户，钉 `markerStore.saves` 不增、闩置位、drain 武装）。(f) 的 `failSaveOnCallNumber`
    动态取 `saveCalls + 2`：页 1 那次无条件的 Space 表写是第 1 次，第 ② 步是第 2 次。
14. **U-18 (e) 的 `MemorySpaceStore.saveCalls 不增` 写成 `≤ 1`**：页循环每页无条件 `writeSpaceTable`
    一次，那个 +1 与第 ② 步无关；断言的是「页写之外没有第二次」+ 闩 / drain 标志逐字不变。
15. **U-18 (a) ~ (d) 的 marker 用十进制 `"5"`、重放页水位 `"3"`**（brief 写 `"M5"`）：
    `FakePhiSyncClient.pagesByMarker` 按十进制水位分页，非数字 marker 读成 0；水位 3 ≤ 5 让
    「从 5 起拉不到、从 nil 重放才拉到」成立，正是 (a) 的「重放页里带 r1」。(c) 用不带 `syncId` 的
    行、(d) 带——brief 说四段共用一份行，这里让 (c)/(d) 各自表达一半判据。
16. **U-30 的游标多带 `deletedAtMs`**（照 CASE 6.18 / 6.21 的书签形状）：否则 reset 之后同一轮的
    发布段会为它补键（有本机行）或差分为它发 tombstone（无本机行、`entityId == ""` ⇒ §9.1 第二道
    闸就地写 `deletedAtMs` 并清 `reconciled`），断言读到的就不再是 reset 本身。
17. **U-28 的次序探针是文件末尾的 `RecordingSpaceStore`**（记三个 `…HadRecords` 第一次为真的次序），
    不是往三个假件里塞共享数组——假件没有那个钩子，全局约束又要求改既有假件显式声明。
18. **U-29 的 sink 记 label、不调引擎**：形状逐字是协调器那一行（裸 sink、label 从注册项带来），
    引擎调用本身没有可数的测试面；真 `LocalStore` 在临时目录上，`tearDown` 里删。
19. **U-11 的 Space 段与设置段用 2b-L1 的办法静默**（三个已映射 Space 进 `unreadableTagHashes`、
    预置空 `storedLastEntity`），两台引擎各自的 defaults suite 与 store；`v+1` 不写死，读
    `client.stored[hash].version`。
20. **`PhiSyncMarkerBoundaryTests` 只补了 brief 点名的三格**（B2-3 新用例、B2-7 / B2-7b 经五种 kind
    的共享 fixture）。Task 2b 留下的其余 `— Task 6` 占位（B2-1c (d)、B2-6b、B2-13、B2-15、B2-16 的
    规则版）**原样未动**，交 Task 12 收口决定。

### 验证口径

21. **compile-only**（`xcodebuild build-for-testing … -quiet`，exit 0，零 error，触碰的文件零
    warning）。十九条新用例与三处扩写没有在运行时跑过；每条的走向（`.create` 步落成 `.update`、
    冲突后的限定重发、guard 1 的轮首重放、`hadRecordsSeen == [true, true]` 等）按代码推导。

### Fix round 1（review 的一条 Important，tests only）

22. **U-18 (e) / (f) / (f-empty) 没有静默设置段与 Space 段。** `makeSpaceAccess()` 映了三个没有游标的
    Space，`hasDrainedFullReplay == true` 时 `pushSpaces` 在 `pushOwnedItems` 之前把三条 create 发
    出去并写一次 Space 表：(e) 的「零 commit」与「Space 表写次数」两条断言、(f)/(f-empty) 的
    `failSaveOnCallNumber = saveCalls + 2` 旋钮都被它打偏（旋钮打在 Space 段的表写上，步骤 ② 反而
    成功，断言在引擎正确时变红）。修法：`makeLossFixture` 内调本文件自己的
    `silenceOtherSections`（与 U-16 / U-11 同一个 helper），函数改成 `throws`、七个调用点加 `try`。
23. **序号重新推导**：静默之后 `pushSpaces` 仍然写**一次**表（guard 3 在 `spaceCommitEntries` 里
    `continue` 掉三条 ⇒ `work` 为空 ⇒ `guard !work.isEmpty else { writeSpaceTable(table); return }`
    那一支），`push` 的次序是 settings → spaces → owned。于是 Space 表写：页 1 无条件表写 #1、
    `pushSpaces` 写回 #2、报损重放第 ② 步 #3。(f)/(f-empty) 的旋钮改成 `saveCalls + 3`；(e) 的
    Space 表断言改成精确 `== 2`（没有第三次 = 步骤 ② 没跑）。(a)–(d) 的断言逐条复核，静默不改变
    它们的走向（`hadRecordsSeen == [true, true]`、零 rule commit、marker / drain 标志同前）。
24. **顺手清掉同文件唯一的编译 warning**：U-29 的 `RunLoop.main.run(until:)` 直接在 async 上下文里
    调（Swift 6 下是 error），改经同步 helper `waitPastDebounceWindow(_:)`（照
    `LocalStoreURLRuleThrowingTests` 的形状）。
25. 验证仍是 compile-only：`xcodebuild build-for-testing … -quiet` exit 0，零 error，触碰文件零
    warning。覆盖的用例：`testAFailedMarkerClearLeavesTheLossUnarmedAndRetriggersNextRound`、
    `testAFailedLatchWriteAfterAClearedMarkerStillEndsInAFullReplay`、
    `testAFailedLatchWriteIsRetriedWithAnIdempotentMarkerClear`（以及经同一 fixture 的 (a)–(d) 四条）。

## Task 9

生命周期汇合段：`SyncableOwnedItems.tombstones` 的第七个入参 `explicitDeletions`（R-M3-4a-78）、`.urlRules` 的
`tombstones` 闭包（一次读、两个集合）、`applyOwnedRetentionCascade` 的停放豁免（R-M3-4a-27）、软删行的两条
清理出路（`hardDeleteAfterTombstone` / `purgeSoftDeletedRows` 两个 `= nil` 注册项成员 + 协议两成员 + 假件 +
生产实现 + `purgeExpiredSoftDeletedOwnedRows` 第四步）、`SyncKeyController.ownedItemStores` 第三个元素、
`resetForNewStoreBirthday` 核对。

### brief 的「计划裁定」要求记档的

1. **`explicitDeletions` 只跳两道归属门**：模块里三条判据、`pendingClaims` 排除、整段游标记账逐字照旧，两道门
   包进 `if !explicitDeletions.contains(identity) { … }`。入参排在 `pendingClaims` 之后、带默认空集；书签 / pin 的
   两个调用点与 `SyncableOwnedItemsTests` 的八处调用一个字没改。循环最前面留了一句 `//` 指路：8b-3 的
   `deferredDeletions` 的 `continue` 排在判据 1 之前。
2. **三条规则侧例外的落点**：闭包构造 `locals` 时不做任何归属过滤，靠 `identity(of local:) == syncId` 让 hidden /
   purged / agent / 过期 incognito 目标的活行进 `liveIdentities`（判据 3）；两道门是第二道防线。U-12 两个变体钉住。
3. **停放豁免不刷 `ownerUuid`**：`if table.cursors[identity]?.pendingApply != nil { parked += 1; continue }` 排在
   `guard live.claimed.contains` 之前；`parked > 0` 时一条 info（kind + 条数）。
4. **出路 1 排在 `writeOwnedTable` 之后、冲突重试之前**；`appliedTombstones` 在 `applyOwnedCommitOutcome` 循环里与
   `appliedMinted` 并列收集（`if case .applied = outcome, item.entry.deleted`）。硬删抛错只记 warn（kind），不回滚。
5. **出路 2 不碰 `LocalStore+SpaceURLRule.swift`**：`AccountPhiURLRuleAccess.purgeSoftDeletedURLRules(olderThan:)` =
   一次 `allURLRulesIncludingDeleted()` 筛 `deletedDate < cutoff && syncId != nil` + 逐条 `hardDeleteURLRuleThrowing`
   （一行一事务，特性不是妥协）。判据是行上的 `deletedDate`；`syncId == nil` 的软删行按 R-M3-4a-23 不可达，accepted。
6. **两个注册项成员 `var … = nil`**：合成 memberwise init 给默认实参，`.bookmarks` / `.pins` 工厂零改动。
7. **自撤销**：`SyncKeyController.swift` 的 `for store in ownedItemStores` 一字未改，协调器数组加 `urlRuleStore`
   （Task 6 建的同一个对象）；`clearAllSyncIds` 闭包仍只覆盖书签，理由写进协调器闭包旁与 controller 第 4 步注释；
   `PhiURLRuleLocalAccess` 里加了一句注释钉住「没有、也不许有 `clearAllSyncIds`」。
8. **`resetForNewStoreBirthday` 核对通过**：`for registration in ownedKinds` 覆盖第三条 kind、逐条 `writeOwnedTable`，
   Task 6 已把 `urlRulesReplayedForEmptyTable = false` 加进 Space 表那一批；本任务零代码，CASE 9.3 钉住。

### 与 brief 不同的实现判断

9. **U-13c 的「purge 级联硬删 X 的行」按 store 半边的产物建模**：`FakePhiSpaceAccess.purge` 不级联到
   `FakeURLRuleAccess.rows`（也不想为此改 `PhiSpaceLocalAccessTests.swift` 那个假件），所以 fixture 直接以「行不存在」
   开局；引擎半边（映射被 `dropSpaceMapping` 删、游标豁免、零 tombstone、③ 按载荷建行）逐条断言。
10. **U-13b 的第一页同时带 Space tombstone 与三条规则更新**：只有 Space tombstone 的页不会让规则游标长出
    `pendingApply`（没有入站实体就没有停放），brief 的期望要三条规则更新与 tombstone 同页到达（Space 段先落 ⇒ hidden
    ⇒ 规则段目标不合格 ⇒ 停放）。`su-1` 给一条已落地的 Space 游标，并从 `silenceOtherSections` 的 `unreadableTagHashes`
    里摘掉它；撤销变体直接把 `su-1` 游标从 hidden 改回活着。
11. **U-13 的 RR-B6 重启探针**：第一轮 `client.commitErrorOnce = Boom()` 模拟「发出去之前进程没了」，第二台引擎复用
    同一个 access / store / client；断言行上的 `deletedDate` 与游标上的 `deleteDecidedAtMs` 都活过重启、值只写一次。
12. **CASE 9.3 抛在 owned commit 上**：`r1` 的行改过 host ⇒ 发布段真的发一次规则 commit；设置段与 Space 段按 2b-L1
    静默，`commitErrorOnce = .notMyBirthday` 于是落在那一次上（U-30 用的是 getUpdates 侧的 `throwNotMyBirthdayOnce`）。
13. **U-20 (a) 的 agent Space 用过期 incognito 运行期 id 代替**（`SpaceManager.incognitoRuleTargetId + ".stale-runtime"`，
    `isRoutableRuleTarget` 假 ⇒ `eligibilityOwner` nil），同一条 R-M3-4a-8 判据、不需要真的 agent Space id 形状。
14. **`FakeURLRuleAccess` 多了 `deleteError`**（让两条出路抛，与 `readError` 同款）；本任务的用例没用它，留给 review /
    8b 的失败路径用例。
15. **`purgeExpiredSoftDeletedOwnedRows` 不带 `spaceSectionEnabled` 门**（照 brief ⑥ 原文）：清的是本机 30 天前的软删
    垃圾，与门无关；门关着超过 30 天的软删行会在没发出 tombstone 的情况下被清掉，这一格由既有的起源 (a) 差分（行没了、
    归属合格 ⇒ tombstone）兜住，只有「目标 Space 同时不合格」才会留一条账户孤儿——与 M3-3 书签硬删的既有行为同形。
16. **`URLRuleKindTests.makeEngine` 加了 `clock: Clock? = nil`**（`PhiSyncEngineSpaceTests.Clock`），9.1 / U-13c 推时钟；
    不传时仍是冻结的 `Self.now`。

### 验证口径

17. **compile-only**（`xcodebuild build-for-testing … -quiet`，exit 0，零 error，触碰的文件零 warning）。十六条新用例
    没有在运行时跑过；每条的走向（判据 3 挡住活行、`explicitDeletions` 绕过两道门、`.applied` ⇒ 硬删、豁免保游标、
    `dropExpiredOwnedTombstones` 先丢游标再由出路 2 按行清）按代码推导。U-22 的「另外两条零 commit」依赖 rank 投影
    在次序一致时沿用基线 rank（U-18 (a) 的零 commit 是同一条前提）。

### Fix round 1（review 的一条 Important + 一条 Minor）

18. **出路 1 只在游标表落盘成功之后跑**：`let saved = writeOwnedTable(registration, table)`，硬删加 `saved` 合取。
    写盘失败时行原样留着（软删、对每个读口不可见），下一轮从盘上重读的游标再发一条 tombstone、`.applied` 之后
    才删。CASE 9.4 `test9_4_exit1IsSkippedWhenTheCursorTableSaveFails`（`PhiSyncEngineOwnedItemsTests`）钉住：
    发布段那一次 save 的序号**不写死**——规则是 `landsEmptyBatch` 的 kind，空页的落地段末尾也无条件写一次表，
    所以先跑一轮行还活着的校准轮数出「一轮几次 save」，再 `failSaveOnCallNumber = saveCalls + N`；断言本轮
    `.cursorSaveFailed` 且 tombstone 已发出（证明失败的是发布段那一次而不是更早的那次）。
19. **`purgeSoftDeletedURLRules` 一行失败不中断**：逐行 `do/catch`，数成功条数，末尾一条 R12 warn（kind + 失败
    条数），返回成功条数；只有那一次读抛出去。
20. **9.3 / 9.4 的假 client 用 `scriptedPages` 喂空页**：种下的服务端行（空密文、只给 commit 的更新路径用）
    否则会在默认 marker 下被拉回来当成一条解不开的入站实体、进 `unreadableTagHashes`、把那次 commit 挡掉。
21. 验证仍是 compile-only：`xcodebuild build-for-testing … -quiet` exit 0，零 error，触碰文件零 warning。

## Task 11

汇合段：`SpaceManager.applyRuleEdits(upserts:deletedIds:)` 成为四个写面（编辑器 Save、agent `urlRules.add` /
`.update` / `.delete`）共用的唯一入口，`setAllRules` / `setRules` 与两条乐观推送删除；编辑器改成显式编辑集
（`URLRulesEditor.computeEditSet`，行级脏判据 + 「清空即删除」+ 拖动排序整桶只带 `sortOrder`），两处本地改写
（失效目标回退到 `ruleTargetSpaces.first` / 整条丢掉）拿掉；agent 四处 draft 构造点都带 `id` / `syncId` /
`spaceId` / `sortOrder`，三个写面改成延迟回执。Commit：见 task-11-report.md。

### brief 的四条计划裁定（要求记档的）

1. **裁定 1（`URLRuleDraft.spaceId` / `.sortOrder`）**：Task 5 已经落地（两个 `Optional` 合并单元，`nil` = 这次
   upsert 不带），没有 BLOCKED；本任务按 `spaceId: String?` + `sortOrder: Int?` 消费。Task 12 收进 spec §15。
2. **裁定 3（store 的 `syncId` 兜底）**：Task 5 的 `applyURLRuleEditsBody` 第 2 步已实现「`id` 命中不到、
   `draft.syncId` 命中 ⇒ 同一条行、`row.id` 改写成 `draft.id`」；U-14 legacy 变体正面钉住。spec §4.3 第 3 条
   仍缺这一句，登记待 Task 12 补。
3. **裁定 5（`ExtensionMessageRouter.swift` 不在 spec §11 文件表；新错误码 `write_failed`）**：三条注册改成
   `return nil  // async reply via ExtensionMessaging`（形状照 `profiles.create` / `.rename`）。`ok` 从此意味着
   已提交。全仓没有 agent 协议错误码表，`write_failed` 只在 handler 注释里描述。
4. **裁定 6（§6.6 第 5 行）**：`SpaceManager.deleteSpace` 的级联改成 `Task { @MainActor in try await
   deleteSpaceCascadeThrowing(spaceId:origin: .userIntent); reloadURLRulesFromStore() }`，失败一条 R12 log。
   代价：级联从「同步入队」变成「一个 Task hop 之后入队」；`deleteSpace` 之后没有任何同步的 store 写依赖这个
   顺序（其后只清 userDefaults 的 theme 记录）。

### 与 brief 不同的实现判断

5. **`SpaceManager.makeForTesting(boundTo:)`（控制者已批准）**：`SpaceManager` 是 `private init()` + `shared`
   + `private bind(to:)`，brief 的 U-24c (a)「一个绑在临时目录 store 上的 SpaceManager、不碰单例」无法成立。
   加了一个 internal 的 `@MainActor static func makeForTesting(boundTo: Account?)`，只置 `boundAccount`
   （不接 publisher、不跑 `ensureDefaultSpace`、不碰 `shared`），带 `//` 注释钉「仅供测试、生产代码绝不能调」；
   `Sources/` 里除定义外零引用（grep 核对）。测试经 `Account.localStorage`（可赋值的 lazy var）指到临时 store。
6. **裁定 4 的重排 draft 用 `content: nil` / `spaceId: nil`**（brief 写的是「四单元原样带库里的值」）：Task 5
   落地后 `nil` 单元的字面含义就是「不碰」，比回填 `stored` 现值更稳（缓存滞后时不会把陈旧内容写回去）；
   body 于是只写 `sortOrder`、两枚戳不动，与裁定 4 的目的逐字相同。序列比较只看**既有行**（`storeId != nil`）
   且 `loaded` 侧只数仍留在同一桶里的 id：单纯删一行 / 清空一行不触发整桶重排（U-15c / U-22 的 `upserts` 为空），
   新行插入或从别的桶搬进来才触发。
7. **恢复支（R-M3-4a-101 / 104）**：行在 (a) 上脏、但 `stored` 里已经没有 ⇒ draft 带原 `id`、`syncId = nil`
   （store 的 2b 步对 `syncId != nil` 命中软删行会抛 `rowAlreadyMapped`）。brief 裁定 2 把「`syncId` 该不该复用」
   留给 8b-4；本任务按控制者的自查清单取 `nil`，用例 `testADirtyRowDeletedRemotelyComesBackWithoutItsOldSyncId`。
8. **`Row.init(from:)` 对小写 uuid 形的 id 也会「重铸」**（`UUID(uuidString:).uuidString` 输出大写）：这种行的
   upsert 走 store 的 `syncId` 兜底并把 `row.id` 改写成大写。功能正确（身份由 `syncId` 兜住、`deletedIds` 走
   `storeId`），只是多一次 `id` 改写；U-14 主变体的种子用大写 UUID 串以便正面断言 `id` 不变。若要消掉这次
   改写，draft 的 `id` 应传 `row.storeId ?? row.id.uuidString`——但那与 brief 裁定 3 / U-14 legacy 变体
   「`id` 变了」的正面断言冲突，本任务照 brief。
9. **三处「陈旧注释」外的残留提及**：`git grep 'setAllRules\|setRules\|pushOptimistic…' -- Sources` 的代码符号
   零命中，但三条 doc 注释仍提到旧名：`LocalStore+SpaceURLRule.swift:697`（Task 5 的扁平 init 注释；brief
   点名本任务不碰该文件）、`TabDataModelSchemaV7.swift:135` / `V8.swift:137`（冻结的历史 schema 文档）。
   都不在 Files 表里，留给 Task 12 的收尾扫。
10. **`URLRuleDraft` 的三个兼容读口（`host` / `pathPrefix` / `askBeforeRouting`）保留**：`Sources/` 里已无
    使用者，但 `Tests/PhiBrowserTests/URLRouterTests.swift:600` 还在用；按 dispatch 的规则不删、记档。
11. **`AgentSpaceRouter.bucket(_:in:)`**：agent 侧的桶序按 `(sortOrder, id)` 排（`storedRules()` 本来就按
    `(spaceId, sortOrder)` 读出来；纯函数的入参可能无序，测试直接构造）。
12. **U-15b 的「下一轮差分 tombstones == 0」与 U-15c 的「tombstones == 1」没有在本任务的用例里跑引擎**：
    真 store 与引擎的 `FakeURLRuleAccess` 不是同一个对象；本任务只断言行状态，tombstone 半边由 Task 9 的
    U-22 / U-12 用例覆盖。
13. **U-24c (b) 多断言了一次改目标的 update**（源桶 / 目标桶各自成序）；delete 面按 brief 直接构造 `EditSet`。

### 验证口径

14. **compile-only**（`xcodebuild build-for-testing … -quiet`，exit 0，零 error，触碰文件零 warning）。九条新
    用例没有在运行时跑过；U-14 / U-22 / U-24c (a) 依赖 Task 8 记的那条运行期未验证前提（一次已 await 的
    后台写之后主上下文 fetch 可见），用例照 `LocalStoreURLRuleThrowingTests` 的 `drainMainQueue()` 形状。
15. CASE 11.1 的三条 grep：代码符号零命中（见第 9 条的注释残留）；`applyRuleEdits(` 在
    `AgentSpaceRouter+Management.swift` 恰好 3；`localStorage.` 只在 `storedRules()` 一处、三个 handler 段内零命中。

### Fix round 1（review 的两条 Important + 一条 Minor）

16. **`makeForTesting(boundTo:)` 改走新的 `private init(testAccount:)`**：从前它调 `private init()`，而那个 init
    无条件 `bind(to: AccountController.shared.account ?? defaultAccount)`（`ensureDefaultSpace` 写真库、订阅
    publisher、`handleSpacesUpdate` 末尾的 `reloadURLRulesFromStore()` 让 U-22 / U-24c (a) 的计数断言依赖时序）。
    新 init 不注册观察者、不绑任何账号、只置 `boundAccount`；第 5 条的「只置 `boundAccount`」从此为真。
    U-22 期望计数 1、U-24c (a) 期望 0 → 1 → 2 → 3，对 bind-nothing 的实例只有 `applyRuleEdits` 会自增，成立。
17. **裁定 4 的重排 draft 跳过已从 `stored` 消失的兄弟行**：pass 3 加 `storedByStoreId[storeId] != nil` 守卫。
    没这条时，远端硬删 / tombstone 掉的兄弟行会以 `content: nil` 的 draft 撞进 store 的插入支
    （`noCandidateSurvived` / `rowAlreadyMapped`），整次 Save 回滚。CASE 11.2
    `testAReorderStillCommitsWhenASiblingVanishedBehindTheSheet` 钉住（重排 + 一条兄弟行硬删 ⇒ `upserts`
    不含它、写入提交、桶稠密）。
18. `computeEditSet` 的中文契约块从 `///` 改成 `//`（首行英文 `///` 保留）。
19. 验证仍是 compile-only：`xcodebuild build-for-testing … -quiet` exit 0，零 error，触碰文件零 warning。

## Task 8b-1

D30 的定义段 + M1 认领：`RuleSignature` / `URLRuleKind.signature(of:)`（行、实体两个重载）/
`baselineSignature` / `isAtRest`（十项，R-M3-4a-86）；协议六个 D30 成员（`signatureIndex` /
`pendingLocalEditIdentities` / `unpublishedIdentities` / `mergePartners` / `notePersistedClaims` /
`noteDeletedRows`）+ `AccountPhiURLRuleAccess` / `FakeURLRuleAccess` 实现；`URLRuleSyncOp.rekey` +
`LocalStore.rekeyURLRuleThrowing` / `rekeyURLRuleBody(localId:to:index:in:)`；`PhiOwnedItemTable.removeCursor`；
`urlRulePlan` 的 M1 pre-pass、`landURLRules` 的 `.claim` → `.rekey` 翻译与两个就地更新口、
`applyOwnedKind` 提交后删旧游标。Commit：见 task-8b-1-report.md。

### brief 的五条计划裁定（要求记档的）

1. **`OwnedItemPlanContext` 三个成员已存在**：`pairs` / `adoptedMerges` / `adoptedFieldWrites` 只**填**不建，
   `SyncableOwnedItems.swift` 只改 `pairs` 那一行注释（「实体身份 -> 本机行的稳定本地 id（书签是 `guid`，
   规则是 `PhiLocalURLRule.id`）」）。`.claim` 的本机 id 走 `OwnedPlanOutput.claimedLocalIds` →
   `OwnedLandingInput.claimedLocalIds`（都带默认空值，书签 / pin 构造点逐字不变）。
2. **`notePersistedClaims` 的参数方向与书签相反**：规则收 **本机行 id -> 新 syncId**（§5.6），
   `BookmarkSyncRoundState.notePersistedClaims` 收的是身份 -> guid。协议注释与两处实现都钉了方向。
3. **M1 不受 `ownedItemsPublishAllowed` 闸约束**：pre-pass 住在 `urlRulePlan`（落地段），`:3811` 的闸一个字节
   没碰；CASE M-11 用 `MemorySpaceStore()`（`hasDrainedFullReplay == false`）验收 `adopted == 3`。
4. **`adoptedFieldWrites` 按 §8.4.2 那张成员表**：判据 `payloadBytes(merged) != payloadBytes(本机行此刻的投影)`；
   `mustRepublish` 判据 `payloadBytes(merged) != payloadBytes(arrival.entity)`。spec 第 2 步那句「本机赢下任何一个
   单元 ⇒ 进 `adoptedFieldWrites`」与表不等价，**spec 内部不自洽，登记待 Task 12 收进 §15**。
5. **`normalize` 显式入参、不给默认值**：三个 `URLRuleKind` 静态函数都收 `normalize:`；调用方一律传
   `URLRuleSignatureQueries.normalize`（= `LocalStore.normalizedRule`）。`signature(of row:)` 自己跑一次归一化
   （CASE M-8 的本机行是 `"GitHub.com."`）。

### 与 brief 不同的实现判断

6. **`mergePartners` 多一个入参 `tombstonesThisPage: Set<String>`**（brief 写的是 `mergePartners(table:resolve:)`）。
   brief 内部矛盾：同一段要求「W 必须静止（十个合取项，**含第 10 项**）」且 CASE M-28 (a) 断言变体 10
   （`tombstonesThisPage == ["r"]`）下不交回——第 10 项只能从本页 tombstone 集合算，协议成员没有别的来源可读它。
   8b-3 接线时从 `input.tombstoned` 传。
7. **四个只读查询的逻辑只有一份**：`URLRuleSignatureQueries`（`PhiURLRuleLocalAccess.swift`，internal enum）承载
   纯函数半边，`AccountPhiURLRuleAccess` 喂 `cachedRows` / `cachedLive`、`FakeURLRuleAccess` 喂 `rows`。
   两处各写一份会在「谁算静止」上分叉。
8. **M1 的候选定义域是「本页到达 ∪ 停放」**（brief ② 只写「每条 arrival」）：与模块 `plan` 的工作集同域。
   CASE M-1 ⑤ 的落地失败 ⇒ 整批停放，下一轮停放项重试时走同一条认领通路收敛到 ①（用例末尾多跑一轮断言）；
   只看 arrival 的实现会在重试轮把它建成第二条行。两条排除：本机已有对应行（含软删行）的到达身份不是候选
   （它按身份落地）；`syncId` 正在本页到达的本机行也不是候选（它被那条到达按身份命中）。
9. **认领的行按账户级 rank 重新排位**：`landURLRules` 把认领当成「进了桶」（与 `.create` 同一条理由）；
   投影下标变了而又没有字段写时，那一次写仍走 `values`（`.update` 折进 `.rekey`），不另发 `.reorder`
   （R-M3-4a-42(b) 一身份一次落地写）。批次入口 `.rekey` 带 `values` 时同样记目标桶。
10. **`URLRuleApplyBatch.init` 对 `.rekey` 按 `localId` 去重**：同一条本机行的第二条 `.rekey` 丢弃（DEBUG 断言），
    留第一条；后到的那条身份落地后复核不过 ⇒ 停放。
11. **`FakeURLRuleAccess.land` 的 `.update` 不再对活行清 `mergePartnerSyncId`**：Task 8 的假件无条件清，与生产
    `upsertURLRuleBody`（只在命中软删行时清）不同形；CASE M-20 第二段（认领带字段写、`mergePartnerSyncId`
    一个字节不动）要求假件与生产同判据。假件的 `.rekey` 照生产 body 做两条守卫 + 撞车检查，**先整批校验再改
    `rows`**（假件没有事务）。
12. **`urlRulePlan` 多一个入参 `access:`**（`signatureIndex` 住在 access 上），注册项闭包跟着传。
13. **CASE M-2b 用 `getUpdatesErrorAfterPages = (1, Boom)` 让本轮止于 pull**：`drainedSpaceStore()` 下发布段的
    补键通路（`unkeyed`）会为这种形状的游标经 client tag 重新认一次身份并收割三元组——那是它的正当行为，但会
    遮住「认领 pre-pass 一个字节没动它」这条断言；R-exec-8 的 `ownerUuid` 刷新同理（fixture 预置 `"su-1"`）。
14. **CASE M-18 主变体第 2 页是空页**（brief 写「别的 kind 的内容」）：本引擎只注册规则 kind，空页对规则照样
    走 `plan` / `land`（`landsEmptyBatch`）；跨页重复认领变体第 2 页带同签名的第二条规则实体。
15. **远端戳一律 5_000_000 ms**（比 fixture 行的 `createdDate` 1_000_000 ms 新），且同桶到达 rank 递增
    （`V` / `W` / `X`）：合并结果 == 入站实体、零 `mustRepublish`、认领后 `sortOrder` 序与基线 rank 序一致 ⇒
    `pushed == 0` 的断言只说认领这一件事。默认戳（100）下本机会按 R-M3-4a-12 赢下三个单元并正当地重新发布一次。
16. **`adopted` 在整批回滚时仍计 `pairs.count`**（`counters.adopted += output.adopted` 在 `land` 之前），与书签
    `adopt` 同形；CASE M-1 ⑤ 不断言它。
17. **测试文件不需要工程改动**：`Tests/PhiBrowserTests` 是 `fileSystemSynchronizedGroups`（Task 7 的
    `URLRuleKindTests.swift` 也不在 pbxproj 里），dispatch 里「照 Task 7 的 gem 脚本注册」那一句不适用。

### 验证口径

18. **compile-only**（`xcodebuild build-for-testing … -quiet`，exit 0，零 error，日志零 warning）。二十四条新用例
    （`URLRuleMergeTests` 18 条、`PhiOwnedItemStateTests` 1 条、`LocalStoreURLRuleThrowingTests` 5 条）没有在
    运行时跑过；每条的走向按代码推导（见 report 的逐条说明）。

## Task 8b-2

§8.4.3 的 M2 收敛：两遍指针 + 整组归约（R-M3-4a-82）、落地段尾钩 `URLRuleMergeTail`、
三个 `LocalStore` 原语、两条清空规则、drain 闸只管第 2 步、§6.6 第 8 行、
`OwnedItemPlan.preLandingSignatures`。

### brief 的「计划裁定」要求记档的

1. **`preLandingSignatures` 用具体类型 `[String: RuleSignature]`**（裁定一）：不用 `AnyHashable`
   （分组键退化成运行期强转、失败即静默空转），也不给 `OwnedItemKind` 加第三个关联类型（会把非泛型的
   `OwnedItemPlan` 拖成泛型、牵动书签与 pin 的每一个调用点）。全仓一个 module，`SyncableOwnedItems.swift`
   已经具名引用过 pin 专属的 `PinnedTabScope`，没有新的构建边。书签与 pin 那两条路径永不填它。
2. **`convergePass` 先跑、`mergePointerPass` 后跑**（裁定四）：与 §8.4.3 伪码「按组交织 + 循环后第二遍」的
   op 发出次序不同，终态逐字相同、行写严格更少。证明**三条腿**逐字写在 `URLRuleKind.mergePass` 的文档
   注释里，评审按那一段核对：(1) 锚点的**身份**不变（锚点 ≤ 胜者 < 每一条败者 ⇒ 锚点永不当败者，那一行
   也必然活到写循环）、(2) 锚点子集的**基数**不变、(3) 终值支配。**第 (2) 条靠的是接缝不是论证**
   （fix round 1 / 评审 F1）：伪码的 `writePointer` 在收敛**之前**求那个 `published.count > 1`，先收敛会把
   「两条已发布成员 + 一条从未发布、本页也没落地的活行」这一组的子集从 2 掉到 1，那条从未发布的成员
   就拿不到指针（而 `mergePartnerSyncId` 生命周期表的 RR10-8 那一行按「它被写过」立）。落法：
   `mergePointerPass` 加第二个入参 `anchorRows`（带默认值 `nil` ⇒ 与 `liveRows` 同一份），**锚点子集建在
   软删之前那一份活集上、写循环仍然只跑软删之后那一份**。探针 `testM2a_theAnchorCardinalityIsEvaluatedBeforeTheSoftDeletes`。
3. **三个原语「找不到行」零写返回、DEBUG `assertionFailure`，不抛**（裁定五）：M2 的输入全部来自同一个事务里
   刚读到的那份投影，结构上必然命中；抛会把整页落地回滚掉，同一页每轮重放每轮抛。
4. **本页 `.transfer` 目标从 M2 第 2 步候选集里减掉**（裁定六 (1)，R-M3-4a-90）：`land` 闭包里
   `input.atRestIdentities.subtracting(URLRuleKind.transferTargets(in: input.steps))`，传进 `mergePass(atRest:)`
   的是减完的那一份。**`transferTargets(in:)` 今天结构性地交空集**——`.transfer` 相由 8b-3 加进 `StepKind`
   （本任务不改那个枚举），函数体里那个穷举 `switch` 会在 8b-3 补 case 的那一刻编译不过，减法本身已经接上。
5. **内容组戳改读「有效账户戳」**（裁定六 (2)，R-M3-4a-94）：唯一取值源是
   `URLRuleKind.effectiveAccountStamps(landed:rebaselined:table:identities:)`；`mergePass` 的 `table:` 入参
   **先被 R-M3-4a-90 删掉、又被 R-M3-4a-94 恢复**（未落地那一半只能从游标 `reconciled` 读），同批加
   `landed:`。**`accountContentStamp(identity:table:)` 那个「只读基线」的旧口仍然不要**——它是这条裁定的反面。
   `convergePass` 的签名与函数体一字不改，它只拿算好的 `[String: Date]`。
6. **有效账户戳的第二层 `rebaselined` 与 `OwnedLandingInput.rebaselined` 这条新通道**（R-M3-4a-97）：
   `plan.rebaselined` 要等 `land` 返回之后才写进游标，落地闭包读 `input.table` 就读到更旧的那一枚戳
   （CASE M-33 变体 (d)）。引擎在 `land(...)` 调用点同批转 `output.plan.rebaselined`。
7. **那张表按单元分两枚（`URLRuleEffectiveStamps`）并经 `URLRuleApplyBatch.accountStamps` 供给 8b-3 的
   `.transfer`**（R-M3-4a-98）：`land` 闭包在拼批次**之前**算一次（`identities` = 本页活行 ∪ `landedIdentities`
   ∪ `transferTargets`），整张交给批次的第四个 init 参数；尾钩那一侧的 `mergePass` 拿同样的三个入参再算一次
   （纯函数、输入逐字相同 ⇒ 不可能分叉）。本任务只**供给**，消费者是 8b-3。
8. **空批次也走完整引擎入口**（R-M3-4a-99）：`OwnedKindRegistration.landsEmptyBatch` 与
   `applyOwnedKind` 那道空批次早退 guard 的第四个析取项由 **Task 6 已经产出**（`.urlRules` 取 `true`、
   书签与 pin 显式 `false`），本任务只放宽另外两处：`LocalStore.applyURLRuleSyncBatchThrowing` 的
   `guard !ops.isEmpty` 放成 `!ops.isEmpty || mergeTail != nil`，`landURLRules` 的
   `guard !input.steps.isEmpty` **整条删掉**。
9. **pre-pass 静止集只是上界，尾钩在事务里做第二次减法**（裁定六 (3)，R-M3-4a-100）：`mergePass` 在重读的
   `rows` 之后、调 `convergePass` **之前**剔掉此刻 `pendingLocalEdit == true` / `deletedDate != nil` / 行已不在
   的身份。**只减不加**——游标侧的七个合取项与第 10 项一律不重算。
10. **指针锚点的「已发布」输入显式传入 `publishedIdentities`**（R-M3-4a-95）：`land` 闭包按
    `Set(input.table.cursors.filter { $0.value.server != nil }.keys)` 算；函数内**不许**拿 `row.syncId != nil`
    当「已发布」（M1 认领那一刻就有 `syncId` 了）。
11. **§6.6 第 8 行落在 Task 6 的刷新钩子上，不碰 `SpaceManager.swift`**（裁定七）：钩子是
    `landURLRules` 末尾那一句 `access.refreshRoutingTableAfterLanding()`（`PhiSyncEngine.swift`，**不在**
    `PhiChromiumCoordinator.swift`）；改动是把它包进
    `if !ops.isEmpty || out.mergeChangedRouting`。**指针写不进这个条件**（CASE M-7 钉住零刷新）。

### 本任务额外的偏离

12. **`RuleSignature: Comparable` 在 `URLRuleKind.swift` 里补了一个扩展**（不改 8b-1 的类型定义本身）：
    两个 pass 都按 `groups.keys.sorted()` 遍历（`PinKind.swift:361` 的收敛先例），而字典 `keys` 的次序是
    每进程随机的。比较键**注入**（先比 `pathPrefix` 有没有、再比值），两个不同的签名绝不比成相等。
13. **三个原语的 body 多一个 `index: inout URLRuleTableIndex` 入参**（brief 的签名只写了 `in context:`）：
    R-M3-4a-56 的寻址条款在一个写块里的落地形式就是那份含软删行的整表索引，而 `upsertURLRuleBody` /
    `hardDeleteURLRuleBody` / `rekeyURLRuleBody` 三者已经是这个形状。body 是 **internal 不是 private**，
    理由同 R-exec-2。
14. **`URLRuleMergeTail` / `URLRuleBatchOutcome` 定义在 `PhiURLRuleLocalAccess.swift`**（brief 把它们画在
    批次入口那一节）：`URLRuleApplyBatch` 要持 `mergeTail`、协议的 `apply(_:)` 要返回 `URLRuleBatchOutcome`，
    放在同步层可以让 `LocalStorage` 不去定义同步层协议依赖的类型。
15. **`apply(_:)` 与 `applyURLRuleSyncBatchThrowing(_:mergeTail:)` 都标 `@discardableResult`**：Task 8 与
    Task 5 留下的那批「只看 `rows` / 库里的行变没变」的值级用例（`URLRuleKindTests` 2 处、
    `LocalStoreURLRuleThrowingTests` 十余处）不必为了一个返回值逐行改。引擎那一侧**永远**读它。
16. **尾钩的装配点是一个非隔离的自由函数 `makeURLRuleMergeTail(...)`**：闭包在写队列上被调，在 `@MainActor`
    的 `landURLRules` 里直接形成会被推断成 `@MainActor` 闭包、转成非隔离函数类型要丢掉全局 actor。
    捕获的全是值类型，闭包体是 `URLRuleKind.mergePass` 这个纯函数。
17. **`landedIdentities(in:)` 含 `.claim`**（brief 的注释只点名 `.create` / `.move` / `.update` 是排除项的
    反面）：一条被认领的行这一页第一次拿到账户身份与账户级 rank，指针的锚点子集要认得它。排除项仍然只有
    `.delete`（以及 8b-3 的 (β)）。有效账户戳的第一层读的是另一份字典 `landed`（`land` 闭包刚翻译出的
    那批 op 的值），两者是两个概念。
18. **不声明 `URLRuleSyncOp.transfer`**：brief 的 op 清单只有三条新 case，而 `.transfer` 的 `source:`
    需要 8b-3 的 `RuleProjection` 类型。`URLRuleBatchOutcome.deferredTombstones` 与
    `URLRuleApplyBatch.accountStamps` 两条给 8b-3 的通道已经**声明并原样回传 / 供给**。
19. **改了一条既有断言**：`URLRuleKindTests.swift` 的回声轮用例把 `applyCalls(access)` 从 1 改成 2 —— 回声轮
    （`push` 先跑一次 pull）那一页零规则 step，而 R-M3-4a-56 要求空批次照样进事务跑 M2。同一处补了两条
    探针（那一批零落地 op、刷新总数仍是 1）。书签与 pin 的用例一条没改。
20. **CASE M2-d 的冲突支用 `.rekey` 撞车，不是「`.softDelete` 命中 `syncId` 不符的行」**：三个原语一律按
    `syncId` 在 `URLRuleTableIndex.bySyncId` 上寻址，那条 `rowAlreadyMapped` 守卫在该寻址路径上**结构性
    不可达**（留着是为了寻址方式一旦变化，静默覆盖仍然变成一次抛错）。钉的东西不变：一次抛错让**尾钩已经
    写下的那几列**一起回滚。
21. **CASE M-36 的「真实用户写」经 `FakeURLRuleAccess.applyEditorSave(...)`**：假件背后没有 `LocalStore`，
    这个入口是 `applyURLRuleEditsBody` 第 4 / 9 步的假件等价物（内容组逐成员比 ⇒ 写 + 置位 + 戳；三个都相同
    ⇒ 零写零置位），用例仍然不许直接戳 `rows`。旋钮 `beforeLandingTransaction` 只在假件上。
22. **CASE M-6 缩到「同一对账户身份、两台的每设备量完全相反 ⇒ 同一个幸存者」**：brief 的逐轮脚本
    （两台并发新建、轮 1/2/3/4 的 `collapsed` 与 tombstone 计数）要一台真的共享服务端状态的双引擎 fixture，
    而它同时依赖 8b-3 的让位半边；本任务写的是**承重的那一条**——胜者选择不依赖任何每设备量
    （本机 `id` / `createdDate` / `sortOrder` / 插入次序），两台软删的身份逐字相同。
23. **CASE M-16b / M-17 (i) / M-25 (e) 的 8b-3 半边不写**（brief 已经点名它们不属于本任务）：M-17 只断 M2
    那一半，M-16b 整条依赖 (ii) 让位支，留给 8b-3。

### Fix round 1（评审 `task-8b-2-review.md` 的 F1 / F3 / F2；F4 ~ F7 由控制者 park）

25. **F1（Important）**：`mergePointerPass` 的锚点子集与写循环分域 —— 见上面重写过的第 2 条。
    `mergePass` 传 `anchorRows: live`（软删之前）、`liveRows: liveAfter`（软删之后）；两处文档与本条 ledger
    同批把「终态逐字相同」那句证明补成三条腿。新增一条纯值探针。
26. **F3（Minor）**：`effectiveAccountStamps` 的**第一层**按同一条「毫秒 0 = 缺席」口径压零。
    `URLRuleLandingValues` 的两枚戳是非可选 `Date`，而 R-M3-4a-12 的无基线分支给目标戳与 rank 戳写的正是
    0 ⇒ 不压就会给 8b-3 的 `.transfer` 递一枚 `Date(1970)` 这种「看起来很旧但很真」的目标戳。缺的那一枚
    **按单元**落到第二 / 三层（一条本页 `.create` 的身份根本没有游标，补不到就仍然缺席）。
27. **F2（Minor）**：`OwnedLandingOutcome.collapsed` / `.mergeChangedRouting` 挪到 `createdRows` /
    `createdPins` **之后**，`createdRows` 那段被劫走的文档注释归位。

### Fix round 2（re-review 在 fix round 1 上判出的新 Important）

28. **锚点子集的「软删之前」那一份定义域只给第一遍用**：fix round 1 让**两遍**都从软删之前那一份活集
    求锚点子集，而 leg (1) 的「锚点 ≤ 胜者 < 每一条败者」**只在分组键与 `convergePass` 的键相同时成立**
    —— 也就是第一遍的「此刻的签名」。第二遍的键是 `preLandingSignatures[id] ?? 此刻的签名`：一条本页按
    K1 被软删掉的败者会以它的**落地前**键 K2 重新进组，并且完全可能是 K2 里 `syncId` 最小的那一条 ⇒
    它当上 K2 的锚点，而它是一条**同一个事务里刚被软删的死行**（K2 的子集还常常正是靠它才够到 2），
    K2 那条活成员的 `mergePartnerSyncId` 会当场指向它。可达性：一条本页落地了入站 `.move` / `.update`
    的行照样保留 pre-pass 那一刻的静止判定，收敛因此完全可能选中它当败者。
    **落法**：`mergePointerPass` 里那个 `pass(_:)` 加一个 `anchorsFrom:` 入参 —— 第一遍传 `anchorRows`
    （软删之前），第二遍传 `liveRows`（软删之后）。这不违反伪码：伪码的第二遍本来就跑在 `liveAfter` 上。
    `mergePass` 与 `mergePointerPass` 两处的证明同批重写，明说哪一遍用哪一份、为什么。
    探针 `testM2a_theSecondPassNeverAnchorsOnARowCollapsedThisPage`（含「`p` 还活着时那条写是对的」的对照）。

### 验证口径

24. **无构建**（2026-09-18 amendment：不跑任何 `xcodebuild`）。本任务新增的 33 条用例与全部实现改动只经
    逐行核对：每个引用到的符号都先 grep 过签名，每个 `switch URLRuleSyncOp` 都是穷举的，
    `URLRuleKind` 的四个新纯函数没有任何 actor 隔离状态。一次统一的编译检查在全部任务做完之后跑。

## Task 8b-3

M3 让位：(α) / (β) 两落点 + `.transfer` + `RuleProjection` + `parkedTombstones` /
`yieldedTombstones` + (ii) 记账 + 轮末 3b 复查 + `deferredDeletions`（spec §8.4.4 / §8.4.6）。

### 偏离与实现裁定（逐条写明理由）

1. **事务内「来源行未变」复查的判据不是六格原样相等**（R-M3-4a-102 / 裁定 11 的实现裁定）。
   `source` 的两枚戳来自 `context.localProjections` 那份**带基线**的投影：一个单元的取值与基线相同时，
   `stamp(_:baseline:…)` 沿用的是**基线**那一枚戳，而不是行上那一列（行上那一列完全可能是 `nil`）。
   拿行上的列去和它原样比，M-12 的 (i) 支（只改了目标、内容组没动 ⇒ 投影的内容组戳 = 基线戳、行上
   `contentUpdatedDate` 是 nil）每一轮都会被判成「变了」⇒ **永久停放**，而那正是这条复查不该挡的形状。
   落成两个合取项：① `host` / `pathPrefix` / `askBeforeRouting` / `spaceId` 四个**取值**逐格相等
   （编辑器那条写路径只在某个单元真的变了时才落写，所以任何一次有效的 Save 必然改掉其中一格）；
   ② 行上那两枚编辑戳**都不新于** `source` 手上那两枚（毫秒粒度，兜住 A→B→A 那种净值不变的两次 Save）。
   行已不在 / `deletedDate != nil` 一律算「变了」。实现是纯函数
   `URLRuleKind.transferSourceUnchanged(row:source:)`，生产落地与假件共用。
2. **`transferred` 与转移那一格 `superseded_by_delete` 在落地事务里求值，不在 plan 闭包里**
   （偏离计划裁定六末段的字面写法）。裁定六写的是「`source.contentUpdatedDate <= W 那一行的
   contentUpdatedDate` ⇒ +1」，而 CASE M-34 的变体 (b) 与 (c) 都期望 `superseded_by_delete == 1`：
   (b) 里 W 的行戳要等本页那条 `.update(W)` 落下去才是真的，(c) 里判据本来就是
   `max(行戳, 有效账户戳)`（R-M3-4a-98）——两样东西 plan 闭包手上都没有。按行戳的字面实现在两个变体上
   都算成 0。落法：`URLRuleBatchOutcome` 加 `transferred` / `transferSupersededByDelete` 两个计数，
   `OwnedLandingOutcome` 加 `transferred` / `supersededByDelete`，引擎并进既有的两个计数器。
   `yield_no_partner` 仍按裁定六留在 plan 闭包（它的两个判据都在 pre-pass 手上）。
3. **`transferURLRuleEditBody` 的签名带 `index: inout URLRuleTableIndex`、返回
   `URLRuleTransferResult`**（Produces 写的是 `in context:` + `-> Int`）。前者与 M2 那三个 body 同形，
   是「一个写块只建一次索引」（R-M3-4a-80 / 56）的硬要求；后者让批次执行器拿得到「内容组输没输」与
   「W 换没换桶」两件事，而公开的 `transferURLRuleEditThrowing(toSyncId:source:targetEffectiveStamps:)`
   仍按 Produces 返回 `Int`（写下去的单元数）。判定本身在纯函数
   `URLRuleKind.transferDecision(target:source:targetEffectiveStamps:)` 里，生产与假件共用。
4. **`partnerNotAtRest` 既是协议要求、也只有协议扩展里那一份实现**（控制者裁定的形状）。①② 两步直接调
   `URLRuleSignatureQueries.mergePartners`，所以「谁算 W」两处不可能分叉；本函数只补第 ③ 步那一次分流
   （「这一组有没有**活的**伙伴行」——软删的伙伴按静止第 7 项永远静止不了，算成「有伙伴」就是无界停放）。
   它对一条**本身静止**、而同组另有一条不静止活行的身份**也会返回真**：那是正确的（若它随后带着一次
   未发布编辑撞上 tombstone，确实该停放），发布段那一侧由第二个合取项 `pendingApply != nil` 干净放行。
5. **`URLRuleApplyBatch` 的 `.transfer` 不进槽**：它写的是**另一条**身份（`toSyncId`）的行，与同
   `syncId` 的落地写没有可合并的关系。于是 Task 8 那条「同一身份不会既有升级写又有 `.delete`」的断言
   对 8b-3 逐字有效，不需要放宽。相序落成 `upgrades + transfers + passthrough + deletes`。
6. **`landBookmarks` 的 `switch step.kind` 加了一条 `.transfer: continue`**（结构性不可达：
   `tombstoneYieldsToLocalEdits` 在书签上恒假）。pin 那一侧不是 `switch`，不用改。
7. **`FakeURLRuleAccess` 加了两个「真实用户写」入口**：`applyEditorRetarget(syncId:toSpaceId:at:)`
   与 `applyEditorDelete(syncId:at:)`，形状照 `LocalStore.applyURLRuleEditsBody` 的第 5 / 7 / 9 步
   （用例不许直接戳 `rows`）。`apply(_:)` 的 `land` 多收 `outcome:` / `alphaSources:` 两个入参，
   M-37 的注入点复用 8b-2 已经加好的 `beforeLandingTransaction`，**没有新加旋钮**。

### 验证口径

8. **无构建**（2026-09-18 amendment）：只经逐行核对。每个引用到的符号都先 grep 过签名；
   `StepKind` / `URLRuleSyncOp` / `OwnedItemTombstoneResult` 上的每一个 `switch` 都重新核过穷举性
   （`SyncableOwnedItems.phase`、`URLRuleKind.landedIdentities` / `.transferTargets`、
   `landBookmarks`、`landURLRules`、`URLRuleApplyBatch.init`、`applyURLRuleSyncBatchBody`、
   `FakeURLRuleAccess.land`、`URLRuleMergeTests.opSummary` / `.stepSummary`）；
   `URLRuleKind` 的三个新纯函数没有任何 actor 隔离状态。

### Fix round 1（review 判出的两条 Important，**只补测试**）

9. **F1 —— R-M3-4a-84 守卫的引擎接线零覆盖**：原来的 `test8b33_…` 是模块级的（把
   `deferredDeletions: ["b"]` 手喂进 `SyncableOwnedItems.tombstones`），绕过了「谁来算这个集合」
   与「引擎读不读 `diff.deferred`」两件真正会写歪的事。补三条**引擎级**用例，全部经
   `pullOnce()` / `handleLocalOwnedChange(label:)` 真实走完发布段：
   `testM22_theEngineComputedGuardSuppressesTheTombstoneThroughAFullRound`（CASE M-22 的「W 不
   静止 ⇒ 停放」那一支 + CASE 8b-3.3 的整轮版：`pendingApply` 仍在、四个游标字段与轮首逐字
   相同、`client.commit` 里没有 X 的 tombstone、行一个字节没动）、
   `testM22_anOwnerShapedParkIsNotCoveredByTheGuard`（对照二：owner 形状停放**不**进守卫 ⇒
   那一轮照常发 tombstone，`pendingApply == nil` 一条的实现在这里红）、
   `testM22_theGuardAlsoHoldsOnAPushOnlyRound`（对照三：只跑 `.localOwnedChange` 那一趟，
   外加「`rows` 换成 `allURLRules()` ⇒ 守卫恒空」的同趟断言）。
10. **F2 —— 轮末 3b 复查的两条「不过」支零覆盖**：补
   `test8b34_aYieldWithNoUsableServerTripleWritesNothing`（CASE 8b-3.4 两个变体：`entityId` 为空
   / `version == 0`，**同时**目标 Space 已 purge ⇒ 成因一必须先判 ⇒ 一个字节都不写、撤销支没
   跑）、`testM12_variant2_theRecheckRevokesTheYieldOnALaterRound`（变体 (2)：第一轮准入通过、
   3b 与限定重发都拿 `.conflict`，**下一轮**才 hidden ⇒ 仍然复查并撤销、行被硬删；行上
   `pendingLocalEdit == false` 同时覆盖变体 (4)——第三个合取项写成「`pendingLocalEdit` ∨
   `unpublished`」的实现在这里恒假 ⇒ 行留着 ⇒ 断言红）、
   `testM12_variant3_anUnresolvableOwnerWritesNothingAndRepublishesLater`（变体 (3)：Space 只是
   不在 `currentSpaces()` 里、Space 游标根本不存在 ⇒ 零写；映射建立之后正常发 3b、
   `resurrected == 1`）。M-12 (ii) 那条原有用例补上 `.applied` 之后的三条断言
   （`resurrected == 1`、`deletedAtMs` 被清、两份基线都写回）——服务端那一行用
   `FakePhiSyncClient.seed(tagHash:…)` 铺好，否则 update 支在寻址上直接抛。
11. **本轮没有改动任何生产代码**：三条引擎级新用例把守卫与复查两段真的跑了一遍，没有暴露出
    实现缺陷。F3 / F4 / F5 / F6 / F7 / F8 六条 Minor 按控制者指示**不动**。
12. 一处口径澄清（写进用例注释，不改代码）：`.localOwnedChange` 那一趟走的是
    `push(retryOnConflict:)`，而它自己**先做一次 preflight pull**，所以 `plan` 照样会跑——
    对照三因此是「守卫对每一种走到发布段的轮次都成立」这条行为断言，判别「守卫读的是不是
    `plan` 的产物」靠的是 `OwnedPlanOutput` 上根本没有那个成员（结构性不可写）。

## Task 8b-4

M4 `pendingLocalEdit` 生命周期的两处清位（R-M3-4a-79 / R-M3-4a-91 / R-M3-4a-96）+ M5 编辑器
按行按字段记脏（R-M3-4a-72）。

### brief 的「计划裁定」要求记档的

1. **裁定 1（`URLRuleDraft` 的三个可选合并单元）本步是零改动。** Task 5 已经按本形状落地：
   `content: ContentUnit?` / `spaceId: String?` / `sortOrder: Int?`、`applyURLRuleEditsBody`
   的单元判据就是「非 nil 即在场」、插入支的前置要求 `content != nil ∧ spaceId != nil` 不成立
   时抛 `LocalStoreWriteError.noCandidateSurvived` 并整批回滚。扁平便利 init 与四处既有构造点
   一行都没碰。
2. **裁定 2（比较值是行侧投影、毫秒粒度）落在两个新纯函数上**：
   `URLRuleKind.clearingProjection(of:)`（行 -> `RuleProjection`）与
   `URLRuleKind.clearingProjectionMatches(row:confirmed:)`（逐单元、`stampMilliseconds` 粒度）。
   两处清位与 `.urlRules` 的 `snapshot` 闭包调的是**同一个**函数，所以「基线」与「此刻」在结构上
   不可能用两套折算。投影**不截断**戳（截断会让两次投影自己也对不齐），毫秒换算只在比较那一步做。
3. **裁定 3（`RuleProjection` 的第八个成员 `sortOrder: Int?`）带默认值 `nil`**，所以
   `URLRuleKind.transferSource(of:resolve:)` 与既有测试的每一处构造点一个字不改，而
   `transferURLRuleEditBody` / `transferDecision` 一个字节都不读它（rank 不转移）。
   **`nil` 在清位那一侧恒不等**（fail-closed）：从实体折出来的投影永远当不成清位基线。
4. **裁定 4（目标单元的换算通路）走「kind 侧换算完再交给原语」那一支。** 两处清位比较的两侧
   **都是行侧投影**，所以比的是本机 `spaceId`（`RuleProjection.targetSpaceId`），
   `targetOwnerUuid` 在行侧投影里恒空、**不参与比较**——与 `transferURLRuleEditBody` 只读
   `source.targetSpaceId` 逐字同一条通路，`LocalStore` 因此仍然不认识任何账户映射。
   `confirmed.targetSpaceId == nil` ⇒ 恒不等（换不出 ⇒ 不清）。
5. **裁定 14 的两层分工**：**原语**收 `entries: [String: RuleProjection]`（R-M3-4a-91），
   **注册项闭包** `clearPendingLocalEdits` 收 `Set<String>`（R-M3-4a-96），基线由 `.urlRules`
   闭包从**捕获的** `state.publishBaseline` 查出来。spec §8.4.5 待同批修订；附录 C-28。
6. **裁定 11 的恢复支**（远端删掉的脏行按「完整单元 + `syncId = nil`」重建，R-M3-4a-101）与
   **软删那一格**（「`stored` 里找不到」有硬删与软删两种现实，编辑器**一行都不用分**，判定由
   Task 5 的写事务第 2b 步收口，R-M3-4a-104；唯一的下游事实是 Save 之后那一行的 `storeId`
   换成了新铸的 `id`）。附录 C-36 / C-39。
7. **裁定 12 那张「脏位 -> 合并单元」映射表**由 Task 12 一次性写进 spec §15 实施勘误段。

### 与 brief 不同的地方

8. **`URLRuleSyncRoundState` 多了一个 `publishResolver`（brief 没写）。** 注册项闭包的类型被
   R-M3-4a-96 写死成 `(Set<String>) async -> Void`，拿不到 `maps`，而第二层的第 ② 步要调
   `pendingLocalEditIdentities(resolve:)`。于是与 `publishBaseline` **同一趟**（`snapshot` 闭包里）
   记下本轮的 resolver；`nil` ⇒ 这一轮整条不清位（fail-closed）。不新开通道、不改闭包类型。
9. **两个闭包对 `access` 是强捕获，不是 brief 示例代码里的 `[weak access]`。** 同一个工厂产出的
   其余每一个闭包（`beginRound` / `localIdentities` / `plan` / `land` / `liveOwners` /
   `hardDeleteAfterTombstone` / `purgeSoftDeletedRows`）都强捕获同一个 `access`，弱捕获这两个
   挡不住任何环，只会让两处清位在生命周期上与别处不一致。
10. **`computeEditSet` 的第三遍「整桶重排」整条删掉。** 裁定 12 写死「`acceptDrop` **只给被拖动
    那一行**记 `.order`」，而 U-21 要求 `upserts` **恰好 1 条**；第三遍按定义给同桶其余既有行也
    发 `sortOrder` draft ⇒ 整桶进 `upserts` ⇒ 整桶被 `applyURLRuleEditsBody` 第 9 步置位 ⇒ 那一轮
    整桶不静止、整桶对远端删除让位。其余兄弟行的稠密重编号由第 8 步的重排定义域完成，**不置位**
    （`upsertedIds` 不含它们）。Task 11 的两条相关用例随之改判（`testReorderingABucket…` 更名为
    `…SendsASortOrderOnlyDraftForTheDraggedRowOnly`、`testAReorderStillCommits…` 的期待从
    `[I2, I0]` 收成 `[I2]`），**它们钉的行为没有被削弱，只是换成了 M5 的判据**。
11. **`loaded` 这个入参保留在 `computeEditSet` 的签名里但已经没有读者。** brief 把签名写死成
    `computeEditSet(rows:loaded:removed:stored:dirty:)`；M5 之后「用户碰过没有」由 `dirty` 回答、
    「与库里还差不差」由 `stored` 回答，`loaded` 两头都不沾。保留是为了 §5.8 的调用形状与
    `loadedRows` 这个 `@State` 的既有含义，删它属于另一次改动。
12. **裁定 10（sheet 期间按字段刷新的收紧）在本仓库是空操作。** Task 11 **没有**实现 §5.8 第 3 条
    的「sheet 打开期间按字段刷新」——`load()` 只在 `.onAppear` 跑一次，编辑器此后不再从 store
    刷新任何字段。所以「脏字段一律不刷新」这条收紧没有落点可改；本任务不新造一条刷新通路
    （那是 §5.8 第 3 条自己的任务）。U-15d 的 ③ / ④ / ⑤ 在「没有刷新」这一现实下**照样成立**，
    而且成立的理由与裁定 10 同源：③ 的目标单元根本不在场、④ 零脏位、⑤ 脏字段不会被覆盖。
    **spec §5.8 第 3 条在实现上仍然缺席，这一条记进勘误**。
13. **U-15f / U-15g 里「sheet 打开期间那次删除」用生产的落地批次入口驱动，不是 `pullOnce()`。**
    brief 要求「用既有 `pullOnce()` 驱动、不要手写硬删 / `deletedDate`」；后半条严格遵守——
    硬删走 `.delete(syncId:)` op、软删走 `.softDelete(syncId:mergePartnerSyncId:)` op，两者都经
    `LocalStore.applyURLRuleSyncBatchThrowing`，与引擎落地段调的是**同一份 body**。前半条做不到
    的原因是结构性的：这两条用例跑在真 `LocalStore` 上（U-15g 的断言依赖 Task 5 写事务里的
    第 2b 步），而 `URLRuleKindTests` 的真库段没有引擎脚手架（引擎段用的是 `FakeURLRuleAccess`），
    把 `AccountPhiURLRuleAccess` + 引擎 + 假 client 接起来属于新造脚手架、且**不经构建无法验证**。
14. **U-15d 与 U-21 的「下一轮 `pushed == 1` / 恰好一条 commit」两条引擎侧断言没有写。** 同第 13
    条的理由（编辑器用例跑在真库上、那一层没有引擎）。清位两侧的发布行为由
    `URLRuleMergeTests` 的 M-7 / M-7b / M-7c / M-7d / M-7e / M-19 / M-19x 覆盖。
15. **M-19 的七个输入按「可观测终态」归并**：(a) 归一化不动点折回、(b) `ask` 改了又改回来、
    (c) 零单元转移三者在行与游标上是**同一个状态**（标志置位 ∧ 快照字节 == `reconciled`），
    合成一条用例三行断言；(d) 用 `FakeURLRuleAccess.failNextClearPendingLocalEdit` 造「(a) 那次
    行写失败」并断言下一轮由 (b) 自愈；(e) / (f) 各一条；(g) 并进 M-19x (x1) 的四条边界。
16. **M-20 改在真 `LocalStore` 上跑**（复用 8b-2 的 `makeMergeStore` / `mergeRows` 脚手架）：
    落地的每一种写（`.create` / `.update` / `.move` / `.reorder` / `.rekey` / M2 的三条 / 入站
    tombstone 的硬删）各一次 + 编辑器删除集那一条软删，逐条断言 `pendingLocalEdit == false`。
    `deleteSpaceCascade` 的两个级联入口（`.userIntent` / `.retentionPurge`）由 Task 9 的用例覆盖，
    本任务不重复。
17. **M-7b / M-7d 的「提交在途」注入点是 `FakePhiSyncClient` 既有的 `gatedCommitTagHash` +
    `arrivedInCommit` / `commitGate`**（形状照 `PhiSyncEngineOwnedItemsTests` 的加密失败用例），
    没有往假 client 上加任何新开关；M-7e 的注入点按 brief 落在 `FakeURLRuleAccess` 上
    （`beforeClearPendingLocalEditIfUnchanged`），那是唯一够得到 `entries` 的一层。
18. **多改了一个 brief 没列的生产文件：`Sources/Sync/Phi/URLRuleKind.swift`。** 裁定 2 要求
    「两处清位与 `snapshot` 闭包用**同一个**折算函数」，而那三个调用点分别在 `LocalStorage`、
    `Sync/Phi` 的引擎与工厂里；`URLRuleKind` 是它们共同的、既有的判据之家
    （`transferSourceUnchanged` / `transferDecision` 就住在那里，理由逐字相同：两处各写一份
    的实现迟早分叉）。新增的只有 `clearingProjection(of:)` 与
    `clearingProjectionMatches(row:confirmed:)` 两个纯函数，没有碰任何既有成员。
19. **`FakeURLRuleAccess` 的两个新实现与生产 body 逐字同形**（同一条判据函数
    `URLRuleKind.clearingProjectionMatches`），并新增两个 `Call` case
    （`.clearPendingLocalEdit(syncId:)` / `.clearPendingLocalEditIfUnchanged(count:)`）让
    「一次行写」「空集零事务」这两条在假件上可断言。

### 验证口径

20. **无构建**（2026-09-18 amendment）：逐行核对 + `swiftc -parse` 语法过一遍。每个新符号在使用
    前都 grep 过签名（`RuleProjection` 成员表、`transferURLRuleEditThrowing` 的实参形状、
    `URLRuleDraft` 成员表、`URLRuleSyncRoundState`、`computeEditSet` 现签名与 `stored` 实参类型
    ——brief 点名的那五项全部核过）；`URLRuleSyncOp` 仍然 `Equatable`（新成员是 `Int?`）；
    `OwnedKindRegistration` 的成员次序与三个工厂的实参次序逐条对齐；两处清位都跑在
    `@MainActor` 的 access 上、原语在 `LocalStore` 的写队列上。本任务**没有新增任何 `switch`**。
