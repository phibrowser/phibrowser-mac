// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@MainActor
final class SearchTabsActionExecutor {
    typealias ActivateChromiumTab = (Int64, Int64) -> Bool
    typealias RestoreClosedTab = (Int64, Int64) -> Bool

    private weak var browserState: BrowserState?
    private let activateChromiumTab: ActivateChromiumTab
    private let restoreClosedTab: RestoreClosedTab

    init(browserState: BrowserState) {
        self.browserState = browserState
        self.activateChromiumTab = { tabId, windowId in
            ChromiumLauncher.sharedInstance().bridge?
                .activateSearchTab(withTabId: tabId, windowId: windowId) ?? false
        }
        self.restoreClosedTab = { sessionId, windowId in
            ChromiumLauncher.sharedInstance().bridge?
                .openRecentlyClosedSearchEntry(withSessionId: sessionId, windowId: windowId) ?? false
        }
    }

    init(
        browserState: BrowserState?,
        activateChromiumTab: @escaping ActivateChromiumTab,
        restoreClosedTab: @escaping RestoreClosedTab
    ) {
        self.browserState = browserState
        self.activateChromiumTab = activateChromiumTab
        self.restoreClosedTab = restoreClosedTab
    }

    @discardableResult
    func perform(_ action: SearchTabsActionTarget) -> Bool {
        guard let state = browserState else {
            return false
        }

        switch action {
        case let .activateChromiumTab(tabId, _):
            return activateChromiumTab(Int64(tabId), Int64(state.windowId))
        case let .restoreClosedTab(sessionId, _, _):
            return restoreClosedTab(Int64(sessionId), Int64(state.windowId))
        case let .openPinned(localGuid, preferredPaneGuid):
            return openPinned(localGuid: localGuid, preferredPaneGuid: preferredPaneGuid, in: state)
        case let .openBookmark(localGuid, _):
            guard let bookmark = state.bookmarkManager.bookmark(withGuid: localGuid) else {
                return false
            }
            state.openBookmark(bookmark)
            return true
        case .showBookmarkMenuRoot:
            return false
        }
    }

    @discardableResult
    func close(_ item: SearchTabsItem) -> Bool {
        guard item.isClosableOpenTab,
              let tabId = item.primary.chromiumTabId,
              let state = browserState(for: item.primary.windowId),
              let tab = state.tabs.first(where: { $0.guid == tabId }) else {
            return false
        }

        tab.close()
        return true
    }

    private func openPinned(localGuid: String, preferredPaneGuid: String?, in state: BrowserState) -> Bool {
        let requestedGuid = preferredPaneGuid ?? localGuid
        let requestedTab = state.pinnedTabs.first { $0.guidInLocalDB == requestedGuid }
        let fallbackTab = state.pinnedTabs.first { $0.guidInLocalDB == localGuid }

        guard let tab = requestedTab ?? fallbackTab else {
            return false
        }

        state.openOrFocusPinnedTab(tab)
        return true
    }

    private func browserState(for windowId: Int?) -> BrowserState? {
        guard let windowId else {
            return browserState
        }

        if let browserState, browserState.windowId == windowId {
            return browserState
        }

        return MainBrowserWindowControllersManager.shared.getBrowserState(for: windowId)
    }
}
