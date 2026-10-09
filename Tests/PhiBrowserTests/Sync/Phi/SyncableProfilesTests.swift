import SwiftProtobuf
import XCTest
@testable import Phi

final class SyncableProfilesTests: XCTestCase {

    private func name(_ value: String, at stamp: Int64) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue()
        v.stringValue = value
        v.updatedAtMs = stamp
        return v
    }

    private func entity(_ uuid: String, _ value: String, at stamp: Int64,
                        createdAtMs: Int64 = 0) -> Phi_PhiProfileEntity {
        var e = Phi_PhiProfileEntity()
        e.profileUuid = uuid
        e.name = name(value, at: stamp)
        e.createdAtMs = createdAtMs
        return e
    }

    private func table(_ uuid: String, baseline: Phi_PhiProfileEntity?,
                       localNameAtBaseline: String?,
                       pending: Phi_PhiProfileEntity? = nil) throws -> PhiSpaceSyncTable {
        var table = PhiSpaceSyncTable()
        var cursor = PhiProfileCursor()
        cursor.entityId = "e-\(uuid)"
        cursor.version = 1
        cursor.reconciled = try baseline?.serializedData()
        cursor.server = cursor.reconciled
        cursor.pendingProjection = try pending?.serializedData()
        cursor.localNameAtBaseline = localNameAtBaseline
        table.profileCursors[uuid] = cursor
        return table
    }

    private func snapshot(_ name: String, table: PhiSpaceSyncTable, now: Int64 = 5_000,
                          createdAtMs: Int64 = 0) -> Phi_PhiProfileEntity? {
        SyncableProfiles.snapshot(
            profiles: [PhiLocalProfile(profileId: "Profile 1", displayName: name, createdAtMs: createdAtMs)],
            table: table, globalUuid: { $0 == "Profile 1" ? "pu-1" : nil }, now: now)["pu-1"]
    }

    // MARK: - Snapshot

    func testAnUnmappedProfileIsNeverPublished() {
        let out = SyncableProfiles.snapshot(
            profiles: [PhiLocalProfile(profileId: "Local", displayName: "Local", createdAtMs: 0)],
            table: PhiSpaceSyncTable(), globalUuid: { _ in nil }, now: 1)
        XCTAssertTrue(out.isEmpty)
    }

    func testTheFirstPublicationStampsTheLocalNameAtZero() {
        let out = snapshot("Work", table: PhiSpaceSyncTable(), createdAtMs: 42)
        XCTAssertEqual(out?.profileUuid, "pu-1")
        XCTAssertEqual(out?.name.stringValue, "Work")
        XCTAssertEqual(out?.name.updatedAtMs, 0, "a derived name must never beat a real rename")
        XCTAssertEqual(out?.createdAtMs, 42)
    }

    func testASuffixedTwinEchoesTheAccountName() throws {
        let baseline = entity("pu-1", "Work", at: 700)
        let table = try table("pu-1", baseline: baseline, localNameAtBaseline: "Work (2)")

        let out = snapshot("Work (2)", table: table)

        XCTAssertEqual(out?.name, baseline.name, "the suffixed local name is not a rename")
    }

    func testABaselineWithNoRecordedLocalNameEchoesTheAccountName() throws {
        let baseline = entity("pu-1", "Work", at: 700)
        let table = try table("pu-1", baseline: baseline, localNameAtBaseline: nil)

        XCTAssertEqual(snapshot("Work (3)", table: table)?.name, baseline.name)
    }

    func testALocalRenameIsStampedAboveTheBaseline() throws {
        let table = try table("pu-1", baseline: entity("pu-1", "Work", at: 700), localNameAtBaseline: "Work")

        let out = snapshot("Office", table: table, now: 5_000)

        XCTAssertEqual(out?.name.stringValue, "Office")
        XCTAssertEqual(out?.name.updatedAtMs, 5_000)
    }

    func testARenameBackToTheAccountNameTakesTheBaselineStamp() throws {
        // The local name was suffixed, the user renamed it to exactly the account name.
        let table = try table("pu-1", baseline: entity("pu-1", "Work", at: 700),
                              localNameAtBaseline: "Work (2)")

        XCTAssertEqual(snapshot("Work", table: table)?.name.updatedAtMs, 700)
    }

    func testAnOfflineRenameKeepsItsEditStamp() throws {
        let pending = entity("pu-1", "Office", at: 3_000)
        let table = try table("pu-1", baseline: entity("pu-1", "Work", at: 700),
                              localNameAtBaseline: "Work", pending: pending)

        let out = snapshot("Office", table: table, now: 9_000)

        XCTAssertEqual(out?.name.updatedAtMs, 3_000, "the reconnect time must not restamp the edit")
    }

    func testDeletedParkedAndDeferredCursorsAreNotPublished() throws {
        let baseline = entity("pu-1", "Work", at: 700)
        let mutations: [(inout PhiProfileCursor) -> Void] = [
            { $0.pendingDelete = true }, { $0.deletedAtMs = 1 }, { $0.purgedAtMs = 1 },
            { $0.pendingTombstone = true }, { $0.pendingApply = Data([0x01]) },
        ]
        for mutate in mutations {
            var table = try table("pu-1", baseline: baseline, localNameAtBaseline: "Work")
            mutate(&table.profileCursors["pu-1"]!)
            XCTAssertNil(snapshot("Work", table: table))
        }
    }

    // MARK: - Merge

    func testMergeKeepsTheRemoteUnknownFields() throws {
        var remote = entity("pu-1", "Work", at: 100)
        remote = try Phi_PhiProfileEntity(serializedBytes: try remote.serializedData() + Data([0x20, 0x07]))
        let local = entity("pu-1", "Office", at: 200)

        let merged = SyncableProfiles.merge(local: local, remote: remote)

        XCTAssertEqual(merged.name.stringValue, "Office")
        XCTAssertEqual([UInt8](merged.unknownFields.data), [0x20, 0x07])
    }

    func testMergeTakesTheLaterNameAndTheEarliestNonZeroCreation() {
        let a = entity("pu-1", "Work", at: 100, createdAtMs: 0)
        let b = entity("pu-1", "Office", at: 200, createdAtMs: 900)
        let c = entity("pu-1", "Home", at: 50, createdAtMs: 400)

        let ab = SyncableProfiles.merge(local: a, remote: b)
        XCTAssertEqual(ab, SyncableProfiles.merge(local: b, remote: a))
        XCTAssertEqual(ab.name.stringValue, "Office")
        XCTAssertEqual(ab.createdAtMs, 900, "0 means unknown and never wins min()")
        XCTAssertEqual(SyncableProfiles.merge(local: ab, remote: c).createdAtMs, 400)
        XCTAssertEqual(SyncableProfiles.merge(local: a, remote: a), a)
    }
}
