// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

protocol SidebarTabListItemOwner {
    func toggleItemExpanded(_ item: SidebarItem)
    func newTabClicked(_ item: SidebarItem)
    func bookmarkClicked(_ item: SidebarItem)
}
class SidebarTabListViewController: NSViewController {
    private static let bottomContentInset: CGFloat = 130

    /// A temporary, UI-only representation of the currently focusing bookmark tab.
    /// This is used to keep the focusing bookmark visible even when its real parent folders are collapsed.
    final class FocusedBookmarkSidebarItem: SidebarItem, UnderlyingBookmarkProviding, ContextMenuRepresentable, SidebarIndentationLevelProviding {
        var isBookmark: Bool { true }
        
        let underlyingBookmark: Bookmark
        let id: AnyHashable
        let indentationLevelOverride: Int?
        
        init(bookmark: Bookmark, indentationLevelOverride: Int?) {
            self.underlyingBookmark = bookmark
            self.id = AnyHashable("focused-bookmark-proxy:\(bookmark.guid)")
            self.indentationLevelOverride = indentationLevelOverride
        }
        
        var title: String { underlyingBookmark.title }
        var url: String? { underlyingBookmark.url }
        var iconName: String? { underlyingBookmark.iconName }
        var faviconUrl: String? { underlyingBookmark.faviconUrl }
        var isExpandable: Bool { false }
        var hasChildren: Bool { false }
        var childrenItems: [SidebarItem] { [] }
        var depth: Int { underlyingBookmark.depth }
        var itemType: SidebarItemType { .bookmark }
        var isActive: Bool { underlyingBookmark.isActive }
        var isSelectable: Bool { true }
        
        func performAction(with owner: SidebarTabListItemOwner?) {
            owner?.bookmarkClicked(underlyingBookmark)
        }
        
        func makeContextMenu(on menu: NSMenu) {
            underlyingBookmark.makeContextMenu(on: menu, source: .sidebar)
        }
    }
    
    private var outlineView: SideBarOutlineView!
    private var scrollView: NSScrollView!
    
    private let tabSectionController = TabSectionController()
    private let separatorItem = SeparatorItem()
    private var lastSelectedItem: SidebarItem?
    
    private lazy var bookmarkSectionController: BookmarkSectionController = {
        return BookmarkSectionController(browserState: browserState)
    }()
    
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    private lazy var contextMenuHelper = TabAreaContextMenuHelper(browserState: browserState)
    
    private var cancellables = Set<AnyCancellable>()
    private var allItems: [SidebarItem] = []
    
    /// UI-only state: when non-nil, we temporarily "reparent" the focusing bookmark to keep it visible.
    /// This never mutates the real `Bookmark.parent`.
    private var focusedBookmarkPresentation: (proxy: FocusedBookmarkSidebarItem, insertionParent: SidebarItem?, insertionIndex: Int)?
    
    /// Sticky floating bookmark state:
    /// When a folder is collapsed while a bookmark is focusing, we create a floating proxy that should remain
    /// visible even if focusing changes later. It is removed only when the anchor folder is expanded again.
    private var floatingBookmarkGuid: String?
    private var floatingAnchorFolderGuid: String?
    
    /// Tracks the folder GUID that the user explicitly toggled (expand/collapse).
    /// NSOutlineView will also collapse descendant folders when collapsing an ancestor; we must NOT
    /// treat those descendant collapses as user intent, otherwise we would incorrectly reset their
    /// `Bookmark.isExpanded` state (e.g. F2 becomes "closed" when collapsing F1).
    private var userInitiatedToggleFolderGuid: String?
    
    /// Transition-only state: when collapsing an ancestor folder, we temporarily remove the real bookmark row
    /// so it doesn't get animated "into" the collapsing folder. This is UI-only and never mutates the model.
    private var temporarilyHiddenRealBookmarkGuid: String?
    
    /// UI-only drag state for folder drop feedback.
    private var dropFeedbackFolderGuid: String?
    
    /// Temporarily allows folder expansion even during drag, used by `expandFloatingBookmarkParentsIfNeeded`.
    private var allowExpandDuringDrag = false
    
    private var scrollAnimationGeneration: Int = 0
    private var scrollScheduleGeneration: Int = 0
    private var isActive = false
    
    /// Tracks the identity of the focusing tab we last scrolled to.
    /// Scroll is skipped when the focusing tab hasn't changed (e.g. bookmark expand/collapse).
    private var lastScrolledFocusingTabId: AnyHashable?

    /// Flag to control whether bookmarks are shown in the sidebar
    private var showBookmarks: Bool = true
    
    private var browserState: BrowserState
    private weak var hostVC: NSViewController?
    
    init(state: BrowserState, hostVC: NSViewController? = nil) {
        self.browserState = state
        self.hostVC = hostVC
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        view = NSView()
        setupOutlineView()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupAppearance()
        setupDelegates()
    }
    
    private func setupOutlineView() {
        scrollView = OverlayScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.menu = contextMenu
        
        outlineView = SideBarOutlineView()
        outlineView.bottomPadding = Self.bottomContentInset
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.selectionHighlightStyle = .none
        outlineView.style = .fullWidth
        outlineView.backgroundColor = .clear
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        
        outlineView.autoresizingMask = [.width]
        outlineView.target = self
        outlineView.action = #selector(outlineViewClicked(_:))
        outlineView.doubleAction = #selector(outlineViewDoubleClicked(_:))
//        outlineView.draggingDestinationFeedbackStyle = .gap
        
        outlineView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.move, .copy], forLocal: false)
        outlineView.registerForDraggedTypes([.pinnedTab, .normalTab, .phiBookmark])
        outlineView.phiOutlineDelegate = self
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.autoresizesOutlineColumn = true
        
        scrollView.documentView = outlineView
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }
    
    private func setupAppearance() {
        view.wantsLayer = true
    }
    
    private func setupDelegates() {
        bookmarkSectionController.delegate = self
        tabSectionController.delegate = self
    }
    
    private func setupBindings() {
        cancellables.removeAll()
        NotificationCenter.default.publisher(for: .bookmarkStartEditing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let bookmark = notification.object as? Bookmark {
                    self?.startEditingBookmark(bookmark)
                }
            }
            .store(in: &cancellables)
    }

    func setActive(_ active: Bool) {
        if active {
            activate()
        } else {
            deactivate()
        }
    }

    private func activate() {
        guard isActive == false else {
            refreshAllItems()
            return
        }
        isActive = true
        setupBindings()
        bookmarkSectionController.setActive(true)
        tabSectionController.browserState = browserState
        refreshAllItems()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        tabSectionController.browserState = nil
        bookmarkSectionController.setActive(false)
        clearInactiveUIState()
    }

    private func clearInactiveUIState() {
        allItems = []
        focusedBookmarkPresentation = nil
        floatingBookmarkGuid = nil
        floatingAnchorFolderGuid = nil
        temporarilyHiddenRealBookmarkGuid = nil
        dropFeedbackFolderGuid = nil
        allowExpandDuringDrag = false
        scrollAnimationGeneration += 1
        scrollScheduleGeneration += 1
        lastScrolledFocusingTabId = nil
        lastSelectedItem = nil
        userInitiatedToggleFolderGuid = nil
        outlineView.deselectAll(nil)
        outlineView.reloadData()
        browserState.visibleBookmarkTabs = []
    }
    
    private func startEditingBookmark(_ bookmark: Bookmark) {
        expandParents(of: bookmark)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            scheduleScrollToVisible(forItem: bookmark)
            bookmark.isEditing = true
        }
    }
    
    // MARK: - Data Management
    private func refreshAllItems() {
        guard isActive else { return }
        var items: [SidebarItem] = []
        
        if showBookmarks {
            items.append(contentsOf: bookmarkSectionController.bookmarkItems)
            if !bookmarkSectionController.bookmarkItems.isEmpty && !tabSectionController.tabItems.isEmpty {
                items.append(separatorItem)
            }
        }
        
        items.append(contentsOf: tabSectionController.tabItems)
        
        self.allItems = items
        
        rebuildFloatingBookmarkPresentationIfNeeded()
        invalidateExistingTabCells()
        outlineView.reloadData()
        selectActiveTab()
        applyFocusingSelection(for: browserState.focusingTab)

        DispatchQueue.main.async { [weak self] in
            self?.updateVisibleBookmarkTabs()
        }
    }
    
    /// Cancel Combine subscriptions on all visible tab cells before reloadData.
    /// NSOutlineView.reloadData() does NOT call prepareForReuse on replaced cells,
    /// leaving orphaned ViewModels with active subscriptions that cause title flicker.
    /// Uses invalidateSubscriptions() instead of prepareForReuse() to avoid
    /// resetting visual state which causes a visible blank frame during reload.
    private func invalidateExistingTabCells() {
        for row in 0..<outlineView.numberOfRows {
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTabCellView else { continue }
            cell.invalidateSubscriptions()
        }
    }

    private func selectActiveTab() {
        for item in allItems {
            if let tab = item as? Tab, tab.isActive {
               selectItem(tab, clearSelectionFirst: true)
                break
            }
        }
    }
    
    private func selectItem(_ item: SidebarItem?, clearSelectionFirst: Bool = true) {
        if item == nil || clearSelectionFirst {
            outlineView.deselectAll(nil)
            lastScrolledFocusingTabId = nil
        }
        if let item, item.isActive {
            let index = outlineView.row(forItem: item)
            outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            lastScrolledFocusingTabId = item.id
        }
    }
    
    // MARK: - Actions
    @objc private func outlineViewClicked(_ sender: NSOutlineView) {
        let clickedRow = sender.clickedRow
        guard clickedRow != -1 else { return }

        if let event = NSApp.currentEvent,
           event.clickCount > 1,
           let bookmark = bookmarkForRow(clickedRow),
           !bookmark.isFolder {
            return
        }
        
        if let item = outlineView.item(atRow: clickedRow) as? SidebarItem {
            itemClicked(item)
        }
    }

    @objc private func outlineViewDoubleClicked(_ sender: NSOutlineView) {
        let clickedRow = sender.clickedRow
        guard clickedRow != -1 else { return }
        guard let bookmark = bookmarkForRow(clickedRow), !bookmark.isFolder else { return }
        browserState.bookmarkManager.triggerRename(for: bookmark)
    }
    
    private func itemClicked(_ item: SidebarItem) {
        if item.isSelectable {
            userSelectedItem(item)
        } else {
            item.performAction(with: self)
        }
    }
    
    private func userSelectedItem(_ item: SidebarItem) {
        if !item.isSelectable {
            return
        }
        setSelectedItem(item)
        item.performAction(with: self)
    }
    
    private func setSelectedItem(_ item: SidebarItem) {
        lastSelectedItem = item
    }
    
    private func handleBookmarkSelection(_ bookmark: Bookmark) {
        guard !bookmark.isFolder else { return }
        browserState.openBookmark(bookmark)
    }

    private func bookmarkForRow(_ row: Int) -> Bookmark? {
        guard let item = outlineView.item(atRow: row) as? SidebarItem else { return nil }
        if let bookmark = item as? Bookmark { return bookmark }
        if let provider = item as? UnderlyingBookmarkProviding { return provider.underlyingBookmark }
        return nil
    }
    
    // MARK: - Helper Methods
    private func getIndexPath(for item: SidebarItem) -> Int? {
        return allItems.firstIndex { $0.id == item.id }
    }
    
    private func getItem(at row: Int) -> SidebarItem? {
        guard row >= 0 && row < allItems.count else { return nil }
        return allItems[row]
    }
    
    /// Sync `bookmark.isExpanded` with the actual outline view state.
    /// Needed after autosave restore, which does not fire `outlineViewItemDidExpand`.
    private func syncBookmarkExpandedFlags() {
        func traverse(_ items: [SidebarItem]) {
            for item in items {
                guard let bookmark = item as? Bookmark, bookmark.isFolder else { continue }
                bookmark.isExpanded = outlineView.isItemExpanded(bookmark)
                traverse(bookmark.children)
            }
        }
        traverse(allItems)
    }
    
    func tearDown() {
        deactivate()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }


    private func handleFavoriteTabDropToNormalList(tabGuid: String, destinationIndex: Int) -> Bool {
        let destination = calculateTabDestinationIndex(from: destinationIndex)
        browserState.movePinnedTabOut(pinnedGuid: tabGuid, to: destination)
        return true
    }
    
    private func handleFavoriteTabDropToBookmark(pinnedGuid: String, parentGuid: String?, index: Int) -> Bool {
        browserState.movePinnedTabOut(pinnedGuid: pinnedGuid, toBookmark: parentGuid, index: index)
        return true
    }
    
    private func handleBookmarkDropToNormalList(bookmark: Bookmark, destinationIndex: Int) -> Bool {
        let destination = calculateTabDestinationIndex(from: destinationIndex)
        browserState.moveBookmarkOut(bookmark, toNormalTabs: destination)
        return true
    }
}

// MARK: - NSOutlineViewDataSource
extension SidebarTabListViewController: NSOutlineViewDataSource {
    private func visibleChildren(for item: SidebarItem) -> [SidebarItem] {
        var children = item.childrenItems
        if let hiddenGuid = temporarilyHiddenRealBookmarkGuid {
            children.removeAll { child in
                if let bookmark = child as? Bookmark {
                    return bookmark.guid == hiddenGuid
                }
                return (child.id as? String) == hiddenGuid
            }
        }
        return children
    }
    
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        dataSourceChildren(of: item as? SidebarItem).count
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = dataSourceChildren(of: item as? SidebarItem)
        guard children.indices.contains(index) else {
            assertionFailure("Invalid child index \(index), count \(children.count)")
            return separatorItem
        }
        return children[index]
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.isExpandable
        }
        return false
    }
    
    // MARK: - Drag and Drop Source Methods
    
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        
        let pasteboardItem = NSPasteboardItem()
        
        if let tab = sidebarItem as? Tab {
            pasteboardItem.setString(String(tab.guid), forType: .normalTab)
            pasteboardItem.setString(String(browserState.windowId), forType: .sourceWindowId)
            return pasteboardItem
        }
        
        if let bookmark = sidebarItem as? Bookmark {
            pasteboardItem.setString(bookmark.guid, forType: .phiBookmark)
            pasteboardItem.setString(String(browserState.windowId), forType: .sourceWindowId)
            return pasteboardItem
        }
        if let provider = sidebarItem as? UnderlyingBookmarkProviding {
            let bookmark = provider.underlyingBookmark
            pasteboardItem.setString(bookmark.guid, forType: .phiBookmark)
            pasteboardItem.setString(String(browserState.windowId), forType: .sourceWindowId)
            return pasteboardItem
        }
        
        return nil
    }
    
    // MARK: - Drag and Drop Destination Methods
    
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let originalResolvedItem: Any? = {
            if let provider = item as? UnderlyingBookmarkProviding { return provider.underlyingBookmark }
            return item
        }()
        var resolvedItem = originalResolvedItem
        var resolvedIndex = index
        
        let pasteboard = info.draggingPasteboard
        guard let pasteboardItem = pasteboard.pasteboardItems?.first else {
            clearFolderDropFeedback()
            return []
        }
        
        if isCrossWindowDrag(pasteboard),
           let sourceState = sourceBrowserState(for: pasteboard),
           !browserState.canAcceptCrossWindowDrag(from: sourceState) {
            clearFolderDropFeedback()
            return []
        }
        
        if let remapped = remappedDropTargetForFolderRule(in: outlineView, info: info, resolvedItem: originalResolvedItem, proposedChildIndex: index) {
            outlineView.setDropItem(remapped.item, dropChildIndex: remapped.childIndex)
            resolvedItem = remapped.item
            resolvedIndex = remapped.childIndex
        }
        
        updateDropFeedbackFolder(in: outlineView, with: resolvedItem, childIndex: resolvedIndex, pasteboard: pasteboardItem)
        
        let maxRootDropIndex = maxRootDropChildIndex()
        
        if resolvedItem == nil {
            // NSOutlineView has a quirky behavior: dragging an item past the last row
            // may return an incorrect index (like 0), causing the item to jump to the front.
            // Detect this by checking the drag location and index bounds, then redirect
            // to the correct position (append to root).
            let numberOfRows = outlineView.numberOfRows
            let dragLocationInWindow = info.draggingLocation
            let dragLocationInOutline = outlineView.convert(dragLocationInWindow, from: nil)
            
            if numberOfRows > 0 {
                let lastRowRect = outlineView.rect(ofRow: numberOfRows - 1)
                if dragLocationInOutline.y >= lastRowRect.minY {
                    outlineView.setDropItem(nil, dropChildIndex: maxRootDropIndex)
                    return .move
                }
            }
            
            if resolvedIndex > maxRootDropIndex {
                outlineView.setDropItem(nil, dropChildIndex: maxRootDropIndex)
                return .move
            }
        }
    
        if pasteboard.string(forType: .pinnedTab) != nil {
            if resolvedItem == nil {
                let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : resolvedIndex
                if isRowInTabSection(proposedRow) {
                    return .move
                }
                if isRowInBookmarkSection(proposedRow) {
                    return .copy
                }
            }
            if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                return .copy
            }
            return []
        }

        if let draggedItemId = pasteboard.string(forType: .normalTab),
           let tabGuid = Int(draggedItemId) {
            guard browserState.tabs.first(where: { $0.guid == tabGuid }) != nil
                    || sourceBrowserState(for: pasteboard)?.tabs.first(where: { $0.guid == tabGuid }) != nil else {
                return []
            }
            
            if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                return .copy
            }
            
            // Dropping ON a tab (index == -1) would jump it to position 0; redirect to insert before that tab.
            if let targetTab = resolvedItem as? Tab, resolvedIndex == NSOutlineViewDropOnItemIndex {
                let targetRow = outlineView.row(forItem: targetTab)
                if targetRow >= 0 {
                    outlineView.setDropItem(nil, dropChildIndex: targetRow)
                    return .move
                }
            }
            
            if resolvedItem == nil {
                let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : resolvedIndex
                if isRowInBookmarkSection(proposedRow) {
                    return .copy
                }
                if isRowInTabSection(proposedRow) {
                    return .move
                }
            }
            
            return .move
        }
        
        if let draggedBookmarkId = pasteboard.string(forType: .phiBookmark),
           let draggedBookmark = findBookmark(withId: draggedBookmarkId) {
            
            AppLogDebug("[validateDrop] Dragging bookmark: \(draggedBookmark.title)")
            
            if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                let canAccept = bookmarkSectionController.canAcceptDrop(of: draggedBookmark, to: targetBookmark)
                AppLogDebug("[validateDrop] -> Drop on folder '\(targetBookmark.title)', canAccept: \(canAccept)")
                return canAccept ? .move : []
            }
            
            // Non-folder bookmark: redirect to parent folder for sibling reordering.
            if let targetBookmark = resolvedItem as? Bookmark, !targetBookmark.isFolder {
                AppLogDebug("[validateDrop] -> Drop on non-folder bookmark '\(targetBookmark.title)'")
                let parentFolder = targetBookmark.parent
                if let parent = parentFolder {
                    if let targetIndex = parent.children.firstIndex(of: targetBookmark) {
                        AppLogDebug("[validateDrop] -> Redirect to parent folder '\(parent.title)', index: \(targetIndex)")
                        outlineView.setDropItem(parent, dropChildIndex: targetIndex)
                    }
                } else {
                    if let targetIndex = bookmarkSectionController.bookmarkItems.firstIndex(where: { ($0 as? Bookmark)?.guid == targetBookmark.guid }) {
                        AppLogDebug("[validateDrop] -> Redirect to root level, index: \(targetIndex)")
                        outlineView.setDropItem(nil, dropChildIndex: targetIndex)
                    }
                }
                let canAccept = bookmarkSectionController.canAcceptDrop(of: draggedBookmark, to: parentFolder)
                AppLogDebug("[validateDrop] -> canAccept: \(canAccept)")
                return canAccept ? .move : []
            }
            
            if resolvedItem == nil {
                let bookmarkSectionEnd = bookmarkSectionController.bookmarkItems.count
                
                AppLogDebug("[validateDrop] -> Root level drop, index: \(resolvedIndex), bookmarkSectionEnd: \(bookmarkSectionEnd)")
                
                if resolvedIndex <= bookmarkSectionEnd {
                    AppLogDebug("[validateDrop] -> In bookmark section, returning .move")
                    return .move
                } else {
                    AppLogDebug("[validateDrop] -> In tab section, returning .move (will move to normal tabs)")
                    return .move
                }
            }
            
            AppLogDebug("[validateDrop] -> No matching condition, returning []")
        }
        
        return []
    }
    
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let resolvedItem: Any? = {
            if let provider = item as? UnderlyingBookmarkProviding { return provider.underlyingBookmark }
            return item
        }()
        let resolvedIndex = index
        
        defer { clearFolderDropFeedback() }

        let pasteboard = info.draggingPasteboard
        guard pasteboard.pasteboardItems?.isEmpty == false else {
            return false
        }
        
        browserState.tabDraggingSession.end()

        if let pinnedTabId = pasteboard.string(forType: .pinnedTab) {
            if isCrossWindowDrag(pasteboard), let sourceState = sourceBrowserState(for: pasteboard) {
                if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                    sourceState.movePinnedTabOut(
                        pinnedGuid: pinnedTabId,
                        toBookmark: targetBookmark.guid,
                        index: resolvedIndex == NSOutlineViewDropOnItemIndex ? 0 : resolvedIndex
                    )
                    return true
                }
                
                let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : resolvedIndex
                if isRowInBookmarkSection(proposedRow) {
                    sourceState.movePinnedTabOut(pinnedGuid: pinnedTabId, toBookmark: nil, index: resolvedIndex)
                    return true
                }
                
                let destination = calculateTabDestinationIndex(from: resolvedIndex)
                if let openTab = findOpenTab(in: sourceState, matchingLocalGuid: pinnedTabId) {
                    sourceState.movePinnedTabOut(pinnedGuid: pinnedTabId, to: destination)
                    return moveTabToTargetWindow(openTab, destinationIndex: destination, scheduleNormalInsertion: true)
                }
                
                return handleFavoriteTabDropToNormalList(tabGuid: pinnedTabId, destinationIndex: resolvedIndex)
            }
            if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                return handleFavoriteTabDropToBookmark(pinnedGuid: pinnedTabId, parentGuid: targetBookmark.guid, index: resolvedIndex == NSOutlineViewDropOnItemIndex ? 0 : resolvedIndex)
            }
            
            let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : resolvedIndex
            if isRowInBookmarkSection(proposedRow) {
                return handleFavoriteTabDropToBookmark(pinnedGuid: pinnedTabId, parentGuid: nil, index: resolvedIndex)
            }
            
            return handleFavoriteTabDropToNormalList(tabGuid: pinnedTabId, destinationIndex: resolvedIndex)
        }

        if let draggedItemId = pasteboard.string(forType: .normalTab),
           let tabGuid = Int(draggedItemId) {
            let crossWindowSource = sourceBrowserState(for: pasteboard)
            if isCrossWindowDrag(pasteboard), let sourceState = crossWindowSource,
               let draggedTab = sourceState.tabs.first(where: { $0.guid == tabGuid }) {
                
                if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                    sourceState.moveNormalTab(
                        tabId: draggedTab.guid,
                        toBookmark: targetBookmark.guid,
                        index: resolvedIndex == NSOutlineViewDropOnItemIndex ? 0 : resolvedIndex
                    )
                    return true
                }
                
                let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : resolvedIndex
                if isRowInBookmarkSection(proposedRow) {
                    sourceState.moveNormalTab(tabId: draggedTab.guid, toBookmark: nil, index: resolvedIndex)
                    return true
                }
                
                let destination = calculateTabDestinationIndex(from: resolvedIndex)
                return moveTabToTargetWindow(draggedTab, destinationIndex: destination, scheduleNormalInsertion: true)
            }
            
            guard let draggedTab = browserState.tabs.first(where: { $0.guid == tabGuid }) else {
                return false
            }
            
            if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                return bookmarkSectionController.handleDrop(of: draggedTab, to: targetBookmark, at: resolvedIndex == NSOutlineViewDropOnItemIndex ? nil : resolvedIndex)
            } else {
                let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : resolvedIndex
                if isRowInBookmarkSection(proposedRow) {
                    return bookmarkSectionController.handleDrop(of: draggedTab, to: nil, at: resolvedIndex)
                }
                
                return tabSectionController.handleTabDrop(draggedTab: draggedTab, destinationIndex: calculateTabDestinationIndex(from: resolvedIndex))
            }
        }
        
        if let draggedBookmarkId = pasteboard.string(forType: .phiBookmark),
           let draggedBookmark = findBookmark(withId: draggedBookmarkId) {
            
            #if DEBUG
            let itemDescription: String
            if let bookmark = resolvedItem as? Bookmark {
                itemDescription = "Bookmark(\(bookmark.title), isFolder: \(bookmark.isFolder))"
            } else if resolvedItem == nil {
                itemDescription = "nil (root level)"
            } else {
                itemDescription = "Unknown: \(type(of: resolvedItem!))"
            }
            AppLogDebug("[acceptDrop] Bookmark '\(draggedBookmark.title)', item: \(itemDescription), index: \(resolvedIndex)")
            #endif
            
            var dropResult = false
            
            if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                AppLogDebug("[acceptDrop] -> Drop into folder '\(targetBookmark.title)'")
                dropResult = bookmarkSectionController.handleDrop(of: draggedBookmark, to: targetBookmark, at: resolvedIndex == NSOutlineViewDropOnItemIndex ? nil : resolvedIndex)
            }
            
            else if let targetBookmark = resolvedItem as? Bookmark {
                let parentFolder = targetBookmark.parent ?? browserState.bookmarkManager.rootFolder
                AppLogDebug("[acceptDrop] -> Drop on bookmark '\(targetBookmark.title)', redirect to parent: \(parentFolder.title)")
                dropResult = bookmarkSectionController.handleDrop(of: draggedBookmark, to: parentFolder, at: resolvedIndex == NSOutlineViewDropOnItemIndex ? nil : resolvedIndex)
            }
            
            else if resolvedItem == nil {
                let bookmarkSectionEnd = bookmarkSectionController.bookmarkItems.count
                AppLogDebug("[acceptDrop] -> Root level, index: \(resolvedIndex), bookmarkSectionEnd: \(bookmarkSectionEnd)")
                
                if resolvedIndex <= bookmarkSectionEnd {
                    AppLogDebug("[acceptDrop] -> In bookmark section, calling handleDrop with nil parent")
                    dropResult = bookmarkSectionController.handleDrop(of: draggedBookmark, to: nil, at: resolvedIndex)
                } else {
                    AppLogDebug("[acceptDrop] -> In tab section, calling handleBookmarkDropToNormalList")
                    if isCrossWindowDrag(pasteboard), let sourceState = sourceBrowserState(for: pasteboard) {
                        let destination = calculateTabDestinationIndex(from: resolvedIndex)
                        if let openTab = findOpenTab(in: sourceState, matchingLocalGuid: draggedBookmark.guid) {
                            sourceState.moveBookmarkOut(draggedBookmark, toNormalTabs: destination)
                            return moveTabToTargetWindow(openTab, destinationIndex: destination, scheduleNormalInsertion: true)
                        }
                    }
                    dropResult = handleBookmarkDropToNormalList(bookmark: draggedBookmark, destinationIndex: resolvedIndex)
                }
            } else {
                AppLogDebug("[acceptDrop] -> No matching condition for bookmark drop")
            }
            
            return dropResult
        }
        
        return false
    }
    
    func outlineView(_ outlineView: NSOutlineView,
                     draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.expandFloatingBookmarkParentsIfNeeded()
            self?.browserState.isDraggingTab = true
        }
        browserState.tabDraggingSession.attachNativeSession(session)
        browserState.tabDraggingSession.begin(
            draggingItem: draggedItems.first,
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            containerView: hostVC?.view
        )
    }
    
    func outlineView(_ outlineView: NSOutlineView,
                     draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        clearFolderDropFeedback()
        DispatchQueue.main.async { [weak self] in
            self?.browserState.isDraggingTab = false
        }
        browserState.tabDraggingSession.end(
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            dragOperation: operation
        )
    }
    
    // MARK: - Helper Methods for Drag & Drop
    
    /// If a floating bookmark proxy exists, expand its parent folders so the real bookmark
    /// becomes visible, then clear the floating state. Idempotent — safe to call multiple times.
    private func expandFloatingBookmarkParentsIfNeeded() {
        guard focusedBookmarkPresentation != nil else { return }
        if let floatingGuid = floatingBookmarkGuid,
           let bookmark = browserState.bookmarkManager.bookmark(withGuid: floatingGuid) {
            removeFocusedBookmarkPresentation(animated: false)
            floatingBookmarkGuid = nil
            floatingAnchorFolderGuid = nil
            allowExpandDuringDrag = true
            expandParents(of: bookmark)
            allowExpandDuringDrag = false
        } else {
            removeFocusedBookmarkPresentation(animated: false)
        }
    }
    
    /// Returns the append position for a root-level drop, accounting for any
    /// UI-only focused bookmark proxy that may be present.
    private func maxRootDropChildIndex() -> Int {
        dataSourceChildren(of: nil).count
    }
    
    private func isRowInBookmarkSection(_ row: Int) -> Bool {
        guard showBookmarks else { return false }
        let bookmarkSectionEnd = bookmarkSectionController.bookmarkItems.count
        return row <= bookmarkSectionEnd
    }
    
    private func isRowInTabSection(_ row: Int) -> Bool {
        if !showBookmarks {
            return true
        }
        let bookmarkSectionEnd = bookmarkSectionController.bookmarkItems.count
        let separatorOffset = (!bookmarkSectionController.bookmarkItems.isEmpty && !tabSectionController.tabItems.isEmpty) ? 1 : 0
        return row > bookmarkSectionEnd + separatorOffset
    }
    
    private func calculateTabDestinationIndex(from outlineViewIndex: Int) -> Int {
        if !showBookmarks {
            return max(0, outlineViewIndex - 1)
        }
        
        let bookmarkSectionEnd = bookmarkSectionController.bookmarkItems.count
        let separatorOffset = (!bookmarkSectionController.bookmarkItems.isEmpty && !tabSectionController.tabItems.isEmpty) ? 1 : 0
        let tabSectionStart = tabSectionStartIndexInRootChildren(bookmarkCount: bookmarkSectionEnd, separatorCount: separatorOffset)
        
        // -1 for the "New Tab" button at the top of tab section
        return max(0, outlineViewIndex - tabSectionStart - 1)
    }
    
    private func findBookmark(withId id: String) -> Bookmark? {
        return browserState.bookmarkManager.bookmark(withGuid: id)
    }
    
    private func updateDropFeedbackFolder(in outlineView: NSOutlineView, with resolvedItem: Any?, childIndex: Int, pasteboard: NSPasteboardItem) {
        let isTabLikeDrag = pasteboard.string(forType: .normalTab) != nil
        || pasteboard.string(forType: .pinnedTab) != nil
        || pasteboard.string(forType: .phiBookmark) != nil
        guard isTabLikeDrag,
              childIndex == NSOutlineViewDropOnItemIndex,
              let folder = resolvedItem as? Bookmark,
              !outlineView.isItemExpanded(folder),
              folder.isFolder else {
            clearFolderDropFeedback()
            return
        }
        setFolderDropFeedback(folder)
    }
    
    private func setFolderDropFeedback(_ folder: Bookmark) {
        guard dropFeedbackFolderGuid != folder.guid else { return }
        
        let previousGuid = dropFeedbackFolderGuid
        dropFeedbackFolderGuid = folder.guid
        
        if let previousGuid {
            updateFolderDropFeedbackCell(guid: previousGuid, highlighted: false)
        }
        updateFolderDropFeedbackCell(guid: folder.guid, highlighted: true)
    }
    
    private func clearFolderDropFeedback() {
        guard let currentGuid = dropFeedbackFolderGuid else { return }
        dropFeedbackFolderGuid = nil
        updateFolderDropFeedbackCell(guid: currentGuid, highlighted: false)
    }
    
    private func updateFolderDropFeedbackCell(guid: String, highlighted: Bool) {
        guard let folder = findBookmark(withId: guid) else { return }
        let row = outlineView.row(forItem: folder)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkCellView else {
            return
        }
        cell.setDropTargetHighlighted(highlighted)
    }
    
    private func remappedDropTargetForFolderRule(
        in outlineView: NSOutlineView,
        info: NSDraggingInfo,
        resolvedItem: Any?,
        proposedChildIndex: Int
    ) -> (item: Any?, childIndex: Int)? {
        guard let folder = resolvedItem as? Bookmark,
              folder.isFolder else {
            return nil
        }
        
        let row = outlineView.row(forItem: folder)
        guard row >= 0 else { return nil }
        let isExpanded = outlineView.isItemExpanded(folder)
        
        let locationInOutline = outlineView.convert(info.draggingLocation, from: nil)
        let rowRect = outlineView.rect(ofRow: row)
        
        // Rule 1: collapsed folder — cursor in upper half + on-item keeps "enter folder";
        // all other cases (lower half, or gap regardless of half) remap to parent level.
        if !isExpanded {
            let insertBefore = outlineView.isFlipped ? (locationInOutline.y < rowRect.midY) : (locationInOutline.y > rowRect.midY)
            
            if insertBefore && proposedChildIndex == NSOutlineViewDropOnItemIndex {
                return nil
            }
            
            let parentItem = folder.parent
            let siblings = dataSourceChildren(of: parentItem)
            guard let folderIndex = siblings.firstIndex(where: { $0.id == folder.id }) else {
                return nil
            }
            
            let targetIndex = insertBefore ? folderIndex : folderIndex + 1
            return (item: parentItem, childIndex: targetIndex)
        }
        
        // Rule 2: expanded folder + on-item => disable on behavior and map to first child slot.
        // This makes "drop after A row" land before A1 instead of before sibling B.
        if isExpanded && proposedChildIndex == NSOutlineViewDropOnItemIndex {
            return (item: folder, childIndex: 0)
        }
        
        return nil
    }
    
    private func dataSourceChildren(of parent: SidebarItem?) -> [SidebarItem] {
        if let parent {
            var children = visibleChildren(for: parent)
            if let presentation = focusedBookmarkPresentation,
               let insertionParent = presentation.insertionParent,
               insertionParent.id == parent.id {
                let insertionIndex = min(max(0, presentation.insertionIndex), children.count)
                children.insert(presentation.proxy, at: insertionIndex)
            }
            return children
        }
        
        var children = allItems
        if let presentation = focusedBookmarkPresentation,
           presentation.insertionParent == nil {
            let insertionIndex = min(max(0, presentation.insertionIndex), children.count)
            children.insert(presentation.proxy, at: insertionIndex)
        }
        return children
    }
    
    private func dragSourceWindowId(from pasteboard: NSPasteboard) -> Int? {
        guard let idString = pasteboard.string(forType: .sourceWindowId) else { return nil }
        return Int(idString)
    }
    
    private func sourceBrowserState(for pasteboard: NSPasteboard) -> BrowserState? {
        guard let sourceId = dragSourceWindowId(from: pasteboard) else { return nil }
        return MainBrowserWindowControllersManager.shared.getBrowserState(for: sourceId)
    }
    
    private func isCrossWindowDrag(_ pasteboard: NSPasteboard) -> Bool {
        guard let sourceId = dragSourceWindowId(from: pasteboard) else { return false }
        let targetId = browserState.windowId
        return sourceId != targetId
    }
    
    private func findOpenTab(in state: BrowserState, matchingLocalGuid guid: String) -> Tab? {
        return state.tabs.first { $0.guidInLocalDB == guid }
    }
    
    private func moveTabToTargetWindow(_ tab: Tab, destinationIndex: Int, scheduleNormalInsertion: Bool) -> Bool {
        guard let wrapper = tab.webContentWrapper else { return false }
        let targetState = browserState
        if scheduleNormalInsertion {
            targetState.scheduleNormalTabInsertion(tabGuid: tab.guid, at: destinationIndex)
        }
        let insertIndex = max(0, targetState.tabs.count)
        wrapper.moveSelf(toWindow: targetState.windowId.int64Value, at: insertIndex)
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarTabListViewController: NSOutlineViewDelegate {
//    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
//        let item = outlineView.item(atRow: row) as? SidebarItem
//        rowView.isSelected = self.lastSelectedItem === item
//    }
    
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let sidebarItem = item as? SidebarItem else {
            return nil
        }
        
        switch sidebarItem.itemType {
        case .tab, .newTabButton:
            return InsetTableRowView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        case .bookmark, .bookmarkFolder:
            return BookmarkRowView(/*insets:  NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)*/)
        default:
            return nil
        }
    }
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        
        let cellView: SidebarCellView
        
        switch sidebarItem.itemType {
        case .bookmark, .bookmarkFolder:
            let identifier = NSUserInterfaceItemIdentifier("BookmarkCell")
            var bookmarkCell = outlineView.makeView(withIdentifier: identifier, owner: self) as? BookmarkCellView
            if bookmarkCell == nil {
                bookmarkCell = BookmarkCellView()
                bookmarkCell?.identifier = identifier
            }
            bookmarkCell?.editDelegate = self
            cellView = bookmarkCell!
            
        case .tab:
            let identifier = NSUserInterfaceItemIdentifier("TabCell")
            let tabCell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarTabCellView ?? {
                let c = SidebarTabCellView()
                c.identifier = identifier
                return c
            }()
            tabCell.delegate = self
            cellView = tabCell
            
        case .newTabButton:
            let identifier = NSUserInterfaceItemIdentifier("NewTabButtonCell")
            var newTabCell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NewTabButtonCellView
            if newTabCell == nil {
                newTabCell = NewTabButtonCellView()
                newTabCell?.identifier = identifier
            }
            cellView = newTabCell!
            
        case .separator:
            let identifier = NSUserInterfaceItemIdentifier("SeparatorCell")
            var separatorCell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SeparatorCellView
            if separatorCell == nil {
                separatorCell = SeparatorCellView()
                separatorCell?.identifier = identifier
            }
            cellView = separatorCell!

        case .tabGroup:
            // PLACEHOLDER (commit 1): no producer of `.tabGroup` items
            // exists at this commit (TabGroupSidebarItem is introduced in
            // commit 3), so this branch is unreachable at runtime.
            // The real cell wiring lives in commit 3.
            fatalError("tabGroup cell wired up in a later commit")
        }
        
        cellView.configure(with: sidebarItem)
        if let bookmarkCell = cellView as? BookmarkCellView,
           let bookmark = sidebarItem as? Bookmark {
            bookmarkCell.setDropTargetHighlighted(bookmark.isFolder && bookmark.guid == dropFeedbackFolderGuid)
        }
        return cellView
    }
    
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let sidebarItem = item as? SidebarItem else { return 32.0 }
        
        switch sidebarItem.itemType {
        case .separator:
            return 16.0 // Smaller height for separator
        default:
            return 36.0
        }
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        return true
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if browserState.isDraggingTab && !allowExpandDuringDrag {
            return false
        }
        return (item as? SidebarItem)?.isExpandable ?? false
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let sidebarItem = item as? SidebarItem else { return false }
        return sidebarItem.isSelectable
    }
    
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let bookmark = notification.userInfo?["NSObject"] as? Bookmark else { return }
        if userInitiatedToggleFolderGuid == bookmark.guid {
            bookmark.isExpanded = true
            userInitiatedToggleFolderGuid = nil
        }
        temporarilyHiddenRealBookmarkGuid = nil
        // Defer to next run loop to avoid conflicting with NSOutlineView's expand animation.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let oldPresentation = self.focusedBookmarkPresentation
            self.restoreExpandedDescendantsIfNeeded(of: bookmark)
            self.rebuildFloatingBookmarkPresentationIfNeeded()
            self.updateVisibleBookmarkTabs()
            let newPresentation = self.focusedBookmarkPresentation
            self.applyFloatingPresentation(from: oldPresentation, to: newPresentation, animated: false)
        }
    }
    
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let bookmark = notification.userInfo?["NSObject"] as? Bookmark else { return }
        // Only update isExpanded for the folder the user explicitly toggled; descendant collapses
        // triggered by NSOutlineView should preserve their original expanded state for restoration.
        if userInitiatedToggleFolderGuid == bookmark.guid {
            bookmark.isExpanded = false
            userInitiatedToggleFolderGuid = nil
        }
        temporarilyHiddenRealBookmarkGuid = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let oldPresentation = self.focusedBookmarkPresentation
            self.rebuildFloatingBookmarkPresentationIfNeeded()
            self.updateVisibleBookmarkTabs()
            let newPresentation = self.focusedBookmarkPresentation
            self.applyFloatingPresentation(from: oldPresentation, to: newPresentation, animated: false)
        }
    }
    
    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        guard let bookmark = item as? Bookmark else { return nil }
        return bookmark.guid
    }

    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        guard let guid = object as? String else { return nil }
        return bookmarkSectionController.sidebarItem(withGuid: guid)
    }
}

extension SidebarTabListViewController: SidebarTabListItemOwner {
    func toggleItemExpanded(_ item: any SidebarItem) {
        if let folder = item as? Bookmark, folder.isFolder {
            userInitiatedToggleFolderGuid = folder.guid
        }
        if outlineView.isItemExpanded(item) {
            // Collapsing a folder that contains the focusing bookmark: remove the real row first,
            // insert proxy, then collapse — so the bookmark doesn't animate "into" the folder.
            if let folder = item as? Bookmark, folder.isFolder,
               let focusingTab = browserState.focusingTab,
               let localGuid = focusingTab.guidInLocalDB,
               let focusingBookmark = browserState.bookmarkManager.bookmark(withGuid: localGuid),
               isBookmark(focusingBookmark, descendantOf: folder) {
                
                let desired = computeFocusedBookmarkPresentation(for: focusingTab, treatingFolderAsCollapsed: folder)
                guard let desired else {
            outlineView.animator().collapseItem(item)
                    return
                }
                
                floatingBookmarkGuid = focusingBookmark.guid
                floatingAnchorFolderGuid = folder.guid
                
                if let parent = focusingBookmark.parent {
                    let siblings = visibleChildren(for: parent)
                    if let idx = siblings.firstIndex(where: { $0.id == focusingBookmark.id }) {
                        outlineView.beginUpdates()
                        temporarilyHiddenRealBookmarkGuid = focusingBookmark.guid
                        outlineView.removeItems(at: IndexSet(integer: idx), inParent: parent, withAnimation: [.effectFade])
                        focusedBookmarkPresentation = desired
                        outlineView.insertItems(at: IndexSet(integer: desired.insertionIndex), inParent: desired.insertionParent, withAnimation: [.effectFade, .effectGap])
                        outlineView.endUpdates()
                    } else {
                        focusedBookmarkPresentation = desired
                        outlineView.beginUpdates()
                        outlineView.insertItems(at: IndexSet(integer: desired.insertionIndex), inParent: desired.insertionParent, withAnimation: [.effectFade, .effectGap])
                        outlineView.endUpdates()
                    }
                } else {
                    focusedBookmarkPresentation = desired
                    outlineView.beginUpdates()
                    outlineView.insertItems(at: IndexSet(integer: desired.insertionIndex), inParent: desired.insertionParent, withAnimation: [.effectFade, .effectGap])
                    outlineView.endUpdates()
                }
                
                outlineView.animator().collapseItem(item)
                applyFocusingSelection(for: focusingTab)
                return
            }
            
            outlineView.animator().collapseItem(item)
        } else {
            if let folder = item as? Bookmark, folder.isFolder,
               let focusingTab = browserState.focusingTab,
               let localGuid = focusingTab.guidInLocalDB,
               let focusingBookmark = browserState.bookmarkManager.bookmark(withGuid: localGuid),
               isBookmark(focusingBookmark, descendantOf: folder) {
                
                // Single-child shortcut: if the proxy occupies the same visual slot as the real child
                // after expansion, expand without animator to avoid a redundant "slide down" animation.
                if focusingBookmark.parent == folder,
                   folder.children.count == 1,
                   folder.children.first?.guid == focusingBookmark.guid,
                   let existing = focusedBookmarkPresentation,
                   let expected = expectedProxyInsertionAfterCollapsedFolder(folder),
                   existing.insertionParent?.id == expected.insertionParent?.id,
                   existing.insertionIndex == expected.insertionIndex,
                   existing.proxy.underlyingBookmark.guid == focusingBookmark.guid {
                    
                    removeFocusedBookmarkPresentation(animated: false)
                    temporarilyHiddenRealBookmarkGuid = nil
                    outlineView.expandItem(item)
                    DispatchQueue.main.async { [weak self] in
                        self?.updateVisibleBookmarkTabs()
                    }
                    applyFocusingSelection(for: focusingTab)
                    return
                }
                
                temporarilyHiddenRealBookmarkGuid = nil
            outlineView.animator().expandItem(item)
                
                DispatchQueue.main.async { [weak self] in
                    self?.updateVisibleBookmarkTabs()
                    self?.applyFocusingSelection(for: focusingTab)
                }
                return
            }
            
            outlineView.animator().expandItem(item)
        }
    }
    
    func newTabClicked(_ item: any SidebarItem) {
        browserState.windowController?.newBrowserTab(nil)
    }
    
    func bookmarkClicked(_ item: any SidebarItem) {
        guard let bookmark = item as? Bookmark, bookmark.isFolder == false else {
            return
        }
        browserState.openBookmark(bookmark)
    }
}

// MARK: - Section Controller Delegates

extension SidebarTabListViewController: BookmarkSectionDelegate {
    func bookmarkSectionDidUpdate() {
        guard isActive else { return }
        refreshAllItems()
    }
    
    func bookmarkSectionInitialDataDidLoad() {
        guard isActive else { return }
        guard outlineView.autosaveName == nil else { return }
        outlineView.autosaveExpandedItems = true
        outlineView.autosaveName = "SidebarTabList"
        syncBookmarkExpandedFlags()
    }
}

extension SidebarTabListViewController: TabSectionDelegate {
    /// Tab section start index in root-level dataSource children. Accounts for the floating proxy
    /// which may shift separator / tab indices by +1 when inserted at root level.
    private func tabSectionStartIndexInRootChildren(bookmarkCount: Int, separatorCount: Int) -> Int {
        var start = bookmarkCount + separatorCount
        if let presentation = focusedBookmarkPresentation,
           presentation.insertionParent == nil,
           presentation.insertionIndex <= start {
            start += 1
        }
        return start
    }
    
    func tabSectionDidUpdate(with change: TabSectionChange) {
        guard isActive else { return }
        if change.needsFullReload {
            refreshAllItems()
            clearFloatingProxyIfTabClosed()
            return
        }
        
        applyIncrementalTabChange(change)
        clearFloatingProxyIfTabClosed()
    }
    
    /// Applies incremental tab changes to avoid cell flicker from full reloadData.
    private func applyIncrementalTabChange(_ change: TabSectionChange) {
        var items: [SidebarItem] = []
        if showBookmarks {
            items.append(contentsOf: bookmarkSectionController.bookmarkItems)
            if !bookmarkSectionController.bookmarkItems.isEmpty && !tabSectionController.tabItems.isEmpty {
                items.append(separatorItem)
            }
        }
        items.append(contentsOf: tabSectionController.tabItems)
        
        let tabSectionStart: Int
        if showBookmarks {
            let bookmarkCount = bookmarkSectionController.bookmarkItems.count
            let separatorCount = (!bookmarkSectionController.bookmarkItems.isEmpty && !tabSectionController.tabItems.isEmpty) ? 1 : 0
            tabSectionStart = tabSectionStartIndexInRootChildren(bookmarkCount: bookmarkCount, separatorCount: separatorCount)
        } else {
            tabSectionStart = 0
        }
        
        // Fallback to full reload if outline view has no data yet (e.g. layout mode just switched).
        let currentOutlineChildCount = outlineView.numberOfChildren(ofItem: nil)
        if currentOutlineChildCount == 0 && !items.isEmpty {
            self.allItems = items
            rebuildFloatingBookmarkPresentationIfNeeded()
            outlineView.reloadData()
            selectActiveTab()
            applyFocusingSelection(for: browserState.focusingTab)
            DispatchQueue.main.async { [weak self] in
                self?.updateVisibleBookmarkTabs()
            }
            return
        }
        
        let hasStructuralChanges = change.moveOperation != nil
            || !change.removedIndices.isEmpty
            || !change.insertedIndices.isEmpty

        // When there are no structural changes, skip updating allItems. Modifying allItems
        // without a matching NSOutlineView structural call creates an inconsistency:
        // outlineView.row(forItem:) would return indices based on the NEW allItems while
        // NSOutlineView still renders the OLD layout. scrollRowToVisible would then request
        // a row beyond the current layout, triggering a spurious viewFor:item: call that
        // creates a duplicate SidebarTabCellView for the same Tab, causing the two-label
        // flicker bug.
        if !hasStructuralChanges {
            selectActiveTab()
            applyFocusingSelection(for: browserState.focusingTab)
            return
        }

        self.allItems = items

        outlineView.beginUpdates()

        if let moveOp = change.moveOperation {
            let adjustedFrom = moveOp.from + tabSectionStart
            let adjustedTo = moveOp.to + tabSectionStart
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1
                context.allowsImplicitAnimation = true
                outlineView.moveItem(at: adjustedFrom, inParent: nil, to: adjustedTo, inParent: nil)
            }
        } else {
            if !change.removedIndices.isEmpty {
                let adjustedRemovedIndices = IndexSet(change.removedIndices.map { $0 + tabSectionStart })
                outlineView.removeItems(at: adjustedRemovedIndices, inParent: nil, withAnimation: [.effectFade])
            }

            if !change.insertedIndices.isEmpty {
                let adjustedInsertedIndices = IndexSet(change.insertedIndices.map { $0 + tabSectionStart })
                outlineView.insertItems(at: adjustedInsertedIndices, inParent: nil, withAnimation: [.effectFade])
            }
        }

        outlineView.endUpdates()

        // Defer selection to the next run loop so NSOutlineView finishes its
        // insert/remove animation layout pass first. Calling row(forItem:) or
        // selectRowIndexes while animations are in flight can trigger a spurious
        // viewFor:item: call, creating a duplicate cell for the same Tab.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectActiveTab()
            self.applyFocusingSelection(for: self.browserState.focusingTab)
            self.updateVisibleBookmarkTabs()
        }
    }
    
    func focusingTabChanged(_ tab: Tab?) {
        guard isActive else { return }
        clearFloatingProxyIfTabClosed()
        applyFocusingSelection(for: tab)
        updateVisibleBookmarkTabs()
    }
    
    private func expandParents(of bookmark: Bookmark) {
        var parents: [Bookmark] = []
        var current = bookmark.parent
        while let parent = current {
            parents.insert(parent, at: 0)
            current = parent.parent
        }
        
        for parent in parents {
            if !outlineView.isItemExpanded(parent) {
                outlineView.expandItem(parent)
                parent.isExpanded = true
            }
        }
    }
}

// MARK: - Focusing bookmark visibility (temporary UI-only reparenting)
extension SidebarTabListViewController {
    private func restoreExpandedDescendantsIfNeeded(of folder: Bookmark) {
        guard folder.isFolder else { return }
        
        func traverse(_ node: Bookmark) {
            for child in node.children where child.isFolder {
                if child.isExpanded, !outlineView.isItemExpanded(child) {
                    outlineView.expandItem(child)
                    child.isExpanded = true
                }
                traverse(child)
            }
        }
        
        traverse(folder)
    }
    
    private func applyFloatingPresentation(
        from old: (proxy: FocusedBookmarkSidebarItem, insertionParent: SidebarItem?, insertionIndex: Int)?,
        to new: (proxy: FocusedBookmarkSidebarItem, insertionParent: SidebarItem?, insertionIndex: Int)?,
        animated: Bool
    ) {
        let anim: NSOutlineView.AnimationOptions = animated ? [.effectFade, .effectGap] : []
        
        if let old, let new,
           old.proxy.underlyingBookmark.guid == new.proxy.underlyingBookmark.guid,
           old.insertionParent?.id == new.insertionParent?.id,
           old.insertionIndex == new.insertionIndex {
            return
        }
        if old == nil, new == nil {
            return
        }
        
        outlineView.beginUpdates()
        
        if let old {
            focusedBookmarkPresentation = nil
            if canApplyFocusedPresentationMutation(parent: old.insertionParent, index: old.insertionIndex, isInsertion: false) {
                outlineView.removeItems(at: IndexSet(integer: old.insertionIndex), inParent: old.insertionParent, withAnimation: anim)
            } else {
                outlineView.reloadData()
            }
        }
        
        if let new {
            focusedBookmarkPresentation = new
            if canApplyFocusedPresentationMutation(parent: new.insertionParent, index: new.insertionIndex, isInsertion: true) {
                outlineView.insertItems(at: IndexSet(integer: new.insertionIndex), inParent: new.insertionParent, withAnimation: anim)
            } else {
                outlineView.reloadData()
            }
        }
        
        outlineView.endUpdates()
    }
    private func rebuildFloatingBookmarkPresentationIfNeeded() {
        guard let bookmarkGuid = floatingBookmarkGuid,
              let bookmark = browserState.bookmarkManager.bookmark(withGuid: bookmarkGuid) else {
            focusedBookmarkPresentation = nil
            floatingBookmarkGuid = nil
            floatingAnchorFolderGuid = nil
            return
        }
        
        var parents: [Bookmark] = []
        var current = bookmark.parent
        while let p = current {
            parents.insert(p, at: 0)
            current = p.parent
        }
        
        guard let firstCollapsed = parents.first(where: { $0.isFolder && !outlineView.isItemExpanded($0) }) else {
            focusedBookmarkPresentation = nil
            floatingBookmarkGuid = nil
            floatingAnchorFolderGuid = nil
            return
        }
        
        floatingAnchorFolderGuid = firstCollapsed.guid
        
        guard let expected = expectedProxyInsertionAfterCollapsedFolder(firstCollapsed) else {
            focusedBookmarkPresentation = nil
            floatingBookmarkGuid = nil
            floatingAnchorFolderGuid = nil
            return
        }
        
        let indentationLevel = max(0, firstCollapsed.depth) + 1
        let proxy = FocusedBookmarkSidebarItem(bookmark: bookmark, indentationLevelOverride: indentationLevel)
        focusedBookmarkPresentation = (proxy: proxy, insertionParent: expected.insertionParent, insertionIndex: expected.insertionIndex)
    }

    /// Updates `browserState.visibleBookmarkTabs` based on what bookmark items are currently visible in the outline view.
    /// The order is the same as the sidebar visual order (top-to-bottom).
    private func updateVisibleBookmarkTabs() {
        guard isActive else {
            browserState.visibleBookmarkTabs = []
            return
        }
        guard showBookmarks else {
            browserState.visibleBookmarkTabs = []
            return
        }
        
        var guidsInOrder: [String] = []
        guidsInOrder.reserveCapacity(16)
        var seen = Set<String>()

        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? SidebarItem else { continue }
            guard item.isBookmark else { continue }

            let guid: String?
            if let bookmark = item as? Bookmark, bookmark.isFolder == false {
                guid = bookmark.guid
            } else if let provider = item as? UnderlyingBookmarkProviding, provider.underlyingBookmark.isFolder == false {
                guid = provider.underlyingBookmark.guid
            } else {
                guid = nil
            }

            guard let guid, !guid.isEmpty, !seen.contains(guid) else { continue }
            seen.insert(guid)
            guidsInOrder.append(guid)
        }

        var bookmarksInOrder: [Bookmark] = []
        bookmarksInOrder.reserveCapacity(guidsInOrder.count)
        for guid in guidsInOrder {
            if let bookmark = browserState.bookmarkManager.bookmark(withGuid: guid) {
                bookmarksInOrder.append(bookmark)
            }
        }

        browserState.visibleBookmarkTabs = bookmarksInOrder
    }

    /// Computes `focusedBookmarkPresentation` so that the focusing bookmark tab is always visible,
    /// even when some of its parent folders are collapsed.
    ///
    /// Rules (matching the examples in the request):
    /// - If the first collapsed folder on the path is `Folder1`, show the focusing bookmark as a sibling right after `Folder1`.
    /// - If `Folder1` is expanded but `Folder2` is collapsed, show it under `Folder1`, right after `Folder2` (same level as `Folder2`).
    /// - This state is temporary and never changes the real `Bookmark.parent`.
    private func isBookmark(_ bookmark: Bookmark, descendantOf ancestor: Bookmark) -> Bool {
        var current: Bookmark? = bookmark.parent
        while let p = current {
            if p == ancestor { return true }
            current = p.parent
        }
        return false
    }
    
    /// The proxy is always inserted as a sibling right after the first-collapsed folder.
    /// This helper computes that expected insertion location for a given collapsed folder,
    /// matching the data source's indexing rules (including `visibleChildren` filtering).
    private func expectedProxyInsertionAfterCollapsedFolder(_ folder: Bookmark) -> (insertionParent: SidebarItem?, insertionIndex: Int)? {
        if let parent = folder.parent {
            let siblings = visibleChildren(for: parent)
            let idx = siblings.firstIndex(where: { $0.id == folder.id }) ?? siblings.count
            return (insertionParent: parent, insertionIndex: min(idx + 1, siblings.count))
        } else {
            let idx = allItems.firstIndex(where: { $0.id == folder.id }) ?? 0
            return (insertionParent: nil, insertionIndex: min(idx + 1, allItems.count))
        }
    }
    
    /// Computes a temporary, UI-only "presentation" for the focusing bookmark tab so it remains visible
    /// even when some of its ancestor folders are collapsed in the outline view.
    ///
    /// This method DOES NOT mutate the real bookmark tree (`Bookmark.parent` / `Bookmark.children`).
    /// Instead, it returns a tuple describing:
    /// - a proxy item (`FocusedBookmarkSidebarItem`) that renders like the underlying `Bookmark`
    /// - where that proxy should be inserted (which parent, and at what child index) in the outline view
    ///
    /// - Parameters:
    ///   - tab: The current focusing tab. If it is not a bookmark-backed tab (or cannot be mapped to a `Bookmark`),
    ///     this returns `nil`.
    ///   - collapsedOverride: A *prediction hint* used during transitions (typically right before collapsing a folder).
    ///     If provided, this folder will be treated as "collapsed" for the purpose of finding the first collapsed
    ///     ancestor, even if `outlineView.isItemExpanded(folder)` is still `true` at the time of computation.
    ///     This allows us to place the proxy in the correct post-collapse location BEFORE the collapse animation runs.
    ///   - expandedOverride: A *prediction hint* used during transitions (typically right before expanding a folder).
    ///     If provided, this folder will be treated as "expanded" for the purpose of finding the first collapsed
    ///     ancestor, even if `outlineView.isItemExpanded(folder)` is still `false` at the time of computation.
    ///     This allows us to compute the correct post-expand placement (often removing the proxy altogether)
    ///     without waiting for the expand animation to fully finish.
    ///
    /// - Returns:
    ///   A presentation tuple (proxy + insertion location), or `nil` when the focusing bookmark is already visible
    ///   at its real position (i.e., there is no collapsed ancestor in the current/predicted state).
    private func computeFocusedBookmarkPresentation(
        for tab: Tab?,
        treatingFolderAsCollapsed collapsedOverride: Bookmark? = nil,
        treatingFolderAsExpanded expandedOverride: Bookmark? = nil
    ) -> (proxy: FocusedBookmarkSidebarItem, insertionParent: SidebarItem?, insertionIndex: Int)? {
        guard showBookmarks else {
            return nil
        }
        guard let tab else {
            return nil
        }
        
        if allItems.contains(where: { $0.id == tab.id }) {
            return nil
        }
        
        guard let localGuid = tab.guidInLocalDB,
              let bookmark = browserState.bookmarkManager.bookmark(withGuid: localGuid),
              !bookmark.isFolder else {
            return nil
        }
        
        var parents: [Bookmark] = []
        var current = bookmark.parent
        while let parent = current {
            parents.insert(parent, at: 0)
            current = parent.parent
        }
        
        guard let firstCollapsed = parents.first(where: { parent in
            guard parent.isFolder else { return false }
            if let collapsedOverride, parent == collapsedOverride {
                return true
            }
            if let expandedOverride, parent == expandedOverride {
                return false
            }
            return !outlineView.isItemExpanded(parent)
        }) else {
            return nil
        }
        
        let visualIndentationLevel = max(0, firstCollapsed.depth) + 1
        let proxy = FocusedBookmarkSidebarItem(bookmark: bookmark, indentationLevelOverride: visualIndentationLevel)
        
        if let insertionParent = firstCollapsed.parent {
            let children = visibleChildren(for: insertionParent)
            let idx = children.firstIndex(where: { $0.id == firstCollapsed.id }) ?? children.count
            return (proxy: proxy, insertionParent: insertionParent, insertionIndex: min(idx + 1, children.count))
        } else {
            let idx = allItems.firstIndex(where: { $0.id == firstCollapsed.id }) ?? 0
            return (proxy: proxy, insertionParent: nil, insertionIndex: min(idx + 1, allItems.count))
        }
    }

    private func applyFocusedBookmarkPresentation(for tab: Tab?, animated: Bool) {
        let old = focusedBookmarkPresentation
        let new = computeFocusedBookmarkPresentation(for: tab)
        
        if let old, let new,
           old.proxy.underlyingBookmark.guid == new.proxy.underlyingBookmark.guid,
           old.insertionParent?.id == new.insertionParent?.id,
           old.insertionIndex == new.insertionIndex {
            applyFocusingSelection(for: tab)
            updateVisibleBookmarkTabs()
            return
        }
        if old == nil, new == nil {
            applyFocusingSelection(for: tab)
            updateVisibleBookmarkTabs()
            return
        }
        
        let anim: NSOutlineView.AnimationOptions = animated ? [.effectFade, .effectGap] : []
        
        outlineView.beginUpdates()
        
        if let old {
            focusedBookmarkPresentation = nil
            if canApplyFocusedPresentationMutation(parent: old.insertionParent, index: old.insertionIndex, isInsertion: false) {
                outlineView.removeItems(at: IndexSet(integer: old.insertionIndex), inParent: old.insertionParent, withAnimation: anim)
            } else {
                outlineView.reloadData()
            }
        }
        
        if let new {
            focusedBookmarkPresentation = new
            if canApplyFocusedPresentationMutation(parent: new.insertionParent, index: new.insertionIndex, isInsertion: true) {
                outlineView.insertItems(at: IndexSet(integer: new.insertionIndex), inParent: new.insertionParent, withAnimation: anim)
            } else {
                outlineView.reloadData()
            }
        }
        
        outlineView.endUpdates()
        
        applyFocusingSelection(for: tab)
        updateVisibleBookmarkTabs()
    }
    
    private func clearFloatingProxyIfTabClosed() {
        guard let floatingGuid = floatingBookmarkGuid else { return }
        guard let bookmark = browserState.bookmarkManager.bookmark(withGuid: floatingGuid) else {
            clearFloatingProxyState()
            return
        }
        if !bookmark.isOpened {
            clearFloatingProxyState()
        }
    }
    
    private func clearFloatingProxyState() {
        removeFocusedBookmarkPresentation(animated: true)
        floatingBookmarkGuid = nil
        floatingAnchorFolderGuid = nil
    }
    
    private func removeFocusedBookmarkPresentation(animated: Bool) {
        guard let old = focusedBookmarkPresentation else { return }
        let anim: NSOutlineView.AnimationOptions = animated ? [.effectFade, .effectGap] : []
        
        outlineView.beginUpdates()
        focusedBookmarkPresentation = nil
        if canApplyFocusedPresentationMutation(parent: old.insertionParent, index: old.insertionIndex, isInsertion: false) {
            outlineView.removeItems(at: IndexSet(integer: old.insertionIndex), inParent: old.insertionParent, withAnimation: anim)
        } else {
            outlineView.reloadData()
        }
        outlineView.endUpdates()

        updateVisibleBookmarkTabs()
    }
    
    /// Bounds-check helper to prevent occasional crashes when NSOutlineView structural updates
    /// race with animations or external data refresh.
    private func canApplyFocusedPresentationMutation(parent: SidebarItem?, index: Int, isInsertion: Bool) -> Bool {
        if let parent {
            let count = outlineView(outlineView, numberOfChildrenOfItem: parent)
            if isInsertion {
                return index >= 0 && index <= count
            } else {
                return index >= 0 && index < count
            }
        } else {
            let count = outlineView(outlineView, numberOfChildrenOfItem: nil)
            if isInsertion {
                return index >= 0 && index <= count
            } else {
                return index >= 0 && index < count
            }
        }
    }

    private func scheduleScrollToVisible(forItem item: Any?) {
        guard let item else { return }
        scrollScheduleGeneration += 1
        let generation = scrollScheduleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.scrollScheduleGeneration else { return }
            let row = outlineView.row(forItem: item)
            if row >= 0 {
                animateScrollRowToVisible(row)
            }
        }
    }

    private func animateScrollRowToVisible(_ row: Int) {
        guard row >= 0,
              let scrollView = outlineView.enclosingScrollView else {
            return
        }

        let clipView = scrollView.contentView
        if let layer = clipView.layer,
           let presentation = layer.presentation(),
           presentation.bounds.origin != layer.bounds.origin {
            clipView.setBoundsOrigin(presentation.bounds.origin)
            layer.removeAllAnimations()
        }

        let rowRect = outlineView.rect(ofRow: row)
        let visibleRect = clipView.documentVisibleRect

        var targetY = visibleRect.origin.y
        if rowRect.minY < visibleRect.minY {
            targetY = rowRect.minY
        } else if rowRect.maxY > visibleRect.maxY {
            targetY = rowRect.maxY - visibleRect.height
        } else {
            return
        }

        let maxY = max(0, outlineView.frame.height - visibleRect.height)
        targetY = max(0, min(targetY, maxY))

        guard abs(targetY - visibleRect.origin.y) > 0.5 else { return }

        scrollAnimationGeneration += 1
        let generation = scrollAnimationGeneration

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clipView.animator().setBoundsOrigin(NSPoint(x: visibleRect.origin.x, y: targetY))
        } completionHandler: { [weak self] in
            guard let self, generation == self.scrollAnimationGeneration else {
                return
            }
            scrollView.reflectScrolledClipView(clipView)
        }
    }
    
    private func applyFocusingSelection(for tab: Tab?) {
        guard let tab else {
            lastScrolledFocusingTabId = nil
            selectItem(nil)
            return
        }
        
        let shouldScroll = tab.id != lastScrolledFocusingTabId
        
        if let item = allItems.first(where: { $0.id == tab.id }) {
            selectItem(item, clearSelectionFirst: true)
            if shouldScroll {
                lastScrolledFocusingTabId = tab.id
                scheduleScrollToVisible(forItem: item)
            }
            return
        }
        
        if let presentation = focusedBookmarkPresentation,
           let guid = tab.guidInLocalDB,
           presentation.proxy.underlyingBookmark.guid == guid {
            let row = outlineView.row(forItem: presentation.proxy)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if shouldScroll {
                    lastScrolledFocusingTabId = tab.id
                    scheduleScrollToVisible(forItem: presentation.proxy)
                }
            } else {
                selectItem(nil)
            }
            return
        }
        
        guard let localGuid = tab.guidInLocalDB,
              let bookmark = browserState.bookmarkManager.bookmark(withGuid: localGuid) else {
            selectItem(nil)
            return
        }
        var row = outlineView.row(forItem: bookmark)
        if row < 0 {
            expandParents(of: bookmark)
            row = outlineView.row(forItem: bookmark)
        }
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if shouldScroll {
                lastScrolledFocusingTabId = tab.id
                scheduleScrollToVisible(forItem: bookmark)
            }
        } else {
            selectItem(nil)
        }
    }
}

// MARK: - right click menu
extension SidebarTabListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.contextMenu else {
            return
        }
        
        guard let clickedRow = outlineView.rightClickedRow,
              let item = outlineView.item(atRow: clickedRow) as? ContextMenuRepresentable else {
                  defultMenu(on: menu)
                  return
              }
       
        if let bookmark = item as? Bookmark {
            bookmark.makeContextMenu(on: menu, source: .sidebar)
        } else {
            item.makeContextMenu(on: menu)
        }
    }
    
    private func defultMenu(on menu: NSMenu) {
        contextMenuHelper.populate(menu)
    }
}

// MARK: - BookmarkCellViewDelegate
extension SidebarTabListViewController: BookmarkCellViewDelegate {
    func bookmarkCellDidEndEditing(_ bookmark: Bookmark, newTitle: String) {
        browserState.bookmarkManager.updateBookmark(guid: bookmark.guid, title: newTitle, url: nil)
    }
}

extension SidebarTabListViewController: TabCellDelegate {
    func tabCellDidRequestClose(_ tab: Tab) {
        tabSectionController.closeTab(tab)
    }
}

// MARK: - Middle Click to Close Tab
extension SidebarTabListViewController: SideBarOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, draggingEntered sender: any NSDraggingInfo) {
        expandFloatingBookmarkParentsIfNeeded()
    }
    
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        browserState.tabDraggingSession.attachNativeSession(session)
        browserState.tabDraggingSession.update(
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y)
        )
    }
    
    func outlineView(_ outlineView: SideBarOutlineView, didMiddleClickRow row: Int) {
        guard row >= 0 else { return }
        guard let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        guard let tab = item as? Tab, !tab.isPinned else { return }
        tabSectionController.closeTab(tab)
    }
}



/// About Floating Tabs (Floating Bookmark Proxy)
///
/// A "floating tab" is a temporary proxy node (`FocusedBookmarkSidebarItem`) inserted into the
/// outline view data source when the currently-focusing bookmark tab is hidden because its parent
/// folders are collapsed. This keeps the bookmark visible and clickable in the sidebar.
///
/// #### 1) Implementation (UI-only, real hierarchy untouched)
/// - `Bookmark.parent` / `Bookmark.children` are **never** mutated.
/// - A `FocusedBookmarkSidebarItem` (conforming to `UnderlyingBookmarkProviding`) is injected
///   into a parent's children via `insertItems/removeItems + beginUpdates/endUpdates` to avoid
///   breaking animations with `reloadData()`.
///
/// #### 2) Sticky state (follows collapse/expand, not focusing)
/// Once a floating proxy appears (e.g. Tab1 floats when F1 collapses), it persists even if the
/// user switches to another tab. It disappears only when the anchor folder expands and the real
/// bookmark becomes visible again.
///
/// - Key state:
///   - `floatingBookmarkGuid`: the bookmark currently floating.
///   - `floatingAnchorFolderGuid`: the first collapsed ancestor folder the proxy attaches after.
///
/// - Triggers:
///   - **User collapses a folder**: if the focusing bookmark is a descendant, record the floating
///     state, compute insertion position, and insert proxy.
///   - **User expands a folder**: enters the rebuild/evaluate flow (see section 3).
///   - **focusingTabChanged / tabSectionDidUpdate**: removes proxy if the bookmark's tab is closed.
///
/// #### 3) How the proxy moves/disappears (example: F1 -> F2 -> Tab1)
/// The proxy always attaches after the **first collapsed ancestor** on the path:
/// - F1 collapsed: Tab1 floats after F1
/// - F1 expanded, F2 collapsed: Tab1 moves to after F2 (under F1)
/// - Both expanded: Tab1 visible at its real position, proxy removed
///
/// Implemented by `rebuildFloatingBookmarkPresentationIfNeeded()`:
/// - Walks the parent chain from `floatingBookmarkGuid` to find the first collapsed folder.
/// - If none found: clear floating state + remove proxy.
/// - If found: update `floatingAnchorFolderGuid` and reposition proxy after that folder.
///
/// #### 4) Indentation
/// The proxy is inserted as a sibling, so its real outline level may be shallower than expected.
/// `SidebarIndentationLevelProviding.indentationLevelOverride` is set to `firstCollapsedFolder.depth + 1`,
/// and `SideBarOutlineView` uses `max(level(forRow:), override)` for the final indentation.
///
/// #### 5) Caveats (animation / consistency / state restoration)
/// - **Never mutate structure during expand/collapse animation**: `outlineViewItemDidExpand/Collapse`
///   defers proxy rebuild via `DispatchQueue.main.async` to avoid NSOutlineView internal state crashes.
/// - **Ancestor collapse must not pollute descendant isExpanded**: collapsing F1 also triggers F2's
///   collapse notification. `userInitiatedToggleFolderGuid` distinguishes user-initiated toggles from
///   passive cascading collapses, preserving F2's expanded state for restoration.
/// - **Descendant expansion restoration**: `restoreExpandedDescendantsIfNeeded(of:)` re-expands
///   descendants marked `isExpanded` in the model after their ancestor is expanded.
///
/// #### 6) Keyboard tab switching (CMD+[ ] / CMD+number)
/// - `browserState.visibleBookmarkTabs` is maintained by `updateVisibleBookmarkTabs()`, including
///   both opened and unopened bookmarks visible in the outline view (including proxy -> underlying).
/// - `BrowserState.switchTab` uses `openBookmark(_:)` for bookmark candidates.
///
/// #### 7) Drag & drop handling (expandFloatingBookmarkParentsIfNeeded)
/// The proxy injected into `dataSourceChildren` shifts NSOutlineView's child indices (data-source
/// space) away from the model indices expected by `handleDrop`, causing indicator/drop mismatches.
///
/// Solution: expand the proxy's parent folders when a drag begins so the real bookmark becomes
/// visible and the proxy is removed. During drag, `focusedBookmarkPresentation == nil` and all
/// indices are naturally in model space.
///
/// - **Internal drag**: `willBeginAt` calls `expandFloatingBookmarkParentsIfNeeded()` via
///   `DispatchQueue.main.async` (deferred so NSOutlineView captures the correct drag image first).
/// - **External drag** (pinned tab / other window): `draggingEntered` calls it synchronously.
/// - `shouldExpandItem` blocks expansion when `isDraggingTab == true`;
///   `expandFloatingBookmarkParentsIfNeeded` temporarily sets `allowExpandDuringDrag = true` to bypass.
/// - Folders stay expanded after drag ends; no restoration needed.
