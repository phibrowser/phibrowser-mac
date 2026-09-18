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
