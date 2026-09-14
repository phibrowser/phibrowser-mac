// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

/// `LocalStoreActor.perform(_:)` 的失败路径。
///
/// `LocalStoreActor` 是一个 `@ModelActor`，整个进程的后台写共用它那**一个**
/// `modelContext`；`performBackgroundWrite` / `…AndWait` / `…AndWaitThrowing` 三条入口又都
/// 经同一条 FIFO 队列排到它身上。所以「一次写失败之后上下文是什么状态」不是那一次写自己的
/// 事，而是此后**每一次**写的前提。
@MainActor
final class LocalStoreWriteRollbackTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// 一次 save 失败的写之后，**下一次普通写照样落盘**。
    ///
    /// 防的是什么：`perform(_:)` 的 catch 一度只记一行日志、**不 rollback**，而它的 throwing
    /// 兄弟 `performThrowing` 从第一天起就 rollback。坏掉的那一批改动于是原样留在共享上下文
    /// 里，此后每一次 save 都带着它重试并同样失败——一条 fire-and-forget 的 UI 写就此让全部
    /// 后台写（同步落地也在内）持续失败，直到别处某个 throwing 写碰巧把它 rollback 掉。
    /// Mac B 2026-09-14 的现场里这个窗口是 19 秒，期间用户的两次取消固定被静默吞掉，一次
    /// Space 落地连带失败。
    ///
    /// 坏写的形状照现场那一个：给一个**还没 insert** 的 `TabDataModel` 写 `profile`。
    /// `ProfileModel.tabs` 是那一笔的 inverse，SwiftData 只能为它现造一个六个必填列全空的
    /// 替身登记进上下文，save 于是整批校验失败（NSCocoaErrorDomain 1560）。
    ///
    /// **这是一条 characterisation 用例，不是探针。** 它钉的是「上一次写失败之后下一次写
    /// 照样落盘」这条不变量。它**不能保证**在修复之前会红：那要求①那次 save 真的失败，而
    /// 替身什么时候被物化进 Core Data 上下文，调查（§6）没能定位——现场那一批是在迁移的
    /// save 成功之后约 100 秒才开始发作的。①成功时这条用例照样绿，只是那一轮没有验到
    /// rollback。
    ///
    /// 唯一在这里的**载荷**是②那条断言。下面「空 guid 一条都没有」那一条是兜底：按调查的
    /// 结论替身在两种结局下都到不了盘上，所以它不可能变红，留着只为万一真的发生时有人喊。
    func testAFailedWriteDoesNotPoisonTheNextWrite() async throws {
        let store = try makeStore()

        // ① 坏写。`perform` 不抛，失败只在日志里，所以这里没有可断言的返回值——载荷全在②。
        await store.performBackgroundWriteAndWait { context in
            let profiles = (try? context.fetch(FetchDescriptor<ProfileModel>())) ?? []
            guard let profile = profiles.first else { return }
            let orphan = TabDataModel(
                title: "Orphan",
                guid: "orphan",
                index: 0,
                url: URL(string: "https://orphan.example")!,
                favicon: nil,
                createdDate: Date(timeIntervalSince1970: 1_000),
                updatedDate: Date(timeIntervalSince1970: 1_000)
            )
            orphan.dataType = .pinnedTab
            // **故意**先写关系、永不 insert：这一笔经 inverse 反向登记出一个空白替身。
            orphan.profile = profile
        }

        // ② 载荷：一次完全正常的写。没有 rollback 的话，①留下的替身会让这一次 save 也整批
        // 失败，于是这一行永远不落盘。
        await store.performBackgroundWriteAndWait { context in
            let model = TabDataModel(
                title: "Healthy",
                guid: "healthy",
                index: 0,
                url: URL(string: "https://healthy.example")!,
                favicon: nil,
                createdDate: Date(timeIntervalSince1970: 2_000),
                updatedDate: Date(timeIntervalSince1970: 2_000)
            )
            model.dataType = .pinnedTab
            context.insert(model)
        }

        XCTAssertEqual(store.getTab(by: "healthy")?.title, "Healthy",
                      "上一次写失败不该让这一次跟着失败")
        XCTAssertNil(store.getTab(by: "orphan"), "坏写自己当然不落盘")
        XCTAssertTrue(store.getAllTabs().allSatisfy { !$0.guid.isEmpty },
                      "空白替身一条都没有落盘")
    }

    // MARK: - Fixtures

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: "Default"))
        try context.save()
        return store
    }
}
