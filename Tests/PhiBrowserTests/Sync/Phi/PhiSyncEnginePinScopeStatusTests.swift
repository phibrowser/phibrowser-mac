import CryptoKit
import Foundation
import XCTest
@testable import Phi

/// Pinned-tab scope status: the account keeps dormant copies of a pin in every scope (app, Profile and
/// Space shapes). A copy whose owner resolves locally but belongs to another pinned-tab scope is parked
/// with parkedForScope, still replanned every round, and excluded from Needs attention and held counts.
/// Ordinary parking (an unmapped owner) keeps its status behaviour. Self-contained so it does not share
/// setup with the larger owned-item suites.
@MainActor
final class PhiSyncEnginePinScopeStatusTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore
    typealias Clock = PhiSyncEngineSpaceTests.Clock

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        suiteName = "PhiSyncEnginePinScopeStatusTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func space(_ spaceId: String) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: spaceId, profileId: "Default", name: "S", colorHex: "#3A6FF8",
                      iconName: "emoji:1F4BC", sortOrder: 0,
                      createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                      opacityLight: nil, opacityDark: nil)
    }

    /// A paired device: local Space space-a maps to su-1, the Default Profile maps to pu-1.
    private func makeSpaceAccess() -> FakePhiSpaceAccess {
        let access = FakePhiSpaceAccess()
        access.spaceMappings = ["space-a": "su-1"]
        access.spaces = [space("space-a")]
        access.uuidByProfileId = ["Default": "pu-1"]
        access.profileIdByUuid = ["pu-1": "Default"]
        access.knownLocalProfileIds = ["Default"]
        return access
    }

    private func makeSpaceStore() -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        return store
    }

    private func makeEngine(client: FakePhiSyncClient, access: FakePhiSpaceAccess,
                            ownedKinds: [OwnedKindRegistration]) -> PhiSyncEngine {
        let clock = Clock()
        return PhiSyncEngine(domainKeys: StubDomainKeys(key: key),
                             client: client, defaults: defaults, deviceKeyId: "devA", pairingComplete: true,
                             settings: [], spaceAccess: access, spaceStore: makeSpaceStore(),
                             ownedKinds: ownedKinds, previewMaxPages: PhiSyncEngine.defaultPreviewMaxPages,
                             now: { clock.read() })
    }

    private func pinTag(_ lineage: String, owner: String) -> String {
        PhiSyncEntity.pinClientTag(lineage, ownerKey: owner)
    }

    private func remotePin(_ lineage: String, owner: String, version: Int64) -> PhiRemoteEntity {
        remoteEntity(envelope(pinPayload(lineage: lineage, ownerKey: owner)),
                     tag: pinTag(lineage, owner: owner), version: version,
                     entityId: "srv-\(lineage)-\(owner)", key: key)
    }

    private func pinnedTabsHeld(_ engine: PhiSyncEngine) -> Int? {
        engine.statusSnapshot.detail?.kinds[.pinnedTabs]?.held
    }

    // MARK: - Cases

    /// In app scope, the Space- and Profile-shaped copies of mapped owners are dormant: parked with
    /// parkedForScope, still counted as parked in the round log counters, but the round is Up to date
    /// with no held pinned tabs.
    func testCopiesForAnotherScopeAreParkedWithoutNeedingAttention() async throws {
        let pinAccess = FakePinAccess(scope: .app, account: .app)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remotePin("la", owner: "app", version: 3),
            remotePin("ls", owner: "su-1", version: 4),
            remotePin("lp", owner: "pu-1", version: 5),
        ])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(),
                                ownedKinds: [.pins(access: pinAccess, store: pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("pins")
        XCTAssertNotNil(pinAccess.rows.first { PinKind.lineageKey($0.lineageId) == "la" },
                        "The app-shaped pin lands in app scope")
        XCTAssertNil(table.cursors["la:app"]?.pendingApply)
        XCTAssertNil(table.cursors["la:app"]?.parkedForScope)
        for identity in ["ls:su-1", "lp:pu-1"] {
            XCTAssertNotNil(table.cursors[identity]?.pendingApply, "\(identity) stays parked for replay")
            XCTAssertEqual(table.cursors[identity]?.parkedForScope, true,
                           "\(identity) resolves in another scope, so it is a dormant copy")
        }
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(counters?.parked, 2, "The pins log line still reports the dormant copies as parked")
        XCTAssertEqual(engine.statusSnapshot.phase, .upToDate)
        XCTAssertEqual(pinnedTabsHeld(engine), 0)
    }

    /// A Space-shaped copy whose Space is not mapped is ordinary parking: it waits on a mapping, so the
    /// round needs attention and the pin is held.
    func testAnUnmappedOwnerStillHoldsTheRound() async throws {
        let pinAccess = FakePinAccess(scope: .app, account: .app)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remotePin("la", owner: "app", version: 3),
            remotePin("lu", owner: "su-9", version: 4),
        ])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(),
                                ownedKinds: [.pins(access: pinAccess, store: pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("pins")
        XCTAssertNotNil(table.cursors["lu:su-9"]?.pendingApply)
        XCTAssertNil(table.cursors["lu:su-9"]?.parkedForScope)
        XCTAssertEqual(engine.statusSnapshot.phase, .needsAttention)
        XCTAssertEqual(pinnedTabsHeld(engine), 1)
    }

    /// The dormant copy is replanned every round: once the local scope becomes space, the next round
    /// lands it and clears both pendingApply and parkedForScope.
    func testADormantCopyLandsWhenTheScopeChanges() async throws {
        let pinAccess = FakePinAccess(scope: .app, account: .app)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remotePin("ls", owner: "su-1", version: 4)])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(),
                                ownedKinds: [.pins(access: pinAccess, store: pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(table.cursors["ls:su-1"]?.parkedForScope, true, "Precondition: dormant in app scope")

        pinAccess.scope = .space
        pinAccess.account = .space
        await engine.pullOnce()

        table = await engine.ownedTableForTesting("pins")
        XCTAssertNil(table.cursors["ls:su-1"]?.pendingApply, "The converged round lands the parked payload")
        XCTAssertNil(table.cursors["ls:su-1"]?.parkedForScope)
        XCTAssertEqual(pinAccess.rows.first { PinKind.lineageKey($0.lineageId) == "ls" }?.spaceId, "space-a")
    }

    /// Cursor files written before parkedForScope existed decode unchanged, and the flag round-trips.
    func testACursorWithoutTheNewKeyStillDecodes() throws {
        var cursor = PhiOwnedItemCursor()
        cursor.entityId = "srv-1"
        cursor.pendingApply = Data([1])
        cursor.parkedForScope = true
        let encoded = try JSONEncoder().encode(cursor)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["parkedForScope"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(PhiOwnedItemCursor.self, from: encoded), cursor)
        object.removeValue(forKey: "parkedForScope")
        let legacy = try JSONDecoder().decode(PhiOwnedItemCursor.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.parkedForScope)
        XCTAssertEqual(legacy.entityId, "srv-1")
        XCTAssertEqual(legacy.pendingApply, Data([1]))
    }
}
