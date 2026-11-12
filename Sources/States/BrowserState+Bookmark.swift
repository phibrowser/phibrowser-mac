// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

private typealias BookmarkOriginNavigationContext = (
    currentURL: String,
    originalURL: String,
    wrapper: WebContentWrapper & NSObject
)

/// The bookmark row fields for a split's panes in slot order: the first two
/// are the row's URLs, any others its extra panes. A pane's title is dropped
/// when it only repeats the first pane's (common for panes of the same page),
/// so the bookmark bar label stays compact.
struct SplitBookmarkFields {
    let url: String
    let title: String
    let secondaryUrl: String
    let secondaryTitle: String?
    let extraPanes: [SplitBookmarkExtraPane]

    /// Nil unless there are two to four panes and each has a URL.
    init?(panes: [(url: String?, title: String)]) {
        guard (2...SplitGroup.maxPaneCount).contains(panes.count) else { return nil }
        let urls = panes.compactMap { $0.url?.isEmpty == false ? $0.url : nil }
        guard urls.count == panes.count else { return nil }
        let primaryTitle = panes[0].title
        func displayTitle(_ title: String) -> String? {
            title == primaryTitle || title.isEmpty ? nil : title
        }
        url = URLProcessor.processUserInput(urls[0])
        title = primaryTitle.isEmpty ? urls[0] : primaryTitle
        secondaryUrl = URLProcessor.processUserInput(urls[1])
        secondaryTitle = displayTitle(panes[1].title)
        extraPanes = zip(urls, panes).dropFirst(2).map { url, pane in
            SplitBookmarkExtraPane(url: URLProcessor.processUserInput(url),
                                   title: displayTitle(pane.title))
        }
    }
}

extension BrowserState {
    private func syncBookmarkBinding(_ bookmark: Bookmark, with tab: Tab?, focusingTabGuid: Int?) {
        if let tab {
            if !bookmark.isOpened {
                bookmark.isOpened = true
            }
            if bookmark.chromiumTabGuid != tab.guid {
                bookmark.chromiumTabGuid = tab.guid
            }
            bookmark.setWebContentWrapper(tab.webContentWrapper)

            let isActive = (tab.guid == focusingTabGuid)
            if bookmark.isActive != isActive {
                bookmark.isActive = isActive
            }
        } else {
            if bookmark.isOpened {
                bookmark.isOpened = false
            }
            if bookmark.chromiumTabGuid != -1 {
                bookmark.chromiumTabGuid = -1
            }
            bookmark.setWebContentWrapper(nil)
            if bookmark.isActive {
                bookmark.isActive = false
            }
        }
    }

    @MainActor
    func displayNewFolderDialog(_ name: String? = nil, placeholder: String? = nil, isFolder: Bool) async -> String? {
        let alert = NSAlert()
        alert.messageText = (name?.isEmpty == true || isFolder) ? NSLocalizedString("app.bookmarkFolderDialog.createTitle", value: "New Folder", comment: "New folder dialog title")
        : NSLocalizedString("app.bookmarkFolderDialog.renameTitle", value: "Rename", comment: "Rename folder or bookmark dialog title")
        alert.alertStyle = .informational


        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        inputField.placeholderString = placeholder ?? NSLocalizedString("app.bookmarkFolderDialog.nameField.placeholder", value: "Folder Name", comment: "New folder dialog input placeholder")
        inputField.stringValue = name ?? ""
        alert.accessoryView = inputField

        alert.addButton(withTitle: NSLocalizedString("app.newBookmarkFolderDialog.confirmButton", value: "Confirm", comment: "New folder dialog confirm button title"))
        alert.addButton(withTitle: NSLocalizedString("app.newBookmarkFolderDialog.cancelButton", value: "Cancel", comment: "New folder dialog cancel button title"))

        let response: NSApplication.ModalResponse
        if let window = self.windowController?.window  {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        if response == .alertFirstButtonReturn {
            let name = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return name
        } else {
            return nil
        }
    }

    @MainActor
    func displayRenameBookmarkDialog(initialName: String) async -> String? {
        return await displayNewFolderDialog(initialName, placeholder: "", isFolder: false)
    }

    @MainActor
    func displayRenameBookmarkFolderDialog(initialName: String) async -> String? {
        return await displayNewFolderDialog(initialName, placeholder: "", isFolder: true)
    }
    
    func createDirectory(title: String,
                         parentId: String?,
                         index: Int? = nil) {
        localStore.createDirectory(title: title, profileId: profileId, parentId: parentId, spaceId: spaceId)
    }
    
    func addBookmark(url: String, title: String, parentId: String) {
        localStore.createBookmark(url: url, title: title, profileId: profileId, parentId: parentId, spaceId: spaceId)
    }

    /// If `tab` belongs to a split, save the whole split as one split-view
    /// bookmark and return true. Otherwise return false so the caller can fall
    /// back to a single-URL bookmark path.
    ///
    /// `bindLiveSplit` selects between two save semantics:
    /// - `true` (drag-to-bookmark): the live split is bound to the new bookmark
    ///   via `splitBookmarkBindings`, hiding the live panes from the normal tab
    ///   list so the bookmark cell becomes the split's opened representation —
    ///   a move (mirrors single-tab drag through `moveNormalTab`).
    /// - `false` (menu "Add Split to Bookmark/Folder" and Cmd+D): the bookmark
    ///   is an independent *copy* and the on-screen split stays open and
    ///   unbound, mirroring the single-tab menu/Cmd+D bookmark path which also
    ///   leaves the live tab in place.
    @discardableResult
    func addSplitBookmarkFromTab(_ tab: Tab,
                                 toFolder parent: Bookmark? = nil,
                                 toFolderGuid: String? = nil,
                                 targetIndex: Int? = nil,
                                 bindLiveSplit: Bool = true) -> Bool {
        // Pinned-split cells render synthetic-`guid` records; their `guid`
        // doesn't match the live SplitGroup's tab ids. Fall back to a
        // `guidInLocalDB` lookup so the context-menu actions can pass the
        // record-tab directly without each caller having to resolve.
        let resolvedTab: Tab? = {
            if splitGroup(forTabId: tab.guid) != nil { return tab }
            guard let dbGuid = tab.guidInLocalDB, !dbGuid.isEmpty else { return nil }
            return tabs.first(where: { $0.guidInLocalDB == dbGuid })
        }()
        let parentGuid = toFolderGuid ?? parent?.guid
        if let resolvedTab,
           let group = splitGroup(forTabId: resolvedTab.guid) {
            let panes = group.tabIds.compactMap { tabId in tabs.first(where: { $0.guid == tabId }) }
            guard panes.count == group.paneCount,
                  let fields = SplitBookmarkFields(panes: panes.map { (url: $0.url, title: $0.title) }) else {
                return false
            }
            let newBookmarkGuid = UUID().uuidString
            // `toFolderGuid` lets the "New Folder" flow target a folder created
            // with a pre-generated guid before its Bookmark instance has been
            // published into the tree. Falls back to `parent?.guid` for the
            // common case where the caller already holds the Bookmark.
            // Use `localStore.createBookmark` directly so we control the guid and
            // can register the bookmark→split binding immediately, before the
            // bookmark publisher republishes the tree.
            localStore.createBookmark(
                url: fields.url,
                title: fields.title,
                profileId: profileId,
                parentId: parentGuid,
                index: targetIndex,
                guid: newBookmarkGuid,
                spaceId: spaceId,
                secondaryUrl: fields.secondaryUrl,
                secondaryTitle: fields.secondaryTitle,
                splitExtraPanes: fields.extraPanes,
                layout: group.layout.rawValue,
                favicon: panes[0].liveFaviconData ?? panes[0].cachedFaviconData
            )
            // Drag binds the live split so it becomes the bookmark's opened
            // representation (a move); menu/Cmd+D leaves the split open as an
            // independent copy. Pinned splits never bind from this path — the
            // live pinned split must stay pinned and unbound (the
            // drag-from-pinned-split path `savePinnedSplitAsBookmark` handles
            // the unpin+bind case).
            if bindLiveSplit, !group.isPinned {
                splitBookmarkBindings[newBookmarkGuid] = group.id
            }
            updateNormalTabs()
            return true
        }
        // Unopened pinned split: no live SplitGroup, but the panes are
        // persisted as linked records in `pinnedTabs`. Build the bookmark
        // from each pinned record's persisted URL/title so the right-click
        // "Add Split to Bookmark / Folder" works on a cell whose panes
        // haven't been opened in this session yet.
        if let myDB = tab.guidInLocalDB, !myDB.isEmpty,
           let pinnedSelf = pinnedTabs.first(where: { $0.guidInLocalDB == myDB }),
           let dbGuids = pinnedSplitDBGuids(forPinnedTab: pinnedSelf) {
            let records = dbGuids.compactMap { db in pinnedTabs.first(where: { $0.guidInLocalDB == db }) }
            guard records.count == dbGuids.count,
                  let fields = SplitBookmarkFields(panes: records.map { (url: $0.url, title: $0.title) }) else {
                return false
            }
            localStore.createBookmark(
                url: fields.url,
                title: fields.title,
                profileId: profileId,
                parentId: parentGuid,
                index: targetIndex,
                guid: UUID().uuidString,
                spaceId: spaceId,
                secondaryUrl: fields.secondaryUrl,
                secondaryTitle: fields.secondaryTitle,
                splitExtraPanes: fields.extraPanes,
                layout: pinnedSplitLayout(dbGuids: dbGuids).rawValue,
                favicon: records[0].liveFaviconData ?? records[0].cachedFaviconData
            )
            return true
        }
        return false
    }
    
    /// Activates the existing tab for a bookmark or creates a new tab when needed.
    /// Split bookmarks consult `splitBookmarkBindings` to find the split that
    /// was opened from this bookmark — if it still exists its first pane is
    /// re-activated; otherwise a fresh split is opened and registered.
    func openBookmark(_ bookmark: Bookmark) {
        guard !bookmark.isFolder, let url = bookmark.url else { return }
        // Bookmark activation is dispatched from UI/menu paths on the main thread.
        MainActor.assumeIsolated {
            clearGroupOverview()
            clearMultiSelection()
        }

        localStore.updateLastSeen(bookmark.guid)
        if bookmark.secondaryUrl?.isEmpty == false {
            if layoutMode.isTraditional {
                detachBookmarkTabsForComfortableLayout(bookmarkGuids: [bookmark.guid])
                openURLsAsSplit(bookmark.splitPaneURLs,
                                layout: bookmark.layout ?? .vertical)
                return
            }
            if let splitId = splitBookmarkBindings[bookmark.guid],
               let group = splits.first(where: { $0.id == splitId }),
               let primaryTab = tabs.first(where: { $0.guid == group.firstTabId }),
               let wrapper = primaryTab.webContentWrapper {
                wrapper.setAsActiveTab()
                MainActor.assumeIsolated {
                    focuseTab(primaryTab)
                }
            } else {
                openURLsAsSplit(bookmark.splitPaneURLs,
                                bookmarkGuid: bookmark.guid,
                                layout: bookmark.layout ?? .vertical)
            }
            return
        }

        guard let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            createTab(url, customGuid: nil, focusAfterCreate: true)
            return
        }

        if layoutMode.isTraditional {
            detachBookmarkTabsForComfortableLayout(bookmarkGuids: [realBookmark.guid])
            createTab(URLProcessor.processUserInput(url), customGuid: nil, focusAfterCreate: true)
            return
        }

        // Verify the binding from BOTH directions before activating: the
        // bookmark side (isOpened/webContentWrapper) must agree with the
        // tab side (a live tab whose `guidInLocalDB` still points back at
        // this bookmark, and which isn't currently a pane of a split).
        // When the tab side has been cleared (e.g. a normal-tab drop onto
        // the bookmark's pane formed a split and detached the pane) the
        // bookmark-side check alone would activate the now-split pane —
        // falling through to `createTab` here opens a fresh bookmark
        // tab, which `handleBookmarkTabOpened` rebinds cleanly.
        if realBookmark.isOpened,
           let boundTab = tabs.first(where: { $0.guidInLocalDB == realBookmark.guid }),
           let wrapper = boundTab.webContentWrapper,
           splitGroup(forTabId: boundTab.guid) == nil {
            wrapper.setAsActiveTab()
            MainActor.assumeIsolated {
                focuseTab(boundTab)
            }
        } else {
            createTab(URLProcessor.processUserInput(url), customGuid: realBookmark.guid, focusAfterCreate: true)
        }
    }

    func updateBookmarkSplitLayout(bookmarkGuid: String, layout: SplitLayout) {
        bookmarkManager.updateSplitLayout(guid: bookmarkGuid, layout: layout)
        guard let splitId = splitBookmarkBindings[bookmarkGuid],
              splits.contains(where: { $0.id == splitId }) else {
            return
        }
        updateSplitLayout(splitId, layout: layout)
    }

    /// Returns one live bookmark pane to the URL stored by its bookmark.
    /// The load stays in the tab even when the return is cross-domain, and
    /// the tab's binding is not touched.
    func navigateBookmarkTabToOriginalURL(_ tab: Tab, bookmark: Bookmark) {
        guard let context = bookmarkOriginNavigationContext(for: tab, bookmark: bookmark) else {
            return
        }
        performBookmarkOriginNavigation(context)
    }

    /// Preserves a bookmark pane's current page as a normal background tab,
    /// then returns the bookmark pane to its stored URL.
    func separateBookmarkTabFromCurrentURL(_ tab: Tab, bookmark: Bookmark) {
        guard let context = bookmarkOriginNavigationContext(for: tab, bookmark: bookmark) else {
            return
        }
        createTab(context.currentURL, customGuid: nil, focusAfterCreate: false)
        performBookmarkOriginNavigation(context)
    }

    private func bookmarkOriginNavigationContext(
        for tab: Tab,
        bookmark: Bookmark
    ) -> BookmarkOriginNavigationContext? {
        guard tabs.contains(where: { $0 === tab }),
              let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            return nil
        }

        let originalURL: String?
        if let splitId = splitBookmarkBindings[realBookmark.guid],
           let group = splits.first(where: { $0.id == splitId }) {
            // The bookmark stores the URLs of slots 0 and 1; any further
            // pane of the bound split has no stored origin.
            switch group.slot(of: tab.guid) {
            case 0:
                originalURL = realBookmark.url
            case 1:
                originalURL = realBookmark.secondaryUrl
            default:
                return nil
            }
        } else {
            guard realBookmark.isOpened,
                  tab.guidInLocalDB == realBookmark.guid,
                  splitGroup(forTabId: tab.guid) == nil else {
                return nil
            }
            originalURL = realBookmark.url
        }

        guard let originalURL,
              !originalURL.isEmpty,
              let currentURL = tab.url,
              !currentURL.isEmpty,
              !URLProcessor.areEquivalentForOriginNavigation(currentURL, originalURL),
              let wrapper = tab.webContentWrapper else {
            return nil
        }

        return (
            currentURL: currentURL,
            originalURL: originalURL,
            wrapper: wrapper
        )
    }

    private func performBookmarkOriginNavigation(_ context: BookmarkOriginNavigationContext) {
        DispatchQueue.main.async {
            context.wrapper.navigateInPlace(toURL: context.originalURL)
        }
    }

    /// Mirror the split-bookmark binding state onto the bookmark's published
    /// flags so the sidebar/bookmark-bar cell reads "opened"/"active" the
    /// same way a normal bookmark does. Call after mutating
    /// `splitBookmarkBindings` or after the focused tab changes.
    func syncSplitBookmarkOpenedState(bookmarkGuid: String) {
        guard let bookmark = bookmarkManager.bookmark(withGuid: bookmarkGuid) else { return }
        let isOpened = splitBookmarkBindings[bookmarkGuid] != nil
        if bookmark.isOpened != isOpened { bookmark.isOpened = isOpened }
        // Split bookmarks don't bind a single `webContentWrapper`; clear it
        // and reset chromiumTabGuid so the normal-bookmark code paths (e.g.
        // `closeBookmark`'s wrapper lookup) don't accidentally pick a stale
        // tab. The split-aware activate/close paths read
        // `splitBookmarkBindings` directly.
        if bookmark.chromiumTabGuid != -1 { bookmark.chromiumTabGuid = -1 }
        bookmark.setWebContentWrapper(nil)
        if let splitId = splitBookmarkBindings[bookmarkGuid],
           let group = splits.first(where: { $0.id == splitId }),
           let primaryTab = tabs.first(where: { $0.guid == group.firstTabId }) {
            bookmark.setCanonicalFaviconSource(primaryTab.webContentWrapper)
        } else {
            bookmark.clearCanonicalFaviconSource()
        }
        let isActive: Bool = {
            guard let splitId = splitBookmarkBindings[bookmarkGuid],
                  let group = splits.first(where: { $0.id == splitId }),
                  let focusedId = focusingTab?.guid else { return false }
            return group.contains(tabId: focusedId)
        }()
        if bookmark.isActive != isActive { bookmark.isActive = isActive }
    }
    
    /// Closes the currently open tab(s) associated with a bookmark. For split
    /// bookmarks every pane of the bound split is closed via the binding map.
    func closeBookmark(_ bookmark: Bookmark) {
        guard let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            return
        }

        if let splitId = splitBookmarkBindings[realBookmark.guid],
           let group = splits.first(where: { $0.id == splitId }) {
            // Snapshot the tabs before closing — closing a pane can dissolve
            // the split and clear the binding, so a later lookup against
            // `group` would race with state cleanup.
            let panes = group.tabIds
                .compactMap { id in tabs.first(where: { $0.guid == id }) }
            noteBookmarkSplitClosing(group)
            panes.forEach { $0.close() }
            return
        }

        if realBookmark.isOpened, realBookmark.chromiumTabGuid != -1 {
            if let tab = tabs.first(where: { $0.guid == realBookmark.chromiumTabGuid }) {
                tab.close()
            }
        }
    }
    
    /// Marks a bookmark as opened when a tab is created for its local guid.
    func handleBookmarkTabOpened(_ tab: Tab) {
        guard let localGuid = tab.guidInLocalDB, !localGuid.isEmpty else {
            return
        }
        
        if let bookmark = bookmarkManager.bookmark(withGuid: localGuid) {
            localStore.updateLastSeen(localGuid)
            syncBookmarkBinding(bookmark, with: tab, focusingTabGuid: focusingTab?.guid)
        }
    }
    
    /// Clears bookmark-open state when its linked tab closes.
    func handleBookmarkTabClosed(_ tab: Tab) {
        guard let localGuid = tab.guidInLocalDB, !localGuid.isEmpty else {
            return
        }

        if let bookmark = bookmarkManager.bookmark(withGuid: localGuid) {
            syncBookmarkBinding(bookmark, with: nil, focusingTabGuid: focusingTab?.guid)
        }
    }
    
    /// Recomputes open-state flags for all bookmarks from the current tab list.
    func syncAllBookmarksOpenedState() {
        guard !isIncognito else { return }
        let allBookmarks = bookmarkManager.getAllBookmarks()
        let focusingTabGuid = focusingTab?.guid

        for bookmark in allBookmarks {
            guard !bookmark.isFolder else { continue }

            // Split-view bookmarks bind to a live split via
            // `splitBookmarkBindings` rather than `guidInLocalDB`; route
            // them through the split-aware sync so isOpened/isActive
            // reflect the bound split.
            if splitBookmarkBindings[bookmark.guid] != nil {
                syncSplitBookmarkOpenedState(bookmarkGuid: bookmark.guid)
                continue
            }

            if let matchedTab = tabs.first(where: { $0.guidInLocalDB == bookmark.guid }) {
                syncBookmarkBinding(bookmark, with: matchedTab, focusingTabGuid: focusingTabGuid)
            } else {
                syncBookmarkBinding(bookmark, with: nil, focusingTabGuid: focusingTabGuid)
            }
        }

        updateNormalTabs()
    }
}

@MainActor
extension BrowserState {
    func replacementURLForBookmark(guid: String) -> URL? {
        guard !isIncognito,
              let bookmark = bookmarkManager.bookmark(withGuid: guid),
              !bookmark.isFolder, (bookmark.secondaryUrl ?? "").isEmpty,
              bookmark.isOpened,
              let tab = tabs.first(where: { $0.guid == bookmark.chromiumTabGuid && $0.guidInLocalDB == guid }),
              splitGroup(forTabId: tab.guid) == nil,
              let current = tab.webContentWrapper?.urlString, !current.isEmpty,
              let url = localStore.normalizedURL(from: current),
              url.absoluteString != bookmark.url else { return nil }
        return url
    }

    func replaceSavedURLForBookmark(guid: String) {
        guard let url = replacementURLForBookmark(guid: guid) else { return }
        // The editor also navigates the attached tab; this action only saves.
        localStore.updateBookmark(guid, profileId: profileId, title: nil,
                                  url: url.absoluteString, expectedSpaceId: spaceId)
    }
}
