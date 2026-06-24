# Native Tab Search Data Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a profile-scoped native tab search data layer that combines Chromium open/recently closed tabs with native pinned-tab and bookmark entries.

**Architecture:** Add a focused `Sources/UserInterface/SearchTabs/` data module. Providers parse Chromium bridge snapshots and native `BrowserState`/`LocalStore` state, while a pure aggregator performs query matching, split shaping, and deterministic ranking for UI consumption.

**Tech Stack:** Swift, AppKit/Foundation, XCTest, existing `BrowserState`, `LocalStore`, `BookmarkManager`, and `PhiChromiumBridgeHeader`.

**Repository Rule:** Do not commit during implementation unless the user explicitly asks. The project instructions override the generic plan template's frequent-commit guidance.

---

## File Structure

- Create `Sources/UserInterface/SearchTabs/SearchTabsModels.swift`
  - Owns public data structs/enums used by providers, aggregator, tests, and future UI.
- Create `Sources/UserInterface/SearchTabs/SearchTabsQueryMatcher.swift`
  - Owns query normalization and deterministic match scoring.
- Create `Sources/UserInterface/SearchTabs/SearchTabsChromiumProvider.swift`
  - Parses bridge dictionaries and exposes typed Chromium open/closed snapshots.
- Create `Sources/UserInterface/SearchTabs/SearchTabsNativeProvider.swift`
  - Builds native pin/bookmark/bookmark-root snapshots from `BrowserState`.
- Create `Sources/UserInterface/SearchTabs/SearchTabsAggregator.swift`
  - Converts provider snapshots into `SearchTabsItem`, applies query filtering, split metadata, and sorting.
- Create `Sources/UserInterface/SearchTabs/SearchTabsDataController.swift`
  - Small facade future UI can call with `snapshot(query:)`.
- Create `Tests/PhiBrowserTests/SearchTabsDataTests.swift`
  - Focused unit coverage for parser, matcher, sorting, native split shaping, and incognito behavior.
- Modify `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`
  - Add missing search-tabs bridge declarations if the header still lacks them.
- Modify `Phi.xcodeproj/project.pbxproj`
  - Add new source files to the app target because `Sources` is not a filesystem-synchronized root group.

Reserve these project IDs for the new source files:

| File | PBXBuildFile ID | PBXFileReference ID |
| --- | --- | --- |
| `SearchTabsModels.swift` | `5EA17ABC0000000000000100` | `5EA17ABC0000000000000110` |
| `SearchTabsQueryMatcher.swift` | `5EA17ABC0000000000000101` | `5EA17ABC0000000000000111` |
| `SearchTabsChromiumProvider.swift` | `5EA17ABC0000000000000102` | `5EA17ABC0000000000000112` |
| `SearchTabsNativeProvider.swift` | `5EA17ABC0000000000000103` | `5EA17ABC0000000000000113` |
| `SearchTabsAggregator.swift` | `5EA17ABC0000000000000104` | `5EA17ABC0000000000000114` |
| `SearchTabsDataController.swift` | `5EA17ABC0000000000000105` | `5EA17ABC0000000000000115` |

Use `5EA17ABC0000000000000120` for the `SearchTabs` PBX group.

## Task 1: Add Core Models And Query Matcher

**Files:**
- Create: `Sources/UserInterface/SearchTabs/SearchTabsModels.swift`
- Create: `Sources/UserInterface/SearchTabs/SearchTabsQueryMatcher.swift`
- Create: `Tests/PhiBrowserTests/SearchTabsDataTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing matcher and model tests**

Add this initial test file:

```swift
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
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: fail because `SearchTabsQueryMatcher` and the search-tabs model types do not exist.

- [ ] **Step 3: Add `SearchTabsModels.swift`**

Create:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SearchTabsSource: Equatable {
    case chromium
    case native
}

enum SearchTabsKind: Equatable {
    case openedtab
    case closedtab
    case pin
    case bookmark
    case bookmarkRoot
}

enum SearchTabsDisplayMode: Equatable {
    case single
    case split
    case bookmarkMenuRoot
}

enum SearchTabsMatchedField: Hashable {
    case title
    case url
    case host
    case secondaryTitle
    case secondaryURL
}

struct SearchTabsPane: Equatable {
    let title: String
    let url: String?
    let faviconData: Data?
    let faviconURL: String?
    let localGuid: String?
    let chromiumTabId: Int?
    let windowId: Int?
}

struct SearchTabsItemState: Equatable {
    let isOpen: Bool
    let isActive: Bool
    let isHostWindow: Bool
    let isPinnedInChromium: Bool
    let isSplit: Bool
    let lastSeen: Date?
    let lastActiveElapsedMs: Int64?
    let lastActiveElapsedText: String?
}

struct SearchTabsRankingMetadata: Equatable {
    let matchScore: Int
    let matchedFields: Set<SearchTabsMatchedField>
    let providerOrder: Int
}

struct SearchTabsSplitRelation: Equatable {
    enum Role: Equatable {
        case primary
        case secondary
    }

    let splitId: String
    let layout: SplitLayout?
    let role: Role
    let partnerTabId: Int
    let partnerTitle: String
    let partnerURL: String?
}

enum SearchTabsActionTarget: Equatable {
    case activateChromiumTab(tabId: Int, windowId: Int)
    case restoreClosedTab(sessionId: Int, sourceEntrySessionId: Int, sourceEntryType: String)
    case openPinned(localGuid: String, preferredPaneGuid: String?)
    case openBookmark(localGuid: String, preferredPaneGuid: String?)
    case showBookmarkMenuRoot(profileId: String)
}

struct SearchTabsItem: Equatable {
    let id: String
    let source: SearchTabsSource
    let kind: SearchTabsKind
    let displayMode: SearchTabsDisplayMode
    let primary: SearchTabsPane
    let secondary: SearchTabsPane?
    let splitRelation: SearchTabsSplitRelation?
    let state: SearchTabsItemState
    let ranking: SearchTabsRankingMetadata
    let action: SearchTabsActionTarget
    let secondaryAction: SearchTabsActionTarget?
}

struct SearchTabsSnapshot: Equatable {
    let query: String
    let profileId: String
    let windowId: Int
    let generatedAt: Date
    let items: [SearchTabsItem]
}

struct SearchTabsMatch: Equatable {
    let score: Int
    let matchedFields: Set<SearchTabsMatchedField>
}
```

- [ ] **Step 4: Add `SearchTabsQueryMatcher.swift`**

Create:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SearchTabsQueryMatcher {
    static let titlePrefixScore = 400
    static let titleContainsScore = 300
    static let hostContainsScore = 200
    static let urlContainsScore = 100

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func match(
        query: String,
        primaryTitle: String,
        primaryURL: String?,
        secondaryTitle: String?,
        secondaryURL: String?
    ) -> SearchTabsMatch? {
        let normalized = normalizedQuery(query)
        guard !normalized.isEmpty else {
            return SearchTabsMatch(score: 0, matchedFields: [])
        }

        var bestScore = 0
        var fields: Set<SearchTabsMatchedField> = []

        scoreText(primaryTitle, query: normalized, prefixField: .title, containsField: .title, bestScore: &bestScore, fields: &fields)
        if let secondaryTitle {
            scoreText(secondaryTitle, query: normalized, prefixField: .secondaryTitle, containsField: .secondaryTitle, bestScore: &bestScore, fields: &fields)
        }
        scoreURL(primaryURL, query: normalized, urlField: .url, hostField: .host, bestScore: &bestScore, fields: &fields)
        scoreURL(secondaryURL, query: normalized, urlField: .secondaryURL, hostField: .secondaryURL, bestScore: &bestScore, fields: &fields)

        guard bestScore > 0 else { return nil }
        return SearchTabsMatch(score: bestScore, matchedFields: fields)
    }

    private static func scoreText(
        _ text: String,
        query: String,
        prefixField: SearchTabsMatchedField,
        containsField: SearchTabsMatchedField,
        bestScore: inout Int,
        fields: inout Set<SearchTabsMatchedField>
    ) {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if normalized.hasPrefix(query) {
            record(score: titlePrefixScore, field: prefixField, bestScore: &bestScore, fields: &fields)
        } else if normalized.contains(query) {
            record(score: titleContainsScore, field: containsField, bestScore: &bestScore, fields: &fields)
        }
    }

    private static func scoreURL(
        _ rawURL: String?,
        query: String,
        urlField: SearchTabsMatchedField,
        hostField: SearchTabsMatchedField,
        bestScore: inout Int,
        fields: inout Set<SearchTabsMatchedField>
    ) {
        guard let rawURL, !rawURL.isEmpty else { return }
        let normalizedURL = rawURL.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let host = URL(string: rawURL)?.host?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
           host.contains(query) {
            record(score: hostContainsScore, field: hostField, bestScore: &bestScore, fields: &fields)
        } else if normalizedURL.contains(query) {
            record(score: urlContainsScore, field: urlField, bestScore: &bestScore, fields: &fields)
        }
    }

    private static func record(
        score: Int,
        field: SearchTabsMatchedField,
        bestScore: inout Int,
        fields: inout Set<SearchTabsMatchedField>
    ) {
        if score > bestScore {
            bestScore = score
            fields = [field]
        } else if score == bestScore {
            fields.insert(field)
        }
    }
}
```

- [ ] **Step 5: Add source files to `Phi.xcodeproj/project.pbxproj`**

Add the first two files to the app target project file.

In the `PBXBuildFile` section, add:

```text
5EA17ABC0000000000000100 /* SearchTabsModels.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5EA17ABC0000000000000110 /* SearchTabsModels.swift */; };
5EA17ABC0000000000000101 /* SearchTabsQueryMatcher.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5EA17ABC0000000000000111 /* SearchTabsQueryMatcher.swift */; };
```

In the `PBXFileReference` section, add:

```text
5EA17ABC0000000000000110 /* SearchTabsModels.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SearchTabsModels.swift; sourceTree = "<group>"; };
5EA17ABC0000000000000111 /* SearchTabsQueryMatcher.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SearchTabsQueryMatcher.swift; sourceTree = "<group>"; };
```

In the `PBXGroup` section, add this group:

```text
5EA17ABC0000000000000120 /* SearchTabs */ = {
    isa = PBXGroup;
    children = (
        5EA17ABC0000000000000110 /* SearchTabsModels.swift */,
        5EA17ABC0000000000000111 /* SearchTabsQueryMatcher.swift */,
    );
    path = SearchTabs;
    sourceTree = "<group>";
};
```

In the `B0F370CC2E432646000B51F9 /* UserInterface */` group children, insert:

```text
5EA17ABC0000000000000120 /* SearchTabs */,
```

near `AA10000000000000000000G1 /* TabSwitch */`.

In the app target `PBXSourcesBuildPhase` children, add:

```text
5EA17ABC0000000000000100 /* SearchTabsModels.swift in Sources */,
5EA17ABC0000000000000101 /* SearchTabsQueryMatcher.swift in Sources */,
```

Before editing, verify the reserved IDs are absent with `rg "5EA17ABC00000000000001" Phi.xcodeproj/project.pbxproj`. Expected: no matches.

- [ ] **Step 6: Run tests for Task 1**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: `SearchTabsDataTests` passes.

## Task 2: Add Chromium Provider Parser

**Files:**
- Create: `Sources/UserInterface/SearchTabs/SearchTabsChromiumProvider.swift`
- Modify: `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`
- Modify: `Tests/PhiBrowserTests/SearchTabsDataTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing Chromium parser tests**

Append to `SearchTabsDataTests`:

```swift
    func testChromiumProviderParsesOpenAndClosedTabDictionaries() {
        let snapshot = SearchTabsChromiumProvider.parse(data: [
            "openTabs": [
                [
                    "tabId": 11,
                    "windowId": 7,
                    "index": 1,
                    "title": "GitHub",
                    "url": "https://github.com",
                    "groupIdHex": "abc",
                    "active": true,
                    "pinned": false,
                    "split": true,
                    "hostWindow": true,
                    "lastActiveElapsedMs": 20,
                    "lastActiveElapsedText": "just now",
                ],
            ],
            "recentlyClosedTabs": [
                [
                    "sessionId": 101,
                    "sourceEntrySessionId": 100,
                    "sourceEntryType": "tab",
                    "title": "Closed",
                    "url": "https://closed.example",
                    "groupIdHex": "",
                    "lastActiveTimeMs": 1_800_000_000_000,
                    "lastActiveElapsedMs": 500,
                    "lastActiveElapsedText": "5 mins ago",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.openTabs.count, 1)
        XCTAssertEqual(snapshot.openTabs.first?.tabId, 11)
        XCTAssertEqual(snapshot.openTabs.first?.windowId, 7)
        XCTAssertEqual(snapshot.openTabs.first?.isSplit, true)
        XCTAssertEqual(snapshot.openTabs.first?.lastActiveElapsedMs, 20)
        XCTAssertEqual(snapshot.closedTabs.count, 1)
        XCTAssertEqual(snapshot.closedTabs.first?.sessionId, 101)
        XCTAssertEqual(snapshot.closedTabs.first?.sourceEntryType, "tab")
    }

    func testChromiumProviderSkipsMalformedItemsWithoutDroppingValidItems() {
        let snapshot = SearchTabsChromiumProvider.parse(data: [
            "openTabs": [
                ["tabId": -1, "windowId": 7, "title": "Bad"],
                [
                    "tabId": 12,
                    "windowId": 7,
                    "index": 0,
                    "title": "Valid",
                    "url": "https://valid.example",
                    "active": false,
                    "pinned": false,
                    "split": false,
                    "hostWindow": false,
                    "lastActiveElapsedMs": 100,
                    "lastActiveElapsedText": "1 min ago",
                ],
            ],
            "recentlyClosedTabs": [
                ["sessionId": 0, "title": "Bad"],
                [
                    "sessionId": 201,
                    "sourceEntrySessionId": 201,
                    "sourceEntryType": "window",
                    "title": "Valid Closed",
                    "url": "https://closed.example",
                    "lastActiveTimeMs": 1,
                    "lastActiveElapsedMs": 2,
                    "lastActiveElapsedText": "2 ms ago",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.openTabs.map(\.tabId), [12])
        XCTAssertEqual(snapshot.closedTabs.map(\.sessionId), [201])
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: fail because `SearchTabsChromiumProvider` is missing.

- [ ] **Step 3: Add bridge declarations if missing**

In `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`, add these declarations near related tab/window bridge methods if they are not already present:

```objc
- (NSDictionary<NSString *, id> *)getSearchTabsDataWithWindowId:(int64_t)windowId;

- (BOOL)activateSearchTabWithTabId:(int64_t)tabId
                          windowId:(int64_t)windowId;

- (BOOL)openRecentlyClosedSearchEntryWithSessionId:(int64_t)sessionId
                                          windowId:(int64_t)windowId;
```

- [ ] **Step 4: Add `SearchTabsChromiumProvider.swift`**

Create:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SearchTabsChromiumSnapshot: Equatable {
    let openTabs: [ChromiumSearchOpenTab]
    let closedTabs: [ChromiumSearchClosedTab]
}

struct ChromiumSearchOpenTab: Equatable {
    let tabId: Int
    let windowId: Int
    let index: Int
    let title: String
    let url: String
    let groupIdHex: String
    let isActive: Bool
    let isPinned: Bool
    let isSplit: Bool
    let isHostWindow: Bool
    let lastActiveElapsedMs: Int64
    let lastActiveElapsedText: String
}

struct ChromiumSearchClosedTab: Equatable {
    let sessionId: Int
    let sourceEntrySessionId: Int
    let sourceEntryType: String
    let title: String
    let url: String
    let groupIdHex: String
    let lastActiveTimeMs: Int64
    let lastActiveElapsedMs: Int64
    let lastActiveElapsedText: String
    let providerOrder: Int
}

@MainActor
struct SearchTabsChromiumProvider {
    var fetchData: (Int) -> [AnyHashable: Any]

    init(fetchData: @escaping (Int) -> [AnyHashable: Any] = { windowId in
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              let data = bridge.getSearchTabsData(withWindowId: Int64(windowId)) as? [AnyHashable: Any] else {
            return [:]
        }
        return data
    }) {
        self.fetchData = fetchData
    }

    func snapshot(windowId: Int) -> SearchTabsChromiumSnapshot {
        Self.parse(data: fetchData(windowId))
    }

    static func parse(data: [AnyHashable: Any]) -> SearchTabsChromiumSnapshot {
        let rawOpenTabs = data["openTabs"] as? [[AnyHashable: Any]] ?? []
        let rawClosedTabs = data["recentlyClosedTabs"] as? [[AnyHashable: Any]] ?? []
        return SearchTabsChromiumSnapshot(
            openTabs: rawOpenTabs.compactMap(parseOpenTab),
            closedTabs: rawClosedTabs.enumerated().compactMap { index, item in
                parseClosedTab(item, providerOrder: index)
            }
        )
    }

    private static func parseOpenTab(_ item: [AnyHashable: Any]) -> ChromiumSearchOpenTab? {
        guard let tabId = intValue(item["tabId"]), tabId > 0,
              let windowId = intValue(item["windowId"]), windowId > 0 else {
            return nil
        }
        return ChromiumSearchOpenTab(
            tabId: tabId,
            windowId: windowId,
            index: intValue(item["index"]) ?? 0,
            title: stringValue(item["title"]),
            url: stringValue(item["url"], fallback: "about:blank"),
            groupIdHex: stringValue(item["groupIdHex"]),
            isActive: boolValue(item["active"]),
            isPinned: boolValue(item["pinned"]),
            isSplit: boolValue(item["split"]),
            isHostWindow: boolValue(item["hostWindow"]),
            lastActiveElapsedMs: int64Value(item["lastActiveElapsedMs"]) ?? Int64.max,
            lastActiveElapsedText: stringValue(item["lastActiveElapsedText"])
        )
    }

    private static func parseClosedTab(_ item: [AnyHashable: Any], providerOrder: Int) -> ChromiumSearchClosedTab? {
        guard let sessionId = intValue(item["sessionId"]), sessionId > 0 else {
            return nil
        }
        return ChromiumSearchClosedTab(
            sessionId: sessionId,
            sourceEntrySessionId: intValue(item["sourceEntrySessionId"]) ?? sessionId,
            sourceEntryType: stringValue(item["sourceEntryType"], fallback: "unknown"),
            title: stringValue(item["title"]),
            url: stringValue(item["url"]),
            groupIdHex: stringValue(item["groupIdHex"]),
            lastActiveTimeMs: int64Value(item["lastActiveTimeMs"]) ?? 0,
            lastActiveElapsedMs: int64Value(item["lastActiveElapsedMs"]) ?? Int64.max,
            lastActiveElapsedText: stringValue(item["lastActiveElapsedText"]),
            providerOrder: providerOrder
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return (string as NSString).boolValue }
        return false
    }

    private static func stringValue(_ value: Any?, fallback: String = "") -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return fallback
    }
}
```

- [ ] **Step 5: Add provider file to the project**

Add `SearchTabsChromiumProvider.swift` to the same `SearchTabs` PBX group and app target source build phase created in Task 1.

In the `PBXBuildFile` section, add:

```text
5EA17ABC0000000000000102 /* SearchTabsChromiumProvider.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5EA17ABC0000000000000112 /* SearchTabsChromiumProvider.swift */; };
```

In the `PBXFileReference` section, add:

```text
5EA17ABC0000000000000112 /* SearchTabsChromiumProvider.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SearchTabsChromiumProvider.swift; sourceTree = "<group>"; };
```

In the `5EA17ABC0000000000000120 /* SearchTabs */` group children, add:

```text
5EA17ABC0000000000000112 /* SearchTabsChromiumProvider.swift */,
```

In the app target `PBXSourcesBuildPhase` children, add:

```text
5EA17ABC0000000000000102 /* SearchTabsChromiumProvider.swift in Sources */,
```

- [ ] **Step 6: Run tests for Task 2**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: `SearchTabsDataTests` passes.

## Task 3: Add Native Provider

**Files:**
- Create: `Sources/UserInterface/SearchTabs/SearchTabsNativeProvider.swift`
- Modify: `Tests/PhiBrowserTests/SearchTabsDataTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing native provider tests**

Append to `SearchTabsDataTests`:

```swift
    func testNativeProviderReturnsBookmarkRootOnlyForEmptyQuery() throws {
        let bookmark = Bookmark(guid: "bookmark-1", title: "Docs", url: "https://docs.example", profileId: "Default")
        let provider = SearchTabsNativeProvider(
            profileId: "Default",
            windowId: 7,
            isIncognito: false,
            pinnedTabs: [],
            bookmarks: [bookmark],
            focusingTab: nil,
            splits: [],
            pinnedSplitPair: { _ in nil }
        )
        let snapshot = provider.snapshot(includeBookmarkRoot: true)

        XCTAssertEqual(snapshot.bookmarkRoot?.kind, .bookmarkRoot)
        XCTAssertEqual(snapshot.bookmarks.count, 1)
        XCTAssertEqual(snapshot.bookmarks.first?.guid, "bookmark-1")
    }

    func testNativeProviderSkipsNativeResultsForIncognito() throws {
        let provider = SearchTabsNativeProvider(
            profileId: "Default",
            windowId: 7,
            isIncognito: true,
            pinnedTabs: [
                Tab(guid: -1, url: "https://pinned.example", isActive: false, index: 0, title: "Pinned", customGuid: "pin-1")
            ],
            bookmarks: [],
            focusingTab: nil,
            splits: [],
            pinnedSplitPair: { _ in nil }
        )
        let snapshot = provider.snapshot(includeBookmarkRoot: true)

        XCTAssertTrue(snapshot.pins.isEmpty)
        XCTAssertTrue(snapshot.bookmarks.isEmpty)
        XCTAssertNil(snapshot.bookmarkRoot)
    }

    func testNativeProviderBuildsPinnedSplitAsSingleEntry() throws {
        let left = Tab(guid: 10, url: "https://mail.example", isActive: true, index: 0, title: "Mail", customGuid: "pin-left")
        let right = Tab(guid: 11, url: "https://calendar.example", isActive: false, index: 1, title: "Calendar", customGuid: "pin-right")
        left.splitPartnerGuid = "pin-right"
        right.splitPartnerGuid = "pin-left"
        left.isOpenned = true
        right.isOpenned = true
        let provider = SearchTabsNativeProvider(
            profileId: "Default",
            windowId: 7,
            isIncognito: false,
            pinnedTabs: [left, right],
            bookmarks: [],
            focusingTab: left,
            splits: [],
            pinnedSplitPair: { tab in
                tab.guidInLocalDB == "pin-left" || tab.guidInLocalDB == "pin-right"
                    ? ("pin-left", "pin-right")
                    : nil
            }
        )
        let snapshot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(snapshot.pins.count, 1)
        XCTAssertEqual(snapshot.pins.first?.primary.localGuid, "pin-left")
        XCTAssertEqual(snapshot.pins.first?.secondary?.localGuid, "pin-right")
        XCTAssertEqual(snapshot.pins.first?.displayMode, .split)
        XCTAssertEqual(snapshot.pins.first?.state.isOpen, true)
        XCTAssertEqual(snapshot.pins.first?.state.isActive, true)
    }

    func testNativeProviderBuildsSplitBookmarkAsSingleEntry() throws {
        let bookmark = Bookmark(
            guid: "bookmark-split",
            title: "Mail",
            url: "https://mail.example",
            secondaryUrl: "https://calendar.example",
            secondaryTitle: "Calendar",
            profileId: "Default",
            isFolder: false
        )
        let provider = SearchTabsNativeProvider(
            profileId: "Default",
            windowId: 7,
            isIncognito: false,
            pinnedTabs: [],
            bookmarks: [bookmark],
            focusingTab: nil,
            splits: [],
            pinnedSplitPair: { _ in nil }
        )
        let snapshot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(snapshot.bookmarks.count, 1)
        XCTAssertEqual(snapshot.bookmarks.first?.displayMode, .split)
        XCTAssertEqual(snapshot.bookmarks.first?.primary.title, "Mail")
        XCTAssertEqual(snapshot.bookmarks.first?.secondary?.title, "Calendar")
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: fail because `SearchTabsNativeProvider` is missing.

- [ ] **Step 3: Add `SearchTabsNativeProvider.swift`**

Create:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SearchTabsNativeSnapshot: Equatable {
    let pins: [NativeSearchEntry]
    let bookmarks: [NativeSearchEntry]
    let bookmarkRoot: NativeSearchEntry?
}

struct NativeSearchEntry: Equatable {
    let id: String
    let kind: SearchTabsKind
    let displayMode: SearchTabsDisplayMode
    let primary: SearchTabsPane
    let secondary: SearchTabsPane?
    let state: SearchTabsItemState
    let action: SearchTabsActionTarget
    let secondaryAction: SearchTabsActionTarget?
    let providerOrder: Int
}

@MainActor
struct SearchTabsNativeProvider {
    private struct Input {
        let profileId: String
        let windowId: Int
        let isIncognito: Bool
        let pinnedTabs: [Tab]
        let bookmarks: [Bookmark]
        let focusingTab: Tab?
        let splits: [SplitGroup]
        let pinnedSplitPair: (Tab) -> (String, String)?
    }

    private let makeInput: () -> Input

    init(browserState: BrowserState) {
        self.makeInput = { [weak browserState] in
            guard let state = browserState else {
                return Input(
                    profileId: LocalStore.defaultProfileId,
                    windowId: 0,
                    isIncognito: true,
                    pinnedTabs: [],
                    bookmarks: [],
                    focusingTab: nil,
                    splits: [],
                    pinnedSplitPair: { _ in nil }
                )
            }
            return Input(
                profileId: state.profileId,
                windowId: state.windowId,
                isIncognito: state.isIncognito,
                pinnedTabs: state.pinnedTabs,
                bookmarks: state.bookmarkManager.getAllBookmarks(),
                focusingTab: state.focusingTab,
                splits: state.splits,
                pinnedSplitPair: { tab in state.pinnedSplitDBPair(forPinnedTab: tab) }
            )
        }
    }

    init(
        profileId: String,
        windowId: Int,
        isIncognito: Bool,
        pinnedTabs: [Tab],
        bookmarks: [Bookmark],
        focusingTab: Tab?,
        splits: [SplitGroup],
        pinnedSplitPair: @escaping (Tab) -> (String, String)?
    ) {
        self.makeInput = {
            Input(
                profileId: profileId,
                windowId: windowId,
                isIncognito: isIncognito,
                pinnedTabs: pinnedTabs,
                bookmarks: bookmarks,
                focusingTab: focusingTab,
                splits: splits,
                pinnedSplitPair: pinnedSplitPair
            )
        }
    }

    func snapshot(includeBookmarkRoot: Bool) -> SearchTabsNativeSnapshot {
        let input = makeInput()
        guard !input.isIncognito else {
            return SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        }
        return SearchTabsNativeSnapshot(
            pins: buildPinnedEntries(from: input),
            bookmarks: buildBookmarkEntries(from: input),
            bookmarkRoot: includeBookmarkRoot ? buildBookmarkRoot(profileId: input.profileId) : nil
        )
    }

    private func buildPinnedEntries(from input: Input) -> [NativeSearchEntry] {
        var consumed: Set<String> = []
        var result: [NativeSearchEntry] = []

        for (index, tab) in input.pinnedTabs.enumerated() {
            guard let guid = tab.guidInLocalDB, !consumed.contains(guid) else { continue }

            if let (leftGuid, rightGuid) = input.pinnedSplitPair(tab),
               let left = input.pinnedTabs.first(where: { $0.guidInLocalDB == leftGuid }),
               let right = input.pinnedTabs.first(where: { $0.guidInLocalDB == rightGuid }) {
                consumed.insert(leftGuid)
                consumed.insert(rightGuid)
                result.append(makePinnedSplitEntry(left: left, right: right, providerOrder: index, input: input))
            } else {
                consumed.insert(guid)
                result.append(makePinnedEntry(tab, providerOrder: index, input: input))
            }
        }
        return result
    }

    private func makePinnedEntry(_ tab: Tab, providerOrder: Int, input: Input) -> NativeSearchEntry {
        let guid = tab.guidInLocalDB ?? ""
        let isActive = input.focusingTab?.guidInLocalDB == guid || input.focusingTab?.guid == tab.guid
        return NativeSearchEntry(
            id: "pin:\(guid)",
            kind: .pin,
            displayMode: .single,
            primary: pane(from: tab),
            secondary: nil,
            state: itemState(isOpen: tab.isOpenned, isActive: isActive, isHostWindow: true, isPinnedInChromium: tab.isPinned, isSplit: false, lastSeen: tab.lastSeen),
            action: .openPinned(localGuid: guid, preferredPaneGuid: nil),
            secondaryAction: nil,
            providerOrder: providerOrder
        )
    }

    private func makePinnedSplitEntry(left: Tab, right: Tab, providerOrder: Int, input: Input) -> NativeSearchEntry {
        let leftGuid = left.guidInLocalDB ?? ""
        let rightGuid = right.guidInLocalDB ?? ""
        let focusedGuid = input.focusingTab?.guidInLocalDB
        let focusedTabId = input.focusingTab?.guid
        let isActive = focusedGuid == leftGuid || focusedGuid == rightGuid || focusedTabId == left.guid || focusedTabId == right.guid
        return NativeSearchEntry(
            id: "pin-split:\(leftGuid):\(rightGuid)",
            kind: .pin,
            displayMode: .split,
            primary: pane(from: left),
            secondary: pane(from: right),
            state: itemState(isOpen: left.isOpenned || right.isOpenned, isActive: isActive, isHostWindow: true, isPinnedInChromium: left.isPinned || right.isPinned, isSplit: true, lastSeen: maxDate(left.lastSeen, right.lastSeen)),
            action: .openPinned(localGuid: leftGuid, preferredPaneGuid: nil),
            secondaryAction: .openPinned(localGuid: leftGuid, preferredPaneGuid: rightGuid),
            providerOrder: providerOrder
        )
    }

    private func buildBookmarkEntries(from input: Input) -> [NativeSearchEntry] {
        input.bookmarks.enumerated().compactMap { index, bookmark in
            guard !bookmark.isFolder else { return nil }
            return makeBookmarkEntry(bookmark, providerOrder: index, input: input)
        }
    }

    private func makeBookmarkEntry(_ bookmark: Bookmark, providerOrder: Int, input: Input) -> NativeSearchEntry {
        let secondaryPane: SearchTabsPane? = {
            guard let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty else { return nil }
            return SearchTabsPane(
                title: bookmark.secondaryTitle?.isEmpty == false ? bookmark.secondaryTitle! : secondaryURL,
                url: secondaryURL,
                faviconData: nil,
                faviconURL: nil,
                localGuid: bookmark.guid,
                chromiumTabId: nil,
                windowId: input.windowId
            )
        }()
        let isSplit = secondaryPane != nil
        return NativeSearchEntry(
            id: isSplit ? "bookmark-split:\(bookmark.guid)" : "bookmark:\(bookmark.guid)",
            kind: .bookmark,
            displayMode: isSplit ? .split : .single,
            primary: SearchTabsPane(
                title: bookmark.title,
                url: bookmark.url,
                faviconData: bookmark.liveFaviconData ?? bookmark.cachedFaviconData,
                faviconURL: bookmark.faviconUrl,
                localGuid: bookmark.guid,
                chromiumTabId: bookmark.chromiumTabGuid == -1 ? nil : bookmark.chromiumTabGuid,
                windowId: input.windowId
            ),
            secondary: secondaryPane,
            state: itemState(isOpen: bookmark.isOpened, isActive: bookmark.isActive, isHostWindow: true, isPinnedInChromium: false, isSplit: isSplit, lastSeen: bookmark.lastSeen),
            action: .openBookmark(localGuid: bookmark.guid, preferredPaneGuid: nil),
            secondaryAction: isSplit ? .openBookmark(localGuid: bookmark.guid, preferredPaneGuid: bookmark.guid) : nil,
            providerOrder: providerOrder
        )
    }

    private func buildBookmarkRoot(profileId: String) -> NativeSearchEntry {
        NativeSearchEntry(
            id: "bookmark-root:\(profileId)",
            kind: .bookmarkRoot,
            displayMode: .bookmarkMenuRoot,
            primary: SearchTabsPane(title: "Bookmarks", url: nil, faviconData: nil, faviconURL: nil, localGuid: nil, chromiumTabId: nil, windowId: nil),
            secondary: nil,
            state: itemState(isOpen: false, isActive: false, isHostWindow: true, isPinnedInChromium: false, isSplit: false, lastSeen: nil),
            action: .showBookmarkMenuRoot(profileId: profileId),
            secondaryAction: nil,
            providerOrder: Int.max
        )
    }

    private func pane(from tab: Tab) -> SearchTabsPane {
        SearchTabsPane(
            title: tab.storedTitle ?? tab.title,
            url: tab.pinnedUrl ?? tab.url,
            faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
            faviconURL: tab.faviconUrl,
            localGuid: tab.guidInLocalDB,
            chromiumTabId: tab.guid > 0 ? tab.guid : nil,
            windowId: tab.windowId
        )
    }

    private func itemState(
        isOpen: Bool,
        isActive: Bool,
        isHostWindow: Bool,
        isPinnedInChromium: Bool,
        isSplit: Bool,
        lastSeen: Date?
    ) -> SearchTabsItemState {
        SearchTabsItemState(
            isOpen: isOpen,
            isActive: isActive,
            isHostWindow: isHostWindow,
            isPinnedInChromium: isPinnedInChromium,
            isSplit: isSplit,
            lastSeen: lastSeen,
            lastActiveElapsedMs: nil,
            lastActiveElapsedText: nil
        )
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }
}
```

- [ ] **Step 4: Add provider file to the project**

Add `SearchTabsNativeProvider.swift` to the `SearchTabs` PBX group and app target source build phase.

In the `PBXBuildFile` section, add:

```text
5EA17ABC0000000000000103 /* SearchTabsNativeProvider.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5EA17ABC0000000000000113 /* SearchTabsNativeProvider.swift */; };
```

In the `PBXFileReference` section, add:

```text
5EA17ABC0000000000000113 /* SearchTabsNativeProvider.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SearchTabsNativeProvider.swift; sourceTree = "<group>"; };
```

In the `5EA17ABC0000000000000120 /* SearchTabs */` group children, add:

```text
5EA17ABC0000000000000113 /* SearchTabsNativeProvider.swift */,
```

In the app target `PBXSourcesBuildPhase` children, add:

```text
5EA17ABC0000000000000103 /* SearchTabsNativeProvider.swift in Sources */,
```

- [ ] **Step 5: Run tests for Task 3**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: `SearchTabsDataTests` passes.

## Task 4: Add Aggregator And Data Controller

**Files:**
- Create: `Sources/UserInterface/SearchTabs/SearchTabsAggregator.swift`
- Create: `Sources/UserInterface/SearchTabs/SearchTabsDataController.swift`
- Modify: `Tests/PhiBrowserTests/SearchTabsDataTests.swift`
- Modify: `Phi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing aggregator tests**

Append to `SearchTabsDataTests`:

```swift
    func testAggregatorKeepsOpenedTabAndMatchingNativePinAndRanksOpenedFirst() {
        let open = ChromiumSearchOpenTab(
            tabId: 42,
            windowId: 7,
            index: 0,
            title: "GitHub",
            url: "https://github.com",
            groupIdHex: "",
            isActive: false,
            isPinned: true,
            isSplit: false,
            isHostWindow: true,
            lastActiveElapsedMs: 10,
            lastActiveElapsedText: "just now"
        )
        let pin = NativeSearchEntry(
            id: "pin:github",
            kind: .pin,
            displayMode: .single,
            primary: SearchTabsPane(title: "GitHub", url: "https://github.com", faviconData: nil, faviconURL: nil, localGuid: "github", chromiumTabId: 42, windowId: 7),
            secondary: nil,
            state: SearchTabsItemState(isOpen: true, isActive: false, isHostWindow: true, isPinnedInChromium: true, isSplit: false, lastSeen: nil, lastActiveElapsedMs: nil, lastActiveElapsedText: nil),
            action: .openPinned(localGuid: "github", preferredPaneGuid: nil),
            secondaryAction: nil,
            providerOrder: 0
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "git",
            profileId: "Default",
            windowId: 7,
            chromium: SearchTabsChromiumSnapshot(openTabs: [open], closedTabs: []),
            native: SearchTabsNativeSnapshot(pins: [pin], bookmarks: [], bookmarkRoot: nil),
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(snapshot.items.map(\.kind), [.openedtab, .pin])
        XCTAssertEqual(snapshot.items.first?.action, .activateChromiumTab(tabId: 42, windowId: 7))
        XCTAssertEqual(snapshot.items.last?.state.isOpen, true)
    }

    func testAggregatorEmptyQueryShowsBookmarkRootButNotClosedBookmarks() {
        let closedBookmark = NativeSearchEntry(
            id: "bookmark:docs",
            kind: .bookmark,
            displayMode: .single,
            primary: SearchTabsPane(title: "Docs", url: "https://docs.example", faviconData: nil, faviconURL: nil, localGuid: "docs", chromiumTabId: nil, windowId: 7),
            secondary: nil,
            state: SearchTabsItemState(isOpen: false, isActive: false, isHostWindow: true, isPinnedInChromium: false, isSplit: false, lastSeen: nil, lastActiveElapsedMs: nil, lastActiveElapsedText: nil),
            action: .openBookmark(localGuid: "docs", preferredPaneGuid: nil),
            secondaryAction: nil,
            providerOrder: 0
        )
        let root = NativeSearchEntry(
            id: "bookmark-root:Default",
            kind: .bookmarkRoot,
            displayMode: .bookmarkMenuRoot,
            primary: SearchTabsPane(title: "Bookmarks", url: nil, faviconData: nil, faviconURL: nil, localGuid: nil, chromiumTabId: nil, windowId: nil),
            secondary: nil,
            state: SearchTabsItemState(isOpen: false, isActive: false, isHostWindow: true, isPinnedInChromium: false, isSplit: false, lastSeen: nil, lastActiveElapsedMs: nil, lastActiveElapsedText: nil),
            action: .showBookmarkMenuRoot(profileId: "Default"),
            secondaryAction: nil,
            providerOrder: Int.max
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "",
            profileId: "Default",
            windowId: 7,
            chromium: SearchTabsChromiumSnapshot(openTabs: [], closedTabs: []),
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [closedBookmark], bookmarkRoot: root),
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(snapshot.items.map(\.kind), [.bookmarkRoot])
    }

    func testAggregatorSortsOpenedTabsByHostActiveThenElapsedAscending() {
        let hostOlder = makeOpenTab(tabId: 1, windowId: 7, index: 0, active: false, host: true, elapsed: 500)
        let otherRecent = makeOpenTab(tabId: 2, windowId: 8, index: 0, active: false, host: false, elapsed: 1)
        let hostActive = makeOpenTab(tabId: 3, windowId: 7, index: 1, active: true, host: true, elapsed: 200)
        let hostRecent = makeOpenTab(tabId: 4, windowId: 7, index: 2, active: false, host: true, elapsed: 20)

        let snapshot = SearchTabsAggregator.aggregate(
            query: "",
            profileId: "Default",
            windowId: 7,
            chromium: SearchTabsChromiumSnapshot(openTabs: [hostOlder, otherRecent, hostActive, hostRecent], closedTabs: []),
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil),
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(snapshot.items.map { $0.primary.chromiumTabId }, [3, 4, 1, 2])
    }

    private func makeOpenTab(tabId: Int, windowId: Int, index: Int, active: Bool, host: Bool, elapsed: Int64) -> ChromiumSearchOpenTab {
        ChromiumSearchOpenTab(
            tabId: tabId,
            windowId: windowId,
            index: index,
            title: "Tab \(tabId)",
            url: "https://example\(tabId).com",
            groupIdHex: "",
            isActive: active,
            isPinned: false,
            isSplit: false,
            isHostWindow: host,
            lastActiveElapsedMs: elapsed,
            lastActiveElapsedText: "\(elapsed)"
        )
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: fail because `SearchTabsAggregator` is missing.

- [ ] **Step 3: Add `SearchTabsAggregator.swift`**

Create:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SearchTabsAggregator {
    static func aggregate(
        query: String,
        profileId: String,
        windowId: Int,
        chromium: SearchTabsChromiumSnapshot,
        native: SearchTabsNativeSnapshot,
        generatedAt: Date = Date()
    ) -> SearchTabsSnapshot {
        let normalizedQuery = SearchTabsQueryMatcher.normalizedQuery(query)
        let isEmptyQuery = normalizedQuery.isEmpty
        var items: [SearchTabsItem] = []

        items.append(contentsOf: chromium.openTabs.enumerated().compactMap { index, tab in
            makeOpenTabItem(tab, providerOrder: index, query: normalizedQuery, includeWhenQueryIsEmpty: isEmptyQuery)
        })

        items.append(contentsOf: native.pins.compactMap { entry in
            makeNativeItem(entry, query: normalizedQuery, includeWhenQueryIsEmpty: isEmptyQuery)
        })

        items.append(contentsOf: native.bookmarks.compactMap { entry in
            if isEmptyQuery && !entry.state.isOpen { return nil }
            return makeNativeItem(entry, query: normalizedQuery, includeWhenQueryIsEmpty: isEmptyQuery)
        })

        if isEmptyQuery, let root = native.bookmarkRoot {
            items.append(nativeItem(root, match: SearchTabsMatch(score: 0, matchedFields: [])))
        }

        items.append(contentsOf: chromium.closedTabs.compactMap { tab in
            makeClosedTabItem(tab, query: normalizedQuery, includeWhenQueryIsEmpty: isEmptyQuery)
        })

        return SearchTabsSnapshot(
            query: query,
            profileId: profileId,
            windowId: windowId,
            generatedAt: generatedAt,
            items: items.sorted(by: sort)
        )
    }

    private static func makeOpenTabItem(
        _ tab: ChromiumSearchOpenTab,
        providerOrder: Int,
        query: String,
        includeWhenQueryIsEmpty: Bool
    ) -> SearchTabsItem? {
        let match = SearchTabsQueryMatcher.match(query: query, primaryTitle: tab.title, primaryURL: tab.url, secondaryTitle: nil, secondaryURL: nil)
        guard includeWhenQueryIsEmpty || match != nil else { return nil }
        return SearchTabsItem(
            id: "openedtab:\(tab.windowId):\(tab.tabId)",
            source: .chromium,
            kind: .openedtab,
            displayMode: .single,
            primary: SearchTabsPane(title: tab.title, url: tab.url, faviconData: nil, faviconURL: nil, localGuid: nil, chromiumTabId: tab.tabId, windowId: tab.windowId),
            secondary: nil,
            splitRelation: nil,
            state: SearchTabsItemState(isOpen: true, isActive: tab.isActive, isHostWindow: tab.isHostWindow, isPinnedInChromium: tab.isPinned, isSplit: tab.isSplit, lastSeen: nil, lastActiveElapsedMs: tab.lastActiveElapsedMs, lastActiveElapsedText: tab.lastActiveElapsedText),
            ranking: SearchTabsRankingMetadata(matchScore: match?.score ?? 0, matchedFields: match?.matchedFields ?? [], providerOrder: providerOrder),
            action: .activateChromiumTab(tabId: tab.tabId, windowId: tab.windowId),
            secondaryAction: nil
        )
    }

    private static func makeClosedTabItem(
        _ tab: ChromiumSearchClosedTab,
        query: String,
        includeWhenQueryIsEmpty: Bool
    ) -> SearchTabsItem? {
        let match = SearchTabsQueryMatcher.match(query: query, primaryTitle: tab.title, primaryURL: tab.url, secondaryTitle: nil, secondaryURL: nil)
        guard includeWhenQueryIsEmpty || match != nil else { return nil }
        return SearchTabsItem(
            id: "closedtab:\(tab.sessionId)",
            source: .chromium,
            kind: .closedtab,
            displayMode: .single,
            primary: SearchTabsPane(title: tab.title, url: tab.url, faviconData: nil, faviconURL: nil, localGuid: nil, chromiumTabId: nil, windowId: nil),
            secondary: nil,
            splitRelation: nil,
            state: SearchTabsItemState(isOpen: false, isActive: false, isHostWindow: false, isPinnedInChromium: false, isSplit: false, lastSeen: nil, lastActiveElapsedMs: tab.lastActiveElapsedMs, lastActiveElapsedText: tab.lastActiveElapsedText),
            ranking: SearchTabsRankingMetadata(matchScore: match?.score ?? 0, matchedFields: match?.matchedFields ?? [], providerOrder: tab.providerOrder),
            action: .restoreClosedTab(sessionId: tab.sessionId, sourceEntrySessionId: tab.sourceEntrySessionId, sourceEntryType: tab.sourceEntryType),
            secondaryAction: nil
        )
    }

    private static func makeNativeItem(_ entry: NativeSearchEntry, query: String, includeWhenQueryIsEmpty: Bool) -> SearchTabsItem? {
        let match = SearchTabsQueryMatcher.match(
            query: query,
            primaryTitle: entry.primary.title,
            primaryURL: entry.primary.url,
            secondaryTitle: entry.secondary?.title,
            secondaryURL: entry.secondary?.url
        )
        guard includeWhenQueryIsEmpty || match != nil else { return nil }
        return nativeItem(entry, match: match ?? SearchTabsMatch(score: 0, matchedFields: []))
    }

    private static func nativeItem(_ entry: NativeSearchEntry, match: SearchTabsMatch) -> SearchTabsItem {
        SearchTabsItem(
            id: entry.id,
            source: .native,
            kind: entry.kind,
            displayMode: entry.displayMode,
            primary: entry.primary,
            secondary: entry.secondary,
            splitRelation: nil,
            state: entry.state,
            ranking: SearchTabsRankingMetadata(matchScore: match.score, matchedFields: match.matchedFields, providerOrder: entry.providerOrder),
            action: entry.action,
            secondaryAction: entry.secondaryAction
        )
    }

    private static func sort(_ lhs: SearchTabsItem, _ rhs: SearchTabsItem) -> Bool {
        if kindPriority(lhs) != kindPriority(rhs) {
            return kindPriority(lhs) < kindPriority(rhs)
        }
        if lhs.kind == .openedtab && rhs.kind == .openedtab {
            return sortOpened(lhs, rhs)
        }
        if lhs.ranking.matchScore != rhs.ranking.matchScore {
            return lhs.ranking.matchScore > rhs.ranking.matchScore
        }
        if lhs.state.isOpen != rhs.state.isOpen {
            return lhs.state.isOpen
        }
        if lhs.state.isActive != rhs.state.isActive {
            return lhs.state.isActive
        }
        if lhs.state.lastSeen != rhs.state.lastSeen {
            return (lhs.state.lastSeen ?? .distantPast) > (rhs.state.lastSeen ?? .distantPast)
        }
        if lhs.state.lastActiveElapsedMs != rhs.state.lastActiveElapsedMs {
            return (lhs.state.lastActiveElapsedMs ?? Int64.max) < (rhs.state.lastActiveElapsedMs ?? Int64.max)
        }
        return lhs.ranking.providerOrder < rhs.ranking.providerOrder
    }

    private static func sortOpened(_ lhs: SearchTabsItem, _ rhs: SearchTabsItem) -> Bool {
        if lhs.state.isHostWindow != rhs.state.isHostWindow {
            return lhs.state.isHostWindow
        }
        if lhs.state.isActive != rhs.state.isActive {
            return lhs.state.isActive
        }
        if lhs.state.lastActiveElapsedMs != rhs.state.lastActiveElapsedMs {
            return (lhs.state.lastActiveElapsedMs ?? Int64.max) < (rhs.state.lastActiveElapsedMs ?? Int64.max)
        }
        if lhs.primary.windowId != rhs.primary.windowId {
            return (lhs.primary.windowId ?? Int.max) < (rhs.primary.windowId ?? Int.max)
        }
        return lhs.ranking.providerOrder < rhs.ranking.providerOrder
    }

    private static func kindPriority(_ item: SearchTabsItem) -> Int {
        switch item.kind {
        case .openedtab:
            return 0
        case .pin, .bookmark where item.state.isOpen:
            return 1
        case .pin:
            return 2
        case .bookmark:
            return 3
        case .bookmarkRoot:
            return 4
        case .closedtab:
            return 5
        }
    }
}
```

- [ ] **Step 4: Add `SearchTabsDataController.swift`**

Create:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@MainActor
final class SearchTabsDataController {
    private weak var browserState: BrowserState?
    private let chromiumProvider: SearchTabsChromiumProvider

    init(
        browserState: BrowserState,
        chromiumProvider: SearchTabsChromiumProvider = SearchTabsChromiumProvider()
    ) {
        self.browserState = browserState
        self.chromiumProvider = chromiumProvider
    }

    func snapshot(query: String) -> SearchTabsSnapshot {
        guard let state = browserState else {
            return SearchTabsSnapshot(query: query, profileId: LocalStore.defaultProfileId, windowId: 0, generatedAt: Date(), items: [])
        }
        let normalized = SearchTabsQueryMatcher.normalizedQuery(query)
        let chromium = chromiumProvider.snapshot(windowId: state.windowId)
        let native = SearchTabsNativeProvider(browserState: state).snapshot(includeBookmarkRoot: normalized.isEmpty)
        return SearchTabsAggregator.aggregate(
            query: query,
            profileId: state.profileId,
            windowId: state.windowId,
            chromium: chromium,
            native: native
        )
    }
}
```

- [ ] **Step 5: Add aggregator/controller files to the project**

Add both new files to the `SearchTabs` PBX group and app target source build phase.

In the `PBXBuildFile` section, add:

```text
5EA17ABC0000000000000104 /* SearchTabsAggregator.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5EA17ABC0000000000000114 /* SearchTabsAggregator.swift */; };
5EA17ABC0000000000000105 /* SearchTabsDataController.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5EA17ABC0000000000000115 /* SearchTabsDataController.swift */; };
```

In the `PBXFileReference` section, add:

```text
5EA17ABC0000000000000114 /* SearchTabsAggregator.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SearchTabsAggregator.swift; sourceTree = "<group>"; };
5EA17ABC0000000000000115 /* SearchTabsDataController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SearchTabsDataController.swift; sourceTree = "<group>"; };
```

In the `5EA17ABC0000000000000120 /* SearchTabs */` group children, add:

```text
5EA17ABC0000000000000114 /* SearchTabsAggregator.swift */,
5EA17ABC0000000000000115 /* SearchTabsDataController.swift */,
```

In the app target `PBXSourcesBuildPhase` children, add:

```text
5EA17ABC0000000000000104 /* SearchTabsAggregator.swift in Sources */,
5EA17ABC0000000000000105 /* SearchTabsDataController.swift in Sources */,
```

- [ ] **Step 6: Run tests for Task 4**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: `SearchTabsDataTests` passes.

## Task 5: Add Split Relation Enrichment And Final Verification

**Files:**
- Modify: `Sources/UserInterface/SearchTabs/SearchTabsAggregator.swift`
- Modify: `Sources/UserInterface/SearchTabs/SearchTabsDataController.swift`
- Modify: `Tests/PhiBrowserTests/SearchTabsDataTests.swift`

- [ ] **Step 1: Add failing live split relation test**

Append to `SearchTabsDataTests`:

```swift
    func testDataControllerAddsSplitRelationForLiveOpenedSplitPane() throws {
        let state = try makeSearchTabsState(isIncognito: false)
        let primary = Tab(guid: 50, url: "https://mail.example", isActive: true, index: 0, title: "Mail")
        let secondary = Tab(guid: 51, url: "https://calendar.example", isActive: false, index: 1, title: "Calendar")
        state.tabs = [primary, secondary]
        state.splits = [
            SplitGroup(id: "split-50-51", primaryTabId: 50, secondaryTabId: 51, layout: .vertical, ratio: 0.5)
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
                        "active": true,
                        "pinned": false,
                        "split": true,
                        "hostWindow": true,
                        "lastActiveElapsedMs": 1,
                        "lastActiveElapsedText": "now",
                    ],
                ],
                "recentlyClosedTabs": [],
            ]
        })
        let controller = SearchTabsDataController(browserState: state, chromiumProvider: chromium)

        let item = controller.snapshot(query: "").items.first

        XCTAssertEqual(item?.splitRelation?.splitId, "split-50-51")
        XCTAssertEqual(item?.splitRelation?.role, .primary)
        XCTAssertEqual(item?.splitRelation?.partnerTabId, 51)
        XCTAssertEqual(item?.splitRelation?.partnerTitle, "Calendar")
    }

    private func makeSearchTabsState(isIncognito: Bool = false) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default", isIncognito: isIncognito)
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: fail because open-tab split relation is still nil.

- [ ] **Step 3: Add split relation enrichment**

Update `SearchTabsAggregator.aggregate` to accept an optional split-relation resolver:

```swift
static func aggregate(
    query: String,
    profileId: String,
    windowId: Int,
    chromium: SearchTabsChromiumSnapshot,
    native: SearchTabsNativeSnapshot,
    generatedAt: Date = Date(),
    splitRelation: (Int) -> SearchTabsSplitRelation? = { _ in nil }
) -> SearchTabsSnapshot
```

Update the open-tab append block:

```swift
items.append(contentsOf: chromium.openTabs.enumerated().compactMap { index, tab in
    makeOpenTabItem(
        tab,
        providerOrder: index,
        query: normalizedQuery,
        includeWhenQueryIsEmpty: isEmptyQuery,
        splitRelation: splitRelation(tab.tabId)
    )
})
```

Update `makeOpenTabItem` signature and assigned field:

```swift
private static func makeOpenTabItem(
    _ tab: ChromiumSearchOpenTab,
    providerOrder: Int,
    query: String,
    includeWhenQueryIsEmpty: Bool,
    splitRelation: SearchTabsSplitRelation?
) -> SearchTabsItem?
```

Inside the returned `SearchTabsItem`, set:

```swift
splitRelation: splitRelation,
```

Update `SearchTabsDataController.snapshot(query:)` to pass a resolver:

```swift
return SearchTabsAggregator.aggregate(
    query: query,
    profileId: state.profileId,
    windowId: state.windowId,
    chromium: chromium,
    native: native,
    splitRelation: { [weak state] tabId in
        guard let state,
              let group = state.splitGroup(forTabId: tabId),
              let partnerId = group.partnerTabId(of: tabId),
              let partner = state.tabs.first(where: { $0.guid == partnerId }) else {
            return nil
        }
        return SearchTabsSplitRelation(
            splitId: group.id,
            layout: group.layout,
            role: group.primaryTabId == tabId ? .primary : .secondary,
            partnerTabId: partnerId,
            partnerTitle: partner.title,
            partnerURL: partner.url
        )
    }
)
```

- [ ] **Step 4: Run targeted tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/SearchTabsDataTests
```

Expected: `SearchTabsDataTests` passes.

- [ ] **Step 5: Run focused build-for-testing**

Run:

```bash
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS'
```

Expected: build succeeds. If environment signing blocks the test bundle, record the exact error and keep the successful compile/test evidence from the earlier targeted command.

- [ ] **Step 6: Inspect final diff**

Run:

```bash
git diff --check
git status --short
```

Expected: `git diff --check` produces no whitespace errors. `git status --short` shows only the planned search-tabs files, the spec/plan docs, the bridge header if it needed declarations, and `Phi.xcodeproj/project.pbxproj`.

## Self-Review Checklist

- Spec coverage:
  - Typed UI-ready result model: Task 1.
  - Query matching and scoring: Task 1.
  - Chromium provider parsing: Task 2.
  - Native provider for pins/bookmarks/bookmark root: Task 3.
  - Empty-query bookmark root behavior: Task 4.
  - Non-empty bookmark leaf search: Task 4.
  - Opened tab priority and duplicate native entries: Task 4.
  - Split native item shaping: Task 3.
  - Live open split relation metadata: Task 5.
  - Incognito native exclusion: Task 3.
  - Verification: Task 5.
- Placeholder scan:
  - Every implementation task names concrete files, commands, and code snippets.
  - The only conditional path is bridge declaration addition, guarded by current checkout state.
- Type consistency:
  - Model names are introduced in Task 1 before provider and aggregator tasks use them.
  - Provider snapshot names match the aggregator signatures.
  - Action targets match the approved spec.
