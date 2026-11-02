// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Binds tabs to live folder rows through a URL-derived marker in `guidInLocalDB`, as bookmarks do with their guid.
extension BrowserState {
    /// True only while the row exists, or a tab restored after its folder was deleted would vanish.
    func isLiveFolderTab(_ tab: Tab) -> Bool {
        guard let guid = tab.guidInLocalDB else { return false }
        return liveFolderTabMarkers.contains(guid)
    }

    func liveFolderTab(for row: LiveFolderRow) -> Tab? {
        tabs.first { $0.guidInLocalDB == row.tabMarker }
    }

    @MainActor
    func openLiveFolderRow(_ row: LiveFolderRow) {
        clearGroupOverview()
        clearMultiSelection()
        LiveFolderManager.shared.markRead(url: row.url, inSpace: spaceId)
        if let tab = liveFolderTab(for: row), let wrapper = tab.webContentWrapper {
            wrapper.setAsActiveTab()
            focuseTab(tab)
        } else {
            createTab(row.url, customGuid: row.tabMarker, focusAfterCreate: true)
        }
    }

    @MainActor
    func removeLiveFolderRow(_ row: LiveFolderRow) {
        let tab = liveFolderTab(for: row)
        LiveFolderManager.shared.hideRow(url: row.url, inSpace: spaceId)
        tab?.close()
    }

    @MainActor
    func deleteLiveFolder() {
        for tab in tabs where LiveFolderRow.isTabMarker(tab.guidInLocalDB) {
            tab.guidInLocalDB = nil
            tab.webContentWrapper?.updateTabCustomValue("")
        }
        LiveFolderManager.shared.deleteFolder(inSpace: spaceId)
    }

    func updateLiveFolderTabMarkers(_ markers: Set<String>) {
        guard markers != liveFolderTabMarkers else { return }
        liveFolderTabMarkers = markers
        updateNormalTabs()
    }
}
