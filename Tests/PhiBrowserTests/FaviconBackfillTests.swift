// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import XCTest
@testable import Phi

/// The favicon backfill in memory: rows seeded through the store's own
/// Migration write paths, a fake fetch that records what it was asked and
/// answers when told, and the store read back for what landed on the row.
///
/// The tests are `async` and wait by suspending rather than by spinning the
/// run loop: the backfill hands every answer to the main queue, which a run
/// loop nested inside a main-actor job does not drain.
@MainActor
final class FaviconBackfillTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private let profileID = LocalStore.defaultProfileId
    private let spaceID = "space-migrated"
    /// Any bytes will do: the store keeps what it is given.
    private let icon = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
    private let otherIcon = Data([0x89, 0x50, 0x4E, 0x47, 0x02])

    // MARK: - What is asked and what is written

    func testRowsWithoutBytesGetTheAnsweredBytes() async throws {
        let store = try makeStore()
        let bookmark = try await seedBookmarks(in: store, urls: ["https://example.com/"])[0]
        let pinned = try await seedPinnedTab(in: store, guid: "pin", url: "https://pinned.example/")
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: [pinned, bookmark])

        XCTAssertEqual(fetch.asks, [ask("https://pinned.example/"), ask("https://example.com/")])
        fetch.answer("https://pinned.example/", with: icon)
        fetch.answer("https://example.com/", with: otherIcon)
        await waitUntil {
            store.getTab(by: pinned)?.favicon == icon && store.getTab(by: bookmark)?.favicon == otherIcon
        }
    }

    func testARowThatHoldsBytesIsNeitherAskedNorChanged() async throws {
        let store = try makeStore()
        let bookmark = try await seedBookmarks(in: store, urls: ["https://example.com/"])[0]
        store.updateTabFavicon(bookmark, favicon: icon)
        await waitUntil { store.getTab(by: bookmark)?.favicon == icon }
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: [bookmark])
        await settle(store)

        XCTAssertTrue(fetch.asks.isEmpty)
        XCTAssertEqual(store.getTab(by: bookmark)?.favicon, icon)
    }

    func testANothingAnswerLeavesTheRowEmpty() async throws {
        let store = try makeStore()
        let bookmark = try await seedBookmarks(in: store, urls: ["https://example.com/"])[0]
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: [bookmark])
        fetch.answer("https://example.com/", with: nil)
        await settle(store)

        XCTAssertNil(store.getTab(by: bookmark)?.favicon)
    }

    func testAnInternalPageIsNeverAsked() async throws {
        let store = try makeStore()
        let rows = try await seedBookmarks(in: store, urls: ["phi://newtab", "https://example.com/"])
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: rows)

        XCTAssertEqual(fetch.asks, [ask("https://example.com/")])
    }

    func testASplitBookmarkAsksBothPagesTheSecondFirstAndKeepsTheFirstPagesBytes() async throws {
        let store = try makeStore()
        let split = try await seedSplitBookmark(
            in: store, first: "https://github.com/", second: "https://www.baidu.com/")
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: [split])

        XCTAssertEqual(fetch.asks, [ask("https://www.baidu.com/")], "the first page waits on the second")
        fetch.answer("https://www.baidu.com/", with: otherIcon)
        await waitUntil { fetch.asks.count == 2 }
        XCTAssertEqual(fetch.asks, [ask("https://www.baidu.com/"), ask("https://github.com/")])
        fetch.answer("https://github.com/", with: icon)
        await waitUntil { store.getTab(by: split)?.favicon == icon }
    }

    /// The second icon is not on the row, so the views showing it are told
    /// through the favicon repository — whatever the first page answers.
    func testASecondPagesAnswerReachesTheRepositoryWhenTheFirstPageAnswersNothing() async throws {
        let store = try makeStore()
        let split = try await seedSplitBookmark(
            in: store, first: "https://github.com/", second: "https://www.baidu.com/")
        let fetch = RecordingFetch()
        let repository = ProfileScopedFaviconRepository(fetcher: fetch)
        let backfill = makeBackfill(fetch: fetch, store: store, repository: repository)
        var stored: [String?] = []
        let subscription = repository.iconStored.sink { stored.append($0.pageURLString) }
        defer { subscription.cancel() }

        backfill.enqueue(profileId: profileID, guids: [split])
        fetch.answer("https://www.baidu.com/", with: otherIcon)
        await waitUntil { stored == ["https://www.baidu.com/"] }
        await waitUntil { fetch.asks.count == 2 }
        fetch.answer("https://github.com/", with: nil)
        await settle(store)

        XCTAssertEqual(stored, ["https://www.baidu.com/"])
        XCTAssertNil(store.getTab(by: split)?.favicon)
    }

    func testASecondPagesAnswerReachesTheRepositoryWhenTheFirstPageIsInternal() async throws {
        let store = try makeStore()
        let split = try await seedSplitBookmark(
            in: store, first: "phi://newtab", second: "https://www.baidu.com/")
        let fetch = RecordingFetch()
        let repository = ProfileScopedFaviconRepository(fetcher: fetch)
        let backfill = makeBackfill(fetch: fetch, store: store, repository: repository)
        var stored: [String?] = []
        let subscription = repository.iconStored.sink { stored.append($0.pageURLString) }
        defer { subscription.cancel() }

        backfill.enqueue(profileId: profileID, guids: [split])

        XCTAssertEqual(fetch.asks, [ask("https://www.baidu.com/")])
        fetch.answer("https://www.baidu.com/", with: otherIcon)
        await waitUntil { stored == ["https://www.baidu.com/"] }
    }

    func testASecondPagesAnswerReachesTheRepositoryWhenTheFirstPageTimesOut() async throws {
        let store = try makeStore()
        let split = ArcDataParserTool.Bookmark(
            guid: "arc-split", title: "Split", url: "https://github.com/", isFolder: false)
        split.split = ArcSplit(secondaryTitle: "Second", secondaryURL: "https://www.baidu.com/", layout: "vertical")
        let rows = try await seedBookmarks(in: store, leaves: [split] + (1...4).map {
            ArcDataParserTool.Bookmark(
                guid: "arc-\($0)", title: "Site \($0)", url: "https://site\($0).example/", isFolder: false)
        })
        let fetch = RecordingFetch()
        let repository = ProfileScopedFaviconRepository(fetcher: fetch)
        let backfill = makeBackfill(fetch: fetch, store: store, repository: repository, requestDeadline: 0.2)
        var stored: [String?] = []
        let subscription = repository.iconStored.sink { stored.append($0.pageURLString) }
        defer { subscription.cancel() }

        backfill.enqueue(profileId: profileID, guids: rows)
        fetch.answer("https://www.baidu.com/", with: otherIcon)
        await waitUntil { fetch.asks.count == 5 }
        XCTAssertEqual(fetch.asks.last?.pageURL, "https://github.com/")
        // The first page is never answered: the deadline frees its slot with
        // the three beside it, and the last row gets asked.
        await waitUntil { fetch.asks.count == 6 }
        await settle(store)

        XCTAssertEqual(stored, ["https://www.baidu.com/"])
        XCTAssertNil(store.getTab(by: rows[0])?.favicon)
    }

    /// A second page answering after its deadline is announced all the same.
    func testASecondPagesAnswerAfterTheDeadlineIsStillAnnounced() async throws {
        let store = try makeStore()
        let split = try await seedSplitBookmark(
            in: store, first: "https://github.com/", second: "https://www.baidu.com/")
        let fetch = RecordingFetch()
        let repository = ProfileScopedFaviconRepository(fetcher: fetch)
        let backfill = makeBackfill(fetch: fetch, store: store, repository: repository, requestDeadline: 0.2)
        var stored: [String?] = []
        let subscription = repository.iconStored.sink { stored.append($0.pageURLString) }
        defer { subscription.cancel() }

        backfill.enqueue(profileId: profileID, guids: [split])
        await waitUntil { fetch.asks.count == 2 }
        XCTAssertTrue(stored.isEmpty, "the first page was asked once the second's deadline passed")
        fetch.answer("https://www.baidu.com/", with: otherIcon)

        await waitUntil { stored == ["https://www.baidu.com/"] }
    }

    func testBothRowsOfAPinnedSplitPairAreAsked() async throws {
        let store = try makeStore()
        let left = try await seedPinnedTab(in: store, guid: "left", url: "https://left.example/")
        let right = try await seedPinnedTab(in: store, guid: "right", url: "https://right.example/")
        store.updatePinnedSplitPair(primaryGuid: left, secondaryGuid: right, layout: "vertical")
        await store.performBackgroundWriteAndWait { _ in }
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: [left, right])

        XCTAssertEqual(fetch.asks, [ask("https://left.example/"), ask("https://right.example/")])
    }

    func testBytesThatLandedMeanwhileAreNotReplaced() async throws {
        let store = try makeStore()
        let bookmark = try await seedBookmarks(in: store, urls: ["https://example.com/"])[0]
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)
        backfill.enqueue(profileId: profileID, guids: [bookmark])
        // The page was opened while its fetch was out, and its own icon
        // reached the row through the live path.
        store.updateTabFavicon(bookmark, favicon: icon)
        await waitUntil { store.getTab(by: bookmark)?.favicon == icon }

        fetch.answer("https://example.com/", with: otherIcon)
        await settle(store)

        XCTAssertEqual(store.getTab(by: bookmark)?.favicon, icon)
    }

    // MARK: - One queue, one limit

    /// The answer was for the page the row no longer holds.
    func testARowRePointedWhileItsFetchWasOutIsLeftAlone() async throws {
        let store = try makeStore()
        let bookmark = try await seedBookmarks(in: store, urls: ["https://example.com/"])[0]
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: [bookmark])
        XCTAssertEqual(fetch.asks, [ask("https://example.com/")])
        store.updateBookmark(bookmark, profileId: profileID, title: nil, url: "https://elsewhere.example/")
        await waitUntil { store.getTab(by: bookmark)?.url.absoluteString == "https://elsewhere.example/" }
        fetch.answer("https://example.com/", with: icon)
        await settle(store)

        XCTAssertNil(store.getTab(by: bookmark)?.favicon)
    }

    func testTwoBatchesShareOneLimitOfFourAndAreWorkedInArrivalOrder() async throws {
        let store = try makeStore()
        let rows = try await seedBookmarks(in: store, urls: (1...6).map { "https://site\($0).example/" })
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: Array(rows[0..<3]))
        backfill.enqueue(profileId: profileID, guids: Array(rows[3..<6]))

        XCTAssertEqual(fetch.asks.map(\.pageURL), (1...4).map { "https://site\($0).example/" })
        XCTAssertEqual(fetch.inFlightCount, 4)
        fetch.answer("https://site2.example/", with: icon)
        await waitUntil { fetch.asks.count == 5 }
        XCTAssertEqual(fetch.asks.last?.pageURL, "https://site5.example/")
        XCTAssertEqual(fetch.inFlightCount, 4)
        fetch.answer("https://site4.example/", with: icon)
        await waitUntil { fetch.asks.count == 6 }
        XCTAssertEqual(fetch.asks.last?.pageURL, "https://site6.example/")
        XCTAssertEqual(fetch.inFlightCount, 4)
    }

    func testARequestThatNeverSettlesFreesItsSlotAfterTheDeadline() async throws {
        let store = try makeStore()
        let rows = try await seedBookmarks(in: store, urls: (1...5).map { "https://site\($0).example/" })
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store, requestDeadline: 0.2)

        backfill.enqueue(profileId: profileID, guids: rows)

        XCTAssertEqual(fetch.asks.count, 4)
        await waitUntil { fetch.asks.count == 5 }
        await settle(store)
        for row in rows {
            XCTAssertNil(store.getTab(by: row)?.favicon)
        }
    }

    /// The slot moved on at the deadline; the bytes still land.
    func testAnAnswerAfterTheDeadlineStillLandsOnTheRow() async throws {
        let store = try makeStore()
        let rows = try await seedBookmarks(in: store, urls: (1...5).map { "https://site\($0).example/" })
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store, requestDeadline: 0.2)

        backfill.enqueue(profileId: profileID, guids: rows)
        await waitUntil { fetch.asks.count == 5 }
        fetch.answer("https://site1.example/", with: icon)

        await waitUntil { store.getTab(by: rows[0])?.favicon == icon }
    }

    // MARK: - Dropping a batch

    func testAMissingStoreDropsTheBatch() async throws {
        let store = try makeStore()
        let bookmark = try await seedBookmarks(in: store, urls: ["https://example.com/"])[0]
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: nil)

        backfill.enqueue(profileId: profileID, guids: [bookmark])
        await settle(store)

        XCTAssertTrue(fetch.asks.isEmpty)
        XCTAssertNil(store.getTab(by: bookmark)?.favicon)
    }

    func testARowThatIsGoneIsSkipped() async throws {
        let store = try makeStore()
        let fetch = RecordingFetch()
        let backfill = makeBackfill(fetch: fetch, store: store)

        backfill.enqueue(profileId: profileID, guids: ["never-written"])

        XCTAssertTrue(fetch.asks.isEmpty)
    }

    // MARK: - The rows a trigger hands over

    /// The walk is what puts a Space's Bookmarks in front of the backfill:
    /// folders are entered in place, so a nested Bookmark is not left a
    /// globe, and the order is the sidebar's, so the icons fill in top-down.
    func testASpacesBookmarksAreWalkedInSidebarOrderFoldersInPlace() async throws {
        let store = try await makeStoreWithWalkedTree()

        let guids = FaviconBackfill.bookmarkGUIDs(
            under: store.fetchBookmarks(parentId: nil, profileId: profileID, spaceId: spaceID))

        XCTAssertEqual(guids.map { store.getTab(by: $0)?.title }, ["First", "Nested", "Last"])
    }

    /// The browser-data import narrows the walk to the rows without an icon,
    /// with the predicate it passes: a row that holds bytes is left out, and
    /// a folder is still entered for the rows inside it.
    func testTheWalkNarrowedToRowsWithoutAnIconStillEntersFolders() async throws {
        let store = try await makeStoreWithWalkedTree()
        let rows = store.fetchBookmarks(parentId: nil, profileId: profileID, spaceId: spaceID)
        let first = try XCTUnwrap(rows.first { $0.title == "First" })
        first.favicon = icon
        try XCTUnwrap(store.getMainContext()).save()

        let guids = FaviconBackfill.bookmarkGUIDs(
            under: store.fetchBookmarks(parentId: nil, profileId: profileID, spaceId: spaceID),
            where: { $0.favicon == nil })

        XCTAssertEqual(guids.map { store.getTab(by: $0)?.title }, ["Nested", "Last"])
    }

    // MARK: - Fixtures

    /// Records every ask in order and holds each answer until the test gives
    /// it, so what is in flight can be counted and answered in any order.
    private final class RecordingFetch: ProfileScopedFaviconFetching {
        struct Ask: Equatable {
            let profileId: String
            let pageURL: String
        }

        private(set) var asks: [Ask] = []
        private var pending: [(pageURL: String, completion: (Data?) -> Void)] = []

        var inFlightCount: Int { pending.count }

        func getFavicon(profileId: String, pageURLString: String, completion: @escaping (Data?) -> Void) {
            asks.append(Ask(profileId: profileId, pageURL: pageURLString))
            pending.append((pageURLString, completion))
        }

        /// Answers the oldest unanswered ask for `pageURL`.
        func answer(_ pageURL: String, with data: Data?, file: StaticString = #filePath, line: UInt = #line) {
            guard let index = pending.firstIndex(where: { $0.pageURL == pageURL }) else {
                XCTFail("nothing in flight for \(pageURL)", file: file, line: line)
                return
            }
            pending.remove(at: index).completion(data)
        }
    }

    private func ask(_ pageURL: String) -> RecordingFetch.Ask {
        RecordingFetch.Ask(profileId: profileID, pageURL: pageURL)
    }

    /// A backfill with its own favicon repository, so nothing reaches the
    /// app-wide one.
    private func makeBackfill(
        fetch: RecordingFetch,
        store: LocalStore?,
        repository: ProfileScopedFaviconRepository? = nil,
        requestDeadline: TimeInterval = 60
    ) -> FaviconBackfill {
        FaviconBackfill(
            fetcher: fetch,
            store: { store },
            requestDeadline: requestDeadline,
            repository: repository ?? ProfileScopedFaviconRepository(fetcher: fetch))
    }

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        // A migrated Space is a non-default one, which the Arc save refuses to
        // write into unless it exists.
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(SpaceModel(
            spaceId: spaceID, profileId: profileID, name: "Migrated",
            colorHex: "#000000", iconName: "circle", sortOrder: 1))
        try context.save()
        return store
    }

    /// Writes one Arc tree of plain links through the Migration's own save
    /// and returns the rows' identifiers in sidebar order.
    private func seedBookmarks(in store: LocalStore, urls: [String]) async throws -> [String] {
        try await seedBookmarks(in: store, leaves: urls.enumerated().map { index, url in
            ArcDataParserTool.Bookmark(guid: "arc-\(index)", title: url, url: url, isFolder: false)
        })
    }

    /// Writes an Arc split entry — one row carrying both pages — and returns
    /// its identifier.
    private func seedSplitBookmark(in store: LocalStore, first: String, second: String) async throws -> String {
        let leaf = ArcDataParserTool.Bookmark(guid: "arc-split", title: "Split", url: first, isFolder: false)
        leaf.split = ArcSplit(secondaryTitle: "Second", secondaryURL: second, layout: "vertical")
        return try await seedBookmarks(in: store, leaves: [leaf])[0]
    }

    private func seedBookmarks(in store: LocalStore, leaves: [ArcDataParserTool.Bookmark]) async throws -> [String] {
        let root = ArcDataParserTool.Bookmark(guid: "root", title: "Space", url: nil, isFolder: true)
        root.children = leaves
        let written = await store.saveArcBookmarksToLocalStore(
            root, profileId: profileID, spaceId: spaceID, landingFolder: false)
        XCTAssertEqual(written, leaves.count)
        let rows = store.fetchBookmarks(parentId: nil, profileId: profileID, spaceId: spaceID)
        XCTAssertEqual(rows.count, leaves.count)
        return rows.map(\.guid)
    }

    private func seedPinnedTab(in store: LocalStore, guid: String, url: String) async throws -> String {
        XCTAssertTrue(store.createPinnedTab(
            guid: guid, url: url, title: url, profileId: profileID, spaceId: spaceID))
        await store.performBackgroundWriteAndWait { _ in }
        return guid
    }

    /// A Space holding a Bookmark, a folder with one inside, and another
    /// Bookmark, written through the Migration's own save.
    private func makeStoreWithWalkedTree() async throws -> LocalStore {
        let store = try makeStore()
        let folder = ArcDataParserTool.Bookmark(guid: "folder", title: "Reading", url: nil, isFolder: true)
        folder.children = [ArcDataParserTool.Bookmark(
            guid: "nested", title: "Nested", url: "https://nested.example/", isFolder: false)]
        let root = ArcDataParserTool.Bookmark(guid: "root", title: "Space", url: nil, isFolder: true)
        root.children = [
            ArcDataParserTool.Bookmark(guid: "first", title: "First", url: "https://first.example/", isFolder: false),
            folder,
            ArcDataParserTool.Bookmark(guid: "last", title: "Last", url: "https://last.example/", isFolder: false),
        ]
        let written = await store.saveArcBookmarksToLocalStore(
            root, profileId: profileID, spaceId: spaceID, landingFolder: false)
        XCTAssertEqual(written, 3)
        return store
    }

    /// Lets the main queue run — the backfill hands its answers to it — and
    /// the store's queued writes land, so that "nothing was written" can be
    /// asserted rather than merely not yet observed.
    private func settle(_ store: LocalStore) async {
        await Task.yield()
        await store.performBackgroundWriteAndWait { _ in }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout.", file: file, line: line)
    }
}
