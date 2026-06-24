// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class SearchTabsDataTests: XCTestCase {
    func testQueryMatcherRanksTitlePrefixBeforeTitleContainsAndURLContains() {
        let prefix = SearchTabsQueryMatcher.match(
            query: "git",
            primaryTitle: "GitHub",
            primaryURL: "https://example.com",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let titleContains = SearchTabsQueryMatcher.match(
            query: "hub",
            primaryTitle: "GitHub",
            primaryURL: "https://example.com",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let hostContains = SearchTabsQueryMatcher.match(
            query: "github",
            primaryTitle: "Docs",
            primaryURL: "https://github.com/features/copilot",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let pathContains = SearchTabsQueryMatcher.match(
            query: "copilot",
            primaryTitle: "Docs",
            primaryURL: "https://github.com/features/copilot",
            secondaryTitle: nil,
            secondaryURL: nil
        )

        XCTAssertGreaterThan(prefix?.score ?? 0, titleContains?.score ?? 0)
        XCTAssertGreaterThan(titleContains?.score ?? 0, hostContains?.score ?? 0)
        XCTAssertGreaterThan(hostContains?.score ?? 0, pathContains?.score ?? 0)
        XCTAssertEqual(prefix?.matchedFields, [.title])
        XCTAssertEqual(hostContains?.matchedFields, [.host])
        XCTAssertEqual(pathContains?.matchedFields, [.url])
    }

    func testQueryMatcherSearchesSecondaryPaneForNativeSplitEntries() {
        let match = SearchTabsQueryMatcher.match(
            query: "calendar",
            primaryTitle: "Mail",
            primaryURL: "https://mail.example",
            secondaryTitle: "Calendar",
            secondaryURL: "https://calendar.example"
        )

        XCTAssertEqual(match?.score, SearchTabsQueryMatcher.titlePrefixScore)
        XCTAssertEqual(match?.matchedFields, [.secondaryTitle])
    }

    func testQueryMatcherReturnsNilForNonMatchingQuery() {
        let match = SearchTabsQueryMatcher.match(
            query: "figma",
            primaryTitle: "Mail",
            primaryURL: "https://mail.example",
            secondaryTitle: nil,
            secondaryURL: nil
        )

        XCTAssertNil(match)
    }

    func testChromiumProviderParsesValidOpenAndRecentlyClosedTabs() {
        let snapshot = SearchTabsChromiumProvider.parse(data: [
            "openTabs": [
                [
                    "tabId": NSNumber(value: 101),
                    "windowId": "42",
                    "index": NSNumber(value: 3),
                    "title": "Phi Browser",
                    "url": "https://phi.sh",
                    "groupIdHex": "ABCDEF",
                    "active": NSNumber(value: true),
                    "pinned": false,
                    "split": "true",
                    "hostWindow": "1",
                    "lastActiveElapsedMs": "2500",
                    "lastActiveElapsedText": "2 secs ago",
                ],
            ],
            "recentlyClosedTabs": [
                [
                    "sessionId": "777",
                    "sourceEntrySessionId": NSNumber(value: 700),
                    "sourceEntryType": "window",
                    "title": "Closed Docs",
                    "url": "https://docs.phi.sh",
                    "groupIdHex": "CLOSED",
                    "lastActiveTimeMs": NSNumber(value: 1_800_000),
                    "lastActiveElapsedMs": NSNumber(value: 9_000),
                    "lastActiveElapsedText": "9 secs ago",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.openTabs, [
            ChromiumSearchOpenTab(
                tabId: 101,
                windowId: 42,
                index: 3,
                title: "Phi Browser",
                url: "https://phi.sh",
                groupIdHex: "ABCDEF",
                active: true,
                pinned: false,
                split: true,
                hostWindow: true,
                lastActiveElapsedMs: 2_500,
                lastActiveElapsedText: "2 secs ago"
            ),
        ])
        XCTAssertEqual(snapshot.closedTabs, [
            ChromiumSearchClosedTab(
                sessionId: 777,
                sourceEntrySessionId: 700,
                sourceEntryType: "window",
                title: "Closed Docs",
                url: "https://docs.phi.sh",
                groupIdHex: "CLOSED",
                lastActiveTimeMs: 1_800_000,
                lastActiveElapsedMs: 9_000,
                lastActiveElapsedText: "9 secs ago",
                providerOrder: 0
            ),
        ])
    }

    func testChromiumProviderSkipsMalformedItemsWithoutDroppingValidSiblings() {
        let snapshot = SearchTabsChromiumProvider.parse(data: [
            "openTabs": [
                [
                    "tabId": 0,
                    "windowId": 42,
                    "title": "Invalid Open Tab",
                ],
                "not a dictionary",
                [
                    "tabId": "202",
                    "windowId": NSNumber(value: 84),
                    "title": "Valid Open Tab",
                ],
            ],
            "recentlyClosedTabs": [
                [
                    "sessionId": -1,
                    "title": "Invalid Closed Tab",
                ],
                "not a dictionary",
                [
                    "sessionId": NSNumber(value: 303),
                    "title": "Valid Closed Tab",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.openTabs, [
            ChromiumSearchOpenTab(
                tabId: 202,
                windowId: 84,
                index: 0,
                title: "Valid Open Tab",
                url: "about:blank",
                groupIdHex: "",
                active: false,
                pinned: false,
                split: false,
                hostWindow: false,
                lastActiveElapsedMs: Int64.max,
                lastActiveElapsedText: ""
            ),
        ])
        XCTAssertEqual(snapshot.closedTabs, [
            ChromiumSearchClosedTab(
                sessionId: 303,
                sourceEntrySessionId: 303,
                sourceEntryType: "unknown",
                title: "Valid Closed Tab",
                url: "",
                groupIdHex: "",
                lastActiveTimeMs: 0,
                lastActiveElapsedMs: Int64.max,
                lastActiveElapsedText: "",
                providerOrder: 2
            ),
        ])
    }

    func testChromiumProviderRejectsBooleanAndFractionalNumberIDs() {
        let snapshot = SearchTabsChromiumProvider.parse(data: [
            "openTabs": [
                [
                    "tabId": NSNumber(value: true),
                    "windowId": NSNumber(value: 42),
                    "title": "Boolean Tab ID",
                ],
                [
                    "tabId": NSNumber(value: 1.9),
                    "windowId": NSNumber(value: 42),
                    "title": "Fractional Tab ID",
                ],
                [
                    "tabId": NSNumber(value: 404),
                    "windowId": NSNumber(value: 42),
                    "title": "Valid Open Tab",
                    "active": NSNumber(value: 2),
                    "pinned": NSNumber(value: 1),
                    "split": NSNumber(value: 0),
                    "hostWindow": NSNumber(value: 1.5),
                ],
            ],
            "recentlyClosedTabs": [
                [
                    "sessionId": NSNumber(value: true),
                    "title": "Boolean Session ID",
                ],
                [
                    "sessionId": NSNumber(value: 2.2),
                    "title": "Fractional Session ID",
                ],
                [
                    "sessionId": NSNumber(value: 505),
                    "title": "Valid Closed Tab",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.openTabs, [
            ChromiumSearchOpenTab(
                tabId: 404,
                windowId: 42,
                index: 0,
                title: "Valid Open Tab",
                url: "about:blank",
                groupIdHex: "",
                active: false,
                pinned: true,
                split: false,
                hostWindow: false,
                lastActiveElapsedMs: Int64.max,
                lastActiveElapsedText: ""
            ),
        ])
        XCTAssertEqual(snapshot.closedTabs, [
            ChromiumSearchClosedTab(
                sessionId: 505,
                sourceEntrySessionId: 505,
                sourceEntryType: "unknown",
                title: "Valid Closed Tab",
                url: "",
                groupIdHex: "",
                lastActiveTimeMs: 0,
                lastActiveElapsedMs: Int64.max,
                lastActiveElapsedText: "",
                providerOrder: 2
            ),
        ])
    }

    func testNativeProviderReturnsBookmarkRootOnlyForEmptyQuery() {
        let bookmark = Bookmark(
            guid: "bookmark-1",
            title: "Docs",
            url: "https://docs.example",
            profileId: "profile-1"
        )
        let provider = SearchTabsNativeProvider(
            profileId: "profile-1",
            windowId: 42,
            bookmarks: [bookmark]
        )

        let withRoot = provider.snapshot(includeBookmarkRoot: true)
        let withoutRoot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(withRoot.bookmarkRoot?.kind, .bookmarkRoot)
        XCTAssertEqual(withRoot.bookmarkRoot?.providerOrder, Int.max)
        XCTAssertEqual(withRoot.bookmarks.count, 1)
        XCTAssertEqual(withRoot.bookmarks.first?.guid, "bookmark-1")
        XCTAssertNil(withoutRoot.bookmarkRoot)
    }

    func testNativeProviderSkipsNativeResultsForIncognito() {
        let pinnedTab = Tab(
            guid: 100,
            url: "https://pinned.example",
            isActive: false,
            index: 0,
            title: "Pinned",
            customGuid: "pin-1"
        )
        let bookmark = Bookmark(
            guid: "bookmark-1",
            title: "Docs",
            url: "https://docs.example",
            profileId: "otr-profile"
        )
        let provider = SearchTabsNativeProvider(
            profileId: "otr-profile",
            windowId: 42,
            isIncognito: true,
            pinnedTabs: [pinnedTab],
            bookmarks: [bookmark]
        )

        let snapshot = provider.snapshot(includeBookmarkRoot: true)

        XCTAssertTrue(snapshot.pins.isEmpty)
        XCTAssertTrue(snapshot.bookmarks.isEmpty)
        XCTAssertNil(snapshot.bookmarkRoot)
    }

    func testNativeProviderBuildsPinnedSplitAsSingleEntry() throws {
        let left = Tab(
            guid: 101,
            url: "https://left.example",
            isActive: true,
            index: 0,
            title: "Left",
            customGuid: "pin-left"
        )
        let right = Tab(
            guid: 102,
            url: "https://right.example",
            isActive: false,
            index: 1,
            title: "Right",
            customGuid: "pin-right"
        )
        left.splitPartnerGuid = "pin-right"
        right.splitPartnerGuid = "pin-left"
        left.isOpenned = true
        right.isOpenned = true

        let provider = SearchTabsNativeProvider(
            profileId: "profile-1",
            windowId: 42,
            pinnedTabs: [left, right],
            focusingTab: left,
            pinnedSplitPair: { tab in
                switch tab.guidInLocalDB {
                case "pin-left", "pin-right":
                    return ("pin-left", "pin-right")
                default:
                    return nil
                }
            }
        )

        let snapshot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(snapshot.pins.count, 1)
        let entry = try XCTUnwrap(snapshot.pins.first)
        XCTAssertEqual(entry.kind, .pin)
        XCTAssertEqual(entry.primary.localGuid, "pin-left")
        XCTAssertEqual(entry.secondary?.localGuid, "pin-right")
        XCTAssertEqual(entry.displayMode, .split)
        XCTAssertTrue(entry.state.isSplit)
        XCTAssertTrue(entry.state.isOpen)
        XCTAssertTrue(entry.state.isActive)
    }

    func testNativeProviderBuildsSplitBookmarkAsSingleEntry() throws {
        let bookmark = Bookmark(
            guid: "bookmark-1",
            title: "Mail",
            url: "https://mail.example",
            secondaryUrl: "https://calendar.example",
            secondaryTitle: "Calendar",
            profileId: "profile-1"
        )
        let provider = SearchTabsNativeProvider(
            profileId: "profile-1",
            windowId: 42,
            bookmarks: [bookmark]
        )

        let snapshot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(snapshot.bookmarks.count, 1)
        let entry = try XCTUnwrap(snapshot.bookmarks.first)
        XCTAssertEqual(entry.kind, .bookmark)
        XCTAssertEqual(entry.displayMode, .split)
        XCTAssertEqual(entry.primary.title, "Mail")
        XCTAssertEqual(entry.secondary?.title, "Calendar")
    }

    func testNativeProviderFallsBackToSecondaryURLWhenSplitBookmarkTitleIsBlank() throws {
        let nilTitleBookmark = Bookmark(
            guid: "bookmark-1",
            title: "Mail",
            url: "https://mail.example",
            secondaryUrl: "https://calendar.example",
            secondaryTitle: nil,
            profileId: "profile-1"
        )
        let emptyTitleBookmark = Bookmark(
            guid: "bookmark-2",
            title: "Docs",
            url: "https://docs.example",
            secondaryUrl: "https://tasks.example",
            secondaryTitle: "",
            profileId: "profile-1"
        )
        let provider = SearchTabsNativeProvider(
            profileId: "profile-1",
            windowId: 42,
            bookmarks: [nilTitleBookmark, emptyTitleBookmark]
        )

        let snapshot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(snapshot.bookmarks.count, 2)
        XCTAssertEqual(try XCTUnwrap(snapshot.bookmarks.first).secondary?.title, "https://calendar.example")
        XCTAssertEqual(try XCTUnwrap(snapshot.bookmarks.last).secondary?.title, "https://tasks.example")
    }

    func testAggregatorKeepsOpenedTabAndMatchingNativePinAndRanksOpenedFirst() throws {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(
                    tabId: 42,
                    windowId: 7,
                    title: "GitHub",
                    url: "https://github.com",
                    active: false,
                    pinned: true,
                    hostWindow: true,
                    lastActiveElapsedMs: 10
                ),
            ],
            closedTabs: []
        )
        let native = SearchTabsNativeSnapshot(
            pins: [
                nativeEntry(
                    id: "pin:github",
                    guid: "github",
                    kind: .pin,
                    title: "GitHub",
                    url: "https://github.com",
                    isOpen: true
                ),
            ],
            bookmarks: [],
            bookmarkRoot: nil
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "git",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: native
        )

        XCTAssertEqual(snapshot.items.map(\.kind), [.openedtab, .pin])
        XCTAssertEqual(snapshot.items.first?.action, .activateChromiumTab(tabId: 42, windowId: 7))
        XCTAssertTrue(try XCTUnwrap(snapshot.items.last).state.isOpen)
    }

    func testAggregatorEmptyQueryShowsOnlyOpenAndRecentlyClosedItems() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(
                    tabId: 42,
                    windowId: 7,
                    title: "Open Tab",
                    active: true,
                    hostWindow: true,
                    lastActiveElapsedMs: 10
                ),
            ],
            closedTabs: [
                makeClosedTab(
                    sessionId: 100,
                    title: "Closed Tab",
                    lastActiveTimeMs: 1_000,
                    lastActiveElapsedMs: 20
                ),
            ]
        )
        let native = SearchTabsNativeSnapshot(
            pins: [
                nativeEntry(
                    id: "pin:open",
                    guid: "open",
                    kind: .pin,
                    title: "Pinned Tab",
                    url: "https://pin.example",
                    isOpen: true
                ),
            ],
            bookmarks: [
                nativeEntry(
                    id: "bookmark:closed",
                    guid: "closed",
                    kind: .bookmark,
                    title: "Closed Bookmark",
                    url: "https://closed.example",
                    isOpen: false
                ),
            ],
            bookmarkRoot: nativeEntry(
                id: "bookmark-root:profile-1",
                guid: nil,
                kind: .bookmarkRoot,
                title: "Bookmarks",
                url: nil,
                isOpen: false,
                displayMode: .bookmarkMenuRoot,
                action: .showBookmarkMenuRoot(profileId: "profile-1"),
                providerOrder: Int.max
            )
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: native
        )

        XCTAssertEqual(snapshot.items.map(\.kind), [.openedtab, .closedtab])
    }

    func testAggregatorSortsOpenedTabsByHostActiveThenElapsedAscending() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(tabId: 1, windowId: 7, title: "Host Older", hostWindow: true, lastActiveElapsedMs: 500),
                makeOpenTab(tabId: 2, windowId: 8, title: "Other Recent", hostWindow: false, lastActiveElapsedMs: 1),
                makeOpenTab(tabId: 3, windowId: 7, title: "Host Active", active: true, hostWindow: true, lastActiveElapsedMs: 200),
                makeOpenTab(tabId: 4, windowId: 7, title: "Host Recent", hostWindow: true, lastActiveElapsedMs: 20),
            ],
            closedTabs: []
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )

        XCTAssertEqual(snapshot.items.map(\.primary.chromiumTabId), [3, 4, 1, 2])
    }

    func testAggregatorSortsOpenedTabTieByChromiumIndex() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(tabId: 2, windowId: 7, index: 2, title: "Docs Second", hostWindow: true, lastActiveElapsedMs: 10),
                makeOpenTab(tabId: 1, windowId: 7, index: 1, title: "Docs First", hostWindow: true, lastActiveElapsedMs: 10),
            ],
            closedTabs: []
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "docs",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )

        XCTAssertEqual(snapshot.items.map(\.primary.chromiumTabId), [1, 2])
    }

    func testAggregatorSortsClosedTabsByElapsedBeforeTimestamp() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [],
            closedTabs: [
                makeClosedTab(
                    sessionId: 1,
                    title: "Docs Older Activity",
                    lastActiveTimeMs: 2_000,
                    lastActiveElapsedMs: 500,
                    providerOrder: 0
                ),
                makeClosedTab(
                    sessionId: 2,
                    title: "Docs Recent Activity",
                    lastActiveTimeMs: 1_000,
                    lastActiveElapsedMs: 10,
                    providerOrder: 1
                ),
            ]
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "docs",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )

        XCTAssertEqual(snapshot.items.map(\.action), [
            .restoreClosedTab(sessionId: 2, sourceEntrySessionId: 2, sourceEntryType: "tab"),
            .restoreClosedTab(sessionId: 1, sourceEntrySessionId: 1, sourceEntryType: "tab"),
        ])
    }

    func testAggregatorExcludesUnmatchedItemsForNonEmptyQuery() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(tabId: 1, windowId: 7, title: "Mail", lastActiveElapsedMs: 10),
            ],
            closedTabs: [
                makeClosedTab(sessionId: 1, title: "Calendar", lastActiveTimeMs: 1_000, lastActiveElapsedMs: 20),
            ]
        )
        let native = SearchTabsNativeSnapshot(
            pins: [
                nativeEntry(id: "pin:notes", guid: "notes", kind: .pin, title: "Notes", url: "https://notes.example", isOpen: false),
            ],
            bookmarks: [
                nativeEntry(id: "bookmark:tasks", guid: "tasks", kind: .bookmark, title: "Tasks", url: "https://tasks.example", isOpen: true),
            ],
            bookmarkRoot: nativeEntry(
                id: "bookmark-root:profile-1",
                guid: nil,
                kind: .bookmarkRoot,
                title: "Bookmarks",
                url: nil,
                isOpen: false,
                displayMode: .bookmarkMenuRoot,
                action: .showBookmarkMenuRoot(profileId: "profile-1"),
                providerOrder: Int.max
            )
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "git",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: native
        )

        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testAggregatorKeepsLiveSplitOpenedTabsAsSingleDisplayItems() throws {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(
                    tabId: 42,
                    windowId: 7,
                    title: "Split Docs",
                    split: true,
                    lastActiveElapsedMs: 10
                ),
            ],
            closedTabs: []
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )
        let item = try XCTUnwrap(snapshot.items.first)

        XCTAssertEqual(item.displayMode, .single)
        XCTAssertTrue(item.state.isSplit)
        XCTAssertNil(item.splitRelation)
    }

    func testDataControllerAttachesSplitRelationToOpenChromiumTab() throws {
        let state = try makeSearchTabsState()
        let mail = Tab(
            guid: 50,
            url: "https://mail.example",
            isActive: true,
            index: 0,
            title: "Mail"
        )
        let calendar = Tab(
            guid: 51,
            url: "https://calendar.example",
            isActive: false,
            index: 1,
            title: "Calendar"
        )
        state.tabs = [mail, calendar]
        state.splits = [
            SplitGroup(
                id: "split-50-51",
                primaryTabId: 50,
                secondaryTabId: 51,
                layout: .vertical,
                ratio: 0.5
            ),
        ]
        let chromium = SearchTabsChromiumProvider(fetchData: { _ in
            [
                "openTabs": [
                    [
                        "tabId": 50,
                        "windowId": 7,
                        "index": 0,
                        "title": "Mail",
                        "url": "https://mail.example",
                        "split": true,
                        "hostWindow": true,
                        "lastActiveElapsedMs": 10,
                    ],
                ],
            ]
        })
        let controller = SearchTabsDataController(browserState: state, chromiumProvider: chromium)

        let snapshot = controller.snapshot(query: "")
        let item = try XCTUnwrap(snapshot.items.first)
        let relation = try XCTUnwrap(item.splitRelation)

        XCTAssertEqual(item.displayMode, .single)
        XCTAssertTrue(item.state.isSplit)
        XCTAssertEqual(relation.splitId, "split-50-51")
        XCTAssertEqual(relation.role, .primary)
        XCTAssertEqual(relation.partnerTabId, 51)
        XCTAssertEqual(relation.partnerTitle, "Calendar")
        XCTAssertEqual(relation.partnerURL, "https://calendar.example")
    }

    func testDataControllerReleasedStateUsesDefaultProfileAndWindowZero() {
        let controller = SearchTabsDataController(
            browserState: nil,
            chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in [:] })
        )

        let snapshot = controller.snapshot(query: "git")

        XCTAssertEqual(snapshot.profileId, LocalStore.defaultProfileId)
        XCTAssertEqual(snapshot.windowId, 0)
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testActionExecutorUsesCurrentWindowForChromiumActions() throws {
        let state = try makeSearchTabsState()
        var activated: (tabId: Int64, windowId: Int64)?
        var restored: (sessionId: Int64, windowId: Int64)?
        let executor = SearchTabsActionExecutor(
            browserState: state,
            activateChromiumTab: { tabId, windowId in
                activated = (tabId, windowId)
                return true
            },
            restoreClosedTab: { sessionId, windowId in
                restored = (sessionId, windowId)
                return true
            }
        )

        XCTAssertTrue(executor.perform(.activateChromiumTab(tabId: 101, windowId: 999)))
        XCTAssertTrue(executor.perform(.restoreClosedTab(sessionId: 202, sourceEntrySessionId: 303, sourceEntryType: "tab")))

        XCTAssertEqual(activated?.tabId, 101)
        XCTAssertEqual(activated?.windowId, Int64(state.windowId))
        XCTAssertEqual(restored?.sessionId, 202)
        XCTAssertEqual(restored?.windowId, Int64(state.windowId))
    }

    func testActionExecutorReleasedStateReturnsFalse() {
        let executor = SearchTabsActionExecutor(
            browserState: nil,
            activateChromiumTab: { _, _ in true },
            restoreClosedTab: { _, _ in true }
        )

        XCTAssertFalse(executor.perform(.activateChromiumTab(tabId: 101, windowId: 7)))
    }

    private func makeSearchTabsState(isIncognito: Bool = false) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default", isIncognito: isIncognito)
    }

    private func makeOpenTab(
        tabId: Int64,
        windowId: Int64,
        index: Int = 0,
        title: String,
        url: String = "https://example.com",
        active: Bool = false,
        pinned: Bool = false,
        split: Bool = false,
        hostWindow: Bool = false,
        lastActiveElapsedMs: Int64
    ) -> ChromiumSearchOpenTab {
        ChromiumSearchOpenTab(
            tabId: tabId,
            windowId: windowId,
            index: index,
            title: title,
            url: url,
            groupIdHex: "",
            active: active,
            pinned: pinned,
            split: split,
            hostWindow: hostWindow,
            lastActiveElapsedMs: lastActiveElapsedMs,
            lastActiveElapsedText: ""
        )
    }

    private func makeClosedTab(
        sessionId: Int64,
        sourceEntrySessionId: Int64? = nil,
        sourceEntryType: String = "tab",
        title: String,
        url: String = "https://example.com",
        lastActiveTimeMs: Int64,
        lastActiveElapsedMs: Int64,
        providerOrder: Int = 0
    ) -> ChromiumSearchClosedTab {
        ChromiumSearchClosedTab(
            sessionId: sessionId,
            sourceEntrySessionId: sourceEntrySessionId ?? sessionId,
            sourceEntryType: sourceEntryType,
            title: title,
            url: url,
            groupIdHex: "",
            lastActiveTimeMs: lastActiveTimeMs,
            lastActiveElapsedMs: lastActiveElapsedMs,
            lastActiveElapsedText: "",
            providerOrder: providerOrder
        )
    }

    private func nativeEntry(
        id: String,
        guid: String?,
        kind: SearchTabsKind,
        title: String,
        url: String?,
        isOpen: Bool,
        displayMode: SearchTabsDisplayMode = .single,
        action: SearchTabsActionTarget? = nil,
        providerOrder: Int = 0
    ) -> NativeSearchEntry {
        let localGuid = kind == .bookmarkRoot ? nil : guid
        let resolvedAction = action ?? {
            switch kind {
            case .pin:
                return .openPinned(localGuid: guid ?? "", preferredPaneGuid: nil)
            case .bookmark:
                return .openBookmark(localGuid: guid ?? "", preferredPaneGuid: nil)
            case .bookmarkRoot:
                return .showBookmarkMenuRoot(profileId: "profile-1")
            case .openedtab, .closedtab:
                return .showBookmarkMenuRoot(profileId: "profile-1")
            }
        }()

        return NativeSearchEntry(
            id: id,
            guid: guid,
            kind: kind,
            displayMode: displayMode,
            primary: SearchTabsPane(
                title: title,
                url: url,
                faviconData: nil,
                faviconURL: nil,
                localGuid: localGuid,
                chromiumTabId: nil,
                windowId: 7
            ),
            secondary: nil,
            state: SearchTabsItemState(
                isOpen: isOpen,
                isActive: false,
                isHostWindow: true,
                isPinnedInChromium: false,
                isSplit: false,
                lastSeen: nil,
                lastActiveElapsedMs: nil,
                lastActiveElapsedText: nil
            ),
            action: resolvedAction,
            secondaryAction: nil,
            providerOrder: providerOrder
        )
    }
}
