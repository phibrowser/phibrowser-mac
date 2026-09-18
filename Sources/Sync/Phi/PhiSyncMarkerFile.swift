// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// 共享进度 marker 与 store birthday 的落点（M3-4a §2.10 / R-M3-4a-18）：
//
//     <account.userDataStorage>/sync/marker.json
//
// 与三张 per-kind 游标表（`bookmarks-cursors.json` / `pins-cursors.json` / 规则表）并排，
// 同一个目录，`account.userDataStorage` 就是 `<App Support>/Phi/users/<userID>`
// （`Account.swift`）。
//
// **为什么必须从 `UserDefaults.standard` 搬出来**：一次用户数据导入
// （`AppController+UserDataBackup.swift` 的 `replacePhiUserDataDirectory(withExtractedPhiAt:)`）
// 是**整目录替换**——库与三张游标表一起回退到备份那一刻。marker 若留在 `UserDefaults`
// 里就**不回退**，结果是「回退的库 + 当前的 marker」那一对：marker 说本机已经越过账户
// 的全部历史，于是本该重放的页一页都不会再来；而游标表里的身份在回退后的库里找不到行，
// 五种 kind 的差分各自把整张表判成「本机已删」，发出一批 tombstone，删掉账户上每一台
// 设备的数据。两者放进同一个目录，导入天然是一致的一组。
//
// 迁移（`PhiSyncMarkerMigration`）是一次性的：`phi.sync.marker` / `phi.sync.storeBirthday`
// 两个旧键迁进文件之后被清掉；写失败就不清键、下次启动重来。两个键本身仍然声明着
// （`PhiSyncEngine.legacyMarkerStateKeys`），账户切换与自撤销的擦除面连它们一起擦。
//
// **写入纪律**逐字同三张游标表（M3-2 §5.3 的单写者规则）：只有排进引擎 `roundQueue` 的
// Round 写它；落盘一律 `Data.write(to:options:.atomic)`，落下去的永远是一份完整的表。
// 引擎内部有一份内存镜像，写穿 + 失败回滚（`PhiSyncEngine.persistMarkerState`）。

/// `users/<sub>/sync/marker.json` 的内容（§2.10 / R-M3-4a-18）。与三张游标表并排，
/// 于是一次用户数据导入（`AppController+UserDataBackup.swift` 整目录替换）
/// 把库与 marker 一起回退，不再出现「回退的库 + 当前的 marker」那一对。
struct PhiSyncMarkerFile: Codable, Equatable {
    /// 1 = M3-4a 首版。读到更小的、或者根本读不出来 ⇒ 空表（§10：与 marker 为 nil 同义，
    /// 下一次 pull 从头重放整个 data type）。
    static let currentFormatVersion = 1
    var formatVersion: Int = currentFormatVersion
    /// 不透明的 `DataTypeProgressMarker.token`。nil = 从头重放整个 data type。
    ///
    /// `Data?` 而不是 `Data`：「没有水位」（重放）与「零长度水位」（越过）必须分得开。
    var marker: Data?
    /// 服务端那个 store 的身份；空串 = 还不知道（与 `storedBirthday` 的约定逐字相同）。
    var storeBirthday: String = ""
}

/// `: AnyObject` —— 与 `PhiOwnedItemStateStore`（`PhiOwnedItemState.swift`）同因：
/// 引擎跨轮持有它，非 class-bound 会让「测试改了假件、引擎看得到」这个前提失效。
protocol PhiSyncMarkerStore: AnyObject {
    /// 读不出来交回一张**空的**（`marker == nil`、`storeBirthday == ""`）并且**不写回**。
    func load() -> PhiSyncMarkerFile
    /// `true` = 已落盘。§2.5 第 4 条第三个置位点读的就是它（Task 2b）。
    @discardableResult func save(_ file: PhiSyncMarkerFile) -> Bool
    /// §4.4 的自撤销：删文件，不是存一张空的。
    func deleteFile()
}

/// 账户目录下的 `marker.json`（文件头注释里的落点）。三个方法逐字照
/// `FileOwnedItemStateStore` 的形状。
final class FilePhiSyncMarkerStore: PhiSyncMarkerStore {
    /// 公开是因为测试要读它，断言「读不出来的那一路一个字节都不许写回去」。
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// **三种情形返回同一样东西**：文件不存在、字节解不开、`formatVersion` 低于
    /// `currentFormatVersion`——都是一张**空表**，并且**任何一种都不写回文件**。
    ///
    /// 不写回是这条契约里最容易被「顺手修好」掉的一半：读不出来就写一张空的回去，会把一次
    /// 真正的丢失变成一张「正常的空表」，此后再也分辨不出。§10 的「`marker.json` 丢失 /
    /// 解不开 = marker 为 nil = 下一次 pull 从头重放」这条自愈路径要成立，前提就是这里的
    /// 失败方向是**空表 + 不写回**。
    ///
    /// 三种情形合在一个 `guard` 里，是因为它们的**结论**逐字相同；分成三个分支写出来，迟早
    /// 有一个分支被单独改成「写回去」。
    func load() -> PhiSyncMarkerFile {
        guard let bytes = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PhiSyncMarkerFile.self, from: bytes),
              decoded.formatVersion >= PhiSyncMarkerFile.currentFormatVersion else {
            return PhiSyncMarkerFile()
        }
        return decoded
    }

    /// 原子落盘一份**完整**的表。写失败**不重试**、回传 `false`（R-M3-4a-83）：引擎据此回滚
    /// 内存镜像，下一轮重投同一页。目录不存在时顺手建（`withIntermediateDirectories: true`），
    /// 与三张游标表走同一条路。
    ///
    /// R12：日志里只有 `has_marker=<Bool>` 与错误元数据；marker 字节、birthday 串一律不进日志。
    @discardableResult
    func save(_ file: PhiSyncMarkerFile) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
            return true
        } catch {
            AppLogError("[phi-sync] marker save failed has_marker=\(file.marker != nil) "
                + "(\(PhiSyncLog.describe(error)))")
            return false
        }
    }

    func deleteFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            AppLogWarn("[phi-sync] marker delete failed (\(PhiSyncLog.describe(error)))")
        }
    }
}

/// 只给测试与「还没接线」的构造点用：引擎的 `markerStore` 为 nil 时的回落实现，
/// 读写的正是 `PhiSyncEngine.markerStateKey` / `storeBirthdayStateKey` 两个旧键，
/// 空值一律 `removeObject`（与 M3-4a 之前 `writeState` 的 nil 语义逐字相同）。
///
/// 存在的理由是「既有用例一条不改」：`storedMarker` / `storedBirthday` 的断言散在四个测试
/// 文件约四十处，读的都是自己那个 suite 里的这两个键。生产永不落进这一支——`markerStore`
/// 的唯一生产构造点 `PhiChromiumCoordinator.buildPhiSyncEngine` 必传 `FilePhiSyncMarkerStore`，
/// 所以「marker 不住在 `UserDefaults` 里」在生产上是构造点保证的；这一支最坏也只是退回
/// M3-4a 之前的形状，不是一个新的坏状态。
final class DefaultsBackedPhiSyncMarkerStore: PhiSyncMarkerStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> PhiSyncMarkerFile {
        PhiSyncMarkerFile(marker: defaults.data(forKey: PhiSyncEngine.markerStateKey),
                          storeBirthday: defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey) ?? "")
    }

    @discardableResult
    func save(_ file: PhiSyncMarkerFile) -> Bool {
        write(file.marker, forKey: PhiSyncEngine.markerStateKey)
        write(file.storeBirthday.isEmpty ? nil : file.storeBirthday,
              forKey: PhiSyncEngine.storeBirthdayStateKey)
        return true
    }

    /// 「删文件」在这一支上就是把两个键去掉——与收缩之前 `stateKeys` 的擦除对它们做的一样。
    func deleteFile() {
        for key in PhiSyncEngine.legacyMarkerStateKeys { defaults.removeObject(forKey: key) }
    }

    private func write(_ value: Any?, forKey key: String) {
        guard let value else { return defaults.removeObject(forKey: key) }
        defaults.set(value, forKey: key)
    }
}

enum PhiSyncMarkerMigration {
    /// R-M3-4a-18 的一次性迁移。幂等：文件里已经有东西 ⇒ 一个字节都不动、两个键原样留着；
    /// 两个键都空 ⇒ 什么都不做；写失败 ⇒ **不清键**、返回 false，下次启动重来。
    /// 返回值 = 「这一次真的迁移了」。
    ///
    /// 「文件不存在」的判据取 `store.load()` 交回的那张表是否为空，不取 `fileExists`：协议上
    /// 没有存在性查询，而「解不开的字节」按 §10 与 marker 为 nil 同义——此时两个旧键是仅存
    /// 的真相，迁移过去严格更好。代价是一个有界的残留：一台迁移写失败、随后引擎又把文件
    /// 写成空的机器，下次启动会把旧 marker 迁回来，多跑一轮 `NOT_MY_BIRTHDAY` 再清一次。
    ///
    /// **调用点必须排在 `resetPhiSyncCursorIfAccountChanged` 之后**：那次擦除连两个 legacy
    /// 键一起擦，否则一台迁移写失败的机器换账户之后会把上一个账户的 marker 迁进新账户的
    /// 文件——服务端的 marker 是按账户发的不透明 token，新账户按它要增量等于永久漏收。
    @discardableResult
    static func migrateLegacyMarker(from defaults: UserDefaults,
                                    into store: any PhiSyncMarkerStore) -> Bool {
        let legacyMarker = defaults.data(forKey: PhiSyncEngine.markerStateKey)
        let legacyBirthday = defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey) ?? ""
        guard legacyMarker != nil || !legacyBirthday.isEmpty else { return false }
        guard store.load() == PhiSyncMarkerFile() else { return false }
        let migrated = PhiSyncMarkerFile(marker: legacyMarker, storeBirthday: legacyBirthday)
        guard store.save(migrated) else {
            // 不清键：两个键仍是仅存的真相，下次启动再来一次。
            AppLogWarn("[phi-sync] legacy marker migration deferred: marker file not written "
                + "has_marker=\(legacyMarker != nil)")
            return false
        }
        for key in PhiSyncEngine.legacyMarkerStateKeys { defaults.removeObject(forKey: key) }
        AppLogInfo("[phi-sync] migrated the legacy marker into the account directory "
            + "has_marker=\(legacyMarker != nil)")
        return true
    }
}
