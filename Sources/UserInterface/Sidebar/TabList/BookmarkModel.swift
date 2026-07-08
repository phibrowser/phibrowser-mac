// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

class Bookmark: WebContentRepresentable {
    let guid: String
    let profileId: String?
    @Published var title: String
    @Published var url: String?
    /// Second URL for a split-view bookmark. Non-nil means clicking the
    /// bookmark opens both URLs as a split. Mirrors `TabDataModel.secondaryUrl`.
    @Published var secondaryUrl: String?
    /// Display title for the secondary URL of a split-view bookmark. Optional
    /// even when `secondaryUrl` is set — callers fall back to the secondary
    /// URL's host when this is nil/empty.
    @Published var secondaryTitle: String?
    @Published var faviconUrl: String?
    @Published private(set) var cachedFaviconData: Data?
    @Published private(set) var liveFaviconData: Data?
    /// Whether this bookmark matches the currently focused tab.
    @Published var isActive: Bool = false
    /// Whether the folder is expanded in the UI.
    @Published var isExpanded: Bool = false
    /// Whether the bookmark is currently in inline-edit mode.
    @Published var isEditing: Bool = false
    @Published var lastSeen: Date?
    /// Persisted creation/modification times, mirroring `TabDataModel`.
    /// Not published — only read by the Netscape HTML export
    /// (ADD_DATE / LAST_MODIFIED), never rendered.
    var createdDate: Date?
    var updatedDate: Date?

    let isFolder: Bool
    
    weak var parent: Bookmark?
    
    /// Whether the bookmark currently has an opened Chromium tab.
    @Published var isOpened = false
    /// Associated Chromium tab guid, or `-1` when closed.
    var chromiumTabGuid: Int = -1
    /// Associated web-content wrapper for the opened tab.
    private(set) var webContentWrapper: (WebContentWrapper & NSObject)?
    private(set) var children: [Bookmark] = []
    private var cancellables = Set<AnyCancellable>()
    private var canonicalFaviconCancellables = Set<AnyCancellable>()
    private var faviconSnapshotUpdater: ((Data) -> Void)?
    
    init(guid: String = UUID().uuidString,
         title: String,
         url: String? = nil,
         secondaryUrl: String? = nil,
         secondaryTitle: String? = nil,
         profileId: String? = nil,
         faviconData: Data? = nil,
         lastSeen: Date? = nil,
         createdDate: Date? = nil,
         updatedDate: Date? = nil,
         isFolder: Bool = false) {
        self.guid = guid
        self.profileId = profileId
        self.title = title
        self.url = url
        self.secondaryUrl = secondaryUrl
        self.secondaryTitle = secondaryTitle
        self.cachedFaviconData = faviconData
        self.lastSeen = lastSeen
        self.createdDate = createdDate
        self.updatedDate = updatedDate
        self.isFolder = isFolder
    }
    
    convenience init(title: String, url: String) {
        self.init(title: title, url: url, isFolder: false)
    }
    
    convenience init(folderTitle: String) {
        self.init(title: folderTitle, isFolder: true)
    }
    
    convenience init(title: String, children: [Bookmark]) {
        self.init(title: title, isFolder: true)
        self.children = children
    }
    
    func addChild(_ bookmark: Bookmark) {
        guard isFolder else { return }
        bookmark.parent = self
        children.append(bookmark)
    }
    
    func insertChild(_ bookmark: Bookmark, at index: Int) {
        guard isFolder else { return }
        bookmark.parent = self
        children.insert(bookmark, at: min(index, children.count))
    }
    
    func removeChild(_ bookmark: Bookmark) {
        guard isFolder else { return }
        if let index = children.firstIndex(of: bookmark) {
            children.remove(at: index)
            bookmark.parent = nil
        }
    }
    
    func moveChild(from sourceIndex: Int, to destinationIndex: Int) {
        guard isFolder, sourceIndex < children.count else { return }
        let bookmark = children.remove(at: sourceIndex)
        children.insert(bookmark, at: min(destinationIndex, children.count))
    }

    fileprivate func replaceChildren(_ newChildren: [Bookmark]) {
        guard isFolder else { return }

        let newChildGUIDs = Set(newChildren.map(\.guid))
        for child in children where !newChildGUIDs.contains(child.guid) {
            child.parent = nil
        }

        children = newChildren
        for child in children {
            child.parent = self
        }
    }
    
    var hasChildren: Bool {
        return isFolder && !children.isEmpty
    }
    
    var depth: Int {
        var count = 0
        var current = parent
        while current != nil {
            count += 1
            current = current?.parent
        }
        return count
    }
    
    /// Stores the associated web-content wrapper for an opened bookmark tab.
    func setWebContentWrapper(_ wrapper: (WebContentWrapper & NSObject)?) {
        if wrapper == nil {
            clearCanonicalFaviconSource()
        }
        if let currentWrapper = webContentWrapper, let wrapper, currentWrapper === wrapper {
            return
        }
        if webContentWrapper == nil, wrapper == nil {
            return
        }
        self.webContentWrapper = wrapper
        setupObservers(for: wrapper)
        if let wrapper {
            setCanonicalFaviconSource(wrapper)
        }
    }

    func setCanonicalFaviconSource<Wrapper: WebContentWrapper & NSObject>(_ wrapper: Wrapper?) {
        clearCanonicalFaviconSource()

        guard let wrapper else { return }

        updateCachedFaviconDataIfNeeded(wrapper.favIconData, forWrapperURL: wrapper.urlString)

        wrapper.publisher(for: \.favIconData)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak wrapper] data in
                guard let self, let wrapper else { return }
                self.updateCachedFaviconDataIfNeeded(data, forWrapperURL: wrapper.urlString)
            }
            .store(in: &canonicalFaviconCancellables)

        wrapper.publisher(for: \.urlString)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak wrapper] urlString in
                guard let self, let wrapper else { return }
                self.updateCachedFaviconDataIfNeeded(wrapper.favIconData, forWrapperURL: urlString)
            }
            .store(in: &canonicalFaviconCancellables)
    }

    func clearCanonicalFaviconSource() {
        canonicalFaviconCancellables.forEach { $0.cancel() }
        canonicalFaviconCancellables.removeAll()
    }
    
    func setFaviconSnapshotUpdater(_ updater: @escaping (Data) -> Void) {
        faviconSnapshotUpdater = updater
    }
    
    func updateCachedFaviconData(_ data: Data?, persist: Bool = true) {
        guard let data, cachedFaviconData != data else { return }
        cachedFaviconData = data
        if persist {
            faviconSnapshotUpdater?(data)
        }
    }
    
    private func setupObservers<Wrapper: WebContentWrapper & NSObject>(for wrapper: Wrapper?) {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        liveFaviconData = nil
        
        guard let wrapper else { return }
        
        wrapper.publisher(for: \.favIconURL)
            .receive(on: DispatchQueue.main)
            .assign(to: \.faviconUrl, on: self)
            .store(in: &cancellables)

        liveFaviconData = wrapper.favIconData

        wrapper.publisher(for: \.favIconData)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.liveFaviconData = data
            }
            .store(in: &cancellables)
    }

    private func updateCachedFaviconDataIfNeeded(_ data: Data?, forWrapperURL wrapperURLString: String?) {
        guard let bookmarkURLString = canonicalURLString(url),
              canonicalURLString(wrapperURLString) == bookmarkURLString else { return }
        updateCachedFaviconData(data, persist: true)
    }

    private func canonicalURLString(_ rawURLString: String?) -> String? {
        guard let rawURLString = rawURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURLString.isEmpty else {
            return nil
        }

        let processedURLString: String
        if rawURLString.hasPrefix("phi://") || URL(string: rawURLString)?.scheme == nil {
            processedURLString = URLProcessor.processUserInput(rawURLString)
        } else {
            processedURLString = rawURLString
        }
        guard var components = URLComponents(string: processedURLString) else {
            return processedURLString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        }
        return components.url?.absoluteString ?? processedURLString
    }
}

extension Bookmark: Equatable {
    static func == (lhs: Bookmark, rhs: Bookmark) -> Bool {
        return lhs.guid == rhs.guid
    }
}

extension Bookmark: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(guid)
    }
}

extension Bookmark: CustomDebugStringConvertible {
    var debugDescription: String {
        return "Bookmark: title: \(title), parent: \(parent?.title ?? ""), guid: \(guid), isFolder: \(isFolder)"
    }
}

class BookmarkManager: ObservableObject {
    @Published private(set) var rootFolder: Bookmark
    
    /// Lookup table for bookmark guid -> bookmark instance.
    private var bookmarkIndex: [String: Bookmark] = [:]
    
    /// Pending bookmark guid that should enter edit mode once UI is ready.
    private var pendingEditGuid: String?
    
    /// Expanded folder guids preserved across refreshes.
    private var expandedFolderGuids: Set<String> = []
    
    private var cancellables = Set<AnyCancellable>()
    
    private weak var browserState: BrowserState?
    
    init(with browseState: BrowserState) {
        self.browserState = browseState
        self.rootFolder = Bookmark(folderTitle: "Bookmarks")
        guard !browseState.isIncognito else { return }
        browseState.localStore.createDefaultRootDir(profileId: browseState.profileId, spaceId: browseState.spaceId)
        Task { @MainActor in
            browseState.localStore.bookmarksPublisher(profileId: browseState.profileId, spaceId: browseState.spaceId)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] bookmarkModels in
                    guard let self else { return }
                    let bookmarks = self.mappedModels(from: bookmarkModels)
                    if self.hasSameSidebarTree(as: bookmarks) {
                        self.applyNonLayoutUpdates(from: bookmarks)
                        self.browserState?.syncAllBookmarksOpenedState()
                        self.browserState?.pruneMultiSelectionBookmarks()
                        return
                    }

                    self.saveExpandedState()
                    let reusedBookmarks = self.mappedModels(from: bookmarkModels, reusingExistingBookmarks: true)
                    self.rootFolder = Bookmark(title: "Bookmarks", children: reusedBookmarks)
                    self.rebuildIndex()
                    self.browserState?.syncAllBookmarksOpenedState()
                    self.browserState?.pruneMultiSelectionBookmarks()
                }
                .store(in: &cancellables)
        }
       
    }
    
    /// Saves the set of currently expanded folders.
    private func saveExpandedState() {
        expandedFolderGuids.removeAll()
        for bookmark in getAllBookmarks() where bookmark.isFolder && bookmark.isExpanded {
            expandedFolderGuids.insert(bookmark.guid)
        }
    }
    
    /// Rebuilds the guid -> bookmark index after a refresh.
    private func rebuildIndex() {
        bookmarkIndex.removeAll()
        for bookmark in getAllBookmarks() {
            bookmarkIndex[bookmark.guid] = bookmark
            
            if bookmark.isFolder && expandedFolderGuids.contains(bookmark.guid) {
                bookmark.isExpanded = true
            }
        }
        
        if let pendingGuid = pendingEditGuid,
           let bookmark = bookmarkIndex[pendingGuid] {
            pendingEditGuid = nil
            NotificationCenter.default.post(name: .bookmarkStartEditing, object: bookmark)
        }
    }

    private func hasSameSidebarTree(as bookmarks: [Bookmark]) -> Bool {
        bookmarkTreesMatch(rootFolder.children, bookmarks)
    }

    private func bookmarkTreesMatch(_ lhs: [Bookmark], _ rhs: [Bookmark]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        for (left, right) in zip(lhs, rhs) {
            guard left.guid == right.guid,
                  left.title == right.title,
                  left.url == right.url,
                  left.secondaryUrl == right.secondaryUrl,
                  left.secondaryTitle == right.secondaryTitle,
                  left.profileId == right.profileId,
                  left.cachedFaviconData == right.cachedFaviconData,
                  left.isFolder == right.isFolder,
                  bookmarkTreesMatch(left.children, right.children) else {
                return false
            }
        }

        return true
    }

    private func applyNonLayoutUpdates(from bookmarks: [Bookmark]) {
        func traverse(_ bookmark: Bookmark) {
            if let existing = bookmarkIndex[bookmark.guid],
               existing.lastSeen != bookmark.lastSeen {
                existing.lastSeen = bookmark.lastSeen
            }
            bookmark.children.forEach(traverse)
        }

        bookmarks.forEach(traverse)
    }
    
    func updateBookmark(guid: String,
                        title: String? = nil,
                        url: String? = nil,
                        secondaryUrl: String?? = nil,
                        secondaryTitle: String?? = nil) {
        guard let profileId = browserState?.profileId else { return }
        browserState?.localStore.updateBookmark(guid,
                                                profileId: profileId,
                                                title: title,
                                                url: url,
                                                secondaryUrl: secondaryUrl,
                                                secondaryTitle: secondaryTitle)

        guard let state = browserState else { return }

        // A split-view bookmark drives its attached live split through
        // `splitBookmarkBindings` — its panes aren't bound via `guidInLocalDB`,
        // so editing either URL has to navigate the matching pane directly.
        if let splitId = state.splitBookmarkBindings[guid],
           let group = state.splits.first(where: { $0.id == splitId }) {
            let current = bookmarkIndex[guid]
            if let url,
               let newPrimary = state.localStore.normalizedURL(from: url)?.absoluteString,
               newPrimary != current?.url,
               let primaryTab = state.tabs.first(where: { $0.guid == group.primaryTabId }) {
                navigateSplitPane(primaryTab, to: newPrimary)
            }
            if let secondaryUrlOpt = secondaryUrl, let rawSecondary = secondaryUrlOpt,
               !rawSecondary.isEmpty,
               let newSecondary = state.localStore.normalizedURL(from: rawSecondary)?.absoluteString,
               newSecondary != current?.secondaryUrl,
               let secondaryTab = state.tabs.first(where: { $0.guid == group.secondaryTabId }) {
                navigateSplitPane(secondaryTab, to: newSecondary)
            }
            return
        }

        guard let url,
              let normalizedURL = state.localStore.normalizedURL(from: url)?.absoluteString else {
            return
        }

        if let currentURL = bookmarkIndex[guid]?.url, currentURL == normalizedURL {
            return
        }

        guard let tab = state.tabs.first(where: { $0.guidInLocalDB == guid }),
              let wrapper = tab.webContentWrapper else {
            return
        }

        DispatchQueue.main.async {
            wrapper.updateTabCustomValue("")
            wrapper.navigate(toURL: normalizedURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                wrapper.updateTabCustomValue(guid)
            }
        }
    }
    
    /// Navigates one pane of a bookmarked split to `url`. The pane carries a
    /// non-empty `custom_value` marker (e.g. the NTP partner minted during the
    /// open-as-split flow), which makes `CrossDomainNewTabNavigationThrottle`
    /// hijack a cross-domain change into a brand-new tab. Clear the marker
    /// before navigating and restore it once the load settles, mirroring the
    /// single-tab path above.
    private func navigateSplitPane(_ tab: Tab, to url: String) {
        guard let wrapper = tab.webContentWrapper else { return }
        let restore = tab.guidInLocalDB ?? ""
        DispatchQueue.main.async {
            wrapper.updateTabCustomValue("")
            wrapper.navigate(toURL: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                wrapper.updateTabCustomValue(restore)
            }
        }
    }

    /// O(1) lookup for a bookmark by guid.
    func bookmark(withGuid guid: String) -> Bookmark? {
        return bookmarkIndex[guid]
    }
    
    func fetchBookmarks() {
//        let wrappers = ChromiumLauncher.sharedInstance().bridge?.getAllBookmarks(withWindowId: Int64(browserState?.windowId ?? 0))
//        bookmarksChanged(with: wrappers ?? [])
    }
    
    func bookmarksChanged(with wrappers: [BookmarkWrapper]) {
//        let bookmarks = Self.mappedModels(from: wrappers)
//        rootFolder = Bookmark(title: "Bookmarks", children: bookmarks)
    }
    
//    func bookmarkInfoChanged(_ id: Int64, title: String?, url: String?, facicon favicon_url: String?) {
//        DispatchQueue.global(qos: .utility).async {
//            let allBookmarks =  self.getAllBookmarks()
//            if let target = allBookmarks.first(where: { $0.guid == "\(id)" }) {
//                DispatchQueue.main.async {
//                    if let title {
//                        target.title = title
//                    }
//                    if let url {
//                        target.url = url
//                    }
//                    if let favicon_url {
//                        target.faviconUrl = favicon_url
//                    }
//                }
//            }
//        }
//    }
    
    func addBookmark(title: String,
                     url: String,
                     to parent: Bookmark? = nil,
                     targetIndex: Int? = nil,
                     faviconData: Data? = nil) {
        addBookmark(title: title,
                    url: url,
                    toParentGuid: parent?.guid,
                    targetIndex: targetIndex,
                    faviconData: faviconData)
    }

    /// Adds a bookmark under a parent referenced by guid. Use when the parent
    /// was just created and may not yet be present in the in-memory index.
    func addBookmark(title: String,
                     url: String,
                     toParentGuid parentGuid: String?,
                     targetIndex: Int? = nil,
                     faviconData: Data? = nil) {
        guard let profileId = browserState?.profileId else { return }
        let spaceId = browserState?.spaceId ?? LocalStore.defaultSpaceId
        browserState?.localStore.createBookmark(url: url,
                                                title: title,
                                                profileId: profileId,
                                                parentId: parentGuid,
                                                index: targetIndex,
                                                spaceId: spaceId,
                                                favicon: faviconDataForNewBookmark(url: url, explicitData: faviconData))
    }

    /// Stores both panes of a split as a single bookmark. Clicking the saved
    /// bookmark later reopens the pair as a split via `BrowserState.openBookmark`.
    /// `secondaryTitle` should be the secondary pane's display title so the
    /// bookmark bar can render both names; pass nil if unknown.
    func addSplitBookmark(title: String,
                          primaryURL: String,
                          secondaryURL: String,
                          secondaryTitle: String?,
                          to parent: Bookmark? = nil,
                          targetIndex: Int? = nil,
                          primaryFaviconData: Data? = nil) {
        guard let profileId = browserState?.profileId else { return }
        let spaceId = browserState?.spaceId ?? LocalStore.defaultSpaceId
        browserState?.localStore.createBookmark(url: primaryURL,
                                                title: title,
                                                profileId: profileId,
                                                parentId: parent?.guid,
                                                index: targetIndex,
                                                spaceId: spaceId,
                                                secondaryUrl: secondaryURL,
                                                secondaryTitle: secondaryTitle,
                                                favicon: faviconDataForNewBookmark(url: primaryURL, explicitData: primaryFaviconData))
    }

    func addFolder(title: String, to parent: Bookmark? = nil) {
        guard let profileId = browserState?.profileId else { return }
        let spaceId = browserState?.spaceId ?? LocalStore.defaultSpaceId
        browserState?.localStore.createDirectory(title: title, profileId: profileId, parentId: parent?.guid, spaceId: spaceId)
    }

    /// Creates a new folder and marks it for inline editing.
    func addFolderWithEditing(title: String, to parent: Bookmark? = nil) {
        let newGuid = UUID().uuidString
        pendingEditGuid = newGuid
        guard let profileId = browserState?.profileId else { return }
        let spaceId = browserState?.spaceId ?? LocalStore.defaultSpaceId
        browserState?.localStore.createDirectory(title: title, profileId: profileId, parentId: parent?.guid, guid: newGuid, spaceId: spaceId)
    }

    /// Creates a folder and inserts the bookmark without triggering sidebar inline editing.
    func addFolderFromTabStrip(title: String,
                              to parent: Bookmark? = nil,
                              bookmarkTitle: String?,
                              bookmarkURL: String,
                              bookmarkFaviconData: Data? = nil,
                              completion: @escaping (Bool, String) -> Void) {
        let newGuid = UUID().uuidString
        guard let profileId = browserState?.profileId else { return }
        let spaceId = browserState?.spaceId ?? LocalStore.defaultSpaceId
        browserState?.localStore.createDirectoryWithBookmark(folderTitle: title,
                                                             folderGuid: newGuid,
                                                             profileId: profileId,
                                                             parentId: parent?.guid,
                                                             bookmarkTitle: bookmarkTitle,
                                                             bookmarkURL: bookmarkURL,
                                                             bookmarkFavicon: faviconDataForNewBookmark(url: bookmarkURL, explicitData: bookmarkFaviconData),
                                                             spaceId: spaceId) { success in
            completion(success, newGuid)
        }
    }

    private func faviconDataForNewBookmark(url: String, explicitData: Data?) -> Data? {
        if let explicitData { return explicitData }
        guard let state = browserState,
              let targetURL = state.localStore.normalizedURL(from: url)?.absoluteString else {
            return nil
        }

        func matches(_ tab: Tab) -> Bool {
            guard let tabURL = tab.url,
                  let normalized = state.localStore.normalizedURL(from: tabURL)?.absoluteString else {
                return false
            }
            return normalized == targetURL
        }

        if let focusingTab = state.focusingTab, matches(focusingTab) {
            return focusingTab.liveFaviconData ?? focusingTab.cachedFaviconData
        }

        return state.tabs.first(where: matches).flatMap { tab in
            tab.liveFaviconData ?? tab.cachedFaviconData
        }
    }
    
    /// Triggers inline rename mode for the given bookmark.
    func triggerRename(for bookmark: Bookmark) {
        NotificationCenter.default.post(name: .bookmarkStartEditing, object: bookmark)
    }
    
    func removeBookmark(_ bookmark: Bookmark) {
        guard let profileId = browserState?.profileId else { return }
        browserState?.closeOpenTabsForRemovedBookmark(bookmark)
        browserState?.localStore.deleteBookmark(bookmark.guid, profileId: profileId)
    }
    
    func findBookmark(byURL url: String) -> Bookmark? {
        guard let normalized = browserState?.localStore.normalizedURL(from: url)?.absoluteString else { return nil }
        return getAllBookmarks().first { !$0.isFolder && $0.url == normalized }
    }

    /// Finds an existing split-view bookmark whose primary pane matches `url`.
    /// Unlike `findBookmark(byURL:)`, this only matches bookmarks that carry a
    /// secondary URL, so a split's Cmd+D toggle won't collide with a plain
    /// single-page bookmark sharing the same primary URL.
    func findSplitBookmark(byPrimaryURL url: String) -> Bookmark? {
        guard let normalized = browserState?.localStore.normalizedURL(from: url)?.absoluteString else { return nil }
        return getAllBookmarks().first {
            !$0.isFolder && $0.url == normalized && $0.secondaryUrl?.isEmpty == false
        }
    }

    func moveBookmark(_ bookmark: Bookmark, to newParent: Bookmark, at index: Int? = nil) {
        guard let profileId = browserState?.profileId else { return }
        browserState?.localStore.moveBookmark(bookmark.guid, profileId: profileId, to: newParent.guid, newIndex: index ?? Int.max)
    }
    
    func getAllBookmarks() -> [Bookmark] {
        var allBookmarks: [Bookmark] = []
        
        func traverse(_ bookmark: Bookmark) {
            allBookmarks.append(bookmark)
            for child in bookmark.children {
                traverse(child)
            }
        }
        
        for child in rootFolder.children {
            traverse(child)
        }
        
        return allBookmarks
    }
    
    /// Returns all folders while preserving the folder-only hierarchy under the root.
    func getAllFolderWithHierarchy() -> [Bookmark] {
        func filterFolders(_ bookmark: Bookmark) -> Bookmark? {
            guard bookmark.isFolder else { return nil }
            
            let folderChildren = bookmark.children.compactMap { filterFolders($0) }
            let newFolder = Bookmark(guid: bookmark.guid, title: bookmark.title, isFolder: true)
            for child in folderChildren {
                newFolder.addChild(child)
            }
            return newFolder
        }
        
        return rootFolder.children.compactMap { filterFolders($0) }
    }
}

extension BookmarkManager {
    func mappedModels(from models: [TabDataModel], reusingExistingBookmarks: Bool = false) -> [Bookmark] {
        let bookmarkModels = models.filter { $0.dataType == .bookmark || $0.dataType == .bookmarkFolder }
        guard !bookmarkModels.isEmpty else { return [] }
        
        let sortedModels = bookmarkModels.sorted { lhs, rhs in
            let lhsParent = lhs.parent?.guid ?? ""
            let rhsParent = rhs.parent?.guid ?? ""
            if lhsParent != rhsParent {
                return lhsParent < rhsParent
            }
            return lhs.index < rhs.index
        }
        
        var bookmarkMap: [String: Bookmark] = [:]
        for model in sortedModels {
            let bookmark = reusableBookmark(for: model, reusingExistingBookmarks: reusingExistingBookmarks) ?? Bookmark(model)
            bookmark.updateSidebarFields(from: model)
            bookmark.setFaviconSnapshotUpdater { [weak self] data in
                self?.browserState?.localStore.updateTabFavicon(model.guid, favicon: data)
            }
            bookmarkMap[model.guid] = bookmark
        }

        for bookmark in bookmarkMap.values {
            bookmark.parent = nil
            if bookmark.isFolder {
                bookmark.replaceChildren([])
            }
        }
        
        for model in sortedModels {
            guard let bookmark = bookmarkMap[model.guid],
                  let parentGuid = model.parent?.guid,
                  let parentBookmark = bookmarkMap[parentGuid],
                  parentBookmark.isFolder else {
                continue
            }
            parentBookmark.addChild(bookmark)
        }
        
        // The publisher already filters by `(profileId, spaceId)` so the
        // result set contains exactly one Space-local root — the folder
        // whose `parent == nil`. We identify it structurally instead of
        // dereferencing `profile.bookmarkRoot` so the same code works
        // whether the active Space is the default (root shared with the
        // Profile) or a user-created Space (root owned only by the
        // SpaceModel).
        let rootGuid = sortedModels.first { $0.parent == nil && $0.dataType == .bookmarkFolder }?.guid

        var topLevel: [Bookmark] = []
        for model in sortedModels {
            if model.guid == rootGuid { continue }
            if let parentGuid = model.parent?.guid {
                if parentGuid == rootGuid {
                    if let bookmark = bookmarkMap[model.guid] {
                        topLevel.append(bookmark)
                    }
                } else if bookmarkMap[parentGuid] == nil {
                    if let bookmark = bookmarkMap[model.guid] {
                        topLevel.append(bookmark)
                    }
                }
            } else if let bookmark = bookmarkMap[model.guid] {
                topLevel.append(bookmark)
            }
        }
        return topLevel
    }

    private func reusableBookmark(for model: TabDataModel, reusingExistingBookmarks: Bool) -> Bookmark? {
        guard reusingExistingBookmarks, let existing = bookmarkIndex[model.guid] else { return nil }

        let modelIsFolder = model.dataType == .bookmarkFolder
        let modelProfileId = model.profile?.profileId ?? model.profileId
        guard existing.isFolder == modelIsFolder, existing.profileId == modelProfileId else { return nil }

        return existing
    }
}

extension Bookmark {
    convenience init(_ model: TabDataModel) {
        let isFolder = (model.dataType == .bookmarkFolder)
        let resolvedURL = isFolder ? nil : model.url.absoluteString
        let resolvedSecondary = isFolder ? nil : model.secondaryUrl?.absoluteString
        let resolvedSecondaryTitle = isFolder ? nil : model.secondaryTitle
        self.init(guid: model.guid,
                  title: Self.sidebarTitle(from: model),
                  url: resolvedURL,
                  secondaryUrl: resolvedSecondary,
                  secondaryTitle: resolvedSecondaryTitle,
                  profileId: model.profile?.profileId ?? model.profileId,
                  faviconData: model.favicon,
                  lastSeen: isFolder ? nil : model.lastSeen,
                  createdDate: model.createdDate,
                  updatedDate: model.updatedDate,
                  isFolder: isFolder)
    }

    fileprivate func updateSidebarFields(from model: TabDataModel) {
        title = Self.sidebarTitle(from: model)
        url = isFolder ? nil : model.url.absoluteString
        secondaryUrl = isFolder ? nil : model.secondaryUrl?.absoluteString
        secondaryTitle = isFolder ? nil : model.secondaryTitle
        cachedFaviconData = model.favicon
        lastSeen = isFolder ? nil : model.lastSeen
        createdDate = model.createdDate
        updatedDate = model.updatedDate
    }

    private static func sidebarTitle(from model: TabDataModel) -> String {
        model.overrideTitle?.isEmpty == false ? model.overrideTitle! : model.title
    }
}
