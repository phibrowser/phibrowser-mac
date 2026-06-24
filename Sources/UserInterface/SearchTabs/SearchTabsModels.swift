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

enum SearchTabsSectionKind: CaseIterable, Hashable {
    case openTabs
    case pinnedTabs
    case bookmarks
    case recentlyClosed

    init?(item: SearchTabsItem) {
        switch item.kind {
        case .openedtab:
            self = .openTabs
        case .pin:
            self = .pinnedTabs
        case .bookmark:
            self = .bookmarks
        case .closedtab:
            self = .recentlyClosed
        case .bookmarkRoot:
            return nil
        }
    }
}

struct SearchTabsSectionSnapshot: Equatable {
    let kind: SearchTabsSectionKind
    let items: [SearchTabsItem]
    let isCollapsed: Bool

    var visibleItems: [SearchTabsItem] {
        isCollapsed ? [] : items
    }
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

extension SearchTabsItem {
    var isClosableOpenTab: Bool {
        kind == .openedtab
            && !state.isPinnedInChromium
            && !state.isSplit
            && primary.chromiumTabId != nil
            && primary.windowId != nil
    }
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
