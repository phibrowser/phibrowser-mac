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

    /// Throwing sibling used ONLY by the sync layer: `PhiSyncEngine` may write the `reconciled` / `server`
    /// baselines only after the row landed, and the fire-and-forget original swallows its own failure (§4.9).
    ///
    /// Three deliberate UI differences: accept an absolute `URL` without user-input/search processing; default
    /// `allowsEmptyTitle` to true to preserve remote empty titles; and throw on unresolved parents instead of
    /// silently falling back to the Space root.
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
                                    layout: String? = nil,
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
                                          layout: layout,
                                          favicon: favicon,
                                          allowsEmptyTitle: allowsEmptyTitle,
                                          now: now,
                                          in: context)
        // Persist the identity and row in one transaction; landing has no second write that could fail.
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

    /// Throwing sibling used ONLY by the sync layer (§4.9). `allowsEmptyTitle` does not affect folders:
    /// `insertDirectoryNode` copies the title verbatim.
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
                        context.insert(folder)
                        folder.profile = profile
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
                        node.profile = profile
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
                    context.insert(node)
                    node.profile = profile
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
                // `toSpaceId: nil` preserves UI behavior: use the row's Space, fall back to its root for a
                // missing/nil parentId, and do not retag.
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

    /// One call retags the entire subtree's Space/Profile and reparents it to any folder, updating fields
    /// without deleting/recreating rows or changing child GUIDs.
    ///
    /// Existing `moveBookmark` uses the row's own Space and cannot move across Spaces; `moveBookmarks` always
    /// targets a Space root. `toParentGuid == nil` targets this Space's canonical root.
    func moveBookmarkThrowing(guid: String,
                              toParentGuid parentGuid: String?,
                              inSpaceId spaceId: String,
                              index: Int) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            // The destination Space determines the Profile; if its local row is absent, use the bookmark's
            // existing Profile.
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
        // Retag only when sync explicitly supplies a destination Space. UI calls pass nil and retain the
        // existing `node.updatedDate = Date()` behavior.
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
                // `readOnlyTargetRoot: false` preserves UI heal-on-read: reclaim an orphan root, merge
                // duplicate roots' children, then remove duplicates before moving. A pure read would silently
                // drop the gesture while bookmarks remain under the orphan root.
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

    /// Throwing sibling used ONLY by the sync layer (§4.9). Source and destination share a Profile: account
    /// rows do not move between Chromium profiles.
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
        // An empty list is a caller bug, not a successful no-op.
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
        // Sync uses `readOnlyTargetRoot: true`: `bookmarkRoot(createIfNeeded: true)` can create roots, reclaim
        // orphans and delete duplicates on every round, and makes the missing-root guard unreachable. UI uses
        // false to preserve heal-on-read and complete moves from orphan roots.
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

        // If both silent `continue` paths skip the entire batch, throw instead of letting sync persist an
        // unrecoverable false-success baseline.
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
        // Preserve UI behavior by treating an empty title as no title update. The shared body's empty-title
        // behavior with `allowsEmptyTitle == false` substitutes the URL, matching create, while UI updates
        // have always ignored empty titles.
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
    /// `title == nil` leaves the title unchanged; `title == ""` with `allowsEmptyTitle: true` clears it,
    /// preserving valid remote empty titles. Update `contentUpdatedDate` only for actual content changes.
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
    /// Validate all URLs before writing any fields, avoiding a partial title update when a simultaneous URL
    /// edit is invalid.
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
        // Outer optional selects whether to change; inner optional selects the value, with nil meaning clear.
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
            // With `allowsEmptyTitle == false`, substitute the URL for an empty title, matching
            // `insertBookmarkNode`.
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
        // Stamp only actual content changes; saving an identical title must not outrank a peer's edit.
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
        root.spaceId = spaceId
        root.isCreatedByChromium = false
        context.insert(root)
        root.profile = profile
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

    /// Read-only root resolution via `SpaceModel.bookmarkRoot`; return nil if absent and write nothing.
    ///
    /// Do not use `bookmarkRoot(…)` in each sync round's reads: it heals relationships and deletes duplicate
    /// roots even before `guard createIfNeeded`. Keep those mutations on the UI path.
    ///
    /// The default-Space fallback reads the legacy `ProfileModel.bookmarkRoot` pointer to the same physical
    /// tree; it does not repair the backlink.
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

    /// Fetch all bookmark/folder rows once with relationships prefetched for snapshot, diff and index
    /// projections.
    ///
    /// Capture raw values in local constants for `#Predicate`: `TabDataModel.type` is an Int, and its computed
    /// extension property `dataType` is not visible to the macro.
    func allBookmarkModels(in context: ModelContext) throws -> [TabDataModel] {
        let bookmarkRaw = TabDataType.bookmark.rawValue
        let folderRaw = TabDataType.bookmarkFolder.rawValue
        var descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == bookmarkRaw || $0.type == folderRaw }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.parent, \.profile]
        return try context.fetch(descriptor)
    }

    /// Canonical root GUIDs for each (profileId, spaceId) pair. Resolve each Space once: calling
    /// `isBookmarkRoot(_:in:)` per row fetches all Profiles and Spaces each time, making large trees
    /// quadratic.
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

        // Use `guid` as the secondary key, matching `pinnedTabs(...)`. An excluded sibling (parked, pending
        // deletion or unidentified) may retain an index that collides with a newly assigned one. Without a
        // stable tie-break, fetch order can flip every round and cause endless rank commits; with it,
        // collisions are deterministic even if imperfect.
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
        folder.isCreatedByChromium = false
        // Insert before assigning `profile`. Its inverse `ProfileModel.tabs` otherwise creates an
        // uninitialized placeholder for a model outside the context; its missing required fields cause every
        // later save to fail validation (NSCocoaErrorDomain 1560). This applies to every new `TabDataModel`,
        // not only pins.
        context.insert(folder)
        folder.profile = parent.profile
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
        // Keep the UI default of replacing empty titles with the URL. Sync passes true to preserve remote
        // empty titles; substituting the URL would disagree with `reconciled`, look like a fresh local edit
        // next round, and overwrite the peer's cleared title.
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
        bookmark.isCreatedByChromium = false
        bookmark.secondaryUrl = secondaryUrl
        bookmark.secondaryTitle = (secondaryTitle?.isEmpty == false) ? secondaryTitle : nil
        bookmark.layout = secondaryUrl == nil ? nil : layout
        context.insert(bookmark)
        bookmark.profile = parent.profile
        try insert(node: bookmark, to: parent, at: index, in: context)
        return bookmark
    }
    
    /// `strict: false` preserves UI tolerance: silently fall back to the Space root for an
    /// unresolved/non-folder parent.
    ///
    /// Sync alone uses true: an unintended root fallback would become a local position change next round and
    /// overwrite the correct remote `parent_uuid`.
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

    /// Destination root resolution for `moveBookmarksBody`.
    ///
    /// `readOnly: false` preserves UI heal-on-read before `guard createIfNeeded`: reclaim orphan roots, merge
    /// children and delete duplicate roots. Pure reads would drop gestures after concurrent initialization
    /// leaves orphan roots.
    ///
    /// Sync uses true and `existingBookmarkRoot` to avoid main-context mutations on every round and keep the
    /// missing-target-root guard meaningful.
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

    /// The row's own `profileId`, or nil if the row is absent.
    func bookmarkNodeProfileId(_ guid: String, in context: ModelContext) throws -> String? {
        try bookmarkNode(with: guid, in: context)?.profileId
    }

    /// A Space belongs to one Profile. Return nil if its local row is absent.
    func profileId(ofSpaceId spaceId: String, in context: ModelContext) throws -> String? {
        let descriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate<SpaceModel> { $0.spaceId == spaceId }
        )
        return try context.fetch(descriptor).first?.profileId
    }

    /// Normalize user-entered URLs on the UI path only: `URLProcessor.processUserInput` can turn non-URLs into
    /// searches. The throwing sync sibling accepts `URL` directly.
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

// MARK: - Bulk insertion for sync landing

extension LocalStore {
    /// A bookmark/folder row for bulk insertion, with `index` precomputed by the caller's §4.10 rank
    /// projection.
    struct BulkBookmarkInsert {
        var guid: String
        /// Account sync identity, persisted with the row in one transaction so no second landing write can
        /// fail.
        var syncId: String?
        var title: String
        /// Folders carry a placeholder URL.
        var url: URL
        var index: Int
        var isFolder: Bool
        /// nil attaches directly to this Space's canonical root.
        var parentGuid: String?
        var spaceId: String
        var profileId: String
        var createdDate: Date
        var contentUpdatedDate: Date?
        var secondaryUrl: URL?
        var secondaryTitle: String?
        /// The `TabSource` raw value.
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

    /// Insert N siblings with precomputed indices, bypassing `insert(node:to:at:in:)`, and normalize each
    /// touched parent once at transaction end.
    ///
    /// The single-row bookmark/folder helpers fetch siblings and normalize on every insert: 250 rows in one
    /// folder cause 250 fetches and full reorders, quadratic work inside the single transaction required by
    /// §4.5. UI keeps the existing single-row path.
    func insertBookmarksBulkThrowing(_ rows: [BulkBookmarkInsert]) async throws {
        _ = try await performBackgroundWriteAndWaitThrowing { context in
            try self.insertBookmarksBulkBody(rows, in: context)
        }
    }

    /// Returns the number of normalized parents, equal to the number of `normalizeIndexes` calls.
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

            // Parents can precede their children in this batch (§4.4 topological order); check already
            // inserted batch rows before persisted rows.
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
                if let root = try existingBookmarkRoot(profileId: row.profileId,
                                                       spaceId: row.spaceId,
                                                       in: context) {
                    parent = root
                } else {
                    // Review A4: a Space that exists but has never materialized its root (the
                    // default Space on a fresh device, or a pre-Spaces row never opened in a
                    // window) must not park the account's whole bookmark batch forever. This is
                    // a write transaction already, so materialize the root the way Space
                    // creation does. A Space row that is absent altogether still parks.
                    let spaceId = row.spaceId
                    let profileId = row.profileId
                    let spaceDescriptor = FetchDescriptor<SpaceModel>(
                        predicate: #Predicate<SpaceModel> { $0.spaceId == spaceId && $0.profileId == profileId })
                    guard try context.fetchCount(spaceDescriptor) > 0,
                          let root = try bookmarkRoot(profileId: profileId, spaceId: spaceId,
                                                      in: context, createIfNeeded: true) else {
                        throw LocalStoreWriteError.rowNotFound
                    }
                    parent = root
                }
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
            node.isCreatedByChromium = false
            node.secondaryUrl = row.secondaryUrl
            node.secondaryTitle = row.secondaryTitle
            node.source = row.source
            node.syncId = row.syncId
            node.contentUpdatedDate = row.contentUpdatedDate
            // Insert before assigning either relationship. Sync landing (R-exec-2) follows this order for both
            // `parent` and `profile`, just as scope migration must.
            context.insert(node)
            node.profile = profile
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

// MARK: - One remote landing round (sync only, §4.5 / R-exec-2)

/// §4.5 requires all rows in a remote landing round to share one transaction: any error means none landed.
///
/// Existing throwing helpers each enqueue and await their own serialized
/// `performBackgroundWriteAndWaitThrowing` (LocalStore.swift:466). Calling them separately creates N
/// transactions; nesting them inside a write deadlocks behind the waiting outer block.
///
/// Keep this extension in this file to access private move/update/delete bodies and bookmark/children/index
/// helpers, as on the Task 2b pin side. Single-row throwing APIs remain available; this batch entry reuses
/// their bodies so UI and sync behavior cannot diverge.
extension LocalStore {
    /// Apply the entire preordered bookmark batch in one transaction. `BookmarkApplyBatch` supplies §4.4
    /// three-phase topological order; never reorder operations here.
    ///
    /// 1. Recheck the import lock inside the write (§4.9 item 3), covering imports started after the round's
    /// preliminary read. Refuse the entire batch, roll back and retry next round, equivalent to parking that
    /// Space's bookmarks.
    /// 2. Coalesce consecutive creates using `insertBookmarksBulkBody`, preserving relative order and avoiding
    /// repeated sibling fetches/reorders for each insert.
    /// 3. Normalize each touched parent once at the end (§4.10); per-operation normalization alone does not
    /// ensure final dense indices.
    ///
    /// Remote creates carrying `contentUpdatedDate` use bulk insertion because single-row create APIs lack
    /// that argument (Task 2a item 3).
    func applyBookmarkSyncBatchThrowing(_ ops: [BookmarkApplyOp]) async throws {
        guard !ops.isEmpty else { return }
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyBookmarkSyncBatchBody(ops, in: context)
        }
    }

    /// Clear all bookmark identities on account exit/sync reset (§9.2) in one bulk write, avoiding one
    /// transaction per row. Only bookmarks and folders use this `syncId` column; pins derive identity from
    /// `(pinLineageId, owner)` (§3.2).
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

    /// Transaction body, extracted solely for readability; it has one caller.
    private func applyBookmarkSyncBatchBody(_ ops: [BookmarkApplyOp],
                                            in context: ModelContext) throws {
        try refuseIfImporting(ops, in: context)

        // Record touched parent GUIDs for final normalization, not models: children are deleted before
        // parents, so a retained model may already be deleted by transaction end and unsafe to read.
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
                // `bookmarkNode(with:)` matches any `TabDataModel` by GUID, including tabs and pins. Claiming
                // a non-bookmark would hide it from the next snapshot, making diff emit a tombstone for the
                // remote entity.
                guard node.dataType == .bookmark || node.dataType == .bookmarkFolder else {
                    throw LocalStoreWriteError.rowNotFound
                }
                // Claim identity only once (§6.1). Reclaiming the same UUID is idempotent; replacing it fails
                // closed because the old identity would lose its local row and be tombstoned. This guard
                // enforces the planner invariant at the write boundary (R-M3-3-14).
                guard node.syncId == nil || node.syncId == syncId else {
                    throw LocalStoreWriteError.rowAlreadyMapped
                }
                // Claiming is not editing: write identity without changing `contentUpdatedDate`.
                node.syncId = syncId

            case .move(let guid, let parentGuid, let spaceId, let index):
                try flushCreates()
                // Remember the old parent before moving so it is normalized too.
                remember(try bookmarkNode(with: guid, in: context)?.parent)
                // Use the destination Space's Profile, falling back to the row's existing Profile if the Space
                // is absent locally, matching `moveBookmarkThrowing` (:603).
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
                // Outer optional selects whether to change; inner optional selects the value. A nil inner
                // title clears it, so explicitly pass `allowsEmptyTitle: true` regardless of defaults (Task 2a
                // item 4). A nil inner URL means unchanged: bookmarks cannot lose their URL.
                // `updateBookmarkBody` never reads `profileId`, so avoid an otherwise wasted row fetch per
                // update.
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
                // `deleteBookmarkBody` calls `context.delete(node)`; `children` cascades deletion
                // (TabDataModelSchemaV10.swift:112). Protect descendants not named by the batch, especially
                // unpublished local rows. Named children are deleted first or moved away in phase 1; R-M3-3-17
                // requires every other child to be deleted or lifted to the Space root before its folder.
                // Violation rolls back for retry instead of silently losing user data.
                //
                // Explicitly exclude `isDeleted` children: child-first deletes have already marked them in
                // this context. Pending-change fetch behavior was not runtime-tested in this milestone
                // (compile-only), and §4.4 suggests the opposite behavior. Filtering works either way and
                // prevents every nonempty remote folder deletion from failing forever with `folderNotEmpty`.
                if node.dataType == .bookmarkFolder,
                   try children(of: node, in: context).contains(where: { !$0.isDeleted }) {
                    throw LocalStoreWriteError.folderNotEmpty
                }
                remember(node.parent)
                try deleteBookmarkBody(guid, profileId: node.profileId ?? Self.defaultProfileId,
                                       in: context)
            }
        }
        try flushCreates()

        // §4.10: project once per parent. Skip parents deleted by this batch; their children have already been
        // removed by cascade.
        for parentGuid in touchedParentGuids {
            guard let parent = try bookmarkNode(with: parentGuid, in: context) else { continue }
            normalizeIndexes(for: try children(of: parent, in: context))
        }
    }

    /// Refuse the entire batch if any touched Space is importing. Resolve Spaces for GUID-only
    /// claim/update/delete operations inside the transaction; a round-start snapshot may already be stale.
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
            // Importing is transient, unlike `targetNotWritable`: park and retry instead of treating it as
            // structural failure. Sort so concurrent imports report a deterministic Space rather than Set
            // iteration order.
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
// MARK: - Test hooks

extension LocalStore {
    /// Create a Space and immediately materialize its bookmark root, avoiding repeated six-field `SpaceModel`
    /// setup in tests.
    func createSpaceForTesting(spaceId: String, profileId: String) async throws {
        try await createSpaceThrowing(profileId: profileId,
                                      name: spaceId,
                                      colorHex: "#000000",
                                      iconName: "star",
                                      spaceId: spaceId,
                                      createdDate: nil)
    }

    /// Insert with the supplied index without normalization to create sibling index collisions.
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
            node.isCreatedByChromium = false
            context.insert(node)
            node.profile = parent.profile
            node.parent = parent
            return true
        }
    }

    /// Detach `SpaceModel.bookmarkRoot` while preserving its root row, creating an orphan root with a broken
    /// relationship.
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

    /// Run the same body as `insertBookmarksBulkThrowing`, returning the normalization count for tests.
    func insertBookmarksBulkThrowingCountingNormalizations(
        _ rows: [BulkBookmarkInsert]
    ) async throws -> Int {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.insertBookmarksBulkBody(rows, in: context)
        }
    }
}
#endif
