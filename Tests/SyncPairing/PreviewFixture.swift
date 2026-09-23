import CryptoKit
import Foundation

// The runner inserts the complete production runPreview method. These stand-ins isolate
// pagination from the app host; encrypted entity decoding is covered by the hosted suite.
/* PRODUCTION_PREVIEW_TYPES */

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
    let storedBirthday = "old-server"
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
    let first = await fixture.preview()
    guard case .success = first else {
        throw NSError(domain: "PreviewRegression", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "An unpaired device with an old birthday must preview the current server: \(first)"])
    }
    precondition(fixture.client.calls.count == 2)
    precondition(fixture.client.calls[0].marker == nil && fixture.client.calls[0].birthday == "")
    precondition(fixture.client.calls[1].marker == Data([1]))
    precondition(fixture.client.calls[1].birthday == "current-server", "Pin subsequent pages to the first response's generation")
    precondition(fixture.storedBirthday == "old-server")
    precondition(fixture.stopSignal.blocksData(revision: fixture.stopSignal.revision))

    fixture.client.birthday = "another-reset"
    guard case .success = await fixture.preview() else { preconditionFailure("Each entry must start fresh") }
    precondition(fixture.client.calls[2].marker == nil && fixture.client.calls[2].birthday == "")
    precondition(fixture.client.calls[3].birthday == "another-reset")

    fixture.client.resetAfterFirstPage = true
    guard case .failure(.transport("not_my_birthday")) = await fixture.preview() else {
        preconditionFailure("A reset during pagination must fail without partial choices")
    }
    guard case .success = await fixture.preview() else { preconditionFailure("Retry must use the new generation") }
    precondition(fixture.client.calls[6].marker == nil && fixture.client.calls[6].birthday == "")
    precondition(fixture.client.calls[7].birthday == "reset-during-preview")

    fixture.client.failNextRequest = true
    guard case .failure(.transport) = await fixture.preview() else {
        preconditionFailure("Transport failure must not return cached choices")
    }
    print("PASS preview: stale birthday, fresh re-entry, pinned pagination, mid-preview reset, retry, transport failure")
}
