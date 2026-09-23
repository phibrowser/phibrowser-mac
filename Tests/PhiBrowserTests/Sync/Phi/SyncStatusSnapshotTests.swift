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
}
