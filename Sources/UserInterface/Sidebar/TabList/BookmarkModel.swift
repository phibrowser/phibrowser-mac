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
    @Published var faviconUrl: String?
    @Published private(set) var cachedFaviconData: Data?
    @Published private(set) var liveFaviconData: Data?
    /// Whether this bookmark matches the currently focused tab.
    @Published var isActive: Bool = false
    /// Whether the folder is expanded in the UI.
    @Published var isExpanded: Bool = false
    /// Whether the bookmark is currently in inline-edit mode.
    @Published var isEditing: Bool = false
    
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
    private var faviconSnapshotUpdater: ((Data) -> Void)?
    
    init(guid: String = UUID().uuidString,
         title: String,
         url: String? = nil,
         profileId: String? = nil,
         faviconData: Data? = nil,
         isFolder: Bool = false) {
        self.guid = guid
        self.profileId = profileId
        self.title = title
        self.url = url
        self.cachedFaviconData = faviconData
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
        if let currentWrapper = webContentWrapper, let wrapper, currentWrapper === wrapper {
            return
        }
        if webContentWrapper == nil, wrapper == nil {
            return
        }
        self.webContentWrapper = wrapper
        setupObservers(for: wrapper)
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
        updateCachedFaviconData(wrapper.favIconData, persist: false)

        wrapper.publisher(for: \.favIconData)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.liveFaviconData = data
                self?.updateCachedFaviconData(data, persist: true)
            }
            .store(in: &cancellables)
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
        browseState.localStore.createDefaultRootDir(profileId: browseState.profileId)
        Task { @MainActor in
            browseState.localStore.bookmarksPublisher(profileId: browseState.profileId)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] bookmarkModels in
                    guard let self else { return }
                    self.saveExpandedState()
                    
                    let bookmarks = self.mappedModels(from: bookmarkModels)
                    self.rootFolder = Bookmark(title: "Bookmarks", children: bookmarks)
                    self.rebuildIndex()
                    self.browserState?.syncAllBookmarksOpenedState()
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
    
    func updateBookmark(guid: String, title: String? = nil, url: String? = nil) {
        guard let profileId = browserState?.profileId else { return }
        browserState?.localStore.updateBookmark(guid, profileId: profileId, title: title, url: url)

        guard let state = browserState,
              let url,
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
    
    func addBookmark(title: String, url: String, to parent: Bookmark? = nil, targetIndex: Int? = nil) {
        guard let profileId = browserState?.profileId else { return }
        browserState?.localStore.createBookmark(url: url, title: title, profileId: profileId, parentId: parent?.guid, index: targetIndex)
    }
    
    func addFolder(title: String, to parent: Bookmark? = nil) {
        guard let profileId = browserState?.profileId else { return }
        browserState?.localStore.createDirectory(title: title, profileId: profileId, parentId: parent?.guid)
    }
    
    /// Creates a new folder and marks it for inline editing.
    func addFolderWithEditing(title: String, to parent: Bookmark? = nil) {
        let newGuid = UUID().uuidString
        pendingEditGuid = newGuid
        guard let profileId = browserState?.profileId else { return }
        browserState?.localStore.createDirectory(title: title, profileId: profileId, parentId: parent?.guid, guid: newGuid)
    }

    /// Creates a folder and inserts the bookmark without triggering sidebar inline editing.
    func addFolderFromTabStrip(title: String,
                              to parent: Bookmark? = nil,
                              bookmarkTitle: String?,
                              bookmarkURL: String,
                              completion: @escaping (Bool, String) -> Void) {
        let newGuid = UUID().uuidString
        guard let profileId = browserState?.profileId else { return }
        browserState?.localStore.createDirectoryWithBookmark(folderTitle: title,
                                                             folderGuid: newGuid,
                                                             profileId: profileId,
                                                             parentId: parent?.guid,
                                                             bookmarkTitle: bookmarkTitle,
                                                             bookmarkURL: bookmarkURL) { success in
            completion(success, newGuid)
        }
    }
    
    /// Triggers inline rename mode for the given bookmark.
    func triggerRename(for bookmark: Bookmark) {
        NotificationCenter.default.post(name: .bookmarkStartEditing, object: bookmark)
    }
    
    func removeBookmark(_ bookmark: Bookmark) {
        guard let profileId = browserState?.profileId else { return }
        browserState?.localStore.deleteBookmark(bookmark.guid, profileId: profileId)
    }
    
    func findBookmark(byURL url: String) -> Bookmark? {
        guard let normalized = browserState?.localStore.normalizedURL(from: url)?.absoluteString else { return nil }
        return getAllBookmarks().first { !$0.isFolder && $0.url == normalized }
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
    func mappedModels(from models: [TabDataModel]) -> [Bookmark] {
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
            let bookmark = Bookmark(model)
            bookmark.setFaviconSnapshotUpdater { [weak self] data in
                self?.browserState?.localStore.updateTabFavicon(model.guid, favicon: data)
            }
            bookmarkMap[model.guid] = bookmark
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
        
        var topLevel: [Bookmark] = []
        for model in sortedModels {
            let isRoot = model.profile?.bookmarkRoot?.guid == model.guid
            guard !isRoot else { continue }
            if let parentGuid = model.parent?.guid {
                if model.parent?.profile?.bookmarkRoot?.guid == parentGuid {
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
}

extension Bookmark {
    convenience init(_ model: TabDataModel) {
        let displayTitle = (model.overrideTitle?.isEmpty == false ? model.overrideTitle! : model.title)
        let isFolder = (model.dataType == .bookmarkFolder)
        let resolvedURL = isFolder ? nil : model.url.absoluteString
        self.init(guid: model.guid,
                  title: displayTitle,
                  url: resolvedURL,
                  profileId: model.profile?.profileId ?? model.profileId,
                  faviconData: model.favicon,
                  isFolder: isFolder)
    }
}
