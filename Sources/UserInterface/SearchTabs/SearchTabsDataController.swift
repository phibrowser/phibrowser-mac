// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@MainActor
final class SearchTabsDataController {
    private weak var browserState: BrowserState?
    private let chromiumProvider: SearchTabsChromiumProvider

    init(browserState: BrowserState) {
        self.browserState = browserState
        self.chromiumProvider = SearchTabsChromiumProvider()
    }

    init(browserState: BrowserState, chromiumProvider: SearchTabsChromiumProvider) {
        self.browserState = browserState
        self.chromiumProvider = chromiumProvider
    }

    init(browserState: BrowserState?, chromiumProvider: SearchTabsChromiumProvider) {
        self.browserState = browserState
        self.chromiumProvider = chromiumProvider
    }

    func snapshot(query: String) -> SearchTabsSnapshot {
        guard let state = browserState else {
            return SearchTabsSnapshot(
                query: query,
                profileId: LocalStore.defaultProfileId,
                windowId: 0,
                generatedAt: Date(),
                items: []
            )
        }

        let nativeProvider = SearchTabsNativeProvider(browserState: state)
        return SearchTabsAggregator.aggregate(
            query: query,
            profileId: state.profileId,
            windowId: state.windowId,
            chromium: chromiumProvider.snapshot(windowId: state.windowId),
            native: nativeProvider.snapshot(includeBookmarkRoot: false),
            splitRelation: { tabId in
                Self.splitRelation(for: tabId, in: state)
            }
        )
    }

    private static func splitRelation(for tabId: Int, in state: BrowserState) -> SearchTabsSplitRelation? {
        guard let group = state.splitGroup(forTabId: tabId),
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
}
