import Foundation

func AppLogInfo(_ message: String) {}
enum PhiSyncEntity { static let dataTypeID = 2000 }

/// Production enrollment, gate and pull-entry replay logic; only storage is replaced.
final class SpaceReplayFixture {
    struct Table: Equatable {
        var spaceSectionEnabled = true
        var markerMovedWhileGateShut = false
        var lastEnrollmentReplayToken: UUID?
        var hasDrainedFullReplay = true
        var drainInProgress = false
    }
    struct StopSignal { mutating func setPaired(_ paired: Bool) {} }
    enum Outcome { case ok, cursorSaveFailed }
    var stopSignal = StopSignal()
    var roundOutcome = Outcome.ok
    var spaceSectionEnabled = true
    var enrollmentSpaceReplayToken: UUID?
    var spaceStore: Bool? = true, spaceAccess: Bool? = true
    var table = Table()
    var storedMarker: Data? = Data([1])
    var failNextTableSave = false, failNextMarkerSave = false
    var requestedMarkers: [Data?] = []

    func loadSpaceTable() -> Table { table }
    func mutateSpaceTable(_ mutation: (inout Table) -> Void) -> Bool {
        var updated = table
        mutation(&updated)
        guard updated != table else { return true }
        if failNextTableSave { failNextTableSave = false; return false }
        table = updated
        return true
    }
    func persistStoredMarker(_ marker: Data?) -> Bool {
        if failNextMarkerSave { failNextMarkerSave = false; return false }
        storedMarker = marker
        return true
    }

    /* PRODUCTION_ENABLE */
    /* PRODUCTION_GATE */
    /* PRODUCTION_ARM */

    func openGate() { applySpaceGate(true) }
    func pull() -> Bool {
        /* PRODUCTION_PULL_PREFLIGHT */
        _ = spaceTableAtEntry
        requestedMarkers.append(storedMarker)
        return true
    }
}

enum ReplayFailure: Error { case assertion(String) }
@main struct SpaceReplayTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw ReplayFailure.assertion(message) }
    }
    static func main() throws {
        var bytes: Data?
        var enrollment = SyncPairingEnrollment()
        try enrollment.configure(deviceKeyID: "device", recordData: nil,
                                 saveRecord: { bytes = $0; return true })
        try enrollment.setPaired(true, replaySpaces: true)
        let token = enrollment.spaceReplayToken
        try expect(token != nil, "Completion must persist its replay requirement")
        var restored = SyncPairingEnrollment()
        try restored.configure(deviceKeyID: "device", recordData: bytes, saveRecord: { _ in true })
        let interrupted = SpaceReplayFixture()
        interrupted.enrollmentSpaceReplayToken = restored.spaceReplayToken
        try expect(restored.isPaired && restored.spaceReplayToken == token,
                   "A restart before activation must restore the same replay requirement")
        try expect(interrupted.pull() && interrupted.requestedMarkers[0] == nil,
                   "Startup must replay even if the completion notification never ran")
        let consumed = SpaceReplayFixture()
        consumed.enrollmentSpaceReplayToken = restored.spaceReplayToken
        consumed.table.lastEnrollmentReplayToken = token
        try expect(consumed.pull() && consumed.requestedMarkers[0] != nil,
                   "A consumed token must not replay on every restart")
        try restored.setPaired(false)
        try expect(restored.spaceReplayToken == nil, "Unpairing must withdraw the old request")

        let legacy = SpaceReplayFixture()
        legacy.enableAfterPairing()
        legacy.openGate()
        try expect(legacy.storedMarker != nil, "Legacy activation must preserve its cursor")

        let setup = SpaceReplayFixture()
        setup.enableAfterPairing(replayToken: UUID())
        setup.openGate()
        try expect(setup.storedMarker == nil && setup.table.drainInProgress,
                   "Completing setup replays even if the gate stayed open")
        setup.storedMarker = Data([2])
        setup.table.hasDrainedFullReplay = true
        setup.table.drainInProgress = false
        setup.openGate()
        try expect(setup.storedMarker == Data([2]), "A completed replay must not repeat")

        let tableFailure = SpaceReplayFixture()
        tableFailure.enableAfterPairing(replayToken: UUID())
        tableFailure.failNextTableSave = true
        tableFailure.openGate()
        try expect(tableFailure.storedMarker != nil, "A failed replay latch must preserve the cursor")
        tableFailure.failNextTableSave = true
        try expect(!tableFailure.pull() && tableFailure.requestedMarkers.isEmpty,
                   "A repeated latch failure must block the old incremental request")
        try expect(tableFailure.pull() && tableFailure.requestedMarkers.count == 1
                   && tableFailure.requestedMarkers[0] == nil,
                   "The next live pull must retry the enrollment replay without another gate event")

        let markerFailure = SpaceReplayFixture()
        markerFailure.enableAfterPairing(replayToken: UUID())
        markerFailure.failNextMarkerSave = true
        markerFailure.openGate()
        try expect(markerFailure.table.markerMovedWhileGateShut && markerFailure.storedMarker != nil,
                   "Marker failure must keep the durable replay latch")
        let restarted = SpaceReplayFixture()
        restarted.table = markerFailure.table
        restarted.storedMarker = markerFailure.storedMarker
        try expect(restarted.pull() && restarted.requestedMarkers[0] == nil,
                   "A persisted latch must recover across engine restart")
        print("PASS Space replay: setup versus legacy, one-shot replay, table/marker failure and restart")
    }
}
