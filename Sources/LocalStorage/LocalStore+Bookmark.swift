// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData
import Combine

extension LocalStore {
    static let defaultRootDirIdentifier = "default-root-dir"
    private static let folderPlaceholderURL: URL = {
        URL(string: "https://bookmark.phi/folder")!
    }()
    private static let importedFromArcFolderTitle = NSLocalizedString(
        "Imported From Arc",
        comment: "Arc bookmarks import folder title"
    )
    
    /// Creates a bookmark node, attaching it to the root when `parentId` is nil.
    func createBookmark(url: String?,
                        title: String?,
                        profileId: String,
                        parentId: String?,
                        index: Int? = nil,
                        guid: String? = nil,
                        spaceId: String? = nil) {
        guard let normalizedURL = normalizedURL(from: url),
        let bookmarkURL = URL(string: URLProcessor.processUserInput( normalizedURL.absoluteString)) else {
            AppLogError("Invalid bookmark url: \(url ?? "nil")")
            return
        }
        
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, in: context) else {
                    AppLogError("Parent folder not found when creating bookmark")
                    return
                }
                let now = Date()
                _ = try self.insertBookmarkNode(title: title,
                                                profileId: profileId,
                                                url: bookmarkURL,
                                                parent: parent,
                                                index: index,
                                                guid: guid,
                                                spaceId: spaceId,
                                                now: now,
                                                in: context)
            } catch {
                AppLogError("Failed to create bookmark: \(error)")
            }
        }
    }
    
    /// Creates a bookmark folder node.
    func createDirectory(title: String,
                         profileId: String,
                         parentId: String?,
                         index: Int? = nil,
                         guid: String? = nil,
                         spaceId: String? = nil) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, in: context) else {
                    AppLogError("Parent folder not found when creating directory")
                    return
                }
                let now = Date()
                _ = try self.insertDirectoryNode(title: title,
                                                 profileId: profileId,
                                                 parent: parent,
                                                 index: index,
                                                 guid: guid,
                                                 spaceId: spaceId,
                                                 now: now,
                                                 in: context)
            } catch {
                AppLogError("Failed to create directory: \(error)")
            }
        }
    }

    /// Creates a folder and its initial bookmark in the same write transaction.
    func createDirectoryWithBookmark(folderTitle: String,
                                     folderGuid: String,
                                     profileId: String,
                                     parentId: String?,
                                     bookmarkTitle: String?,
                                     bookmarkURL: String,
                                     index: Int? = nil,
                                     completion: ((Bool) -> Void)? = nil) {
        AppLogDebug("[BookmarkAdd] createDirectoryWithBookmark request folderTitle=\(folderTitle) parentId=\(parentId ?? "nil") folderGuid=\(folderGuid) bookmarkTitle=\(bookmarkTitle ?? "nil") bookmarkURL=\(bookmarkURL)")
        guard let normalizedBookmarkURL = normalizedURL(from: bookmarkURL) else {
            AppLogError("Invalid bookmark url: \(bookmarkURL)")
            completion?(false)
            return
        }
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, in: context) else {
                    AppLogError("Parent folder not found when creating directory with bookmark")
                    return
                }
                let now = Date()
                let folder = try self.insertDirectoryNode(title: folderTitle,
                                                          profileId: profileId,
                                                          parent: parent,
                                                          index: index,
                                                          guid: folderGuid,
                                                          spaceId: parent.spaceId,
                                                          now: now,
                                                          in: context)

                _ = try self.insertBookmarkNode(title: bookmarkTitle,
                                                profileId: profileId,
                                                url: normalizedBookmarkURL,
                                                parent: folder,
                                                index: nil,
                                                guid: nil,
                                                spaceId: folder.spaceId,
                                                now: now,
                                                in: context)
                completion?(true)
            } catch {
                AppLogError("Failed to create directory with bookmark: \(error)")
                completion?(false)
            }
        }
    }
    
    /// Ensures the hidden root folder exists for bookmarks without an explicit parent.
    func createDefaultRootDir(profileId: String) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                _ = try self.bookmarkRoot(profileId: profileId, in: context, createIfNeeded: true)
            } catch {
                AppLogError("Failed to create default root: \(error)")
            }
        }
    }

    /// Persists bookmarks imported from Arc into the local store.
    func saveArcBookmarksToLocalStore(_ bookmarks: [ArcDataParserTool.Bookmark], profileId: String) async {
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                guard let profile = try self.profile(with: profileId, in: context, createIfNeeded: true),
                      let root = try self.bookmarkRoot(profileId: profileId, in: context, createIfNeeded: true) else { return }
                
                let now = Date()
                let importRoot = TabDataModel(
                    title: Self.importedFromArcFolderTitle,
                    guid: UUID().uuidString,
                    index: 0,
                    url: Self.folderPlaceholderURL,
                    favicon: nil,
                    createdDate: now,
                    updatedDate: now
                )
                importRoot.dataType = .bookmarkFolder
                importRoot.isCreatedByChromium = false
                importRoot.spaceId = root.spaceId
                importRoot.profileId = profileId
                importRoot.source = 3
                importRoot.profile = profile
                context.insert(importRoot)
                try self.insert(node: importRoot, to: root, at: nil, in: context)
                
                func insertArcBookmark(
                    _ arcBookmark: ArcDataParserTool.Bookmark,
                    parent: TabDataModel,
                    index: Int
                ) throws {
                    let title = (arcBookmark.title?.isEmpty ?? true) ? "Untitled" : arcBookmark.title
                    let url = arcBookmark.isFolder
                        ? Self.folderPlaceholderURL
                        : self.normalizedURL(from: arcBookmark.url)
                    guard let url else {
                        AppLogError("Skipping bookmark with invalid URL: \(arcBookmark.url ?? "nil")")
                        return
                    }
                    
                    let node = TabDataModel(
                        title: title ?? "Untitled",
                        guid: UUID().uuidString,
                        index: 0,
                        url: url,
                        favicon: nil,
                        createdDate: now,
                        updatedDate: now
                    )
                    node.dataType = arcBookmark.isFolder ? .bookmarkFolder : .bookmark
                    node.isCreatedByChromium = false
                    node.spaceId = parent.spaceId
                    node.profileId = profileId
                    node.source = 3
                    node.profile = profile
                    context.insert(node)
                    try self.insert(node: node, to: parent, at: index, in: context)
                    
                    for (childIndex, child) in arcBookmark.children.enumerated() {
                        try insertArcBookmark(child, parent: node, index: childIndex)
                    }
                }
                
                for (index, bookmark) in bookmarks.enumerated() {
                    try insertArcBookmark(bookmark, parent: importRoot, index: index)
                }
            } catch {
                AppLogError("Failed to save Arc bookmarks: \(error)")
            }
        }
    }
    
    func saveChromiumBookmarksToLocalStore(_ bookmarks: [BookmarkWrapper], profileId: String) async {
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                guard let profile = try self.profile(with: profileId, in: context, createIfNeeded: true),
                      let root = try self.bookmarkRoot(profileId: profileId, in: context, createIfNeeded: true) else { return }
                guard let bookmarksBar = bookmarks.first(where: { $0.title == "Bookmarks Bar" }) else {
                    AppLogError("Bookmarks Bar not found in Chromium bookmarks")
                    return
                }
                
                func insertChromiumBookmark(
                    _ wrapper: BookmarkWrapper,
                    parent: TabDataModel,
                    index: Int
                ) throws {
                    let title = (wrapper.title?.isEmpty == false)
                        ? wrapper.title!
                        : (wrapper.urlString ?? "Untitled")
                    let url = wrapper.isFolder
                        ? Self.folderPlaceholderURL
                        : self.normalizedURL(from: wrapper.urlString)
                    
                    guard let url else {
                        AppLogError("Skipping bookmark with invalid URL: \(wrapper.urlString ?? "nil")")
                        return
                    }
                    
                    let now = Date()
                    let node = TabDataModel(
                        title: title,
                        guid: UUID().uuidString,
                        index: 0,
                        url: url,
                        favicon: nil,
                        createdDate: now,
                        updatedDate: now
                    )
                    node.dataType = wrapper.isFolder ? .bookmarkFolder : .bookmark
                    node.isCreatedByChromium = false
                    node.spaceId = parent.spaceId
                    node.profileId = profileId
                    node.source = Self.importedBrowserSourceValue(
                        forTitle: title,
                        inheritedSource: parent.source,
                        isTopLevelImportFolder: parent.guid == root.guid
                    )
                    node.profile = profile
                    context.insert(node)
                    try self.insert(node: node, to: parent, at: index, in: context)
                    
                    let orderedChildren = wrapper.children.sorted { $0.indexInParent < $1.indexInParent }
                    for (childIndex, child) in orderedChildren.enumerated() {
                        try insertChromiumBookmark(child, parent: node, index: childIndex)
                    }
                }
                
                let orderedRootChildren = bookmarksBar.children.sorted { $0.indexInParent < $1.indexInParent }
                for (index, bookmark) in orderedRootChildren.enumerated() {
                    try insertChromiumBookmark(bookmark, parent: root, index: index)
                }
            } catch {
                AppLogError("Failed to save Chromium bookmarks: \(error)")
            }
        }
    }

    func reorderImportedBrowserFolders(profileId: String) async {
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                guard let root = try self.bookmarkRoot(profileId: profileId, in: context, createIfNeeded: false) else { return }
                let rootChildren = try self.children(of: root, in: context)

                let rankedImportFolders = rootChildren.enumerated().compactMap { offset, child -> (Int, Int, TabDataModel)? in
                    guard let rank = Self.importedBrowserFolderRank(for: child.title, source: child.source),
                          child.dataType == .bookmarkFolder else {
                        return nil
                    }
                    return (rank, offset, child)
                }

                guard !rankedImportFolders.isEmpty else { return }

                let importFolderGuids = Set(rankedImportFolders.map { $0.2.guid })
                let orderedImportFolders = rankedImportFolders
                    .sorted { lhs, rhs in
                        if lhs.0 != rhs.0 {
                            return lhs.0 < rhs.0
                        }
                        return lhs.1 < rhs.1
                    }
                    .map(\.2)

                let otherFolders = rootChildren.filter {
                    $0.dataType == .bookmarkFolder && !importFolderGuids.contains($0.guid)
                }
                let nonFolders = rootChildren.filter { $0.dataType != .bookmarkFolder }

                self.normalizeIndexes(for: otherFolders + orderedImportFolders + nonFolders)
            } catch {
                AppLogError("Failed to reorder imported browser folders: \(error)")
            }
        }
    }
    
    /// Moves a bookmark or folder to a new parent and sibling index.
    func moveBookmark(_ guid: String, profileId: String, to parentId: String?, newIndex: Int) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let node = try self.bookmarkNode(with: guid, in: context) else {
                    AppLogError("Bookmark \(guid) not found for move")
                    return
                }
                guard try !self.isProfileBookmarkRoot(node, in: context) else {
                    AppLogError("Attempted to move bookmark root")
                    return
                }
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, in: context) else {
                    AppLogError("Target parent not found for move")
                    return
                }
                
                let originalParent = node.parent
                node.parent = parent
                
                if let originalParent, originalParent.guid != parent.guid {
                    let originalSiblings = try self.children(of: originalParent, in: context)
                    self.normalizeIndexes(for: originalSiblings)
                }
                
                var siblings = try self.children(of: parent, in: context).filter { $0.guid != node.guid }
                let targetIndex = Self.clamp(index: newIndex, upperBound: siblings.count)
                siblings.insert(node, at: targetIndex)
                self.normalizeIndexes(for: siblings)
                node.updatedDate = Date()
            } catch {
                AppLogError("Failed to move bookmark: \(error)")
            }
        }
    }
    
    /// Updates bookmark title and URL, normalizing the URL when provided.
    func updateBookmark(_ guid: String, profileId: String, title: String?, url: String?) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let node = try self.bookmarkNode(with: guid, in: context) else {
                    AppLogError("Bookmark \(guid) not found for update")
                    return
                }
                if let title, !title.isEmpty {
                    node.title = title
                }
                if let urlString = url {
                    guard let newURL = self.normalizedURL(from: urlString) else {
                        AppLogError("Invalid URL while updating bookmark: \(urlString)")
                        return
                    }
                    node.url = newURL
                }
                node.updatedDate = Date()
            } catch {
                AppLogError("Failed to update bookmark: \(error)")
            }
        }
    }
    
    /// Deletes a bookmark or folder and compacts sibling indexes.
    func deleteBookmark(_ guid: String, profileId: String) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let node = try self.bookmarkNode(with: guid, in: context) else { return }
                guard try !self.isProfileBookmarkRoot(node, in: context) else {
                    AppLogError("Attempted to delete bookmark root")
                    return
                }
                
                let parent = node.parent
                context.delete(node)
                
                if let parent {
                    let siblings = try self.children(of: parent, in: context)
                    self.normalizeIndexes(for: siblings)
                }
            } catch {
                AppLogError("Failed to delete bookmark: \(error)")
            }
        }
    }
    
    @MainActor
    /// Returns all bookmarks directly under the specified parent.
    func fetchBookmarks(parentId: String?, profileId: String) -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            guard let parent = try resolveParent(for: parentId, profileId: profileId, in: context, createIfNeeded: false) else {
                return []
            }
            let siblings = try children(of: parent, in: context)
            return siblings
        } catch {
            AppLogError("Failed to fetch bookmarks: \(error)")
            return []
        }
    }
    
    @MainActor
    /// Returns a single bookmark node for editing or navigation.
    func fetchBookmark(with guid: String) -> TabDataModel? {
        guard let context = mainContext else { return nil }
        do {
            return try bookmarkNode(with: guid, in: context)
        } catch {
            AppLogError("Failed to fetch bookmark \(guid): \(error)")
            return nil
        }
    }
    
    @MainActor
    /// Publishes bookmark changes from the underlying store.
    func bookmarksPublisher(profileId: String) -> AnyPublisher<[TabDataModel], Never> {
        guard let context = mainContext else {
            return Just([]).eraseToAnyPublisher()
        }
        
        let subject = CurrentValueSubject<[TabDataModel], Never>([])
        let fetchBookmarks: () -> [TabDataModel] = {
            do {
                let bookmarkRaw = TabDataType.bookmark.rawValue
                let folderRaw = TabDataType.bookmarkFolder.rawValue
                let predicate = #Predicate<TabDataModel> { $0.type == bookmarkRaw || $0.type == folderRaw }
                let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.createdDate)]
                let descriptor = FetchDescriptor<TabDataModel>(
                    predicate: predicate,
                    sortBy: sortBy
                )
                let bookmarks: [TabDataModel] = try context.fetch(descriptor)
                return bookmarks.filter { $0.profile?.profileId == profileId }
            } catch {
                AppLogError("Failed to fetch bookmarks for publisher: \(error)")
                return []
            }
        }
        
        subject.send(fetchBookmarks())
        
        let notificationCenter = NotificationCenter.default
        let cancellable = notificationCenter
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter { Self.notificationContainsChanges($0, matching: {
                guard $0.entity.name == TabDataModel.entityName, let type = Self.tabType(from: $0) else { return false }
                return type == TabDataType.bookmark.rawValue || type == TabDataType.bookmarkFolder.rawValue
            }) }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                subject.send(fetchBookmarks())
            }
        
        return subject
            .handleEvents(receiveCancel: {
                cancellable.cancel()
            })
            .eraseToAnyPublisher()
    }
}

// MARK: - Helpers
private extension LocalStore {
    /// Inserts a node into the parent children sequence and reindexes siblings.
    func insert(node: TabDataModel,
                to parent: TabDataModel,
                at index: Int?,
                in context: ModelContext) throws {
        node.parent = parent
        var siblings = try children(of: parent, in: context).filter { $0.guid != node.guid }
        let targetIndex = Self.clamp(index: index, upperBound: siblings.count)
        siblings.insert(node, at: targetIndex)
        normalizeIndexes(for: siblings)
    }
    
    func children(of parent: TabDataModel, in context: ModelContext) throws -> [TabDataModel] {
        let parentGuid = parent.guid
        let predicate = #Predicate<TabDataModel> {
            $0.parent?.guid == parentGuid
        }

        let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index)]
        let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate, sortBy: sortBy)
        return try context.fetch(descriptor)
    }
    
    /// Normalizes sibling indexes into a contiguous `0...n-1` range.
    func normalizeIndexes(for nodes: [TabDataModel]) {
        for (position, node) in nodes.enumerated() where node.index != position {
            node.index = position
            node.updatedDate = Date()
        }
    }
    
    func bookmarkNode(with guid: String, in context: ModelContext) throws -> TabDataModel? {
        let predicate = #Predicate<TabDataModel> { $0.guid == guid }
        let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
        return try context.fetch(descriptor).first
    }

    func insertDirectoryNode(title: String,
                             profileId: String,
                             parent: TabDataModel,
                             index: Int?,
                             guid: String?,
                             spaceId: String?,
                             now: Date,
                             in context: ModelContext) throws -> TabDataModel {
        let folder = TabDataModel(title: title,
                                  guid: guid ?? UUID().uuidString,
                                  index: 0,
                                  url: Self.folderPlaceholderURL,
                                  favicon: nil as Data?,
                                  createdDate: now,
                                  updatedDate: now)
        folder.dataType = TabDataType.bookmarkFolder
        folder.spaceId = spaceId ?? parent.spaceId
        folder.profileId = profileId
        folder.profile = parent.profile
        folder.isCreatedByChromium = false
        context.insert(folder)
        try insert(node: folder, to: parent, at: index, in: context)
        return folder
    }

    func insertBookmarkNode(title: String?,
                            profileId: String,
                            url: URL,
                            parent: TabDataModel,
                            index: Int?,
                            guid: String?,
                            spaceId: String?,
                            now: Date,
                            in context: ModelContext) throws -> TabDataModel {
        let bookmark = TabDataModel(title: (title?.isEmpty == false ? title! : url.absoluteString),
                                    guid: guid ?? UUID().uuidString,
                                    index: 0,
                                    url: url,
                                    favicon: nil as Data?,
                                    createdDate: now,
                                    updatedDate: now)
        bookmark.dataType = TabDataType.bookmark
        bookmark.spaceId = spaceId ?? parent.spaceId
        bookmark.profileId = profileId
        bookmark.profile = parent.profile
        bookmark.isCreatedByChromium = false
        context.insert(bookmark)
        try insert(node: bookmark, to: parent, at: index, in: context)
        return bookmark
    }
    
    func bookmarkRoot(profileId: String,
                      in context: ModelContext,
                      createIfNeeded: Bool) throws -> TabDataModel? {
        guard let profile = try profile(with: profileId, in: context, createIfNeeded: createIfNeeded) else {
            return nil
        }
        if let existing = profile.bookmarkRoot {
            return existing
        }
        guard createIfNeeded else { return nil }
        let now = Date()
        let root = TabDataModel(title: NSLocalizedString("Bookmarks", comment: "Default root bookmarks folder title"),
                                guid: UUID().uuidString,
                                index: 0,
                                url: Self.folderPlaceholderURL,
                                favicon: nil as Data?,
                                createdDate: now,
                                updatedDate: now)
        root.dataType = TabDataType.bookmarkFolder
        root.profileId = profileId
        root.profile = profile
        root.isCreatedByChromium = false
        context.insert(root)
        profile.bookmarkRoot = root
        return root
    }
    
    func resolveParent(for parentId: String?,
                       profileId: String,
                       in context: ModelContext,
                       createIfNeeded: Bool = true) throws -> TabDataModel? {
        if let parentId,
           let node = try bookmarkNode(with: parentId, in: context),
           node.dataType == .bookmarkFolder {
            return node
        }
        return try bookmarkRoot(profileId: profileId, in: context, createIfNeeded: createIfNeeded)
    }

    func isProfileBookmarkRoot(_ node: TabDataModel, in context: ModelContext) throws -> Bool {
        let descriptor: FetchDescriptor<ProfileModel> = FetchDescriptor<ProfileModel>()
        let profiles: [ProfileModel] = try context.fetch(descriptor)
        return profiles.contains(where: { $0.bookmarkRoot?.guid == node.guid })
    }

    static func importedBrowserSourceValue(
        forTitle title: String,
        inheritedSource: Int,
        isTopLevelImportFolder: Bool
    ) -> Int {
        guard isTopLevelImportFolder else {
            return inheritedSource == 0 ? 1 : inheritedSource
        }

        switch importedBrowserFolderRank(for: title, source: inheritedSource) {
        case 0:
            return 1
        case 2:
            return 2
        default:
            return inheritedSource == 0 ? 1 : inheritedSource
        }
    }

    static func importedBrowserFolderRank(for title: String, source: Int) -> Int? {
        if source == 3 || title == importedFromArcFolderTitle {
            return 1
        }

        let lowercasedTitle = title.lowercased()
        if lowercasedTitle.contains("chrome") {
            return 0
        }
        if lowercasedTitle.contains("safari") {
            return 2
        }
        return nil
    }
    
    static func clamp(index: Int?, upperBound: Int) -> Int {
        guard let index = index else { return upperBound }
        return max(0, min(index, upperBound))
    }
    
    static func clamp(index: Int, upperBound: Int) -> Int {
        max(0, min(index, upperBound))
    }
    
}

extension LocalStore {
    func normalizedURL(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(raw)")
    }
}
