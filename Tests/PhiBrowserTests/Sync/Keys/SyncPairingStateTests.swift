import XCTest
@testable import Phi

final class SyncPairingStateTests: XCTestCase {
    func testRejectedCompletionDoesNotReleaseEnrollment() throws {
        var enrollment = SyncPairingEnrollment()
        try enrollment.configure(deviceKeyID: "device", recordData: nil, saveRecord: { _ in false })
        XCTAssertThrowsError(try enrollment.setPaired(true))
        XCTAssertFalse(enrollment.isPaired)
    }

    func testRestoredCompletionIsBoundToDevice() throws {
        let bytes = try JSONEncoder().encode(SyncPairingRecord(version: 1, deviceKeyID: "old", paired: true))
        var enrollment = SyncPairingEnrollment()
        try enrollment.configure(deviceKeyID: "new", recordData: bytes, saveRecord: { _ in true })
        XCTAssertFalse(enrollment.isPaired)
    }
}
