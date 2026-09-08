import Foundation
import XCTest
@testable import Phi

/// In-memory `PhiSpaceLocalAccess` used by this task and by every engine test
/// from Task 8 on. Records what the engine asked for so the ordering
/// invariants (§5.6, §6.2 A2) can be asserted.
@MainActor
final class FakePhiSpaceAccess: PhiSpaceLocalAccess {
    enum Call: Equatable {
        case create(String)
        case update(String)
        case rebind(spaceId: String, toProfileId: String)
        case themeState(String)
        case order([String])
        case hide(String)
        case unhide(String)
        case purge(String)
        case refreshProfiles
        case dropMapping(String)
    }

    var spaces: [PhiLocalSpace] = []
    /// Everything the strip can order, agent Spaces included. Defaults to
    /// `spaces` so the fixtures that do not care about §6.5 exclusions need no
    /// extra setup; the ordering tests set it explicitly.
    var orderableSpaces: [PhiLocalSpace]?
    var profileIdByUuid: [String: String] = [:]
    var uuidByProfileId: [String: String] = [:]
    /// Local Chromium profiles this device still has (`userAssignableProfiles`).
    /// Defaults to "every profile any mapping mentions", so a fixture only has
    /// to set it when it is testing the dead-mapping path (§6.2 A0).
    var knownLocalProfileIds: Set<String>?
    var importingSpaceIds: Set<String> = []
    var refreshOutcome: ProfileRefreshOutcome = .unchanged
    /// What `profilesCreatedInLastRefresh()` reports (§11's `profiles_created`).
    var createdProfilesInLastRefresh = 0
    /// Runs inside `refreshAccountProfiles()`, the way §3.6's auto-create does.
    var onRefresh: (() -> Void)?
    var errorOnNextWrite: Error?
    private(set) var calls: [Call] = []
    private(set) var droppedMappings: [String] = []

    func currentSpaces() -> [PhiLocalSpace] { spaces }
    func allSpacesForOrdering() -> [PhiLocalSpace] { orderableSpaces ?? spaces }
    func globalUuid(forProfileId profileId: String) -> String? { uuidByProfileId[profileId] }
    func localProfileId(forGlobalUuid uuid: String) -> String? { profileIdByUuid[uuid] }
    func isKnownLocalProfile(_ profileId: String) -> Bool {
        if let knownLocalProfileIds { return knownLocalProfileIds.contains(profileId) }
        return profileIdByUuid.values.contains(profileId) || uuidByProfileId[profileId] != nil
    }
    func dropMapping(forProfileId profileId: String) {
        calls.append(.dropMapping(profileId))
        droppedMappings.append(profileId)
        uuidByProfileId.removeValue(forKey: profileId)
        for (uuid, id) in profileIdByUuid where id == profileId {
            profileIdByUuid.removeValue(forKey: uuid)
        }
    }
    func isImporting(intoSpaceId spaceId: String) -> Bool { importingSpaceIds.contains(spaceId) }

    func refreshAccountProfiles() async -> ProfileRefreshOutcome {
        calls.append(.refreshProfiles)
        onRefresh?()
        return refreshOutcome
    }

    func profilesCreatedInLastRefresh() -> Int { createdProfilesInLastRefresh }

    private func failIfArmed() throws {
        if let error = errorOnNextWrite { errorOnNextWrite = nil; throw error }
    }

    func create(_ space: PhiLocalSpace) async throws {
        try failIfArmed(); calls.append(.create(space.spaceId)); spaces.append(space)
    }
    func update(spaceId: String, name: String?, colorHex: String?,
                iconName: String?, createdDate: Date?) async throws {
        try failIfArmed(); calls.append(.update(spaceId))
        guard let index = spaces.firstIndex(where: { $0.spaceId == spaceId }) else { return }
        if let name { spaces[index].name = name }
        if let colorHex { spaces[index].colorHex = colorHex }
        if let iconName { spaces[index].iconName = iconName }
        if let createdDate { spaces[index].createdDate = createdDate }
    }
    func rebind(spaceId: String, toProfileId profileId: String) async throws {
        try failIfArmed(); calls.append(.rebind(spaceId: spaceId, toProfileId: profileId))
        guard let index = spaces.firstIndex(where: { $0.spaceId == spaceId }) else { return }
        spaces[index].profileId = profileId
    }
    func applyThemeState(spaceId: String, themeId: String?,
                         opacityLight: Double?, opacityDark: Double?) async throws {
        try failIfArmed(); calls.append(.themeState(spaceId))
        guard let index = spaces.firstIndex(where: { $0.spaceId == spaceId }) else { return }
        spaces[index].themeId = themeId
        spaces[index].opacityLight = opacityLight
        spaces[index].opacityDark = opacityDark
    }
    func applyOrder(_ orderedSpaceIds: [String]) async throws {
        try failIfArmed(); calls.append(.order(orderedSpaceIds))
        for (index, spaceId) in orderedSpaceIds.enumerated() {
            guard let at = spaces.firstIndex(where: { $0.spaceId == spaceId }) else { continue }
            spaces[at].sortOrder = index
        }
    }
    func hide(spaceId: String) async throws { try failIfArmed(); calls.append(.hide(spaceId)) }
    func unhide(spaceId: String) async throws { try failIfArmed(); calls.append(.unhide(spaceId)) }
    func purge(spaceId: String) async throws {
        try failIfArmed(); calls.append(.purge(spaceId))
        spaces.removeAll { $0.spaceId == spaceId }
    }
}

final class PhiSpaceLocalAccessTests: XCTestCase {

    @MainActor
    func testFakeAccessAppliesAndRecordsWrites() async throws {
        let access = FakePhiSpaceAccess()
        try await access.create(PhiLocalSpace(
            spaceId: "u1", profileId: "Default", name: "Work", colorHex: "#3A6FF8",
            iconName: "emoji:1F4BC", sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1),
            themeId: nil, opacityLight: nil, opacityDark: nil))
        try await access.update(spaceId: "u1", name: "Work2", colorHex: nil,
                                iconName: nil, createdDate: nil)
        XCTAssertEqual(access.calls, [.create("u1"), .update("u1")])
        XCTAssertEqual(access.currentSpaces().first?.name, "Work2")
    }

    @MainActor
    func testArmedErrorPropagatesOutOfTheWrite() async {
        struct Boom: Error {}
        let access = FakePhiSpaceAccess()
        access.errorOnNextWrite = Boom()
        do {
            try await access.rebind(spaceId: "u1", toProfileId: "Profile 2")
            XCTFail("rebind should have thrown")
        } catch {
            // The engine relies on this signal: a write that throws must leave
            // both baselines unwritten (§5.6).
        }
    }

    func testLocalSpaceIsAValueSnapshot() {
        let a = PhiLocalSpace(spaceId: "u1", profileId: "Default", name: "Work",
                              colorHex: "#000000", iconName: "phi:x", sortOrder: 3,
                              createdDate: Date(timeIntervalSince1970: 10),
                              themeId: "dark", opacityLight: 0.82, opacityDark: nil)
        var b = a
        XCTAssertEqual(a, b)
        b.name = "Other"
        XCTAssertNotEqual(a, b)
    }
}

/// The production `AccountPhiSpaceAccess` reaches the mapping table through
/// `SyncKeyController` -> `ProfileKeyManager` -> `ProfileSyncMappingStore`.
/// `FakePhiSpaceAccess` cannot cover that hop, and Task 4 had to ship both
/// members as placeholders, so these pin that the real forwarding is in place:
/// a reverse lookup that silently returned nil would land no inbound Space at
/// all, and a `dropMapping` that silently did nothing would disable §6.2 A0's
/// only self-heal — both invisible to every other test in the suite.
@MainActor
final class AccountPhiSpaceAccessMappingTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    /// `AccountPhiSpaceAccess` holds its controller weakly, so the test owns the
    /// strong reference for the duration of the case.
    private var controller: SyncKeyController?

    override func tearDown() {
        controller = nil
        super.tearDown()
    }

    private func makeAccess(store: MemoryMappingStore) -> AccountPhiSpaceAccess {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let manager = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let profileKeys = ProfileKeyManager(api: api, keyManager: manager, mappingStore: store)
        let approvals = DeviceApprovalService(api: api, keyManager: manager, deviceKeyProvider: provider)
        let controller = SyncKeyController(manager: manager, approvals: approvals,
                                           profileKeys: profileKeys,
                                           localProfilesProvider: { [] },
                                           notifyChromium: {})
        self.controller = controller
        return AccountPhiSpaceAccess(account: Account(userID: UUID().uuidString),
                                     controller: controller)
    }

    func testLocalProfileIdForwardsToTheMappingStore() {
        let store = MemoryMappingStore()
        store.map = ["Default": "uuid-a", "Profile 1": "uuid-b"]
        let access = makeAccess(store: store)
        XCTAssertEqual(access.localProfileId(forGlobalUuid: "uuid-b"), "Profile 1")
        XCTAssertNil(access.localProfileId(forGlobalUuid: "uuid-z"))
    }

    func testDropMappingForwardsToTheMappingStore() {
        let store = MemoryMappingStore()
        store.map = ["Default": "uuid-a", "Profile 1": "uuid-b"]
        let access = makeAccess(store: store)
        access.dropMapping(forProfileId: "Default")
        XCTAssertEqual(store.map, ["Profile 1": "uuid-b"])
        XCTAssertNil(access.localProfileId(forGlobalUuid: "uuid-a"),
                     "the dropped uuid must go back to being unmapped")
    }
}
