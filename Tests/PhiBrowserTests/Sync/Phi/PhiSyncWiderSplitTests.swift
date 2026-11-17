import CryptoKit
import Foundation
import SwiftData
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

    /// A side-by-side 2-pane split (and every plain bookmark) publishes the same bytes an older
    /// client does: the new fields stay absent, so the upgrade republishes nothing. An explicit
    /// "vertical" is the default too.
    func testATwoPaneSplitBookmarkLeavesTheExtraPanesFieldAbsent() async throws {
        let client = FakePhiSyncClient()
        let sender = FakeBookmarkAccess(rows: [
            .fixture(guid: "g1", spaceId: "s-1", url: URL(string: "https://a.example/")!,
                     secondaryUrl: URL(string: "https://b.example/")!, splitLayout: "vertical"),
        ])
        let deviceA = makeDevice("A", client: client,
                                 ownedKinds: [.bookmarks(access: sender, store: MemoryOwnedItemStore())])
        await deviceA.setSpaceSyncEnabled(true)
        await deviceA.pullOnce()

        let published = try XCTUnwrap(committedBookmarks(client).first)
        XCTAssertEqual(published.secondaryURL.stringValue, "https://b.example/")
        XCTAssertFalse(published.hasSplitExtraPanes)
        XCTAssertFalse(published.hasSplitLayout, "The default orientation is not on the wire")
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
                     splitPartnerLineageId: "LB", splitLayout: "vertical"),
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
        XCTAssertTrue(published.allSatisfy { !$0.hasSplitLayout }, "Side by side is not on the wire")
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

    // MARK: - Split orientation (split_layout)

    private func stackedPinRows() -> [PhiLocalPin] {
        let pair: [PhiLocalPin] = [
            .fixture(lineageId: "LA", guid: "p0", profileId: "Default", index: 0, title: "A",
                     url: URL(string: "https://a.example/")!, splitPartnerLineageId: "LB",
                     splitLayout: "horizontal", createdDate: Date(timeIntervalSince1970: 1)),
            .fixture(lineageId: "LB", guid: "p1", profileId: "Default", index: 1, title: "B",
                     url: URL(string: "https://b.example/")!, splitPartnerLineageId: "LA",
                     splitLayout: "horizontal", createdDate: Date(timeIntervalSince1970: 1)),
        ]
        let wide = ["LC", "LD", "LE", "LF"]
        return pair + wide.enumerated().map { index, lineage in
            .fixture(lineageId: lineage, guid: "p\(index + 2)", profileId: "Default", index: index + 2,
                     title: lineage, url: URL(string: "https://\(lineage.lowercased()).example/")!,
                     splitPaneLineageIds: wide, splitLayout: "horizontal",
                     createdDate: Date(timeIntervalSince1970: 1))
        }
    }

    /// Stacked 2-pane and 4-pane split bookmarks arrive stacked.
    func testStackedSplitBookmarksReachTheOtherDeviceStacked() async throws {
        let client = FakePhiSyncClient()
        let sender = FakeBookmarkAccess(rows: [
            .fixture(guid: "g1", spaceId: "s-1", index: 0, title: "Pair",
                     url: URL(string: "https://a.example/")!,
                     secondaryUrl: URL(string: "https://b.example/")!, splitLayout: "horizontal"),
            .fixture(guid: "g2", spaceId: "s-1", index: 1, title: "Four",
                     url: URL(string: "https://a.example/")!,
                     secondaryUrl: URL(string: "https://b.example/")!, splitExtraPanes: extraPanes,
                     splitLayout: "horizontal"),
        ])
        let deviceA = makeDevice("A", client: client,
                                 ownedKinds: [.bookmarks(access: sender, store: MemoryOwnedItemStore())])
        await deviceA.setSpaceSyncEnabled(true)
        await deviceA.pullOnce()

        let published = committedBookmarks(client)
        XCTAssertEqual(published.count, 2)
        XCTAssertTrue(published.allSatisfy { $0.splitLayout.stringValue == "horizontal" })

        let receiver = FakeBookmarkAccess()
        let deviceB = makeDevice("B", client: client,
                                 ownedKinds: [.bookmarks(access: receiver, store: MemoryOwnedItemStore())])
        await deviceB.setSpaceSyncEnabled(true)
        await deviceB.pullOnce()

        XCTAssertEqual(receiver.rows.count, 2)
        XCTAssertTrue(receiver.rows.allSatisfy { $0.splitLayout == "horizontal" })
        XCTAssertEqual(receiver.rows.first { $0.title == "Four" }?.splitExtraPanes, extraPanes)
    }

    /// A stacked pinned pair and a stacked 4-pane pinned split arrive stacked on every member.
    func testStackedPinnedSplitsReachTheOtherDeviceStacked() async throws {
        let client = FakePhiSyncClient()
        let sender = FakePinAccess(scope: .profile, account: .profile, rows: stackedPinRows())
        let deviceA = makeDevice("A", client: client,
                                 ownedKinds: [.pins(access: sender, store: MemoryOwnedItemStore())])
        await deviceA.setSpaceSyncEnabled(true)
        await deviceA.pullOnce()

        let published = committedPins(client)
        XCTAssertEqual(published.count, 6)
        XCTAssertTrue(published.allSatisfy { $0.splitLayout.stringValue == "horizontal" })

        let receiver = FakePinAccess(scope: .profile, account: .profile)
        let deviceB = makeDevice("B", client: client,
                                 ownedKinds: [.pins(access: receiver, store: MemoryOwnedItemStore())])
        await deviceB.setSpaceSyncEnabled(true)
        await deviceB.pullOnce()

        XCTAssertEqual(receiver.rows.count, 6)
        for row in receiver.rows {
            XCTAssertEqual(row.splitLayout, "horizontal", "\(row.lineageId) lands stacked")
        }
        XCTAssertEqual(Set(receiver.rows.compactMap(\.splitPartnerLineageId).map(PinKind.lineageKey)),
                       ["la", "lb"])
    }

    /// Changing the orientation after the first sync publishes it, and the peer applies it; going
    /// back to side by side publishes the stamped "" and the peer follows.
    func testAnOrientationChangeAfterTheFirstSyncPropagates() async throws {
        let client = FakePhiSyncClient()
        let bookmarks = FakeBookmarkAccess(rows: [
            .fixture(guid: "g1", spaceId: "s-1", url: URL(string: "https://a.example/")!,
                     secondaryUrl: URL(string: "https://b.example/")!),
        ])
        var rows = stackedPinRows()
        for index in rows.indices { rows[index].splitLayout = nil }
        let pins = FakePinAccess(scope: .profile, account: .profile, rows: rows)
        let deviceA = makeDevice("A", client: client, ownedKinds: [
            .bookmarks(access: bookmarks, store: MemoryOwnedItemStore()),
            .pins(access: pins, store: MemoryOwnedItemStore()),
        ])
        let receivedBookmarks = FakeBookmarkAccess()
        let receivedPins = FakePinAccess(scope: .profile, account: .profile)
        let deviceB = makeDevice("B", client: client, ownedKinds: [
            .bookmarks(access: receivedBookmarks, store: MemoryOwnedItemStore()),
            .pins(access: receivedPins, store: MemoryOwnedItemStore()),
        ])
        await deviceA.setSpaceSyncEnabled(true)
        await deviceB.setSpaceSyncEnabled(true)
        await deviceA.pullOnce()
        await deviceB.pullOnce()
        XCTAssertEqual(receivedPins.rows.count, 6)
        XCTAssertTrue(committedPins(client).allSatisfy { !$0.hasSplitLayout })

        bookmarks.rows[0].splitLayout = "horizontal"
        for index in pins.rows.indices { pins.rows[index].splitLayout = "horizontal" }
        await deviceA.pullOnce()
        await deviceB.pullOnce()

        XCTAssertEqual(receivedBookmarks.rows.first?.splitLayout, "horizontal")
        XCTAssertTrue(receivedPins.rows.allSatisfy { $0.splitLayout == "horizontal" },
                      "Every member of both pinned splits is stacked")

        bookmarks.rows[0].splitLayout = "vertical"
        for index in pins.rows.indices { pins.rows[index].splitLayout = "vertical" }
        await deviceA.pullOnce()
        await deviceB.pullOnce()

        XCTAssertEqual(wireSplitLayout(receivedBookmarks.rows.first?.splitLayout), "")
        XCTAssertTrue(receivedPins.rows.allSatisfy { wireSplitLayout($0.splitLayout).isEmpty },
                      "Side by side again on every member")
    }

    /// Members of one split whose own fields disagree land one orientation: the anchor's (the
    /// pair's smaller lineage), whichever member names it.
    func testThePairsAnchorDecidesTheOrientationOfBothMembers() async throws {
        for anchorStacked in [true, false] {
            var la = pinPayload(lineage: "la", title: "la", url: "https://la.example/", splitPartner: "lb")
            var lb = pinPayload(lineage: "lb", title: "lb", url: "https://lb.example/", splitPartner: "la")
            if anchorStacked {
                la.splitLayout = stamped("horizontal", at: 100)
            } else {
                lb.splitLayout = stamped("horizontal", at: 900)
            }
            let client = FakePhiSyncClient()
            client.scriptedPages = [page([
                remoteEntity(envelope(la), tag: PhiSyncEntity.pinClientTag("la", ownerKey: "pu-1"),
                             version: 10, entityId: "srv-la", key: key),
                remoteEntity(envelope(lb), tag: PhiSyncEntity.pinClientTag("lb", ownerKey: "pu-1"),
                             version: 11, entityId: "srv-lb", key: key),
            ], marker: "11")]
            let receiver = FakePinAccess(scope: .profile, account: .profile)
            let device = makeDevice("B", client: client,
                                    ownedKinds: [.pins(access: receiver, store: MemoryOwnedItemStore())])
            await device.setSpaceSyncEnabled(true)
            await device.pullOnce()

            XCTAssertEqual(receiver.rows.count, 2)
            let layouts = Set(receiver.rows.map { wireSplitLayout($0.splitLayout) })
            XCTAssertEqual(layouts, [anchorStacked ? "horizontal" : ""],
                           "Both members follow la, the anchor, even when lb's own value is newer")
        }
    }

    /// An older client's payload has no orientation; it never erases a stamped one.
    func testAnOlderClientsPayloadWithoutTheOrientationLosesToTheStampedValue() {
        var newerBookmark = bookmarkPayload(uuid: "b1", contentStamp: 100)
        newerBookmark.secondaryURL = stamped("https://b.example/", at: 100)
        newerBookmark.splitLayout = stamped("horizontal", at: 100)
        var olderBookmark = bookmarkPayload(uuid: "b1", title: "renamed", contentStamp: 900)
        olderBookmark.secondaryURL = stamped("https://b.example/", at: 900)
        let bookmarkHere = BookmarkKind.merge(local: newerBookmark, remote: olderBookmark)
        XCTAssertEqual(bookmarkHere.splitLayout.stringValue, "horizontal")
        XCTAssertEqual(bookmarkHere, BookmarkKind.merge(local: olderBookmark, remote: newerBookmark))

        var newerPin = pinPayload(lineage: "la", splitPartner: "lb")
        newerPin.splitLayout = stamped("horizontal", at: 100)
        let olderPin = pinPayload(lineage: "la", title: "renamed", splitPartner: "lb", contentStamp: 900)
        let pinHere = PinKind.merge(local: newerPin, remote: olderPin)
        XCTAssertEqual(pinHere.splitLayout.stringValue, "horizontal")
        XCTAssertEqual(pinHere, PinKind.merge(local: olderPin, remote: newerPin))
        XCTAssertFalse(PinKind.merge(local: olderPin, remote: olderPin).hasSplitLayout)
    }

    /// A member still waiting for its partner (unlinked locally) re-emits the baseline's
    /// orientation rather than publishing side by side.
    func testAPinWaitingForItsPartnerKeepsTheBaselineOrientation() {
        var baseline = pinPayload(lineage: "lx", splitPartner: "lb")
        baseline.splitLayout = stamped("horizontal", at: 100)
        let waiting = PhiLocalPin.fixture(lineageId: "LX", guid: "p1", profileId: "Default",
                                          splitPartnerLineageId: nil, splitLayout: nil)
        let projected = PinKind.project(waiting, resolve: OwnerResolver.fixture(), scope: .profile,
                                        parentIdentity: nil)

        let entity = projected.map {
            PinKind.stamp($0, baseline: baseline, local: waiting, rank: "V", now: 5_000)
        }

        XCTAssertEqual(entity?.splitLayout.stringValue, "horizontal")
        XCTAssertEqual(entity?.splitLayout.updatedAtMs, 100, "Not a local change")
    }

    /// Review finding P2: a stacked pinned pair that a peer expanded to three panes. Landing unlinks
    /// the pair in the store, which resets both rows' orientation, so the orientation must be written
    /// after that, against the state the links leave behind. Runs on a real `LocalStore`, whose link
    /// writes are what reset the orientation.
    func testAStackedPinnedPairExpandedToThreePanesStaysStackedOnEveryMember() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        let context = try XCTUnwrap(store.getMainContext())
        if try context.fetch(FetchDescriptor<ProfileModel>()).isEmpty {
            context.insert(ProfileModel(profileId: "Default"))
            try context.save()
        }
        let suite = "PhiSyncWiderSplitTests.store.\(UUID().uuidString)"
        suites.append(suite)
        let access = AccountPhiPinnedTabAccess(store: store, defaults: UserDefaults(suiteName: suite)!)
        _ = try access.allPins()
        // The receiver's stacked pair, as an earlier round landed it.
        try await access.apply(PinApplyBatch(unordered: [
            .create(.fixture(lineageId: "la", guid: "G-a", spaceId: nil, profileId: "Default", index: 0,
                             title: "la", url: URL(string: "https://la.example/")!)),
            .create(.fixture(lineageId: "lb", guid: "G-b", spaceId: nil, profileId: "Default", index: 1,
                             title: "lb", url: URL(string: "https://lb.example/")!)),
            .update(guid: "G-a", fields: PinFieldPatch(splitPartnerLineageId: .some("lb"),
                                                       splitLayout: .some("horizontal"))),
            .update(guid: "G-b", fields: PinFieldPatch(splitLayout: .some("horizontal"))),
        ]), expectedGeneration: access.pinScopeGeneration(), expectedScope: access.currentScope())
        let pinStore = MemoryOwnedItemStore()
        for (index, lineage) in ["la", "lb"].enumerated() {
            var baseline = pinPayload(lineage: lineage, rank: ["V", "W"][index], title: lineage,
                                      url: "https://\(lineage).example/",
                                      splitPartner: lineage == "la" ? "lb" : "la")
            baseline.splitLayout = stamped("horizontal", at: 100)
            pinStore.table.cursors["\(lineage):pu-1"] = ownedCursor(
                reconciled: baselineBytes(baseline), server: baselineBytes(baseline),
                entityId: "srv-\(lineage)", version: 1, ownerUuid: "pu-1")
        }
        // The peer's three-pane split, still stacked.
        let members = ["la", "lb", "lc"]
        let client = FakePhiSyncClient()
        client.scriptedPages = [page(members.enumerated().map { index, lineage in
            var payload = widerSplitPin(lineage, members: members)
            payload.rank = stamped(["V", "W", "X"][index], at: 500)
            payload.splitPartnerUuid = stamped("", at: 500)
            payload.splitLayout = stamped("horizontal", at: 500)
            return remoteEntity(envelope(payload),
                                tag: PhiSyncEntity.pinClientTag(lineage, ownerKey: "pu-1"),
                                version: Int64(10 + index), entityId: "srv-\(lineage)", key: key)
        }, marker: "12")]
        let device = makeDevice("B", client: client, ownedKinds: [.pins(access: access, store: pinStore)])
        await device.setSpaceSyncEnabled(true)
        await device.pullOnce()

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let rows = store.getAllPinnedTabs(for: "Default").sorted { $0.index < $1.index }
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertEqual(row.decodedSplitPaneGuids.count, 3, "\(row.guid) is a member of the three-pane split")
            XCTAssertNil(row.splitPartnerGuid)
            XCTAssertEqual(row.layout, "horizontal", "\(row.guid) stays stacked")
        }
    }
}
