// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

/// Each card owns its views, while all edits use the same store as Sidebar.
struct LibrarySpaceManagementView: NSViewControllerRepresentable {
    let contents: LibrarySpaceContents
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    func makeNSViewController(context: Context) -> LibrarySpaceManagementController {
        LibrarySpaceManagementController(contents: contents, theme: theme, appearance: appearance)
    }

    func updateNSViewController(_ controller: LibrarySpaceManagementController, context: Context) {
        controller.themeSource.setTheme(theme)
        controller.themeSource.setUserAppearanceChoice(appearance.isDark ? .dark : .light)
    }
}

struct LibrarySpaceItemDrag: Codable {
    static let type = NSPasteboard.PasteboardType("com.phibrowser.library.space-items")
    static let didBegin = Notification.Name("LibrarySpaceItemDragDidBegin")
    static let didEnd = Notification.Name("LibrarySpaceItemDragDidEnd")
    let storeID: UUID
    let profileID: String
    let spaceID: String
    let ids: [String]
    let isPin: Bool
    let pinnedScope: String?

    @MainActor
    init(contents: LibrarySpaceContents, ids: [String], isPin: Bool) {
        storeID = contents.storeIdentifier
        profileID = contents.scope.profileId
        spaceID = contents.scope.spaceId
        self.ids = ids
        self.isPin = isPin
        pinnedScope = isPin ? contents.store?.pinnedTabScope().rawValue : nil
    }

    func writer() -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.type)
        return item
    }

    static func read(_ info: NSDraggingInfo) -> Self? {
        read(info.draggingPasteboard)
    }

    static func read(_ pasteboard: NSPasteboard) -> Self? {
        guard let data = pasteboard.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

private final class LibraryBookmarkOutline: SideBarOutlineView {
    var contextMenu: ((Int) -> NSMenu)?
    var deleteSelection: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelection?() }
        else { super.keyDown(with: event) }
    }
}

final class LibrarySpaceManagementController: NSViewController,
    NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate, BookmarkCellViewDelegate {
    private let contents: LibrarySpaceContents
    let themeSource: BrowserThemeContext
    private let pins = ReorderingCollectionView()
    private let pinDropIndicator = CALayer()
    private let pinScroll = NSScrollView()
    private let pinLayout = PinnedTabLayout()
    private let outline = LibraryBookmarkOutline()
    private var pinHeight: NSLayoutConstraint!
    private var bookmarkTopSpacing: NSLayoutConstraint!
    private var isDraggingItems = false
    private var subscriptions = Set<AnyCancellable>()
    private var displayedPins: [LibrarySpaceContents.Item] = []
    private var snapshot: DiffableOutlineSnapshot<AnyHashable>?
    private var roots: [Bookmark] { contents.bookmarkManager.rootFolder.children }
    private var expandedIDs = Set<String>()
    private var isReloading = false
    private var lastDropValidation: String?

    init(contents: LibrarySpaceContents, theme: Theme, appearance: Appearance) {
        self.contents = contents
        themeSource = BrowserThemeContext(configuration: BrowserThemeConfiguration(
            currentTheme: theme, userAppearanceChoice: appearance.isDark ? .dark : .light,
            mirrorsSharedTheme: false, mirrorsSharedAppearance: false))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.subtreeThemeSource = themeSource
        pins.collectionViewLayout = pinLayout
        pins.backgroundColors = [.clear]
        pins.dataSource = self
        pins.delegate = self
        pins.isSelectable = true
        pins.capturesContextMenuClicks = true
        pins.wantsLayer = true
        pinDropIndicator.isHidden = true
        pins.layer?.addSublayer(pinDropIndicator)
        pins.managedDragOperation = { [weak self] info in self?.updatePinDrop(info) ?? [] }
        pins.managedDrop = { [weak self] info in
            guard let self else { return false }
            defer { pinDropIndicator.isHidden = true }
            return collectionView(pins, acceptDrop: info,
                indexPath: IndexPath(item: pinDropIndex(info), section: PinnedTabLayout.Section.tabs.rawValue), dropOperation: .before)
        }
        pins.managedDragExited = { [weak self] in self?.pinDropIndicator.isHidden = true }
        pins.register(PinnedTabItem.self, forItemWithIdentifier: PinnedTabItem.reuseIdentifier)
        pins.register(PinnedSplitItem.self, forItemWithIdentifier: PinnedSplitItem.reuseIdentifier)
        pins.registerForDraggedTypes([LibrarySpaceItemDrag.type])
        pins.setDraggingSourceOperationMask(.move, forLocal: true)
        pins.setDraggingSourceOperationMask([], forLocal: false)

        pinScroll.documentView = pins
        pinScroll.drawsBackground = false
        pinScroll.hasVerticalScroller = true
        pinScroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = true
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 36
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = CGFloat(SideBarOutlineView.indentation)
        outline.style = .fullWidth
        outline.dragsWindowFromBlankArea = false
        outline.selectionHighlightStyle = .none
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(toggleClickedFolder)
        outline.doubleAction = #selector(openSelectedBookmark)
        outline.registerForDraggedTypes([LibrarySpaceItemDrag.type])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.contextMenu = { [weak self] row in self?.bookmarkMenu(row: row) ?? NSMenu() }
        outline.deleteSelection = { [weak self] in self?.deleteSelectedBookmarks() }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline

        let add = HoverableButtonNSView(
            config: HoverableButtonConfig(imageSize: NSSize(width: 14, height: 14), systemName: "ellipsis",
                                          hoverBackgroundColor: .hover, imageTintColor: .textSecondary,
                                          cornerRadius: 12),
            target: self, selector: #selector(showMoreMenu(_:)))
        add.toolTip = NSLocalizedString("library.spaces.moreActions", value: "More Actions", comment: "Library Space card - more actions button")
        add.setAccessibilityLabel(add.toolTip)
        [pinScroll, scroll, add].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        pinHeight = pinScroll.heightAnchor.constraint(equalToConstant: 48)
        bookmarkTopSpacing = scroll.topAnchor.constraint(equalTo: pinScroll.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([
            pinScroll.topAnchor.constraint(equalTo: view.topAnchor),
            pinScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pinScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), pinHeight,
            bookmarkTopSpacing,
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -8),
            add.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            add.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            add.widthAnchor.constraint(equalToConstant: 24), add.heightAnchor.constraint(equalToConstant: 24)
        ])
        contents.$pins.sink { [weak self] values in
            guard let self else { return }
            displayedPins = values
            pins.reloadData()
            updatePinHeight()
        }.store(in: &subscriptions)
        contents.bookmarkManager.$rootFolder.sink { [weak self] root in self?.reloadBookmarks(root.children) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: LibrarySpaceItemDrag.didBegin)
            .sink { [weak self] notification in
                guard let self, let pasteboard = notification.object as? NSPasteboard,
                      let drag = LibrarySpaceItemDrag.read(pasteboard),
                      drag.storeID == contents.storeIdentifier,
                      drag.isPin || drag.ids.allSatisfy({ self.contents.store?.getTab(by: $0)?.dataType == .bookmark }) else { return }
                isDraggingItems = true
                updatePinHeight()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: LibrarySpaceItemDrag.didEnd)
            .sink { [weak self] _ in
                guard let self else { return }
                isDraggingItems = false
                pinDropIndicator.isHidden = true
                updatePinHeight()
            }.store(in: &subscriptions)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        pins.reloadData()
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkCellView else { continue }
            cell.browserState = liveState
            cell.configureAppearance()
            cell.setManagementSelected(outline.selectedRowIndexes.contains(row))
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePinHeight()
    }

    private func updatePinHeight() {
        pinLayout.configure(parentWidth: max(view.bounds.width, 1), tabCount: displayedPins.count, extensionCount: 0)
        pinLayout.prepare()
        let height = max(45, pinLayout.contentHeight)
        pins.setFrameSize(NSSize(width: max(view.bounds.width, 1), height: height))
        let collapsed = displayedPins.isEmpty && !isDraggingItems
        pinScroll.isHidden = collapsed
        pinHeight.constant = collapsed ? 0 : min(height, max(45, view.bounds.height * 0.4))
        bookmarkTopSpacing.constant = collapsed ? 0 : 8
    }

    private func reloadBookmarks(_ items: [Bookmark]) {
        let selected = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Bookmark)?.guid })
        let next = SidebarDiffableSnapshotBuilder(rootItems: items).makeSnapshot()
        isReloading = true
        outline.reloadWith(next, animated: true, updateDataSource: { [weak self] in
            self?.snapshot = next
        }, completion: { [weak self] in
            guard let self else { return }
            func restore(_ nodes: [Bookmark]) {
                for node in nodes where node.isFolder && expandedIDs.contains(node.guid) {
                    node.isExpanded = true
                    outline.expandItem(node)
                    restore(node.children)
                }
            }
            restore(items)
            outline.selectRowIndexes(IndexSet((0..<outline.numberOfRows).filter {
                guard let bookmark = self.outline.item(atRow: $0) as? Bookmark else { return false }
                return !bookmark.isFolder && selected.contains(bookmark.guid)
            }), byExtendingSelection: false)
            isReloading = false
        })
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 2 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        section == PinnedTabLayout.Section.tabs.rawValue ? displayedPins.count : 0
    }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = displayedPins[indexPath.item]
        if let right = item.secondaryPin {
            let left = liveState?.pinnedTabs.first { $0.guidInLocalDB == item.id } ?? item.pin
            let right = liveState?.pinnedTabs.first { $0.guidInLocalDB == item.secondaryID } ?? right
            let cell = collectionView.makeItem(withIdentifier: PinnedSplitItem.reuseIdentifier, for: indexPath) as! PinnedSplitItem
            cell.populateContextMenu = { [weak self] menu in self?.populatePinMenu(menu, item: item) }
            cell.configure(leftTab: left, rightTab: right, browserState: liveState, themeProvider: themeSource)
            cell.itemDoubleClicked = { [weak self] _, _ in self?.open(itemID: item.id, isPin: true) }
            cell.itemClicked = { [weak collectionView] _ in collectionView?.selectionIndexPaths = [indexPath] }
            return cell
        }
        let cell = collectionView.makeItem(withIdentifier: PinnedTabItem.reuseIdentifier, for: indexPath) as! PinnedTabItem
        cell.populateContextMenu = { [weak self] menu in self?.populatePinMenu(menu, item: item) }
        cell.configure(with: liveState?.pinnedTabs.first { $0.guidInLocalDB == item.id } ?? item.pin,
                       browserState: liveState, themeProvider: themeSource)
        cell.itemDoubleClicked = { [weak self] _, _ in self?.open(itemID: item.id, isPin: true) }
        cell.itemClicked = { [weak collectionView] _, _ in collectionView?.selectionIndexPaths = [indexPath] }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let snapshot else { return 0 }
        return (item as? Bookmark).map { snapshot.childIDs(of: $0.id).count } ?? snapshot.rootIDs.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let snapshot else { return contents.bookmarkManager.rootFolder }
        let ids = (item as? Bookmark).map { snapshot.childIDs(of: $0.id) } ?? snapshot.rootIDs
        return snapshot.item(for: ids[index]) ?? contents.bookmarkManager.rootFolder
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Bookmark)?.isFolder == true }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Bookmark)?.isFolder == false
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let bookmark = item as? Bookmark else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("libraryBookmark")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? BookmarkCellView) ?? BookmarkCellView()
        cell.identifier = identifier
        cell.usesActiveBrowserStateFallback = false
        cell.browserState = liveState
        cell.editDelegate = self
        cell.onSelectFolderIcon = { [weak self] bookmark, icon in
            guard let self, validStore() != nil, validBookmark(bookmark.guid) else { return }
            actionManager.updateFolderIcon(guid: bookmark.guid, iconName: icon.rawValue)
            log("folder.icon", ids: [bookmark.guid])
        }
        cell.configure(with: bookmark)
        cell.setManagementSelected(outline.selectedRowIndexes.contains(outline.row(forItem: bookmark)))
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        for row in 0..<outline.numberOfRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkCellView)?
                .setManagementSelected(outline.selectedRowIndexes.contains(row))
        }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? Bookmark else { return }
        item.isExpanded = true
        if !isReloading { expandedIDs.insert(item.guid) }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? Bookmark else { return }
        item.isExpanded = false
        if !isReloading { expandedIDs.remove(item.guid) }
    }
    func bookmarkCellDidEndEditing(_ bookmark: Bookmark, newTitle: String) {
        guard validStore() != nil, validBookmark(bookmark.guid) else { return }
        actionManager.updateBookmark(guid: bookmark.guid, title: newTitle)
        log("bookmark.rename", ids: [bookmark.guid])
    }

    private func pinDropIndex(_ info: NSDraggingInfo) -> Int {
        let point = pins.convert(info.draggingLocation, from: nil)
        for index in displayedPins.indices {
            guard let frame = pinLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 1))?.frame else { continue }
            if point.y < frame.minY || (point.y <= frame.maxY && point.x < frame.midX) { return index }
        }
        return displayedPins.count
    }
    private func updatePinDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        let accepted = validPinDrop(info) != nil
        let index = pinDropIndex(info)
        recordDropValidation("pin index=\(index) accepted=\(accepted)")
        guard accepted else { pinDropIndicator.isHidden = true; return [] }
        let before = index < displayedPins.count
        let target = before ? index : max(0, displayedPins.count - 1)
        let frame = pinLayout.layoutAttributesForItem(at: IndexPath(item: target, section: 1))?.frame
            ?? NSRect(x: 4, y: 4, width: 0, height: 37)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pinDropIndicator.backgroundColor = ThemedColor.textPrimary.resolve(theme: themeSource.currentTheme, appearance: themeSource.currentAppearance).cgColor
        pinDropIndicator.frame = NSRect(x: before ? max(0, frame.minX - 4) : frame.maxX + 2,
                                      y: frame.minY, width: 2, height: frame.height)
        pinDropIndicator.isHidden = false
        CATransaction.commit()
        if let event = NSApp.currentEvent { _ = pins.autoscroll(with: event) }
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let id = displayedPins[indexPath.item].id
        log("pin.drag.begin", ids: [id])
        return LibrarySpaceItemDrag(contents: contents, ids: [id], isPin: true).writer()
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        NotificationCenter.default.post(name: LibrarySpaceItemDrag.didBegin, object: session.draggingPasteboard)
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        NotificationCenter.default.post(name: LibrarySpaceItemDrag.didEnd, object: nil)
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        NotificationCenter.default.post(name: LibrarySpaceItemDrag.didBegin, object: session.draggingPasteboard)
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NotificationCenter.default.post(name: LibrarySpaceItemDrag.didEnd, object: nil)
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard validPinDrop(draggingInfo) != nil else { return [] }
        proposedDropIndexPath.pointee = NSIndexPath(forItem: min(max(proposedDropIndexPath.pointee.item, 0), displayedPins.count), inSection: PinnedTabLayout.Section.tabs.rawValue)
        proposedDropOperation.pointee = .before
        return .move
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let drag = validPinDrop(draggingInfo), let id = drag.ids.first, let store = validStore() else { return false }
        let index = displayedPins.prefix(indexPath.item).reduce(0) { $0 + ($1.secondaryID == nil ? 1 : 2) }
        if !drag.isPin {
            return acceptBookmarksAsPins(draggingInfo, drag: drag, index: index)
        }
        let mirrored = samePinnedOwner(profileID: drag.profileID, spaceID: drag.spaceID)
        AppLogInfo("[LibrarySpaces] pin.drop sameOwner=\(mirrored) target=\(contents.scope.spaceId) source=\(drag.spaceID)")
        Task {
            do {
                let result = try await store.transferPinnedTab(guid: id, sourceProfileId: drag.profileID, sourceSpaceId: drag.spaceID,
                    targetProfileId: contents.scope.profileId, targetSpaceId: contents.scope.spaceId,
                    destinationIndex: index, destinationIndexIncludesSourceUnit: mirrored)
                detachRemovedPins(Set(result.guidMapping.compactMap { $0.key == $0.value ? nil : $0.key }))
                log("pin.drop.saved", ids: drag.ids, source: drag.spaceID)
            } catch { AppLogError("[LibrarySpaces] pin.drop.failed error=\(error)") }
        }
        return true
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let bookmark = item as? Bookmark else { return nil }
        log("bookmark.drag.begin", ids: [bookmark.guid])
        let ids = outline.selectedRowIndexes.contains(outline.row(forItem: bookmark)) ? selectedBookmarks.map(\.guid) : [bookmark.guid]
        return LibrarySpaceItemDrag(contents: contents, ids: ids, isPin: false).writer()
    }
    private func bookmarkDropPlan(_ info: NSDraggingInfo, item: Any?, index: Int) -> BookmarkManagerDropPlan? {
        guard let drag = validDrag(info, isPin: false),
              let source = info.draggingSource as? LibraryBookmarkOutline,
              let sourceController = source.dataSource as? LibrarySpaceManagementController,
              sourceController.validStore() != nil,
              sourceController.contents.scope.spaceId == drag.spaceID,
              sourceController.contents.scope.profileId == drag.profileID else { return nil }
        let target: BookmarkManagerDropTarget
        if let bookmark = item as? Bookmark {
            target = index == NSOutlineViewDropOnItemIndex ? .onFolder(guid: bookmark.guid)
                : .betweenSiblings(parentGuid: bookmark.guid, index: index)
        } else {
            target = .atRoot(index: index < 0 ? roots.count : index)
        }
        guard case .move(let plan) = BookmarkManagerDropResolver.resolve(
            orderedBookmarkGuids: drag.ids, target: target,
            rootFolder: sourceController.contents.bookmarkManager.rootFolder, isSearchActive: false,
            destinationRootFolder: contents.bookmarkManager.rootFolder) else { return nil }
        return plan
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        var destination = item
        var childIndex = index
        if let folder = item as? Bookmark, folder.isFolder,
           let remapped = SidebarBookmarkFolderDropResolver.remappedTarget(
                folder: folder, outlineView: outlineView, locationInWindow: info.draggingLocation,
                proposedChildIndex: index, siblings: folder.parent?.children ?? roots) {
            destination = remapped.item
            childIndex = remapped.childIndex
        }
        // A drop on the root draws AppKit's outline-wide destination border.
        // Show the append position instead, matching the resolved move target.
        if destination == nil, childIndex == NSOutlineViewDropOnItemIndex {
            childIndex = roots.count
        }
        let accepted = pinBookmarkDropIsValid(info, item: destination)
            || bookmarkDropPlan(info, item: destination, index: childIndex) != nil
        recordDropValidation("bookmark parent=\((destination as? Bookmark)?.guid ?? "root") index=\(childIndex) accepted=\(accepted)")
        guard accepted else { return [] }
        outlineView.setDropItem(destination, dropChildIndex: childIndex)
        return .move
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if pinBookmarkDropIsValid(info, item: item) {
            return acceptPinAsBookmark(info, parent: item as? Bookmark, index: max(index, 0))
        }
        guard let drag = validDrag(info, isPin: false), validStore() != nil,
              let plan = bookmarkDropPlan(info, item: item, index: index) else { return false }
        if drag.spaceID == contents.scope.spaceId && drag.profileID == contents.scope.profileId {
            contents.bookmarkManager.moveBookmarks(plan)
        } else if let source = info.draggingSource as? LibraryBookmarkOutline,
                  let sourceController = source.dataSource as? LibrarySpaceManagementController,
                  let target = SpaceManager.shared.spaces.first(where: { $0.spaceId == contents.scope.spaceId }) {
            guard sourceController.moveBookmarks(plan.orderedBookmarkGuids, to: target,
                                                 targetParentId: plan.destinationParentGuid,
                                                 destinationIndex: plan.destinationIndex) else { return false }
        } else {
            return false
        }
        log("bookmark.drop parent=\(plan.destinationParentGuid ?? "root") index=\(plan.destinationIndex)", ids: drag.ids, source: drag.spaceID)
        if let parent = item as? Bookmark { expandedIDs.insert(parent.guid); outline.expandItem(parent) }
        return true
    }
    private func validDrag(_ info: NSDraggingInfo, isPin: Bool? = nil) -> LibrarySpaceItemDrag? {
        guard validStore() != nil, let drag = LibrarySpaceItemDrag.read(info),
              drag.storeID == contents.storeIdentifier, isPin == nil || drag.isPin == isPin,
              !drag.ids.isEmpty,
              !drag.isPin || drag.pinnedScope == contents.store?.pinnedTabScope().rawValue,
              let source = sourceController(info), source.validStore() != nil,
              source.contents.scope.profileId == drag.profileID,
              source.contents.scope.spaceId == drag.spaceID,
              source.contents.storeIdentifier == drag.storeID else { return nil }
        return drag
    }

    private func sourceController(_ info: NSDraggingInfo) -> LibrarySpaceManagementController? {
        if let collection = info.draggingSource as? NSCollectionView {
            return collection.dataSource as? LibrarySpaceManagementController
        }
        return (info.draggingSource as? NSOutlineView)?.dataSource as? LibrarySpaceManagementController
    }

    private func validPinDrop(_ info: NSDraggingInfo) -> LibrarySpaceItemDrag? {
        guard let drag = validDrag(info), let source = sourceController(info) else { return nil }
        if drag.isPin {
            return drag.ids.count == 1 && source.displayedPins.contains(where: { $0.id == drag.ids[0] }) ? drag : nil
        }
        return drag.ids.allSatisfy {
            source.validBookmark($0) && source.contents.bookmarkManager.bookmark(withGuid: $0)?.isFolder == false
        } ? drag : nil
    }

    private func pinBookmarkDropIsValid(_ info: NSDraggingInfo, item: Any?) -> Bool {
        guard let drag = validPinDrop(info), drag.isPin else { return false }
        guard let item else { return true }
        guard let folder = item as? Bookmark, folder.isFolder else { return false }
        return validBookmarkFolder(folder.guid)
    }

    private func acceptBookmarksAsPins(_ info: NSDraggingInfo, drag: LibrarySpaceItemDrag, index: Int) -> Bool {
        guard let store = validStore(), let source = sourceController(info) else { return false }
        let bookmarks = drag.ids.compactMap { source.contents.bookmarkManager.bookmark(withGuid: $0) }
        guard bookmarks.count == drag.ids.count else { return false }
        if samePinnedOwner(profileID: drag.profileID, spaceID: drag.spaceID), let state = source.conversionState {
            // Use the sidebar path when a runtime exists, retaining live tab and split bindings.
            source.prepareLiveBookmarksForRemoval(bookmarks, moving: true, excluding: state)
            var afterGuid = displayedPins.flatMap { [$0.id, $0.secondaryID].compactMap { $0 } }.prefix(index).last
            for bookmark in bookmarks {
                guard let guid = state.moveBookmarkOut(bookmark, afterPinnedGuid: afterGuid) else { return false }
                afterGuid = guid
            }
        } else {
            Task {
                do {
                    source.prepareLiveBookmarksForRemoval(bookmarks, moving: true)
                    try await store.convertBookmarksToPinnedTabs(drag.ids,
                        sourceProfileId: drag.profileID, sourceSpaceId: drag.spaceID,
                        targetProfileId: contents.scope.profileId, targetSpaceId: contents.scope.spaceId,
                        destinationIndex: index)
                } catch { AppLogError("[LibrarySpaces] bookmark.pin.failed error=\(error)") }
            }
        }
        return true
    }

    private func acceptPinAsBookmark(_ info: NSDraggingInfo, parent: Bookmark?, index: Int) -> Bool {
        guard let drag = validDrag(info, isPin: true), let id = drag.ids.first,
              let store = validStore() else { return false }
        if samePinnedOwner(profileID: drag.profileID, spaceID: drag.spaceID), let state = conversionState,
           let pin = state.pinnedTabs.first(where: { $0.guidInLocalDB == id }) {
            let ids = Set([id, pin.splitPartnerGuid].compactMap { $0 })
            state.movePinnedTabOut(pinnedGuid: id, toBookmark: parent?.guid, index: index)
            detachRemovedPins(ids)
        } else {
            Task {
                do {
                    let removed = try await store.convertPinnedTabToBookmark(id,
                        sourceProfileId: drag.profileID, sourceSpaceId: drag.spaceID,
                        targetProfileId: contents.scope.profileId, targetSpaceId: contents.scope.spaceId,
                        parentGuid: parent?.guid, destinationIndex: index)
                    detachRemovedPins(removed)
                } catch { AppLogError("[LibrarySpaces] pin.bookmark.failed error=\(error)") }
            }
        }
        if let parent { expandedIDs.insert(parent.guid); outline.expandItem(parent) }
        return true
    }

    private var conversionState: BrowserState? {
        liveState ?? SpaceSessionControllersManager.shared.getAllWindows().map(\.browserState).first {
            !$0.isIncognito && $0.localStore.identifier == contents.storeIdentifier
                && $0.profileId == contents.scope.profileId && $0.spaceId == contents.scope.spaceId
        }
    }

    private func samePinnedOwner(profileID: String, spaceID: String) -> Bool {
        guard let scope = contents.store?.pinnedTabScope() else { return false }
        return LocalStore.pinnedTransferOwner(scope: scope, profileId: profileID, spaceId: spaceID)
            == LocalStore.pinnedTransferOwner(scope: scope, profileId: contents.scope.profileId, spaceId: contents.scope.spaceId)
    }

    private var liveState: BrowserState? {
        guard let window = view.window,
              let host = SpaceSessionControllersManager.shared.findControllerWith(window: window),
              let state = host.slot?
                .windowController(for: contents.scope.spaceId)?.browserState,
              state.localStore.identifier == contents.storeIdentifier,
              state.profileId == contents.scope.profileId else { return nil }
        return state
    }
    private var actionManager: BookmarkManager { liveState?.bookmarkManager ?? contents.bookmarkManager }

    /// Library can manage a Space that exists only in another window slot.
    /// Clean every matching runtime without repeating persistence per window.
    static func prepareLiveBookmarksForRemoval(_ bookmarks: [Bookmark],
                                              scope: BookmarkManagementScope,
                                              storeIdentifier: UUID,
                                              states: [BrowserState],
                                              moving: Bool) {
        var leafGuids = Set<String>()
        func collect(_ bookmark: Bookmark) {
            if bookmark.isFolder { bookmark.children.forEach(collect) }
            else { leafGuids.insert(bookmark.guid) }
        }
        bookmarks.forEach(collect)
        for state in states where !state.isIncognito
            && state.localStore.identifier == storeIdentifier
            && state.profileId == scope.profileId && state.spaceId == scope.spaceId {
            if moving {
                state.detachBookmarkTabsForComfortableLayout(bookmarkGuids: leafGuids)
            } else {
                bookmarks.forEach { state.closeOpenTabsForRemovedBookmark($0) }
            }
            state.updateNormalTabs()
        }
    }

    private func prepareLiveBookmarksForRemoval(_ bookmarks: [Bookmark], moving: Bool, excluding state: BrowserState? = nil) {
        Self.prepareLiveBookmarksForRemoval(bookmarks, scope: contents.scope,
            storeIdentifier: contents.storeIdentifier,
            states: SpaceSessionControllersManager.shared.getAllWindows().map(\.browserState).filter { $0 !== state },
            moving: moving)
    }

    @discardableResult
    private func moveBookmarks(_ ids: [String], to target: Space,
                               targetParentId: String? = nil, destinationIndex: Int? = nil) -> Bool {
        guard let store = validStore(),
              SpaceManager.shared.acceptsStoreAction(from: target.storeIdentifier) else { return false }
        if let state = liveState, !state.canMoveBookmarks(bookmarkGuids: ids, to: target) { return false }
        let bookmarks = ids.filter(validBookmark).compactMap { contents.bookmarkManager.bookmark(withGuid: $0) }
        guard !bookmarks.isEmpty else { return false }
        prepareLiveBookmarksForRemoval(bookmarks, moving: true)
        store.moveBookmarks(bookmarks.map(\.guid), sourceProfileId: contents.scope.profileId,
                            toSpaceId: target.spaceId, targetProfileId: target.profileId,
                            sourceSpaceId: contents.scope.spaceId, targetParentId: targetParentId,
                            destinationIndex: destinationIndex)
        return true
    }

    private func detachRemovedPins(_ ids: Set<String>) {
        for controller in SpaceSessionControllersManager.shared.getAllWindows()
            where controller.browserState.localStore.identifier == contents.storeIdentifier {
            controller.browserState.detachLiveTabsFromRemovedPins(ids)
        }
    }

    private func validStore() -> LocalStore? {
        guard let store = contents.store, !store.isClosedForAccountDirectoryRemoval,
              SpaceManager.shared.acceptsStoreAction(from: contents.storeIdentifier),
              SpaceManager.shared.spaces.contains(where: { $0.spaceId == contents.scope.spaceId && $0.profileId == contents.scope.profileId }) else { return nil }
        return store
    }
    private func validBookmark(_ id: String) -> Bool {
        guard let row = validStore()?.getTab(by: id) else { return false }
        return row.profileId == contents.scope.profileId && row.spaceId == contents.scope.spaceId
            && (row.dataType == .bookmark || row.dataType == .bookmarkFolder)
    }
    private func recordDropValidation(_ value: String) {
        guard value != lastDropValidation else { return }
        lastDropValidation = value
        log("drop.validate \(value)")
    }

    private func log(_ action: String, ids: [String] = [], source: String? = nil) {
        AppLogInfo("[LibrarySpaces] \(action) space=\(contents.scope.spaceId) source=\(source ?? contents.scope.spaceId) ids=\(ids)")
    }

    @discardableResult
    private func addAction(_ title: String, to menu: NSMenu, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        menu.addItem(item)
        return item
    }
    @objc private func runMenuAction(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }

    @objc private func showMoreMenu(_ sender: NSView) {
        guard validStore() != nil,
              let space = SpaceManager.shared.spaces.first(where: { $0.spaceId == contents.scope.spaceId }) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        addCreateActions(to: menu, parent: nil)
        menu.addItem(.separator())

        let profileItem = NSMenuItem(title: NSLocalizedString("library.spaces.setProfile", value: "Set Profile", comment: "Library Space menu - choose the Space profile"), action: nil, keyEquivalent: "")
        let profiles = NSMenu()
        profiles.autoenablesItems = false
        for profile in ProfileManager.shared.userAssignableProfiles {
            let item = addAction(profile.displayName, to: profiles) { [weak self] in
                guard let self, validStore() != nil else { return }
                AppController.shared.confirmSpaceProfileChange(space, to: profile.profileId)
            }
            item.state = profile.profileId == space.profileId ? .on : .off
        }
        profileItem.submenu = profiles
        profileItem.isEnabled = space.spaceId != LocalStore.defaultSpaceId
            && !space.isAgentSpace && !AgentSpaceManager.shared.isAgentSpace(space.spaceId)
        menu.addItem(profileItem)

        let deleteItem = addAction(NSLocalizedString("library.spaces.deleteSpace", value: "Delete Space…", comment: "Library Space menu - delete this Space after confirmation"), to: menu) { [weak self] in
            guard let self, validStore() != nil else { return }
            AppController.shared.confirmSpaceDeletion(space)
        }
        deleteItem.isEnabled = SpaceManager.shared.canDeleteSpace(spaceId: space.spaceId)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    private func addCreateActions(to menu: NSMenu, parent: Bookmark?) {
        addAction(NSLocalizedString("library.spaces.newPin", value: "New Pinned Tab…", comment: "Library Space menu - create pinned tab"), to: menu) { [weak self] in self?.editPin(nil) }
        addAction(NSLocalizedString("library.spaces.newBookmark", value: "New Bookmark…", comment: "Library Space menu - create bookmark"), to: menu) { [weak self] in self?.editBookmark(nil, parent: parent, folder: false) }
        addAction(NSLocalizedString("library.spaces.newFolder", value: "New Folder…", comment: "Library Space menu - create folder"), to: menu) { [weak self] in self?.editBookmark(nil, parent: parent, folder: true) }
    }
    private func bookmarkMenu(row: Int) -> NSMenu {
        let menu = NSMenu()
        let bookmark = row >= 0 && row < outline.numberOfRows ? outline.item(atRow: row) as? Bookmark : nil
        if let bookmark {
            if !bookmark.isFolder && !outline.selectedRowIndexes.contains(row) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let targets = bookmark.isFolder ? [bookmark] : selectedBookmarks
            if !bookmark.isFolder {
                addAction(NSLocalizedString("library.spaces.openItem", value: "Open", comment: "Library Space menu - open item"), to: menu) { [weak self] in self?.open(itemID: bookmark.guid, isPin: false) }
            }
            addAction(NSLocalizedString("library.spaces.editItem", value: "Edit…", comment: "Library Space menu - edit item"), to: menu) { [weak self] in self?.editBookmark(bookmark, parent: bookmark.parent, folder: bookmark.isFolder) }
            addMoveActions(to: menu, ids: targets.map(\.guid), isPin: false)
            addAction(NSLocalizedString("library.spaces.deleteItem", value: "Delete", comment: "Library Space menu - delete item"), to: menu) { [weak self] in self?.deleteBookmarks(targets) }
        } else {
            addCreateActions(to: menu, parent: nil)
        }
        log("bookmark.menu", ids: bookmark.map { [$0.guid] } ?? [])
        return menu
    }
    private func populatePinMenu(_ menu: NSMenu, item: LibrarySpaceContents.Item) {
        menu.removeAllItems()
        addAction(NSLocalizedString("library.spaces.openItem", value: "Open", comment: "Library Space menu - open item"), to: menu) { [weak self] in self?.open(itemID: item.id, isPin: true) }
        addAction(NSLocalizedString("library.spaces.editItem", value: "Edit…", comment: "Library Space menu - edit item"), to: menu) { [weak self] in
            self?.editPin(item.pin, secondaryTab: item.secondaryPin)
        }
        addMoveActions(to: menu, ids: [item.id], isPin: true)
        addAction(NSLocalizedString("library.spaces.deleteItem", value: "Delete", comment: "Library Space menu - delete item"), to: menu) { [weak self] in
            guard let self, let store = validStore() else { return }
            Task {
                do {
                    let removed = try await store.removePinnedTabUnit(guid: item.id,
                        profileId: self.contents.scope.profileId, spaceId: self.contents.scope.spaceId)
                    self.detachRemovedPins(removed)
                } catch { AppLogError("[LibrarySpaces] pin.delete.failed error=\(error)") }
            }
            log("pin.delete", ids: [item.id])
        }
        log("pin.menu", ids: [item.id])
    }
    private func addMoveActions(to menu: NSMenu, ids: [String], isPin: Bool) {
        let item = NSMenuItem(title: NSLocalizedString("library.spaces.moveToSpace", value: "Move to Space", comment: "Library Space menu - move items to another Space"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for space in SpaceManager.shared.spaces where space.spaceId != contents.scope.spaceId && !space.isAgentSpace && !SpaceManager.isIncognitoSpaceId(space.spaceId) {
            if isPin && samePinnedOwner(profileID: space.profileId, spaceID: space.spaceId) { continue }
            addAction(space.name, to: submenu) { [weak self] in
                guard let self, let store = validStore(), SpaceManager.shared.acceptsStoreAction(from: space.storeIdentifier) else { return }
                log("item.move", ids: ids, source: space.spaceId)
                if isPin, let id = ids.first {
                    Task {
                        do {
                            let result = try await store.transferPinnedTab(guid: id, sourceProfileId: self.contents.scope.profileId,
                                sourceSpaceId: self.contents.scope.spaceId, targetProfileId: space.profileId,
                                targetSpaceId: space.spaceId, destinationIndex: Int.max)
                            self.detachRemovedPins(Set(result.guidMapping.compactMap { $0.key == $0.value ? nil : $0.key }))
                        } catch { AppLogError("[LibrarySpaces] pin.move.failed error=\(error)") }
                    }
                } else {
                    moveBookmarks(ids, to: space)
                }
            }
        }
        if !submenu.items.isEmpty { item.submenu = submenu; menu.addItem(item) }
    }
    private var selectedBookmarks: [Bookmark] { outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Bookmark } }
    private func deleteSelectedBookmarks() {
        deleteBookmarks(selectedBookmarks)
    }
    private func deleteBookmarks(_ targets: [Bookmark]) {
        guard validStore() != nil else { return }
        let ids = targets.map(\.guid).filter(validBookmark)
        let bookmarks = ids.compactMap { contents.bookmarkManager.bookmark(withGuid: $0) }
        prepareLiveBookmarksForRemoval(bookmarks, moving: false)
        bookmarks.forEach { contents.bookmarkManager.removeBookmark($0) }
        log("bookmark.delete", ids: ids)
    }
    private func validBookmarkFolder(_ id: String?) -> Bool {
        guard let id else { return true }
        guard let row = validStore()?.getTab(by: id) else { return false }
        return row.dataType == .bookmarkFolder && row.profileId == contents.scope.profileId
            && row.spaceId == contents.scope.spaceId
    }

    private func editBookmark(_ bookmark: Bookmark?, parent: Bookmark?, folder: Bool) {
        guard let store = validStore(), bookmark == nil || validBookmark(bookmark!.guid) else { return }
        let originalParentGuid = parent?.guid
        let secondaryURL = bookmark?.secondaryUrl
        // Folder creation and bookmark writes are queued in order; the new folder
        // may not have reached the main-context subscription when Save runs.
        var createdFolderGuid: String?
        log(bookmark == nil ? "bookmark.create.begin" : "bookmark.edit.begin", ids: bookmark.map { [$0.guid] } ?? [])
        EditPinnedTabPresenter.presentModal(
            mode: folder ? (bookmark == nil ? .newFolder : .folder) : (bookmark == nil ? .newBookmark : .bookmark),
            title: bookmark?.title ?? "", urlString: bookmark?.url ?? "",
            secondaryUrlString: secondaryURL, secondaryTitleString: bookmark?.secondaryTitle,
            modelContainer: store.container,
            profileId: contents.scope.profileId, spaceId: contents.scope.spaceId,
            initialFolderGuid: originalParentGuid,
            from: view.window,
            onCreateFolder: { [weak self] name in
                guard let self, validStore() != nil else { return nil }
                let guid = UUID().uuidString
                actionManager.addFolder(title: name, guid: guid)
                createdFolderGuid = guid
                return guid
            },
            onValidate: { [weak self] result in
                guard let self, let store = validStore(),
                      bookmark == nil || validBookmark(bookmark!.guid),
                      validBookmarkFolder(folder ? originalParentGuid : result.parentFolderGuid),
                      folder || store.normalizedURL(from: result.url) != nil,
                      secondaryURL == nil || store.normalizedURL(from: result.secondaryUrl) != nil else {
                    NSSound.beep()
                    return false
                }
                return true
            }
        ) { [weak self] result in
            guard let self, let store = validStore(), bookmark == nil || validBookmark(bookmark!.guid) else { return }
            let parentGuid = folder ? originalParentGuid : result.parentFolderGuid
            guard (parentGuid != nil && parentGuid == createdFolderGuid) || validBookmarkFolder(parentGuid) else { return }
            if let bookmark {
                actionManager.updateBookmark(guid: bookmark.guid, title: result.title,
                    url: folder ? nil : result.url,
                    secondaryUrl: secondaryURL == nil ? nil : .some(result.secondaryUrl ?? ""),
                    secondaryTitle: secondaryURL == nil ? nil : .some(result.secondaryTitle ?? ""))
                if !folder && parentGuid != originalParentGuid {
                    store.moveBookmark(bookmark.guid, profileId: contents.scope.profileId,
                                       to: parentGuid, newIndex: Int.max)
                }
            } else if folder {
                actionManager.addFolder(title: result.title ?? "", to: parent)
            } else if let url = result.url {
                actionManager.addBookmark(title: result.title ?? "", url: url, toParentGuid: parentGuid)
            }
            if let parentGuid { expandedIDs.insert(parentGuid) }
            log("bookmark.edit.save", ids: bookmark.map { [$0.guid] } ?? [])
        }
    }
    private func editPin(_ tab: Tab?, secondaryTab: Tab? = nil) {
        guard validStore() != nil else { return }
        EditPinnedTabPresenter.presentModal(
            mode: tab == nil ? .newPin : .pin,
            title: tab?.title ?? "", urlString: tab?.url ?? "",
            secondaryUrlString: secondaryTab?.url, secondaryTitleString: secondaryTab?.title,
            from: view.window,
            onValidate: { [weak self] result in
                guard let self, let store = validStore(),
                      store.normalizedURL(from: result.url) != nil,
                      secondaryTab == nil || store.normalizedURL(from: result.secondaryUrl) != nil,
                      secondaryTab == nil || contents.pins.contains(where: {
                          $0.id == tab?.guidInLocalDB && $0.secondaryID == secondaryTab?.guidInLocalDB
                      }),
                      tab == nil || store.getAllPinnedTabs(for: contents.scope.profileId, spaceId: contents.scope.spaceId)
                        .contains(where: { $0.guid == tab?.guidInLocalDB }) else {
                    NSSound.beep()
                    return false
                }
                return true
            }
        ) { [weak self] result in
            guard let self, let store = validStore(), let rawURL = result.url,
                  let url = URL(string: URLProcessor.processUserInput(rawURL)) else { return }
            if let id = tab?.guidInLocalDB {
                guard store.getAllPinnedTabs(for: contents.scope.profileId, spaceId: contents.scope.spaceId).contains(where: { $0.guid == id }) else { return }
                if let secondaryTab {
                    guard let secondaryID = secondaryTab.guidInLocalDB,
                          contents.pins.contains(where: { $0.id == id && $0.secondaryID == secondaryID }),
                          let secondaryURL = store.normalizedURL(from: result.secondaryUrl) else { return }
                    store.updatePinnedTab(resolving: secondaryID, profileId: contents.scope.profileId,
                                          spaceId: contents.scope.spaceId, url: secondaryURL, title: result.secondaryTitle)
                }
                store.updatePinnedTab(resolving: id, profileId: contents.scope.profileId, spaceId: contents.scope.spaceId, url: url, title: result.title)
            } else {
                store.createPinnedTab(guid: UUID().uuidString, url: url.absoluteString, title: result.title ?? "",
                                      profileId: contents.scope.profileId, spaceId: contents.scope.spaceId)
            }
            log("pin.edit.save", ids: [tab?.guidInLocalDB, secondaryTab?.guidInLocalDB].compactMap { $0 })
        }
    }
    @objc private func toggleClickedFolder() {
        let modifiers = outline.consumeMouseDownModifierFlags() ?? NSApp.currentEvent?.modifierFlags ?? []
        guard modifiers.intersection([.command, .shift, .option, .control]).isEmpty,
              outline.editedRow == -1,
              outline.clickedRow >= 0,
              let bookmark = outline.item(atRow: outline.clickedRow) as? Bookmark,
              bookmark.isFolder, !bookmark.isEditing else { return }
        if outline.isItemExpanded(bookmark) { outline.collapseItem(bookmark) }
        else { outline.expandItem(bookmark) }
        log("folder.toggle", ids: [bookmark.guid])
    }
    @objc private func openSelectedBookmark() {
        guard outline.clickedRow >= 0,
              let bookmark = outline.item(atRow: outline.clickedRow) as? Bookmark,
              !bookmark.isFolder else { return }
        open(itemID: bookmark.guid, isPin: false)
    }
    private func open(itemID: String, isPin: Bool) {
        guard validStore() != nil,
              let window = view.window,
              let host = SpaceSessionControllersManager.shared.findControllerWith(window: window),
              let slot = host.slot else { return }
        let scope = contents.scope
        host.dismissLibraryIfVisible()
        slot.activate(spaceId: scope.spaceId, onSwapSettled: { [self, weak slot] in
            guard validStore() != nil,
                  let state = slot?.windowController(for: scope.spaceId)?.browserState else { return }
            if isPin, let pin = state.pinnedTabs.first(where: { $0.guidInLocalDB == itemID }) { state.openOrFocusPinnedTab(pin) }
            else if let bookmark = state.bookmarkManager.bookmark(withGuid: itemID) { state.openBookmark(bookmark) }
            log("item.open", ids: [itemID])
        })
    }
}
