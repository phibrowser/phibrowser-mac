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
