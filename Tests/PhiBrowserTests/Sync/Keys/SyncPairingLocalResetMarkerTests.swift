// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The `sync.pairingLocalReset` resume marker and its clearing hooks
/// (docs/sync.md, "Replacing this Mac's data at pairing").
@MainActor
final class SyncPairingLocalResetMarkerTests: XCTestCase {
    /// One account's defaults key.
    final class Slot {
        var data: Data?
        var failWrites = false
        var writes = 0
        lazy var store = SyncPairingLocalResetMarkerStore(
            readData: { self.data },
            writeData: { value in
                self.writes += 1
                guard !self.failWrites else { return false }
                self.data = value
                return true
            })
    }

    private let marker = SyncPairingLocalResetMarker(deviceKeyID: "device-a", deleteProfileIds: ["Profile 2"],
                                                     startedAtMs: 1_760_000_000_000)

    func testTheMarkerRoundTripsForItsDeviceKeyOnly() throws {
        let slot = Slot()
        XCTAssertNil(slot.store.load(deviceKeyID: "device-a"))
        try slot.store.save(marker)

        XCTAssertEqual(slot.store.load(deviceKeyID: "device-a"), marker)
        XCTAssertNil(slot.store.load(deviceKeyID: "device-b"), "a marker from another device key is ignored")
        XCTAssertNil(slot.store.load(deviceKeyID: ""))
    }

    func testUnreadableOrNewerMarkersAreIgnored() {
        let slot = Slot()
        slot.data = Data("not json".utf8)
        XCTAssertNil(slot.store.load(deviceKeyID: "device-a"))
        slot.data = Data(#"{"v":2,"deviceKeyID":"device-a","deleteProfileIds":[],"startedAtMs":1}"#.utf8)
        XCTAssertNil(slot.store.load(deviceKeyID: "device-a"))
        slot.data = Data(#"{"v":1,"deviceKeyID":"device-a","deleteProfileIds":["P"],"startedAtMs":1}"#.utf8)
        XCTAssertEqual(slot.store.load(deviceKeyID: "device-a")?.deleteProfileIds, ["P"])
    }

    func testAFailedWriteThrowsAndClearIsIdempotent() throws {
        let slot = Slot()
        slot.failWrites = true
        XCTAssertThrowsError(try slot.store.save(marker))
        slot.failWrites = false
        try slot.store.save(marker)

        XCTAssertTrue(slot.store.clear())
        XCTAssertNil(slot.data)
        let writes = slot.writes
        XCTAssertTrue(slot.store.clear(), "clearing an absent marker succeeds")
        XCTAssertEqual(slot.writes, writes, "and writes nothing")
    }

    /// The key is account-scoped: another account's defaults never see this account's marker, so
    /// an account switch needs no clearing and switching back still resumes.
    func testTheMarkerIsScopedToItsAccountsDefaults() throws {
        let accountA = Slot(), accountB = Slot()
        try accountA.store.save(marker)
        XCTAssertNil(accountB.store.load(deviceKeyID: "device-a"))
        XCTAssertEqual(accountA.store.load(deviceKeyID: "device-a"), marker)
    }

    // MARK: - Gate hooks

    func testCompletingEnrollmentClearsTheMarker() throws {
        let slot = Slot()
        try slot.store.save(marker)
        let gate = ProfilePairingGate()
        try gate.configureEnrollment(deviceKeyID: "device-a", recordData: nil, saveRecord: { _ in true },
                                     clearLocalResetMarker: { slot.store.clear() })
        try gate.beginEnrollment()
        XCTAssertNotNil(slot.store.load(deviceKeyID: "device-a"), "starting setup again keeps the marker")

        try gate.completeEnrollment(verifiedDeviceKeyID: "device-a")

        XCTAssertTrue(gate.isPaired)
        XCTAssertNil(slot.data)
    }

    func testAFailedCompletionAndFinishLaterKeepTheMarker() throws {
        let slot = Slot()
        try slot.store.save(marker)
        let gate = ProfilePairingGate()
        try gate.configureEnrollment(deviceKeyID: "device-a", recordData: nil, saveRecord: { _ in false },
                                     clearLocalResetMarker: { slot.store.clear() })

        XCTAssertThrowsError(try gate.completeEnrollment(verifiedDeviceKeyID: "device-a"))
        gate.finishLater()

        XCTAssertFalse(gate.isPaired)
        XCTAssertEqual(slot.store.load(deviceKeyID: "device-a"), marker)
    }

    /// Every path to a persisted paired record clears the marker: a launch that finds the record
    /// paired (a crash between completion and the clear, or legacy verification) clears it too.
    func testConfiguringAnAlreadyPairedEnrollmentClearsTheMarker() throws {
        let slot = Slot()
        try slot.store.save(marker)
        let record = try JSONEncoder().encode(SyncPairingRecord(version: 1, deviceKeyID: "device-a", paired: true))
        let gate = ProfilePairingGate()
        try gate.configureEnrollment(deviceKeyID: "device-a", recordData: record, saveRecord: { _ in true },
                                     clearLocalResetMarker: { slot.store.clear() })
        XCTAssertTrue(gate.isPaired)
        XCTAssertNil(slot.data)
    }

    func testConfiguringAnUnpairedEnrollmentKeepsTheMarker() throws {
        let slot = Slot()
        try slot.store.save(marker)
        let gate = ProfilePairingGate()
        try gate.configureEnrollment(deviceKeyID: "device-a", recordData: nil, saveRecord: { _ in true },
                                     clearLocalResetMarker: { slot.store.clear() })
        XCTAssertEqual(slot.store.load(deviceKeyID: "device-a"), marker)
    }
}
