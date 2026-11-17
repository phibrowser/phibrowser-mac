import CryptoKit
import Foundation
import XCTest
@testable import Phi

/// PHI-2046: a split of three or four panes syncs whole, for bookmarks (`split_extra_panes`) and
/// for pinned tabs (`split_pane_uuids`). The round-trip cases run two engines against one fake
/// server: device A publishes, device B pulls what A committed and lands it through its own access.
@MainActor
final class PhiSyncWiderSplitTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore
    typealias Clock = PhiSyncEngineSpaceTests.Clock

    private let key = SymmetricKey(size: .bits256)
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSpaceAccess() -> FakePhiSpaceAccess {
        let access = FakePhiSpaceAccess()
        access.spaceMappings = ["s-1": "su-1"]
        access.spaces = [PhiLocalSpace(spaceId: "s-1", profileId: "Default", name: "S",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                                       opacityLight: nil, opacityDark: nil)]
        access.uuidByProfileId = ["Default": "pu-1"]
        access.profileIdByUuid = ["pu-1": "Default"]
        access.knownLocalProfileIds = ["Default"]
        return access
    }

    /// One device: its own defaults suite, Space access and drained Space store, sharing `client`.
    private func makeDevice(_ name: String, client: FakePhiSyncClient,
                            ownedKinds: [OwnedKindRegistration]) -> PhiSyncEngine {
        let suite = "PhiSyncWiderSplitTests.\(name).\(UUID().uuidString)"
        suites.append(suite)
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        let clock = Clock()
        return PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                             defaults: UserDefaults(suiteName: suite)!, deviceKeyId: "dev-\(name)",
                             pairingComplete: true, settings: [], spaceAccess: makeSpaceAccess(),
                             spaceStore: store, ownedKinds: ownedKinds,
                             now: { clock.read() })
    }

    private func committedBookmarks(_ client: FakePhiSyncClient) -> [Phi_PhiBookmarkEntity] {
        bookmarkCommits(client).compactMap { call in
            guard let ciphertext = call.ciphertext,
                  let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
                  case .bookmark(let payload)? = entity.kind else { return nil }
            return payload
        }
    }

    private func committedPins(_ client: FakePhiSyncClient) -> [Phi_PhiPinTabEntity] {
        pinCommits(client).compactMap { call in
            guard let ciphertext = call.ciphertext,
                  let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
                  case .pinTab(let payload)? = entity.kind else { return nil }
            return payload
        }
    }

    private let extraPanes = [
        PhiLocalBookmark.ExtraPane(url: "https://c.example/", title: "C"),
        PhiLocalBookmark.ExtraPane(url: "https://d.example/", title: nil),
    ]

    private func fourPanePins() -> [PhiLocalPin] {
        let members = ["LA", "LB", "LC", "LD"]
        return members.enumerated().map { index, lineage in
            .fixture(lineageId: lineage, guid: "p\(index)", profileId: "Default", index: index,
                     title: lineage, url: URL(string: "https://\(lineage.lowercased()).example/")!,
                     splitPaneLineageIds: members,
                     createdDate: Date(timeIntervalSince1970: 1))
        }
    }

    private func widerSplitPin(_ lineage: String, members: [String],
                               stamp: Int64 = 500) -> Phi_PhiPinTabEntity {
        var payload = pinPayload(lineage: lineage, title: lineage,
                                 url: "https://\(lineage).example/")
        payload.splitPaneUuids = stamped(PinKind.encodePaneLineages(members), at: stamp)
        return payload
    }

    // MARK: - Bookmarks

    /// The reported symptom: a 4-pane split bookmark arrived with its left two panes only.
    func testAFourPaneSplitBookmarkReachesTheOtherDeviceWithAllFourPanes() async throws {
        let client = FakePhiSyncClient()
        let sender = FakeBookmarkAccess(rows: [
            .fixture(guid: "g1", spaceId: "s-1", title: "Split", url: URL(string: "https://a.example/")!,
                     secondaryUrl: URL(string: "https://b.example/")!, secondaryTitle: "B",
                     splitExtraPanes: extraPanes),
        ])
        let deviceA = makeDevice("A", client: client,
                                 ownedKinds: [.bookmarks(access: sender, store: MemoryOwnedItemStore())])
        await deviceA.setSpaceSyncEnabled(true)
        await deviceA.pullOnce()

        let published = committedBookmarks(client)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.secondaryURL.stringValue, "https://b.example/")
        XCTAssertEqual(published.first.map(BookmarkKind.extraPanes(of:)), extraPanes,
                       "Both panes after the first two are on the wire, in order")

        let receiver = FakeBookmarkAccess()
        let deviceB = makeDevice("B", client: client,
                                 ownedKinds: [.bookmarks(access: receiver, store: MemoryOwnedItemStore())])
        await deviceB.setSpaceSyncEnabled(true)
        await deviceB.pullOnce()

        XCTAssertEqual(receiver.rows.count, 1)
        let landed = try XCTUnwrap(receiver.rows.first)
        XCTAssertEqual(landed.url.absoluteString, "https://a.example/")
        XCTAssertEqual(landed.secondaryUrl?.absoluteString, "https://b.example/")
        XCTAssertEqual(landed.splitExtraPanes, extraPanes, "The receiver lands all four panes")
    }

    /// A 2-pane split (and every plain bookmark) publishes the same bytes an older client does:
    /// the new field stays absent, so the upgrade republishes nothing.
    func testATwoPaneSplitBookmarkLeavesTheExtraPanesFieldAbsent() async throws {
        let client = FakePhiSyncClient()
        let sender = FakeBookmarkAccess(rows: [
            .fixture(guid: "g1", spaceId: "s-1", url: URL(string: "https://a.example/")!,
                     secondaryUrl: URL(string: "https://b.example/")!),
        ])
        let deviceA = makeDevice("A", client: client,
                                 ownedKinds: [.bookmarks(access: sender, store: MemoryOwnedItemStore())])
        await deviceA.setSpaceSyncEnabled(true)
        await deviceA.pullOnce()

        let published = try XCTUnwrap(committedBookmarks(client).first)
        XCTAssertEqual(published.secondaryURL.stringValue, "https://b.example/")
        XCTAssertFalse(published.hasSplitExtraPanes)
    }

    /// An older client republishing its own edit drops the field it does not know. That payload
    /// carries no stamp for it, so the newer device's panes win the merge on either side.
    func testAnOlderClientsPayloadWithoutExtraPanesLosesToTheStampedPanes() {
        var newer = bookmarkPayload(uuid: "b1", contentStamp: 100)
        newer.secondaryURL = stamped("https://b.example/", at: 100)
        newer.splitExtraPanes = stamped(BookmarkKind.encodeExtraPanes(extraPanes), at: 100)
        var older = bookmarkPayload(uuid: "b1", title: "renamed", contentStamp: 900)
        older.secondaryURL = stamped("https://b.example/", at: 900)

        let mergedHere = BookmarkKind.merge(local: newer, remote: older)
        let mergedThere = BookmarkKind.merge(local: older, remote: newer)

        XCTAssertEqual(BookmarkKind.extraPanes(of: mergedHere), extraPanes)
        XCTAssertEqual(mergedHere.title.stringValue, "renamed", "The older client's edit still lands")
        XCTAssertEqual(mergedHere, mergedThere, "The merge is symmetric")
        XCTAssertFalse(BookmarkKind.merge(local: older, remote: older).hasSplitExtraPanes,
                       "Merging two payloads without the field does not invent it")
    }

    /// Removing the extra panes publishes the explicit "" once the account has seen them.
    func testRemovingTheExtraPanesPublishesTheClearedValue() throws {
        var baseline = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", contentStamp: 100)
        baseline.secondaryURL = stamped("https://b.example/", at: 100)
        baseline.splitExtraPanes = stamped(BookmarkKind.encodeExtraPanes(extraPanes), at: 100)
        let local = PhiLocalBookmark.fixture(guid: "g1", syncId: "b1", spaceId: "space-a",
                                             url: URL(string: "https://e.example")!,
                                             secondaryUrl: URL(string: "https://b.example/")!,
                                             contentUpdatedDate: Date(timeIntervalSince1970: 2))
        let projected = try XCTUnwrap(BookmarkKind.project(local, resolve: OwnerResolver.fixture(),
                                                           scope: nil, parentIdentity: nil))

        let stampedEntity = BookmarkKind.stamp(projected, baseline: baseline,
                                               local: local, rank: "V", now: 5_000)

        XCTAssertTrue(stampedEntity.hasSplitExtraPanes)
        XCTAssertEqual(stampedEntity.splitExtraPanes.stringValue, "")
        XCTAssertGreaterThan(stampedEntity.splitExtraPanes.updatedAtMs, 100)
    }

    // MARK: - Pinned tabs

    /// The reported symptom: each pane of a 4-pane pinned split arrived as a separate pinned tab.
    func testAFourPaneSplitOfPinnedTabsReachesTheOtherDeviceAsOneSplit() async throws {
        let client = FakePhiSyncClient()
        let sender = FakePinAccess(scope: .profile, account: .profile, rows: fourPanePins())
        let deviceA = makeDevice("A", client: client,
                                 ownedKinds: [.pins(access: sender, store: MemoryOwnedItemStore())])
        await deviceA.setSpaceSyncEnabled(true)
        await deviceA.pullOnce()

        let published = committedPins(client)
        XCTAssertEqual(published.count, 4)
        for pin in published {
            XCTAssertEqual(PinKind.paneLineages(of: pin), ["la", "lb", "lc", "ld"],
                           "Every member names all four, in pane order")
            XCTAssertEqual(pin.splitPartnerUuid.stringValue, "", "A wider split is not a pair")
        }

        let receiver = FakePinAccess(scope: .profile, account: .profile)
        let deviceB = makeDevice("B", client: client,
                                 ownedKinds: [.pins(access: receiver, store: MemoryOwnedItemStore())])
        await deviceB.setSpaceSyncEnabled(true)
        let commitsBefore = pinCommits(client).count
        await deviceB.pullOnce()

        XCTAssertEqual(receiver.rows.count, 4)
        for row in receiver.rows {
            XCTAssertEqual(row.splitPaneLineageIds.map(PinKind.lineageKey), ["la", "lb", "lc", "ld"],
                           "\(row.lineageId) lands as a member of the 4-pane split")
            XCTAssertNil(row.splitPartnerLineageId)
        }
        let echoed = committedPins(client).dropFirst(commitsBefore)
        XCTAssertFalse(echoed.contains { $0.splitPaneUuids.stringValue.isEmpty },
                       "Landing the split must not echo it back as an unsplit")
    }

    /// A 2-pane pinned split keeps the pair encoding and leaves the new field absent.
    func testAPinnedPairLeavesTheMemberListAbsent() async throws {
        let client = FakePhiSyncClient()
        let sender = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LA", guid: "p0", profileId: "Default", index: 0,
                     splitPartnerLineageId: "LB"),
            .fixture(lineageId: "LB", guid: "p1", profileId: "Default", index: 1,
                     url: URL(string: "https://b.example")!, splitPartnerLineageId: "LA"),
        ])
        let deviceA = makeDevice("A", client: client,
                                 ownedKinds: [.pins(access: sender, store: MemoryOwnedItemStore())])
        await deviceA.setSpaceSyncEnabled(true)
        await deviceA.pullOnce()

        let published = committedPins(client)
        XCTAssertEqual(published.count, 2)
        XCTAssertTrue(published.allSatisfy { !$0.hasSplitPaneUuids })
        XCTAssertEqual(Set(published.map(\.splitPartnerUuid.stringValue)), ["la", "lb"])
    }

    /// Members arriving in different rounds (design §7.4): a list naming a pin not landed yet is
    /// not written and not published as an unsplit; the member that completes it links the
    /// waiting ones in the same transaction.
    func testAWiderSplitWhoseMembersArriveAcrossRoundsLinksOnceTheLastOneLands() async throws {
        let members = ["la", "lb", "lc", "ld"]
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page(["la", "lb"].enumerated().map { index, lineage in
                remoteEntity(envelope(widerSplitPin(lineage, members: members)),
                             tag: PhiSyncEntity.pinClientTag(lineage, ownerKey: "pu-1"),
                             version: Int64(10 + index), entityId: "srv-\(lineage)", key: key)
            }, marker: "11"),
        ]
        let receiver = FakePinAccess(scope: .profile, account: .profile)
        let store = MemoryOwnedItemStore()
        let device = makeDevice("B", client: client,
                                ownedKinds: [.pins(access: receiver, store: store)])
        await device.setSpaceSyncEnabled(true)
        await device.pullOnce()

        XCTAssertEqual(receiver.rows.count, 2)
        XCTAssertTrue(receiver.rows.allSatisfy { $0.splitPaneLineageIds.isEmpty },
                      "Half a split is not written")
        var table = await device.ownedTableForTesting("pins")
        XCTAssertEqual(table.cursors["la:pu-1"]?.pendingPartnerLineage, "lc")
        XCTAssertFalse(committedPins(client).contains { $0.splitPaneUuids.stringValue.isEmpty },
                       "A waiting member re-emits its list instead of clearing it")

        client.scriptedPages = [
            page(["lc", "ld"].enumerated().map { index, lineage in
                remoteEntity(envelope(widerSplitPin(lineage, members: members)),
                             tag: PhiSyncEntity.pinClientTag(lineage, ownerKey: "pu-1"),
                             version: Int64(12 + index), entityId: "srv-\(lineage)", key: key)
            }, marker: "13"),
        ]
        await device.pullOnce()

        XCTAssertEqual(receiver.rows.count, 4)
        for row in receiver.rows {
            XCTAssertEqual(row.splitPaneLineageIds.map(PinKind.lineageKey), members,
                           "\(row.lineageId) is a member once every member has landed")
        }
        table = await device.ownedTableForTesting("pins")
        XCTAssertNil(table.cursors["la:pu-1"]?.pendingPartnerLineage)
        XCTAssertNil(table.cursors["lb:pu-1"]?.pendingPartnerLineage)
    }

    /// A local unsplit of a published wider split reaches the peers as the stamped "".
    func testUnsplittingAPublishedWiderSplitPublishesTheClearedList() async throws {
        let members = ["la", "lb", "lc", "ld"]
        let client = FakePhiSyncClient()
        let rows: [PhiLocalPin] = members.enumerated().map { index, lineage in
            .fixture(lineageId: lineage.uppercased(), guid: "p\(index)", profileId: "Default",
                     index: index, title: lineage, url: URL(string: "https://\(lineage).example/")!,
                     createdDate: Date(timeIntervalSince1970: 1))
        }
        let store = MemoryOwnedItemStore()
        for (index, lineage) in members.enumerated() {
            var baseline = widerSplitPin(lineage, members: members, stamp: 100)
            baseline.rank = stamped(["V", "W", "X", "Y"][index], at: 100)
            baseline.createdAtMs = 1_000
            store.table.cursors["\(lineage):pu-1"] = ownedCursor(
                reconciled: baselineBytes(baseline), server: baselineBytes(baseline),
                entityId: "srv-\(lineage)", version: 1, ownerUuid: "pu-1")
            // The account holds what the cursors say was published, so the unsplit is an update.
            client.seed(tagHash: PhiSyncEntity.clientTagHash(
                            for: PhiSyncEntity.pinClientTag(lineage, ownerKey: "pu-1")),
                        ciphertext: try PhiEntityCodec.encrypt(envelope(baseline), key: key),
                        version: 1, entityId: "srv-\(lineage)")
        }
        let access = FakePinAccess(scope: .profile, account: .profile, rows: rows)
        let device = makeDevice("A", client: client, ownedKinds: [.pins(access: access, store: store)])
        await device.setSpaceSyncEnabled(true)
        await device.pullOnce()

        let published = committedPins(client)
        XCTAssertEqual(Set(published.map(\.pinUuid)), Set(members))
        for pin in published {
            XCTAssertTrue(pin.hasSplitPaneUuids)
            XCTAssertEqual(pin.splitPaneUuids.stringValue, "", "\(pin.pinUuid) leaves the split")
            XCTAssertGreaterThan(pin.splitPaneUuids.updatedAtMs, 100,
                                 "The cleared list outranks the stale one")
        }
    }

    /// An older client's pin payload has no member list; it never erases a newer one.
    func testAnOlderClientsPinPayloadKeepsTheStampedMemberList() {
        let newer = widerSplitPin("la", members: ["la", "lb", "lc"], stamp: 100)
        let older = pinPayload(lineage: "la", title: "renamed", url: "https://la.example/",
                               contentStamp: 900)

        let mergedHere = PinKind.merge(local: newer, remote: older)
        let mergedThere = PinKind.merge(local: older, remote: newer)

        XCTAssertEqual(PinKind.paneLineages(of: mergedHere), ["la", "lb", "lc"])
        XCTAssertEqual(mergedHere.title.stringValue, "renamed")
        XCTAssertEqual(mergedHere, mergedThere)
        XCTAssertFalse(PinKind.merge(local: older, remote: older).hasSplitPaneUuids)
    }
}
