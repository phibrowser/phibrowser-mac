import XCTest
@testable import Phi

/// R-M3-4a-83, first boundary: return values and rollback for all six AccountUserDefaults write APIs.
///
/// Make the directory read-only to force real `persistLocked` failures; in-memory fakes cannot cover
/// this (also used by the production-store tests in SpaceSyncMappingManagerTests). An `.atomic` write
/// needs a temporary file in the same directory: mode 0o500 preserves reads and deterministically
/// fails writes for the non-root test process.
///
/// Each case uses a random userID under FileSystemUtils.phiBrowserDataDirectory()/users/<uuid>/.
/// tearDown restores permissions before deleting that subtree; reversing the order leaves residue.
final class AccountUserDefaultsRollbackTests: XCTestCase {

    /// Codable payload for CASE 2a.6.
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
        // userDefaults is lazy; this access creates the defaults/ directory.
        _ = account.userDefaults
        return account
    }

    private static func defaultsDirectory(for account: Account) -> URL {
        account.userDataStorage.appendingPathComponent("defaults", isDirectory: true)
    }

    private static func plistURL(for account: Account) -> URL {
        defaultsDirectory(for: account).appendingPathComponent("account_defaults.plist")
    }

    /// 0o500 allows reads and traversal but blocks the temporary file required by `.atomic` writes.
    private static func setDefaultsDirectoryWritable(_ writable: Bool, for account: Account) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o700 : 0o500],
            ofItemAtPath: defaultsDirectory(for: account).path)
    }

    private func setWritable(_ writable: Bool, for account: Account) throws {
        try Self.setDefaultsDirectoryWritable(writable, for: account)
    }

    // MARK: - CASE 2a.1

    /// CASE 2a.1: set(_:forKey:) with a String key rolls back failed disk writes.
    /// Returning failure without rollback leaves object(forKey:) at v2 while disk remains v1,
    /// the cause of the second-round failure after a plist write error in §2.7.
    func testAFailedWriteRollsBackTheStringKeyFace() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        XCTAssertTrue(defaults.set("v1", forKey: "k"))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.set("v2", forKey: "k"), "A failed disk write returns false")
        XCTAssertEqual(defaults.object(forKey: "k") as? String, "v1",
                       "Memory returns to the pre-write state and never gets ahead of disk")

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.set("v3", forKey: "k"))
        XCTAssertEqual(defaults.object(forKey: "k") as? String, "v3")
        XCTAssertEqual(AccountUserDefaults(account: account).string(forKey: "k"), "v3",
                       "A fresh instance for the same account reads the persisted value")
    }

    // MARK: - CASE 2a.2

    /// CASE 2a.2: the same contract for set(_:forKey: DefaultsKey).
    /// B2-13 requires checking both overloads: each has its own queue.sync block,
    /// and the type system cannot detect a missing rollback in one of them.
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

    /// CASE 2a.3: failed removeObject(forKey:) leaves no partial deletion.
    /// A forwarding implementation that calls set(nil, forKey: key) without returning its result
    /// would always report true.
    func testAFailedRemoveObjectLeavesTheValueInPlaceAndReportsIt() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        XCTAssertTrue(defaults.set("v1", forKey: "k"))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.removeObject(forKey: "k"))
        XCTAssertEqual(defaults.object(forKey: "k") as? String, "v1", "Deletion cannot partially succeed")

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.removeObject(forKey: "k"))
        XCTAssertNil(defaults.object(forKey: "k"))
        XCTAssertNil(AccountUserDefaults(account: account).object(forKey: "k"))
    }

    // MARK: - CASE 2a.4

    /// CASE 2a.4: both outcomes of set(_:forCodableKey:).
    /// AccountPhiSpaceSyncStateStore.save and both mapping stores share this forwarding chain;
    /// without propagating the result, all three stores report incorrect Bool values.
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

    /// CASE 2a.5: failed removeAll() restores the entire dictionary.
    /// The other five APIs cannot detect rollback that restores only the touched key;
    /// here that bug makes all account preferences disappear from memory.
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

    /// CASE 2a.6: the three CAS branches of set(_:forCodableKey:ifCurrentDataEquals:).
    /// The result means changed AND persisted, rather than merely called. The sole caller,
    /// the avatar cache in Account.swift, discards it and must retain its behavior. Only (c)
    /// returns true; previously (a)=false, (b)=true, (c)=true. Branch (b) was a false positive
    /// that changed memory without changing disk.
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

        // (a) No match: no changes and no disk writes.
        XCTAssertFalse(defaults.set(p2, forCodableKey: "p", ifCurrentDataEquals: Data([0x09])))
        XCTAssertEqual(defaults.data(forKey: "p"), d1)
        let modifiedAfter = try FileManager.default
            .attributesOfItem(atPath: plist.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter, "The nonmatching branch must not write any bytes")

        // (b) Match followed by disk failure rolls back; this previously returned true.
        try setWritable(false, for: account)
        XCTAssertFalse(defaults.set(p2, forCodableKey: "p", ifCurrentDataEquals: d1))
        XCTAssertEqual(defaults.data(forKey: "p"), d1, "Rollback leaves P1 in memory")

        // (c) Match and successful persistence returns true.
        try setWritable(true, for: account)
        XCTAssertTrue(defaults.set(p2, forCodableKey: "p", ifCurrentDataEquals: d1))
        let stored: Payload? = defaults.codableValue(forKey: "p")
        XCTAssertEqual(stored, p2)
        let fromDisk: Payload? = AccountUserDefaults(account: account).codableValue(forKey: "p")
        XCTAssertEqual(fromDisk, p2)
    }
}
