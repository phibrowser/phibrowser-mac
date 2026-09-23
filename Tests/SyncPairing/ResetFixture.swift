import Foundation

/* PRODUCTION_MARKER_TYPE */
enum NativeSyncResetError: Error { case cleanupFailed }
func AppLogInfo(_ message: String) {}
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
final class PhiSpaceSyncState {
    static let shared = PhiSpaceSyncState()
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
    func removeAllMappings() { mappings = [:] }
    func allMappings() -> [String: String] { mappings }
}
final class ResetManager {
    var hasKey = true
    var deviceKeyProviderForTesting: ResetManager { self }
    func deviceKeyId() throws -> String { "device" }
    func discardARK() { hasKey = false }
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
    var requiresReconfiguration: Bool { markerStore?.load().requiresReconfiguration == true }
    var markerStore: ResetMarkerStore? = ResetMarkerStore()
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
        precondition(fixture.profileKeys.mappings.isEmpty && fixture.spaceKeys!.mappings.isEmpty)
        precondition(fixture.spaceStateStore!.table == PhiSpaceSyncTable())
        precondition(defaults.string(forKey: "browser.setting") == "retained")
        precondition(defaults.object(forKey: "browser.setting.phiSyncTs") == nil)
        precondition(defaults.object(forKey: "phi.sync.entityId") == nil)
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
        print("PASS native reset: remote refusal, cleanup journal, retry, account fence, retained browsing preferences")
    }
}
