// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

class BookmarkSectionController: NSObject {
    private let bookmarkManager: BookmarkManager
    private var cancellables = Set<AnyCancellable>()
    private var isActive = false
    
    private(set) var bookmarkItems: [SidebarItem] = []
    private(set) var expandedFolders: Set<String> = []
    private(set) var isInitialDataLoaded = false

    /// Mirrors `BookmarkManager.didApplyFirstStoreDelivery` while this
    /// section is active. Distinct from `isInitialDataLoaded`, which tracks
    /// the first NON-EMPTY tree: a profile with no bookmarks at all still
    /// gets a delivery, and consumers that must not stall forever have to key
    /// on the delivery rather than on there being rows.
    private(set) var hasAppliedFirstStoreDelivery = false

    weak var delegate: BookmarkSectionDelegate?
    
    init(browserState: BrowserState) {
        bookmarkManager = browserState.bookmarkManager
        super.init()
        refreshBookmarkItems(bookmarkManager.rootFolder, notifyDelegate: false)
    }
    
    func setActive(_ active: Bool) {
        if active {
            activateBindings()
        } else {
            deactivateBindings()
        }
    }

    private func activateBindings() {
        guard isActive == false else {
            refreshBookmarkItems(bookmarkManager.rootFolder, notifyDelegate: false)
            return
        }
        isActive = true
        cancellables.removeAll()
        bookmarkManager.$rootFolder
            .sink { [weak self] root in
                self?.refreshBookmarkItems(root, notifyDelegate: true)
            }
            .store(in: &cancellables)
        refreshBookmarkItems(bookmarkManager.rootFolder, notifyDelegate: false)
        // Subscribed LAST, after `bookmarkItems` is filled. On a
        // re-activation the delivery has usually already happened, so this
        // reports it the moment it is subscribed — and the consumer paints on
        // that report. Subscribing earlier would have it paint an outline
        // whose bookmark section is still the empty one `deactivateBindings`
        // left behind.
        bookmarkManager.$didApplyFirstStoreDelivery
            .filter { $0 }
            .prefix(1)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hasAppliedFirstStoreDelivery = true
                self.delegate?.bookmarkSectionDidApplyFirstStoreDelivery()
            }
            .store(in: &cancellables)
    }

    private func deactivateBindings() {
        guard isActive else { return }
        isActive = false
        cancellables.removeAll()
        bookmarkItems = []
        expandedFolders.removeAll()
        isInitialDataLoaded = false
        hasAppliedFirstStoreDelivery = false
    }

    private func refreshBookmarkItems(_ root: Bookmark, notifyDelegate: Bool) {
        bookmarkItems = root.children
        let isFirstLoad = !isInitialDataLoaded && !bookmarkItems.isEmpty
        if isFirstLoad {
            isInitialDataLoaded = true
        }
        if notifyDelegate {
            delegate?.bookmarkSectionDidUpdate()
        }
        if notifyDelegate && isFirstLoad {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.bookmarkSectionInitialDataDidLoad()
            }
        }
    }
    
    func addBookmarkFromTab(_ tab: Tab, to folder: Bookmark? = nil, index: Int?) {
        guard let url = tab.url else { return }
        
        let title = tab.title.count > 0 ? tab.title : url
        let targetFolder = folder ?? bookmarkManager.rootFolder
        
        bookmarkManager.addBookmark(title: title,
                                    url: url,
                                    to: targetFolder,
                                    targetIndex: index,
                                    faviconData: tab.liveFaviconData ?? tab.cachedFaviconData)
    }
    
    func deleteBookmark(_ bookmark: Bookmark) {
        bookmarkManager.removeBookmark(bookmark)
    }
    
    func moveBookmark(_ bookmark: Bookmark, to newParent: Bookmark, at index: Int? = nil) {
        bookmarkManager.moveBookmark(bookmark, to: newParent, at: index)
    }
    
    func createFolder(title: String, in parent: Bookmark? = nil) {
        bookmarkManager.addFolder(title: title, to: parent)
    }
    
    // MARK: - Query
    
    /// Look up a bookmark sidebar item by GUID.
    func sidebarItem(withGuid guid: String) -> SidebarItem? {
        return bookmarkManager.bookmark(withGuid: guid)
    }
    
    // MARK: - Drag and Drop Support
    
    func canAcceptDrop(of item: Any, to target: Bookmark?) -> Bool {
        if let _ = item as? Tab {
            return true // Tabs can always be dropped to create bookmarks
        }
        
        if let bookmark = item as? Bookmark {
            if target == nil {
                return true
            }
            
            guard let target = target, target.isFolder else {
                return false
            }
            
            if bookmark == target {
                return false
            }
            
            // Only folders need cycle detection.
            if bookmark.isFolder && isDescendant(target, of: bookmark) {
                return false
            }
            
            return true
        }
        
        return false
    }
    
    /// Return whether `potentialDescendant` is a descendant of `ancestor`.
    private func isDescendant(_ potentialDescendant: Bookmark, of ancestor: Bookmark) -> Bool {
        var current = potentialDescendant.parent
        while current != nil {
            if current == ancestor {
                return true
            }
            current = current?.parent
        }
        return false
    }
    
    func handleDrop(of item: Any, to target: Bookmark?, at index: Int?) -> Bool {
        let state = SpaceSessionControllersManager.shared.activeWindowController?.browserState

        if let tab = item as? Tab {
            // Split-pair tabs become one split-view bookmark; the original
            // split keeps running because `addSplitBookmarkFromTab` does not
            // rebind either tab. Single tabs fall through to the migrating
            // `moveNormalTab` path, which converts the tab in place.
            if state?.addSplitBookmarkFromTab(tab, toFolder: target, targetIndex: index) == true {
                return true
            }
            state?.moveNormalTab(tabId: tab.guid, toBookmark: target?.guid, index: index ?? 0)
            return true
        }
        
        if let bookmark = item as? Bookmark {
            let targetFolder = target ?? bookmarkManager.rootFolder
            let sourceFolder = bookmark.parent ?? bookmarkManager.rootFolder
            
            guard targetFolder.isFolder, bookmark != targetFolder else {
                return false
            }
            
            if bookmark.isFolder && isDescendant(targetFolder, of: bookmark) {
                return false
            }
            
            var normalizedIndex = index
            if var destinationIndex = normalizedIndex,
               sourceFolder.guid == targetFolder.guid,
               let sourceIndex = sourceFolder.children.firstIndex(where: { $0.guid == bookmark.guid }) {
                // NSOutlineView gives destination index in pre-removal coordinates.
                // When moving downward within the same folder, convert it to post-removal coordinates.
                if sourceIndex < destinationIndex {
                    destinationIndex -= 1
                }
                if sourceIndex == destinationIndex {
                    return false
                }
                normalizedIndex = destinationIndex
            }
            
            moveBookmark(bookmark, to: targetFolder, at: normalizedIndex)
            return true
        }
        
        return false
    }
}

protocol BookmarkSectionDelegate: AnyObject {
    func bookmarkSectionDidUpdate()
    /// The first NON-EMPTY bookmark tree has been built. Kept separate from
    /// the delivery signal below because the outline's autosave name may only
    /// be assigned once there are rows to expand — assigning it against an
    /// empty outline would persist an empty expanded-item set over the user's
    /// saved one.
    func bookmarkSectionInitialDataDidLoad()
    /// The store's FIRST payload for this window has been applied — an empty
    /// one included, and immediately for windows that never subscribe. Fires
    /// exactly once per activation, after the payload has re-projected the
    /// window's tab list.
    func bookmarkSectionDidApplyFirstStoreDelivery()
}
