import XCTest
@testable import Phi

final class SyncStatusSnapshotTests: XCTestCase {
    func testOlderRoundCannotClearNewLocalWork() {
        let state = SyncStatusState()
        let revision = state.update(.syncing)
        state.update(.syncing)
        state.update(.upToDate, completing: revision)
        XCTAssertEqual(state.snapshot.phase, .syncing)
        XCTAssertNil(state.snapshot.lastSuccess)
    }

    func testNativeSuccessAloneCannotReportWholeAccountSuccess() {
        let native = SyncContextSnapshot(id: "phi", phase: .upToDate, lastSuccess: Date(), revision: 1)
        XCTAssertEqual(SyncStatusSummary.reduce(paired: true, requiredIDs: ["phi", "profile"], snapshots: [native]).phase, .checking)
        XCTAssertEqual(SyncStatusSummary.reduce(paired: false, requiredIDs: ["phi"], snapshots: [native]).phase, .notStarted)
    }

    /// heldByReason follows a visited kind's table like held, is part of equality, and the reason enum
    /// round-trips through its stable raw values.
    func testHeldByReasonMergesComparesAndCodes() throws {
        let first = SyncRoundDetail(kinds: [.pinnedTabs: SyncKindStatus(
            held: 3, heldByReason: [.unmappedProfileOwner: 2, .lineageExists: 1])])
        var merged = SyncNativeDetail().merging(round: first, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(merged.kinds[.pinnedTabs]?.heldByReason, [.unmappedProfileOwner: 2, .lineageExists: 1])
        XCTAssertNotEqual(SyncKindStatus(held: 1, heldByReason: [.unknown: 1]),
                          SyncKindStatus(held: 1, heldByReason: [.storeError: 1]))
        merged = merged.merging(round: SyncRoundDetail(kinds: [.pinnedTabs: SyncKindStatus()]),
                                at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(merged.kinds[.pinnedTabs]?.heldByReason, [:], "A visited kind with nothing held clears it")

        let reasons = Dictionary(uniqueKeysWithValues: SyncHeldReason.allCases.map { ($0.rawValue, $0) })
        let decoded = try JSONDecoder().decode([String: SyncHeldReason].self, from: JSONEncoder().encode(reasons))
        XCTAssertEqual(decoded, reasons)
        XCTAssertEqual(SyncHeldReason.unmappedProfileOwner.snakeCase, "unmapped_profile_owner")
        XCTAssertEqual(PhiSyncEngine.heldByReasonLogLine("pins", [.lineageExists: 2, .unmappedProfileOwner: 1, .unknown: 0]),
                       "[phi-sync] pins held_by_reason unmapped_profile_owner=1 lineage_exists=2")
        XCTAssertNil(PhiSyncEngine.heldByReasonLogLine("pins", [:]))
    }
}
