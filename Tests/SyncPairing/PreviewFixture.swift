import CryptoKit
import Foundation

// The runner inserts the complete production runPreview method. These stand-ins isolate
// pagination from the app host; encrypted entity decoding is covered by the hosted suite.
/* PRODUCTION_PREVIEW_TYPES */
/* PRODUCTION_MARKER_TYPE */

final class PreviewMarkerStore {
    var file = PhiSyncMarkerFile()
    var failSave = false
    func save(_ file: PhiSyncMarkerFile) -> Bool {
        if failSave { return false }; self.file = file; return true
    }
}

enum PhiSyncProtocolError: Error { case notMyBirthday }
enum PhiSyncLog {
    static func describe(_ error: Error) -> String { String(describing: error) }
}
func AppLogInfo(_ message: String) {}
struct PreviewField { var stringValue = ""; var intValue: Int64 = 0 }
struct Phi_PhiSpaceEntity {
    var spaceUuid = ""
    var name = PreviewField(), iconName = PreviewField(), colorHex = PreviewField()
    var profileUuid = PreviewField(), themeID = PreviewField()
    var overlayOpacityLight = PreviewField(), overlayOpacityDark = PreviewField()
}
struct PreviewDecoded {
    enum Kind { case space(Phi_PhiSpaceEntity) }
    var kind: Kind?
}
enum PhiEntityCodec {
    static func decrypt(_ data: Data, key: SymmetricKey) throws -> PreviewDecoded {
        preconditionFailure("Pagination fixtures must not substitute for encrypted entity tests")
    }
}
enum PhiSyncEntity {
    static let settingsClientTagHash = "settings"
    static func clientTagHash(for tag: String) -> String { tag }
    static func spaceClientTag(_ uuid: String) -> String { uuid }
}
enum SyncableSpaces {
    static let defaultSpaceUuid = "default"
    static func refuses(_ space: Phi_PhiSpaceEntity) -> Bool { false }
}
struct PreviewRemoteEntity {
    let clientTagHash: String
    let deleted: Bool
    let ciphertext: Data
    let version: Int64
}
final class PreviewClient {
    var birthday = "current-server"
    var resetAfterFirstPage = false
    var failNextRequest = false
    var calls: [(marker: Data?, birthday: String)] = []
    func getUpdates(marker: Data?, storeBirthday: String) async throws
        -> (entities: [PreviewRemoteEntity], newMarker: Data, storeBirthday: String, changesRemaining: Bool) {
        calls.append((marker, storeBirthday))
        if failNextRequest { failNextRequest = false; throw URLError(.notConnectedToInternet) }
        guard storeBirthday.isEmpty || storeBirthday == birthday else {
            throw PhiSyncProtocolError.notMyBirthday
        }
        let responseBirthday = birthday
        if marker == nil, resetAfterFirstPage {
            birthday = "reset-during-preview"
            resetAfterFirstPage = false
        }
        return ([], Data([1]), responseBirthday, marker == nil)
    }
}
final class PreviewKeys {
    func domainKey() async throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}
final class PreviewFixture {
    final class PreviewBox { var result: Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>? }
    let stopSignal = EngineStopSignal(paired: false)
    let domainKeys = PreviewKeys()
    let client = PreviewClient()
    var markerState = PhiSyncMarkerFile(marker: Data([9]), storeBirthday: "old-server")
    var storedBirthday: String { markerState.storeBirthday }
    let markerStore = PreviewMarkerStore()
    let statusState = SyncStatusState()
    var requiresReconfiguration: Bool { stopSignal.requiresReconfiguration }
    var canPublishThisRound = false
    enum Outcome { case notMyBirthday }
    var roundOutcome = Outcome.notMyBirthday
    /* PRODUCTION_REQUIRE_RESET */
    var lastPreviewStats = (0, 0)
    let previewMaxPages = 400
    static let previewDeadlineMs: Int64 = 120_000
    func now() -> Int64 { 1_000 }
    func observeServerDate() {}
    /* PRODUCTION_PREVIEW */

    func preview() async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError> {
        let box = PreviewBox()
        await runPreview(into: box)
        return box.result!
    }
}

func testPreviewAfterServerReset() async throws {
    let fixture = PreviewFixture()
    guard case .failure(.transport("not_my_birthday")) = await fixture.preview() else {
        throw NSError(domain: "ExplicitResetRegression", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "A changed server must require explicit reconfiguration, not silently accept a fresh preview"])
    }
    let requests = fixture.client.calls.count
    guard case .failure(.transport("not_my_birthday")) = await fixture.preview() else {
        preconditionFailure("Ordinary Retry must not accept the changed server")
    }
    precondition(fixture.client.calls.count == requests, "A paused preview must not issue more requests")
    precondition(fixture.storedBirthday == "old-server")
    precondition(fixture.markerState.marker == Data([9]))
    precondition(fixture.markerStore.file.requiresReconfiguration == true)
    precondition(fixture.statusState.snapshot.phase == .needsAttention)
    let failedWrite = PreviewFixture()
    failedWrite.markerStore.failSave = true
    _ = await failedWrite.preview()
    _ = await failedWrite.preview()
    precondition(failedWrite.requiresReconfiguration && failedWrite.client.calls.count == 1)
    precondition(failedWrite.markerStore.file.requiresReconfiguration == nil)
    let normal = PreviewFixture()
    normal.markerState = PhiSyncMarkerFile()
    normal.client.failNextRequest = true
    guard case .failure = await normal.preview() else { preconditionFailure("Expected offline") }
    guard case .success = await normal.preview() else { preconditionFailure("Expected retry") }
    guard case .success = await normal.preview() else { preconditionFailure("Expected fresh reentry") }
    precondition(normal.client.calls.count == 5)
    precondition(normal.client.calls[3].marker == nil && normal.client.calls[3].birthday.isEmpty)
    precondition(normal.markerStore.file == PhiSyncMarkerFile())
    let paginatedReset = PreviewFixture()
    paginatedReset.markerState = PhiSyncMarkerFile()
    paginatedReset.client.resetAfterFirstPage = true
    guard case .failure(.transport("not_my_birthday")) = await paginatedReset.preview() else {
        preconditionFailure("A reset between pages must pause")
    }
    let legacy = try JSONDecoder().decode(PhiSyncMarkerFile.self,
        from: Data(#"{"formatVersion":1,"storeBirthday":"old"}"#.utf8))
    precondition(legacy.requiresReconfiguration == nil && legacy.storeBirthday == "old")
    print("PASS preview: mismatch and pagination reset pause, failed persistence pauses in memory, ordinary retry/reentry fetch fresh data")
}
