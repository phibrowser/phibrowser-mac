// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// 把 pin 作用域桥接成一条同步设置的**全部**机制（§7.1）。
///
/// 作用域今天不是 `UserDefaults` 偏好，而是 SwiftData 单例行
/// `BrowserDataSettingsModel.pinnedTabScopeRawValue`，由 `LocalStore.pinnedTabScope(in:)` 读、
/// 由 `LocalStore.changePinnedTabScope(to:preferredProfileId:preferredSpaceId:)` 改。而
/// `SyncableSetting` 的 `read` / `write` 两个闭包都收一个 `UserDefaults` 并且是**同步**的，
/// `LocalStore` 的读在主 actor、写是异步的。两者接不上。
///
/// **选定的机制是镜像偏好 + 落地观察者**，不是「让 `SyncableSetting` 的闭包去读
/// `LocalStore`」——后者要把一个同步闭包变成主 actor 上的异步调用，会改到 M3-1 的设置通道
/// 本身。四段接线：
///
/// 1. 本文件的 `pinnedTabScope` 是一条**普通的** `SyncableSetting`，进 `SyncableSettings.all`。
/// 2. 本地 → 镜像：`changePinnedTabScope` 的成功路径末尾写一次镜像键。
/// 3. 每次挂载账户时按本文件的 `reseed(rowValue:into:)` 重新播种（R-M3-3-8）。
/// 4. 镜像 → 本地：协调器在 `.phiSyncedSettingsDidApply` 上的观察者跑既有的本地迁移。
///
/// 引擎自己**不读这个键**：它经 `PhiPinnedTabLocalAccess.accountScope()` 读，那是 §7.3
/// 作用域不一致判据的唯一接缝。
///
/// 放在自己的文件里而不是塞进 `SyncableSettings.swift`，因为 `reseed` 要被单测直接调用。
enum PinnedTabScopeMirror {

    /// 镜像偏好键，同时也是线上 map 的 key。值是 `PinnedTabScope.rawValue`
    /// （`"space"` / `"profile"` / `"app"`），住在 `UserDefaults.standard`——与其余可同步
    /// 设置同一个域，也正是 `AccountPhiPinnedTabAccess` 读的那个域。
    ///
    /// 字符串在 `AccountPhiPinnedTabAccess` 里另有一份**只读**副本：那一侧刻意不 import
    /// 本类型，读者与写者的耦合面就只有这个键名。
    static let key = "PhiPinnedTabScope"

    /// 一条普通的同步设置，形状照 `SyncableSettings.layoutMode`。
    ///
    /// `read` 在键缺失或值不认识时返回 **nil**，于是 `snapshot` 整条跳过这个 key：账户上
    /// 「还没发过作用域」与「作用域是 `.profile`」不是同一件事，回落成后者会让一台本机在
    /// Space 作用域的机器把 `.profile` 当成账户值发出去。播种（`reseed`）是这个键出现的
    /// 唯一入口。
    ///
    /// `write` 校验 `PinnedTabScope(rawValue:) != nil`，不认识就**静默丢弃**（一个更新的
    /// 对端）。丢弃之后 `SyncableSettings.apply` 的回读比对不相等，于是它不刷 sidecar，本机
    /// 值在下一轮被重新推上去，而不是被标成已同步。
    static let pinnedTabScope = SyncableSetting(
        key: key,
        read: { defaults in
            guard let raw = defaults.string(forKey: key),
                  PinnedTabScope(rawValue: raw) != nil else { return nil }
            var value = Phi_PhiSettingValue()
            value.stringValue = raw
            return value
        },
        write: { value, defaults in
            guard case .stringValue(let raw) = value.v,
                  PinnedTabScope(rawValue: raw) != nil else { return }
            defaults.set(raw, forKey: key)
        }
    )

    /// `reseed` 的三种结局。调用方按它决定跑不跑迁移——`reseed` 自己是同步的、不碰
    /// SwiftData，所以它能被单测直接调用。
    enum ReseedOutcome: Equatable {
        /// 键与行一致：零写入。
        case noop
        /// 键缺失：已按行写了键与两个 sidecar。
        case seeded
        /// 键与行不符：键没动，请按这个**镜像值**重跑一次本地迁移。
        case runLocalMigration(to: PinnedTabScope)
    }

    /// 挂载账户时重新播种镜像键（R-M3-3-8 / I12 / L4）。
    ///
    /// | 情形 | 动作 |
    /// |---|---|
    /// | 镜像键**缺失** | 按行写键，并同批把两个 sidecar 写成与之匹配 ⇒ `.seeded` |
    /// | 镜像键存在但**与行不符** | 键不动（账户的值是权威），返回 `.runLocalMigration` |
    /// | 镜像键与行**一致** | 零写入，sidecar 也不碰 ⇒ `.noop` |
    ///
    /// **不变量：`reseed` 永远不清 sidecar。** 清掉之后下一轮快照会把这个键当作本机新改的、
    /// 盖上 `now` 发出去——一台离线两周的机器重新挂载账户，就能把账户级作用域**倒回**两周
    /// 前的值，并拖着每一台设备重跑一次全量 pin 迁移。
    ///
    /// **键权威那一条同样有真实反例。** 镜像与行不符的两种成因在数据上无法区分：一种是跨
    /// 账户串扰（`UserDefaults.standard` 设备全局，`BrowserDataSettingsModel` 每账户一份），
    /// 另一种是「账户值已经落地、但迁移没跑完」（App 在 `apply` 与 `changePinnedTabScope`
    /// 之间被杀，或迁移抛错——`guard currentScope != newScope` 使失败在行上不留任何痕迹）。
    /// 按行改写键，第二种情形就把刚刚落地的账户值擦掉并把旧值发回去，而 §11.4 指望的正是
    /// 这条路径来重试。取「键权威 + 重跑迁移」之后，第一种情形也仍然收敛：串扰进来的那个
    /// 值会被账户的下一次快照对比纠正，代价至多是一次多余的迁移。
    ///
    /// - Parameters:
    ///   - rowValue: SwiftData 单例行上的当前作用域。
    ///   - defaults: 镜像键所在的偏好域（生产是 `UserDefaults.standard`）。
    static func reseed(rowValue: PinnedTabScope, into defaults: UserDefaults) -> ReseedOutcome {
        guard let raw = defaults.string(forKey: key),
              let mirrored = PinnedTabScope(rawValue: raw) else {
            seed(rowValue, into: defaults)
            return .seeded
        }
        guard mirrored != rowValue else { return .noop }
        return .runLocalMigration(to: mirrored)
    }

    /// 情形一的那一批写：键 + 两个 sidecar，一次写齐。
    ///
    /// **时间戳写 0，不写 `now`。** 两个 sidecar 存在的意义就是让 `snapshot` 不把这次播种
    /// 判成一次本地编辑；而 `now` 恰恰是「本地编辑」的戳，写它等于让一台从没收到过账户作用
    /// 域的机器用自己的默认值赢下对端一次真实的作用域变更。0 是这次播种的诚实取值——它背后
    /// 没有任何一次用户操作——于是任何真实编辑（走 §7.1 第 2 步，由 `snapshot` 盖上 `now`）
    /// 都稳稳赢过它；账户上一个也没有时，这个值仍然照常被推上去。两台机器同时以 0 播种不同
    /// 值时由 `lwwWinner` 的字节 tie-break 收敛，与设备无关。
    private static func seed(_ scope: PinnedTabScope, into defaults: UserDefaults) {
        var value = Phi_PhiSettingValue()
        value.stringValue = scope.rawValue
        defaults.set(scope.rawValue, forKey: key)
        defaults.set(NSNumber(value: Int64(0)), forKey: SyncableSettings.timestampKey(for: key))
        defaults.set(SyncableSettings.signature(of: value),
                     forKey: SyncableSettings.valueKey(for: key))
    }
}
