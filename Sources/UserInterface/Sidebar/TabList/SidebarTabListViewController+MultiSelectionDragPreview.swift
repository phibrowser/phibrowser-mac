// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

private struct SidebarMultiSelectionDragPreview {
    let image: NSImage
    let sourceImageOrigin: CGPoint
}

private struct SidebarMultiSelectionDragPreviewLayer {
    let id: AnyHashable
    let image: NSImage
}

extension SidebarTabListViewController {
    private enum SidebarMultiSelectionPreviewItem {
        case tab(Int)
        case bookmark(String)

        var previewId: AnyHashable {
            switch self {
            case .tab(let tabId):
                return AnyHashable("tab:\(tabId)")
            case .bookmark(let guid):
                return AnyHashable("bookmark:\(guid)")
            }
        }
    }

    private func tabPreviewId(_ tabId: Int) -> AnyHashable {
        AnyHashable("tab:\(tabId)")
    }

    private func bookmarkPreviewId(_ guid: String) -> AnyHashable {
        AnyHashable("bookmark:\(guid)")
    }

    func applyMultiSelectionDragImageIfNeeded(session: NSDraggingSession,
                                              startingFrom tab: Tab,
                                              sourceImage: NSImage?,
                                              sourceGroupCell: TabGroupCellView?,
                                              browserState: BrowserState,
                                              outlineView: SideBarOutlineView) -> Bool {
        guard let tabIds = browserState.multiSelectionDragTabIds(startingFrom: tab),
              let preview = makeMultiSelectionDragPreview(
                startingTabId: tab.guid,
                tabIds: tabIds,
                bookmarkGuids: browserState.multiSelectionDragBookmarkGuids() ?? [],
                sourceImage: sourceImage,
                sourceGroupCell: sourceGroupCell,
                browserState: browserState,
                outlineView: outlineView
              ) else {
            return false
        }

        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { draggingItem, _, _ in
            let sourceFrame = draggingItem.draggingFrame
            let frame = NSRect(
                x: sourceFrame.origin.x - preview.sourceImageOrigin.x,
                y: sourceFrame.origin.y - preview.sourceImageOrigin.y,
                width: preview.image.size.width,
                height: preview.image.size.height
            )
            draggingItem.imageComponentsProvider = nil
            draggingItem.setDraggingFrame(frame, contents: preview.image)
        }
        browserState.tabDraggingSession.setOriginalDragImage(preview.image)
        return true
    }

    func applyMultiSelectionDragImageIfNeeded(session: NSDraggingSession,
                                              startingFrom bookmark: Bookmark,
                                              sourceImage: NSImage?,
                                              browserState: BrowserState,
                                              outlineView: SideBarOutlineView) -> Bool {
        guard let bookmarkGuids = browserState.multiSelectionDragBookmarkGuids(startingFrom: bookmark) else {
            return false
        }
        let tabIds = browserState.multiSelectionDragTabIdsForBookmarkDrag() ?? []
        guard let preview = makeMultiSelectionDragPreview(
            startingBookmarkGuid: bookmark.guid,
            tabIds: tabIds,
            bookmarkGuids: bookmarkGuids,
            sourceImage: sourceImage,
            sourceGroupCell: nil,
            browserState: browserState,
            outlineView: outlineView
        ) else {
            return false
        }

        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { draggingItem, _, _ in
            let sourceFrame = draggingItem.draggingFrame
            let frame = NSRect(
                x: sourceFrame.origin.x - preview.sourceImageOrigin.x,
                y: sourceFrame.origin.y - preview.sourceImageOrigin.y,
                width: preview.image.size.width,
                height: preview.image.size.height
            )
            draggingItem.imageComponentsProvider = nil
            draggingItem.setDraggingFrame(frame, contents: preview.image)
        }
        browserState.tabDraggingSession.setOriginalDragImage(preview.image)
        return true
    }

    private func makeMultiSelectionDragPreview(startingTabId: Int,
                                               tabIds: [Int],
                                               bookmarkGuids: [String],
                                               sourceImage: NSImage?,
                                               sourceGroupCell: TabGroupCellView?,
                                               browserState: BrowserState,
                                               outlineView: SideBarOutlineView) -> SidebarMultiSelectionDragPreview? {
        makeMultiSelectionDragPreview(
            startingItemId: tabPreviewId(startingTabId),
            startingTabId: startingTabId,
            tabIds: tabIds,
            bookmarkGuids: bookmarkGuids,
            sourceImage: sourceImage,
            sourceGroupCell: sourceGroupCell,
            browserState: browserState,
            outlineView: outlineView
        )
    }

    private func makeMultiSelectionDragPreview(startingBookmarkGuid: String,
                                               tabIds: [Int],
                                               bookmarkGuids: [String],
                                               sourceImage: NSImage?,
                                               sourceGroupCell: TabGroupCellView?,
                                               browserState: BrowserState,
                                               outlineView: SideBarOutlineView) -> SidebarMultiSelectionDragPreview? {
        makeMultiSelectionDragPreview(
            startingItemId: bookmarkPreviewId(startingBookmarkGuid),
            startingTabId: nil,
            tabIds: tabIds,
            bookmarkGuids: bookmarkGuids,
            sourceImage: sourceImage,
            sourceGroupCell: sourceGroupCell,
            browserState: browserState,
            outlineView: outlineView
        )
    }

    private func makeMultiSelectionDragPreview(startingItemId: AnyHashable,
                                               startingTabId: Int?,
                                               tabIds: [Int],
                                               bookmarkGuids: [String],
                                               sourceImage: NSImage?,
                                               sourceGroupCell: TabGroupCellView?,
                                               browserState: BrowserState,
                                               outlineView: SideBarOutlineView) -> SidebarMultiSelectionDragPreview? {
        let orderedPreviewIds = multiSelectionDragPreviewTabIds(
            startingTabId: startingTabId,
            tabIds: tabIds,
            browserState: browserState
        )
        let previewTabIds = TabDragCountBadge.visibleRepresentativeTabIds(
            tabIds: orderedPreviewIds,
            browserState: browserState
        )
        let visibleCount = TabDragCountBadge.visibleUnitCount(
            tabIds: tabIds,
            browserState: browserState
        ) + bookmarkGuids.count
        guard visibleCount > 1 else { return nil }

        let previewItems = Array(
            mixedPreviewItems(startingItemId: startingItemId,
                              tabIds: Array(previewTabIds),
                              bookmarkGuids: bookmarkGuids)
                .prefix(3)
        )
        var layers: [SidebarMultiSelectionDragPreviewLayer] = []
        for item in previewItems {
            switch item {
            case .tab(let tabId):
                if let image = draggingImageForSidebarTabId(
                    tabId,
                    sourceGroupCell: sourceGroupCell,
                    outlineView: outlineView
                ) {
                    layers.append(SidebarMultiSelectionDragPreviewLayer(id: tabPreviewId(tabId), image: image))
                } else if tabPreviewId(tabId) == startingItemId, let sourceImage {
                    layers.append(SidebarMultiSelectionDragPreviewLayer(id: tabPreviewId(tabId), image: sourceImage))
                }
            case .bookmark(let guid):
                if let image = draggingImageForSidebarBookmarkGuid(guid, outlineView: outlineView) {
                    layers.append(SidebarMultiSelectionDragPreviewLayer(id: bookmarkPreviewId(guid), image: image))
                } else if bookmarkPreviewId(guid) == startingItemId, let sourceImage {
                    layers.append(SidebarMultiSelectionDragPreviewLayer(id: bookmarkPreviewId(guid), image: sourceImage))
                }
            }
        }
        if layers.isEmpty, let sourceImage {
            layers.append(SidebarMultiSelectionDragPreviewLayer(id: startingItemId, image: sourceImage))
        }
        let fallbackImage = sourceImage ?? layers.first?.image
        for item in previewItems where layers.count < min(visibleCount, 3) {
            let id = item.previewId
            guard layers.contains(where: { $0.id == id }) == false,
                  let fallbackImage else {
                continue
            }
            layers.append(SidebarMultiSelectionDragPreviewLayer(id: id, image: fallbackImage))
        }
        return makeStackedMultiSelectionDragPreview(
            layers: layers,
            sourceItemId: startingItemId,
            count: visibleCount
        )
    }

    private func multiSelectionDragPreviewTabIds(startingTabId: Int?,
                                                 tabIds: [Int],
                                                 browserState: BrowserState) -> [Int] {
        var orderedIds: [Int] = []
        func appendIfPresent(_ tabId: Int?) {
            guard let tabId,
                  tabIds.contains(tabId),
                  !orderedIds.contains(tabId) else {
                return
            }
            orderedIds.append(tabId)
        }

        appendIfPresent(browserState.focusingTab?.guid)
        appendIfPresent(startingTabId)
        for tabId in tabIds {
            appendIfPresent(tabId)
        }
        return orderedIds
    }

    private func mixedPreviewItems(startingItemId: AnyHashable,
                                   tabIds: [Int],
                                   bookmarkGuids: [String]) -> [SidebarMultiSelectionPreviewItem] {
        var items: [SidebarMultiSelectionPreviewItem] = []
        func append(_ item: SidebarMultiSelectionPreviewItem) {
            guard !items.contains(where: { $0.previewId == item.previewId }) else { return }
            items.append(item)
        }

        if let starting = tabIds.first(where: { tabPreviewId($0) == startingItemId }) {
            append(.tab(starting))
        }
        if let starting = bookmarkGuids.first(where: { bookmarkPreviewId($0) == startingItemId }) {
            append(.bookmark(starting))
        }
        tabIds.forEach { append(.tab($0)) }
        bookmarkGuids.forEach { append(.bookmark($0)) }
        return items
    }

    private func draggingImageForSidebarTabId(_ tabId: Int,
                                              sourceGroupCell: TabGroupCellView?,
                                              outlineView: SideBarOutlineView) -> NSImage? {
        if let image = sourceGroupCell?.draggingImageForMemberTabId(tabId) {
            return image
        }
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) else { continue }
            if let tab = item as? Tab,
               tab.guid == tabId,
               let cell = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
               ) as? SidebarCellView {
                return cell.createDraggingImage()
            }
            if let pair = item as? SplitPairSidebarItem,
               pair.leftTab.guid == tabId || pair.rightTab.guid == tabId,
               let cell = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
               ) as? SidebarCellView {
                return cell.createDraggingImage()
            }
            if let groupCell = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) as? TabGroupCellView,
               let image = groupCell.draggingImageForMemberTabId(tabId) {
                return image
            }
        }
        return nil
    }

    private func draggingImageForSidebarBookmarkGuid(_ guid: String,
                                                     outlineView: SideBarOutlineView) -> NSImage? {
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) else { continue }
            let bookmark: Bookmark?
            if let direct = item as? Bookmark {
                bookmark = direct
            } else if let provider = item as? UnderlyingBookmarkProviding {
                bookmark = provider.underlyingBookmark
            } else {
                bookmark = nil
            }
            guard bookmark?.guid == guid,
                  let cell = outlineView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                  ) as? SidebarCellView else {
                continue
            }
            return cell.createDraggingImage()
        }
        return nil
    }

    private func makeStackedMultiSelectionDragPreview(layers: [SidebarMultiSelectionDragPreviewLayer],
                                                      sourceItemId: AnyHashable,
                                                      count: Int) -> SidebarMultiSelectionDragPreview? {
        let visibleLayers = Array(layers.prefix(3))
        guard !visibleLayers.isEmpty else { return nil }

        let maxWidth = visibleLayers.map(\.image.size.width).max() ?? 0
        let maxHeight = visibleLayers.map(\.image.size.height).max() ?? 0
        guard maxWidth > 0, maxHeight > 0 else { return nil }

        let layerSpacing = NSSize(width: 3, height: 3)
        let badgeSize = TabDragCountBadge.size(for: count)
        let badgeOverlap = badgeSize.height * (12.0 / 28.0)
        let padding: CGFloat = 7.5
        let stackDepth = CGFloat(visibleLayers.count - 1)
        let canvasSize = NSSize(
            width: maxWidth + stackDepth * layerSpacing.width + badgeOverlap + padding,
            height: maxHeight + stackDepth * layerSpacing.height + badgeOverlap + padding
        )
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        let baseOrigin = NSPoint(
            x: badgeOverlap,
            y: padding * 0.5 + stackDepth * layerSpacing.height
        )
        var sourceImageOrigin = baseOrigin
        for index in stride(from: visibleLayers.count - 1, through: 0, by: -1) {
            let layer = visibleLayers[index]
            let snapshot = layer.image
            let depth = CGFloat(index)
            let rect = NSRect(
                x: baseOrigin.x + depth * layerSpacing.width,
                y: baseOrigin.y - depth * layerSpacing.height,
                width: snapshot.size.width,
                height: snapshot.size.height
            )
            if layer.id == sourceItemId {
                sourceImageOrigin = rect.origin
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            snapshot.draw(
                in: rect,
                from: NSRect(origin: .zero, size: snapshot.size),
                operation: .sourceOver,
                fraction: index == 0 ? 1.0 : 0.92
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        let badgeRect = NSRect(
            x: 0,
            y: canvasSize.height - badgeSize.height,
            width: badgeSize.width,
            height: badgeSize.height
        )
        TabDragCountBadge.draw(count: count, in: badgeRect)

        return SidebarMultiSelectionDragPreview(
            image: image,
            sourceImageOrigin: sourceImageOrigin
        )
    }
}
