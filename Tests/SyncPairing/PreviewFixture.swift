import CryptoKit
import Foundation

// The runner inserts the complete production runPreview method. These stand-ins isolate
// filtering and pagination from the app host. Codec results are boundary fixtures;
// authenticated decryption remains covered by the hosted suite.
/* PRODUCTION_PREVIEW_TYPES */
/* PRODUCTION_MARKER_TYPE */

final class PreviewMarkerStore {
    var file = PhiSyncMarkerFile()
    var failSave = false
    func load() -> PhiSyncMarkerFile { file }
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
    var refused = false
    var name = PreviewField(), iconName = PreviewField(), colorHex = PreviewField()
    var profileUuid = PreviewField(), themeID = PreviewField()
    var overlayOpacityLight = PreviewField(), overlayOpacityDark = PreviewField()
}
struct Phi_PhiProfileEntity {
    var profileUuid = ""
    var name = PreviewField()
}
struct Phi_PhiBookmarkEntity {
    var bookmarkUuid = ""
    var parentUuid = PreviewField(), spaceUuid = PreviewField()
    var isFolder = false
}
struct Phi_PhiPinTabEntity {
    enum OneOf_Owner { case spaceUuid(String), profileUuid(String) }
    var owner: OneOf_Owner?
}
struct Phi_PhiURLRuleEntity { var targetSpaceUuid = PreviewField() }
struct PreviewDecoded {
    enum Kind {
        case space(Phi_PhiSpaceEntity), profile(Phi_PhiProfileEntity)
        case bookmark(Phi_PhiBookmarkEntity), pinTab(Phi_PhiPinTabEntity), urlRule(Phi_PhiURLRuleEntity)
    }
    var kind: Kind?
}
enum PhiEntityCodec {
    static var decoded: [Data: PreviewDecoded] = [:]
    static func decrypt(_ data: Data, key: SymmetricKey) throws -> PreviewDecoded {
        guard let value = decoded[data] else { throw NSError(domain: "Unreadable fixture", code: 1) }
        return value
    }
}
enum PhiSyncEntity {
    static let settingsClientTagHash = "settings"
    static func clientTagHash(for tag: String) -> String { tag }
    static func spaceClientTag(_ uuid: String) -> String { uuid }
    static func profileClientTag(_ uuid: String) -> String { "phi-profile:" + uuid }
    static func bookmarkClientTag(_ uuid: String) -> String { "phi-bookmark:" + uuid }
}
enum SyncableSpaces {
    static let defaultSpaceUuid = "default"
    static func refuses(_ space: Phi_PhiSpaceEntity) -> Bool { space.refused }
}
struct PreviewRemoteEntity {
    let clientTagHash: String
    let deleted: Bool
    let ciphertext: Data
    let version: Int64
}
final class PreviewClient {
    var entities: [PreviewRemoteEntity] = []
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
        return (marker == nil ? entities : [], Data([1]), responseBirthday, marker == nil)
    }
}

func testPreviewCompleteness() async throws {
    let fixture = PreviewFixture()
    fixture.markerState = PhiSyncMarkerFile()
    var valid = Phi_PhiSpaceEntity(); valid.spaceUuid = "valid"
    var refused = Phi_PhiSpaceEntity(); refused.spaceUuid = "refused"; refused.refused = true
    var defaultSpace = Phi_PhiSpaceEntity(); defaultSpace.spaceUuid = "default"
    var renamed = Phi_PhiProfileEntity(); renamed.profileUuid = "p1"; renamed.name.stringValue = "Alpha"
    var older = Phi_PhiProfileEntity(); older.profileUuid = "p1"; older.name.stringValue = "P168-1"
    PhiEntityCodec.decoded = [
        Data([1]): PreviewDecoded(kind: .space(valid)),
        Data([2]): PreviewDecoded(kind: .space(refused)),
        Data([3]): PreviewDecoded(kind: nil),
        Data([4]): PreviewDecoded(kind: .bookmark(Phi_PhiBookmarkEntity())),
        Data([5]): PreviewDecoded(kind: .space(defaultSpace)),
        Data([6]): PreviewDecoded(kind: .profile(renamed)),
        Data([7]): PreviewDecoded(kind: .profile(older))
    ]
    defer { PhiEntityCodec.decoded = [:] }
    func row(_ hash: String, _ data: UInt8, deleted: Bool = false, version: Int64 = 1) -> PreviewRemoteEntity {
        PreviewRemoteEntity(clientTagHash: hash, deleted: deleted, ciphertext: Data([data]), version: version)
    }
    fixture.client.entities = [row("valid", 1), row("invalid", 9), row("wrong-tag", 1),
        row("refused", 2), row("unknown", 3), row("bookmark", 4), row("default", 5),
        row("settings", 9), row("deleted", 9, deleted: true),
        row("phi-profile:p1", 6, version: 3), row("phi-profile:p1", 7, version: 2), row("phi-profile:other", 6)]
    guard case .success(let preview) = await fixture.preview() else {
        preconditionFailure("Readable choices must remain available")
    }
    precondition(preview.spaces.map(\.syncUuid) == ["valid"])
    precondition(preview.skippedEntityCount == 5,
                 "Unreadable, wrong-tag, refused, unknown and mis-tagged Profile entities must prevent absence claims")
    precondition(preview.deletedProfileTagHashes == ["deleted"])
    precondition(preview.profileNames == ["p1": "Alpha"],
                 "A Profile is named from its highest-version entity; a payload that does not hash back is not a name")
    precondition(preview.bookmarkCount == nil && preview.pinnedTabCount == nil && preview.urlRuleCount == nil,
                 "An undecryptable entity could be of any counted kind")
    precondition(fixture.markerStore.file == PhiSyncMarkerFile(), "Preview must remain read-only")
    print("PASS preview completeness: skipped unknown/unreadable/refused entities retain uncertainty")
}
func testPreviewItemCounts() async throws {
    let fixture = PreviewFixture()
    fixture.markerState = PhiSyncMarkerFile()
    func bookmark(_ uuid: String, parent: String = "", space: String = "live",
                  folder: Bool = false) -> PreviewDecoded {
        var entity = Phi_PhiBookmarkEntity(); entity.bookmarkUuid = uuid; entity.isFolder = folder
        entity.parentUuid.stringValue = parent; entity.spaceUuid.stringValue = space
        return PreviewDecoded(kind: .bookmark(entity))
    }
    func pin(_ owner: Phi_PhiPinTabEntity.OneOf_Owner?) -> PreviewDecoded {
        var entity = Phi_PhiPinTabEntity(); entity.owner = owner
        return PreviewDecoded(kind: .pinTab(entity))
    }
    func rule(_ target: String) -> PreviewDecoded {
        var entity = Phi_PhiURLRuleEntity(); entity.targetSpaceUuid.stringValue = target
        return PreviewDecoded(kind: .urlRule(entity))
    }
    var liveSpace = Phi_PhiSpaceEntity(); liveSpace.spaceUuid = "live"
    var agent = Phi_PhiSpaceEntity(); agent.spaceUuid = "agent"; agent.refused = true
    PhiEntityCodec.decoded = [
        Data([1]): bookmark("b1"), Data([2]): bookmark("b2"), Data([3]): bookmark("f1", folder: true),
        Data([4]): bookmark("b3"), Data([5]): bookmark("b4"), Data([6]): bookmark("b5"),
        Data([7]): bookmark("child", parent: "f1", space: "dead"),     // Root Space decides
        Data([8]): bookmark("deadRoot", space: "dead"),
        Data([9]): bookmark("fDead", space: "dead", folder: true),
        Data([10]): bookmark("deadChild", parent: "fDead", space: "live"),
        Data([11]): bookmark("lifted", parent: "gone", space: "live"),  // Deleted parent: lifted
        Data([12]): bookmark("orphan", parent: "missing", space: "live"), // Absent parent: parked
        Data([13]): bookmark("agentRoot", space: "agent"),
        Data([20]): pin(.spaceUuid("live")), Data([21]): pin(.spaceUuid("dead")),
        Data([22]): pin(.profileUuid("p-live")), Data([23]): pin(.profileUuid("p-dead")), Data([24]): pin(nil),
        Data([30]): rule("live"), Data([31]): rule("dead"), Data([32]): rule("agent"), Data([33]): rule(""),
        Data([40]): PreviewDecoded(kind: nil),
        Data([50]): PreviewDecoded(kind: .space(liveSpace)), Data([51]): PreviewDecoded(kind: .space(agent))
    ]
    defer { PhiEntityCodec.decoded = [:] }
    func row(_ hash: String, _ data: UInt8, deleted: Bool = false, version: Int64 = 1) -> PreviewRemoteEntity {
        PreviewRemoteEntity(clientTagHash: hash, deleted: deleted, ciphertext: Data([data]), version: version)
    }
    fixture.client.entities = [
        row("live", 50), row("agent", 51),
        row("b1", 1), row("b1", 1, version: 2), row("b2", 2), row("f1", 3), row("child", 7),
        row("b3", 4), row("b3", 99, deleted: true, version: 2),
        // A higher-version tombstone delivered before an older live version stays the latest.
        row("b4", 99, deleted: true, version: 3), row("b4", 5, version: 1),
        row("b5", 99, deleted: true, version: 1), row("b5", 6, version: 3),
        row("deadRoot", 8), row("fDead", 9), row("deadChild", 10), row("lifted", 11),
        row("phi-bookmark:gone", 99, deleted: true), row("orphan", 12), row("agentRoot", 13),
        row("p1", 20), row("p2", 20), row("p2", 20), row("p3", 21), row("p4", 22), row("p5", 23), row("p6", 24),
        row("r1", 30), row("r2", 31), row("r3", 32), row("r4", 33), row("unknown", 40),
        row("stale", 99, version: 1), row("stale", 30, version: 2),
        // Owner tombstones on the last page: the filter is a post-pass.
        row("dead", 99, deleted: true), row("phi-profile:p-dead", 99, deleted: true)]
    guard case .success(let preview) = await fixture.preview() else { preconditionFailure("Expected success") }
    precondition(preview.bookmarkCount == 5, "b1, b2, child, b5 and lifted; got \(String(describing: preview.bookmarkCount))")
    precondition(preview.pinnedTabCount == 4, "Live Space twice, live Profile, App scope; got \(String(describing: preview.pinnedTabCount))")
    precondition(preview.urlRuleCount == 2, "Live targets only; got \(String(describing: preview.urlRuleCount))")
    precondition(fixture.markerStore.file == PhiSyncMarkerFile(), "Preview must remain read-only")
    print("PASS preview counts: per kind, deduped by client tag hash, tombstones, folders and items of deleted or refused owners excluded")
}
final class PreviewKeys {
    func domainKey() async throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}
final class PreviewFixture {
    final class PreviewBox { var result: Result<PhiAccountSpacePreview, PhiSpacePreviewError>? }
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

    func preview() async -> Result<PhiAccountSpacePreview, PhiSpacePreviewError> {
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
