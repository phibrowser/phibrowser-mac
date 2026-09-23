import CryptoKit
import Foundation
import XCTest
@testable import Phi

/// M3-3 §5 engine boundaries: kind registration/dispatch, tag validation, rounds, slicing, gates and counters.
/// The initial cases register bookmarks; Task 5b-2 adds pins and coexistence coverage through the same generic
/// engine. Drive existing setSpaceSyncEnabled/pullOnce entry points and await values before XCTest autoclosure
/// assertions. Main-actor fakes require @MainActor on this class, matching PhiSyncEngineSpaceTests.
@MainActor
final class PhiSyncEngineOwnedItemsTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias Gate = PhiSyncEngineTests.Gate
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore
    typealias Clock = PhiSyncEngineSpaceTests.Clock

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        suiteName = "PhiSyncEngineOwnedItemsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func bookmarkHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.bookmarkClientTag(uuid))
    }

    private func bookmarkTag(_ uuid: String) -> String {
        PhiSyncEntity.bookmarkClientTag(uuid)
    }

    /// Preview accepts only Space payloads, so provide Space tags/ciphertext here. Bookmarks use the existing
    /// bookmarkTag helper.
    private func spaceHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))
    }

    private func spaceCiphertext(_ uuid: String, name: String = "Work") throws -> Data {
        try PhiEntityCodec.encrypt(envelope(spacePayload(uuid: uuid, name: name)), key: key)
    }

    private func space(_ spaceId: String) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: spaceId, profileId: "Default", name: "S", colorHex: "#3A6FF8",
                      iconName: "emoji:1F4BC", sortOrder: 0,
                      createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                      opacityLight: nil, opacityDark: nil)
    }

    /// A paired device with complete Space and bidirectional profile mappings.
    private func makeSpaceAccess(_ mappings: [String: String] = ["s-1": "su-1"])
        -> FakePhiSpaceAccess {
        let access = FakePhiSpaceAccess()
        access.spaceMappings = mappings
        access.spaces = mappings.keys.sorted().map(space)
        access.uuidByProfileId = ["Default": "pu-1"]
        access.profileIdByUuid = ["pu-1": "Default"]
        access.knownLocalProfileIds = ["Default"]
        return access
    }

    /// Preseed hasDrainedFullReplay true to satisfy publication guard ①. CASE 6.14 / 6.23 / 6.26 test the
    /// opposite without this helper.
    private func makeSpaceStore(drained: Bool = true) -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = drained
        return store
    }

    /// Matches PhiSyncEngineSpaceTests.makeEngine: every parameter except client defaults. Empty settings
    /// avoids real SyncableSettings.all commits through the disposable defaults suite; count bookmarks with
    /// bookmarkCommits. access is optional because constructing an @MainActor fake as a nonisolated default
    /// argument would not compile. Existing makeEngine(client:ownedKinds:) calls remain valid.
    private func makeEngine(client: FakePhiSyncClient,
                            access: FakePhiSpaceAccess? = nil,
                            store: MemorySpaceStore = MemorySpaceStore(),
                            clock: Clock = Clock(),
                            domainKeys: StubDomainKeys? = nil,
                            ownedKinds: [OwnedKindRegistration] = [],
                            previewMaxPages: Int = PhiSyncEngine.defaultPreviewMaxPages)
        -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: domainKeys ?? StubDomainKeys(key: key),
                      client: client, defaults: defaults, deviceKeyId: "devA", pairingComplete: true,
                      settings: [], spaceAccess: access ?? makeSpaceAccess(), spaceStore: store,
                      ownedKinds: ownedKinds, previewMaxPages: previewMaxPages,
                      now: { clock.read() })
    }

    private func bookmarkKind(_ access: FakeBookmarkAccess,
                              _ store: MemoryOwnedItemStore) -> OwnedKindRegistration {
        .bookmarks(access: access, store: store)
    }

    /// Decrypt the full bookmark payload for ordering and field assertions.
    private func committedBookmark(_ call: FakePhiSyncClient.CommitCall) -> Phi_PhiBookmarkEntity? {
        guard let ciphertext = call.ciphertext,
              let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
              case .bookmark(let payload)? = entity.kind else { return nil }
        return payload
    }

    private func applyCallCount(_ access: FakeBookmarkAccess) -> Int {
        access.calls.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    /// A live published cursor with baseline, server metadata and known ownership.
    private func publishedCursor(_ payload: Phi_PhiBookmarkEntity,
                                 entityId: String = "srv-1",
                                 version: Int64 = 1,
                                 owner: String = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), server: baselineBytes(payload),
                    entityId: entityId, version: version, ownerUuid: owner)
    }

    // MARK: - Equivalent pin helpers

    /// Both pin-tag components participate: identity is (lineage, owner), so one lineage under N owners is N
    /// entities.
    private func pinTag(_ lineage: String, owner: String = "pu-1") -> String {
        PhiSyncEntity.pinClientTag(lineage, ownerKey: owner)
    }

    private func pinHash(_ lineage: String, owner: String = "pu-1") -> String {
        PhiSyncEntity.clientTagHash(for: pinTag(lineage, owner: owner))
    }

    private func pinKind(_ access: FakePinAccess,
                         _ store: MemoryOwnedItemStore) -> OwnedKindRegistration {
        .pins(access: access, store: store)
    }

    /// Equivalent URL-rule helper for M3-4a Task 6; rule engine cases live in URLRuleKindTests.swift's Task 6
    /// section.
    private func urlRuleKind(_ access: FakeURLRuleAccess,
                             _ store: MemoryOwnedItemStore) -> OwnedKindRegistration {
        .urlRules(access: access, store: store)
    }

    /// Decrypt the full pin payload from a commit.
    private func committedPin(_ call: FakePhiSyncClient.CommitCall) -> Phi_PhiPinTabEntity? {
        guard let ciphertext = call.ciphertext,
              let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
              case .pinTab(let payload)? = entity.kind else { return nil }
        return payload
    }

    /// Pin equivalent of publishedCursor, defaulting to profile owner pu-1.
    private func publishedPinCursor(_ payload: Phi_PhiPinTabEntity,
                                    entityId: String = "srv-p1",
                                    version: Int64 = 1,
                                    owner: String = "pu-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), server: baselineBytes(payload),
                    entityId: entityId, version: version, ownerUuid: owner)
    }

    // MARK: - CASE 6.1–6.3: dispatch

    /// CASE 6.1: dispatch four interleaved entity kinds to their respective handlers.
    func testOnePageOfFourKindsRoutesEachEntityToItsOwnSection() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = makeSpaceStore()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var remoteSpace = spacePayload(uuid: "su-9")
        remoteSpace.profileUuid = stamped("pu-1", at: 100)
        client.scriptedPages = [page([
            remoteSettingsEntity(key: "theme.dark", value: "on", version: 10, key: key),
            remoteEntity(envelope(remoteSpace), tag: PhiSyncEntity.spaceClientTag("su-9"),
                         version: 11, entityId: "srv-space", key: key),
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 12, entityId: "srv-b1", key: key),
            remoteUnknownKind(tag: "phi-future:x", version: 13, key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(Set(table.cursors.keys), ["b1"])
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.pulled, 1)
        XCTAssertNotNil(spaceStore.table.cursors["su-9"], "The Space section lands normally")
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey),
                        "The settings section lands normally")
        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertTrue(unreadable.isEmpty, "Unknown kinds neither enter tables nor report errors")
    }

    /// CASE 6.2: route tombstones before decryption. They contain no ciphertext; classifying decryption
    /// failure as unreadable would permanently lose remote deletions once marker advances.
    func testATombstoneIsRoutedBeforeAnyDecryptAttempt() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 2)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.tombstones, 1)
        XCTAssertEqual(counters?.unreadable, 0)
        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertTrue(unreadable.isEmpty)
    }

    /// CASE 6.3: identities learned within a drain are immediately routable. Rebuilding the index incorrectly
    /// per page can discard later pages of a large tree as unknown after marker has advanced.
    func testAnIdentityLearnedOnPageOneRoutesItsTombstoneOnPageTwo() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteEntity(envelope(bookmarkPayload(uuid: "b7")), tag: bookmarkTag("b7"),
                               version: 5, entityId: "srv-b7", key: key)],
                 marker: "m1", changesRemaining: true),
            page([remoteTombstone(tag: bookmarkTag("b7"), version: 6)], marker: "m2"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.tombstones, 1)
    }

    // MARK: - CASE 6.4–6.6b: tag validation

    /// CASE 6.4: payload/tag mismatch is discarded and quarantined without cursor changes, preventing forged
    /// or defective payloads from becoming valid update baselines.
    func testAPayloadThatDoesNotHashBackToItsTagIsQuarantinedAndLeavesTheCursorAlone() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"), version: 3)
        let before = store.table.cursors["b1"]
        let client = FakePhiSyncClient()
        // The tag identifies b1 but payload bookmark_uuid is b2.
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b2")), tag: bookmarkTag("b1"),
                         version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors["b1"]?.version, 3)
        XCTAssertEqual(table.cursors["b1"], before, "No cursor field may change")
        XCTAssertNil(table.cursors["b2"], "Forged payloads never create cursors")
        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertEqual(Set(unreadable.keys), [bookmarkHash("b1")])
    }

    /// CASE 6.5: a changed payload owner still lands. §2.5 validates identity, not ownership; comparing the
    /// old owner would reject every legitimate cross-Space move.
    func testACrossSpaceMoveIsNotTreatedAsAForgedPayload() async throws {
        let spaceAccess = makeSpaceAccess(["s-1": "su-1", "s-2": "su-2"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(
            bookmarkPayload(uuid: "b1", spaceUuid: "su-1", locationStamp: 100))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1", spaceUuid: "su-2",
                                                  locationStamp: 500)),
                         tag: bookmarkTag("b1"), version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertTrue(unreadable.isEmpty, "A cross-Space move is not a forged payload")
        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.spaceId, "s-2")
    }

    /// CASE 6.6: tombstones have no payload and are exempt from tag validation.
    func testATombstoneIsExemptFromTheTagVerification() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 4)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertTrue(unreadable.isEmpty)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b1"]?.deletedAtMs, "Finalize deletion even without a local row")
    }

    /// CASE 6.6b: refuse is_folder mismatches with the physical local row type. Converting a bookmark loses
    /// URL meaning; converting a folder orphans its children. refuses(_:baseline:) cannot cover this case
    /// because the local identity has no baseline.
    func testAnEntityWhoseFolderFlagContradictsThePhysicalRowIsRefused() async throws {
        // Use an unmapped local Space to exclude this row from publication; isolate the assertion that refusal
        // creates no cursor.
        let spaceAccess = makeSpaceAccess()
        let row = PhiLocalBookmark.fixture(guid: "G1", syncId: "b1", spaceId: "s-9",
                                           isFolder: false)
        let access = FakeBookmarkAccess(rows: [row])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1", isFolder: true,
                                                  url: "https://bookmark.phi/folder")),
                         tag: bookmarkTag("b1"), version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.refused, 1)
        XCTAssertEqual(access.rows, [row], "Every field of the row is unchanged")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b1"], "A refusal never creates a cursor")
    }

    // MARK: - CASE 6.7–6.11b: rounds and slices

    /// CASE 6.7: a Space and its three bookmarks land in the same round, avoiding an extra-round delay for
    /// every new Space tree.
    func testANewSpaceAndTheBookmarksUnderItLandInTheSameRound() async throws {
        let spaceAccess = makeSpaceAccess([:])
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var remoteSpace = spacePayload(uuid: "su-9")
        remoteSpace.profileUuid = stamped("pu-1", at: 100)
        var entities = [remoteEntity(envelope(remoteSpace),
                                     tag: PhiSyncEntity.spaceClientTag("su-9"),
                                     version: 10, entityId: "srv-space", key: key)]
        for index in 0..<3 {
            entities.append(remoteEntity(
                envelope(bookmarkPayload(uuid: "b\(index)", spaceUuid: "su-9",
                                         rank: "V\(index + 1)")),
                tag: bookmarkTag("b\(index)"), version: Int64(11 + index),
                entityId: "srv-b\(index)", key: key))
        }
        client.scriptedPages = [page(entities)]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.applied, 3)
        XCTAssertEqual(counters?.parked, 0)
    }

    /// A paired device whose Space `s-2` is bound to the non-default Profile `Work` and holds no
    /// local rows of the kind under test (review A4/A5).
    private func makeSpaceAccessOnWorkProfile() -> FakePhiSpaceAccess {
        let spaceAccess = FakePhiSpaceAccess()
        spaceAccess.spaceMappings = ["s-2": "su-2"]
        spaceAccess.spaces = [PhiLocalSpace(spaceId: "s-2", profileId: "Work", name: "S", colorHex: "#3A6FF8",
                                            iconName: "emoji:1F4BC", sortOrder: 0,
                                            createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                                            opacityLight: nil, opacityDark: nil)]
        spaceAccess.uuidByProfileId = ["Default": "pu-1", "Work": "pu-2"]
        spaceAccess.profileIdByUuid = ["pu-1": "Default", "pu-2": "Work"]
        spaceAccess.knownLocalProfileIds = ["Default", "Work"]
        return spaceAccess
    }

    /// Review A4: the first bookmark landed into a Space bound to a non-default Profile used to
    /// be created under the default Profile (no sibling row to copy from), and the store finds
    /// no root for that (Profile, Space) pair — the whole Space's batch parked on every round.
    /// The row belongs to the Space's own Profile.
    func testABookmarkLandedIntoASpaceOnAnotherProfileBelongsToThatSpacesProfile() async throws {
        let spaceAccess = makeSpaceAccessOnWorkProfile()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1", spaceUuid: "su-2")),
                         tag: bookmarkTag("b1"), version: 11, entityId: "srv-b1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.applied, 1)
        let landed = access.rows.first { $0.syncId == "b1" }
        XCTAssertEqual(landed?.spaceId, "s-2")
        XCTAssertEqual(landed?.profileId, "Work", "the row belongs to the Space's Profile, not the default one")
    }

    /// Review A5: the same for a Space-scoped pin. Space-scope queries match on both ids, so a
    /// pin created under the default Profile persisted but was invisible to the Space's windows.
    func testASpaceScopedPinLandedIntoASpaceOnAnotherProfileBelongsToThatSpacesProfile() async throws {
        let spaceAccess = makeSpaceAccessOnWorkProfile()
        let pinAccess = FakePinAccess(scope: .space, account: .space)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "su-2")),
                         tag: pinTag("lx", owner: "su-2"), version: 9, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(counters?.applied, 1)
        let landed = pinAccess.rows.first { PinKind.lineageKey($0.lineageId) == "lx" }
        XCTAssertEqual(landed?.spaceId, "s-2")
        XCTAssertEqual(landed?.profileId, "Work", "the pin belongs to the Space's Profile, not the default one")
    }

    /// CASE 6.8: publish 250 items per round, in 10 batches of 25.
    func testThePublishSliceIsCappedAtTwoHundredAndFiftyPerRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: (0..<600).map {
            .fixture(guid: "G\($0)", spaceId: "s-1", index: $0)
        })
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let firstRound = bookmarkCommits(client).count
        XCTAssertEqual(firstRound, 250)
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.pendingPublish, 350)

        // commits is private(set), so subtract the previous count instead of clearing it between rounds.
        await engine.pullOnce()
        XCTAssertEqual(bookmarkCommits(client).count - firstRound, 350)
    }

    /// CASE 6.9: live slices are prefix-closed in topological order. Publishing a child before its deferred
    /// parent forces needless parking/retries on the receiver.
    func testEveryEntityInTheSliceHasItsParentInTheSameSlice() async throws {
        let spaceAccess = makeSpaceAccess()
        var rows: [PhiLocalBookmark] = []
        for index in 0..<300 {
            rows.append(.fixture(guid: "G\(index)",
                                 spaceId: "s-1",
                                 parentGuid: index == 0 ? nil : "G\(index - 1)",
                                 index: 0,
                                 isFolder: true,
                                 url: URL(string: "https://bookmark.phi/folder")!))
        }
        let access = FakeBookmarkAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 250)
        let published = Set(commits.compactMap { committedBookmarkUuid($0, key: key) })
        for call in commits {
            guard let entity = committedBookmark(call) else {
                XCTFail("Cannot decrypt commit ciphertext")
                continue
            }
            let parent = entity.parentUuid.stringValue
            guard !parent.isEmpty else { continue }
            XCTAssertTrue(published.contains(parent),
                          "Every item's parent must also be in this slice")
        }
    }

    /// CASE 6.10: tombstones use reverse topology; ancestors wait for descendants to be applied, not merely
    /// pending.
    func testAnAncestorTombstoneWaitsForItsDescendantToBeApplied() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        store.table.cursors["parent"] = publishedCursor(
            bookmarkPayload(uuid: "parent", isFolder: true,
                            url: "https://bookmark.phi/folder"),
            entityId: "srv-parent", version: 4)
        store.table.cursors["child"] = publishedCursor(
            bookmarkPayload(uuid: "child", parentUuid: "parent"),
            entityId: "srv-child", version: 5)
        let client = FakePhiSyncClient()
        client.refuseCommitsForTagHashes = [bookmarkHash("child")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = Set(bookmarkCommits(client).filter(\.deleted).map(\.clientTagHash))
        XCTAssertEqual(tombstones, [bookmarkHash("child")], "The parent must wait")
    }

    /// CASE 6.10b: never split a tombstone subtree across rounds. Partial removal would expose a still-live
    /// folder with only some children and allow new writes into it.
    func testATombstoneSliceNeverSplitsOneSubtreeAcrossTwoRounds() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        store.table.cursors["folder"] = publishedCursor(
            bookmarkPayload(uuid: "folder", isFolder: true,
                            url: "https://bookmark.phi/folder"),
            entityId: "srv-folder", version: 4)
        var descendants: Set<String> = []
        for index in 0..<500 {
            let identity = "d\(String(format: "%03d", index))"
            descendants.insert(bookmarkHash(identity))
            store.table.cursors[identity] = publishedCursor(
                bookmarkPayload(uuid: identity, parentUuid: "folder"),
                entityId: "srv-\(identity)", version: 5)
        }
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let sent = Set(bookmarkCommits(client).filter(\.deleted).map(\.clientTagHash))
        XCTAssertEqual(sent, descendants,
                       "Publish the entire subtree together without deferring part to another round")
        XCTAssertFalse(sent.contains(bookmarkHash("folder")),
                       "The folder waits for server acceptance of its descendants")
    }

    /// CASE 6.10c: folder tombstone landing supports an empty promotion set. R-M3-3-17 step 2 must be a no-op,
    /// without assuming a first descendant exists.
    func testAFolderTombstoneWithNoDescendantsLandsWithoutAnyLift() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "f1", spaceId: "s-1", isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["f1"] = publishedCursor(
            bookmarkPayload(uuid: "f1", isFolder: true, url: "https://bookmark.phi/folder"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("f1"), version: 7)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertFalse(access.rows.contains { $0.guid == "F1" })
        let lifts = access.lastAppliedOps.filter {
            if case .move = $0 { return true } else { return false }
        }
        XCTAssertTrue(lifts.isEmpty, "No descendants means no promotion")
    }

    /// CASE 6.10b-2 / R-exec-4: orphan-root rows are excluded from snapshots but never tombstoned. Using
    /// snapshot membership as diff predicate 3 would delete remote b9 even though its local row still exists.
    func testARowUnderAnOrphanRootIsNeverPublishedAndNeverTombstoned() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        access.orphanedSyncIds = ["b9"]
        let store = MemoryOwnedItemStore()
        store.table.cursors["b9"] = publishedCursor(bookmarkPayload(uuid: "b9"))
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(bookmarkCommits(client).isEmpty,
                      "Publish neither a tombstone nor an update")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b9"]?.deletedAtMs)
        XCTAssertFalse(table.cursors["b9"]?.pendingDelete ?? true)
    }

    /// CASE 6.10c-2: an importing Space must not block another Space's landing. A shared transaction would let
    /// s-b's import lock roll back s-a's two unrelated rows. Assertion ③ distinguishes actual isolation from
    /// an implementation that merely retries A before B later.
    func testAnImportingSpaceParksOnlyItsOwnEntities() async throws {
        let spaceAccess = makeSpaceAccess(["s-a": "su-a", "s-b": "su-b"])
        let access = FakeBookmarkAccess()
        access.importingSpaceIds = ["s-b"]
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var entities: [PhiRemoteEntity] = []
        for (offset, identity) in ["a1", "a2"].enumerated() {
            entities.append(remoteEntity(envelope(bookmarkPayload(uuid: identity,
                                                                  spaceUuid: "su-a",
                                                                  rank: "V\(offset + 1)")),
                                         tag: bookmarkTag(identity), version: Int64(10 + offset),
                                         entityId: "srv-\(identity)", key: key))
        }
        for (offset, identity) in ["b1", "b2"].enumerated() {
            entities.append(remoteEntity(envelope(bookmarkPayload(uuid: identity,
                                                                  spaceUuid: "su-b",
                                                                  rank: "V\(offset + 1)")),
                                         tag: bookmarkTag(identity), version: Int64(20 + offset),
                                         entityId: "srv-\(identity)", key: key))
        }
        client.scriptedPages = [page(entities)]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(access.rows.filter { $0.spaceId == "s-a" }.count, 2, "① Unlocked rows land normally")
        XCTAssertNotNil(table.cursors["a1"]?.reconciled)
        XCTAssertTrue(access.rows.filter { $0.spaceId == "s-b" }.isEmpty, "② Locked rows do not land")
        XCTAssertNotNil(table.cursors["b1"]?.pendingApply)
        XCTAssertNil(table.cursors["b1"]?.reconciled)
        XCTAssertFalse(table.cursors["b1"]?.pendingTombstone ?? true)
        XCTAssertEqual(applyCallCount(access), 2, "③ One apply per Space, rather than one shared apply")
        // A6: newly parked cursors also harvest server metadata. Marker already passed this version; if
        // metadata is omitted now, later landing cannot recover it from replay.
        XCTAssertEqual(table.cursors["b1"]?.entityId, "srv-b1")
        XCTAssertEqual(table.cursors["b1"]?.version, 20)

        access.importingSpaceIds = []
        await engine.pullOnce()
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(access.rows.filter { $0.spaceId == "s-b" }.count, 2, "④ Lands next round")
        XCTAssertNotNil(table.cursors["b1"]?.reconciled)
        XCTAssertEqual(table.cursors["b1"]?.entityId, "srv-b1",
                       "⑤ Identity survives parked landing: no b1 entity arrived this round, so metadata must come from "
                       + "the round that parked it")
        XCTAssertEqual(table.cursors["b1"]?.version, 20)
    }

    /// CASE 6.10c-3: distinguish three landing failures. Parking structural errors retries an unfixable batch
    /// forever; refusing import-locked batches permanently loses valid incoming work.
    func testTheThreeLandingFailuresTakeThreeDifferentPaths() async throws {
        func runRound(_ failure: Error?) async -> (PhiOwnedItemTable, OwnedRoundCounters?) {
            let spaceAccess = makeSpaceAccess()
            let access = FakeBookmarkAccess()
            access.applyErrorOnce = failure
            let store = MemoryOwnedItemStore()
            let client = FakePhiSyncClient()
            client.scriptedPages = [page([
                remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                             version: 9, entityId: "srv-1", key: key),
            ])]
            let engine = makeEngine(client: client, access: spaceAccess,
                                    store: makeSpaceStore(),
                                    ownedKinds: [bookmarkKind(access, store)])
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()
            let table = await engine.ownedTableForTesting("bookmarks")
            let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
            return (table, counters)
        }

        // ① Import lock parks without incrementing refused.
        let importing = await runRound(LocalStoreWriteError.spaceImporting(spaceId: "s-1"))
        XCTAssertNotNil(importing.0.cursors["b1"]?.pendingApply)
        XCTAssertEqual(importing.1?.refused, 0)

        // ② folderNotEmpty is refused without pendingApply.
        let notEmpty = await runRound(LocalStoreWriteError.folderNotEmpty)
        XCTAssertNil(notEmpty.0.cursors["b1"]?.pendingApply)
        XCTAssertEqual(notEmpty.1?.refused, 1)

        // ③ rowAlreadyMapped is refused like ②.
        let mapped = await runRound(LocalStoreWriteError.rowAlreadyMapped)
        XCTAssertNil(mapped.0.cursors["b1"]?.pendingApply)
        XCTAssertEqual(mapped.1?.refused, 1)
    }

    /// CASE 6.10d / R-exec-3: local-read errors skip the kind for the round with zero tombstones. Treating
    /// failure as empty rows makes predicate 3 declare every published identity missing, deleting the
    /// account's entire bookmark tree on all devices.
    func testAFailedLocalReadSkipsTheWholeKindAndEmitsNoTombstone() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        access.readError = LocalStoreWriteError.storeUnavailable
        let store = MemoryOwnedItemStore()
        for identity in ["b1", "b2", "b3"] {
            store.table.cursors[identity] = publishedCursor(bookmarkPayload(uuid: identity),
                                                            entityId: "srv-\(identity)")
        }
        let before = store.table
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(bookmarkCommits(client).isEmpty, "① No commits, especially no tombstones")
        XCTAssertEqual(store.table, before, "② Every cursor-table field matches the pre-call state")
        var counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.localReadFailed, 1)

        // ④ Restored reads return all three rows and produce zero commits. Checking only localReadFailed == 0
        // would miss recovery that still misclassifies them as absent and emits three tombstones.
        access.readError = nil
        access.rows = [
            .fixture(guid: "Gb1", syncId: "b1", spaceId: "s-1", index: 0),
            .fixture(guid: "Gb2", syncId: "b2", spaceId: "s-1", index: 1),
            .fixture(guid: "Gb3", syncId: "b3", spaceId: "s-1", index: 2),
        ]
        await engine.pullOnce()
        counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.localReadFailed, 0)
        XCTAssertTrue(bookmarkCommits(client).filter(\.deleted).isEmpty,
                      "④ Recovery never tombstones identities still present locally")
    }

    /// CASE 6.11: B8 escape permits ancestor deletion after descendants are abandoned. Otherwise a permanently
    /// rejected child tombstone blocks the whole ancestor chain indefinitely.
    func testAnAncestorTombstoneGoesOutOnceItsDescendantHasGivenUp() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        store.table.cursors["parent"] = publishedCursor(
            bookmarkPayload(uuid: "parent", isFolder: true,
                            url: "https://bookmark.phi/folder"),
            entityId: "srv-parent", version: 4)
        var child = publishedCursor(bookmarkPayload(uuid: "child", parentUuid: "parent"),
                                    entityId: "srv-child", version: 5)
        child.deleteRejectRounds = 3
        store.table.cursors["child"] = child
        let client = FakePhiSyncClient()
        client.refuseCommitsForTagHashes = [bookmarkHash("child")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = Set(bookmarkCommits(client).filter(\.deleted).map(\.clientTagHash))
        XCTAssertTrue(tombstones.contains(bookmarkHash("parent")))
    }

    /// CASE 6.11b / P5: refused entities must not create cursors. plan harvests metadata before refusal, so
    /// blindly creating cursors from harvest would grow the table on every malformed replay.
    func testRefusedEntitiesNeverGrowCursorsNoMatterHowManyRounds() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)

        for round in 0..<3 {
            client.scriptedPages = [page([
                // Invalid rank ending in 0.
                remoteEntity(envelope(bookmarkPayload(uuid: "b8", rank: "0")),
                             tag: bookmarkTag("b8"), version: Int64(10 + round),
                             entityId: "srv-b8", key: key),
                // Uppercase identity models a device incorrectly publishing its local guid.
                remoteEntity(envelope(bookmarkPayload(uuid: "B9")),
                             tag: bookmarkTag("B9"), version: Int64(20 + round),
                             entityId: "srv-b9", key: key),
            ])]
            await engine.pullOnce()
            let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
            XCTAssertEqual(counters?.refused, 2, "Round \(round)")
            let table = await engine.ownedTableForTesting("bookmarks")
            XCTAssertTrue(table.cursors.isEmpty, "The cursor table remains empty after round \(round)")
        }
    }

    // MARK: - CASE 6.12–6.19: gates and baseline ordering

    /// CASE 6.12: a closed gate prevents publication. Deliberate case-spec deviation: the case says inbound
    /// pulled == 1, but implementation spec §5.1 / §5.4 gates all three dispatch branches with spaceLive.
    /// Owned kinds share the Space gate, so inbound entities are discarded until gate-opening full replay
    /// (CASE 6.13). Assert the implementation contract where the two conflict.
    func testAShutGatePublishesNothing() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(false)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0)
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.pulled ?? 0, 0, "A closed gate skips owned items at dispatch, like Spaces")
        XCTAssertNil(access.rows.first?.syncId, "A closed gate never mints identities")
    }

    /// CASE 6.13: gate-opening replay covers Space and every registered kind. Assert counts separately; a
    /// positive sum could hide one omitted kind stuck at its pre-gate state.
    func testTheGateOpenEdgeReplaysBothTheSpaceSectionAndEveryRegisteredKind() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = makeSpaceStore()
        spaceStore.table.markerMovedWhileGateShut = true
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var remoteSpace = spacePayload(uuid: "su-9")
        remoteSpace.profileUuid = stamped("pu-1", at: 100)
        client.scriptedPages = [page([
            remoteEntity(envelope(remoteSpace), tag: PhiSyncEntity.spaceClientTag("su-9"),
                         version: 10, entityId: "srv-space", key: key),
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 11, entityId: "srv-b1", key: key),
            remoteEntity(envelope(pinPayload(lineage: "lx")),
                         tag: PhiSyncEntity.pinClientTag("lx", ownerKey: "pu-1"),
                         version: 12, entityId: "srv-pin", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // Keep the two assertions separate.
        XCTAssertNotNil(spaceStore.table.cursors["su-9"], "The Space section processed its entity")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertGreaterThanOrEqual(counters?.pulled ?? 0, 1, "The bookmark section processed its entity")
    }

    /// CASE 6.14: guard ① prevents both commits and identity minting before full replay drains. Zero commits
    /// alone would permit minted-but-unpublished identities that never receive a create later.
    func testAnInterruptedDrainCommitsNothingAndMintsNothing() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: (0..<3).map {
            .fixture(guid: "G\($0)", spaceId: "s-1", index: $0)
        })
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.getUpdatesErrorAfterPages = (pages: 1, error: PhiSyncProtocolError.http(500))
        client.pageBudgetExhaustsAfter = 4

        let engine = makeEngine(client: client, access: spaceAccess,
                                store: makeSpaceStore(drained: false),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0)
        XCTAssertTrue(access.rows.allSatisfy { $0.syncId == nil },
                      "No UUID may be minted into a local row")
    }

    /// CASE 6.15: failed apply must not persist any baseline bytes.
    func testAThrownApplyWritesNoBaseline() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b1"]?.reconciled)
    }

    /// CASE 6.16: post-landing verification finds an unchanged row, parks it and leaves baseline unwritten.
    /// §4.5 requires verification before baseline persistence so silent write refusal cannot look successful.
    func testASilentlyEmptyLandingIsParkedRatherThanBaselined() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        access.applyLandsNothingSilently = true
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b1"]?.reconciled)
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.applied, 0)
    }

    /// CASE 6.17: a locally won field must republish while server records the actually pulled payload.
    /// Assertion ④ catches storing merged bytes in server: it would claim knowledge of bytes the server never
    /// saw and incorrectly discard a later remote update. Commit counts alone miss this.
    func testALocallyWonFieldIsRepublishedAndServerKeepsThePulledBytes() async throws {
        let spaceAccess = makeSpaceAccess(["s-1": "su-1", "s-2": "su-2"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "local",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let baseline = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", title: "old",
                                       locationStamp: 100, contentStamp: 100)
        let inbound = bookmarkPayload(uuid: "b1", spaceUuid: "su-2", title: "old",
                                      locationStamp: 300, contentStamp: 100)
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(baseline, entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(inbound), tag: bookmarkTag("b1"), version: 42,
                         entityId: "srv-b1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 1, "①")
        XCTAssertEqual(commits.first?.baseVersion, 42, "②")
        let sent = commits.first.flatMap(committedBookmark)
        XCTAssertEqual(sent?.title.stringValue, "local", "③ The title is local")
        XCTAssertEqual(sent?.spaceUuid.stringValue, "su-2", "③ The location is remote")
        let table = await engine.ownedTableForTesting("bookmarks")
        // ④ Once commit is accepted, the server has the sent payload, so both baselines equal it (R-exec-7,
        // matching Space behavior). Updating only reconciled leaves stale server state and defeats
        // redundant-publication suppression.
        let sentBytes = sent.map(baselineBytes)
        XCTAssertNotNil(sentBytes)
        XCTAssertEqual(table.cursors["b1"]?.reconciled, sentBytes)
        XCTAssertEqual(table.cursors["b1"]?.server, sentBytes)
        XCTAssertNotEqual(table.cursors["b1"]?.server, baselineBytes(inbound),
                          "④ The accepted commit superseded the remote bytes recorded during landing")
    }

    /// A mismatch preserves owned-item metadata until explicit reconfiguration.
    func testNotMyBirthdayPreservesOwnedCursor() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        var cursor = publishedCursor(bookmarkPayload(uuid: "b1"), entityId: "srv-b1", version: 9)
        cursor.deleteRejectRounds = 2
        cursor.deletedAtMs = 1_234
        store.table.cursors["b1"] = cursor
        let reconciled = cursor.reconciled
        let client = FakePhiSyncClient()
        client.throwNotMyBirthdayOnce = true

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let landed = store.table.cursors["b1"]
        XCTAssertEqual(landed?.entityId, "srv-b1")
        XCTAssertEqual(landed?.version, 9)
        XCTAssertEqual(landed?.server, cursor.server)
        XCTAssertEqual(landed?.deleteRejectRounds, 2)
        XCTAssertEqual(landed?.reconciled, reconciled, "reconciled remains unchanged")
        XCTAssertEqual(landed?.ownerUuid, "su-1", "ownerUuid remains unchanged")
        XCTAssertEqual(landed?.deletedAtMs, 1_234, "deletedAtMs remains unchanged")
    }

    /// CASE 6.19, publication writeback exception ②: encryption failure breaks rather than returns, preserving
    /// outcomes from accepted earlier slices. Encryption belongs to the engine, so inject
    /// StubDomainKeys.error, not a client switch; losing outcomes would republish against stale baselines next
    /// round.
    func testAnEncryptionFailureKeepsTheOutcomesTheEarlierSlicesAlreadyProduced() async throws {
        let spaceAccess = makeSpaceAccess()
        // 60 identified rows without cursors: batches hold 25, with identity-sorted b00…b24 first.
        let access = FakeBookmarkAccess(rows: (0..<60).map {
            .fixture(guid: "G\($0)", syncId: String(format: "b%02d", $0), spaceId: "s-1",
                     index: $0)
        })
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        let arrived = Gate()
        let release = Gate()
        client.gatedCommitTagHash = bookmarkHash("b00")
        client.arrivedInCommit = arrived
        client.commitGate = release
        let domainKeys = StubDomainKeys(key: key)

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                domainKeys: domainKeys,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        let round = Task { await engine.pullOnce() }
        await arrived.wait()
        domainKeys.error = LocalStoreWriteError.storeUnavailable
        await release.open()
        await round.value

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertFalse(table.cursors["b00"]?.entityId.isEmpty ?? true,
                       "Cursors from the first batch already harvested entityId/version")
        XCTAssertGreaterThan(table.cursors["b00"]?.version ?? 0, 0)
    }

    // MARK: - CASE 6.20–6.26: recovery

    /// CASE 6.20: quarantine unreadable entities without overwriting cursors, then clear quarantine after
    /// recovery. Testing only quarantine would allow permanent read-only state after transient key failure.
    /// Use remoteUnreadable rather than the case-spec forceInvalidMessage switch, which affects commit
    /// outcomes rather than decryption; expected behavior is unchanged.
    func testAnUnreadableEntityIsQuarantinedAndReleasedOnceItBecomesReadable() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteUnreadable(tag: bookmarkTag("b1"), version: 5)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var quarantined = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertNotNil(quarantined[bookmarkHash("b1")])
        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b1"]?.reconciled, "The cursor is not overwritten")

        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1", rank: "W")),
                         tag: bookmarkTag("b1"), version: 6, entityId: "srv-b1", key: key),
        ])]
        await engine.pullOnce()

        quarantined = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertNil(quarantined[bookmarkHash("b1")], "Readable entities automatically leave quarantine")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b1"]?.reconciled)
    }

    /// CASE 6.22: conflict retries are scoped. Ignoring conflicts would let one identity occupy a 250-item
    /// slice slot and conflict again every round forever.
    func testAConflictRetriesOnlyTheEntitiesThatConflicted() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: (0..<3).map {
            .fixture(guid: "G\($0)", syncId: "b\($0)", spaceId: "s-1", index: $0)
        })
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.conflictOnceForTagHashes = [bookmarkHash("b0"), bookmarkHash("b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 5, "Three initial commits plus two scoped retries")
        XCTAssertEqual(Set(commits.suffix(2).map(\.clientTagHash)),
                       [bookmarkHash("b0"), bookmarkHash("b1")],
                       "Retry covers only those two entities")
    }

    /// CASE 6.23: full replay after loss, including MemoryOwnedItemStore's own contract. Assertion ③ prevents
    /// treating replay as new creation and duplicating every identified local bookmark.
    func testALostCursorFileReplaysTheWholeTypeWithoutRecreatingAnyRow() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let spaceStore = makeSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        store.forcedLoss = true
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(bookmarkPayload(uuid: "b1")), key: key),
                    version: 20, entityId: "srv-b1")

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① Trigger full-type replay; ② no commits during replay.
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
        XCTAssertEqual(bookmarkCommits(client).count, 0)
        // ⑤ Verify the fake receives the engine's hadRecords value and returns an empty table when reporting
        // loss.
        XCTAssertEqual(store.hadRecordsSeen.first, true)
        XCTAssertTrue(store.load(hadRecords: true).table.cursors.isEmpty)
        XCTAssertTrue(store.load(hadRecords: true).reportedLoss)

        store.forcedLoss = false
        await engine.pullOnce()

        // ③ Replay rebuilds cursors by identity without creating rows already present locally.
        let creates = access.lastAppliedOps.filter {
            if case .create = $0 { return true } else { return false }
        }.count
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(access.rows.count, 1, "One row must never become two")

    }

    /// CASE 6.23 assertion 4: lost files with HadRecords false must not trigger engine replay. getUpdatesCalls
    /// must contain no extra nil-marker request; checking only fake reportedLoss semantics would miss an
    /// engine that still replays.
    func testALostCursorFileWithNoPriorRecordDoesNotReplay() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()          // No local rows, so no published cursor can be written
        let spaceStore = makeSpaceStore()
        XCTAssertFalse(spaceStore.table.bookmarksHadRecords, "Precondition: this device never published bookmarks")
        let store = MemoryOwnedItemStore()
        store.forcedLoss = true
        let client = FakePhiSyncClient()
        // Use an empty page with a real marker so a from-scratch request is observable.
        client.scriptedPages = [page([], marker: "m1"), page([], marker: "m2")]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.filter { $0.marker == nil }.count, 1,
                       "Without HadRecords there is no loss; round two must not pull from scratch")
        XCTAssertTrue(spaceStore.table.hasDrainedFullReplay)
    }

    /// CASE 6.24 / 6.25: per-kind latches are independent of Space's permanent latch and can rearm (A2). A
    /// separate exposed flag alone proves neither; rearming is their essential behavioral difference.
    func testThePerKindReplayGateIsIndependentOfTheSpaceLatchAndCanRearm() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let spaceStore = makeSpaceStore()
        // The permanent Space latch has already been consumed.
        spaceStore.table.hadRecords = true
        spaceStore.table.didReplayForEmptyTable = true
        spaceStore.table.bookmarksHadRecords = true
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(bookmarkPayload(uuid: "b1")), key: key),
                    version: 20, entityId: "srv-b1")

        func markerNilCalls() -> Int { client.getUpdatesCalls.filter { $0.marker == nil }.count }

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()               // Establish a marker
        let baselineCalls = markerNilCalls()

        // CASE 6.24: bookmark file loss actually triggers replay despite the consumed Space latch.
        store.forcedLoss = true
        await engine.pullOnce()               // Publication load detects loss and clears marker
        store.forcedLoss = false
        await engine.pullOnce()               // This round pulls from scratch
        XCTAssertGreaterThan(markerNilCalls(), baselineCalls,
                             "getUpdatesCalls gains a new nil-marker request")
        let afterFirstLoss = markerNilCalls()

        // CASE 6.25: after loading a published cursor again, another loss rearms replay.
        store.forcedLoss = true
        await engine.pullOnce()
        store.forcedLoss = false
        await engine.pullOnce()
        XCTAssertGreaterThan(markerNilCalls(), afterFirstLoss,
                             "The per-kind latch rearms and produces another nil-marker request")
    }

    // MARK: - Additional review regressions

    /// T6-C3: when minted identity writeback fails, retain its cursor and advance only successful Spaces. The
    /// server already accepted these entities; dropping cursors while local syncId stays nil would remint
    /// duplicates next round and leave unowned account ghosts with no possible diff tombstone (§4.7). Slice
    /// writeback by Space so one import lock cannot block another.
    func testAFailedIdentityWriteBackKeepsTheCursorAndMintsNothingNextRound() async throws {
        let spaceAccess = makeSpaceAccess(["s-a": "su-a", "s-b": "su-b"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GA", spaceId: "s-a", index: 0, title: "A",
                     url: URL(string: "https://a.example")!),
            .fixture(guid: "GB", spaceId: "s-b", index: 0, title: "B",
                     url: URL(string: "https://b.example")!),
        ])
        access.importingSpaceIds = ["s-b"]
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // The account accepted both entities.
        XCTAssertEqual(bookmarkCommits(client).count, 2)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors.count, 2, "Preserve every accepted identity's cursor")
        // Unlocked Space: identity was written back to the local row.
        XCTAssertNotNil(access.rows.first { $0.guid == "GA" }?.syncId)
        // Locked Space: retain the payload parked in its cursor for next-round adoption.
        XCTAssertNil(access.rows.first { $0.guid == "GB" }?.syncId)
        let parked = table.cursors.values.filter { $0.pendingApply != nil }
        XCTAssertEqual(parked.count, 1)

        // Next round the row still has nil syncId, but must not mint another identity for the existing account
        // entity.
        let before = bookmarkCommits(client).count
        await engine.pullOnce()
        let after = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(after.cursors.count, 2, "Next round must not mint another identity for the same local row")
        XCTAssertEqual(bookmarkCommits(client).count - before, 0,
                       "Nor publish a second identity to the account")
    }

    /// T6-N3: a previously accepted identity whose local claim is still parked.
    /// A local push now includes a pull/apply phase. The settings cursor only keeps
    /// unrelated settings publication out of these owned-item assertions.
    private func parkedClaimFixture(url: URL = URL(string: "https://b.example")!)
        -> (access: FakeBookmarkAccess, store: MemoryOwnedItemStore,
            spaceStore: MemorySpaceStore, spaceAccess: FakePhiSpaceAccess) {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GB", spaceId: "s-1", title: "B", url: url),
        ])
        let store = MemoryOwnedItemStore()
        // Parked bytes must exactly match local projection. Row createdDate defaults to 1_000 seconds, so
        // payload must use 1_000_000 ms; mismatch would cause a pointless post-adoption update (T6-N6). Real
        // baselines come from the same row.
        var cursor = publishedCursor(bookmarkPayload(uuid: "bpark", title: "B",
                                                     url: "https://b.example",
                                                     createdAtMs: 1_000_000),
                                     entityId: "srv-bpark", version: 7)
        cursor.pendingApply = cursor.reconciled
        store.table.cursors["bpark"] = cursor
        defaults.set("srv-settings", forKey: PhiSyncEngine.entityIdStateKey)
        return (access, store, makeSpaceStore(), spaceAccess)
    }

    /// A locally triggered round retries a parked claim without replacing its identity.
    func testALocalPushRetriesTheParkedClaimInsteadOfDeletingTheEntity() async throws {
        let fixture = parkedClaimFixture()
        let client = FakePhiSyncClient()
        let engine = makeEngine(client: client, access: fixture.spaceAccess,
                                store: fixture.spaceStore,
                                ownedKinds: [bookmarkKind(fixture.access, fixture.store)])
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()

        XCTAssertTrue(bookmarkCommits(client).isEmpty,
                      "Neither tombstone the identity nor mint another for the row")
        XCTAssertEqual(fixture.access.rows.first { $0.guid == "GB" }?.syncId, "bpark",
                       "The import lock is gone; write identity back this round")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["bpark"]?.pendingApply, "Successful writeback clears parking")
        XCTAssertNil(table.cursors["bpark"]?.deletedAtMs)
    }

    /// An unclaimable accepted identity is tombstoned and the changed row gets a new one.
    func testALocalPushStillTombstonesAnUnclaimableParkedIdentity() async throws {
        let fixture = parkedClaimFixture(url: URL(string: "https://b-edited.example")!)
        let client = FakePhiSyncClient()
        // This parked payload was already downloaded; the preflight has no newer
        // updates. Keep a real readable entity on the server for the tombstone.
        let accepted = try Phi_PhiEntity(serializedBytes: XCTUnwrap(fixture.store.table.cursors["bpark"]?.reconciled))
        client.seed(tagHash: bookmarkHash("bpark"),
                    ciphertext: try PhiEntityCodec.encrypt(accepted, key: key), version: 7,
                    entityId: "srv-bpark")
        defaults.set(Data("7".utf8), forKey: PhiSyncEngine.markerStateKey)
        let engine = makeEngine(client: client, access: fixture.spaceAccess,
                                store: fixture.spaceStore,
                                ownedKinds: [bookmarkKind(fixture.access, fixture.store)])
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(client.getUpdatesCalls.first?.marker, Data("7".utf8))
        XCTAssertEqual(commits.filter(\.deleted).map(\.clientTagHash), [bookmarkHash("bpark")],
                       "The unmatched identity is still cleaned up")
        XCTAssertEqual(commits.filter { !$0.deleted }.count, 1,
                       "Mint exactly one new identity for the local row")
        XCTAssertNotEqual(fixture.access.rows.first { $0.guid == "GB" }?.syncId, "bpark")
    }

    /// T6-N4: preserve the merged payload when adopting a genuine inbound entity parked by an import lock.
    /// claim writes only identity; clearing parking after claim alone discards field-level adopt results
    /// behind the advanced marker. The next snapshot would overwrite the remote position with local values,
    /// violating §6.2's prohibition on wholesale local adoption.
    func testAParkedInboundEntityKeepsItsPayloadUntilTheMergeActuallyLands() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GX", spaceId: "s-1", title: "local",
                     url: URL(string: "https://x.example")!),
        ])
        let store = MemoryOwnedItemStore()
        // §5.6 T4 shape: parked payload never landed, so reconciled is nil.
        var cursor = ownedCursor(entityId: "srv-x1", version: 5, ownerUuid: "su-1")
        cursor.pendingApply = baselineBytes(bookmarkPayload(uuid: "x1", title: "remote",
                                                            url: "https://x.example",
                                                            contentStamp: 9_000))
        store.table.cursors["x1"] = cursor
        defaults.set("srv-settings", forKey: PhiSyncEngine.entityIdStateKey)
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)

        // The import lock has gone. The preflight must land the parked merge before
        // the publishing phase can snapshot this row.
        await engine.pushLocalSettings()

        XCTAssertEqual(access.rows.first { $0.guid == "GX" }?.syncId, "x1", "Identity was written back")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["x1"]?.pendingApply,
                     "The preflight lands the payload before clearing it")
        XCTAssertTrue(bookmarkCommits(client).isEmpty,
                      "The local snapshot must not overwrite the merged remote field")
        XCTAssertEqual(access.rows.first { $0.guid == "GX" }?.title, "remote",
                       "Remotely won fields must reach the local row")
        XCTAssertNotNil(table.cursors["x1"]?.reconciled)
    }

    /// T6-N5: identities written by entry retry must be visible to landing in the same round. adopt filters
    /// the entry snapshot for nil syncId; failing to refresh would assign a second identity to the same row.
    /// Production then refuses the entire Space batch with rowAlreadyMapped, permanently losing inbound
    /// entities. The fake's claim does not throw this case, so assert the preceding invariant: never assign
    /// that second identity.
    func testAMidRoundClaimIsVisibleToTheSameRoundsAdoption() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GB", spaceId: "s-1", title: "B",
                     url: URL(string: "https://b.example")!),
        ])
        let store = MemoryOwnedItemStore()
        // Writeback retry shape: parked payload is a copy of reconciled.
        let landed = bookmarkPayload(uuid: "e1", title: "B", url: "https://b.example")
        var cursor = publishedCursor(landed, entityId: "srv-e1", version: 4)
        cursor.pendingApply = cursor.reconciled
        store.table.cursors["e1"] = cursor
        let client = FakePhiSyncClient()
        // A second account entity with the same parent and URL would incorrectly match GB without snapshot
        // refresh.
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "e2", rank: "W", title: "B",
                                                  url: "https://b.example")),
                         tag: bookmarkTag("e2"), version: 30, entityId: "srv-e2", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "GB" }?.syncId, "e1",
                       "The row is already claimed and must not receive a second identity")
        XCTAssertEqual(access.rows.count, 2, "The second entity creates its own row")
        XCTAssertEqual(access.rows.first { $0.guid != "GB" }?.syncId, "e2")
    }

    /// T6-N1 round 1: two Spaces, one import-locked. Return the accepted identity retained in the cursor but
    /// not claimed by its local row.
    private func runFailedWriteBackRound()
        async -> (engine: PhiSyncEngine, client: FakePhiSyncClient,
                  access: FakeBookmarkAccess, store: MemoryOwnedItemStore, orphan: String) {
        let spaceAccess = makeSpaceAccess(["s-a": "su-a", "s-b": "su-b"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GA", spaceId: "s-a", index: 0, title: "A",
                     url: URL(string: "https://a.example")!),
            .fixture(guid: "GB", spaceId: "s-b", index: 0, title: "B",
                     url: URL(string: "https://b.example")!),
        ])
        access.importingSpaceIds = ["s-b"]
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let claimed = access.rows.first { $0.guid == "GA" }?.syncId
        let orphan = table.cursors.keys.first { $0 != claimed } ?? ""
        return (engine, client, access, store, orphan)
    }

    /// T6-N1: failed-writeback cursors need ownerUuid immediately at applied so later diff can delete them.
    /// Preprocessing refreshes only existing cursors before commit. A newly accepted cursor without owner
    /// remains untombstoneable, leaving an unclaimed account duplicate forever if the user changes the URL
    /// before adoption retry.
    func testAnUnclaimedMintedIdentityCarriesItsOwnerAndIsEventuallyTombstoned() async throws {
        let round1 = await runFailedWriteBackRound()
        let engine = round1.engine
        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertFalse(round1.orphan.isEmpty)
        XCTAssertEqual(table.cursors[round1.orphan]?.ownerUuid, "su-b",
                       "Set ownership when the minted identity's commit is accepted")
        XCTAssertNotNil(table.cursors[round1.orphan]?.pendingApply)

        // A user URL edit during the retry window breaks §6's positional matching.
        if let index = round1.access.rows.firstIndex(where: { $0.guid == "GB" }) {
            round1.access.rows[index].url = URL(string: "https://b-edited.example")!
        }
        round1.access.importingSpaceIds = []
        await engine.pullOnce()

        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors[round1.orphan]?.ownerUuid, "su-b", "Ownership must not be refreshed to nil")
        let tombstoned = Set(bookmarkCommits(round1.client).filter(\.deleted)
            .map(\.clientTagHash))
        XCTAssertTrue(tombstoned.contains(bookmarkHash(round1.orphan)),
                      "Diff must clean up the unclaimed identity instead of leaving a permanent orphan")
    }

    /// Other T6-N1 case: deleting the local row during retry must also permit account cleanup.
    func testAnUnclaimedMintedIdentityIsTombstonedWhenItsRowIsDeletedLocally() async throws {
        let round1 = await runFailedWriteBackRound()
        round1.access.rows.removeAll { $0.guid == "GB" }
        round1.access.importingSpaceIds = []
        await round1.engine.pullOnce()

        let tombstoned = Set(bookmarkCommits(round1.client).filter(\.deleted)
            .map(\.clientTagHash))
        XCTAssertTrue(tombstoned.contains(bookmarkHash(round1.orphan)))
    }

    /// T6-I1 / §5.6 T3: a tombstone with resolved identity but no local row still finalizes deletedAtMs.
    /// Otherwise retention can never remove its live-looking cursor, and diff emits another tombstone for an
    /// already deleted remote entity.
    func testARemoteTombstoneWithNoLocalRowStillStampsTheCursor() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()            // This row does not exist locally
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b1"]?.deletedAtMs, "T3 still finalizes deletion")
        XCTAssertNil(table.cursors["b1"]?.reconciled)
        XCTAssertTrue(bookmarkCommits(client).filter(\.deleted).isEmpty,
                      "A remotely deleted entity needs no additional local tombstone")
        // Other half of CASE 6b.3: nothing is deleted, so landing must not even open a transaction.
        XCTAssertEqual(applyCallCount(access), 0, "No local row means no apply call")
    }

    /// T6-I2: adoption and movement under one parent must leave unique sibling indices. claim writes identity
    /// and update writes fields, neither index; the batch applies raw indices without shifting siblings.
    /// Explicit permutation must move the adopted row too or it collides with a renumbered sibling, making
    /// fetch order unstable (CASE 2a.22).
    func testAClaimAndAMoveUnderTheSameParentNeverCollideOnAnIndex() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "f1", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            // Pending adoption: no identity, with content matching incoming x1 exactly.
            .fixture(guid: "GX", spaceId: "s-1", parentGuid: "F1", index: 0,
                     title: "X", url: URL(string: "https://x.example")!),
            // An identified row moves this round.
            .fixture(guid: "GY", syncId: "y1", spaceId: "s-1", parentGuid: "F1", index: 1,
                     title: "Y", url: URL(string: "https://y.example")!),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["f1"] = publishedCursor(
            bookmarkPayload(uuid: "f1", isFolder: true, url: "https://bookmark.phi/folder"))
        store.table.cursors["y1"] = publishedCursor(
            bookmarkPayload(uuid: "y1", parentUuid: "f1", rank: "W", title: "Y",
                            url: "https://y.example"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            // Adopt GX by matching parent and URL. x1 ranks after y1, so claiming identity alone is
            // insufficient: without permutation it stays at index 0 and collides with y1.
            remoteEntity(envelope(bookmarkPayload(uuid: "x1", parentUuid: "f1", rank: "Z",
                                                  title: "X", url: "https://x.example")),
                         tag: bookmarkTag("x1"), version: 30, entityId: "srv-x1", key: key),
            // y1 changes rank and genuinely moves to the front.
            remoteEntity(envelope(bookmarkPayload(uuid: "y1", parentUuid: "f1", rank: "V",
                                                  title: "Y", url: "https://y.example",
                                                  rankStamp: 500)),
                         tag: bookmarkTag("y1"), version: 31, entityId: "srv-y1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let siblings = access.rows.filter { $0.parentGuid == "F1" }
        XCTAssertEqual(siblings.count, 2)
        XCTAssertEqual(Set(siblings.map(\.index)).count, 2,
                       "Sibling rows must not share an index")
    }

    /// T6-I3: a cursor file that always fails to load permits at most one replay. Resetting the latch on
    /// successful save treats the engine's own reconstructed memory table as recovery evidence, causing
    /// endless loss → replay → rebuild → reset loops under persistent permissions or JSON failure.
    func testAPermanentlyUnreadableCursorFileReplaysAtMostOnce() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let spaceStore = makeSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        let store = MemoryOwnedItemStore()
        store.forcedLoss = true                       // This file always fails to load
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(bookmarkPayload(uuid: "b1")), key: key),
                    version: 20, entityId: "srv-b1")

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        for _ in 0..<4 { await engine.pullOnce() }

        XCTAssertLessThanOrEqual(client.getUpdatesCalls.filter { $0.marker == nil }.count, 2,
                                 "The initial marker is already nil; loss permits only one additional replay")
    }

    /// T6-I5 / §4.2 rule 3b: a live local row with deletedAtMs must republish as resurrection and clear that
    /// timestamp. Otherwise it stays local-only or resurrects/conflicts/retries every round.
    func testACursorWithADeletedStampRepublishesTheLiveRowAndClearsTheStamp() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "lx", spaceId: "s-1", title: "back"),
        ])
        let store = MemoryOwnedItemStore()
        var cursor = publishedCursor(bookmarkPayload(uuid: "lx"), entityId: "e-lx", version: 42)
        cursor.reconciled = nil          // Tombstone finalization cleared both baselines
        cursor.server = nil
        cursor.deletedAtMs = 1_000
        store.table.cursors["lx"] = cursor
        let client = FakePhiSyncClient()
        // Remote state is a tombstone with e-lx/version 42 for the resurrection update. Empty scripted pages
        // prevent inbound replay from deleting the local live row, isolating the live-row branch.
        client.seed(tagHash: bookmarkHash("lx"), ciphertext: Data(), version: 42,
                    entityId: "e-lx", deleted: true)
        client.scriptedPages = [page([], marker: "m1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let live = bookmarkCommits(client).filter { !$0.deleted }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.entityId, "e-lx", "Resurrection uses the retained entityId")
        XCTAssertEqual(live.first?.baseVersion, 42)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["lx"]?.deletedAtMs, "Clear deletedAtMs after landing")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.resurrected, 1)
    }

    /// CASE 6.26: loss observed only by publication's load immediately aborts publication. Assert existing
    /// hasDrainedFullReplay, honoring M2's ruling against a second publishBlocked flag.
    func testALossSeenOnlyByThePublishLoadAbortsThatRoundsPublishInPlace() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", spaceId: "s-1"),        // Unsynced row that should publish
        ])
        let spaceStore = makeSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        let store = MemoryOwnedItemStore()
        store.table.cursors["seed"] = publishedCursor(bookmarkPayload(uuid: "seed"))
        store.loseOnLoadNumber = 2          // Apply reads the old table; publication load alone detects loss
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
    }

    // MARK: - CASE 5b.1–5b.6: pin engine registration

    /// CASE 5b.1: registration actually drives the pin section. Without it no pin store loads and Task 9b
    /// cascade results would never persist.
    func testRegisteringThePinKindMakesTheEngineDriveThePinSection() async throws {
        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [.fixture()])
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let seen = pinStore.hadRecordsSeen
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertFalse(seen.isEmpty, "The pin section loaded its own table at least once")
        XCTAssertNotNil(counters, "The counter output includes PinKind")
    }

    /// CASE 5b.2: two registered kinds remain independent. Last-registration-wins or shared-table
    /// implementations would make one entire kind disappear.
    func testTwoRegisteredKindsKeepTheirOwnTablesCountersAndTagIndices() async throws {
        let spaceAccess = makeSpaceAccess()
        let bookmarkAccess = FakeBookmarkAccess()
        let bookmarkStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 11, entityId: "srv-b1", key: key),
            remoteEntity(envelope(pinPayload(lineage: "lx")), tag: pinTag("lx"),
                         version: 12, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(bookmarkAccess, bookmarkStore),
                                             pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let bookmarkTable = await engine.ownedTableForTesting("bookmarks")
        let pinTable = await engine.ownedTableForTesting("pins")
        let bookmarkCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let pinCounters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(Set(bookmarkTable.cursors.keys), ["b1"], "The bookmark table contains only its bookmark")
        XCTAssertEqual(Set(pinTable.cursors.keys), ["lx:pu-1"], "The pin table contains only its pin")
        XCTAssertEqual(bookmarkCounters?.pulled, 1)
        XCTAssertEqual(pinCounters?.pulled, 1)
    }

    /// CASE 5b.3 / CASE 6.4–6.5: pin tag validation includes owner because owner is half the identity
    /// (R-M3-3-15). Owner mismatch is malformed identity, not rebind; rebind is old-tag tombstone plus new-tag
    /// create.
    func testAPinPayloadWhoseOwnerDoesNotMatchItsTagIsQuarantined() async throws {
        let spaceAccess = makeSpaceAccess()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile,
                                      rows: [.fixture(lineageId: "LX", guid: "p1")])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:pu-1"] = publishedPinCursor(pinPayload(lineage: "lx"),
                                                               version: 3)
        let before = pinStore.table.cursors["lx:pu-1"]
        let client = FakePhiSyncClient()
        // Tag ownerKey is pu-1, but payload owner is su-9.
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "su-9")),
                         tag: pinTag("lx"), version: 9, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(table.cursors["lx:pu-1"], before, "No cursor field may change")
        XCTAssertNil(table.cursors["lx:su-9"], "Forged payloads never create cursors")
        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertEqual(Set(unreadable.keys), [pinHash("lx")])
    }

    /// CASE 5b.4 / CASE 6.13: gate-opening replay covers all three kinds. Separate all three assertions so one
    /// successful kind cannot hide another stuck behind the advanced marker.
    func testTheGateOpenEdgeReplayCoversTheSpaceSectionAndBothOwnedKinds() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = makeSpaceStore()
        spaceStore.table.markerMovedWhileGateShut = true
        let bookmarkAccess = FakeBookmarkAccess()
        let bookmarkStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var remoteSpace = spacePayload(uuid: "su-9")
        remoteSpace.profileUuid = stamped("pu-1", at: 100)
        client.scriptedPages = [page([
            remoteEntity(envelope(remoteSpace), tag: PhiSyncEntity.spaceClientTag("su-9"),
                         version: 10, entityId: "srv-space", key: key),
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 11, entityId: "srv-b1", key: key),
            remoteEntity(envelope(pinPayload(lineage: "lx")), tag: pinTag("lx"),
                         version: 12, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(bookmarkAccess, bookmarkStore),
                                             pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let bookmarkCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let pinCounters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertNotNil(spaceStore.table.cursors["su-9"], "The Space section processed its entity")
        XCTAssertGreaterThanOrEqual(bookmarkCounters?.pulled ?? 0, 1, "The bookmark section processed its entity")
        XCTAssertGreaterThanOrEqual(pinCounters?.pulled ?? 0, 1, "The pin section processed its entity")
    }

    /// CASE 5b-2.1, formerly 6.6c: explicit local unsplit publishes an empty partner, while
    /// pendingPartnerLineage preserves a not-yet-arrived partner. Always retaining baseline makes unsplit
    /// impossible; always clearing breaks valid pairs before arrival.
    /// Assert timestamps too: an empty string with the baseline stamp loses the serialized-byte LWW tie to the
    /// old partner value, making remote unsplit ineffective. Case ③ covers fully linked pairs without
    /// pendingPartnerLineage; clearing those would cause permanent reciprocal republication, consuming the
    /// 250-item budget.
    func testALocalSplitReleaseSendsAnEmptyPartnerWhileAHalfLandedPairKeepsTheBaseline() async throws {
        let spaceAccess = makeSpaceAccess()
        // Rows ①/② have nil splitPartnerLineageId. ① changes title to expose its projected partner; ③'s two
        // rows link each other. Explicit createdDate aligns all four rows with payload 1_000 ms: fixture
        // default 1_000 seconds differs by 1,000×. Unstamped created_at_ms mismatch causes permanent false
        // diffs, as previously seen for bookmarks in 0bba0ae5.
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LA", guid: "pa", index: 0, title: "A", createdDate: created),
            .fixture(lineageId: "LC", guid: "pc", index: 1, title: "T", createdDate: created),
            .fixture(lineageId: "LE", guid: "pe", index: 2, title: "T",
                     splitPartnerLineageId: "lf", createdDate: created),
            .fixture(lineageId: "LF", guid: "pf", index: 3, title: "T",
                     splitPartnerLineageId: "le", createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // ① Actually waiting for its partner. All four baselines use field stamp 100.
        var waiting = publishedPinCursor(pinPayload(lineage: "la", rank: "V",
                                                    splitPartner: "lb"))
        waiting.pendingPartnerLineage = "lb"
        pinStore.table.cursors["la:pu-1"] = waiting
        // ② Its partner had arrived; the user explicitly unlinked it.
        pinStore.table.cursors["lc:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lc", rank: "W", splitPartner: "ld"), entityId: "srv-p2")
        // ③ Both halves are linked, baseline retains partner, and no pendingPartnerLineage remains.
        pinStore.table.cursors["le:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "le", rank: "X", splitPartner: "lf"), entityId: "srv-p3")
        pinStore.table.cursors["lf:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lf", rank: "Y", splitPartner: "le"), entityId: "srv-p4")
        let client = FakePhiSyncClient()
        let clock = Clock()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                clock: clock, ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = pinCommits(client)
        let waitingHalf = commits.first { $0.clientTagHash == pinHash("la") }
            .flatMap(committedPin)
        let releasedHalf = commits.first { $0.clientTagHash == pinHash("lc") }
            .flatMap(committedPin)
        let baselineStamp: Int64 = 100
        XCTAssertEqual(waitingHalf?.splitPartnerUuid.stringValue, "lb",
                       "The partner has not landed; retain baseline rather than publish empty")
        XCTAssertEqual(waitingHalf?.splitPartnerUuid.updatedAtMs, baselineStamp,
                       "Retained baseline values keep their stamps; this is not a new edit")
        XCTAssertEqual(releasedHalf?.splitPartnerUuid.stringValue, "",
                       "Explicit local unlink publishes empty instead of the baseline's old partner")
        XCTAssertEqual(releasedHalf?.splitPartnerUuid.updatedAtMs, clock.nowMs,
                       "Unlink uses this round's now or loses the remote LWW tie to the old link")
        XCTAssertGreaterThan(releasedHalf?.splitPartnerUuid.updatedAtMs ?? 0, baselineStamp)
        XCTAssertNil(commits.first { $0.clientTagHash == pinHash("le") },
                     "An unchanged fully linked pair must not become an edit in the table copy")
        XCTAssertNil(commits.first { $0.clientTagHash == pinHash("lf") })
        XCTAssertEqual(commits.count, 2, "Only ① and ② should publish this round")
    }

    /// CASE 5b.6 / R-exec-5: landing remote pins preserves content stamps. Nil would fall back to landing-time
    /// createdDate and falsely defeat genuinely later remote edits in future conflicts.
    func testARemotePinLandsWithTheEntitysOwnContentTimestamp() async throws {
        let spaceAccess = makeSpaceAccess()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // Content stamp is 5 seconds, much earlier than Clock's 2023 now.
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", contentStamp: 5_000)),
                         tag: pinTag("lx"), version: 9, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let landed = pinAccess.rows.first { PinKind.lineageKey($0.lineageId) == "lx" }
        let stamp = landed?.contentUpdatedDate
        XCTAssertEqual(stamp, Date(timeIntervalSince1970: 5),
                       "Land the entity's content stamp, not nil or landing time")
    }

    // MARK: - CASE 6b.1–6b.13: tombstone landing (§5.6 T1–T4 / R-M3-3-17 / L1 / L2)

    /// Align row fixture createdDate 1_000 seconds with payload createdAtMs 1_000_000 ms. The payload default
    /// is only 1_000 ms; this unstamped-field mismatch creates permanent diffs and invalidates zero-commit
    /// assertions for unrelated reasons. Every baseline here passes the aligned value explicitly.
    private static let rowCreatedAtMs: Int64 = 1_000_000

    /// Baseline payload aligned field for field with PhiLocalBookmark.fixture.
    private func alignedPayload(uuid: String,
                                spaceUuid: String = "su-1",
                                parentUuid: String = "",
                                rank: String = "V",
                                isFolder: Bool = false,
                                title: String = "T",
                                url: String = "https://e.example") -> Phi_PhiBookmarkEntity {
        bookmarkPayload(uuid: uuid, spaceUuid: spaceUuid, parentUuid: parentUuid, rank: rank,
                        isFolder: isFolder, title: title, url: url,
                        createdAtMs: Self.rowCreatedAtMs)
    }

    private func moveIndex(_ ops: [BookmarkApplyOp]) -> Int? {
        ops.firstIndex { if case .move = $0 { return true } else { return false } }
    }

    private func deleteGuids(_ ops: [BookmarkApplyOp]) -> [String] {
        ops.compactMap { if case .delete(let guid) = $0 { return guid } else { return nil } }
    }

    /// CASE 6b.1 / T1: an unknown hash across all three indices is ignored, logs info and creates no cursor.
    /// Inventing a deletion cursor would block future arrivals via §4.2(3)/L2 even though the local row never
    /// existed (§11.4 failure table).
    func testATombstoneNoIndexRecognisesBuildsNoCursorAtAll() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteTombstone(tag: bookmarkTag("never-published"), version: 9),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let spaceTable = await engine.spaceTableForTesting
        XCTAssertEqual(Set(table.cursors.keys), ["b1"],
                       "An unknown hash must not create another owned cursor")
        XCTAssertTrue(spaceTable.cursors.isEmpty, "The Space table must not create a cursor for it either")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.tombstones, 0, "Do not count a tombstone that never landed")
    }

    /// CASE 6b.2 / T2: resolved identity plus existing row deletes the row and sets deletedAtMs from the test
    /// Clock. The actor engine has no nowForTesting hook.
    func testARemoteTombstoneDeletesTheRowAndStampsItWithThisRoundsClock() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]
        let clock = Clock()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                clock: clock, ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let stamp = table.cursors["b1"]?.deletedAtMs
        let clockNow = clock.nowMs
        XCTAssertTrue(access.rows.isEmpty, "The remote deletion actually removed the row")
        XCTAssertEqual(stamp, clockNow, "Finalization uses this round's clock value")
        XCTAssertNil(table.cursors["b1"]?.reconciled, "Clear both baselines together")
        XCTAssertNil(table.cursors["b1"]?.server)
        XCTAssertFalse(table.cursors["b1"]?.pendingTombstone ?? true)
    }

    /// CASE 6b.4 / T4: park deletion while the row's Space is importing, since the importer may be using its
    /// parent for insertion positions.
    func testAnImportLockParksARemoteTombstoneInsteadOfDeletingMidImport() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        access.importingSpaceIds = ["space-a"]
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(access.rows.map(\.guid), ["G1"], "Delete no rows during import")
        XCTAssertTrue(table.cursors["b1"]?.pendingTombstone ?? false, "Parked as a work-set entry")
        XCTAssertNil(table.cursors["b1"]?.deletedAtMs, "Do not mark deletion finalized until it succeeds")
    }

    /// CASE 6b.5: apply the parked tombstone in the first round after import ends. Marker already passed it,
    /// so failing to retry would silently discard the deletion forever.
    func testAParkedTombstoneIsHonouredOnTheFirstRoundAfterTheImport() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        access.importingSpaceIds = ["space-a"]
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)], marker: "m1"),
            page([], marker: "m2"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // The second scripted page is empty; deletion can only come from pendingTombstone work.
        access.importingSpaceIds = []
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertTrue(access.rows.isEmpty, "The first post-import round actually deletes it")
        XCTAssertNotNil(table.cursors["b1"]?.deletedAtMs)
        XCTAssertFalse(table.cursors["b1"]?.pendingTombstone ?? true, "Clear parking after applying it")
    }

    /// CASE 6b.6 / R-M3-3-17: promote descendants before deleting a remote-tombstoned folder. SwiftData
    /// cascade would destroy children and cause diff to propagate their deletion to every device.
    func testARemoteFolderTombstoneLiftsItsDescendantsBeforeDeletingTheFolder() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "folder", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            .fixture(guid: "C1", syncId: "child", spaceId: "s-1", parentGuid: "F1", index: 0),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["folder"] = publishedCursor(
            alignedPayload(uuid: "folder", isFolder: true, url: "https://bookmark.phi/folder"),
            entityId: "srv-folder", version: 3)
        store.table.cursors["child"] = publishedCursor(
            alignedPayload(uuid: "child", parentUuid: "folder"),
            entityId: "srv-child", version: 4)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("folder"), version: 9)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let ops = access.lastAppliedOps
        XCTAssertEqual(access.rows.map(\.guid), ["C1"], "① The folder is gone and the child survives")
        XCTAssertNil(access.rows.first?.parentGuid, "② Promote the child to the Space root")
        XCTAssertNil(table.cursors["child"]?.deletedAtMs, "③ The child is not the deleted entity")
        let lift = moveIndex(ops)
        let removal = ops.firstIndex { if case .delete = $0 { return true } else { return false } }
        XCTAssertNotNil(lift, "④ The batch must contain the promotion operation")
        XCTAssertNotNil(removal)
        if let lift, let removal { XCTAssertLessThan(lift, removal, "④ Promote before deletion") }
        XCTAssertEqual(applyCallCount(access), 1, "⑤ All three steps share one transaction")
    }

    /// CASE 6b.6b: promote all local descendants, including cursorless rows. Cursor-only traversal destroys a
    /// newly created unsynced bookmark with no recovery source. forceInvalidMessage rejects publication so
    /// accepted-commit identity writeback (§6.4) cannot interfere; this tests promotion does not mint, while
    /// CASE 6.14 covers publication.
    func testTheLiftSetIsEveryLocalDescendantIncludingRowsWithNoIdentityYet() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "folder", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            .fixture(guid: "C1", syncId: "child", spaceId: "s-1", parentGuid: "F1", index: 0),
            // A new local-only bookmark never published to the account.
            .fixture(guid: "C2", spaceId: "s-1", parentGuid: "F1", index: 1,
                     title: "fresh", url: URL(string: "https://fresh.example")!),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["folder"] = publishedCursor(
            alignedPayload(uuid: "folder", isFolder: true, url: "https://bookmark.phi/folder"),
            entityId: "srv-folder", version: 3)
        store.table.cursors["child"] = publishedCursor(
            alignedPayload(uuid: "child", parentUuid: "folder"),
            entityId: "srv-child", version: 4)
        let client = FakePhiSyncClient()
        client.forceInvalidMessage = true
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("folder"), version: 9)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let survivors = access.rows.sorted { $0.guid < $1.guid }
        XCTAssertEqual(survivors.map(\.guid), ["C1", "C2"], "Both descendants survive; delete the folder last")
        XCTAssertTrue(survivors.allSatisfy { $0.parentGuid == nil }, "Promote both to the Space root")
        XCTAssertNil(survivors.first { $0.guid == "C2" }?.syncId, "Promotion does not mint identities")
    }

    /// CASE 6b.7: descendants with their own tombstones are not promoted first, avoiding a spurious local
    /// position change.
    func testADescendantCarryingItsOwnTombstoneIsDeletedRatherThanLifted() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "folder", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            .fixture(guid: "C1", syncId: "child", spaceId: "s-1", parentGuid: "F1", index: 0),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["folder"] = publishedCursor(
            alignedPayload(uuid: "folder", isFolder: true, url: "https://bookmark.phi/folder"),
            entityId: "srv-folder", version: 3)
        store.table.cursors["child"] = publishedCursor(
            alignedPayload(uuid: "child", parentUuid: "folder"),
            entityId: "srv-child", version: 4)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteTombstone(tag: bookmarkTag("folder"), version: 9, entityId: "srv-folder"),
            remoteTombstone(tag: bookmarkTag("child"), version: 10, entityId: "srv-child"),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let ops = access.lastAppliedOps
        XCTAssertNil(moveIndex(ops), "Do not promote a descendant that must disappear")
        XCTAssertEqual(deleteGuids(ops), ["C1", "F1"], "The delete phase orders children before parents")
        XCTAssertTrue(access.rows.isEmpty)
    }

    /// CASE 6b.8: write deletedAtMs before diff and refresh the row snapshot after remote deletion. Otherwise
    /// diff re-tombstones it, or the stale live snapshot plus deletedAtMs invokes §4.2(3b) to resurrect it.
    /// Assert zero commits for the whole round, not merely zero tombstone commits.
    func testARowDeletedByARemoteTombstoneCommitsNothingInTheSameRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "Neither echo remote deletion as local nor resurrect it during same-round publication")
        XCTAssertNotNil(table.cursors["b1"]?.deletedAtMs)
    }

    /// CASE 6b.9 / R-M3-3-7: every transition out of live state writes deletedAtMs. Omitting it leaves a
    /// cursor eligible for repeated tombstones forever and ineligible for 30-day retention cleanup.
    func testEveryPathOutOfBeingAliveStampsDeletedAtMs() async throws {
        // ① The server accepts a local tombstone.
        let acceptedAccess = FakeBookmarkAccess()          // The local row is already absent
        let acceptedStore = MemoryOwnedItemStore()
        acceptedStore.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                            entityId: "srv-b1", version: 3)
        let acceptedClient = FakePhiSyncClient()
        let accepted = makeEngine(client: acceptedClient, access: makeSpaceAccess(),
                                  store: makeSpaceStore(),
                                  ownedKinds: [bookmarkKind(acceptedAccess, acceptedStore)])
        await accepted.setSpaceSyncEnabled(true)
        await accepted.pullOnce()
        let acceptedTable = await accepted.ownedTableForTesting("bookmarks")
        XCTAssertEqual(bookmarkCommits(acceptedClient).filter(\.deleted).count, 1,
                       "① Diff actually emitted a local tombstone")
        XCTAssertNotNil(acceptedTable.cursors["b1"]?.deletedAtMs, "① The applied branch finalizes deletion")

        // ② An inbound tombstone lands.
        let inboundAccess = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let inboundStore = MemoryOwnedItemStore()
        inboundStore.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                           entityId: "srv-b1", version: 3)
        let inboundClient = FakePhiSyncClient()
        inboundClient.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]
        let inbound = makeEngine(client: inboundClient, access: makeSpaceAccess(),
                                 store: makeSpaceStore(),
                                 ownedKinds: [bookmarkKind(inboundAccess, inboundStore)])
        await inbound.setSpaceSyncEnabled(true)
        await inbound.pullOnce()
        let inboundTable = await inbound.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(inboundTable.cursors["b1"]?.deletedAtMs, "② Inbound landing finalizes deletion")

        // ③ Abandon pendingDelete after INVALID_MESSAGE rejects it for three rounds.
        let refusedAccess = FakeBookmarkAccess()
        let refusedStore = MemoryOwnedItemStore()
        refusedStore.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                           entityId: "srv-b1", version: 3)
        let refusedClient = FakePhiSyncClient()
        refusedClient.refuseCommitsForTagHashes = [bookmarkHash("b1")]
        let refused = makeEngine(client: refusedClient, access: makeSpaceAccess(),
                                 store: makeSpaceStore(),
                                 ownedKinds: [bookmarkKind(refusedAccess, refusedStore)])
        await refused.setSpaceSyncEnabled(true)
        for _ in 0..<3 { await refused.pullOnce() }
        let refusedTable = await refused.ownedTableForTesting("bookmarks")
        XCTAssertFalse(refusedTable.cursors["b1"]?.pendingDelete ?? true, "③ Finalize after three rounds")
        XCTAssertNotNil(refusedTable.cursors["b1"]?.deletedAtMs, "③ Abandonment also finalizes deletion")
    }

    /// CASE 6b.10 / L1: engine wiring supplies A9's three conjunction terms in OwnedItemPlanContext, including
    /// deletedSubtree/liveLocalParents. Pure-function tests alone would miss an engine that never enables A9.
    func testAnInboundMoveOutOfADeletedSubtreeCancelsTheLocalDelete() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "FS", syncId: "b-survivor", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            .fixture(guid: "GC", syncId: "b-child", spaceId: "s-1", index: 1),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b-survivor"] = publishedCursor(
            alignedPayload(uuid: "b-survivor", isFolder: true,
                           url: "https://bookmark.phi/folder"),
            entityId: "srv-survivor", version: 2)
        // Diff decided deletion in the previous round at 1_000.
        store.table.cursors["b-child"] = pendingDeleteCursor(
            decidedAtMs: 1_000, entityId: "srv-child", version: 4,
            reconciled: baselineBytes(alignedPayload(uuid: "b-child")))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            // Location stamp 2_000 is strictly newer than decision 1_000; parent is a live local folder.
            remoteEntity(envelope(bookmarkPayload(uuid: "b-child", parentUuid: "b-survivor",
                                                  rank: "W", locationStamp: 2_000,
                                                  rankStamp: 2_000,
                                                  createdAtMs: Self.rowCreatedAtMs)),
                         tag: bookmarkTag("b-child"), version: 30, entityId: "srv-child",
                         key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertFalse(table.cursors["b-child"]?.pendingDelete ?? true, "A9 canceled this deletion")
        XCTAssertEqual(access.rows.first { $0.guid == "GC" }?.parentGuid, "FS",
                       "The row moves under the live parent")
    }

    /// CASE 6b.11 / L2: resurrection uses versions for both kinds. Marker rollback may replay old entities;
    /// timestamps cannot authorize reviving explicitly deleted rows. A4 requires this for pins and defensively
    /// for bookmarks.
    func testResurrectionIsDecidedByVersionForBothKinds() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        var bookmarkCursor = ownedCursor(entityId: "srv-b1", version: 42, ownerUuid: "su-1")
        bookmarkCursor.deletedAtMs = 900
        store.table.cursors["b1"] = bookmarkCursor
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        var pinCursor = ownedCursor(entityId: "srv-p1", version: 42, ownerUuid: "pu-1")
        pinCursor.deletedAtMs = 900
        pinStore.table.cursors["lx:pu-1"] = pinCursor
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            // Round 1 replays old versions for both entities.
            page([
                remoteEntity(envelope(alignedPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                             version: 41, entityId: "srv-b1", key: key),
                remoteEntity(envelope(pinPayload(lineage: "lx")), tag: pinTag("lx"),
                             version: 41, entityId: "srv-p1", key: key),
            ], marker: "m1"),
            // Round 2 supplies versions newer than their tombstones.
            page([
                remoteEntity(envelope(alignedPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                             version: 43, entityId: "srv-b1", key: key),
                remoteEntity(envelope(pinPayload(lineage: "lx")), tag: pinTag("lx"),
                             version: 43, entityId: "srv-p1", key: key),
            ], marker: "m2"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store),
                                             pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var bookmarkTable = await engine.ownedTableForTesting("bookmarks")
        var pinTable = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(bookmarkTable.cursors["b1"]?.deletedAtMs, 900,
                       "Discard old-version replay and preserve deletedAtMs")
        XCTAssertEqual(pinTable.cursors["lx:pu-1"]?.deletedAtMs, 900)
        XCTAssertTrue(access.rows.isEmpty, "An old replayed entity must not create a row")
        XCTAssertTrue(pinAccess.rows.isEmpty)

        await engine.pullOnce()

        bookmarkTable = await engine.ownedTableForTesting("bookmarks")
        pinTable = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting
        XCTAssertNil(bookmarkTable.cursors["b1"]?.deletedAtMs, "A newer version permits resurrection")
        XCTAssertNil(pinTable.cursors["lx:pu-1"]?.deletedAtMs)
        XCTAssertEqual(counters["bookmarks"]?.resurrected, 1)
        XCTAssertEqual(counters["pins"]?.resurrected, 1)
    }

    /// CASE 6b.12 / spec item 16: partner arrival links both directions in the same landing transaction,
    /// including the non-arriving identity and its cursor, beyond plan's output. A one-sided link leaves
    /// devices inconsistent until another local change. No reconcilePinnedSplitPartners call is structurally
    /// possible on PhiPinnedTabLocalAccess; that BrowserState window heuristic is excluded. An update-only
    /// batch is the fake's observable proof.
    func testAnArrivingHalfLinksBothDirectionsOfTheSplitPairInOneBatch() async throws {
        let spaceAccess = makeSpaceAccess()
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LA", guid: "pa", index: 0, createdDate: created),
            .fixture(lineageId: "LB", guid: "pb", index: 1, createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // la landed last round before lb existed locally and recorded the pending partner.
        var waiting = publishedPinCursor(pinPayload(lineage: "la", rank: "V"),
                                         entityId: "srv-pa")
        waiting.pendingPartnerLineage = "lb"
        pinStore.table.cursors["la:pu-1"] = waiting
        pinStore.table.cursors["lb:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lb", rank: "W"), entityId: "srv-pb")
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lb", rank: "W", splitPartner: "la",
                                             contentStamp: 500)),
                         tag: pinTag("lb"), version: 9, entityId: "srv-pb", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let ops = pinAccess.lastAppliedOps
        var linkOf: [String: String?] = [:]
        for op in ops {
            guard case .update(let guid, let fields) = op,
                  let partner = fields.splitPartnerLineageId else { continue }
            linkOf[guid] = partner
        }
        XCTAssertEqual(ops.count, 2, "② This batch contains exactly two updates and no other operations")
        XCTAssertTrue(ops.allSatisfy { if case .update = $0 { return true } else { return false } },
                      "② No move or relineage operations")
        XCTAssertEqual(linkOf["pa"], "lb", "① la links to lb")
        XCTAssertEqual(linkOf["pb"], "la", "① lb links to la")
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertNil(table.cursors["la:pu-1"]?.pendingPartnerLineage,
                     "④ Partner arrival clears the pending flag")
        // Receiving this link must not look like local unsplit during same-round publication. §7.4 checks
        // whether the local row still links it; entry projections must reflect the link landed mid-round.
        let released = pinCommits(client).compactMap(committedPin)
            .filter { $0.splitPartnerUuid.stringValue.isEmpty }
        XCTAssertTrue(released.isEmpty, "Do not echo a newly received link as an unlink in the same round")
    }

    /// CASE 6b.13: positional one-to-one adoption maps two matching inbound identities to one unclaimed local
    /// row only once. x1 claims GX; x2 must remain leftOver and create another row. Otherwise x2 overwrites
    /// syncId and the next diff deletes the unowned x1 account entity.
    /// Do not rely on the fake's rowAlreadyMapped error: its batch preflight sees both claims against the
    /// pre-op nil identity and permits both. That fake check covers rows already mapped before the batch;
    /// these assertions test adoption's earlier pairing invariant directly.
    func testASecondIdentityPairingToAClaimedRowTakesTheCreatePath() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            // One unsynced local row matches two inbound entities by §6.1 URL key.
            .fixture(guid: "GX", spaceId: "s-1", index: 0, title: "X",
                     url: URL(string: "https://x.example")!),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(alignedPayload(uuid: "x1", rank: "V", title: "X",
                                                 url: "https://x.example")),
                         tag: bookmarkTag("x1"), version: 30, entityId: "srv-x1", key: key),
            remoteEntity(envelope(alignedPayload(uuid: "x2", rank: "W", title: "X",
                                                 url: "https://x.example")),
                         tag: bookmarkTag("x2"), version: 31, entityId: "srv-x2", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let claimed = access.rows.first { $0.guid == "GX" }?.syncId
        XCTAssertEqual(claimed, "x1", "① The first entity claims the row and writes its identity")
        XCTAssertEqual(access.rows.count, 2, "② The second entity creates another local row")
        XCTAssertEqual(access.rows.first { $0.guid != "GX" }?.syncId, "x2")
        XCTAssertNotNil(table.cursors["x1"]?.reconciled,
                        "③ rowAlreadyMapped did not reject the Space's entire batch")
        XCTAssertNotNil(table.cursors["x2"]?.reconciled)
        XCTAssertEqual(counters?.adopted, 1, "④ Exactly one adoption")
    }

    // MARK: - CASE 11.1–11.5: preview page budget and deadline

    // Normal pull's 64 pages at 500 entries cap preview at 32,000 entities across all kinds, including
    // unreclaimed pre-M5 tombstones. Bookmarks/pins can exhaust this before counting Spaces, so pairing
    // preview owns a separate page budget and deadline.

    /// CASE 11.1: default preview budget is 400. Construct the engine directly without previewMaxPages;
    /// helpers explicitly supplying it would miss an incorrect default of 64 used in production.
    func testTheDefaultPreviewPageBudgetIsFourHundredPages() async throws {
        XCTAssertEqual(PhiSyncEngine.defaultPreviewMaxPages, 400)

        let client = FakePhiSyncClient()
        client.keepReportingChangesRemaining = true        // Always report another page
        client.seed(tagHash: spaceHash("su-1"),
                    ciphertext: try spaceCiphertext("su-1"), version: 3)
        let clock = Clock()                                // advancePerRead = 0 disables deadline progression
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: [],
                                   spaceAccess: makeSpaceAccess(), spaceStore: makeSpaceStore(),
                                   ownedKinds: [], now: { clock.read() })

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .truncated)
        // The engine with no override stops at 400 pages, proving its default matches defaultPreviewMaxPages.
        XCTAssertEqual(client.getUpdatesCalls.count, 400)
        let stats = await engine.lastPreviewStatsForTesting
        XCTAssertEqual(stats.pages, 400)
    }

    /// CASE 11.2: continue past page 65; a 64-page limit must fail this case.
    func testThePreviewKeepsPagingPastTheSixtyFourthPage() async throws {
        let client = FakePhiSyncClient()
        // First 65 pages report more changes, with page 66 finishing. Use countdown pageBudgetExhaustsAfter;
        // keepReportingChangesRemaining never finishes and could only produce truncated, while this case
        // expects success.
        client.pageBudgetExhaustsAfter = 65
        client.seed(tagHash: spaceHash("su-1"),
                    ciphertext: try spaceCiphertext("su-1"), version: 3)
        let engine = makeEngine(client: client)

        let result = await engine.previewAccountSpaces()
        guard case .success(let summaries) = result else { return XCTFail("expected success") }
        XCTAssertGreaterThan(client.getUpdatesCalls.count, 64, "Preview is not limited to 64 pages")
        XCTAssertEqual(summaries.map(\.syncUuid), ["su-1"])
    }

    /// CASE 11.3: exceeding page budget returns truncated with two counts exposed through an independent
    /// read-only interface. Counts distinguish truncation from network failure; adding associated values to
    /// truncated would break existing engine/view-model assertions and switches.
    func testAnExhaustedPreviewPageBudgetExposesItsPageAndEntityCounts() async throws {
        let client = FakePhiSyncClient.alwaysMorePages(key: key)
        client.seed(tagHash: spaceHash("su-1"),
                    ciphertext: try spaceCiphertext("su-1"), version: 3)
        let engine = makeEngine(client: client, previewMaxPages: 3)

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .truncated)
        XCTAssertEqual(client.getUpdatesCalls.count, 3)
        let stats = await engine.lastPreviewStatsForTesting
        XCTAssertEqual(stats.pages, 3)
        XCTAssertGreaterThan(stats.entities, 0, "Count scanned entities, not summaries")
    }

    /// CASE 11.4: a 120-second deadline produces timedOut, not truncated. Check at page boundaries inside the
    /// serialized round's unstructured Task, which wizard cancellation cannot stop; otherwise a stalled
    /// network occupies the round queue indefinitely.
    func testThePreviewDeadlineIsTwoMinutesAndReportsTimedOut() async throws {
        XCTAssertEqual(PhiSyncEngine.previewDeadlineMs, 120_000)

        let clock = Clock()
        clock.advancePerRead = 30_000                      // Advance 30 seconds per read
        let client = FakePhiSyncClient()
        client.pageBudgetExhaustsAfter = 1_000             // Always report changesRemaining true
        client.seed(tagHash: spaceHash("su-1"),
                    ciphertext: try spaceCiphertext("su-1"), version: 3)
        let engine = makeEngine(client: client, clock: clock)

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .timedOut, "truncated means page-budget exhaustion; deadline expiry is separate")
        // At 30 seconds per clock step, 120 seconds expires after three pages. Allow one-page slack for an
        // extra now() read.
        XCTAssertGreaterThan(client.getUpdatesCalls.count, 0)
        XCTAssertLessThanOrEqual(client.getUpdatesCalls.count, 4,
                                 "The deadline must stop paging well before the 400-page budget")
    }

    /// CASE 11.5: preview skips tombstones before decryption and non-Spaces before summary creation,
    /// materializing nothing. Preserve read-only behavior; it must never enter Task 6's generic owned-kind
    /// dispatch and write bookmarks during pairing preview.
    func testThePreviewSkipsTombstonesAndNonSpaceKindsAndMaterialisesNothing() async throws {
        let bookmarkAccess = FakeBookmarkAccess(rows: [])
        let bookmarkStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteTombstone(tag: PhiSyncEntity.spaceClientTag("su-dead"), version: 2,
                            entityId: "srv-dead"),
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 3, entityId: "srv-b1", key: key),
            remoteEntity(envelope(spacePayload(uuid: "su-live", name: "Work")),
                         tag: PhiSyncEntity.spaceClientTag("su-live"),
                         version: 4, entityId: "srv-live", key: key),
        ])]
        let engine = makeEngine(client: client, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(bookmarkAccess, bookmarkStore)])

        let result = await engine.previewAccountSpaces()
        guard case .success(let summaries) = result else { return XCTFail("expected success") }
        XCTAssertEqual(summaries.map(\.syncUuid), ["su-live"], "The list excludes tombstones and bookmarks")
        XCTAssertEqual(summaries.first?.name, "Work")
        // No materialization: no local reads/writes, owned-table loads or commits.
        XCTAssertTrue(bookmarkAccess.calls.isEmpty, "Preview does not access local bookmarks")
        XCTAssertTrue(bookmarkStore.hadRecordsSeen.isEmpty, "Preview does not load owned cursor tables")
        XCTAssertTrue(bookmarkStore.table.cursors.isEmpty)
        XCTAssertTrue(client.commits.isEmpty, "Preview performs no commits")
        let stats = await engine.lastPreviewStatsForTesting
        XCTAssertEqual(stats.pages, 1)
        XCTAssertEqual(stats.entities, 3, "Count all page entities before filtering")
    }

    // MARK: - CASE 7.1–7.7: adoption, commit-time minting and publication preprocessing (Group A)

    /// Unsynced local row matching alignedPayload's URL (§6.1 uses URL for bookmarks, title for folders).
    /// Callers choose title/stamps to control winners. Fixture createdDate 1_000 seconds matches
    /// rowCreatedAtMs 1_000_000 ms, preventing unrelated unstamped-field diffs in zero-commit assertions.
    private func adoptableRow(guid: String = "G1", spaceId: String = "s-1",
                              title: String = "T",
                              contentUpdatedDate: Date? = nil) -> PhiLocalBookmark {
        .fixture(guid: guid, spaceId: spaceId, title: title,
                 contentUpdatedDate: contentUpdatedDate)
    }

    /// Scripted page with one bookmark and a numeric marker, since the fake parses Int64 watermarks. Default
    /// m1 parses as 0 and would replay prior-round commits, invalidating second-round silence checks.
    private func oneEntityPage(_ entity: Phi_PhiBookmarkEntity, uuid: String,
                               version: Int64 = 30,
                               entityId: String = "srv-b1")
        -> FakePhiSyncClient.Page {
        page([remoteEntity(envelope(entity), tag: bookmarkTag(uuid), version: version,
                           entityId: entityId, key: key)],
             marker: "500")
    }

    /// CASE 7.1: adoption and landing share one transaction and roll back together. Writing syncId alone would
    /// make local rows ineligible for later adoption and duplicate remote entities. Assertion ② prohibits
    /// reconciled/server bytes, not all cursors: §4.9(3) legitimately creates pendingApply parking cursors
    /// after failed landing.
    func testAFailedLandingRollsBackTheClaimAndWritesNoBaseline() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [adoptableRow()])
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(alignedPayload(uuid: "b1"), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let syncId = access.rows.first { $0.guid == "G1" }?.syncId
        let baselines = table.cursors.values.filter { $0.reconciled != nil || $0.server != nil }
        XCTAssertNil(syncId, "① Landing rollback must not leave syncId partially written")
        XCTAssertTrue(baselines.isEmpty, "② Write no baseline bytes")
        XCTAssertTrue(bookmarkCommits(client).isEmpty,
                      "③ The matched row mints no new identity and has nothing to publish")
    }

    /// CASE 7.2: successful adoption claims instead of copying.
    func testASuccessfulLandingAdoptsTheLocalRowInsteadOfCopyingIt() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [adoptableRow()])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(alignedPayload(uuid: "b1"), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(access.rows.count, 1, "① Adoption must not turn one row into two")
        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.syncId, "b1",
                       "② The row claims the account identity")
        XCTAssertEqual(counters?.adopted, 1, "③")
    }

    /// CASE 7.2b: a locally won field during adoption causes exactly one merged-title commit. Landing raw
    /// inbound bytes would erase local text; ignoring mustRepublish leaves the server's old title forever
    /// because local snapshot already matches merged reconciled. CASE 7.2c covers the remote-wins direction.
    func testALocalFieldWonAtAdoptionIsRepublishedOnceWithTheMergedTitle() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            adoptableRow(title: "local-new",
                         contentUpdatedDate: Date(timeIntervalSince1970: 3_000)),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "remote-old", contentStamp: 2_000_000,
                            createdAtMs: Self.rowCreatedAtMs), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let row = access.rows.first { $0.guid == "G1" }
        XCTAssertEqual(access.rows.count, 1, "①")
        XCTAssertEqual(row?.syncId, "b1", "①")
        XCTAssertEqual(row?.title, "local-new", "① Land the merged result, not the raw inbound entity")
        XCTAssertEqual(counters?.adopted, 1, "②")

        // ③ Exactly one commit across this or the next round; compare the cumulative count after round two.
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 1, "③ The locally won field reaches the account exactly once")
        XCTAssertEqual(commits.first.flatMap(committedBookmark)?.title.stringValue, "local-new",
                       "③ Publish the merged title")
    }

    /// CASE 7.2c: remote-won fields during adoption must update the row. Ignoring fieldWrites leaves local-old
    /// against remote-new reconciled, so the next diff treats stale local data as an edit and silently rolls
    /// back the remote rename.
    func testARemoteFieldWonAtAdoptionRewritesTheLocalRow() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            adoptableRow(title: "local-old",
                         contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "remote-new", contentStamp: 2_000_000,
                            createdAtMs: Self.rowCreatedAtMs), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let row = access.rows.first { $0.guid == "G1" }
        XCTAssertEqual(access.rows.count, 1, "①")
        XCTAssertEqual(row?.syncId, "b1", "①")
        XCTAssertEqual(row?.title, "remote-new", "① Remotely won fields actually reach the local row")

        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "② The account is already correct; neither round should publish")
    }

    /// CASE 7.3: mint at commit, and write identity locally only after acceptance. Early SwiftData identity
    /// writes leave failed entities looking published and prevent later creates.
    func testAMintedIdentityReachesTheLocalRowOnlyAfterTheCommitIsAccepted() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [.fixture(guid: "G1", spaceId: "s-1")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // Reject beyond §5.3's scoped retry allowance so the account accepts none of this entity this round.
        client.forcedConflicts = 10

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertNil(access.rows.first { $0.guid == "G1" }?.syncId,
                     "① Unaccepted commits must not write local identities")

        client.forcedConflicts = 0
        await engine.pullOnce()

        XCTAssertNotNil(access.rows.first { $0.guid == "G1" }?.syncId,
                        "② Write back only after acceptance")
        XCTAssertEqual(access.rows.count, 1, "The row remains singular across both rounds")
    }

    /// CASE 7.4: best-effort deferral is round-local, never persisted (§5.3 / §6.4). Persisting window state
    /// violates CASE 3.2; failing to defer duplicates local/account copies during initial merge (§6.5).
    func testAnUnsyncedRowWaitsOutTheRoundInWhichItsSpaceReceivedEntities() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            // A different URL cannot match the arrival under §6.1, so this round would mint a new identity.
            .fixture(guid: "G2", spaceId: "s-1", index: 1, title: "other",
                     url: URL(string: "https://other.example")!),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(alignedPayload(uuid: "b1"), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "① This Space had arrivals, so defer its unsynced rows from this slice")
        let table = await engine.ownedTableForTesting("bookmarks")
        let fields = Mirror(reflecting: table).children.compactMap(\.label)
        XCTAssertEqual(fields, ["formatVersion", "cursors"],
                       "② Deferral must not persist window state in the cursor table")

        // The first round without that Space's arrival publishes the local row normally.
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 1, "③ Publish next round; deferral does not discard")
        XCTAssertEqual(commits.first.flatMap(committedBookmark)?.url.stringValue,
                       "https://other.example", "③ Publish exactly the deferred row")
    }

    /// CASE 7.5: preprocessing refreshes ownerUuid for every cursor, not just this slice. An unchanged moved
    /// row must not retain its original owner and lose its cursor during that Space's §9.3 purge, leading to a
    /// blind baseVersion 0 overwrite.
    func testTheOwnerPrePassRefreshesEveryCursorNotOnlyThisRoundsSlice() async throws {
        let spaceAccess = makeSpaceAccess(["s-1": "su-1", "s-2": "su-2"])
        let access = FakeBookmarkAccess(rows: [
            // Already published, unchanged and outside the slice; it now lives in s-2.
            .fixture(guid: "GOLD", syncId: "b-old", spaceId: "s-2", title: "T"),
            // This row is minted and enters the current slice.
            .fixture(guid: "GNEW", spaceId: "s-1", index: 1, title: "N",
                     url: URL(string: "https://new.example")!),
        ])
        let store = MemoryOwnedItemStore()
        var stale = publishedCursor(alignedPayload(uuid: "b-old", spaceUuid: "su-2"),
                                    entityId: "srv-old", version: 9)
        stale.ownerUuid = "su-stale"
        store.table.cursors["b-old"] = stale
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([], marker: "500")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let published = bookmarkCommits(client).compactMap { committedBookmarkUuid($0, key: key) }
        XCTAssertEqual(table.cursors["b-old"]?.ownerUuid, "su-2",
                       "① Refresh ownership from the local row's current Space")
        XCTAssertFalse(published.contains("b-old"),
                       "② It is outside the slice; refresh covers every table cursor")
        XCTAssertEqual(published.count, 1, "② Only the new row enters the slice")
    }

    /// CASE 7.6: a remote-won rename yields no current- or next-round commits. Refresh the round-local
    /// projection after landing; otherwise the old title gets a fresh now and overwrites the remote edit.
    /// Checking both rounds also catches delayed refresh.
    func testLandingARemotelyWonTitleCommitsNothingInEitherRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "old",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "old"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "new", contentStamp: 2_000_000,
                            createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.title, "new",
                       "Precondition: the remote winning title actually landed")
        XCTAssertEqual(bookmarkCommits(client).count, 0, "① No commits in the landing round")

        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "② The next round also publishes nothing, proving convergence")
    }

    /// CASE 7.7: refresh position as well as content after remote movement. Otherwise stale location with
    /// fresh now undoes the move. Separately confirm CASE 6.17 assertion ③: if local content wins and
    /// republishes, it must carry the landed su-2 position.
    func testLandingARemotelyWonMoveCommitsNothingAndRepublishesAtTheNewSpace() async throws {
        // First half: position-only change yields zero commits.
        let spaceAccess = makeSpaceAccess(["s-1": "su-1", "s-2": "su-2"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "T",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", spaceUuid: "su-2", locationStamp: 300,
                            createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.spaceId, "s-2",
                       "Precondition: the remote winning move landed")
        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "① Refreshed location makes projection match the new baseline, with nothing to publish")

        // Second half, CASE 6.17 ③: local content wins during the same move; its commit carries the
        // post-landing position.
        let wonAccess = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "local",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let wonStore = MemoryOwnedItemStore()
        wonStore.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "old"),
                                                       entityId: "srv-b1", version: 7)
        let wonClient = FakePhiSyncClient()
        wonClient.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", spaceUuid: "su-2", title: "old", locationStamp: 300,
                            createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]

        let wonEngine = makeEngine(client: wonClient, access: makeSpaceAccess(["s-1": "su-1",
                                                                              "s-2": "su-2"]),
                                   store: makeSpaceStore(),
                                   ownedKinds: [bookmarkKind(wonAccess, wonStore)])
        await wonEngine.setSpaceSyncEnabled(true)
        await wonEngine.pullOnce()

        let wonCommits = bookmarkCommits(wonClient)
        let sent = wonCommits.first.flatMap(committedBookmark)
        XCTAssertEqual(wonCommits.count, 1, "② The locally won title must reach the account")
        XCTAssertEqual(sent?.title.stringValue, "local", "② Carries the local title")
        XCTAssertEqual(sent?.spaceUuid.stringValue, "su-2", "② Carries the post-landing Space")
    }

    // MARK: - CASE 9a.1–9a.3: bookmark lifecycle

    /// Task 9a SyncKeyController fixture injects only owned cursor stores and the narrow clear-syncIds
    /// closure, matching SelfRevokeTests.makeController. Explicitly supply the disposable engineDefaults
    /// suite: self-revoke removes PhiSyncEngine.stateKeys, and default UserDefaults.standard would touch this
    /// machine's actual sync cursors.
    private func makeController(ownedStores: [any PhiOwnedItemStateStore],
                                bookmarkAccess: FakeBookmarkAccess,
                                ledger: SelfRevokeLedger = SelfRevokeLedger()) async throws
        -> SyncKeyController {
        let api = AccountKeyManagerTests.FakeAPI()
        let manager = AccountKeyManager(
            api: api, deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider())
        _ = try await manager.bootstrap()
        let profileKeys = ProfileKeyManager(
            api: api, keyManager: manager,
            mappingStore: ProfileKeyManagerTests.MemoryMappingStore())
        let approvals = DeviceApprovalService(
            api: api, keyManager: manager,
            deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider())
        return SyncKeyController(
            manager: manager, approvals: approvals, profileKeys: profileKeys,
            localProfilesProvider: { [] }, notifyChromium: {},
            engineDefaults: defaults,
            ownedItemStores: ownedStores,
            // Record closure entry, before it may throw: CASE 9a.1 verifies files were already deleted when
            // clearing starts.
            clearAllSyncIds: {
                ledger.note("clearSyncIds")
                try await bookmarkAccess.clearAllSyncIds()
            })
    }

    /// Self-revoke ordering ledger. unchecked Sendable accommodates the clearAllSyncIds closure; tests run on
    /// the main actor without concurrent ledger writers.
    final class SelfRevokeLedger: @unchecked Sendable {
        private(set) var steps: [String] = []
        func note(_ step: String) { steps.append(step) }
    }

    /// CASE 9a.1 store records every side effect in the shared ledger. Keep this case-specific fixture
    /// separate from the widely shared MemoryOwnedItemStore.
    private final class RecordingOwnedItemStore: PhiOwnedItemStateStore {
        let ledger: SelfRevokeLedger
        var table = PhiOwnedItemTable()
        private(set) var deleted = false

        init(ledger: SelfRevokeLedger) { self.ledger = ledger }

        func load(hadRecords: Bool) -> (table: PhiOwnedItemTable, reportedLoss: Bool) {
            ledger.note("load")
            return (table, hadRecords && table.cursors.isEmpty)
        }

        @discardableResult
        func save(_ table: PhiOwnedItemTable) -> Bool {
            self.table = table
            ledger.note("save")
            return true
        }

        func deleteFile() {
            deleted = true
            table = PhiOwnedItemTable()
            ledger.note("deleteFile")
        }
    }

    /// CASE 9a.1 / spec engine 12: self-revoke deletes both cursor files before clearing syncId. Failure after
    /// file deletion is recoverable through identity-based replay; clearing IDs while retaining cursors makes
    /// §4.7 treat the account tree as locally deleted after rejoin.
    /// Record both store and closure side effects. A clear failure propagates and keeps
    /// the cleanup pending without undoing prior cursor deletion.
    func testSelfRevokeDeletesTheCursorFilesBeforeItClearsTheSyncIds() async throws {
        let ledger = SelfRevokeLedger()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        // Step two throws on the recoverable side, proving it does not undo prior file deletion.
        access.failClearSyncIds = true
        let store = RecordingOwnedItemStore(ledger: ledger)
        store.table.cursors["b1"] = ownedCursor(entityId: "srv-b1", version: 1,
                                                ownerUuid: "su-1")

        let controller = try await makeController(ownedStores: [store], bookmarkAccess: access,
                                                  ledger: ledger)
        do {
            try await controller.removeThisDeviceFromSync()
            XCTFail("Expected the local storage failure")
        } catch LocalStoreWriteError.storeUnavailable {}

        XCTAssertEqual(ledger.steps, ["deleteFile", "clearSyncIds"],
                       "① Verify ordering itself: delete files before clearing syncId")
        XCTAssertTrue(store.deleted, "② A clear-syncId error does not undo file deletion")
        XCTAssertEqual(access.rows.first?.syncId, "b1",
                       "③ Failure preserves local syncId on the recoverable side")
        XCTAssertTrue(access.calls.contains(.clearAllSyncIds), "④ The clear-syncId step actually ran")
        XCTAssertFalse(ledger.steps.contains("save"),
                       "⑤ Self-revoke deletes the file; saving an empty table would hide loss on the next load")
    }

    /// CASE 9a.2 / spec engine 11 / E11 / A12: cascade is idempotent and protects live rows. Remove a cursor
    /// only when its owner Space is purged and no live local row claims its identity. Otherwise retain it,
    /// rehome ownerUuid from the row and count rehomed_cursors. Deleting a live cursor enables blind
    /// baseVersion 0 overwrite because server ON CONFLICT(client_tag_hash) DO UPDATE does not version-check.
    func testTheRetentionCascadeRehomesLiveCursorsAndDropsOnlyTheOrphans() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1", "space-b": "su-2"])
        let spaceStore = makeSpaceStore()
        // su-1 was already purged: purgedAtMs remains, but purgeExpired will not return it again. Cascade must
        // inspect persisted purged state, not only UUIDs newly purged this sweep.
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        // b1 still has a live row in space-b; b2 has none.
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-b"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = ownedCursor(entityId: "srv-b1", version: 1,
                                                ownerUuid: "su-1")
        store.table.cursors["b2"] = ownedCursor(entityId: "srv-b2", version: 1,
                                                ownerUuid: "su-1")

        let engine = makeEngine(client: FakePhiSyncClient(), access: spaceAccess,
                                store: spaceStore, ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        let first = await engine.ownedTableForTesting("bookmarks")
        let firstCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(first.cursors["b1"]?.ownerUuid, "su-2",
                       "① Preserve the live row's cursor and update its owner from the row")
        XCTAssertNotNil(first.cursors["b1"], "① The cursor itself remains")
        XCTAssertNil(first.cursors["b2"], "② Remove the cursor with no live claimant")
        XCTAssertEqual(firstCounters?.rehomedCursors, 1, "③ Count one rehomed_cursors update")
        XCTAssertEqual(store.table.cursors["b1"]?.ownerUuid, "su-2", "④ Persisted")
        XCTAssertNil(store.table.cursors["b2"])

        await engine.runRetentionSweep()

        let second = await engine.ownedTableForTesting("bookmarks")
        let secondCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(second.cursors["b1"]?.ownerUuid, "su-2", "⑤ The second sweep has the same result")
        XCTAssertNil(second.cursors["b2"])
        XCTAssertEqual(secondCounters?.rehomedCursors, 0,
                       "⑥ Idempotent: the cursor now targets an unpurged Space and no longer meets predicate (a)")
    }

    /// CASE 9a.3 / spec engine 13: a retired engine's in-flight round writes nothing. Otherwise it can
    /// recreate self-revoked cursor state after local IDs are cleared. Gate open/wait are async; nonisolated
    /// synchronous shutdown blocks every later write as soon as it returns.
    func testARoundInFlightWhenTheDeviceRetiresWritesNothingBack() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = ownedCursor(entityId: "srv-b1", version: 1,
                                                ownerUuid: "su-1")
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b9")), tag: bookmarkTag("b9"),
                         version: 12, entityId: "srv-b9", key: key),
        ])]
        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        let round = Task { await engine.pullOnce() }
        await arrived.wait()

        // Perform self-revoke's two steps while the round is suspended in getUpdates.
        engine.shutdown()
        store.deleteFile()
        await release.open()
        await round.value

        let applied = access.calls.contains { if case .apply = $0 { return true } else { return false } }
        XCTAssertTrue(store.deleted, "① The in-flight round did not recreate the file")
        XCTAssertTrue(store.table.cursors.isEmpty, "② The cursor table remains empty")
        XCTAssertEqual(bookmarkCommits(client).count, 0, "③ No commits after retirement")
        XCTAssertFalse(applied, "④ No landing after retirement")
    }

    /// CASE 9a.4 / §3.6: retention drops finalized tombstone cursors for both kinds after 30 days. Previously
    /// dropExpiredTombstones had no caller, allowing permanent table growth. Reuse
    /// PhiSpaceSyncState.retentionMs, matching M1 §2. Test each boundary by one millisecond: age <=
    /// retentionMs stays; retentionMs + 1 drops.
    func testTheSweepDropsOwnedTombstoneCursorsPastTheRetentionWindow() async throws {
        let clock = Clock()
        let nowMs = clock.nowMs
        let window = PhiSpaceSyncState.retentionMs
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let created = Date(timeIntervalSince1970: 1)

        let bookmarkAccess = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "live", spaceId: "space-a"),
        ])
        let bookmarks = MemoryOwnedItemStore()
        bookmarks.table.cursors["live"] = ownedCursor(entityId: "srv-live", version: 1,
                                                       ownerUuid: "su-1")
        var staleBookmark = ownedCursor(entityId: "srv-old", version: 1, ownerUuid: "su-1")
        staleBookmark.deletedAtMs = nowMs - window - 1
        bookmarks.table.cursors["old"] = staleBookmark
        var freshBookmark = ownedCursor(entityId: "srv-young", version: 1, ownerUuid: "su-1")
        freshBookmark.deletedAtMs = nowMs - window + 1
        bookmarks.table.cursors["young"] = freshBookmark

        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LP", guid: "pp", index: 0, createdDate: created),
        ])
        let pins = MemoryOwnedItemStore()
        pins.table.cursors["lp:pu-1"] = ownedCursor(entityId: "srv-lp", version: 1,
                                                     ownerUuid: "pu-1")
        var stalePin = ownedCursor(entityId: "srv-pold", version: 1, ownerUuid: "pu-1")
        stalePin.deletedAtMs = nowMs - window - 1
        pins.table.cursors["pold:pu-1"] = stalePin

        let engine = makeEngine(client: FakePhiSyncClient(), access: spaceAccess,
                                store: makeSpaceStore(), clock: clock,
                                ownedKinds: [bookmarkKind(bookmarkAccess, bookmarks),
                                             pinKind(pinAccess, pins)])
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        let bookmarkTable = await engine.ownedTableForTesting("bookmarks")
        let pinTable = await engine.ownedTableForTesting("pins")
        XCTAssertNil(bookmarkTable.cursors["old"], "① Drop the whole tombstone cursor after retention expires")
        XCTAssertNotNil(bookmarkTable.cursors["young"], "② Retain cursors still within the window")
        XCTAssertNotNil(bookmarkTable.cursors["live"],
                        "③ Live cursors without deletedAtMs remain unchanged")
        XCTAssertNil(pinTable.cursors["pold:pu-1"], "④ The registration loop covers both kinds")
        XCTAssertNotNil(pinTable.cursors["lp:pu-1"])
        XCTAssertNil(bookmarks.table.cursors["old"], "⑤ Persisted")
        XCTAssertNil(pins.table.cursors["pold:pu-1"])
    }

    // MARK: - CASE 9.2 / 9.3: shared URL-rule lifecycle (M3-4a Task 9)

    /// CASE 9.2: self-revoke deletes the third cursor file while retaining rule syncIds. The generic
    /// ownedItemStores loop removes bookmark/rule stores; only bookmark identities clear. Omitting the rule
    /// store leaves stale publication state; clearing rule IDs would orphan old account identities because
    /// insertion remints (R-M3-4a-23) and adoption applies only to unpublished rows (R-M3-4a-53).
    /// PhiURLRuleLocalAccess structurally has no clearAllSyncIds; controller has no rule-access connection and
    /// must never touch it.
    func testSelfRevokeDeletesTheRuleCursorFileButKeepsTheRuleSyncIds() async throws {
        let bookmarkAccess = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        let ruleAccess = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r1", sortOrder: 0),
            .fixture(id: "i2", syncId: "r2", sortOrder: 1),
        ])
        let bookmarkStore = MemoryOwnedItemStore()
        bookmarkStore.table.cursors["b1"] = ownedCursor(entityId: "srv-b1", version: 1,
                                                        ownerUuid: "su-1")
        let urlRuleStore = MemoryOwnedItemStore()
        urlRuleStore.table.cursors["r1"] = ownedCursor(entityId: "srv-r1", version: 1,
                                                       ownerUuid: "su-1")
        urlRuleStore.table.cursors["r2"] = ownedCursor(entityId: "srv-r2", version: 1,
                                                       ownerUuid: "su-1")

        let controller = try await makeController(ownedStores: [bookmarkStore, urlRuleStore],
                                                  bookmarkAccess: bookmarkAccess)
        try await controller.removeThisDeviceFromSync()

        XCTAssertTrue(urlRuleStore.deleted, "① The third cursor file is deleted")
        XCTAssertTrue(urlRuleStore.table.cursors.isEmpty)
        XCTAssertTrue(bookmarkStore.deleted, "② The bookmark file is deleted too")
        XCTAssertEqual(ruleAccess.rows.compactMap(\.syncId), ["r1", "r2"], "③ Both rule syncIds remain")
        XCTAssertEqual(ruleAccess.rows.count, 2, "③ Both rows remain too")
        XCTAssertTrue(ruleAccess.calls.isEmpty, "③ Self-revoke never touches rule access")
        XCTAssertTrue(ruleAccess.hardDeleteCalls.isEmpty)
        XCTAssertTrue(bookmarkAccess.rows.allSatisfy { $0.syncId == nil }, "④ Bookmark identities still clear")
        XCTAssertTrue(bookmarkAccess.calls.contains(.clearAllSyncIds), "④")
    }

    /// Commit rejection pauses without erasing the rule cursors.
    func testANewStoreBirthdayPreservesRuleCursorsAfterCommitRejection() async throws {
        let ruleHash = { (uuid: String) in
            PhiSyncEntity.clientTagHash(for: PhiSyncEntity.urlRuleClientTag(uuid))
        }
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r1", host: "edited.example", sortOrder: 0),
        ])
        let store = MemoryOwnedItemStore()
        let baselineLive = baselineBytes(urlRulePayload(uuid: "r1"))
        var live = ownedCursor(reconciled: baselineLive, server: baselineLive,
                               entityId: "srv-r1", version: 3, ownerUuid: "su-1")
        live.deleteRejectRounds = 1
        live.rekeyRejectRounds = 2
        let baselineGone = baselineBytes(urlRulePayload(uuid: "r2"))
        var gone = ownedCursor(reconciled: baselineGone, server: baselineGone,
                               entityId: "srv-r2", version: 4, ownerUuid: "su-1")
        gone.deleteRejectRounds = 2
        gone.rekeyRejectRounds = 1
        gone.deletedAtMs = 1_234
        store.table.cursors["r1"] = live
        store.table.cursors["r2"] = gone
        let spaceStore = makeSpaceStore()
        spaceStore.table.urlRulesReplayedForEmptyTable = true
        spaceStore.table.urlRulesHadRecords = true
        // Silence settings/Spaces as in 2b-L1 so the only commit is a rule commit.
        spaceStore.table.unreadableTagHashes[spaceHash("su-1")] = 1
        defaults.set(try Phi_PhiSettingEntity().serializedData(),
                     forKey: PhiSyncEngine.lastEntityStateKey)
        let client = FakePhiSyncClient()
        client.seed(tagHash: ruleHash("r1"), ciphertext: Data(), version: 3, entityId: "srv-r1")
        // An empty scripted page keeps the seeded commit-update row from being pulled as an unreadable inbound
        // entity.
        client.scriptedPages = [page([], marker: "9")]
        client.commitErrorOnce = PhiSyncProtocolError.notMyBirthday
        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: spaceStore, ownedKinds: [urlRuleKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let ruleCommits = client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName }
        XCTAssertEqual(ruleCommits.count, 1, "The owned commit is the one that throws notMyBirthday")
        XCTAssertEqual(ruleCommits.first?.clientTagHash, ruleHash("r1"))
        let table = await engine.ownedTableForTesting("urlrules")
        XCTAssertEqual(table.cursors.count, 2, "Cursor count is unchanged")
        for (identity, before) in [("r1", live), ("r2", gone)] {
            let cursor = try XCTUnwrap(table.cursors[identity])
            XCTAssertEqual(cursor.entityId, before.entityId)
            XCTAssertEqual(cursor.version, before.version)
            XCTAssertEqual(cursor.server, before.server)
            XCTAssertEqual(cursor.deleteRejectRounds, before.deleteRejectRounds)
            XCTAssertEqual(cursor.rekeyRejectRounds, before.rekeyRejectRounds)
        }
        XCTAssertEqual(table.cursors["r1"]?.reconciled, baselineLive, "reconciled remains unchanged")
        XCTAssertEqual(table.cursors["r2"]?.reconciled, baselineGone, "reconciled remains unchanged")
        XCTAssertEqual(table.cursors["r2"]?.deletedAtMs, 1_234, "deletedAtMs remains unchanged")
        XCTAssertNil(table.cursors["r1"]?.deletedAtMs)
        XCTAssertFalse(store.deleted, "The file was not deleted")
        XCTAssertEqual(store.table.cursors.count, 2, "The persisted table also has two entries")
        XCTAssertEqual(store.table.cursors["r1"]?.entityId, "srv-r1")
        XCTAssertTrue(spaceStore.table.urlRulesReplayedForEmptyTable)
        XCTAssertTrue(spaceStore.table.urlRulesHadRecords, "Records prior publication by this device; changing stores does not alter it")
    }

    /// CASE 9.4, Task 9 fix round 1: exit 1 runs only after successful cursor persistence. Soft-deleted
    /// published r1 emits an accepted tombstone, but failing the final publication writeOwnedTable save keeps
    /// its row and yields .cursorSaveFailed. Disk retains the pre-publication baseline without deletedAtMs.
    /// Retry reloads disk, sends the tombstone again and hard-deletes only after applied plus durable cursor
    /// save.
    /// Calibrate save count in a live, unchanged round rather than hardcoding it: rules land empty batches and
    /// save on both landing and empty-work publication. Fail the next round's last save. Deleting before save
    /// loses the soft-deleted row's retry path, leaving an old live-looking disk cursor and no row for exit 2
    /// to protect.
    func test9_4_exit1IsSkippedWhenTheCursorTableSaveFails() async throws {
        let ruleHash = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.urlRuleClientTag("r1"))
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r1", sortOrder: 0),
        ])
        let store = MemoryOwnedItemStore()
        let baseline = baselineBytes(urlRulePayload(uuid: "r1"))
        store.table.cursors["r1"] = ownedCursor(reconciled: baseline, server: baseline,
                                                entityId: "srv-r1", version: 3, ownerUuid: "su-1")
        let spaceStore = makeSpaceStore()
        spaceStore.table.unreadableTagHashes[spaceHash("su-1")] = 1
        defaults.set(try Phi_PhiSettingEntity().serializedData(),
                     forKey: PhiSyncEngine.lastEntityStateKey)
        let client = FakePhiSyncClient()
        client.seed(tagHash: ruleHash, ciphertext: Data(), version: 3, entityId: "srv-r1")
        // Three empty scripted pages keep the seeded row solely for commit-update matching.
        client.scriptedPages = [page([], marker: "9"), page([], marker: "9"), page([], marker: "9")]
        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: spaceStore, ownedKinds: [urlRuleKind(access, store)])
        await engine.setSpaceSyncEnabled(true)

        // Calibration: live row projection equals baseline, so count saves with zero commits.
        await engine.pullOnce()
        let savesPerRound = store.saveCalls
        XCTAssertGreaterThan(savesPerRound, 0, "At least one table save per round at publication end")
        XCTAssertTrue(client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName }.isEmpty)

        // Editor soft-deletes r1; fail the round's final publication save.
        access.rows[0].deletedDate = Date(timeIntervalSince1970: 2_000)
        store.failSaveOnCallNumber = store.saveCalls + savesPerRound
        await engine.pullOnce()

        let firstTombstones = client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName && $0.deleted }
        XCTAssertEqual(firstTombstones.count, 1, "The tombstone was sent and applied while the publication gate was open")
        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed, "The publication save is the failing write")
        XCTAssertEqual(store.saveCalls, 2 * savesPerRound, "The failing save is last in the round")
        XCTAssertEqual(access.rows.count, 1, "Persistence failure preserves the row")
        XCTAssertNotNil(access.rows.first?.deletedDate, "The row remains soft-deleted")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty, "Exit 1 did not run")
        XCTAssertNil(store.table.cursors["r1"]?.deletedAtMs, "Disk retains the pre-publication table")
        XCTAssertEqual(store.table.cursors["r1"]?.pendingDelete, false, "The deletion decision did not persist either")
        XCTAssertNotNil(store.table.cursors["r1"]?.reconciled)

        // Retry reloads the disk cursor, emits the tombstone, receives applied, persists successfully and only
        // then runs exit 1.
        store.failSaveOnCallNumber = nil
        client.reseed(tagHash: ruleHash, ciphertext: Data(), version: 3)
        await engine.pullOnce()

        let secondOutcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(secondOutcome, .ok)
        XCTAssertTrue(access.rows.isEmpty, "Hard-delete only after successful persistence")
        XCTAssertEqual(access.hardDeleteCalls, ["r1"])
        XCTAssertNotNil(store.table.cursors["r1"]?.deletedAtMs, "deletedAtMs persisted this time")
        XCTAssertNil(store.table.cursors["r1"]?.reconciled)
    }

    // MARK: - CASE 9b.1–9b.3: pin lifecycle

    /// CASE 9b.1: resurrection is an update using the tombstone entityId/version. Deterministic
    /// migratePinnedTabs lineage returns (LX,pu-1) after Profile → Space → Profile (R-M3-3-23). The
    /// intermediate absence caused deletion, but R-M3-3-7 preserves metadata. A baseVersion 0 create would be
    /// rejected for version mismatch every round.
    func testAResurrectedPinPublishesAsAnUpdateOverTheTombstonedVersion() async throws {
        let spaceAccess = makeSpaceAccess()
        // Align row createdDate with pinPayload's 1_000 ms; fixture default 1_000 seconds would permanently
        // differ from baseline.
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LX", guid: "px", index: 0, createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // Finalized deletion: accepted tombstone clears both baselines and sets deletedAtMs while retaining
        // entityId/version (R-M3-3-7).
        var tombstoned = PhiOwnedItemCursor()
        tombstoned.entityId = "e-lx"
        tombstoned.version = 42
        tombstoned.deletedAtMs = 900
        tombstoned.ownerUuid = "pu-1"
        pinStore.table.cursors["lx:pu-1"] = tombstoned
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = pinCommits(client)
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(commits.count, 1, "Only this entity should publish this round")
        XCTAssertEqual(commits.first?.entityId, "e-lx", "① Reuse the tombstone entity")
        XCTAssertEqual(commits.first?.baseVersion, 42, "② Reuse its version, not 0")
        XCTAssertEqual(commits.first?.deleted, false, "③ A live update, not a tombstone")
        XCTAssertEqual(counters?.resurrected, 1)
        XCTAssertNil(table.cursors["lx:pu-1"]?.deletedAtMs,
                     "④ Clear deletedAtMs after accepted resurrection or §4.2(3b) resurrects it every round")
    }

    /// CASE 9b.2 / T9a-2: purge protection uses complete pin identity, not lineage, with A12 live-row safety.
    /// Identity is lineage:eligibilityOwner and cursor.ownerUuid is always that same owner, so pin rehome is
    /// structurally unreachable; owner change is old-identity tombstone plus new create (§7.2).
    /// Delete lx:su-1 when its lineage survives only under space-b; lineage-only matching would protect it
    /// forever. Retain lz:su-1 when its actual live row remains in the purged Space after data-cascade
    /// failure. Delete rowless ly:su-1. Removing a live cursor permits blind creates; retaining a truly
    /// obsolete owner cursor defeats §9.3 cleanup.
    func testThePinRetentionCascadeMatchesOnTheFullIdentityNotTheBareLineage() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1", "space-b": "su-2"])
        let spaceStore = makeSpaceStore()
        // su-1 already completed 30-day purge and retains phase-1 purgedAtMs.
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        let created = Date(timeIntervalSince1970: 1)
        // In Space scope, a row's owner is its Space syncUuid.
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px", spaceId: "space-b", index: 0,
                     createdDate: created),
            .fixture(lineageId: "LZ", guid: "pz", spaceId: "space-a", index: 1,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        for identity in ["lx:su-1", "ly:su-1", "lz:su-1"] {
            pinStore.table.cursors[identity] = ownedCursor(entityId: "srv-" + identity,
                                                           version: 1, ownerUuid: "su-1")
        }

        let engine = makeEngine(client: FakePhiSyncClient(), access: spaceAccess,
                                store: spaceStore, ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertNil(table.cursors["lx:su-1"],
                     "① Same lineage under another owner does not claim this identity; remove it")
        XCTAssertNil(table.cursors["ly:su-1"], "② No row means removal")
        XCTAssertNotNil(table.cursors["lz:su-1"],
                        "③ The row remains in the purged Space; A12 protects its cursor")
        XCTAssertEqual(table.cursors["lz:su-1"]?.ownerUuid, "su-1",
                       "④ Unchanged ownership needs no rehome")
        XCTAssertEqual(counters?.rehomedCursors, 0,
                       "⑤ Pin identity contains owner, making the rehome branch unreachable")
        XCTAssertNil(pinStore.table.cursors["lx:su-1"], "⑥ Persisted")
        XCTAssertNotNil(pinStore.table.cursors["lz:su-1"])
    }

    /// R-exec-11 ①: in Space scope, an out-of-scope profile backup protects only its own identity. Mac B on
    /// 2026-09-14 retained such a backup after migration, then unpinned the default-space copy. Lineage-only
    /// presence prevented that Space tombstone forever. Complete identity preserves lx:pu-1 (R-exec-4) while
    /// allowing absent lx:su-1 to tombstone.
    func testAnOutOfScopeBackupRowProtectsOnlyItsOwnPinIdentity() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let created = Date(timeIntervalSince1970: 1)
        // No rows in current Space scope: the user just unpinned the space-a copy.
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [])
        // Migration retained a profile-shaped backup visible through allPinRows but not allPins.
        pinAccess.outOfScopeRows = [
            .fixture(lineageId: "LX", guid: "p-backup", spaceId: nil, index: 0,
                     createdDate: created),
        ]
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "e-space", owner: "su-1")
        pinStore.table.cursors["lx:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "pu-1"), entityId: "e-backup", owner: "pu-1")
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = pinCommits(client).filter(\.deleted)
        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(tombstones.map(\.entityId), ["e-space"],
                       "① Tombstone the identity without a local row")
        XCTAssertEqual(counters?.tombstones, 1)
        XCTAssertNil(table.cursors["lx:pu-1"]?.deleteDecidedAtMs,
                     "② The backup's own identity remains protected from deletion (R-exec-4)")
    }

    /// R-exec-11 ②: deleting one of two Space copies tombstones only that complete identity (§7.2). Same
    /// lineage elsewhere never proves this identity lives. This is an overcorrection guard, not the original
    /// bug probe: old inScope handling already passed here. Ensure adding backup rows to the domain does not
    /// protect sibling-owner cursors; the preceding backup-row test is the direct regression.
    func testDeletingOneSpaceCopyTombstonesOnlyThatPinIdentity() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1", "space-b": "su-2"])
        let created = Date(timeIntervalSince1970: 1)
        // space-a's copy remains; space-b's copy was just unpinned.
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px", spaceId: "space-a", index: 0,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "e-a", owner: "su-1")
        pinStore.table.cursors["lx:su-2"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-2"), entityId: "e-b", owner: "su-2")
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = pinCommits(client).filter(\.deleted)
        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(tombstones.map(\.entityId), ["e-b"],
                       "① Only the identity whose row is actually gone emits a tombstone")
        XCTAssertEqual(counters?.tombstones, 1)
        XCTAssertNil(table.cursors["lx:su-1"]?.deleteDecidedAtMs,
                     "② The identity with a surviving row is unchanged")
    }

    /// R-exec-11 ③ / §4.5: remote deletion of (LX,space-a) removes only that row without parking while
    /// (LX,space-b) survives. Lineage-only post-landing verification would misread the sibling as failed
    /// deletion and park forever. This matches Mac B's minute-long parking after A unpinned Test Space on
    /// 2026-09-14; pair with the two diff-side cases above.
    func testARemotePinTombstoneLandsWhileTheSameLineageSurvivesInAnotherSpace() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1", "space-b": "su-2"])
        let created = Date(timeIntervalSince1970: 1)
        // Two Space copies of one lineage are separate account entities (R-M3-3-15).
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "pa", spaceId: "space-a", index: 0,
                     createdDate: created),
            .fixture(lineageId: "LX", guid: "pb", spaceId: "space-b", index: 0,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // Both identities were published. Tombstones have no payload, so §5.1 tag reverse lookup relies on
        // cursor keys, the pin index's sole seed.
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "e-a", owner: "su-1")
        pinStore.table.cursors["lx:su-2"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-2"), entityId: "e-b", owner: "su-2")
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: pinTag("lx", owner: "su-1"), version: 8,
                                  entityId: "e-a")]),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(pinAccess.lastAppliedOps, [.delete(guid: "pa")],
                       "① This batch contains only that deletion; cross-owner lineage is not a variant and does not remint")
        XCTAssertEqual(pinAccess.rows.map(\.guid), ["pb"], "② The copy in the other Space remains unchanged")
        XCTAssertEqual(counters?.applied, 1, "③ Applied rather than parked")
        XCTAssertEqual(counters?.parked, 0)
        XCTAssertFalse(table.cursors["lx:su-1"]?.pendingTombstone ?? false,
                       "④ Not parked in the work set")
        XCTAssertNotNil(table.cursors["lx:su-1"]?.deletedAtMs, "⑤ Deletion is finalized")
        XCTAssertNil(table.cursors["lx:su-2"]?.deleteDecidedAtMs,
                     "⑥ The identity with a surviving row is unchanged")
    }

    /// R-exec-11 ④: unresolved backup ownership conservatively protects all cursors of that lineage. Unlike
    /// CASE 9b.2's known different owner, unresolved mapping cannot prove a row is unrelated. Premature
    /// deletion during transient mapping failure risks a blind baseVersion 0 overwrite; conservative retention
    /// costs only another retention interval.
    func testAnUnresolvableOwnerOnABackupRowKeepsItsLineagesCursors() async throws {
        // space-gone is absent from mappings, so this backup's owner cannot resolve this round.
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let spaceStore = makeSpaceStore()
        // su-1 already completed 30-day purge, making its pin cursors sweep candidates.
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [])
        pinAccess.outOfScopeRows = [
            .fixture(lineageId: "LX", guid: "p-backup", spaceId: "space-gone", index: 0,
                     createdDate: created),
        ]
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = ownedCursor(entityId: "srv-lx", version: 1,
                                                        ownerUuid: "su-1")

        let engine = makeEngine(client: FakePhiSyncClient(), access: spaceAccess,
                                store: spaceStore, ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertNotNil(table.cursors["lx:su-1"],
                        "① Unresolved ownership conservatively protects all cursors for that lineage")
        XCTAssertEqual(table.cursors["lx:su-1"]?.ownerUuid, "su-1",
                       "② Claim only, without rewriting ownership; source 1 alone writes ownerUuid")
        XCTAssertEqual(counters?.rehomedCursors, 0)
        // Assertion ③ is secondary protection: dropped == 0 and rehomed == 0 skips persistence, so the
        // directly seeded memory cursor alone cannot expose the current defect. Keep it for future accidental
        // cleanup during save; assertion ① is decisive.
        XCTAssertNotNil(pinStore.table.cursors["lx:su-1"], "③ Persisted")
    }

    /// CASE 9b.3 / T6b-1: equal-rank pins tie-break by normalized pin_uuid lineage (§2.4), never
    /// device-specific guid. GUID ordering can reverse between devices and cause endless conflicting rank
    /// publication. Both engines may share defaults here because each fake client's scriptedPages is
    /// sequential and ignores markers.
    func testEqualRanksBreakTheTieOnPinUuidNotTheDeviceLocalGuid() async throws {
        /// Land one round on a device and return lineage → final index.
        func land(guidForLA: String, guidForLB: String) async -> [String: Int] {
            let created = Date(timeIntervalSince1970: 1)
            let access = FakePinAccess(scope: .profile, account: .profile, rows: [
                .fixture(lineageId: "LA", guid: guidForLA, index: 0, createdDate: created),
                .fixture(lineageId: "LB", guid: guidForLB, index: 1, createdDate: created),
            ])
            let store = MemoryOwnedItemStore()
            // Distinct baseline ranks become equal remotely, producing move steps for both pins and a full
            // dense permutation of their touched owner.
            store.table.cursors["la:pu-1"] = publishedPinCursor(
                pinPayload(lineage: "la", rank: "V"), entityId: "srv-la")
            store.table.cursors["lb:pu-1"] = publishedPinCursor(
                pinPayload(lineage: "lb", rank: "W"), entityId: "srv-lb")
            let client = FakePhiSyncClient()
            client.scriptedPages = [page([
                remoteEntity(envelope(pinPayload(lineage: "la", rank: "K", rankStamp: 500)),
                             tag: pinTag("la"), version: 10, entityId: "srv-la", key: key),
                remoteEntity(envelope(pinPayload(lineage: "lb", rank: "K", rankStamp: 500)),
                             tag: pinTag("lb"), version: 11, entityId: "srv-lb", key: key),
            ])]

            let engine = makeEngine(client: client, access: makeSpaceAccess(),
                                    store: makeSpaceStore(),
                                    ownedKinds: [pinKind(access, store)])
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()

            var out: [String: Int] = [:]
            for row in access.rows { out[row.lineageId] = row.index }
            return out
        }

        // Device one: local guid order matches lineage order.
        let deviceA = await land(guidForLA: "p-1", guidForLB: "p-2")
        // Device two: the same pin pair has reversed local guid order.
        let deviceB = await land(guidForLA: "p-9", guidForLB: "p-0")

        XCTAssertEqual(deviceA["LA"], 0, "① Order by pin_uuid: la < lb")
        XCTAssertEqual(deviceA["LB"], 1)
        XCTAssertEqual(deviceB["LA"], 0, "② Reversed GUID order must yield identical final ordering")
        XCTAssertEqual(deviceB["LB"], 1)
        XCTAssertEqual(deviceA, deviceB, "③ Both devices converge to the same pin order")
    }

    // MARK: - CASE 9b.4: mid-round scope migration (R-exec-12 / D-A)

    /// Follower about to migrate: local/account scopes are Space with two Space rows. Incoming entities were
    /// published after the peer moved to Profile and carry profile owners.
    private func migratingPinAccess() -> FakePinAccess {
        // Align createdDate with pinPayload's 1_000 ms as above.
        let created = Date(timeIntervalSince1970: 1)
        return FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px-space", spaceId: "space-a",
                     profileId: "Default", index: 0, createdDate: created),
            .fixture(lineageId: "LY", guid: "py-space", spaceId: "space-a",
                     profileId: "Default", index: 1, createdDate: created),
        ])
    }

    /// After Task 8 follower migration: same lineages, Profile-shaped rows with new physical GUIDs, and both
    /// scopes profile.
    @MainActor
    private func applyFollowerMigration(_ access: FakePinAccess) {
        let created = Date(timeIntervalSince1970: 1)
        access.scope = .profile
        access.account = .profile
        access.rows = [
            .fixture(lineageId: "LX", guid: "px-profile", spaceId: nil,
                     profileId: "Default", index: 0, createdDate: created),
            .fixture(lineageId: "LY", guid: "py-profile", spaceId: nil,
                     profileId: "Default", index: 1, createdDate: created),
        ]
        // Migration rebuilt the physical rows, invalidating the round snapshot. Production clears it without
        // rereading.
        access.beginRound()
    }

    /// Two entities published after the peer switched to Profile, owned by profile UUID.
    private func profileScopedPinPage() -> FakePhiSyncClient.Page {
        page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "pu-1")),
                         tag: pinTag("lx", owner: "pu-1"), version: 10, entityId: "srv-lx",
                         key: key),
            remoteEntity(envelope(pinPayload(lineage: "ly", ownerKey: "pu-1")),
                         tag: pinTag("ly", owner: "pu-1"), version: 11, entityId: "srv-ly",
                         key: key),
        ])
    }

    /// CASE 9b.4 / R-exec-12 / D-A: if scope changes after entry sampling but before landing, §7.3 parks every
    /// arrival with no landing or publication. Mac B build 821 sampled Space locals/scopes before page 1;
    /// incoming settings switched account scope and detached follower migration rebuilt Profile rows 15 ms
    /// later. Frozen Space identities no longer matched Profile arrivals, causing duplicate creates beside
    /// migrated rows despite originally matching scopes. A11 would remint those duplicates irreversibly into
    /// new account lineages.
    func testAScopeMigrationLandingMidRoundParksTheInboundInsteadOfDuplicatingRows() async throws {
        let pinAccess = migratingPinAccess()
        // Run follower migration immediately after entry sampling; beginRound performs accountScope read 1.
        pinAccess.midRoundMigration = (onAccountScopeRead: 1, run: applyFollowerMigration)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [profileScopedPinPage()]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(counters?.applied, 0, "① No entities landed")
        XCTAssertEqual(counters?.parked, 2, "② Both arrivals are parked")
        XCTAssertEqual(counters?.scopeMismatch, true,
                       "③ §11.2 scope_mismatch records scope blocking this pin round")
        XCTAssertEqual(pinAccess.rows.count, 2,
                       "④ Storage contains only the two migrated rows, without duplicates")
        XCTAssertEqual(Set(pinAccess.rows.map(\.guid)), ["px-profile", "py-profile"],
                       "⑤ The surviving rows came from migration, not landing")
        XCTAssertFalse(pinAccess.calls.contains { if case .apply = $0 { return true }
                                                  else { return false } },
                       "⑥ Skip all landing; A11 remint also uses GUIDs invalidated by row replacement")
        XCTAssertEqual(counters?.relineaged, 0)
        XCTAssertEqual(counters?.pushed, 0, "⑦ Skip the entire publication section")
        XCTAssertTrue(pinCommits(client).isEmpty)
        XCTAssertNotNil(table.cursors["lx:pu-1"]?.pendingApply,
                        "⑧ Parking preserves payload in the cursor after marker passed the page")
        XCTAssertNotNil(table.cursors["ly:pu-1"]?.pendingApply)
        // A6: parking also harvests server metadata. These cursors are newly created after marker advances;
        // missing metadata can never be recovered from this version's replay (Mac B build 822, 2026-09-14).
        XCTAssertEqual(table.cursors["lx:pu-1"]?.entityId, "srv-lx",
                       "⑨ Parked-created cursors retain the arriving entityId")
        XCTAssertEqual(table.cursors["lx:pu-1"]?.version, 10)
        XCTAssertEqual(table.cursors["ly:pu-1"]?.entityId, "srv-ly")
        XCTAssertEqual(table.cursors["ly:pu-1"]?.version, 11)
    }

    /// CASE 9b.4b / R-exec-12: next round lands parked pins through update without reminting. Fresh entry
    /// sampling sees consistent new rows/scopes, so (lineage,profileUuid) matches before the create fallback.
    /// This proves D-A convergence with exactly two rows throughout.
    func testTheParkedInboundLandsAsUpdatesOnTheNextRoundWithNoRelineage() async throws {
        let pinAccess = migratingPinAccess()
        pinAccess.midRoundMigration = (onAccountScopeRead: 1, run: applyFollowerMigration)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // Page two is empty; parking retries without another remote delivery.
        client.scriptedPages = [profileScopedPinPage(), page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(counters?.applied, 2, "① Round two lands both parked entities")
        XCTAssertEqual(counters?.relineaged, 0,
                       "② No reminting; each local identity has one row throughout")
        XCTAssertEqual(counters?.scopeMismatch, false, "③ Scope is stable this round")
        XCTAssertEqual(pinAccess.rows.count, 2, "④ Local row count remains 2")
        XCTAssertEqual(Set(pinAccess.rows.map(\.guid)), ["px-profile", "py-profile"],
                       "⑤ Landing updates the two existing rows")
        XCTAssertFalse(pinAccess.lastAppliedOps.contains { if case .create = $0 { return true }
                                                           else { return false } },
                       "⑥ Landing uses update, not create")
        XCTAssertTrue(pinAccess.lastAppliedOps.contains { if case .update = $0 { return true }
                                                          else { return false } })
        XCTAssertNil(table.cursors["lx:pu-1"]?.pendingApply, "⑦ Parking is resolved")
        XCTAssertNil(table.cursors["ly:pu-1"]?.pendingApply)
        // Post-landing cursors must match direct landing exactly. Empty page two provides no plan.harvest
        // metadata, so only parking-time harvest can supply entityId/version. Without it these identities
        // cannot tombstone and only publish blind baseVersion 0 creates.
        XCTAssertEqual(table.cursors["lx:pu-1"]?.entityId, "srv-lx",
                       "⑧ entityId survives parked landing")
        XCTAssertEqual(table.cursors["lx:pu-1"]?.version, 10, "⑨ Version matches the arriving entity")
        XCTAssertEqual(table.cursors["ly:pu-1"]?.entityId, "srv-ly")
        XCTAssertEqual(table.cursors["ly:pu-1"]?.version, 11)
        XCTAssertNotNil(table.cursors["lx:pu-1"]?.reconciled, "⑩ Baseline persists normally")
    }

    /// CASE 9b.4g: two plan steps for one missing local identity produce exactly one create. Mac B build 824
    /// on 2026-09-14 received title and rank changes with a baseline but no row, yielding move + update. A
    /// per-step create loop appended the same new GUID twice, making GUID-indexed writes ambiguous and
    /// crashing the sidebar's unique-key dictionary. Deduplicate at identity granularity.
    func testOneIdentityWithTwoStepsStillCreatesExactlyOneRow() async throws {
        // Only another lineage exists in this local Space; missing lx takes the create branch.
        let pinAccess = FakePinAccess(scope: .space, account: .space,
                                      rows: [.fixture(lineageId: "LY", guid: "py",
                                                      spaceId: "s-1", profileId: "Default")])
        let pinStore = MemoryOwnedItemStore()
        // Baseline rank V and title T.
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1", rank: "V", title: "T",
                       rankStamp: 100, contentStamp: 100),
            owner: "su-1")
        let client = FakePhiSyncClient()
        // Arrival changes rank and title, producing move + update for one identity.
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "su-1", rank: "W",
                                             title: "T2", rankStamp: 200, contentStamp: 200)),
                         tag: pinTag("lx", owner: "su-1"), version: 9, entityId: "srv-p1",
                         key: key),
        ])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let creates = pinAccess.lastAppliedOps.filter {
            if case .create = $0 { return true } else { return false }
        }
        XCTAssertEqual(creates.count, 1, "① Two steps produce exactly one create")
        XCTAssertEqual(pinAccess.rows.filter { PinKind.lineageKey($0.lineageId) == "lx" }.count, 1,
                       "② Storage has one row for this identity")
        XCTAssertEqual(Set(pinAccess.rows.map(\.guid)).count, pinAccess.rows.count,
                       "③ No rows share a GUID, preventing the observed crash")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(counters?.applied, 1, "④ Normal landing result is preserved")
    }

    /// CASE 9b.4h: inbound owner shape incompatible with local scope must park every round without creating
    /// rows. Mac B's 2026-09-14 crash/restart loop had a stale Profile-owned c0020f0d entity after Space
    /// migration. Its rank/title changes produced move + update; resolving the profile then defaulting missing
    /// spaceId created duplicate default-Space rows beside migrated pins. Post-landing verification still
    /// queried Profile ownership, failed forever and reparked, while A11 repeatedly collapsed duplicates
    /// between rounds. Shared GUIDs crashed sidebar startup. Run two rounds to prove retries never add rows.
    func testAnInboundOwnerShapeThatDisagreesWithTheLocalScopeIsParked() async throws {
        // Local rows are Space-shaped, with the migrated lineage already present in its Space.
        let pinAccess = FakePinAccess(scope: .space, account: .space,
                                      rows: [.fixture(lineageId: "LX", guid: "px-space",
                                                      spaceId: "s-1", profileId: "Default")])
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // A stale Profile-owned entity arrives for the same lineage. Empty page two retries parking,
        // reproducing the observed loop.
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "pu-1")),
                         tag: pinTag("lx"), version: 9, entityId: "srv-p1", key: key),
        ]), page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        var table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(counters?.applied, 0, "① No entities landed")
        XCTAssertEqual(counters?.parked, 1, "② The incompatible entity remains parked")
        XCTAssertEqual(pinAccess.rows.count, 1, "③ Storage retains the single row without duplicates")
        XCTAssertEqual(pinAccess.rows.first?.guid, "px-space")
        XCTAssertNotNil(table.cursors["lx:pu-1"]?.pendingApply,
                        "④ Parking retains payload until scopes converge")

        await engine.pullOnce()

        counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(counters?.parked, 1, "⑤ Still parked in round two")
        XCTAssertEqual(pinAccess.rows.count, 1,
                       "⑥ Retry creates no rows, breaking the per-round recreation loop")
        XCTAssertEqual(pinAccess.rows.first?.guid, "px-space")
        XCTAssertFalse(pinAccess.lastAppliedOps.contains { if case .create = $0 { return true }
                                                           else { return false } },
                       "⑦ No create operation was ever produced")
        XCTAssertNotNil(table.cursors["lx:pu-1"]?.pendingApply, "⑧ Payload remains until scopes converge")
    }

    /// CASE 9b.4e / R-exec-1 / A6: after parked landing, local unpin emits one tombstone using actual
    /// entityId/baseVersion. Build 822 wrote seven parked-created cursors with empty metadata, which marker
    /// replay could never repair. Unpin then hit §9.1's empty-entityId guard and finalized locally without
    /// sending a tombstone. This user-visible deletion test extends 9b.4b's metadata assertions to the
    /// consequence.
    func testAnUnpinAfterAParkedLandingTombstonesTheEntityItLandedFrom() async throws {
        let pinAccess = migratingPinAccess()
        pinAccess.midRoundMigration = (onAccountScopeRead: 1, run: applyFollowerMigration)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // Three rounds: scope mismatch parks, parked entities land, then local unpin emits a tombstone.
        client.scriptedPages = [profileScopedPinPage(), page([]), page([])]
        // Seed actual account rows matching scripted entityId/version so round ③'s update-style tombstone can
        // receive applied.
        client.seed(tagHash: pinHash("lx", owner: "pu-1"), ciphertext: Data(), version: 10,
                    entityId: "srv-lx")
        client.seed(tagHash: pinHash("ly", owner: "pu-1"), ciphertext: Data(), version: 11,
                    entityId: "srv-ly")

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.pullOnce()

        // The user unpins LX; its row disappears while LY remains.
        pinAccess.rows.removeAll { $0.lineageId == "LX" }
        await engine.pullOnce()

        let tombstones = pinCommits(client).filter(\.deleted)
        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(tombstones.count, 1, "① Exactly one call tombstone")
        XCTAssertEqual(tombstones.first?.entityId, "srv-lx",
                       "② Carries the actual entityId, not empty")
        XCTAssertEqual(tombstones.first?.baseVersion, 10,
                       "③ Base version comes from parking-time harvest")
        XCTAssertEqual(tombstones.first?.clientTagHash, pinHash("lx", owner: "pu-1"))
        XCTAssertEqual(counters?.tombstones, 1)
        XCTAssertNotNil(table.cursors["lx:pu-1"]?.deletedAtMs,
                        "④ Finalize deletion after server acceptance")
        XCTAssertNil(table.cursors["ly:pu-1"]?.deletedAtMs, "⑤ The identity with a surviving row is unchanged")
    }

    /// CASE 9b.4f / R-exec-1: repair existing cursors with baseline but missing entityId by forcing
    /// publication even when bytes match. Build 822's damaged tables cannot self-repair through replay behind
    /// marker. Server uniqueness on client_tag_hash makes the create recover the original srv ID rather than
    /// duplicate the entity; assertion ③ proves that critical behavior.
    func testABaselinedCursorWithNoEntityIdRepublishesToReKeyItself() async throws {
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px", spaceId: "space-a", index: 0,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // Build-822 damaged cursor: baseline and owner present, server metadata empty.
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "", version: 0, owner: "su-1")
        let client = FakePhiSyncClient()
        // The account entity srv-lx exists, but an empty page prevents delivery behind marker. Only
        // publication can repair its metadata.
        client.seed(tagHash: pinHash("lx", owner: "su-1"), ciphertext: Data(), version: 10,
                    entityId: "srv-lx")
        client.scriptedPages = [page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = pinCommits(client)
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(commits.count, 1,
                       "① Equal snapshot/baseline bytes still publish once through rekey only")
        XCTAssertNil(commits.first?.entityId, "② Publish as create because no local entityId is available")
        XCTAssertEqual(commits.first?.deleted, false)
        XCTAssertEqual(table.cursors["lx:su-1"]?.entityId, "srv-lx",
                       "③ Recover the account row's existing ID without creating another entity")
        XCTAssertGreaterThan(table.cursors["lx:su-1"]?.version ?? 0, 0, "④ Version is repaired too")
        XCTAssertNotNil(table.cursors["lx:su-1"]?.reconciled)
        XCTAssertNil(table.cursors["lx:su-1"]?.rekeyRejectRounds, "⑤ Successful repair resets consecutive rejections")
    }

    /// CASE 9b.4g / R-exec-13 / F-PK-2: abandon rekey after three consecutive rejected rounds, then send
    /// nothing. Rekey uniquely publishes even when snapshot equals baseline; without the limit it retries
    /// every 60 seconds forever, like the tombstone problem addressed in M3-2 §5.1. Unlike tombstone
    /// abandonment, the row remains live, so reconciled/deletedAtMs must stay unchanged; disable only this
    /// repair route.
    func testAGivenUpReKeyStopsCommittingAfterThreeRejections() async throws {
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px", spaceId: "space-a", index: 0,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "", version: 0, owner: "su-1")
        let client = FakePhiSyncClient()
        // Every commit for this tag returns INVALID_MESSAGE without changing account bytes.
        client.refuseCommitsForTagHashes = [pinHash("lx", owner: "su-1")]
        // Five empty scripted rounds prevent fallback reads from empty stored state.
        client.scriptedPages = Array(repeating: page([]), count: 5)

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        for _ in 0..<5 { await engine.pullOnce() }

        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(pinCommits(client).count, 3,
                       "① No rearming after three rounds; rounds four/five publish nothing")
        XCTAssertEqual(table.cursors["lx:su-1"]?.rekeyRejectRounds, 3, "② The cursor records abandonment")
        XCTAssertEqual(table.cursors["lx:su-1"]?.entityId, "", "③ ID is still absent, confirming repair failed")
        XCTAssertNotNil(table.cursors["lx:su-1"]?.reconciled,
                        "④ Abandonment preserves baseline because the local row remains live")
        XCTAssertNil(table.cursors["lx:su-1"]?.deletedAtMs,
                     "⑤ Do not write deletedAtMs; rekey abandonment differs from tombstone abandonment")
        XCTAssertEqual(pinAccess.rows.count, 1, "⑥ The local row remains untouched throughout")
    }

    /// CASE 9b.4h / R-exec-13 / F-PK-4: inbound harvest restores identity and resets consecutive rekey
    /// rejection count. Later independent metadata loss gets all three attempts, rather than inheriting two
    /// stale failures and stopping after one (four total commits under the defect). Phase two's arrival
    /// exactly matches baseline, yielding no plan steps, so it isolates harvest itself.
    func testAHarvestedEntityIdClearsTheRekeyStrikes() async throws {
        let created = Date(timeIntervalSince1970: 1)
        let original = PhiLocalPin.fixture(lineageId: "LX", guid: "px", spaceId: "space-a",
                                           index: 0, createdDate: created)
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [original])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "", version: 0, owner: "su-1")
        let client = FakePhiSyncClient()
        client.refuseCommitsForTagHashes = [pinHash("lx", owner: "su-1")]
        let arrival = page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "su-1")),
                         tag: pinTag("lx", owner: "su-1"), version: 10, entityId: "srv-lx",
                         key: key),
        ])
        // Eight rounds: 2 in phase one, 1 each in phases two/three, 3 in phase four, then a final check.
        client.scriptedPages = [page([]), page([]), arrival] + Array(repeating: page([]), count: 5)

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)

        // Phase one: two rejected rekey rounds produce two commits and two consecutive failures.
        await engine.pullOnce()
        await engine.pullOnce()
        var table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(pinCommits(client).count, 2, "① One attempt in each round")
        XCTAssertEqual(table.cursors["lx:su-1"]?.rekeyRejectRounds, 2, "② Two consecutive failures")

        // Phase two: a remote update arrives and harvest restores identity.
        await engine.pullOnce()
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(table.cursors["lx:su-1"]?.entityId, "srv-lx", "③ Identity is restored")
        XCTAssertNil(table.cursors["lx:su-1"]?.rekeyRejectRounds, "④ Reset consecutive failures too")
        XCTAssertEqual(pinCommits(client).count, 2,
                       "⑤ No publication: ID is restored and content matches baseline")

        // Phase three: later independent damage. A local title edit publishes normally and is rejected,
        // clearing identity through invalidMessage's live branch. This is not rekey and must not increment its
        // rejection count.
        pinAccess.rows[0].title = "\u{6539}\u{8fc7}\u{7684}\u{6807}\u{9898}"
        await engine.pullOnce()
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(pinCommits(client).count, 3, "⑥ One normal content publication")
        XCTAssertEqual(table.cursors["lx:su-1"]?.entityId, "", "⑦ Invalid outcome clears identity again")
        XCTAssertNil(table.cursors["lx:su-1"]?.rekeyRejectRounds,
                     "⑧ Rejected normal content publication does not count as rekey failure")
        // Restore the title so snapshot equals baseline; only rekey can publish during phase four.
        pinAccess.rows[0] = original

        // Phase four gets all three attempts, then abandons.
        for _ in 0..<4 { await engine.pullOnce() }
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(pinCommits(client).count, 6,
                       "⑨ 3 + 3 commits: later damage gets three fresh attempts; without reset total would be four")
        XCTAssertEqual(table.cursors["lx:su-1"]?.rekeyRejectRounds, 3, "⑩ Abandon only after three attempts")
        XCTAssertNotNil(table.cursors["lx:su-1"]?.reconciled, "⑪ Abandonment still preserves baseline")
        XCTAssertEqual(pinAccess.rows.count, 1)
    }

    /// CASE 9b.4c / R-exec-12 / §11.2: a push-only round has no arrivals, plan or landing, so pinSnapshot's
    /// scope recheck is the sole protection. The observed minute-long 25-round loop came from coordinator
    /// defaults debounce (PhiChromiumCoordinator.swift:601–610). Checking only plan would publish
    /// pre-migration rows with fresh now while scope_mismatch stayed false.
    func testAPushOnlyRoundSkipsThePublishWhenTheScopeMovesUnderIt() async throws {
        let pinAccess = migratingPinAccess()
        // Scope read 1 is beginRound; read 2 is pinSnapshot because plan/landing do not run. Inject after read
        // 1 so entry samples match, followed immediately by migration.
        pinAccess.midRoundMigration = (onAccountScopeRead: 1, run: applyFollowerMigration)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // Empty page: no arrivals, so applyOwnedKind returns before plan.
        client.scriptedPages = [page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(counters?.scopeMismatch, true,
                       "① Publication recheck detects changed scope, skips the section and records it")
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertTrue(pinCommits(client).isEmpty,
                      "② Neither pre-migration row is republished; both would publish without the gate")
    }

    /// CASE 9b.4d positive control: the same push-only fixture publishes two entities when scope does not
    /// change. Without it, a closed gate, incomplete mapping or filtered rows could make 9b.4c's zero-commit
    /// assertion vacuous.
    func testThePushOnlyControlRoundStillPublishesWhenTheScopeHoldsStill() async throws {
        let pinAccess = migratingPinAccess()        // No hook: scope remains space throughout
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(counters?.scopeMismatch, false)
        XCTAssertEqual(pinCommits(client).count, 2,
                       "Stable scope publishes both entities that 9b.4c blocks")
    }
}

// MARK: - External review: unpublished local edits

extension PhiSyncEngineOwnedItemsTests {

    /// Other half of spec §12.1 engine item 8: a pending local rename meets a remote edit to another content
    /// field. The existing remote-move case produced no update and missed this bug. Merging against reconciled
    /// alone excludes the pending rename and writes the old title through the four-field update patch,
    /// silently erasing the user's edit without commits or counters.
    func testAnUnpublishedLocalRenameSurvivesARemoteEditOfAnotherField() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        // Account and baseline still contain the old title; local rename has not published.
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "\u{65e7}\u{6807}\u{9898}"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        // The peer edits URL without changing title, but the shared content stamp restamps title too.
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "\u{65e7}\u{6807}\u{9898}", url: "https://peer.example",
                            contentStamp: 2_000_000, createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let row = access.rows.first { $0.guid == "G1" }
        XCTAssertEqual(row?.title, "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}", "① Preserve the unpublished local rename")
        XCTAssertEqual(row?.url.absoluteString, "https://peer.example",
                       "② The peer's actual edit lands normally")
        let commits = bookmarkCommits(client)
        let sent = commits.first.flatMap(committedBookmark)
        XCTAssertEqual(commits.count, 1, "③ The locally won field must reach the account through mustRepublish")
        XCTAssertEqual(sent?.title.stringValue, "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}", "③ Carries the local title")
        XCTAssertEqual(sent?.url.stringValue, "https://peer.example", "③ Also carries the peer's URL")
        XCTAssertEqual(commits.first?.baseVersion, 42, "④ Publication uses the version just pulled")
    }

    /// Equivalent pin regression; external review reproduced both kinds.
    func testAnUnpublishedLocalPinRenameSurvivesARemoteUrlEdit() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LX", guid: "P1", spaceId: nil, profileId: "Default",
                     title: "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}", createdDate: Date(timeIntervalSince1970: 1_000),
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["lx:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", title: "\u{65e7}\u{6807}\u{9898}", createdAtMs: 1_000_000),
            entityId: "srv-p1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", title: "\u{65e7}\u{6807}\u{9898}",
                                             url: "https://peer.example",
                                             contentStamp: 2_000_000, createdAtMs: 1_000_000)),
                         tag: pinTag("lx"), version: 42, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let row = access.rows.first { $0.guid == "P1" }
        XCTAssertEqual(row?.title, "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}", "① Preserve the unpublished local rename")
        XCTAssertEqual(row?.url.absoluteString, "https://peer.example", "② The peer's edit lands normally")
        let sent = pinCommits(client).first.flatMap(committedPin)
        XCTAssertEqual(pinCommits(client).count, 1, "③ The locally won field must reach the account")
        XCTAssertEqual(sent?.title.stringValue, "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}")
    }
}

// MARK: - External review: interrupted multipage pull

extension PhiSyncEngineOwnedItemsTests {

    /// Page 2 throws after page 1 has been consumed by the persisted marker. Routed page-1 create/tombstone
    /// work must not die with round-local variables; the server will never resend it, leaving a permanently
    /// missing bookmark and unapplied deletion despite healthy counters.
    func testAPullInterruptedAfterTheMarkerMovedKeepsWhatTheEarlierPagesDelivered() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GD", syncId: "b-doomed", spaceId: "s-1", index: 0),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b-doomed"] = publishedCursor(alignedPayload(uuid: "b-doomed"),
                                                          entityId: "srv-doomed", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([
                remoteEntity(envelope(alignedPayload(uuid: "b-new", title: "\u{5bf9}\u{7aef}\u{5efa}\u{7684}")),
                             tag: bookmarkTag("b-new"), version: 30, entityId: "srv-new",
                             key: key),
                remoteTombstone(tag: bookmarkTag("b-doomed"), version: 31,
                                entityId: "srv-doomed"),
            ], marker: "31", changesRemaining: true),
        ]
        client.getUpdatesErrorAfterPages = (pages: 1, error: PhiSyncProtocolError.http(500))

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.count, 2, "Precondition: page 1 arrives and page 2 throws")
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                        "Precondition: page 1's marker advancement persists")
        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b-new"]?.pendingApply, "① Park the live entity instead of discarding it")
        XCTAssertEqual(table.cursors["b-new"]?.entityId, "srv-new", "① Harvest server metadata (A6)")
        XCTAssertEqual(table.cursors["b-new"]?.pendingOwnerUuid, "su-1")
        XCTAssertEqual(table.cursors["b-doomed"]?.pendingTombstone, true,
                       "② Preserve the remote tombstone too")
        XCTAssertEqual(table.cursors["b-doomed"]?.version, 31, "② Harvest the tombstone version too")

        // Next round receives nothing behind the advanced marker and relies entirely on the two saved cursor
        // records.
        await engine.pullOnce()

        XCTAssertNotNil(access.rows.first { $0.syncId == "b-new" }, "③ The create eventually lands")
        XCTAssertNil(access.rows.first { $0.guid == "GD" }, "③ The remote deletion eventually applies too")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b-new"]?.pendingApply, "Clear parking only after landing")
        XCTAssertEqual(table.cursors["b-doomed"]?.pendingTombstone, false)
        XCTAssertNotNil(table.cursors["b-doomed"]?.deletedAtMs)
    }
}

// MARK: - External review: tombstones during scope mismatch

extension PhiSyncEngineOwnedItemsTests {

    /// Engine wiring for spec §12.1(15): scope-mismatched tombstones enter pendingTombstone. plan emits no
    /// steps on mismatch, so step-only parking paths would silently lose remote deletion after metadata
    /// harvest and marker advancement, leaving a healthy-looking cursor and permanently live local pin.
    func testAScopeMismatchRoundKeepsAnInboundPinTombstoneUntilTheScopesAgree() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        // Local Space scope versus account Profile scope triggers §7.3 mismatch.
        let pinAccess = FakePinAccess(scope: .space, account: .profile, rows: [
            .fixture(lineageId: "LX", guid: "P1", spaceId: "space-a", profileId: "Default",
                     createdDate: Date(timeIntervalSince1970: 1_000)),
        ])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1", createdAtMs: 1_000_000),
            entityId: "srv-lx", version: 5, owner: "su-1")
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteTombstone(tag: pinTag("lx", owner: "su-1"), version: 12, entityId: "srv-lx"),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("pins")
        XCTAssertNotNil(pinAccess.rows.first { $0.guid == "P1" },
                        "Precondition: the mismatched round lands nothing")
        XCTAssertEqual(table.cursors["lx:su-1"]?.pendingTombstone, true,
                       "① Retain remote deletion in the cursor until scopes converge")
        XCTAssertEqual(table.cursors["lx:su-1"]?.version, 12, "② Harvest server metadata (A6)")

        // The first converged-scope round applies deletion solely from the persisted pending flag.
        pinAccess.account = .space
        await engine.pullOnce()

        XCTAssertNil(pinAccess.rows.first { $0.guid == "P1" },
                     "③ Apply remote deletion in the first converged round")
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(table.cursors["lx:su-1"]?.pendingTombstone, false)
        XCTAssertNotNil(table.cursors["lx:su-1"]?.deletedAtMs)
    }
}

// MARK: - External review: equal values with newer inbound stamps

extension PhiSyncEngineOwnedItemsTests {

    private func baselineTitle(_ bytes: Data?) -> Phi_PhiSettingValue? {
        guard let bytes, let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = BookmarkKind.entity(from: envelope) else { return nil }
        return entity.title
    }

    /// A peer changes title A → B → A. Landing needs no row changes but baseline must absorb the newer stamp,
    /// or a later replay of older B can win against a stale comparison baseline.
    func testASameValueUpdateStillMovesTheBaselineForwardSoALaterOlderEditLoses() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "A"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "A"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            // ① A@300 matches local values with a newer stamp.
            oneEntityPage(bookmarkPayload(uuid: "b1", title: "A", contentStamp: 300,
                                          createdAtMs: Self.rowCreatedAtMs),
                          uuid: "b1", version: 42, entityId: "srv-b1"),
            // ② Then older B@200 arrives via replay, a third device or marker rollback.
            oneEntityPage(bookmarkPayload(uuid: "b1", title: "B", contentStamp: 200,
                                          createdAtMs: Self.rowCreatedAtMs),
                          uuid: "b1", version: 43, entityId: "srv-b1"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(baselineTitle(table.cursors["b1"]?.reconciled)?.updatedAtMs, 300,
                       "① Baseline absorbs the newer stamp")
        XCTAssertEqual(applyCallCount(access), 0, "① Landing needs no work and produces no empty patch")

        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.title, "A",
                       "② Older B@200 loses to account A@300 without changing the local row")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(baselineTitle(table.cursors["b1"]?.reconciled)?.stringValue, "A")
    }
}

// MARK: - Review regressions F-CX-2 / F-CX-3

extension PhiSyncEngineOwnedItemsTests {

    /// F-CX-2: entry local read fails after shared marker consumes the page. Preserve accepted create/deletion
    /// bytes for retry; returning and discarding them loses both forever. R-exec-3 blocks this kind's outbound
    /// work, not retention of already received payloads.
    func testAFailedLocalReadStillKeepsWhatTheMarkerAlreadyConsumed() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GD", syncId: "b-doomed", spaceId: "s-1", index: 0),
        ])
        access.readError = LocalStoreWriteError.storeUnavailable
        let store = MemoryOwnedItemStore()
        store.table.cursors["b-doomed"] = publishedCursor(alignedPayload(uuid: "b-doomed"),
                                                          entityId: "srv-doomed", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(alignedPayload(uuid: "b-new", title: "\u{5bf9}\u{7aef}\u{5efa}\u{7684}")),
                         tag: bookmarkTag("b-new"), version: 30, entityId: "srv-new", key: key),
            remoteTombstone(tag: bookmarkTag("b-doomed"), version: 31, entityId: "srv-doomed"),
        ], marker: "500")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("bookmarks")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.localReadFailed, 1, "Precondition: this round's local read actually throws")
        XCTAssertEqual(applyCallCount(access), 0, "Precondition: the entire landing section was skipped")
        XCTAssertNotNil(table.cursors["b-new"]?.pendingApply, "① Park the live entity instead of discarding it")
        XCTAssertEqual(table.cursors["b-new"]?.entityId, "srv-new", "① Harvest server metadata (A6)")
        XCTAssertEqual(table.cursors["b-doomed"]?.pendingTombstone, true,
                       "② Preserve the remote tombstone too")
        XCTAssertEqual(table.cursors["b-doomed"]?.version, 31)

        // First round after reads recover lands both records despite no new server delivery.
        access.readError = nil
        await engine.pullOnce()

        XCTAssertNotNil(access.rows.first { $0.syncId == "b-new" }, "③ The create eventually lands")
        XCTAssertNil(access.rows.first { $0.guid == "GD" }, "③ The remote deletion eventually applies too")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b-new"]?.pendingApply)
        XCTAssertEqual(table.cursors["b-doomed"]?.pendingTombstone, false)
    }

    /// F-CX-3 ①: a locally won field outside this round's 250-item slice must publish next round. Round-local
    /// must-republish state would disappear while local bytes already match reconciled; durable server !=
    /// reconciled retains the need.
    func testALocallyWonMergeThatMissesThePublishSliceGoesOutOnALaterRound() async throws {
        let alphabet = Array("123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        func fillerRank(_ index: Int) -> String {
            "V" + String(alphabet[index / alphabet.count]) + String(alphabet[index % alphabet.count])
        }
        let spaceAccess = makeSpaceAccess()
        // ① Locally won zz-won sorts after every filler by depth/identity and therefore falls outside the
        // 250-item slice.
        var rows: [PhiLocalBookmark] = [
            .fixture(guid: "G-won", syncId: "zz-won", spaceId: "s-1", index: 0,
                     title: "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ]
        let store = MemoryOwnedItemStore()
        store.table.cursors["zz-won"] = publishedCursor(
            alignedPayload(uuid: "zz-won", rank: "B", title: "\u{65e7}\u{6807}\u{9898}"),
            entityId: "srv-won", version: 7)
        // ② 260 locally renamed rows awaiting publication fill this round's slice.
        for index in 0..<260 {
            let identity = String(format: "f-%03d", index)
            rows.append(.fixture(guid: "G-" + identity, syncId: identity, spaceId: "s-1",
                                 index: index + 1, title: "new",
                                 contentUpdatedDate: Date(timeIntervalSince1970: 500)))
            store.table.cursors[identity] = publishedCursor(
                alignedPayload(uuid: identity, rank: fillerRank(index), title: "old"),
                entityId: "srv-" + identity, version: 2)
        }
        let access = FakeBookmarkAccess(rows: rows)
        let client = FakePhiSyncClient()
        // The peer edits URL while the local rename remains unpublished, so merge keeps the local title.
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "zz-won", rank: "B", title: "\u{65e7}\u{6807}\u{9898}",
                            url: "https://peer.example", contentStamp: 2_000_000,
                            createdAtMs: Self.rowCreatedAtMs),
            uuid: "zz-won", version: 42, entityId: "srv-won")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let firstRound = bookmarkCommits(client)
        XCTAssertEqual(firstRound.count, 250, "Precondition: this round's slice is full")
        XCTAssertFalse(firstRound.contains { $0.clientTagHash == bookmarkHash("zz-won") },
                       "Precondition: the locally won entity is outside the slice")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotEqual(table.cursors["zz-won"]?.server, table.cursors["zz-won"]?.reconciled,
                          "① The cursor durably records different server and landed bytes")

        await engine.pullOnce()

        let later = Array(bookmarkCommits(client).dropFirst(firstRound.count))
        let sent = later.first { $0.clientTagHash == bookmarkHash("zz-won") }
            .flatMap(committedBookmark)
        XCTAssertNotNil(sent, "② Publish next round after the round-local set is long gone")
        XCTAssertEqual(sent?.title.stringValue, "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}", "② Carries the local title")
    }

    /// F-CX-3 ②: interruption between landing and publishing, modeled by commit error, must preserve
    /// republication into the next round. Retirement, sign-out and process exit have the same shape.
    func testALocallyWonMergeSurvivesAFailedCommitAndPublishesNextRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "\u{65e7}\u{6807}\u{9898}"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "\u{65e7}\u{6807}\u{9898}", url: "https://peer.example",
                            contentStamp: 2_000_000, createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]
        client.commitErrorOnce = URLError(.timedOut)

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 1, "Precondition: that round attempted publication and threw")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotEqual(table.cursors["b1"]?.server, table.cursors["b1"]?.reconciled,
                          "① The cursor retains the publication requirement")

        await engine.pullOnce()

        let later = Array(bookmarkCommits(client).dropFirst(1))
        XCTAssertEqual(later.count, 1, "② Republish exactly once next round")
        XCTAssertEqual(later.first.flatMap(committedBookmark)?.title.stringValue, "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}")
        let settled = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(settled.cursors["b1"]?.server, settled.cursors["b1"]?.reconciled,
                       "③ Acceptance aligns both baselines and clears the requirement, preventing endless republication")
    }
}

// MARK: - Review regression F-CX-4: never publish identities with parked remote deletion

extension PhiSyncEngineOwnedItemsTests {

    /// F-CX-4 ①: pending remote tombstone plus server != reconciled must not enter publication. An update
    /// using the tombstone's harvested baseVersion would revive the account entity; later local tombstone
    /// retry deletes the row, leaving an unclaimed remote ghost. §4.2(3) excludes it from the adapter
    /// snapshot, and engine liveCandidates/persistent-republish sets also guard it. Assert the outcome
    /// regardless of which gate blocks it.
    func testACursorWaitingToLandARemoteTombstoneIsNeverPublished() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        // An import lock keeps this round's tombstone parked in its cursor.
        access.importingSpaceIds = ["space-a"]
        let store = MemoryOwnedItemStore()
        // An earlier local field win left different server and landed baselines, creating a durable
        // republication requirement.
        var cursor = publishedCursor(alignedPayload(uuid: "b1"), entityId: "srv-b1", version: 3)
        cursor.server = baselineBytes(alignedPayload(uuid: "b1", title: "\u{8d26}\u{6237}\u{4e0a}\u{7684}\u{65e7}\u{6807}\u{9898}"))
        store.table.cursors["b1"] = cursor
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: bookmarkTag("b1"), version: 8, entityId: "srv-b1")],
                 marker: "500"),
            page([], marker: "500"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors["b1"]?.pendingTombstone, true, "Precondition: the deletion is parked")
        XCTAssertNotEqual(table.cursors["b1"]?.server, table.cursors["b1"]?.reconciled,
                          "Precondition: a durable republication requirement exists")
        XCTAssertTrue(bookmarkCommits(client).filter { !$0.deleted }.isEmpty,
                      "① Publish no live entities, which would resurrect the deleted identity")

        // ② The first round after import ends applies the deletion.
        access.importingSpaceIds = []
        await engine.pullOnce()

        let settled = await engine.ownedTableForTesting("bookmarks")
        XCTAssertTrue(access.rows.isEmpty, "② The remote deletion eventually applies")
        XCTAssertNotNil(settled.cursors["b1"]?.deletedAtMs)
        XCTAssertTrue(bookmarkCommits(client).filter { !$0.deleted }.isEmpty,
                      "② Neither round publishes any live entity")
    }

    /// F-CX-4 ②: a local edit during parking must also be blocked. This uses ordinary snapshot-versus-baseline
    /// diff instead of persistent republication, with the same resurrection risk as ①.
    func testALocalEditIsNotPublishedWhileARemoteTombstoneIsParked() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            // Local title differs from baseline, representing an unpublished edit.
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a", title: "\u{672c}\u{673a}\u{65b0}\u{6807}\u{9898}",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        access.importingSpaceIds = ["space-a"]
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "\u{65e7}\u{6807}\u{9898}"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: bookmarkTag("b1"), version: 8, entityId: "srv-b1")],
                 marker: "500"),
            page([], marker: "500"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors["b1"]?.pendingTombstone, true, "Precondition: the deletion is parked")
        XCTAssertTrue(bookmarkCommits(client).filter { !$0.deleted }.isEmpty,
                      "① Do not publish the local edit this round")

        access.importingSpaceIds = []
        await engine.pullOnce()

        XCTAssertTrue(access.rows.isEmpty, "② The deletion lands normally next round")
        XCTAssertTrue(bookmarkCommits(client).filter { !$0.deleted }.isEmpty)
    }
}

// MARK: - 2026-09-15 commit storm: convergence (R-exec-16) and conflict retry (R-exec-17)

extension PhiSyncEngineOwnedItemsTests {

    /// Each device owns defaults/marker/state, local rows and cursor store, sharing one fake server. Rows have
    /// identical syncId and content stamps but different local GUIDs and createdDate values 11 minutes apart,
    /// matching the Google bookmark independently created before pairing in the observed incident.
    private func makeCreationStampDevice(
        _ name: String, client: FakePhiSyncClient, createdAtMs: Int64
    ) -> (engine: PhiSyncEngine, access: FakeBookmarkAccess, suite: String) {
        let suite = "PhiSyncEngineOwnedItemsTests.\(name).\(UUID().uuidString)"
        let deviceDefaults = UserDefaults(suiteName: suite)!
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G-\(name)", syncId: "b1", spaceId: "s-1",
                     createdDate: Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000),
                     contentUpdatedDate: Date(timeIntervalSince1970: 1)),
        ])
        let store = MemoryOwnedItemStore()
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: deviceDefaults, deviceKeyId: "dev-\(name)", pairingComplete: true,
                                   settings: [], spaceAccess: makeSpaceAccess(),
                                   spaceStore: makeSpaceStore(),
                                   ownedKinds: [bookmarkKind(access, store)],
                                   now: { 1_700_000_000_000 })
        return (engine, access, suite)
    }

    /// CASE 17.1: different local creation times for one bookmark converge after one publication each.
    /// created_at_ms merges by min but BookmarkFieldPatch cannot persist that field locally. Re-emitting local
    /// creation time causes endless projection/reconciled and server/reconciled disagreement: the Mac A/B
    /// 2026-09-14 incident committed the same 176-byte bookmark twice each minute. Additional rounds must stay
    /// silent.
    func testTwoDevicesDisagreeingOnACreationDatePublishOnceEachAndThenGoQuiet() async throws {
        let earlier: Int64 = 1_789_370_308_853
        let later: Int64 = 1_789_370_985_148          // 11 minutes later
        let client = FakePhiSyncClient()
        // The later-timestamp device publishes first; the earlier device then corrects the account through
        // min.
        let deviceB = makeCreationStampDevice("B", client: client, createdAtMs: later)
        let deviceA = makeCreationStampDevice("A", client: client, createdAtMs: earlier)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: deviceB.suite)
            UserDefaults.standard.removePersistentDomain(forName: deviceA.suite)
        }
        await deviceB.engine.setSpaceSyncEnabled(true)
        await deviceA.engine.setSpaceSyncEnabled(true)

        // First round each: B creates the absent account entity, then A pulls and republishes the earlier
        // timestamp.
        await deviceB.engine.pullOnce()
        await deviceA.engine.pullOnce()
        let afterFirstExchange = bookmarkCommits(client).count

        // Four alternating rounds after convergence must emit nothing.
        for _ in 0..<2 {
            await deviceB.engine.pullOnce()
            await deviceA.engine.pullOnce()
        }

        XCTAssertEqual(afterFirstExchange, 2, "① Exactly one initial publication per device")
        XCTAssertEqual(bookmarkCommits(client).count, 2, "② Every subsequent round has zero commits")
        // ③ Each device retains its unwriteable local creation date, while account bytes converge to the
        // earlier value accepted by both.
        let rowB = deviceB.access.rows.first { $0.syncId == "b1" }
        let rowA = deviceA.access.rows.first { $0.syncId == "b1" }
        XCTAssertEqual(rowB?.createdDate, Date(timeIntervalSince1970: TimeInterval(later) / 1000))
        XCTAssertEqual(rowA?.createdDate, Date(timeIntervalSince1970: TimeInterval(earlier) / 1000))
        let published = bookmarkCommits(client).compactMap { committedBookmark($0)?.createdAtMs }
        XCTAssertEqual(published.last, earlier, "④ The account retains the earlier stamp")
    }

    /// CASE 17.2: conflict retry must use server_version from the response as base_version. If discarded, an
    /// empty intervening pull cannot repair the stale cursor and retry conflicts again. Combined with
    /// marker-triggered defaults observation this caused the observed 2.5-second loop; conflicts themselves
    /// log nothing.
    func testAConflictRetryCarriesTheServerVersionFromTheConflictResponse() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "\u{65b0}\u{6807}\u{9898}",
                     contentUpdatedDate: Date(timeIntervalSince1970: 3_000)),
        ])
        let store = MemoryOwnedItemStore()
        // Local cursor version 1 versus server version 9 guarantees a conflict.
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "\u{65e7}\u{6807}\u{9898}"),
                                                    entityId: "srv-b1", version: 1)
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(alignedPayload(uuid: "b1", title: "\u{65e7}\u{6807}\u{9898}")), key: key),
                    version: 9, entityId: "srv-b1")
        // Every pull is empty because marker exceeds all server versions. Thus only the conflict response can
        // update cursor.version, isolating whether the response is consumed.
        defaults.set(Data("999".utf8), forKey: PhiSyncEngine.markerStateKey)

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 2, "① One initial commit and one scoped retry")
        XCTAssertEqual(commits.first?.baseVersion, 1, "② The first attempt uses the local cursor version")
        XCTAssertEqual(commits.last?.baseVersion, 9, "③ Retry uses the version returned by the conflict response")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertGreaterThan(table.cursors["b1"]?.version ?? 0, 9,
                             "④ The server accepts the retry without another conflict")
        XCTAssertEqual(engine.statusSnapshot.phase, .upToDate,
                       "A successful owned-item retry must complete this round's status")
        XCTAssertNotNil(engine.statusSnapshot.lastSuccess)
    }

    /// The invariant a refused create protects: an entry that names no entity carries no base
    /// version. The server answers anything else with INVALID_MESSAGE, which zeroes the cursor
    /// triple and burns one of the three rekey-repair rounds (R-exec-13).
    private func assertEveryCreateCarriesNoBaseVersion(
        _ calls: [FakePhiSyncClient.CommitCall],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for call in calls where call.entityId == nil {
            XCTAssertEqual(call.baseVersion, 0,
                           "a commit naming no entity must carry base version 0",
                           file: file, line: line)
        }
    }

    /// CASE 17.3 / R-exec-17 / R-exec-1: the account refuses a create whose client tag already
    /// names a live row holding other content, and answers with that row's id and version. A
    /// cursor with a baseline but no entityId (the build-822 repair class) must harvest both, so
    /// its scoped retry is an update. Discarding the id while keeping the version is the one
    /// forbidden outcome: the retry would then name no entity at a nonzero base.
    func testARefusedCreateHarvestsTheIdentityTheAccountNamed() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "local-new",
                     contentUpdatedDate: Date(timeIntervalSince1970: 3_000)),
        ])
        let store = MemoryOwnedItemStore()
        // Baseline present, server identity missing: publication is the only repair route.
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "account-old"),
                                                    entityId: "", version: 0)
        let client = FakePhiSyncClient()
        client.conflictsOnLiveCreate = true
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(alignedPayload(uuid: "b1", title: "account-old")), key: key),
                    version: 9, entityId: "srv-b1")
        // Every pull is empty because the marker exceeds all server versions, so only the
        // conflict response itself can key the cursor.
        defaults.set(Data("999".utf8), forKey: PhiSyncEngine.markerStateKey)

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 2, "① One refused create and one scoped retry")
        XCTAssertNil(commits.first?.entityId, "② The first attempt is a create")
        XCTAssertEqual(commits.first?.baseVersion, 0, "②")
        XCTAssertEqual(commits.last?.entityId, "srv-b1",
                       "③ The retry names the row the conflict named")
        XCTAssertEqual(commits.last?.baseVersion, 9, "③ At the version it came with")
        assertEveryCreateCarriesNoBaseVersion(commits)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors["b1"]?.entityId, "srv-b1", "④ The cursor is keyed for good")
        XCTAssertGreaterThan(table.cursors["b1"]?.version ?? 0, 9,
                             "④ The account accepted the retry without another conflict")
        XCTAssertNil(table.cursors["b1"]?.rekeyRejectRounds,
                     "⑤ Repair succeeded, so no rejection streak survives it")
    }

    /// CASE 17.4 / R-exec-17: the same refusal with the row still reachable by pull. Both routes
    /// agree on the base version, and the round still converges after exactly one retry.
    func testARefusedCreateConvergesWhenTheScopedPullAlsoDeliversTheRow() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "local-new",
                     contentUpdatedDate: Date(timeIntervalSince1970: 3_000)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "account-old"),
                                                    entityId: "", version: 0)
        let client = FakePhiSyncClient()
        client.conflictsOnLiveCreate = true
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(alignedPayload(uuid: "b1", title: "account-old")), key: key),
                    version: 9, entityId: "srv-b1")
        // One empty page for the round's own pull; the scoped conflict pull that follows it falls
        // back to the seeded store and delivers the row.
        client.scriptedPages = [page([])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 2, "① One refused create and one scoped retry")
        XCTAssertNil(commits.first?.entityId, "②")
        XCTAssertEqual(commits.last?.entityId, "srv-b1", "③ The retry is an update")
        XCTAssertEqual(commits.last?.baseVersion, 9, "③ Harvest and pull agree on the base")
        assertEveryCreateCarriesNoBaseVersion(commits)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors["b1"]?.entityId, "srv-b1", "④")
        XCTAssertEqual(table.cursors["b1"]?.version,
                       client.stored[bookmarkHash("b1")]?.version,
                       "④ The cursor converges on the account's version")
    }

    /// CASE 17.5 / R-exec-17 / R-exec-13: a conflict that names no row, with an empty scoped
    /// pull, leaves the un-keyed cursor exactly as it was. Writing the version alone would make
    /// the retry a create at a nonzero base — INVALID_MESSAGE, a zeroed triple and one spent
    /// repair round — until the identity gave up entirely.
    func testAConflictWithoutAnIdNeverVersionsAnUnkeyedCursor() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "local-new",
                     contentUpdatedDate: Date(timeIntervalSince1970: 3_000)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "account-old"),
                                                    entityId: "", version: 0)
        let client = FakePhiSyncClient()
        // The first attempt and its scoped retry are both answered CONFLICT with a version and
        // no id; the round after them finds the account willing again.
        client.bareConflictRoundsForTagHashes = [bookmarkHash("b1"): 2]
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(alignedPayload(uuid: "b1", title: "account-old")), key: key),
                    version: 9, entityId: "srv-b1")
        defaults.set(Data("999".utf8), forKey: PhiSyncEngine.markerStateKey)

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(bookmarkCommits(client).count, 2, "① One create and one scoped retry")
        assertEveryCreateCarriesNoBaseVersion(bookmarkCommits(client))
        XCTAssertEqual(table.cursors["b1"]?.entityId, "", "② The cursor is still un-keyed")
        XCTAssertEqual(table.cursors["b1"]?.version, 0,
                       "② An identity-less cursor must never carry a version")
        XCTAssertNil(table.cursors["b1"]?.rekeyRejectRounds,
                     "③ A conflict is not a rejection: no repair round was spent")

        await engine.pullOnce()

        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(bookmarkCommits(client).count, 3, "④ The identity is retried, not given up")
        assertEveryCreateCarriesNoBaseVersion(bookmarkCommits(client))
        XCTAssertEqual(table.cursors["b1"]?.entityId, "srv-b1", "⑤ And it converges")
    }

    /// CASE 17.6 / R-exec-17: content the live row already holds is not a disagreement. The
    /// account answers the create SUCCESS at the EXISTING version without writing, so the cursor
    /// adopts that version and the next round publishes nothing.
    func testACreateMatchingTheLiveRowIsAcceptedWithoutANewVersion() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.conflictsOnLiveCreate = true
        client.identicalCreateTagHashes = [bookmarkHash("b1")]
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(alignedPayload(uuid: "b1")), key: key),
                    version: 9, entityId: "srv-b1")
        defaults.set(Data("999".utf8), forKey: PhiSyncEngine.markerStateKey)

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 1, "① One create, and no republication afterwards")
        assertEveryCreateCarriesNoBaseVersion(commits)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors["b1"]?.entityId, "srv-b1", "②")
        XCTAssertEqual(table.cursors["b1"]?.version, 9, "② The existing version, not a new one")
        XCTAssertEqual(client.stored[bookmarkHash("b1")]?.version, 9,
                       "③ The account row was never written")
    }

    // MARK: - CASE 2a.10(b)（R-M3-4a-16）

    /// CASE 2a.10(b): writeOwnedTable's retired early return is not failure. R-M3-4a-16 requires an actual
    /// save call returning failure; a stopped engine calls save zero times. Returning false from the stopped
    /// guard would wrongly suppress markers under Task 2b.
    func testAStoppedEngineNeverCallsTheOwnedStoreAtAll() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = makeSpaceStore()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteEntity(envelope(bookmarkPayload(uuid: "b1")),
                                                   tag: bookmarkTag("b1"), version: 7,
                                                   entityId: "e1", key: key)],
                                     marker: "m1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let ownedSaves = store.saveCalls
        let spaceSaves = spaceStore.saveCalls
        XCTAssertGreaterThan(ownedSaves, 0, "Precondition: the landing round actually saved the cursor table")

        engine.shutdown()
        await engine.handleLocalOwnedChange(label: "bookmarks")

        XCTAssertEqual(store.saveCalls, ownedSaves, "No cursor-table save calls after retirement")
        XCTAssertEqual(spaceStore.saveCalls, spaceSaves, "The same holds for the Space table")
    }
}

// MARK: - C4 "edit beats delete" at the engine level

extension PhiSyncEngineOwnedItemsTests {

    /// Direction (i), flat: an inbound tombstone for a bookmark this device renamed but has not
    /// published keeps the row and republishes it OVER the tombstone, at the tombstone's own
    /// version. Convergence is by version, not by stamp: the account hands every device a
    /// strictly newer version of the same client tag, including the device that deleted it.
    func testATombstoneYieldsToAnUnpublishedRenameAndRepublishesAtTheTombstoneVersion() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a", title: "renamed",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "T"),
                                                    entityId: "srv-b1", version: 8)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: bookmarkTag("b1"), version: 8, entityId: "srv-b1")]),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.map(\.guid), ["G1"], "The edited row survives the tombstone")
        let live = bookmarkCommits(client).filter { !$0.deleted }
        XCTAssertEqual(live.count, 1, "The yield republishes exactly once")
        XCTAssertEqual(live.first?.baseVersion, 8, "Publish over the tombstone's own version")
        XCTAssertEqual(committedBookmark(live[0])?.title.stringValue, "renamed")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.resurrected, 1, "The resurrection is counted, not silent")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b1"]?.deletedAtMs, "An applied republish clears deletedAtMs")
    }

    /// The control: an untouched bookmark is still hard-deleted by the same tombstone, with no
    /// republication and no resurrection counted. Without this the test above could pass because
    /// yielding had become unconditional.
    func testATombstoneForAnUntouchedBookmarkStillDeletesIt() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 8)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: bookmarkTag("b1"), version: 8, entityId: "srv-b1")]),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.rows.isEmpty, "A never-edited row is deleted as before")
        XCTAssertTrue(bookmarkCommits(client).filter { !$0.deleted }.isEmpty)
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.resurrected, 0)
    }

    /// T1 and the cascade trap: tombstones for a folder and its child arrive together while this
    /// device holds an unpublished rename of the child. The child yields, the folder is deleted,
    /// and the child is LIFTED to the Space root inside the same landing batch — the folder
    /// delete must never carry a surviving child away with it, and the store refuses a folder
    /// delete that still has children, so the lift is what keeps the batch applying at all.
    func testAFolderDeletionLiftsTheChildThatYieldedInsteadOfCascading() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G-F", syncId: "f1", spaceId: "space-a", isFolder: true, title: "F"),
            .fixture(guid: "G-C", syncId: "c1", spaceId: "space-a", parentGuid: "G-F",
                     title: "renamed", contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["f1"] = publishedCursor(
            alignedPayload(uuid: "f1", isFolder: true, title: "F"), entityId: "srv-f1", version: 7)
        store.table.cursors["c1"] = publishedCursor(
            alignedPayload(uuid: "c1", parentUuid: "f1", title: "T"), entityId: "srv-c1",
            version: 8)
        let client = FakePhiSyncClient()
        // Subtree-first publication (A5): the child's tombstone precedes the folder's.
        client.scriptedPages = [
            page([remoteTombstone(tag: bookmarkTag("c1"), version: 8, entityId: "srv-c1"),
                  remoteTombstone(tag: bookmarkTag("f1"), version: 9, entityId: "srv-f1")]),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.map(\.guid), ["G-C"], "The folder is gone, the child survives")
        XCTAssertNil(access.rows.first?.parentGuid, "The survivor sits at the Space root")
        XCTAssertNotNil(access.rows.first?.locationUpdatedDate,
                        "The lift is a location decision this device has to defend")
        let live = bookmarkCommits(client).filter { !$0.deleted }
        XCTAssertEqual(live.count, 1, "Only the child republishes; the folder stays deleted")
        XCTAssertEqual(committedBookmark(live[0])?.bookmarkUuid, "c1")
        XCTAssertEqual(committedBookmark(live[0])?.parentUuid.stringValue, "",
                       "It comes back at the root, not inside the folder that was deleted")
        XCTAssertGreaterThan(committedBookmark(live[0])?.spaceUuid.updatedAtMs ?? 0, 0,
                             "A lifted location must not be stamped 0, which any peer overwrites")
    }

    /// Direction (ii): the local row is already gone and its deletion is in flight when a remote
    /// content edit stamped after the decision arrives. A9 cancels the deletion (C4-a) and the
    /// landing RECREATES the row; dropping the steps would let the next round's diff tombstone it
    /// again and the delete would win after all.
    func testAContentEditNewerThanTheDecisionCancelsADeleteAndRebuildsTheRow() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [])
        let store = MemoryOwnedItemStore()
        var cursor = publishedCursor(alignedPayload(uuid: "b1", title: "T"), entityId: "srv-b1",
                                     version: 8)
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = 1_000
        store.table.cursors["b1"] = cursor
        let client = FakePhiSyncClient()
        let edited = bookmarkPayload(uuid: "b1", title: "renamed", locationStamp: 100,
                                     contentStamp: 2_000, createdAtMs: Self.rowCreatedAtMs)
        client.scriptedPages = [
            page([remoteEntity(envelope(edited), tag: bookmarkTag("b1"), version: 9,
                               entityId: "srv-b1", key: key)]),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.map(\.title), ["renamed"], "The edit brought the row back")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors["b1"]?.pendingDelete, false)
        XCTAssertEqual(table.cursors["b1"]?.deleteDecidedAtMs, 0)
        XCTAssertTrue(bookmarkCommits(client).filter(\.deleted).isEmpty,
                      "No tombstone goes out for the identity whose deletion was cancelled")
    }

    /// T6: a PROFILE-scoped pin has no Space cursor, so a revocation check that only asks
    /// `spaceCursors[owner]` would withhold its yield every round, forever. It must republish.
    func testAYieldedProfileScopedPinStillRepublishes() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakePinAccess(scope: .profile, rows: [
            .fixture(lineageId: "LX", guid: "P1", profileId: "Default", title: "renamed",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["lx:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "pu-1", title: "T"), entityId: "srv-p1",
            version: 8)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: pinTag("lx"), version: 8, entityId: "srv-p1")]),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.map(\.guid), ["P1"], "The edited pin survives the tombstone")
        let live = pinCommits(client).filter { !$0.deleted }
        XCTAssertEqual(live.count, 1, "A Profile-scoped yield is admitted, not withheld")
        XCTAssertEqual(live.first?.baseVersion, 8)
        XCTAssertEqual(committedPin(live[0])?.title.stringValue, "renamed")
    }

    /// T4b: the resurrected pin's split partner was deleted and did not itself yield, so it comes
    /// back UNLINKED and silently. Nothing should be left waiting on a partner lineage that no
    /// longer exists anywhere.
    func testAResurrectedPinWhoseSplitPartnerDiedComesBackUnlinked() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        // The partner row is already gone: deleting a split pin clears the back-reference in the
        // same transaction, so the surviving row no longer names it.
        let access = FakePinAccess(scope: .profile, rows: [
            .fixture(lineageId: "LX", guid: "P1", profileId: "Default", title: "renamed",
                     splitPartnerLineageId: nil,
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["lx:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "pu-1", title: "T", splitPartner: "lq"),
            entityId: "srv-p1", version: 8)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: pinTag("lx"), version: 8, entityId: "srv-p1")]),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let live = pinCommits(client).filter { !$0.deleted }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(committedPin(live[0])?.splitPartnerUuid.stringValue, "",
                       "The dangling link is dropped, not carried forward forever")
        XCTAssertGreaterThan(committedPin(live[0])?.splitPartnerUuid.updatedAtMs ?? 0, 0,
                             "The cleared link carries a real stamp so a peer's stale link loses")
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertNil(table.cursors["lx:pu-1"]?.pendingPartnerLineage)
    }

    /// The sharpest risk in C4: a yield destroyed by the very next page. A tombstone is
    /// redelivered whenever a page is replayed -- a duplicate delivery, or the replay a failed
    /// marker write forces -- and by then yielding has cleared the baseline the derived predicate
    /// compares against. The identity must keep yielding while a live local row claims it.
    func testARedeliveredTombstoneDoesNotDestroyTheYieldItJustCreated() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a", title: "renamed",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "T"),
                                                    entityId: "srv-b1", version: 8)
        let client = FakePhiSyncClient()
        // Both pages belong to ONE pull, so the second arrives before any republish.
        client.scriptedPages = [
            page([remoteTombstone(tag: bookmarkTag("b1"), version: 8, entityId: "srv-b1")],
                 marker: "m1", changesRemaining: true),
            page([remoteTombstone(tag: bookmarkTag("b1"), version: 8, entityId: "srv-b1")],
                 marker: "m2"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.map(\.guid), ["G1"], "The second page must not delete the row")
        let live = bookmarkCommits(client).filter { !$0.deleted }
        XCTAssertEqual(live.count, 1, "One republish, not two")
        XCTAssertEqual(live.first?.baseVersion, 8)
    }
}
