import Foundation

/* PRODUCTION_MARKER_TYPE */
enum NativeSyncResetError: Error { case cleanupFailed }
/* PRODUCTION_KEY_API_ERROR */
func AppLogInfo(_ message: String) {}
enum PhiSyncLog { static func describe(_ error: Error) -> String { "\(type(of: error))" } }
enum PhiSyncEngine {
    static let stateKeys = ["phi.sync.entityId", "phi.sync.version"]
    static let legacyMarkerStateKeys = ["phi.sync.marker", "phi.sync.storeBirthday"]
}
enum SyncableSettings {
    static let timestampSuffix = ".phiSyncTs"
    static let valueSuffix = ".phiSyncVal"
}
enum PhiDefaultSpaceMirror { static let key = "defaultSpaceMirror" }
struct PhiSpaceSyncTable: Equatable { var entries = 0 }
protocol PhiProfileDeletionIntentStore: AnyObject {
    func load() -> [String: String]
    @discardableResult func save(_ intents: [String: String]) -> Bool
}
/// The cleanup clears the Profile deletion journal with the cursors it describes.
final class ResetIntentStore: PhiProfileDeletionIntentStore {
    var intents = ["uuid": "Profile 2"]
    var failSave = false
    func load() -> [String: String] { intents }
    func save(_ value: [String: String]) -> Bool {
        if failSave { return false }; intents = value; return true
    }
}
final class PhiSpaceSyncState {
    static let shared = PhiSpaceSyncState()
    var profileDeletionIntentStore: (any PhiProfileDeletionIntentStore)?
    func refreshCaches(from table: PhiSpaceSyncTable) {}
}
final class ResetMarkerStore {
    var file = PhiSyncMarkerFile(marker: Data([9]), storeBirthday: "old", requiresReconfiguration: true)
    var failSave = false
    func load() -> PhiSyncMarkerFile { file }
    func save(_ value: PhiSyncMarkerFile) -> Bool {
        if failSave { return false }; file = value; return true
    }
    func deleteFile() { file = PhiSyncMarkerFile() }
}
final class ResetMappings {
    var mappings = ["local": "remote"]
    var revokeFails = false
    var revocations = 0
    func revokeDevice(deviceKeyId: String) async throws {
        if revokeFails { throw NativeSyncResetError.cleanupFailed }; revocations += 1
    }
    /// Every reset request, refused or not; `beforeReset` observes the journal at send time.
    var resetCalls = [(operationId: UUID, deviceKeyId: String)]()
    var resetError: Error?
    var beforeReset: () -> Void = {}
    func resetAccount(operationId: UUID, deviceKeyId: String) async throws {
        beforeReset()
        resetCalls.append((operationId, deviceKeyId))
        if let resetError { throw resetError }
    }
    func removeAllMappings() { mappings = [:] }
    func allMappings() -> [String: String] { mappings }
}
final class ResetPendingRegistration {
    var devices = Set(["device"])
    func clear(deviceKeyId: String) { devices.remove(deviceKeyId) }
}
final class ResetManager {
    var hasKey = true
    var deviceKeyProviderForTesting: ResetManager { self }
    func deviceKeyId() throws -> String { "device" }
    var deviceKeyProvider: ResetManager { self }
    let pendingRegistrations = ResetPendingRegistration()
    func discardARK() { hasKey = false }
    /* PRODUCTION_DISCARD_REGISTRATION */
}
/// The pairing-reset resume marker, cleared with the enrollment it belongs to.
final class ResetLocalResetMarker {
    var present = true
    var failClear = false
    func clear() -> Bool {
        if failClear { return false }; present = false; return true
    }
}
final class ResetRotator {
    var count = 0
    func rotateForCurrentAccount() throws { count += 1 }
}
final class ResetCursor {
    var deleted = false
    func deleteFile() { deleted = true }
}
final class ResetSpaces {
    var table = PhiSpaceSyncTable(entries: 3)
    func save(_ value: PhiSpaceSyncTable) -> Bool { table = value; return true }
}
final class ResetFixture {
    var isRetired = false
    var cleaningLocalState = false
    /// Mirrors `SyncKeyController.requiresReconfiguration`: a journaled reset is an unfinished one.
    var requiresReconfiguration: Bool {
        let journal = markerStore?.load()
        return journal?.requiresReconfiguration == true || journal?.resetOperationId != nil
    }
    var markerStore: ResetMarkerStore? = ResetMarkerStore()
    var localResetMarker: ResetLocalResetMarker? = ResetLocalResetMarker()
    let manager = ResetManager()
    let profileKeys = ResetMappings()
    var spaceKeys: ResetMappings? = ResetMappings()
    var deviceKeyRotator: ResetRotator? = ResetRotator()
    var spaceStateStore: ResetSpaces? = ResetSpaces()
    var ownedItemStores = [ResetCursor(), ResetCursor(), ResetCursor()]
    let engineDefaults: UserDefaults
    var steps = [String]()
    var isCurrentAccount: () -> Bool = { true }
    var runtimeRemovalPending: () -> Bool = { false }
    var verifyCursorDeletion: () throws -> Void = {}
    var clearAllSyncIds: (() async throws -> Void)?
    init(_ defaults: UserDefaults) { engineDefaults = defaults }
    func retirePhiSync(_ removingDevice: Bool) { steps.append("stop") }
    func finishLocalCleanup(_ completed: Bool) { steps.append("finish") }
    func invalidateEnrollment() throws { steps.append("unpair") }
    func clearResolved() { steps.append("keys") }
    /* PRODUCTION_CLEANUP */
}

@main struct ResetTests {
    static func main() async throws {
        let suite = "PhiNativeReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("retained", forKey: "browser.setting")
        defaults.set(123, forKey: "browser.setting.phiSyncTs")
        defaults.set("cursor", forKey: "phi.sync.entityId")
        let fixture = ResetFixture(defaults)
        let original = fixture.markerStore!.file
        fixture.profileKeys.revokeFails = true
        do { try await fixture.removeThisDeviceFromSync(); fatalError("Expected refusal") }
        catch NativeSyncResetError.cleanupFailed {}
        precondition(fixture.steps.isEmpty && fixture.markerStore!.file == original)
        fixture.profileKeys.revokeFails = false
        fixture.clearAllSyncIds = {
            precondition(fixture.steps.first == "stop")
            precondition(fixture.ownedItemStores.allSatisfy(\.deleted))
            precondition(fixture.markerStore!.file.requiresReconfiguration == true)
            throw NativeSyncResetError.cleanupFailed
        }
        do { try await fixture.removeThisDeviceFromSync(); fatalError("Expected cleanup failure") }
        catch NativeSyncResetError.cleanupFailed {}
        precondition(fixture.markerStore!.file.marker == original.marker)
        precondition(fixture.markerStore!.file.removalPending == true)
        precondition(fixture.steps.last == "finish")
        fixture.clearAllSyncIds = {}
        try await fixture.reconfigureSync()
        precondition(fixture.profileKeys.revocations == 1)
        precondition(!fixture.requiresReconfiguration)
        precondition(fixture.manager.pendingRegistrations.devices.isEmpty)
        precondition(fixture.profileKeys.mappings.isEmpty && fixture.spaceKeys!.mappings.isEmpty)
        precondition(fixture.spaceStateStore!.table == PhiSpaceSyncTable())
        precondition(defaults.string(forKey: "browser.setting") == "retained")
        precondition(defaults.object(forKey: "browser.setting.phiSyncTs") == nil)
        precondition(defaults.object(forKey: "phi.sync.entityId") == nil)
        precondition(fixture.localResetMarker?.present == false)
        let switched = ResetFixture(defaults)
        defaults.set("next-account", forKey: "phi.sync.entityId")
        switched.clearAllSyncIds = { switched.isCurrentAccount = { false } }
        do { try await switched.reconfigureSync(); fatalError("Expected account fence") }
        catch is CancellationError {}
        precondition(defaults.string(forKey: "phi.sync.entityId") == "next-account")
        precondition(switched.requiresReconfiguration)
        let failed = ResetFixture(defaults)
        failed.markerStore!.failSave = true
        do { try await failed.reconfigureSync(); fatalError("Expected failed journal") }
        catch NativeSyncResetError.cleanupFailed {}
        precondition(!failed.profileKeys.mappings.isEmpty && failed.manager.hasKey)
        let stuckMarker = ResetFixture(defaults)
        stuckMarker.localResetMarker!.failClear = true
        do { try await stuckMarker.reconfigureSync(); fatalError("Expected failed marker removal") }
        catch NativeSyncResetError.cleanupFailed {}
        precondition(stuckMarker.requiresReconfiguration && stuckMarker.localResetMarker!.present)
        print("PASS native reset: remote refusal, cleanup journal, retry, account fence, retained browsing preferences, pairing-reset marker")
        try await accountResetTests(defaults)
    }
}

/// The account reset (docs/sync.md, "Enrollment and setup"): journal before the request,
/// server first, the shared cleanup on `reset`, nothing local on a refusal, the UUID kept
/// for a retry after any other failure, and the resume through `reconfigureSync()`.
func accountResetTests(_ defaults: UserDefaults) async throws {
    func live() -> ResetFixture {
        let fixture = ResetFixture(defaults)
        fixture.markerStore!.file = PhiSyncMarkerFile(marker: Data([9]), storeBirthday: "old")
        return fixture
    }

    let reset = live()
    reset.profileKeys.beforeReset = {
        precondition(reset.markerStore!.file.resetOperationId != nil, "journal precedes the request")
        precondition(reset.requiresReconfiguration, "a journaled reset is an unfinished reconfiguration")
        precondition(reset.steps.isEmpty, "server first: nothing local before the answer")
    }
    try await reset.resetSyncAndRemoveThisDevice()
    precondition(reset.profileKeys.resetCalls.count == 1 && reset.profileKeys.resetCalls[0].deviceKeyId == "device")
    precondition(reset.steps.first == "stop" && reset.steps.last == "finish")
    precondition(reset.deviceKeyRotator!.count == 1 && reset.profileKeys.mappings.isEmpty)
    precondition(reset.markerStore!.file == PhiSyncMarkerFile(), "the marker deletion drops the journaled UUID")
    precondition(reset.profileKeys.revocations == 0, "the reset is not a revoke")

    for refusal in [KeyAPIError.notLastDevice, KeyAPIError.deviceNotFound] {
        let refused = live()
        let original = refused.markerStore!.file
        refused.profileKeys.resetError = refusal
        do { try await refused.resetSyncAndRemoveThisDevice(); fatalError("Expected refusal") }
        catch let error as KeyAPIError {
            switch error { case .notLastDevice, .deviceNotFound: break; default: fatalError("wrong error") }
        }
        precondition(refused.steps.isEmpty && refused.profileKeys.mappings == ["local": "remote"])
        precondition(refused.deviceKeyRotator!.count == 0 && refused.manager.hasKey)
        precondition(refused.markerStore!.file == original, "a refusal forgets the operation and nothing else")
    }

    let offline = live()
    offline.profileKeys.resetError = KeyAPIError.transport(URLError(.notConnectedToInternet))
    do { try await offline.resetSyncAndRemoveThisDevice(); fatalError("Expected transport failure") }
    catch KeyAPIError.transport {}
    let pending = offline.markerStore!.file.resetOperationId
    precondition(pending != nil && offline.steps.isEmpty && offline.profileKeys.mappings == ["local": "remote"])
    offline.profileKeys.resetError = nil
    try await offline.resetSyncAndRemoveThisDevice()
    precondition(offline.profileKeys.resetCalls.map(\.operationId) == [pending!, pending!], "a retry reuses the UUID")
    precondition(offline.markerStore!.file == PhiSyncMarkerFile())

    // A lost success: the server reset, then this Mac relaunched before recording it. Only
    // the journaled UUID is on disk, and it alone makes the reconfiguration pending. The
    // resume retries the journaled operation, then removes.
    let operation = UUID()
    let lost = live()
    lost.markerStore!.file.resetOperationId = operation
    precondition(lost.requiresReconfiguration, "the journal alone requires reconfiguration")
    try await lost.reconfigureSync()
    precondition(lost.profileKeys.resetCalls.map(\.operationId) == [operation])
    precondition(lost.deviceKeyRotator!.count == 1, "a resumed reset rotates the device key like a removal")
    precondition(!lost.requiresReconfiguration && lost.markerStore!.file == PhiSyncMarkerFile())

    // The resume's refusal turns it into an ordinary reconfiguration: no rotation.
    let stranger = live()
    stranger.markerStore!.file.resetOperationId = operation
    stranger.markerStore!.file.requiresReconfiguration = true
    stranger.profileKeys.resetError = KeyAPIError.deviceNotFound
    try await stranger.reconfigureSync()
    precondition(stranger.deviceKeyRotator!.count == 0 && !stranger.requiresReconfiguration)

    // The resume keeps the reconfiguration blocked while the reset's outcome is unknown.
    let unknown = live()
    unknown.markerStore!.file.resetOperationId = operation
    unknown.markerStore!.file.requiresReconfiguration = true
    unknown.profileKeys.resetError = KeyAPIError.http(503, "")
    do { try await unknown.reconfigureSync(); fatalError("Expected server failure") }
    catch KeyAPIError.http(503, _) {}
    precondition(unknown.steps.isEmpty && unknown.requiresReconfiguration)
    precondition(unknown.markerStore!.file.resetOperationId == operation)
    print("PASS account reset: journal first, server first, shared cleanup, refusals change nothing, UUID reuse, resume")
}
