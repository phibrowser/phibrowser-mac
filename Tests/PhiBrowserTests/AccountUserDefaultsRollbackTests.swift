import XCTest
@testable import Phi

/// R-M3-4a-83 的第一个出口：`AccountUserDefaults` 六个写入面的「回传 + 回滚」。
///
/// **注入落盘失败的手法是「把目录改成只读」，不是假件。** 这六个面要验的正是**真实**的
/// `persistLocked` 失败，内存假件覆盖不到（`SpaceSyncMappingManagerTests` 的生产 store
/// 那一组已经为同一个理由写过一次）。`.atomic` 写要在同目录建临时文件，所以目录一旦是
/// `0o500`（r-x）写必然失败、读照常；**测试进程不是 root**，所以这个注入是确定的。
///
/// 每条用例一个全新的随机 userID，副作用是
/// `FileSystemUtils.phiBrowserDataDirectory()/users/<uuid>/`，在 `tearDown` 里**先恢复
/// 权限再**删掉那棵子树——顺序反过来的话只读目录删不掉，下一次跑测试会累积残留。
final class AccountUserDefaultsRollbackTests: XCTestCase {

    /// CASE 2a.6 用的 codable 载荷。
    private struct Payload: Codable, Equatable {
        var a: String
    }

    private var scratchAccounts: [Account] = []

    override func tearDown() {
        for account in scratchAccounts {
            try? Self.setDefaultsDirectoryWritable(true, for: account)
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        scratchAccounts = []
        super.tearDown()
    }

    private func makeAccount() -> Account {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        // `userDefaults` 是 lazy：这一次访问才真正建出 `defaults/` 目录。
        _ = account.userDefaults
        return account
    }

    private static func defaultsDirectory(for account: Account) -> URL {
        account.userDataStorage.appendingPathComponent("defaults", isDirectory: true)
    }

    private static func plistURL(for account: Account) -> URL {
        defaultsDirectory(for: account).appendingPathComponent("account_defaults.plist")
    }

    /// `0o500` = 可读可进入、**不可写**，于是 `.atomic` 写建不出同目录的临时文件。
    private static func setDefaultsDirectoryWritable(_ writable: Bool, for account: Account) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o700 : 0o500],
            ofItemAtPath: defaultsDirectory(for: account).path)
    }

    private func setWritable(_ writable: Bool, for account: Account) throws {
        try Self.setDefaultsDirectoryWritable(writable, for: account)
    }

    // MARK: - CASE 2a.1

    /// CASE 2a.1 — `set(_:forKey:)`（String 键）写盘失败回滚。
    ///
    /// 防的是什么：只回传不回滚的那一版——`object(forKey:)` 在第一次之后就回 `"v2"`，
    /// 而盘上还是 `"v1"`。那正是 §2.7「plist 写失败之后的第二轮」整行的病根。
    func testAFailedWriteRollsBackTheStringKeyFace() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        XCTAssertTrue(defaults.set("v1", forKey: "k"))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.set("v2", forKey: "k"), "写盘失败 ⇒ false")
        XCTAssertEqual(defaults.object(forKey: "k") as? String, "v1",
                       "内存回到写之前那一份：内存永不领先磁盘")

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.set("v3", forKey: "k"))
        XCTAssertEqual(defaults.object(forKey: "k") as? String, "v3")
        XCTAssertEqual(AccountUserDefaults(account: account).string(forKey: "k"), "v3",
                       "同一个账户上新建的实例读盘，盘上确实是它")
    }

    // MARK: - CASE 2a.2

    /// CASE 2a.2 — `set(_:forKey: DefaultsKey)` 同形。
    ///
    /// 防的是什么：B2-13 点名的「不能只点一个重载」。两个重载各有各的 `queue.sync` 块，
    /// 改一个漏一个在类型上完全无声。
    func testAFailedWriteRollsBackTheDefaultsKeyOverloadToo() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        let key = AccountUserDefaults.DefaultsKey.activeSpaceId
        XCTAssertTrue(defaults.set("v1", forKey: key))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.set("v2", forKey: key))
        XCTAssertEqual(defaults.string(forKey: key.rawValue), "v1")

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.set("v3", forKey: key))
        XCTAssertEqual(defaults.string(forKey: key.rawValue), "v3")
        XCTAssertEqual(AccountUserDefaults(account: account).string(forKey: key.rawValue), "v3")
    }

    // MARK: - CASE 2a.3

    /// CASE 2a.3 — `removeObject(forKey:)` 失败不留半删状态。
    ///
    /// 防的是什么：转发面漏掉回传（写成 `set(nil, forKey: key)` 而不 `return`）的实现，
    /// 调用方永远拿到 `true`。
    func testAFailedRemoveObjectLeavesTheValueInPlaceAndReportsIt() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        XCTAssertTrue(defaults.set("v1", forKey: "k"))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.removeObject(forKey: "k"))
        XCTAssertEqual(defaults.object(forKey: "k") as? String, "v1", "没有「半删」这个状态")

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.removeObject(forKey: "k"))
        XCTAssertNil(defaults.object(forKey: "k"))
        XCTAssertNil(AccountUserDefaults(account: account).object(forKey: "k"))
    }

    // MARK: - CASE 2a.4

    /// CASE 2a.4 — `set(_:forCodableKey:)` 的两条出路。
    ///
    /// 防的是什么：这是 `AccountPhiSpaceSyncStateStore.save` 与两张映射 store 共用的那一条
    /// 转发链；它不回传，上面三个 store 的 Bool 全是假的。
    func testAFailedCodableWriteRollsBackAndReportsFalse() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        XCTAssertTrue(defaults.set(["a": "1"], forCodableKey: "m"))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.set(["a": "2"], forCodableKey: "m"))
        let afterFailure: [String: String]? = defaults.codableValue(forKey: "m")
        XCTAssertEqual(afterFailure, ["a": "1"])

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.set(["a": "2"], forCodableKey: "m"))
        let afterSuccess: [String: String]? = defaults.codableValue(forKey: "m")
        XCTAssertEqual(afterSuccess, ["a": "2"])
        let fromDisk: [String: String]? = AccountUserDefaults(account: account)
            .codableValue(forKey: "m")
        XCTAssertEqual(fromDisk, ["a": "2"])
    }

    // MARK: - CASE 2a.5

    /// CASE 2a.5 — `removeAll()` 失败把**整张**字典还回来。
    ///
    /// 防的是什么：回滚写成「只还原被碰过的那一个键」的实现在别的五个面上看不出差别，
    /// 只有 `removeAll` 能把它照出来——而它的失败态是整份账户偏好在内存里凭空消失。
    func testAFailedRemoveAllRestoresTheWholeDictionary() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        let bytes = Data([0x01, 0x02, 0x03])
        XCTAssertTrue(defaults.set("v1", forKey: "s"))
        XCTAssertTrue(defaults.set(bytes, forKey: "d"))
        XCTAssertTrue(defaults.set(["a": "1"], forCodableKey: "m"))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.removeAll())
        XCTAssertEqual(defaults.string(forKey: "s"), "v1")
        XCTAssertEqual(defaults.data(forKey: "d"), bytes)
        let map: [String: String]? = defaults.codableValue(forKey: "m")
        XCTAssertEqual(map, ["a": "1"])

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.removeAll())
        XCTAssertNil(defaults.object(forKey: "s"))
        XCTAssertNil(defaults.object(forKey: "d"))
        XCTAssertNil(defaults.object(forKey: "m"))
    }

    // MARK: - CASE 2a.6

    /// CASE 2a.6 — CAS 面三个分支（`set(_:forCodableKey:ifCurrentDataEquals:)`）。
    ///
    /// 防的是什么：语义从「调用发生了」收口成「已改变**且**已落盘」之后，唯一调用方
    /// （`Account.swift` 的头像缓存，它今天就丢这个返回值）行为必须一字不变：三个分支里
    /// 只有 (c) 为真，与之前的 (a)=false / (b)=true / (c)=true 相比只有 (b) 变号——而 (b)
    /// 之前正是一次**假阳**，值写进了内存、没写进盘。
    func testTheCompareAndSwapFaceMeansChangedAndPersisted() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        let p1 = Payload(a: "1")
        let p2 = Payload(a: "2")
        XCTAssertTrue(defaults.set(p1, forCodableKey: "p"))
        let d1 = try XCTUnwrap(defaults.data(forKey: "p"))
        let plist = Self.plistURL(for: account)
        let modifiedBefore = try FileManager.default
            .attributesOfItem(atPath: plist.path)[.modificationDate] as? Date

        // (a) 比不中：零改动，**磁盘零写**。
        XCTAssertFalse(defaults.set(p2, forCodableKey: "p", ifCurrentDataEquals: Data([0x09])))
        XCTAssertEqual(defaults.data(forKey: "p"), d1)
        let modifiedAfter = try FileManager.default
            .attributesOfItem(atPath: plist.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter, "比不中的那一支一个字节都不许写")

        // (b) 比中但写盘失败 ⇒ 回滚。之前这里回 true。
        try setWritable(false, for: account)
        XCTAssertFalse(defaults.set(p2, forCodableKey: "p", ifCurrentDataEquals: d1))
        XCTAssertEqual(defaults.data(forKey: "p"), d1, "回滚可见：内存仍然是 P1")

        // (c) 比中且落盘 ⇒ true。
        try setWritable(true, for: account)
        XCTAssertTrue(defaults.set(p2, forCodableKey: "p", ifCurrentDataEquals: d1))
        let stored: Payload? = defaults.codableValue(forKey: "p")
        XCTAssertEqual(stored, p2)
        let fromDisk: Payload? = AccountUserDefaults(account: account).codableValue(forKey: "p")
        XCTAssertEqual(fromDisk, p2)
    }
}
