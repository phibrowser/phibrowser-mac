import XCTest
@testable import Phi

@MainActor final class ChromiumSyncStatusTests: XCTestCase {
    func testMissingCapabilityAndFuturePayloadStayUnknown() {
        XCTAssertEqual(ChromiumSyncStatus.decode(nil, profileID: "p", revision: 1).status.phase, .checking)
        XCTAssertEqual(ChromiumSyncStatus.decode(["version": 2, "phase": "upToDate", "enabled_categories": []], profileID: "p", revision: 1).status.phase, .checking)
    }

    func testSuccessNeedsATimestampAndKnownCapabilities() {
        let result = ChromiumSyncStatus.decode(["version": 1, "phase": "upToDate", "enabled_categories": ["history", "passwords"]], profileID: "p", revision: 2)
        XCTAssertEqual(result.status.phase, .checking)
        XCTAssertEqual(result.enabledCategories, ["history"])
    }
}
