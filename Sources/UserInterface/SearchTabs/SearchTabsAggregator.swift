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
        generatedAt: Date = Date(),
        splitRelation: (Int) -> SearchTabsSplitRelation? = { _ in nil }
    ) -> SearchTabsSnapshot {
        let normalizedQuery = SearchTabsQueryMatcher.normalizedQuery(query)
        let isEmptyQuery = normalizedQuery.isEmpty

        let openItems = chromium.openTabs.compactMap { tab in
            makeOpenItem(
                tab: tab,
                normalizedQuery: normalizedQuery,
                splitRelation: splitRelation
            )
        }
        let nativeItems = makeNativeItems(native: native, normalizedQuery: normalizedQuery)
        let closedItems = chromium.closedTabs.compactMap { tab in
            makeClosedItem(tab: tab, normalizedQuery: normalizedQuery)
        }

        let items = (openItems + nativeItems + closedItems)
            .filter { item in shouldInclude(item: item, isEmptyQuery: isEmptyQuery) }
            .sorted(by: sort)

        return SearchTabsSnapshot(
            query: query,
            profileId: profileId,
            windowId: windowId,
            generatedAt: generatedAt,
            items: items
        )
    }

    private static func makeOpenItem(
        tab: ChromiumSearchOpenTab,
        normalizedQuery: String,
        splitRelation: (Int) -> SearchTabsSplitRelation?
    ) -> SearchTabsItem? {
        guard let tabId = intValue(tab.tabId),
              let windowId = intValue(tab.windowId) else {
            return nil
        }
        guard let match = match(
            normalizedQuery: normalizedQuery,
            primaryTitle: tab.title,
            primaryURL: tab.url,
            secondaryTitle: nil,
            secondaryURL: nil
        ) else {
            return nil
        }

        let pane = SearchTabsPane(
            title: tab.title,
            url: tab.url,
            faviconData: nil,
            faviconURL: nil,
            localGuid: nil,
            chromiumTabId: tabId,
            windowId: windowId
        )
        return SearchTabsItem(
            id: "openedtab:\(tab.windowId):\(tab.tabId)",
            source: .chromium,
            kind: .openedtab,
            displayMode: .single,
            primary: pane,
            secondary: nil,
            splitRelation: splitRelation(tabId),
            state: SearchTabsItemState(
                isOpen: true,
                isActive: tab.active,
                isHostWindow: tab.hostWindow,
                isPinnedInChromium: tab.pinned,
                isSplit: tab.split,
                lastSeen: nil,
                lastActiveElapsedMs: tab.lastActiveElapsedMs,
                lastActiveElapsedText: tab.lastActiveElapsedText
            ),
            ranking: SearchTabsRankingMetadata(
                matchScore: match.score,
                matchedFields: match.matchedFields,
                providerOrder: tab.index
            ),
            action: .activateChromiumTab(tabId: tabId, windowId: windowId),
            secondaryAction: nil
        )
    }

    private static func makeClosedItem(
        tab: ChromiumSearchClosedTab,
        normalizedQuery: String
    ) -> SearchTabsItem? {
        guard let sessionId = intValue(tab.sessionId),
              let sourceEntrySessionId = intValue(tab.sourceEntrySessionId) else {
            return nil
        }
        guard let match = match(
            normalizedQuery: normalizedQuery,
            primaryTitle: tab.title,
            primaryURL: tab.url,
            secondaryTitle: nil,
            secondaryURL: nil
        ) else {
            return nil
        }

        return SearchTabsItem(
            id: "closedtab:\(tab.sessionId)",
            source: .chromium,
            kind: .closedtab,
            displayMode: .single,
            primary: SearchTabsPane(
                title: tab.title,
                url: tab.url,
                faviconData: nil,
                faviconURL: nil,
                localGuid: nil,
                chromiumTabId: nil,
                windowId: nil
            ),
            secondary: nil,
            splitRelation: nil,
            state: SearchTabsItemState(
                isOpen: false,
                isActive: false,
                isHostWindow: false,
                isPinnedInChromium: false,
                isSplit: false,
                lastSeen: Date(timeIntervalSince1970: TimeInterval(tab.lastActiveTimeMs) / 1_000),
                lastActiveElapsedMs: tab.lastActiveElapsedMs,
                lastActiveElapsedText: tab.lastActiveElapsedText
            ),
            ranking: SearchTabsRankingMetadata(
                matchScore: match.score,
                matchedFields: match.matchedFields,
                providerOrder: tab.providerOrder
            ),
            action: .restoreClosedTab(
                sessionId: sessionId,
                sourceEntrySessionId: sourceEntrySessionId,
                sourceEntryType: tab.sourceEntryType
            ),
            secondaryAction: nil
        )
    }

    private static func makeNativeItems(
        native: SearchTabsNativeSnapshot,
        normalizedQuery: String
    ) -> [SearchTabsItem] {
        let entries = native.pins + native.bookmarks + [native.bookmarkRoot].compactMap { $0 }
        return entries.compactMap { entry in
            guard let match = match(
                normalizedQuery: normalizedQuery,
                primaryTitle: entry.primary.title,
                primaryURL: entry.primary.url,
                secondaryTitle: entry.secondary?.title,
                secondaryURL: entry.secondary?.url
            ) else {
                return nil
            }
            return SearchTabsItem(
                id: entry.id,
                source: .native,
                kind: entry.kind,
                displayMode: entry.displayMode,
                primary: entry.primary,
                secondary: entry.secondary,
                splitRelation: nil,
                state: entry.state,
                ranking: SearchTabsRankingMetadata(
                    matchScore: match.score,
                    matchedFields: match.matchedFields,
                    providerOrder: entry.providerOrder
                ),
                action: entry.action,
                secondaryAction: entry.secondaryAction
            )
        }
    }

    private static func match(
        normalizedQuery: String,
        primaryTitle: String,
        primaryURL: String?,
        secondaryTitle: String?,
        secondaryURL: String?
    ) -> SearchTabsMatch? {
        if normalizedQuery.isEmpty {
            return SearchTabsMatch(score: 0, matchedFields: [])
        }
        return SearchTabsQueryMatcher.match(
            query: normalizedQuery,
            primaryTitle: primaryTitle,
            primaryURL: primaryURL,
            secondaryTitle: secondaryTitle,
            secondaryURL: secondaryURL
        )
    }

    private static func shouldInclude(item: SearchTabsItem, isEmptyQuery: Bool) -> Bool {
        guard isEmptyQuery else {
            return item.kind != .bookmarkRoot
        }

        switch item.kind {
        case .openedtab:
            return true
        case .closedtab:
            return true
        case .pin:
            return false
        case .bookmark:
            return false
        case .bookmarkRoot:
            return false
        }
    }

    private static func sort(_ lhs: SearchTabsItem, _ rhs: SearchTabsItem) -> Bool {
        if lhs.kind == .openedtab && rhs.kind == .openedtab {
            return sortOpened(lhs, rhs)
        }
        if lhs.kind == .openedtab || rhs.kind == .openedtab {
            return lhs.kind == .openedtab
        }

        let lhsPriority = kindPriority(lhs)
        let rhsPriority = kindPriority(rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if lhs.ranking.matchScore != rhs.ranking.matchScore {
            return lhs.ranking.matchScore > rhs.ranking.matchScore
        }
        if lhs.kind == .closedtab && rhs.kind == .closedtab {
            return sortClosed(lhs, rhs)
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
        if lhs.ranking.providerOrder != rhs.ranking.providerOrder {
            return lhs.ranking.providerOrder < rhs.ranking.providerOrder
        }
        return lhs.id < rhs.id
    }

    private static func sortClosed(_ lhs: SearchTabsItem, _ rhs: SearchTabsItem) -> Bool {
        if lhs.state.lastActiveElapsedMs != rhs.state.lastActiveElapsedMs {
            return (lhs.state.lastActiveElapsedMs ?? Int64.max) < (rhs.state.lastActiveElapsedMs ?? Int64.max)
        }
        if lhs.state.lastSeen != rhs.state.lastSeen {
            return (lhs.state.lastSeen ?? .distantPast) > (rhs.state.lastSeen ?? .distantPast)
        }
        if lhs.ranking.providerOrder != rhs.ranking.providerOrder {
            return lhs.ranking.providerOrder < rhs.ranking.providerOrder
        }
        return lhs.id < rhs.id
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
        if lhs.ranking.providerOrder != rhs.ranking.providerOrder {
            return lhs.ranking.providerOrder < rhs.ranking.providerOrder
        }
        return lhs.id < rhs.id
    }

    private static func kindPriority(_ item: SearchTabsItem) -> Int {
        switch item.kind {
        case .openedtab:
            return 0
        case .pin:
            return item.state.isOpen ? 1 : 2
        case .bookmark:
            return item.state.isOpen ? 1 : 3
        case .bookmarkRoot:
            return 4
        case .closedtab:
            return 5
        }
    }

    private static func intValue(_ value: Int64) -> Int? {
        guard value >= Int64(Int.min), value <= Int64(Int.max) else {
            return nil
        }
        return Int(value)
    }
}
