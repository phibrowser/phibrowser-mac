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
    let guid: String?
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

    private let input: Input

    init(browserState state: BrowserState) {
        self.input = Input(
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

    init(
        profileId: String,
        windowId: Int,
        isIncognito: Bool = false,
        pinnedTabs: [Tab] = [],
        bookmarks: [Bookmark] = [],
        focusingTab: Tab? = nil,
        splits: [SplitGroup] = [],
        pinnedSplitPair: @escaping (Tab) -> (String, String)? = { _ in nil }
    ) {
        self.input = Input(
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

    func snapshot(includeBookmarkRoot: Bool) -> SearchTabsNativeSnapshot {
        guard !input.isIncognito else {
            return SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        }

        let bookmarks = buildBookmarkEntries()
        return SearchTabsNativeSnapshot(
            pins: buildPinnedEntries(),
            bookmarks: bookmarks,
            bookmarkRoot: includeBookmarkRoot ? buildBookmarkRoot() : nil
        )
    }

    private func buildPinnedEntries() -> [NativeSearchEntry] {
        var consumedGuids = Set<String>()
        var entries: [NativeSearchEntry] = []

        for tab in input.pinnedTabs {
            guard let guid = tab.guidInLocalDB, !guid.isEmpty, !consumedGuids.contains(guid) else {
                continue
            }

            if let (leftGuid, rightGuid) = input.pinnedSplitPair(tab),
               let left = pinnedTab(localGuid: leftGuid),
               let right = pinnedTab(localGuid: rightGuid) {
                consumedGuids.insert(leftGuid)
                consumedGuids.insert(rightGuid)
                entries.append(buildPinnedSplitEntry(left: left, right: right, providerOrder: entries.count))
            } else {
                consumedGuids.insert(guid)
                entries.append(buildPinnedSingleEntry(tab: tab, localGuid: guid, providerOrder: entries.count))
            }
        }

        return entries
    }

    private func buildPinnedSingleEntry(tab: Tab, localGuid: String, providerOrder: Int) -> NativeSearchEntry {
        NativeSearchEntry(
            id: "pin:\(localGuid)",
            guid: localGuid,
            kind: .pin,
            displayMode: .single,
            primary: pane(forPinnedTab: tab, localGuid: localGuid),
            secondary: nil,
            state: pinnedState(tabs: [tab], isSplit: false),
            action: .openPinned(localGuid: localGuid, preferredPaneGuid: nil),
            secondaryAction: nil,
            providerOrder: providerOrder
        )
    }

    private func buildPinnedSplitEntry(left: Tab, right: Tab, providerOrder: Int) -> NativeSearchEntry {
        let leftGuid = left.guidInLocalDB ?? ""
        let rightGuid = right.guidInLocalDB ?? ""

        return NativeSearchEntry(
            id: "pin-split:\(leftGuid):\(rightGuid)",
            guid: leftGuid,
            kind: .pin,
            displayMode: .split,
            primary: pane(forPinnedTab: left, localGuid: leftGuid),
            secondary: pane(forPinnedTab: right, localGuid: rightGuid),
            state: pinnedState(tabs: [left, right], isSplit: true),
            action: .openPinned(localGuid: leftGuid, preferredPaneGuid: nil),
            secondaryAction: .openPinned(localGuid: leftGuid, preferredPaneGuid: rightGuid),
            providerOrder: providerOrder
        )
    }

    private func buildBookmarkEntries() -> [NativeSearchEntry] {
        input.bookmarks
            .filter { !$0.isFolder }
            .enumerated()
            .map { providerOrder, bookmark in
                buildBookmarkEntry(bookmark: bookmark, providerOrder: providerOrder)
            }
    }

    private func buildBookmarkEntry(bookmark: Bookmark, providerOrder: Int) -> NativeSearchEntry {
        let isSplit = bookmark.secondaryUrl?.isEmpty == false
        return NativeSearchEntry(
            id: isSplit ? "bookmark-split:\(bookmark.guid)" : "bookmark:\(bookmark.guid)",
            guid: bookmark.guid,
            kind: .bookmark,
            displayMode: isSplit ? .split : .single,
            primary: pane(forBookmark: bookmark, title: bookmark.title, url: bookmark.url),
            secondary: isSplit ? pane(forBookmark: bookmark, title: secondaryTitle(for: bookmark), url: bookmark.secondaryUrl) : nil,
            state: bookmarkState(bookmark: bookmark, isSplit: isSplit),
            action: .openBookmark(localGuid: bookmark.guid, preferredPaneGuid: nil),
            secondaryAction: isSplit ? .openBookmark(localGuid: bookmark.guid, preferredPaneGuid: bookmark.guid) : nil,
            providerOrder: providerOrder
        )
    }

    private func buildBookmarkRoot() -> NativeSearchEntry {
        NativeSearchEntry(
            id: "bookmark-root:\(input.profileId)",
            guid: nil,
            kind: .bookmarkRoot,
            displayMode: .bookmarkMenuRoot,
            primary: SearchTabsPane(
                title: "Bookmarks",
                url: nil,
                faviconData: nil,
                faviconURL: nil,
                localGuid: nil,
                chromiumTabId: nil,
                windowId: input.windowId
            ),
            secondary: nil,
            state: SearchTabsItemState(
                isOpen: false,
                isActive: false,
                isHostWindow: true,
                isPinnedInChromium: false,
                isSplit: false,
                lastSeen: nil,
                lastActiveElapsedMs: nil,
                lastActiveElapsedText: nil
            ),
            action: .showBookmarkMenuRoot(profileId: input.profileId),
            secondaryAction: nil,
            providerOrder: Int.max
        )
    }

    private func secondaryTitle(for bookmark: Bookmark) -> String {
        if let title = bookmark.secondaryTitle, !title.isEmpty {
            return title
        }
        return bookmark.secondaryUrl ?? ""
    }

    private func pinnedTab(localGuid: String) -> Tab? {
        input.pinnedTabs.first { $0.guidInLocalDB == localGuid }
    }

    private func pane(forPinnedTab tab: Tab, localGuid: String) -> SearchTabsPane {
        SearchTabsPane(
            title: tab.storedTitle ?? tab.title,
            url: tab.pinnedUrl ?? tab.url,
            faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
            faviconURL: tab.faviconUrl,
            localGuid: localGuid,
            chromiumTabId: tab.guid > 0 ? tab.guid : nil,
            windowId: input.windowId
        )
    }

    private func pane(forBookmark bookmark: Bookmark, title: String, url: String?) -> SearchTabsPane {
        SearchTabsPane(
            title: title,
            url: url,
            faviconData: bookmark.liveFaviconData ?? bookmark.cachedFaviconData,
            faviconURL: bookmark.faviconUrl,
            localGuid: bookmark.guid,
            chromiumTabId: bookmark.chromiumTabGuid > 0 ? bookmark.chromiumTabGuid : nil,
            windowId: input.windowId
        )
    }

    private func pinnedState(tabs: [Tab], isSplit: Bool) -> SearchTabsItemState {
        SearchTabsItemState(
            isOpen: tabs.contains { $0.isOpenned },
            isActive: tabs.contains(where: isFocused),
            isHostWindow: true,
            isPinnedInChromium: tabs.contains { $0.isPinned },
            isSplit: isSplit,
            lastSeen: tabs.compactMap(\.lastSeen).max(),
            lastActiveElapsedMs: nil,
            lastActiveElapsedText: nil
        )
    }

    private func bookmarkState(bookmark: Bookmark, isSplit: Bool) -> SearchTabsItemState {
        SearchTabsItemState(
            isOpen: bookmark.isOpened,
            isActive: bookmark.isActive,
            isHostWindow: true,
            isPinnedInChromium: false,
            isSplit: isSplit,
            lastSeen: bookmark.lastSeen,
            lastActiveElapsedMs: nil,
            lastActiveElapsedText: nil
        )
    }

    private func isFocused(tab: Tab) -> Bool {
        guard let focusingTab = input.focusingTab else { return false }
        if let localGuid = tab.guidInLocalDB,
           let focusingLocalGuid = focusingTab.guidInLocalDB,
           localGuid == focusingLocalGuid {
            return true
        }
        return tab.guid > 0 && tab.guid == focusingTab.guid
    }
}
