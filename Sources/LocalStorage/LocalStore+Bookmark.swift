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
    /// `secondaryUrl` is set only for split-view bookmarks; clicking such a
    /// bookmark opens both URLs as a side-by-side split. `secondaryTitle`
    /// is the secondary pane's display name and is shown alongside the
    /// primary title in the bookmark bar/sidebar.
    func createBookmark(url: String?,
                        title: String?,
                        profileId: String,
                        parentId: String?,
                        index: Int? = nil,
                        guid: String? = nil,
                        spaceId: String = LocalStore.defaultSpaceId,
                        secondaryUrl: String? = nil,
                        secondaryTitle: String? = nil,
                        favicon: Data? = nil) {
        guard let normalizedURL = normalizedURL(from: url),
        let bookmarkURL = URL(string: URLProcessor.processUserInput( normalizedURL.absoluteString)) else {
            AppLogError("Invalid bookmark url: \(url ?? "nil")")
            return
        }
        // A nil `secondaryUrl` means a single-URL bookmark; a non-nil but
        // unparseable value is a user error and must surface, not silently
        // turn the bookmark into a single-URL one.
        let normalizedSecondary: URL?
        if let raw = secondaryUrl {
            guard let normalized = self.normalizedURL(from: raw),
                  let processed = URL(string: URLProcessor.processUserInput(normalized.absoluteString)) else {
                AppLogError("Invalid bookmark secondary url: \(raw)")
                return
            }
            normalizedSecondary = processed
        } else {
            normalizedSecondary = nil
        }

        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, spaceId: spaceId, in: context) else {
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
                                                secondaryUrl: normalizedSecondary,
                                                secondaryTitle: secondaryTitle,
                                                favicon: favicon,
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
                         spaceId: String = LocalStore.defaultSpaceId) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, spaceId: spaceId, in: context) else {
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
                                                   favicon: Data?)]) {
        let normalizedBookmarks: [(title: String?,
                                   url: URL,
                                   guid: String,
                                   secondaryUrl: URL?,
                                   secondaryTitle: String?,
                                   favicon: Data?)] = bookmarks.compactMap { bookmark -> (title: String?,
                                                                                            url: URL,
                                                                                            guid: String,
                                                                                            secondaryUrl: URL?,
                                                                                            secondaryTitle: String?,
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
    /// directly under a Space-named landing folder. Nothing is written when
    /// `spaceRoot` has no children (avoids empty folders for empty Spaces).
    func saveArcBookmarksToLocalStore(
        _ spaceRoot: ArcDataParserTool.Bookmark,
        profileId: String,
        spaceId: String = LocalStore.defaultSpaceId
    ) async {
        guard !spaceRoot.children.isEmpty else { return }   // no empty Space-named folder
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                guard try self.importTargetSpaceIsWritable(profileId: profileId, spaceId: spaceId, in: context) else {
                    AppLogWarn("Skipping Arc bookmark import: space \(spaceId) no longer exists for profile \(profileId)")
                    return
                }
                guard let profile = try self.profile(with: profileId, in: context, createIfNeeded: true),
                      let root = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: true) else { return }

                let now = Date()
                let importRoot = TabDataModel(
                    // Defensive fallback: the parser fills the Space title (real or
                    // localized "Untitled Space"), so this only matters if a nil-title
                    // root ever reaches here — share the SAME localized fallback the
                    // picker shows, not the legacy generic "Imported From Arc" name.
                    title: spaceRoot.title ?? NSLocalizedString("Untitled Space", comment: "Arc import - fallback name for an Arc Space with no title"),
                    guid: UUID().uuidString, index: 0, url: Self.folderPlaceholderURL,
                    favicon: nil, createdDate: now, updatedDate: now)
                importRoot.dataType = .bookmarkFolder
                importRoot.isCreatedByChromium = false
                importRoot.spaceId = root.spaceId
                importRoot.profileId = profileId
                importRoot.source = 3
                importRoot.profile = profile
                context.insert(importRoot)
                try self.insert(node: importRoot, to: root, at: nil, in: context)

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
                    context.insert(node)
                    try self.insert(node: node, to: parent, at: index, in: context)
                    for (childIndex, child) in arcBookmark.children.enumerated() {
                        try insertArcBookmark(child, parent: node, index: childIndex)
                    }
                }

                // Insert the Space's children directly under the Space-named folder (no double-nest).
                for (index, child) in spaceRoot.children.enumerated() {
                    try insertArcBookmark(child, parent: importRoot, index: index)
                }
            } catch {
                AppLogError("Failed to save Arc bookmarks: \(error)")
            }
        }
    }
    
    func saveChromiumBookmarksToLocalStore(_ bookmarks: [BookmarkWrapper], profileId: String, spaceId: String = LocalStore.defaultSpaceId) async {
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                guard try self.importTargetSpaceIsWritable(profileId: profileId, spaceId: spaceId, in: context) else {
                    AppLogWarn("Skipping Chromium bookmark import: space \(spaceId) no longer exists for profile \(profileId)")
                    return
                }
                guard let profile = try self.profile(with: profileId, in: context, createIfNeeded: true),
                      let root = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: true) else { return }
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
                guard let node = try self.bookmarkNode(with: guid, in: context) else {
                    AppLogError("Bookmark \(guid) not found for move")
                    return
                }
                guard try !self.isBookmarkRoot(node, in: context) else {
                    AppLogError("Attempted to move bookmark root")
                    return
                }
                // Use the source node's own spaceId so a missing/nil parentId
                // falls back to the right Space's root (cross-Space moves are
                // not supported via this API today).
                let resolveSpaceId = node.spaceId ?? Self.defaultSpaceId
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, spaceId: resolveSpaceId, in: context) else {
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
                guard !guids.isEmpty else { return }
                let targetSpaceIsWritable: Bool
                if targetSpaceId == Self.defaultSpaceId {
                    targetSpaceIsWritable = true
                } else {
                    targetSpaceIsWritable = try self.importTargetSpaceIsWritable(profileId: targetProfileId,
                                                                                 spaceId: targetSpaceId,
                                                                                 in: context)
                }
                guard targetSpaceIsWritable else {
                    AppLogError("Target Space not found when moving bookmarks")
                    return
                }
                guard let targetProfile = try self.profile(with: targetProfileId,
                                                           in: context,
                                                           createIfNeeded: true),
                      let targetRoot = try self.bookmarkRoot(profileId: targetProfileId,
                                                             spaceId: targetSpaceId,
                                                             in: context,
                                                             createIfNeeded: true) else {
                    AppLogError("Target bookmark root not found when moving bookmarks")
                    return
                }

                let requestedGuids = Set(guids)
                var sourceParentsByGuid: [String: TabDataModel] = [:]
                var movedNodes: [TabDataModel] = []
                var movedGuids = Set<String>()
                let now = Date()

                for guid in guids {
                    guard let node = try self.bookmarkNode(with: guid, in: context),
                          node.profileId == sourceProfileId,
                          try !self.isBookmarkRoot(node, in: context),
                          !self.hasAncestor(of: node, in: requestedGuids) else {
                        continue
                    }
                    if node.spaceId == targetSpaceId && node.profileId == targetProfileId {
                        continue
                    }

                    if let parent = node.parent {
                        sourceParentsByGuid[parent.guid] = parent
                    }
                    node.parent = targetRoot
                    try self.retagBookmarkSubtree(node,
                                                  profileId: targetProfileId,
                                                  profile: targetProfile,
                                                  spaceId: targetSpaceId,
                                                  updatedDate: now,
                                                  in: context)
                    movedNodes.append(node)
                    movedGuids.insert(node.guid)
                }

                guard !movedNodes.isEmpty else { return }
                for parent in sourceParentsByGuid.values where parent.guid != targetRoot.guid {
                    let siblings = try self.children(of: parent, in: context)
                    self.normalizeIndexes(for: siblings)
                }

                var targetSiblings = try self.children(of: targetRoot, in: context)
                    .filter { !movedGuids.contains($0.guid) }
                targetSiblings.append(contentsOf: movedNodes)
                self.normalizeIndexes(for: targetSiblings)

                for node in movedNodes where node.dataType == .bookmarkFolder {
                    if try self.hasSelectedDescendant(of: node,
                                                      selectedGuids: requestedGuids,
                                                      in: context) {
                        try self.liftUnselectedChildren(from: node,
                                                        selectedGuids: requestedGuids,
                                                        updatedDate: now,
                                                        in: context)
                    }
                }
                targetRoot.updatedDate = now
            } catch {
                AppLogError("Failed to move bookmarks to Space: \(error)")
            }
        }
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
                var secondaryUrlClearedInThisUpdate = false
                if let secondaryUrlOpt = secondaryUrl {
                    if let raw = secondaryUrlOpt, !raw.isEmpty {
                        // Mirror the primary-URL behavior: a non-empty
                        // secondary URL that fails to parse aborts the whole
                        // update so the user sees the error and the bookmark
                        // does not silently keep its old state mixed with
                        // partially-applied changes.
                        guard let normalized = self.normalizedURL(from: raw) else {
                            AppLogError("Invalid secondary URL while updating bookmark: \(raw)")
                            return
                        }
                        node.secondaryUrl = normalized
                    } else {
                        node.secondaryUrl = nil
                        secondaryUrlClearedInThisUpdate = true
                    }
                }
                if secondaryUrlClearedInThisUpdate {
                    node.secondaryTitle = nil
                } else if let secondaryTitleOpt = secondaryTitle {
                    if let raw = secondaryTitleOpt, !raw.isEmpty {
                        node.secondaryTitle = raw
                    } else {
                        node.secondaryTitle = nil
                    }
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
                guard try !self.isBookmarkRoot(node, in: context) else {
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
                return bookmarks.filter {
                    $0.profile?.profileId == profileId && $0.spaceId == spaceId
                }
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
                                           favicon: source.favicon,
                                           now: createdDate,
                                           in: context)
            clone.lastSeen = source.lastSeen
        }
        clone.overrideTitle = source.overrideTitle
        clone.source = source.source
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
                            favicon: Data? = nil,
                            now: Date,
                            in context: ModelContext) throws -> TabDataModel {
        let bookmark = TabDataModel(title: (title?.isEmpty == false ? title! : url.absoluteString),
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
        context.insert(bookmark)
        try insert(node: bookmark, to: parent, at: index, in: context)
        return bookmark
    }
    
    func resolveParent(for parentId: String?,
                       profileId: String,
                       spaceId: String = LocalStore.defaultSpaceId,
                       in context: ModelContext,
                       createIfNeeded: Bool = true) throws -> TabDataModel? {
        if let parentId,
           let node = try bookmarkNode(with: parentId, in: context),
           node.dataType == .bookmarkFolder {
            return node
        }
        return try bookmarkRoot(profileId: profileId,
                                spaceId: spaceId,
                                in: context,
                                createIfNeeded: createIfNeeded)
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
