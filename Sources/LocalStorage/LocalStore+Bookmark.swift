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
    private static let importedFromArcFolderTitle = NSLocalizedString("localData.bookmarks.importedFromArcFolderTitle", value: "Imported From Arc",
        comment: "Arc bookmarks import folder title"
    )
    private static let importedFromDiaFolderTitle = NSLocalizedString("localData.bookmarks.importedFromDiaFolderTitle", value: "Imported From Dia",
        comment: "Bookmark folder - Wrapper created at the Space root to hold the bookmarks imported from Dia; its title must match the one the browser side writes"
    )
    
    /// Creates a bookmark node, attaching it to the root when `parentId` is nil.
    /// `secondaryUrl` is set only for split-view bookmarks; clicking such a
    /// bookmark opens both URLs as a split. `secondaryTitle`
    /// is the secondary pane's display name and is shown alongside the
    /// primary title in the bookmark bar/sidebar. `layout` stores the raw
    /// divider orientation and defaults to side-by-side when absent.
    func createBookmark(url: String?,
                        title: String?,
                        profileId: String,
                        parentId: String?,
                        index: Int? = nil,
                        guid: String? = nil,
                        spaceId: String = LocalStore.defaultSpaceId,
                        secondaryUrl: String? = nil,
                        secondaryTitle: String? = nil,
                        layout: String? = nil,
                        favicon: Data? = nil) {
        let bookmarkURL: URL
        do {
            bookmarkURL = try userInputBookmarkURL(from: url)
        } catch {
            AppLogError("Invalid bookmark url: \(url ?? "nil")")
            return
        }
        // A nil `secondaryUrl` means a single-URL bookmark; a non-nil but
        // unparseable value is a user error and must surface, not silently
        // turn the bookmark into a single-URL one.
        let normalizedSecondary: URL?
        if let raw = secondaryUrl {
            do {
                normalizedSecondary = try userInputBookmarkURL(from: raw)
            } catch {
                AppLogError("Invalid bookmark secondary url: \(raw)")
                return
            }
        } else {
            normalizedSecondary = nil
        }

        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                _ = try self.createBookmarkBody(url: bookmarkURL,
                                                title: title,
                                                profileId: profileId,
                                                parentId: parentId,
                                                index: index,
                                                guid: guid,
                                                spaceId: spaceId,
                                                secondaryUrl: normalizedSecondary,
                                                secondaryTitle: secondaryTitle,
                                                layout: layout,
                                                favicon: favicon,
                                                syncId: nil,
                                                createdDate: nil,
                                                allowsEmptyTitle: false,
                                                strictParent: false,
                                                in: context)
            } catch {
                AppLogError("Failed to create bookmark: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer: `PhiSyncEngine` may write
    /// the `reconciled` / `server` baselines only after the row landed, and the
    /// fire-and-forget original swallows its own failure (§4.9).
    ///
    /// 三处与 UI 入口的有意差异：① 收 `URL` 而不是 `String?`，所以不经过
    /// `URLProcessor.processUserInput`（那是给用户输入准备的，会把不像 URL 的东西变成
    /// 搜索，而线上来的 URL 已经是绝对 URL）；② `allowsEmptyTitle` 默认 `true`，一条
    /// 远端 `title == ""` 的 create 必须原样落成空标题；③ 父解析是严格的，解析不到就抛，
    /// 绝不静默落回 Space root。
    @discardableResult
    func createBookmarkThrowing(url: URL,
                                title: String?,
                                profileId: String,
                                parentId: String?,
                                index: Int? = nil,
                                guid: String? = nil,
                                spaceId: String = LocalStore.defaultSpaceId,
                                secondaryUrl: URL? = nil,
                                secondaryTitle: String? = nil,
                                favicon: Data? = nil,
                                syncId: String? = nil,
                                createdDate: Date? = nil,
                                allowsEmptyTitle: Bool = true) async throws -> String {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.createBookmarkBody(url: url,
                                        title: title,
                                        profileId: profileId,
                                        parentId: parentId,
                                        index: index,
                                        guid: guid,
                                        spaceId: spaceId,
                                        secondaryUrl: secondaryUrl,
                                        secondaryTitle: secondaryTitle,
                                        favicon: favicon,
                                        syncId: syncId,
                                        createdDate: createdDate,
                                        allowsEmptyTitle: allowsEmptyTitle,
                                        strictParent: true,
                                        in: context).guid
        }
    }

    /// Single implementation shared by both entry points.
    private func createBookmarkBody(url: URL,
                                    title: String?,
                                    profileId: String,
                                    parentId: String?,
                                    index: Int?,
                                    guid: String?,
                                    spaceId: String,
                                    secondaryUrl: URL?,
                                    secondaryTitle: String?,
                                    favicon: Data?,
                                    syncId: String?,
                                    createdDate: Date?,
                                    allowsEmptyTitle: Bool,
                                    strictParent: Bool,
                                    in context: ModelContext) throws -> TabDataModel {
        guard let parent = try resolveParent(for: parentId,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             in: context,
                                             strict: strictParent) else {
            throw LocalStoreWriteError.rowNotFound
        }
        let now = createdDate ?? Date()
        let node = try insertBookmarkNode(title: title,
                                          profileId: profileId,
                                          url: url,
                                          parent: parent,
                                          index: index,
                                          guid: guid,
                                          spaceId: spaceId,
                                          secondaryUrl: secondaryUrl,
                                          secondaryTitle: secondaryTitle,
                                          favicon: favicon,
                                          allowsEmptyTitle: allowsEmptyTitle,
                                          now: now,
                                          in: context)
        // 身份与行在同一个事务里写，落地路径没有第二次写可以失败。
        node.syncId = syncId
        return node
    }

    /// Creates a bookmark folder node.
    func createDirectory(title: String,
                         profileId: String,
                         parentId: String?,
                         index: Int? = nil,
                         guid: String? = nil,
                         spaceId: String = LocalStore.defaultSpaceId) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                _ = try self.createDirectoryBody(title: title,
                                                 profileId: profileId,
                                                 parentId: parentId,
                                                 index: index,
                                                 guid: guid,
                                                 spaceId: spaceId,
                                                 syncId: nil,
                                                 createdDate: nil,
                                                 strictParent: false,
                                                 in: context)
            } catch {
                AppLogError("Failed to create directory: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer (§4.9). 文件夹不受
    /// `allowsEmptyTitle` 影响：`insertDirectoryNode` 逐字写标题。
    @discardableResult
    func createDirectoryThrowing(title: String,
                                 profileId: String,
                                 parentId: String?,
                                 index: Int? = nil,
                                 guid: String? = nil,
                                 spaceId: String = LocalStore.defaultSpaceId,
                                 syncId: String? = nil,
                                 createdDate: Date? = nil) async throws -> String {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.createDirectoryBody(title: title,
                                         profileId: profileId,
                                         parentId: parentId,
                                         index: index,
                                         guid: guid,
                                         spaceId: spaceId,
                                         syncId: syncId,
                                         createdDate: createdDate,
                                         strictParent: true,
                                         in: context).guid
        }
    }

    /// Single implementation shared by both entry points.
    private func createDirectoryBody(title: String,
                                     profileId: String,
                                     parentId: String?,
                                     index: Int?,
                                     guid: String?,
                                     spaceId: String,
                                     syncId: String?,
                                     createdDate: Date?,
                                     strictParent: Bool,
                                     in context: ModelContext) throws -> TabDataModel {
        guard let parent = try resolveParent(for: parentId,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             in: context,
                                             strict: strictParent) else {
            throw LocalStoreWriteError.rowNotFound
        }
        let now = createdDate ?? Date()
        let folder = try insertDirectoryNode(title: title,
                                             profileId: profileId,
                                             parent: parent,
                                             index: index,
                                             guid: guid,
                                             spaceId: spaceId,
                                             now: now,
                                             in: context)
        folder.syncId = syncId
        return folder
    }

    /// Creates a folder and its initial bookmark in the same write transaction.
    func createDirectoryWithBookmark(folderTitle: String,
                                     folderGuid: String,
                                     profileId: String,
                                     parentId: String?,
                                     bookmarkTitle: String?,
                                     bookmarkURL: String,
                                     bookmarkFavicon: Data? = nil,
                                     index: Int? = nil,
                                     spaceId: String = LocalStore.defaultSpaceId,
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
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, spaceId: spaceId, in: context) else {
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
                                                favicon: bookmarkFavicon,
                                                now: now,
                                                in: context)
                completion?(true)
            } catch {
                AppLogError("Failed to create directory with bookmark: \(error)")
                completion?(false)
            }
        }
    }

    func createDirectoryWithBookmarks(folderTitle: String,
                                      folderGuid: String,
                                      profileId: String,
                                      parentId: String?,
                                      index: Int?,
                                      spaceId: String = LocalStore.defaultSpaceId,
                                      bookmarks: [(title: String?,
                                                   url: String,
                                                   guid: String,
                                                   secondaryUrl: String?,
                                                   secondaryTitle: String?,
                                                   layout: String?,
                                                   favicon: Data?)]) {
        let normalizedBookmarks: [(title: String?,
                                   url: URL,
                                   guid: String,
                                   secondaryUrl: URL?,
                                   secondaryTitle: String?,
                                   layout: String?,
                                   favicon: Data?)] = bookmarks.compactMap { bookmark -> (title: String?,
                                                                                            url: URL,
                                                                                            guid: String,
                                                                                            secondaryUrl: URL?,
                                                                                            secondaryTitle: String?,
                                                                                            layout: String?,
                                                                                            favicon: Data?)? in
            guard let primaryURL = normalizedURL(from: bookmark.url) else {
                AppLogError("Invalid bookmark url: \(bookmark.url)")
                return nil
            }
            let normalizedSecondaryURL: URL?
            if let secondaryUrl = bookmark.secondaryUrl {
                guard let normalized = normalizedURL(from: secondaryUrl) else {
                    AppLogError("Invalid bookmark secondary url: \(secondaryUrl)")
                    return nil
                }
                normalizedSecondaryURL = normalized
            } else {
                normalizedSecondaryURL = nil
            }
            return (title: bookmark.title,
                    url: primaryURL,
                    guid: bookmark.guid,
                    secondaryUrl: normalizedSecondaryURL,
                    secondaryTitle: bookmark.secondaryTitle,
                    layout: bookmark.layout,
                    favicon: bookmark.favicon)
        }
        guard normalizedBookmarks.count == bookmarks.count else { return }

        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, spaceId: spaceId, in: context) else {
                    AppLogError("Parent folder not found when creating directory with bookmarks")
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
                for (childIndex, bookmark) in normalizedBookmarks.enumerated() {
                    _ = try self.insertBookmarkNode(title: bookmark.title,
                                                    profileId: profileId,
                                                    url: bookmark.url,
                                                    parent: folder,
                                                    index: childIndex,
                                                    guid: bookmark.guid,
                                                    spaceId: folder.spaceId,
                                                    secondaryUrl: bookmark.secondaryUrl,
                                                    secondaryTitle: bookmark.secondaryTitle,
                                                    layout: bookmark.layout,
                                                    favicon: bookmark.favicon,
                                                    now: now,
                                                    in: context)
                }
            } catch {
                AppLogError("Failed to create directory with bookmarks: \(error)")
            }
        }
    }
    
    /// Ensures the hidden root folder exists for bookmarks without an explicit
    /// parent, in the given Space.
    func createDefaultRootDir(profileId: String,
                              spaceId: String = LocalStore.defaultSpaceId) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                _ = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: true)
            } catch {
                AppLogError("Failed to create default root: \(error)")
            }
        }
    }

    /// Persists bookmarks from one Arc Space into the local store.
    /// `spaceRoot` is the Space's bookmark root; its children are imported
    /// under a Space-named folder inside an "Imported From Arc" folder, or —
    /// with `landingFolder` false — directly under the Space's own bookmark
    /// root. Those landing folders keep an import apart from the target
    /// Space's own bookmarks, as the Chromium-side imports' "Imported From
    /// <browser>" folders do, so in a Space created for exactly this tree they
    /// would be pure nesting.
    /// Nothing is written when `spaceRoot` has no children (avoids empty
    /// folders for empty Spaces).
    ///
    /// Returns how many bookmarks were written — folders are not counted — or
    /// nil when the write did not land. The import completion signal reports
    /// success unconditionally and is set before this runs, so a caller that
    /// has to tell a persisted tree from a dropped one reads the outcome here
    /// instead. A failure part-way through still keeps what already landed:
    /// this write has never rolled back, and a Migration does not either.
    @discardableResult
    func saveArcBookmarksToLocalStore(
        _ spaceRoot: ArcDataParserTool.Bookmark,
        profileId: String,
        spaceId: String = LocalStore.defaultSpaceId,
        landingFolder: Bool = true
    ) async -> Int? {
        guard !spaceRoot.children.isEmpty else { return 0 }   // no empty Space-named folder
        do {
            return try await performBackgroundWriteAndWaitThrowing { [weak self] context -> Int? in
                guard let self else { return nil }
                // Caught here rather than thrown out of the write: the actor
                // rolls the whole context back on a thrown error, and this
                // import has always kept the part of the tree that landed.
                do {
                    guard try self.importTargetSpaceIsWritable(profileId: profileId, spaceId: spaceId, in: context) else {
                        AppLogWarn("Skipping Arc bookmark import: space \(spaceId) no longer exists for profile \(profileId)")
                        return nil
                    }
                    guard let profile = try self.profile(with: profileId, in: context, createIfNeeded: true),
                          let root = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: true) else {
                        AppLogError("Skipping Arc bookmark import: no profile or bookmark root "
                            + "for profile \(profileId) space \(spaceId)")
                        return nil
                    }

                    let now = Date()
                    func insertLandingFolder(titled title: String, into parent: TabDataModel) throws -> TabDataModel {
                        let folder = TabDataModel(
                            title: title,
                            guid: UUID().uuidString, index: 0, url: Self.folderPlaceholderURL,
                            favicon: nil, createdDate: now, updatedDate: now)
                        folder.dataType = .bookmarkFolder
                        folder.isCreatedByChromium = false
                        folder.spaceId = root.spaceId
                        folder.profileId = profileId
                        folder.source = 3
                        folder.profile = profile
                        context.insert(folder)
                        try self.insert(node: folder, to: parent, at: nil, in: context)
                        return folder
                    }

                    let landingRoot: TabDataModel?
                    if landingFolder {
                        let importRoot = try insertLandingFolder(
                            titled: Self.importedFromArcFolderTitle, into: root)
                        landingRoot = try insertLandingFolder(
                            // Defensive fallback: the parser already fills every
                            // Space title (the real one, or its localized "Untitled
                            // Space"), so this only matters if a nil-title root ever
                            // reaches here. It uses the parser's own key so the two
                            // cannot drift apart.
                            titled: spaceRoot.title ?? NSLocalizedString("oobe.importBrowserData.arc.untitledSpaceName", value: "Untitled Space", comment: "Arc import - fallback name for an Arc Space with no title"),
                            into: importRoot)
                    } else {
                        // The tree goes straight to the Space's own root: a Space
                        // created for exactly this tree has nothing to keep it
                        // apart from.
                        landingRoot = nil
                    }

                    var insertedCount = 0
                    var bookmarkCount = 0
                    func insertArcBookmark(_ arcBookmark: ArcDataParserTool.Bookmark, parent: TabDataModel, index: Int) throws {
                        let title = (arcBookmark.title?.isEmpty ?? true) ? "Untitled" : arcBookmark.title
                        let url = arcBookmark.isFolder ? Self.folderPlaceholderURL : self.normalizedURL(from: arcBookmark.url)
                        guard let url else {
                            AppLogError("Skipping bookmark with invalid URL: \(arcBookmark.url ?? "nil")")
                            return
                        }
                        let node = TabDataModel(title: title ?? "Untitled", guid: UUID().uuidString,
                            index: 0, url: url, favicon: nil, createdDate: now, updatedDate: now)
                        node.dataType = arcBookmark.isFolder ? .bookmarkFolder : .bookmark
                        node.isCreatedByChromium = false
                        node.spaceId = parent.spaceId
                        node.profileId = profileId
                        node.source = 3
                        node.profile = profile
                        if let split = arcBookmark.split {
                            // A split-view entry: the second page rides on the
                            // same row, as Phi's own split bookmarks do. A
                            // second page whose URL cannot be read costs that
                            // page, not the bookmark.
                            if let secondaryURL = self.normalizedURL(from: split.secondaryURL) {
                                node.secondaryUrl = secondaryURL
                                node.secondaryTitle = split.secondaryTitle.isEmpty ? nil : split.secondaryTitle
                                node.layout = split.layout
                            } else {
                                AppLogError("Dropping the second page of a split bookmark "
                                    + "with an invalid URL: \(split.secondaryURL)")
                            }
                        }
                        context.insert(node)
                        try self.insert(node: node, to: parent, at: index, in: context)
                        insertedCount += 1
                        // A folder is not a bookmark: the count a caller reports
                        // has to match what the user would count in the source.
                        if !arcBookmark.isFolder { bookmarkCount += 1 }
                        for (childIndex, child) in arcBookmark.children.enumerated() {
                            try insertArcBookmark(child, parent: node, index: childIndex)
                        }
                    }

                    // Insert the Space's children directly under the Space-named
                    // folder, or under the Space's own root when there is none
                    // (no double-nest either way).
                    for (index, child) in spaceRoot.children.enumerated() {
                        try insertArcBookmark(child, parent: landingRoot ?? root, index: index)
                    }
                    AppLogInfo("Imported \(insertedCount) Arc bookmark node(s) "
                        + "into profile \(profileId) space \(spaceId)")
                    return bookmarkCount
                } catch {
                    AppLogError("Failed to save Arc bookmarks: \(error)")
                    return nil
                }
            }
        } catch {
            AppLogError("Skipping Arc bookmark import: no writable local store (\(error))")
            return nil
        }
    }
    
    /// Chromium's permanent bookmark bar node is the model root's first child.
    private static let chromiumBookmarkBarRootIndex = 0

    func saveChromiumBookmarksToLocalStore(_ bookmarks: [BookmarkWrapper], profileId: String, spaceId: String = LocalStore.defaultSpaceId) async {
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                // An empty tree is an ordinary outcome (nothing staged, or the
                // window went away before the tree could be read), not the
                // missing-bookmark-bar failure the guard below reports.
                guard !bookmarks.isEmpty else {
                    AppLogWarn("No Chromium bookmarks to import: the bridge returned an empty tree")
                    return
                }
                guard try self.importTargetSpaceIsWritable(profileId: profileId, spaceId: spaceId, in: context) else {
                    AppLogWarn("Skipping Chromium bookmark import: space \(spaceId) no longer exists for profile \(profileId)")
                    return
                }
                guard let profile = try self.profile(with: profileId, in: context, createIfNeeded: true),
                      let root = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: true) else {
                    AppLogError("Skipping Chromium bookmark import: no profile or bookmark root "
                        + "for profile \(profileId) space \(spaceId)")
                    return
                }
                // Chromium titles its permanent bookmark bar node in the UI
                // language (`IDS_BOOKMARK_BAR_FOLDER_NAME`), so it cannot be found
                // by an English title. Match the model position instead. Array
                // position would not do — the bridge drops permanent nodes that
                // are hidden while empty (the mobile node on desktop), so what it
                // hands back is a filtered view, while `indexInParent` still
                // carries each node's real index under the root.
                guard let bookmarksBar = bookmarks.first(where: {
                          $0.indexInParent == Self.chromiumBookmarkBarRootIndex
                      }),
                      bookmarksBar.isFolder else {
                    AppLogError("Bookmark bar node not found in Chromium bookmarks "
                        + "(\(bookmarks.count) root node(s)); nothing imported")
                    return
                }
                var insertedCount = 0
                
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
                    insertedCount += 1
                    
                    let orderedChildren = wrapper.children.sorted { $0.indexInParent < $1.indexInParent }
                    for (childIndex, child) in orderedChildren.enumerated() {
                        try insertChromiumBookmark(child, parent: node, index: childIndex)
                    }
                }
                
                let orderedRootChildren = bookmarksBar.children.sorted { $0.indexInParent < $1.indexInParent }
                for (index, bookmark) in orderedRootChildren.enumerated() {
                    try insertChromiumBookmark(bookmark, parent: root, index: index)
                }
                AppLogInfo("Imported \(insertedCount) Chromium bookmark node(s) "
                    + "into profile \(profileId) space \(spaceId)")
            } catch {
                AppLogError("Failed to save Chromium bookmarks: \(error)")
            }
        }
    }

    func reorderImportedBrowserFolders(profileId: String, spaceId: String = LocalStore.defaultSpaceId) async {
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                guard let root = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: false) else { return }
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
                // `toSpaceId: nil` 保留今天的语义：从行自己身上取 Space，于是一个
                // 缺失 / nil 的 parentId 落回那个 Space 的 root，且不重打任何标签。
                try self.moveBookmarkBody(guid,
                                          profileId: profileId,
                                          toParentGuid: parentId,
                                          toSpaceId: nil,
                                          index: newIndex,
                                          strictParent: false,
                                          in: context)
            } catch {
                AppLogError("Failed to move bookmark: \(error)")
            }
        }
    }

    /// 新原语：**一次调用**同时做「重打整棵子树的 Space / Profile 标签」与「重挂到任意
    /// 文件夹」，而且是一次字段变化，不是删+建——子行的 `guid` 一个都不换。
    ///
    /// 既有的两个原语都表达不了这件事：`moveBookmark` 从行自己身上取 Space 并自述「本
    /// API 今天不支持跨 Space 移动」；`moveBookmarks` 永远落到目标 Space 的 root，从不
    /// 落到某个文件夹。
    ///
    /// `toParentGuid == nil` 表示「直接挂在这个 Space 的 canonical root 下」。
    func moveBookmarkThrowing(guid: String,
                              toParentGuid parentGuid: String?,
                              inSpaceId spaceId: String,
                              index: Int) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            // Profile 由目标 Space 决定（一个 Space 只属于一个 Profile）；目标 Space 行
            // 还不在本地时退回这条行自己的 Profile。
            let targetProfileId = try self.profileId(ofSpaceId: spaceId, in: context)
                ?? self.bookmarkNodeProfileId(guid, in: context)
                ?? Self.defaultProfileId
            try self.moveBookmarkBody(guid,
                                      profileId: targetProfileId,
                                      toParentGuid: parentGuid,
                                      toSpaceId: spaceId,
                                      index: index,
                                      strictParent: true,
                                      in: context)
        }
    }

    /// Single implementation shared by both entry points.
    private func moveBookmarkBody(_ guid: String,
                                  profileId: String,
                                  toParentGuid parentId: String?,
                                  toSpaceId requestedSpaceId: String?,
                                  index newIndex: Int?,
                                  strictParent: Bool,
                                  in context: ModelContext) throws {
        guard let node = try bookmarkNode(with: guid, in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard try !isBookmarkRoot(node, in: context) else {
            throw LocalStoreWriteError.rowIsRoot
        }
        let targetSpaceId = requestedSpaceId ?? node.spaceId ?? Self.defaultSpaceId
        guard let parent = try resolveParent(for: parentId,
                                             profileId: profileId,
                                             spaceId: targetSpaceId,
                                             in: context,
                                             strict: strictParent) else {
            throw LocalStoreWriteError.rowNotFound
        }

        let originalParent = node.parent
        node.parent = parent

        if let originalParent, originalParent.guid != parent.guid {
            let originalSiblings = try children(of: originalParent, in: context)
            normalizeIndexes(for: originalSiblings)
        }

        var siblings = try children(of: parent, in: context).filter { $0.guid != node.guid }
        let targetIndex = Self.clamp(index: newIndex, upperBound: siblings.count)
        siblings.insert(node, at: targetIndex)
        normalizeIndexes(for: siblings)

        let now = Date()
        // 只有显式指定了目标 Space 的调用（也就是同步层）才会重打标签；UI 入口传 nil，
        // 走的还是今天那一行 `node.updatedDate = Date()`。
        if let requestedSpaceId,
           node.spaceId != requestedSpaceId || node.profileId != profileId {
            guard let targetProfile = try profile(with: profileId, in: context, createIfNeeded: true) else {
                throw LocalStoreWriteError.rowNotFound
            }
            try retagBookmarkSubtree(node,
                                     profileId: profileId,
                                     profile: targetProfile,
                                     spaceId: requestedSpaceId,
                                     updatedDate: now,
                                     in: context)
        } else {
            node.updatedDate = now
        }
    }

    /// Moves an explicit bookmark selection as a visual batch.
    ///
    /// When a selected folder also contains selected descendants, only the
    /// selected descendant roots stay inside that folder. Unselected children
    /// are lifted next to their selected parent, and selected descendant
    /// folders shed their own unselected children recursively.
    func moveSelectedBookmarks(_ guids: [String],
                               profileId: String,
                               to parentId: String?,
                               newIndex: Int?) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                var uniqueGuids: [String] = []
                var seenGuids = Set<String>()
                for guid in guids where seenGuids.insert(guid).inserted {
                    uniqueGuids.append(guid)
                }
                guard !uniqueGuids.isEmpty else { return }

                var nodes: [TabDataModel] = []
                for guid in uniqueGuids {
                    guard let node = try self.bookmarkNode(with: guid, in: context),
                          try !self.isBookmarkRoot(node, in: context) else {
                        continue
                    }
                    nodes.append(node)
                }
                guard !nodes.isEmpty else { return }

                let resolveSpaceId = nodes.first?.spaceId ?? Self.defaultSpaceId
                guard let targetParent = try self.resolveParent(for: parentId,
                                                                profileId: profileId,
                                                                spaceId: resolveSpaceId,
                                                                in: context) else {
                    AppLogError("Target parent not found for selected bookmark move")
                    return
                }

                let selectedGuids = Set(nodes.map(\.guid))
                guard !selectedGuids.contains(targetParent.guid) else {
                    AppLogError("Attempted to move selected bookmarks into selected folder")
                    return
                }

                for node in nodes where node.dataType == .bookmarkFolder {
                    if targetParent.guid == node.guid ||
                        self.hasAncestor(of: targetParent, in: [node.guid]) {
                        AppLogError("Attempted to move selected bookmark folder into itself")
                        return
                    }
                }

                let rootNodes = nodes.filter { !self.hasAncestor(of: $0, in: selectedGuids) }
                guard !rootNodes.isEmpty else { return }

                let rootGuids = Set(rootNodes.map(\.guid))
                let originalTargetChildren = try self.children(of: targetParent, in: context)
                let adjustedIndex: Int? = {
                    guard var index = newIndex else { return nil }
                    let upperBound = min(index, originalTargetChildren.count)
                    let movingBeforeIndex = originalTargetChildren
                        .prefix(upperBound)
                        .filter { rootGuids.contains($0.guid) }
                        .count
                    index -= movingBeforeIndex
                    return index
                }()

                var sourceParentsByGuid: [String: TabDataModel] = [:]
                for node in rootNodes {
                    if let originalParent = node.parent {
                        sourceParentsByGuid[originalParent.guid] = originalParent
                    }
                    node.parent = targetParent
                    node.updatedDate = Date()
                }

                for parent in sourceParentsByGuid.values where parent.guid != targetParent.guid {
                    self.normalizeIndexes(for: try self.children(of: parent, in: context))
                }

                var targetSiblings = try self.children(of: targetParent, in: context)
                    .filter { !rootGuids.contains($0.guid) }
                let targetIndex = Self.clamp(index: adjustedIndex ?? Int.max,
                                             upperBound: targetSiblings.count)
                targetSiblings.insert(contentsOf: rootNodes, at: targetIndex)
                self.normalizeIndexes(for: targetSiblings)

                let now = Date()
                for node in rootNodes where node.dataType == .bookmarkFolder {
                    if try self.hasSelectedDescendant(of: node,
                                                      selectedGuids: selectedGuids,
                                                      in: context) {
                        try self.liftUnselectedChildren(from: node,
                                                        selectedGuids: selectedGuids,
                                                        updatedDate: now,
                                                        in: context)
                    }
                }
            } catch {
                AppLogError("Failed to move selected bookmarks: \(error)")
            }
        }
    }

    /// Moves an explicit bookmark selection to another Space's bookmark root.
    /// Selected folder descendants remain inside the folder while unselected
    /// children are lifted beside it, matching bookmark drag behavior.
    func moveBookmarks(_ guids: [String],
                       sourceProfileId: String,
                       toSpaceId targetSpaceId: String,
                       targetProfileId: String) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                // `readOnlyTargetRoot: false` 保留今天的 root 解析，**包括 heal-on-read**：
                // 关系断了但孤儿根还在时，`bookmarkRoot` 会把那个孤儿根认领回来、把重复
                // 根的孩子并过去再删掉重复根，然后这次拖动照常完成。改成纯读会让这一状态
                // 下的用户手势被静默丢弃，而书签就躺在那个孤儿根里。
                try self.moveBookmarksBody(guids,
                                           sourceProfileId: sourceProfileId,
                                           toSpaceId: targetSpaceId,
                                           targetProfileId: targetProfileId,
                                           readOnlyTargetRoot: false,
                                           in: context)
            } catch {
                AppLogError("Failed to move bookmarks to Space: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer (§4.9). 源与目标是同一个 Profile：
    /// 账户里的一条行不会在两个 Chromium profile 之间搬。
    func moveBookmarksThrowing(guids: [String],
                               toSpaceId targetSpaceId: String,
                               profileId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.moveBookmarksBody(guids,
                                       sourceProfileId: profileId,
                                       toSpaceId: targetSpaceId,
                                       targetProfileId: profileId,
                                       readOnlyTargetRoot: true,
                                       in: context)
        }
    }

    /// Single implementation shared by both entry points.
    private func moveBookmarksBody(_ guids: [String],
                                   sourceProfileId: String,
                                   toSpaceId targetSpaceId: String,
                                   targetProfileId: String,
                                   readOnlyTargetRoot: Bool,
                                   in context: ModelContext) throws {
        // 空清单是调用方的 bug，不是一次成功的空操作。
        guard !guids.isEmpty else {
            throw LocalStoreWriteError.noCandidateSurvived
        }
        let targetSpaceIsWritable: Bool
        if targetSpaceId == Self.defaultSpaceId {
            targetSpaceIsWritable = true
        } else {
            targetSpaceIsWritable = try importTargetSpaceIsWritable(profileId: targetProfileId,
                                                                    spaceId: targetSpaceId,
                                                                    in: context)
        }
        guard targetSpaceIsWritable else {
            throw LocalStoreWriteError.targetNotWritable
        }
        // 同步层（`readOnlyTargetRoot: true`）走纯读：`bookmarkRoot(createIfNeeded: true)`
        // 会在每轮都跑的路径上重建一个空 root、认领孤儿根、删重复根，那些都是同步层不想
        // 要的副作用，而且重建之后下面那条守卫永远不可达。UI 路径传 `false`，行为一字
        // 不变——heal-on-read 正是它在孤儿根状态下还能完成拖动的原因。
        guard let targetProfile = try profile(with: targetProfileId,
                                              in: context,
                                              createIfNeeded: true),
              let targetRoot = try targetBookmarkRoot(profileId: targetProfileId,
                                                      spaceId: targetSpaceId,
                                                      readOnly: readOnlyTargetRoot,
                                                      in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }

        let requestedGuids = Set(guids)
        var sourceParentsByGuid: [String: TabDataModel] = [:]
        var movedNodes: [TabDataModel] = []
        var movedGuids = Set<String>()
        let now = Date()

        for guid in guids {
            guard let node = try bookmarkNode(with: guid, in: context),
                  node.profileId == sourceProfileId,
                  try !isBookmarkRoot(node, in: context),
                  !hasAncestor(of: node, in: requestedGuids) else {
                continue
            }
            if node.spaceId == targetSpaceId && node.profileId == targetProfileId {
                continue
            }

            if let parent = node.parent {
                sourceParentsByGuid[parent.guid] = parent
            }
            node.parent = targetRoot
            try retagBookmarkSubtree(node,
                                     profileId: targetProfileId,
                                     profile: targetProfile,
                                     spaceId: targetSpaceId,
                                     updatedDate: now,
                                     in: context)
            movedNodes.append(node)
            movedGuids.insert(node.guid)
        }

        // 上面两处 `continue` 今天完全静默，整批被跳过时旧代码「成功」返回，同步层据此
        // 写下一条永远修不好的基线。
        guard !movedNodes.isEmpty else {
            throw LocalStoreWriteError.noCandidateSurvived
        }
        for parent in sourceParentsByGuid.values where parent.guid != targetRoot.guid {
            let siblings = try children(of: parent, in: context)
            normalizeIndexes(for: siblings)
        }

        var targetSiblings = try children(of: targetRoot, in: context)
            .filter { !movedGuids.contains($0.guid) }
        targetSiblings.append(contentsOf: movedNodes)
        normalizeIndexes(for: targetSiblings)

        for node in movedNodes where node.dataType == .bookmarkFolder {
            if try hasSelectedDescendant(of: node,
                                         selectedGuids: requestedGuids,
                                         in: context) {
                try liftUnselectedChildren(from: node,
                                           selectedGuids: requestedGuids,
                                           updatedDate: now,
                                           in: context)
            }
        }
        targetRoot.updatedDate = now
    }

    /// Clones an explicit bookmark selection into another Space's bookmark
    /// root. A folder with explicitly selected descendants copies only those
    /// descendants; a folder selected by itself still copies its whole tree.
    func cloneBookmarks(_ guids: [String],
                        sourceProfileId: String,
                        toSpaceId targetSpaceId: String,
                        targetProfileId: String) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard !guids.isEmpty else { return }
                let targetSpaceIsWritable: Bool
                if targetSpaceId == Self.defaultSpaceId {
                    targetSpaceIsWritable = true
                } else {
                    targetSpaceIsWritable = try self.importTargetSpaceIsWritable(
                        profileId: targetProfileId,
                        spaceId: targetSpaceId,
                        in: context)
                }
                guard targetSpaceIsWritable else {
                    AppLogError("Target Space not found when cloning bookmarks")
                    return
                }
                guard try self.profile(with: targetProfileId,
                                       in: context,
                                       createIfNeeded: true) != nil,
                      let targetRoot = try self.bookmarkRoot(profileId: targetProfileId,
                                                             spaceId: targetSpaceId,
                                                             in: context,
                                                             createIfNeeded: true) else {
                    AppLogError("Target bookmark root not found when cloning bookmarks")
                    return
                }

                let requestedGuids = Set(guids)
                var sourceRoots: [TabDataModel] = []
                for guid in guids {
                    guard let node = try self.bookmarkNode(with: guid, in: context),
                          node.profileId == sourceProfileId,
                          try !self.isBookmarkRoot(node, in: context),
                          !self.hasAncestor(of: node, in: requestedGuids) else {
                        continue
                    }
                    sourceRoots.append(node)
                }
                guard !sourceRoots.isEmpty else { return }

                let insertionIndex = try self.children(of: targetRoot, in: context).count
                let now = Date()
                for (offset, sourceRoot) in sourceRoots.enumerated() {
                    _ = try self.cloneSelectedBookmarkSubtree(sourceRoot,
                                                              selectedGuids: requestedGuids,
                                                              to: targetRoot,
                                                              at: insertionIndex + offset,
                                                              profileId: targetProfileId,
                                                              spaceId: targetSpaceId,
                                                              createdDate: now,
                                                              in: context)
                }
                targetRoot.updatedDate = now
            } catch {
                AppLogError("Failed to clone bookmarks to Space: \(error)")
            }
        }
    }
    
    /// Updates bookmark title and URL, normalizing the URL when provided.
    /// `secondaryUrl` / `secondaryTitle` are split-bookmark specific: pass
    /// `.some(value)` to set or replace, `.some("")` (for secondaryUrl) to
    /// clear it and turn the bookmark back into a single-URL bookmark, or
    /// `.none` to leave it untouched. Clearing `secondaryUrl` also clears
    /// `secondaryTitle` even if no explicit update was passed for the title.
    func updateBookmark(_ guid: String,
                        profileId: String,
                        title: String?,
                        url: String?,
                        secondaryUrl: String?? = nil,
                        secondaryTitle: String?? = nil) {
        // UI 路径今天静默丢弃空标题（`if let title, !title.isEmpty`）。共享 body 里
        // 「空标题 + `allowsEmptyTitle == false`」的语义是「替换成 URL 字符串」，与
        // create 路径同一条规则，所以这里在入口就把空标题折成「这次不改标题」——UI 的
        // 行为因此一字不变。
        let titleUpdate = (title?.isEmpty == false) ? title : nil
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                try self.updateBookmarkBody(guid,
                                            profileId: profileId,
                                            title: titleUpdate,
                                            url: url,
                                            secondaryUrl: secondaryUrl,
                                            secondaryTitle: secondaryTitle,
                                            allowsEmptyTitle: false,
                                            in: context)
            } catch {
                AppLogError("Failed to update bookmark: \(error)")
            }
        }
    }

    /// Updates the persisted orientation of a split-view bookmark. Ordinary
    /// bookmarks are ignored so layout metadata cannot outlive the second URL.
    func updateBookmarkSplitLayout(_ guid: String, layout: String) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let node = try self.bookmarkNode(with: guid, in: context),
                      node.secondaryUrl != nil,
                      node.layout != layout else {
                    return
                }
                node.layout = layout
                node.updatedDate = Date()
            } catch {
                AppLogError("Failed to update bookmark split layout: \(error)")
            }
        }
    }
    
    /// Throwing sibling used ONLY by the sync layer (§4.9).
    ///
    /// `title == nil` 表示这次不改标题；`title == ""` 配 `allowsEmptyTitle: true` 表示
    /// 把标题清空（远端真的可以有一条空标题的书签）。内容字段真的变了才写
    /// `contentUpdatedDate`。
    func updateBookmarkThrowing(_ guid: String,
                                profileId: String,
                                title: String?,
                                url: String?,
                                secondaryUrl: String?? = nil,
                                secondaryTitle: String?? = nil,
                                allowsEmptyTitle: Bool = true) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.updateBookmarkBody(guid,
                                        profileId: profileId,
                                        title: title,
                                        url: url,
                                        secondaryUrl: secondaryUrl,
                                        secondaryTitle: secondaryTitle,
                                        allowsEmptyTitle: allowsEmptyTitle,
                                        in: context)
        }
    }

    /// Single implementation shared by both entry points.
    ///
    /// **先把全部 URL 解析完再写任何字段**：今天的实现把标题写进 model 之后才校验 URL，
    /// 一次「改标题 + 改成一个非法 URL」于是留下一个半应用状态——标题变了，URL 没变，
    /// 调用方却看不出失败。
    private func updateBookmarkBody(_ guid: String,
                                    profileId: String,
                                    title: String?,
                                    url: String?,
                                    secondaryUrl: String??,
                                    secondaryTitle: String??,
                                    allowsEmptyTitle: Bool,
                                    in context: ModelContext) throws {
        guard let node = try bookmarkNode(with: guid, in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }

        var resolvedURL: URL?
        if let urlString = url {
            guard let newURL = normalizedURL(from: urlString) else {
                throw LocalStoreWriteError.invalidURL
            }
            resolvedURL = newURL
        }
        // 外层「改不改」，内层「改成什么，nil = 清空」。
        var resolvedSecondaryURL: URL??
        if let secondaryUrlOpt = secondaryUrl {
            if let raw = secondaryUrlOpt, !raw.isEmpty {
                // Mirror the primary-URL behavior: a non-empty secondary URL
                // that fails to parse aborts the whole update so the user sees
                // the error and the bookmark does not silently keep its old
                // state mixed with partially-applied changes.
                guard let normalized = normalizedURL(from: raw) else {
                    throw LocalStoreWriteError.invalidURL
                }
                resolvedSecondaryURL = .some(normalized)
            } else {
                resolvedSecondaryURL = .some(nil)
            }
        }

        var contentDidChange = false
        if let resolvedURL, node.url != resolvedURL {
            node.url = resolvedURL
            contentDidChange = true
        }
        if let title {
            // 空标题在 `allowsEmptyTitle == false` 时替换成 URL 字符串，与
            // `insertBookmarkNode` 是同一条规则。
            let effectiveTitle = (title.isEmpty && !allowsEmptyTitle) ? node.url.absoluteString : title
            if node.title != effectiveTitle {
                node.title = effectiveTitle
                contentDidChange = true
            }
        }
        var secondaryUrlClearedInThisUpdate = false
        if let resolvedSecondaryURL {
            if node.secondaryUrl != resolvedSecondaryURL {
                node.secondaryUrl = resolvedSecondaryURL
                contentDidChange = true
            }
            secondaryUrlClearedInThisUpdate = resolvedSecondaryURL == nil
        }
        if secondaryUrlClearedInThisUpdate {
            node.layout = nil
            if node.secondaryTitle != nil {
                node.secondaryTitle = nil
                contentDidChange = true
            }
        } else if let secondaryTitleOpt = secondaryTitle {
            let newSecondaryTitle = (secondaryTitleOpt?.isEmpty == false) ? secondaryTitleOpt : nil
            if node.secondaryTitle != newSecondaryTitle {
                node.secondaryTitle = newSecondaryTitle
                contentDidChange = true
            }
        }

        let now = Date()
        // 只在内容字段真的变化时写：把标题改成同样文字的一次保存，不该让这一行赢下对端
        // 的编辑。
        if contentDidChange {
            node.contentUpdatedDate = now
        }
        node.updatedDate = now
    }

    /// Deletes a bookmark or folder and compacts sibling indexes.
    func deleteBookmark(_ guid: String, profileId: String) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                try self.deleteBookmarkBody(guid, profileId: profileId, in: context)
            } catch {
                AppLogError("Failed to delete bookmark: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer (§4.9).
    func deleteBookmarkThrowing(_ guid: String, profileId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.deleteBookmarkBody(guid, profileId: profileId, in: context)
        }
    }

    /// Single implementation shared by both entry points.
    private func deleteBookmarkBody(_ guid: String,
                                    profileId: String,
                                    in context: ModelContext) throws {
        guard let node = try bookmarkNode(with: guid, in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard try !isBookmarkRoot(node, in: context) else {
            throw LocalStoreWriteError.rowIsRoot
        }

        let parent = node.parent
        context.delete(node)

        if let parent {
            let siblings = try children(of: parent, in: context)
            normalizeIndexes(for: siblings)
        }
    }
    
    @MainActor
    /// Returns all bookmarks directly under the specified parent.
    func fetchBookmarks(parentId: String?,
                        profileId: String,
                        spaceId: String = LocalStore.defaultSpaceId) -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            guard let parent = try resolveParent(for: parentId, profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: false) else {
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
    /// Returns only bookmark rows for the requested Spaces, ordered by most
    /// recently opened first. The scripting API consumes a flat list, so this
    /// intentionally avoids reconstructing the bookmark folder tree.
    func fetchBookmarkTabs(in spaces: [Space]) -> [TabDataModel] {
        guard !spaces.isEmpty, let context = mainContext else { return [] }

        let profileIdBySpaceId = Dictionary(
            uniqueKeysWithValues: spaces.map { ($0.spaceId, $0.profileId) }
        )
        let bookmarkRaw = TabDataType.bookmark.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == bookmarkRaw },
            sortBy: [SortDescriptor(\.lastSeen, order: .reverse)]
        )

        do {
            return try context.fetch(descriptor).filter { bookmark in
                guard let spaceId = bookmark.spaceId,
                      let expectedProfileId = profileIdBySpaceId[spaceId] else {
                    return false
                }
                return bookmark.profileId == expectedProfileId
                    || bookmark.profile?.profileId == expectedProfileId
            }
        } catch {
            AppLogError("Failed to fetch bookmark tabs: \(error)")
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
    /// Publishes bookmark changes from the underlying store, scoped to a Space.
    /// Pre-Spaces rows are backfilled to `LocalStore.defaultSpaceId` by the
    /// V5→V6 migration, so this filter is total — no nil-equivalence rule.
    func bookmarksPublisher(profileId: String,
                            spaceId: String = LocalStore.defaultSpaceId) -> AnyPublisher<[TabDataModel], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[TabDataModel], Never>([])
        let fetchBookmarks: () -> [TabDataModel]? = { [weak self] in
            // Guest migration releases the source container before its window
            // controllers are rebound. A save from the target account can
            // still reach this global notification subscription in that gap.
            // Resolve the context for every fetch instead of retaining the
            // released source context.
            guard let context = self?.mainContext else { return nil }
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
                return bookmarks.filter {
                    $0.profile?.profileId == profileId && $0.spaceId == spaceId
                }
            } catch {
                AppLogError("Failed to fetch bookmarks for publisher: \(error)")
                return []
            }
        }
        
        if let bookmarks = fetchBookmarks() {
            subject.send(bookmarks)
        }
        
        let notificationCenter = NotificationCenter.default
        let cancellable = notificationCenter
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter { Self.notificationContainsChanges($0, matching: {
                guard $0.entity.name == TabDataModel.entityName, let type = Self.tabType(from: $0) else { return false }
                return type == TabDataType.bookmark.rawValue || type == TabDataType.bookmarkFolder.rawValue
            }) }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard let bookmarks = fetchBookmarks() else { return }
                subject.send(bookmarks)
            }
        
        return subject
            .handleEvents(receiveCancel: {
                cancellable.cancel()
            })
            .eraseToAnyPublisher()
    }
}

// MARK: - Bookmark Root (visible to sibling LocalStore extensions)
extension LocalStore {
    /// Whether imported bookmarks may be written into `(profileId, spaceId)`.
    /// The default Space is always allowed (its root is the legacy profile root
    /// and needs no `SpaceModel`). A non-default Space must still have a live
    /// `SpaceModel`: if it was deleted or re-profiled mid-import, writing would
    /// create an orphan root the UI never shows, so the import is dropped.
    func importTargetSpaceIsWritable(profileId: String, spaceId: String, in context: ModelContext) throws -> Bool {
        if spaceId == Self.defaultSpaceId { return true }
        let descriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceId && $0.profileId == profileId }
        )
        return try context.fetchCount(descriptor) > 0
    }

    /// Resolves the hidden root folder for `(profileId, spaceId)`.
    ///
    /// For the default Space, the root is shared with `ProfileModel.bookmarkRoot`
    /// so pre-Spaces data stays reachable without migration data movement —
    /// when a default-space root is materialized we link it on both
    /// `space.bookmarkRoot` and `profile.bookmarkRoot`. For non-default Spaces
    /// a fresh `TabDataModel` folder is created and linked only on the
    /// Space; the Profile-level link is left alone so the default space's
    /// behavior is unchanged.
    func bookmarkRoot(profileId: String,
                      spaceId: String,
                      in context: ModelContext,
                      createIfNeeded: Bool) throws -> TabDataModel? {
        guard let profile = try profile(with: profileId, in: context, createIfNeeded: createIfNeeded) else {
            return nil
        }
        let spaceDescriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceId && $0.profileId == profileId }
        )
        let space = try context.fetch(spaceDescriptor).first

        // Prefer the explicit per-Space root if already linked.
        if let existing = space?.bookmarkRoot {
            return existing
        }
        // Legacy compat: for the default Space, treat the Profile's existing
        // bookmarkRoot as the Space's root and back-link if the Space row
        // is around to receive the pointer.
        if spaceId == Self.defaultSpaceId, let profileRoot = profile.bookmarkRoot {
            space?.bookmarkRoot = profileRoot
            return profileRoot
        }
        // Heal-on-read: an earlier call may have created a root but failed
        // to set the back-link (e.g. because `space` was nil at the time,
        // or because two BookmarkManagers initialised concurrently for
        // the same (profileId, spaceId) — now possible since a Space can
        // host a window in multiple slots simultaneously). Without this
        // recovery, every call here creates ANOTHER orphan root, and the
        // bookmarks publisher returns all of them — visible to the user
        // as duplicate "Bookmarks" folders in non-default Spaces.
        // Reclaim the first matching un-parented bookmarkFolder for this
        // (profileId, spaceId) instead of stamping out a new one. We
        // fetch by the simplest predicate the macro supports (just
        // `type == folder`) and post-filter in Swift to keep the
        // expression checkable — same pattern the publisher uses.
        let folderRaw = TabDataType.bookmarkFolder.rawValue
        let folderDescriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == folderRaw },
            sortBy: [SortDescriptor(\.createdDate)]
        )
        let candidateFolders = try context.fetch(folderDescriptor)
        let orphanRoots = candidateFolders.filter {
            $0.parent == nil &&
            $0.spaceId == spaceId &&
            $0.profileId == profileId &&
            $0.isCreatedByChromium == false
        }
        if let primary = orphanRoots.first {
            // Re-link to the SpaceModel so subsequent calls hit the fast
            // `space?.bookmarkRoot` branch above and stop fetching here.
            space?.bookmarkRoot = primary
            // If earlier races stamped out more than one orphan root,
            // collapse them: reparent every duplicate root's children
            // under the primary, then delete the duplicate. We keep the
            // oldest (createdDate ascending) so any references that
            // already point at the primary stay valid.
            if orphanRoots.count > 1 {
                for duplicate in orphanRoots.dropFirst() {
                    let dupGuid = duplicate.guid
                    let childDescriptor = FetchDescriptor<TabDataModel>(
                        predicate: #Predicate<TabDataModel> { $0.parent?.guid == dupGuid }
                    )
                    // Reparent before deleting. Use `try` (not `try?`): if the
                    // fetch fails we must NOT delete the duplicate, or its
                    // children would be orphaned (SwiftData nullifies their
                    // `parent`) and the bookmarks silently lost. The enclosing
                    // function throws, so the error propagates and the write is
                    // abandoned with the duplicate intact.
                    for child in try context.fetch(childDescriptor) {
                        child.parent = primary
                    }
                    context.delete(duplicate)
                }
            }
            return primary
        }
        guard createIfNeeded else { return nil }
        let now = Date()
        let root = TabDataModel(title: NSLocalizedString("localData.bookmarks.rootFolderTitle", value: "Bookmarks", comment: "Default root bookmarks folder title"),
                                guid: UUID().uuidString,
                                index: 0,
                                url: Self.folderPlaceholderURL,
                                favicon: nil as Data?,
                                createdDate: now,
                                updatedDate: now)
        root.dataType = TabDataType.bookmarkFolder
        root.profileId = profileId
        root.profile = profile
        root.spaceId = spaceId
        root.isCreatedByChromium = false
        context.insert(root)
        space?.bookmarkRoot = root
        // Mirror onto the Profile only when this is the first time the
        // default Space materializes; non-default spaces must not pollute
        // the profile-wide pointer or imports/legacy lookups will jump
        // spaces unexpectedly.
        if spaceId == Self.defaultSpaceId, profile.bookmarkRoot == nil {
            profile.bookmarkRoot = root
        }
        return root
    }

    /// 纯读版的 root 解析：按 `SpaceModel.bookmarkRoot` 关系取，取不到返回 nil，
    /// **一个字节都不写**。
    ///
    /// 为什么不能在同步轮的读路径上用 `bookmarkRoot(…)`：它在 `guard createIfNeeded`
    /// **之前**就有 heal-on-read——`space?.bookmarkRoot = primary` 与
    /// `context.delete(duplicate)`。放进每轮都跑的读路径等于每轮都可能在主 context 上
    /// 删行。治愈逻辑原样留在 `bookmarkRoot` 里，由 UI 路径继续触发。
    ///
    /// 默认 Space 的那条回落是读，不是写：默认 Space 的 root 物理上就是 legacy 的
    /// `ProfileModel.bookmarkRoot`，同一棵树有两个指针。这里只读第二个指针，不回链。
    func existingBookmarkRoot(profileId: String,
                              spaceId: String,
                              in context: ModelContext) throws -> TabDataModel? {
        let spaceDescriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate<SpaceModel> { $0.spaceId == spaceId && $0.profileId == profileId }
        )
        if let linked = try context.fetch(spaceDescriptor).first?.bookmarkRoot {
            return linked
        }
        guard spaceId == Self.defaultSpaceId else { return nil }
        return try profile(with: profileId, in: context, createIfNeeded: false)?.bookmarkRoot
    }

    /// 全部书签与文件夹行，**一次** fetch 带关系预取，给快照 / 差分 / index 投影三个
    /// 消费者复用。
    ///
    /// 谓词把 raw value 先提成局部 `let`：`TabDataModel.type` 是裸 `Int`，`dataType`
    /// 是 extension 上的计算属性，`#Predicate` 看不见它。
    func allBookmarkModels(in context: ModelContext) throws -> [TabDataModel] {
        let bookmarkRaw = TabDataType.bookmark.rawValue
        let folderRaw = TabDataType.bookmarkFolder.rawValue
        var descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == bookmarkRaw || $0.type == folderRaw }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.parent, \.profile]
        return try context.fetch(descriptor)
    }

    /// 本机**所有**带账户级身份的书签 / 文件夹行的 `syncId`，**不做任何根过滤**。
    ///
    /// 与 `allBookmarkModels(in:)` 的关系正是 §4.7 与 §4.8 的分工：快照要的是「同步层认领
    /// 哪些行」，所以它从 canonical root 往下走、把孤儿根整棵排除；而差分的 `locals` 要的是
    /// 「这条身份在本机还有没有行」。两者混用会删掉账户数据——一条曾经发布过、后来它那个根
    /// 不再是 Space 的 canonical root 的行（并发初始化正好造出这种状态，heal-on-read 就是
    /// 为它存在的），会从快照里消失而游标还在，于是差分给它和它每一个后代发 tombstone。
    ///
    /// 「同步层不认领它」与「账户应该忘掉它」是两句不同的话（R-exec-4）。
    func allBookmarkSyncIds(in context: ModelContext) throws -> Set<String> {
        let bookmarkRaw = TabDataType.bookmark.rawValue
        let folderRaw = TabDataType.bookmarkFolder.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> {
                ($0.type == bookmarkRaw || $0.type == folderRaw) && $0.syncId != nil
            }
        )
        return Set(try context.fetch(descriptor).compactMap(\.syncId))
    }

    /// 每一对 (profileId, spaceId) 的 canonical root 的 guid。
    ///
    /// **绝不逐行调 `isBookmarkRoot(_:in:)`**：那个函数每次都 fetch 全部 `ProfileModel`
    /// 与全部 `SpaceModel`，在一棵上千条的树上是平方级。这里每对 Space 只解析一次。
    func canonicalRootGuids(in context: ModelContext) throws -> Set<String> {
        var pairs: [(profileId: String, spaceId: String)] = []
        for space in try context.fetch(FetchDescriptor<SpaceModel>()) {
            pairs.append((space.profileId, space.spaceId))
        }
        for profile in try context.fetch(FetchDescriptor<ProfileModel>()) {
            pairs.append((profile.profileId, Self.defaultSpaceId))
        }
        var guids = Set<String>()
        var seen = Set<String>()
        for pair in pairs {
            guard seen.insert("\(pair.profileId)\u{0}\(pair.spaceId)").inserted else { continue }
            if let root = try existingBookmarkRoot(profileId: pair.profileId,
                                                   spaceId: pair.spaceId,
                                                   in: context) {
                guids.insert(root.guid)
            }
        }
        return guids
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

        // 次键 `\.guid` 与 `pinnedTabs(...)` 一致。没有它的时候，一条被排除的兄弟
        // （停放 / 待删 / 还没身份）留着的过期 `index` 会与新写的撞上，撞上的两行顺序
        // 随 fetch 而变，于是出站 pass 每轮给其中一条算出新 rank 发出去，对端应用后顺序
        // 又翻回来——每轮两条无谓的 commit，永远。有了次键，index 撞车最坏只是「不对」，
        // 而不是「不确定」。
        let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index), SortDescriptor(\.guid)]
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

    func hasAncestor(of node: TabDataModel, in guids: Set<String>) -> Bool {
        var parent = node.parent
        while let current = parent {
            if guids.contains(current.guid) {
                return true
            }
            parent = current.parent
        }
        return false
    }

    func hasSelectedDescendant(of folder: TabDataModel,
                               selectedGuids: Set<String>,
                               in context: ModelContext) throws -> Bool {
        for child in try children(of: folder, in: context) {
            if selectedGuids.contains(child.guid) {
                return true
            }
            if child.dataType == .bookmarkFolder,
               try hasSelectedDescendant(of: child,
                                         selectedGuids: selectedGuids,
                                         in: context) {
                return true
            }
        }
        return false
    }

    func selectedDescendantRoots(under node: TabDataModel,
                                 selectedGuids: Set<String>,
                                 in context: ModelContext) throws -> [TabDataModel] {
        guard node.dataType == .bookmarkFolder else { return [] }
        var roots: [TabDataModel] = []
        for child in try children(of: node, in: context) {
            if selectedGuids.contains(child.guid) {
                roots.append(child)
            } else {
                roots.append(contentsOf: try selectedDescendantRoots(under: child,
                                                                     selectedGuids: selectedGuids,
                                                                     in: context))
            }
        }
        return roots
    }

    func moveBookmarkNode(_ node: TabDataModel,
                          to parent: TabDataModel,
                          at index: Int,
                          updatedDate: Date,
                          in context: ModelContext) throws {
        let originalParent = node.parent
        node.parent = parent
        node.updatedDate = updatedDate

        if let originalParent, originalParent.guid != parent.guid {
            let originalSiblings = try children(of: originalParent, in: context)
            normalizeIndexes(for: originalSiblings)
        }

        var siblings = try children(of: parent, in: context).filter { $0.guid != node.guid }
        let targetIndex = Self.clamp(index: index, upperBound: siblings.count)
        siblings.insert(node, at: targetIndex)
        normalizeIndexes(for: siblings)
    }

    func liftUnselectedChildren(from folder: TabDataModel,
                                selectedGuids: Set<String>,
                                updatedDate: Date,
                                in context: ModelContext) throws {
        guard let parent = folder.parent else { return }

        let originalChildren = try children(of: folder, in: context)
        var siblingOffsetAfterFolder = 1

        for child in originalChildren {
            if selectedGuids.contains(child.guid) {
                if child.dataType == .bookmarkFolder,
                   try hasSelectedDescendant(of: child,
                                             selectedGuids: selectedGuids,
                                             in: context) {
                    try liftUnselectedChildren(from: child,
                                               selectedGuids: selectedGuids,
                                               updatedDate: updatedDate,
                                               in: context)
                }
                continue
            }

            let selectedDescendantRoots = try selectedDescendantRoots(under: child,
                                                                      selectedGuids: selectedGuids,
                                                                      in: context)
            if !selectedDescendantRoots.isEmpty {
                let currentFolderChildren = try children(of: folder, in: context)
                let childIndex = currentFolderChildren.firstIndex { $0.guid == child.guid }
                    ?? currentFolderChildren.count
                var descendantInsertionIndex = childIndex
                for descendant in selectedDescendantRoots {
                    try moveBookmarkNode(descendant,
                                         to: folder,
                                         at: descendantInsertionIndex,
                                         updatedDate: updatedDate,
                                         in: context)
                    descendantInsertionIndex += 1
                    if descendant.dataType == .bookmarkFolder,
                       try hasSelectedDescendant(of: descendant,
                                                 selectedGuids: selectedGuids,
                                                 in: context) {
                        try liftUnselectedChildren(from: descendant,
                                                   selectedGuids: selectedGuids,
                                                   updatedDate: updatedDate,
                                                   in: context)
                    }
                }
            }

            let parentChildren = try children(of: parent, in: context)
            guard let folderIndex = parentChildren.firstIndex(where: { $0.guid == folder.guid }) else {
                continue
            }
            try moveBookmarkNode(child,
                                 to: parent,
                                 at: folderIndex + siblingOffsetAfterFolder,
                                 updatedDate: updatedDate,
                                 in: context)
            siblingOffsetAfterFolder += 1
        }

        normalizeIndexes(for: try children(of: folder, in: context))
    }

    func retagBookmarkSubtree(_ node: TabDataModel,
                              profileId: String,
                              profile: ProfileModel,
                              spaceId: String,
                              updatedDate: Date,
                              in context: ModelContext) throws {
        node.profileId = profileId
        node.profile = profile
        node.spaceId = spaceId
        node.updatedDate = updatedDate
        for child in try children(of: node, in: context) {
            try retagBookmarkSubtree(child,
                                     profileId: profileId,
                                     profile: profile,
                                     spaceId: spaceId,
                                     updatedDate: updatedDate,
                                     in: context)
        }
    }

    func cloneBookmarkSubtree(_ source: TabDataModel,
                              to parent: TabDataModel,
                              at index: Int,
                              profileId: String,
                              spaceId: String,
                              createdDate: Date,
                              in context: ModelContext) throws -> TabDataModel {
        let clone: TabDataModel
        if source.dataType == .bookmarkFolder {
            clone = try insertDirectoryNode(title: source.title,
                                            profileId: profileId,
                                            parent: parent,
                                            index: index,
                                            guid: nil,
                                            spaceId: spaceId,
                                            now: createdDate,
                                            in: context)
            for (childIndex, child) in try children(of: source, in: context).enumerated() {
                _ = try cloneBookmarkSubtree(child,
                                             to: clone,
                                             at: childIndex,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             createdDate: createdDate,
                                             in: context)
            }
        } else {
            clone = try insertBookmarkNode(title: source.title,
                                           profileId: profileId,
                                           url: source.url,
                                           parent: parent,
                                           index: index,
                                           guid: nil,
                                           spaceId: spaceId,
                                           secondaryUrl: source.secondaryUrl,
                                           secondaryTitle: source.secondaryTitle,
                                           layout: source.layout,
                                           favicon: source.favicon,
                                           now: createdDate,
                                           in: context)
            clone.lastSeen = source.lastSeen
        }
        clone.overrideTitle = source.overrideTitle
        clone.source = source.source
        clone.icon = source.icon
        return clone
    }

    func cloneSelectedBookmarkSubtree(_ source: TabDataModel,
                                      selectedGuids: Set<String>,
                                      to parent: TabDataModel,
                                      at index: Int,
                                      profileId: String,
                                      spaceId: String,
                                      createdDate: Date,
                                      in context: ModelContext) throws -> TabDataModel {
        guard source.dataType == .bookmarkFolder,
              try hasSelectedDescendant(of: source,
                                        selectedGuids: selectedGuids,
                                        in: context) else {
            return try cloneBookmarkSubtree(source,
                                            to: parent,
                                            at: index,
                                            profileId: profileId,
                                            spaceId: spaceId,
                                            createdDate: createdDate,
                                            in: context)
        }

        let clone = try insertDirectoryNode(title: source.title,
                                            profileId: profileId,
                                            parent: parent,
                                            index: index,
                                            guid: nil,
                                            spaceId: spaceId,
                                            now: createdDate,
                                            in: context)
        let selectedChildren = try selectedDescendantRoots(under: source,
                                                           selectedGuids: selectedGuids,
                                                           in: context)
        for (childIndex, child) in selectedChildren.enumerated() {
            _ = try cloneSelectedBookmarkSubtree(child,
                                                 selectedGuids: selectedGuids,
                                                 to: clone,
                                                 at: childIndex,
                                                 profileId: profileId,
                                                 spaceId: spaceId,
                                                 createdDate: createdDate,
                                                 in: context)
        }
        clone.overrideTitle = source.overrideTitle
        clone.source = source.source
        clone.icon = source.icon
        return clone
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
                            secondaryUrl: URL? = nil,
                            secondaryTitle: String? = nil,
                            layout: String? = nil,
                            favicon: Data? = nil,
                            allowsEmptyTitle: Bool = false,
                            now: Date,
                            in context: ModelContext) throws -> TabDataModel {
        // 默认（UI 路径）行为一字不变：空标题替换成 URL 字符串。同步层传 `true`，因为
        // 一条 `title == ""` 的远端 create 若落成 URL 字符串，刚写下的 `reconciled` 就与
        // 行对不上，下一轮快照判成本机改了标题、盖 `now`、把 URL 当标题发回去盖掉对端刚
        // 清空的值。
        let resolvedTitle: String
        if let title, !title.isEmpty || allowsEmptyTitle {
            resolvedTitle = title
        } else {
            resolvedTitle = url.absoluteString
        }
        let bookmark = TabDataModel(title: resolvedTitle,
                                    guid: guid ?? UUID().uuidString,
                                    index: 0,
                                    url: url,
                                    favicon: favicon,
                                    createdDate: now,
                                    updatedDate: now)
        bookmark.dataType = TabDataType.bookmark
        bookmark.spaceId = spaceId ?? parent.spaceId
        bookmark.profileId = profileId
        bookmark.profile = parent.profile
        bookmark.isCreatedByChromium = false
        bookmark.secondaryUrl = secondaryUrl
        bookmark.secondaryTitle = (secondaryTitle?.isEmpty == false) ? secondaryTitle : nil
        bookmark.layout = secondaryUrl == nil ? nil : layout
        context.insert(bookmark)
        try insert(node: bookmark, to: parent, at: index, in: context)
        return bookmark
    }
    
    /// `strict: false` 是今天的行为：一个解析不到 / 不是文件夹的父**无日志地**落回
    /// Space root。对 UI 这是善意容错。
    ///
    /// `strict: true` 只给同步层：落回 root 在那边意味着「把一条书签建到了账户没要求的
    /// 位置」，而下一轮差分会把这个位置当成本机意图发回去，覆盖对端正确的
    /// `parent_uuid`。
    func resolveParent(for parentId: String?,
                       profileId: String,
                       spaceId: String = LocalStore.defaultSpaceId,
                       in context: ModelContext,
                       createIfNeeded: Bool = true,
                       strict: Bool = false) throws -> TabDataModel? {
        if let parentId {
            if let node = try bookmarkNode(with: parentId, in: context),
               node.dataType == .bookmarkFolder {
                return node
            }
            if strict {
                throw LocalStoreWriteError.rowNotFound
            }
        }
        return try bookmarkRoot(profileId: profileId,
                                spaceId: spaceId,
                                in: context,
                                createIfNeeded: createIfNeeded)
    }

    /// `moveBookmarksBody` 的目标 root 解析。
    ///
    /// `readOnly: false`（UI 拖放路径）是今天的行为，一字不变：`bookmarkRoot` 在
    /// `guard createIfNeeded` **之前**还会做 heal-on-read——把一个「关系断了但还在」的
    /// 孤儿根认领回来、把重复根的孩子并到主根上再删掉重复根。那正是这条路径在并发
    /// 初始化留下孤儿根之后仍能完成拖动的原因，换成纯读会让用户的手势被静默丢弃。
    ///
    /// `readOnly: true`（同步层）走 `existingBookmarkRoot`：那些治愈动作会在每轮都跑的
    /// 路径上写主 context，而且「重建一个空 root 再搬进去」之后「目标 root 缺失」这条
    /// 守卫永远不可达。
    func targetBookmarkRoot(profileId: String,
                            spaceId: String,
                            readOnly: Bool,
                            in context: ModelContext) throws -> TabDataModel? {
        if readOnly {
            return try existingBookmarkRoot(profileId: profileId, spaceId: spaceId, in: context)
        }
        return try bookmarkRoot(profileId: profileId,
                                spaceId: spaceId,
                                in: context,
                                createIfNeeded: true)
    }

    /// 这条行自己的 `profileId`，不存在就返回 nil。
    func bookmarkNodeProfileId(_ guid: String, in context: ModelContext) throws -> String? {
        try bookmarkNode(with: guid, in: context)?.profileId
    }

    /// 一个 Space 只属于一个 Profile。Space 行还不在本地时返回 nil。
    func profileId(ofSpaceId spaceId: String, in context: ModelContext) throws -> String? {
        let descriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate<SpaceModel> { $0.spaceId == spaceId }
        )
        return try context.fetch(descriptor).first?.profileId
    }

    /// 用户输入的 URL 归一化。`URLProcessor.processUserInput` 会把不像 URL 的东西变成
    /// 搜索，所以它**只在 UI 路径上**跑；同步层的 throwing 兄弟直接收 `URL`。
    func userInputBookmarkURL(from raw: String?) throws -> URL {
        guard let normalized = normalizedURL(from: raw),
              let processed = URL(string: URLProcessor.processUserInput(normalized.absoluteString)) else {
            throw LocalStoreWriteError.invalidURL
        }
        return processed
    }

    /// Returns true if `node` is the hidden top-level folder for any Profile
    /// or Space — i.e. moving/deleting it is illegal because the bookmark tree
    /// would lose its root.
    func isBookmarkRoot(_ node: TabDataModel, in context: ModelContext) throws -> Bool {
        let profileDescriptor: FetchDescriptor<ProfileModel> = FetchDescriptor<ProfileModel>()
        if try context.fetch(profileDescriptor).contains(where: { $0.bookmarkRoot?.guid == node.guid }) {
            return true
        }
        let spaceDescriptor: FetchDescriptor<SpaceModel> = FetchDescriptor<SpaceModel>()
        return try context.fetch(spaceDescriptor).contains(where: { $0.bookmarkRoot?.guid == node.guid })
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
        case 0:  // Chrome
            return 1
        case 3:  // Safari
            return 2
        default:
            return inheritedSource == 0 ? 1 : inheritedSource
        }
    }

    /// Where an imported-browser folder sorts among its kind at the Space root:
    /// Chrome 0, Arc 1, Dia 2, Safari 3 — the order of the import window's
    /// rows. Nil for any other folder.
    static func importedBrowserFolderRank(for title: String, source: Int) -> Int? {
        if source == 3 || title == importedFromArcFolderTitle {
            return 1
        }
        if title == importedFromDiaFolderTitle {
            return 2
        }

        let lowercasedTitle = title.lowercased()
        if lowercasedTitle.contains("chrome") {
            return 0
        }
        if lowercasedTitle.contains("safari") {
            return 3
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

// MARK: - 批量插入（同步层落地专用）

extension LocalStore {
    /// 一条待批量插入的书签 / 文件夹行。`index` 由调用方按 §4.10 的 rank 投影预先算好。
    struct BulkBookmarkInsert {
        var guid: String
        /// 账户级同步身份。与行在同一个事务里写下，落地路径没有第二次写可以失败。
        var syncId: String?
        var title: String
        /// 文件夹带占位 URL。
        var url: URL
        var index: Int
        var isFolder: Bool
        /// nil = 直接挂在这个 Space 的 canonical root 下。
        var parentGuid: String?
        var spaceId: String
        var profileId: String
        var createdDate: Date
        var contentUpdatedDate: Date?
        var secondaryUrl: URL?
        var secondaryTitle: String?
        /// `TabSource` 的 raw value。
        var source: Int

        init(guid: String,
             syncId: String? = nil,
             title: String,
             url: URL,
             index: Int,
             isFolder: Bool,
             parentGuid: String?,
             spaceId: String,
             profileId: String,
             createdDate: Date,
             contentUpdatedDate: Date? = nil,
             secondaryUrl: URL? = nil,
             secondaryTitle: String? = nil,
             source: Int = 0) {
            self.guid = guid
            self.syncId = syncId
            self.title = title
            self.url = url
            self.index = index
            self.isFolder = isFolder
            self.parentGuid = parentGuid
            self.spaceId = spaceId
            self.profileId = profileId
            self.createdDate = createdDate
            self.contentUpdatedDate = contentUpdatedDate
            self.secondaryUrl = secondaryUrl
            self.secondaryTitle = secondaryTitle
            self.source = source
        }
    }

    /// 一次写 N 条兄弟，**index 预先算好、不走 `insert(node:to:at:in:)`**，被触及的父
    /// 收集起来，**在事务末尾对每个父跑一次** `normalizeIndexes`。
    ///
    /// 既有的 `insertBookmarkNode` / `insertDirectoryNode` 都以 `insert(node:to:at:in:)`
    /// 收尾，而它每插一行就 fetch 一次该父的孩子并对整个兄弟列表跑一次
    /// `normalizeIndexes`——250 条落进同一个文件夹是 250 次 fetch 加 250 次全量重排，在
    /// 一个文件夹里是平方级，而且全在 §4.5 要求的那一个事务里、整轮都放不掉。UI 路径
    /// 继续用 `insert(node:to:at:in:)`。
    func insertBookmarksBulkThrowing(_ rows: [BulkBookmarkInsert]) async throws {
        _ = try await performBackgroundWriteAndWaitThrowing { context in
            try self.insertBookmarksBulkBody(rows, in: context)
        }
    }

    /// 返回值是**被重排过的父的个数**，也就是 `normalizeIndexes` 被调用的次数。
    @discardableResult
    func insertBookmarksBulkBody(_ rows: [BulkBookmarkInsert],
                                 in context: ModelContext) throws -> Int {
        guard !rows.isEmpty else { return 0 }
        var profilesById: [String: ProfileModel] = [:]
        var insertedByGuid: [String: TabDataModel] = [:]
        var touchedParents: [String: TabDataModel] = [:]

        for row in rows {
            let profile: ProfileModel
            if let cached = profilesById[row.profileId] {
                profile = cached
            } else {
                guard let resolved = try self.profile(with: row.profileId,
                                                      in: context,
                                                      createIfNeeded: true) else {
                    throw LocalStoreWriteError.rowNotFound
                }
                profilesById[row.profileId] = resolved
                profile = resolved
            }

            // 同一批里父可以排在子前面（§4.4 的拓扑顺序保证了这一点），所以先查本批已插
            // 入的行，再查库里已有的行。
            let parent: TabDataModel
            if let parentGuid = row.parentGuid {
                if let pending = insertedByGuid[parentGuid] {
                    parent = pending
                } else if let existing = try bookmarkNode(with: parentGuid, in: context),
                          existing.dataType == .bookmarkFolder {
                    parent = existing
                } else {
                    throw LocalStoreWriteError.rowNotFound
                }
            } else {
                guard let root = try existingBookmarkRoot(profileId: row.profileId,
                                                          spaceId: row.spaceId,
                                                          in: context) else {
                    throw LocalStoreWriteError.rowNotFound
                }
                parent = root
            }

            let node = TabDataModel(title: row.title,
                                    guid: row.guid,
                                    index: row.index,
                                    url: row.url,
                                    favicon: nil as Data?,
                                    createdDate: row.createdDate,
                                    updatedDate: row.createdDate)
            node.dataType = row.isFolder ? TabDataType.bookmarkFolder : TabDataType.bookmark
            node.spaceId = row.spaceId
            node.profileId = row.profileId
            node.profile = profile
            node.isCreatedByChromium = false
            node.secondaryUrl = row.secondaryUrl
            node.secondaryTitle = row.secondaryTitle
            node.source = row.source
            node.syncId = row.syncId
            node.contentUpdatedDate = row.contentUpdatedDate
            context.insert(node)
            node.parent = parent

            insertedByGuid[row.guid] = node
            touchedParents[parent.guid] = parent
        }

        for parent in touchedParents.values {
            normalizeIndexes(for: try children(of: parent, in: context))
        }
        return touchedParents.count
    }
}

// MARK: - 一轮远端落地（同步层专用，§4.5 / R-exec-2）

/// §4.5 要求一轮远端落地的**多条**行用**一个**事务：抛错 = 一条都没落，部分成功不存在。
///
/// 已有的 throwing 兄弟每一个都自己开一次 `performBackgroundWriteAndWaitThrowing`
/// （`LocalStore.swift:466`），而那个入口把作业 yield 进串行写队列再等写 actor——把它们
/// 挨个调是 N 个事务，套在一个写块里则直接死锁（嵌套的那次排在正等着它的块后面）。
///
/// **必须写在本文件里**：`moveBookmarkBody` / `updateBookmarkBody` / `deleteBookmarkBody`
/// 与 `bookmarkNode` / `children` / `normalizeIndexes` 全是 `private`，别的文件够不着。
/// 与 Task 2b 的 pin 侧同一条理由。
///
/// **既有的 throwing 兄弟一个都不动**：它们继续服务单条落地，这里只是多一个批量入口，
/// 且调的是同一批 body——没有第二份实现，UI 路径与同步路径不可能漂移。
extension LocalStore {
    /// 一整批已排好序的书签落地操作，**一个**事务。
    ///
    /// `ops` 必须已经按 §4.4 的三相拓扑序排好（`BookmarkApplyBatch` 负责），这里**一条都
    /// 不重排**。
    ///
    /// 三件事在这一个块里：
    /// 1. **导入锁在写块内部再读一次**（§4.9 第 3 条）。轮首那次读只是优化——「读完之后
    ///    导入才开始」那个边沿只有在事务里重读才挡得住。占用中就整批抛
    ///    `targetNotWritable`，事务回滚，引擎下一轮重试，等价于「该 Space 的书签本轮整体
    ///    停放」。
    /// 2. **连续的 create 攒成一次批量插入**。`insertBookmarksBulkBody` 把 index 预先算好、
    ///    只在末尾对每个被触及的父跑一次 `normalizeIndexes`；逐条插会让 250 条落进同一个
    ///    文件夹变成 250 次 fetch 加 250 次全量重排。相邻的 create 在三相排序里本来就是连着
    ///    的，所以攒批**不改变任何一条操作的相对次序**。
    /// 3. **末尾对每个被触及的父跑一次 `normalizeIndexes`**（§4.10）：一批操作可能反复动
    ///    同一个父，每条各自那次重排只保证它自己那一刻是稠密的。
    ///
    /// 带 `contentUpdatedDate` 的远端 create 走批量插入那条路：两个单条 create 兄弟的参数表
    /// 里没有这一列（Task 2a 第 3 条事实）。
    func applyBookmarkSyncBatchThrowing(_ ops: [BookmarkApplyOp]) async throws {
        guard !ops.isEmpty else { return }
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyBookmarkSyncBatchBody(ops, in: context)
        }
    }

    /// 退出账户 / 重置同步状态时抹掉全部书签身份（§9.2）。**一次批量写**：逐条一个事务
    /// 在一棵上千条的树上是上千个事务。
    ///
    /// 只碰书签与文件夹行：`syncId` 这一列住在 `TabDataModel` 上，而 pin 的身份是
    /// `(pinLineageId, owner)`（§3.2），不走这一列。
    @discardableResult
    func clearAllBookmarkSyncIdsThrowing() async throws -> Int {
        try await performBackgroundWriteAndWaitThrowing { context in
            let bookmarkRaw = TabDataType.bookmark.rawValue
            let folderRaw = TabDataType.bookmarkFolder.rawValue
            let descriptor = FetchDescriptor<TabDataModel>(
                predicate: #Predicate<TabDataModel> {
                    ($0.type == bookmarkRaw || $0.type == folderRaw) && $0.syncId != nil
                }
            )
            let rows = try context.fetch(descriptor)
            for row in rows { row.syncId = nil }
            return rows.count
        }
    }

    /// 事务体。分出来只为可读性，没有第二个调用方。
    private func applyBookmarkSyncBatchBody(_ ops: [BookmarkApplyOp],
                                            in context: ModelContext) throws {
        try refuseIfImporting(ops, in: context)

        // 被触及的父，末尾统一重排一次。**记 guid，不记 model**：同一批里子先于父被删，
        // 一个攥在手上的 model 到事务末尾可能已经是条删掉的行，再读它的属性是未定义的。
        var touchedParentGuids = Set<String>()
        func remember(_ node: TabDataModel?) {
            guard let node else { return }
            touchedParentGuids.insert(node.guid)
        }

        var pendingCreates: [BulkBookmarkInsert] = []
        func flushCreates() throws {
            guard !pendingCreates.isEmpty else { return }
            try insertBookmarksBulkBody(pendingCreates, in: context)
            for row in pendingCreates {
                guard let parentGuid = row.parentGuid else { continue }
                touchedParentGuids.insert(parentGuid)
            }
            pendingCreates.removeAll(keepingCapacity: true)
        }

        for op in ops {
            switch op {
            case .create(let row):
                pendingCreates.append(Self.bulkInsert(from: row))

            case .claim(let guid, let syncId):
                try flushCreates()
                guard let node = try bookmarkNode(with: guid, in: context) else {
                    throw LocalStoreWriteError.rowNotFound
                }
                // `bookmarkNode(with:)` 按 guid 匹配**任何** `TabDataModel`，包括 tab 与
                // pin 行。往一条非书签行上写书签身份，下一轮快照读不到它、差分判成「本机
                // 没有这一行」，于是给对端那条实体发 tombstone。
                guard node.dataType == .bookmark || node.dataType == .bookmarkFolder else {
                    throw LocalStoreWriteError.rowNotFound
                }
                // 一条行的身份只认领一次（§6.1）。重复认领同一个 uuid 是幂等的，换一个
                // uuid 则是 fail-closed：旧身份会在本机瞬间失去对应行，而差分对此的回答是
                // 删掉对端那条实体。今天这条不变量由协议之上的规划器守着，这里是
                // R-M3-3-14 要求的那道「静默结果必须变成抛错」的闸。
                guard node.syncId == nil || node.syncId == syncId else {
                    throw LocalStoreWriteError.rowAlreadyMapped
                }
                // 认领不是一次编辑：只写身份，`contentUpdatedDate` 不为它而动。
                node.syncId = syncId

            case .move(let guid, let parentGuid, let spaceId, let index):
                try flushCreates()
                // 搬走之后旧父也要重排，所以先把它记下来。
                remember(try bookmarkNode(with: guid, in: context)?.parent)
                // Profile 由目标 Space 决定（一个 Space 只属于一个 Profile）；目标 Space
                // 行还不在本地时退回这条行自己的 Profile。与 `moveBookmarkThrowing`
                // （:603）逐字同一段。
                let targetProfileId = try profileId(ofSpaceId: spaceId, in: context)
                    ?? bookmarkNodeProfileId(guid, in: context)
                    ?? Self.defaultProfileId
                try moveBookmarkBody(guid,
                                     profileId: targetProfileId,
                                     toParentGuid: parentGuid,
                                     toSpaceId: spaceId,
                                     index: index,
                                     strictParent: true,
                                     in: context)
                remember(try bookmarkNode(with: guid, in: context)?.parent)

            case .update(let guid, let fields):
                try flushCreates()
                // 外层「改不改」，内层「改成什么」。`title` 的内层 nil 是「清空」——远端
                // 真的可以有一条空标题的书签，所以 `allowsEmptyTitle` **显式**传 `true`
                // （Task 2a 第 4 条事实：默认值会变，同步层每次自己写出来）。`url` 的内层
                // nil 是「不动」：一条书签丢不掉它的 URL。
                // `updateBookmarkBody` 的 `profileId` 形参在它的实现里一次都没有被读到，
                // 所以这里不再为了算一个没人看的实参多跑一次 `bookmarkNode` fetch——一批
                // 250 条 update 就是 250 次可以省掉的查询。
                try updateBookmarkBody(guid,
                                       profileId: Self.defaultProfileId,
                                       title: fields.title.map { $0 ?? "" },
                                       url: fields.url.flatMap { $0?.absoluteString },
                                       secondaryUrl: fields.secondaryUrl.map { $0?.absoluteString },
                                       secondaryTitle: fields.secondaryTitle,
                                       allowsEmptyTitle: true,
                                       in: context)

            case .delete(let guid):
                try flushCreates()
                guard let node = try bookmarkNode(with: guid, in: context) else {
                    throw LocalStoreWriteError.rowNotFound
                }
                // `deleteBookmarkBody` 就是一句 `context.delete(node)`，而
                // `TabDataModel.children` 带 `@Relationship(deleteRule: .cascade)`
                // （`TabDataModelSchemaV10.swift:112`）——一次删除会把整棵子树无声地带走。
                //
                // 这一批自己点名的后代是安全的：三相排序里 delete 相子先于父，而被「提走」
                // 的孩子在第一相就已经改挂到别处。**挡的是这一批从没提过的后代**，尤其是
                // 本地独有、从没发布过的行：R-M3-3-17 要求引擎先把它们删掉或提到 Space
                // root，漏一个就在这个事务里静默死掉，没有计数也没有日志。正常运行时这条
                // 守卫永远不触发，触发就整批回滚重试，而不是销毁用户数据。
                if node.dataType == .bookmarkFolder,
                   try !children(of: node, in: context).isEmpty {
                    throw LocalStoreWriteError.folderNotEmpty
                }
                remember(node.parent)
                try deleteBookmarkBody(guid, profileId: node.profileId ?? Self.defaultProfileId,
                                       in: context)
            }
        }
        try flushCreates()

        // §4.10：投影按父运行一次。本批次自己删掉的父在这里查不回来，跳过——它的孩子已经
        // 随级联一起走了。
        for parentGuid in touchedParentGuids {
            guard let parent = try bookmarkNode(with: parentGuid, in: context) else { continue }
            normalizeIndexes(for: try children(of: parent, in: context))
        }
    }

    /// 本批次碰到的任何一个 Space 正在被导入 ⇒ 整批不落地。
    ///
    /// `claim` / `update` / `delete` 身上只有 guid，所以它们的 Space 在**事务内**按行查，
    /// 而不是让调用方从一份轮首的快照里猜——那份快照到这一刻可能已经过期。
    private func refuseIfImporting(_ ops: [BookmarkApplyOp], in context: ModelContext) throws {
        var spaceIds = Set<String>()
        for op in ops {
            switch op {
            case .create(let row):
                spaceIds.insert(row.spaceId)
            case .move(_, _, let spaceId, _):
                spaceIds.insert(spaceId)
            case .claim(let guid, _), .update(let guid, _), .delete(let guid):
                if let spaceId = try bookmarkNode(with: guid, in: context)?.spaceId {
                    spaceIds.insert(spaceId)
                }
            }
        }
        for spaceId in spaceIds.sorted() where ImportTargetLock.shared.isImporting(into: spaceId) {
            // 与 `targetNotWritable` 分开：导入是**瞬时**状态，引擎该停放重试，而不是把它
            // 当成一次结构性失败。`sorted()` 只为让多个 Space 同时在导入时报出去的是同一
            // 个，不随 Set 的迭代顺序变。
            throw LocalStoreWriteError.spaceImporting(spaceId: spaceId)
        }
    }

    private static func bulkInsert(from row: PhiLocalBookmark) -> BulkBookmarkInsert {
        BulkBookmarkInsert(guid: row.guid,
                           syncId: row.syncId,
                           title: row.title,
                           url: row.url,
                           index: row.index,
                           isFolder: row.isFolder,
                           parentGuid: row.parentGuid,
                           spaceId: row.spaceId,
                           profileId: row.profileId,
                           createdDate: row.createdDate,
                           contentUpdatedDate: row.contentUpdatedDate,
                           secondaryUrl: row.secondaryUrl,
                           secondaryTitle: row.secondaryTitle,
                           source: row.source)
    }
}

#if DEBUG
// MARK: - 测试钩子

extension LocalStore {
    /// 建一个 Space 并立刻物化它的书签根，省得每个用例自己拼 `SpaceModel` 的六个字段。
    func createSpaceForTesting(spaceId: String, profileId: String) async throws {
        try await createSpaceThrowing(profileId: profileId,
                                      name: spaceId,
                                      colorHex: "#000000",
                                      iconName: "star",
                                      spaceId: spaceId,
                                      createdDate: nil)
    }

    /// 按给定 `index` 插一条书签并**跳过重排**，用来制造「两条兄弟 index 撞车」的前提。
    func insertBookmarkWithIndexForTesting(guid: String,
                                           parentGuid: String,
                                           index: Int) async throws {
        _ = try await performBackgroundWriteAndWaitThrowing { context -> Bool in
            guard let parent = try self.bookmarkNode(with: parentGuid, in: context) else {
                throw LocalStoreWriteError.rowNotFound
            }
            let now = Date()
            let node = TabDataModel(title: guid,
                                    guid: guid,
                                    index: index,
                                    url: URL(string: "https://example.com/\(guid)")!,
                                    favicon: nil as Data?,
                                    createdDate: now,
                                    updatedDate: now)
            node.dataType = TabDataType.bookmark
            node.spaceId = parent.spaceId
            node.profileId = parent.profileId
            node.profile = parent.profile
            node.isCreatedByChromium = false
            context.insert(node)
            node.parent = parent
            return true
        }
    }

    /// 断开 `SpaceModel.bookmarkRoot` 关系但把那条根行留在库里，制造「关系断了但孤儿根
    /// 还在」的状态。
    func detachBookmarkRootRelationshipForTesting(spaceId: String) async throws {
        _ = try await performBackgroundWriteAndWaitThrowing { context -> Bool in
            let descriptor = FetchDescriptor<SpaceModel>(
                predicate: #Predicate<SpaceModel> { $0.spaceId == spaceId }
            )
            guard let space = try context.fetch(descriptor).first else {
                throw LocalStoreWriteError.rowNotFound
            }
            space.bookmarkRoot = nil
            return true
        }
    }

    /// 与 `insertBookmarksBulkThrowing` 同一个 body，额外把重排次数交回给用例。
    func insertBookmarksBulkThrowingCountingNormalizations(
        _ rows: [BulkBookmarkInsert]
    ) async throws -> Int {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.insertBookmarksBulkBody(rows, in: context)
        }
    }
}
#endif
