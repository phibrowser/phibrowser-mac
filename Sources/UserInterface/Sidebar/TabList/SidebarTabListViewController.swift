// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

protocol SidebarTabListItemOwner: AnyObject {
    func toggleItemExpanded(_ item: SidebarItem)
    func newTabClicked(_ item: SidebarItem)
    func bookmarkClicked(_ item: SidebarItem)
}

enum SidebarNewTabStickyResolver {
    static func shouldShowFloatingNewTab(rowRect: CGRect, visibleRect: CGRect) -> Bool {
        rowRect.minY < visibleRect.minY
    }

    static func visibleRectExcludingTopOverlay(visibleRect: CGRect, overlayHeight: CGFloat) -> CGRect {
        let hiddenHeight = max(0, min(overlayHeight, visibleRect.height))
        return CGRect(
            x: visibleRect.origin.x,
            y: visibleRect.origin.y + hiddenHeight,
            width: visibleRect.width,
            height: visibleRect.height - hiddenHeight
        )
    }
}

class SidebarTabListViewController: NSViewController {
    private static let bottomContentInset: CGFloat = 130
    private static let bookmarkRenameClickInterval: TimeInterval = 0.5

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

    private struct FloatingBookmarkPresentationState {
        let focusedPresentation: (proxy: FocusedBookmarkSidebarItem, insertionParent: SidebarItem?, insertionIndex: Int)?
        let floatingBookmarkGuid: String?
        let floatingAnchorFolderGuid: String?

        static var cleared: FloatingBookmarkPresentationState {
            FloatingBookmarkPresentationState(
                focusedPresentation: nil,
                floatingBookmarkGuid: nil,
                floatingAnchorFolderGuid: nil
            )
        }
    }
    
    private var outlineView: SideBarOutlineView!
    private var scrollView: NSScrollView!
    private var floatingNewTabView: FloatingNewTabView?
    
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
    private var lastFarringdonAIEnabled = PhiPreferences.AISettings.phiAIEnabled.loadValue()
    private var lastFarringdonTabCountEligible = false
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
    
    /// Drop-target visual feedback: at most one of bookmark folder
    /// or tab-group is highlighted at a time. Replaces the older
    /// `dropFeedbackFolderGuid: String?` single-purpose flag so the
    /// new tab-group highlight (Phase 3) can ride the same state
    /// machine without parallel bookkeeping.
    private enum DropFeedbackTarget: Equatable {
        case none
        case bookmarkFolder(guid: String)
        case tabGroup(token: String)
    }
    private var dropFeedbackTarget: DropFeedbackTarget = .none
    
    /// Temporarily allows folder expansion even during drag, used by `expandFloatingBookmarkParentsIfNeeded`.
    private var allowExpandDuringDrag = false

    /// UI-only drag overlay for a whole group drag. This never changes
    /// Chromium's persisted collapsed state.
    private var temporarilyCollapsedGroupTokenForDrag: String?

    /// Tear-off Esc handling for whole-group pasteboard drags (mirrors
    /// `TabStrip.installGroupDragEscMonitor`): suppresses `moveGroupSliceToNewWindow`
    /// when the user presses Esc so cancel is not mistaken for desktop drop.
    private var wholeGroupSidebarEscMonitor: Any?
    private var activeWholeGroupSidebarDragSession: ObjectIdentifier?
    private var wholeGroupSidebarEscSuppressedTearOff = false
    private var wholeGroupSidebarEndFinalizeDone = false

    private var suppressesFloatingNewTabDuringDrag = false
    private var scrollAnimationGeneration: Int = 0
    private var scrollScheduleGeneration: Int = 0
    private var isActive = false
    private var bookmarkEditRequestGeneration = 0
    private var lastBookmarkRenameClick: (guid: String, timestamp: TimeInterval)?
    
    /// Tracks the identity of the focusing tab we last scrolled to.
    /// Scroll is skipped when the focusing tab hasn't changed (e.g. bookmark expand/collapse).
    /// Update only when scheduling a scroll; clear when focus has no representable sidebar row.
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

    override func viewDidLayout() {
        super.viewDidLayout()
        updateFloatingNewTabVisibility()
    }
    
    private func setupOutlineView() {
        scrollView = OverlayScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.menu = contextMenu
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        outlineView = SideBarOutlineView()
        outlineView.setAccessibilityIdentifier("sidebarTabList")
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
        outlineView.registerForDraggedTypes([.pinnedTab, .normalTab, .normalTabs, .phiBookmark, .tabGroup])
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

        NotificationCenter.default.publisher(
            for: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateFloatingNewTabVisibility()
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateFloatingNewTabVisibility()
        }
        .store(in: &cancellables)

        browserState.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibleGroupOverviewSelection()
            }
            .store(in: &cancellables)

        // Show/hide the broom (organize-tabs) button when AI is toggled, mirroring
        // how the sidebar drives other AI UI off `UserDefaults.didChangeNotification`.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let enabled = PhiPreferences.AISettings.phiAIEnabled.loadValue()
                guard enabled != self.lastFarringdonAIEnabled else { return }
                self.lastFarringdonAIEnabled = enabled
                self.updateNewTabCleanupVisibility()
            }
            .store(in: &cancellables)

        // The broom also needs enough tabs to be worth a run; refresh the live
        // cells whenever the count crosses the threshold.
        lastFarringdonTabCountEligible =
            FarringdonOrganizer.isTabCountEligible(
                FarringdonOrganizer.eligibleTabCount(in: browserState.normalTabs))
        browserState.$normalTabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                let eligible = FarringdonOrganizer.isTabCountEligible(
                    FarringdonOrganizer.eligibleTabCount(in: tabs))
                guard eligible != self.lastFarringdonTabCountEligible else { return }
                self.lastFarringdonTabCountEligible = eligible
                self.updateNewTabCleanupVisibility()
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
        dropFeedbackTarget = .none
        allowExpandDuringDrag = false
        scrollAnimationGeneration += 1
        scrollScheduleGeneration += 1
        lastScrolledFocusingTabId = nil
        lastSelectedItem = nil
        userInitiatedToggleFolderGuid = nil
        removeFloatingNewTabCell()
        outlineView.deselectAll(nil)
        outlineView.reloadData()
        outlineView.resetDiffableSnapshot()
        browserState.visibleBookmarkTabs = []
    }
    
    private func startEditingBookmark(_ bookmark: Bookmark) {
        bookmarkEditRequestGeneration &+= 1
        let generation = bookmarkEditRequestGeneration
        endBookmarkEditing(except: bookmark)
        expandParents(of: bookmark)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            guard generation == self.bookmarkEditRequestGeneration else { return }
            scheduleScrollToVisible(forItem: bookmark)
            bookmark.isEditing = true
        }
    }
    
    // MARK: - Data Management
    private func refreshAllItems(afterReload: (() -> Void)? = nil) {
        guard isActive else { return }
        let items = makeAllItems()
        let floatingState = nextFloatingBookmarkPresentationState(rootItems: items)
        let snapshot = makeDiffableSnapshot(
            rootItems: items,
            focusedPresentation: floatingState.focusedPresentation
        )

        outlineView.reloadWith(
            snapshot,
            updateDataSource: { [weak self] in
                guard let self else { return }
                self.allItems = items
                self.focusedBookmarkPresentation = floatingState.focusedPresentation
                self.floatingBookmarkGuid = floatingState.floatingBookmarkGuid
                self.floatingAnchorFolderGuid = floatingState.floatingAnchorFolderGuid
            },
            prepareReloadData: { [weak self] in
                self?.invalidateExistingTabCells()
            },
            completion: { [weak self] in
                guard let self else { return }
                self.selectActiveTab()
                self.applyFocusingSelection(for: self.browserState.focusingTab)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updateVisibleBookmarkTabs()
                    self.updateFloatingNewTabVisibility()
                    afterReload?()
                }
            }
        )
    }

    private func makeAllItems() -> [SidebarItem] {
        var items: [SidebarItem] = []

        if showBookmarks {
            items.append(contentsOf: bookmarkSectionController.bookmarkItems)
            if !bookmarkSectionController.bookmarkItems.isEmpty && !tabSectionController.tabItems.isEmpty {
                items.append(separatorItem)
            }
        }

        items.append(contentsOf: tabSectionController.tabItems)
        return items
    }

    private func makeDiffableSnapshot(
        rootItems: [SidebarItem],
        focusedPresentation: (
            proxy: FocusedBookmarkSidebarItem,
            insertionParent: SidebarItem?,
            insertionIndex: Int
        )?
    ) -> DiffableOutlineSnapshot<AnyHashable> {
        let virtualInsertion: SidebarDiffableSnapshotBuilder.VirtualInsertion?
        if let focusedPresentation {
            virtualInsertion = .init(
                item: focusedPresentation.proxy,
                parentID: focusedPresentation.insertionParent?.id,
                index: focusedPresentation.insertionIndex
            )
        } else {
            virtualInsertion = nil
        }

        return SidebarDiffableSnapshotBuilder(
            rootItems: rootItems,
            virtualInsertion: virtualInsertion,
            hiddenItemID: temporarilyHiddenRealBookmarkGuid.map(AnyHashable.init)
        ).makeSnapshot()
    }

    private func syncDiffableSnapshotToCurrentDataSource() {
        outlineView.resetDiffableSnapshot(
            makeDiffableSnapshot(
                rootItems: allItems,
                focusedPresentation: focusedBookmarkPresentation
            )
        )
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
        // Grouped tabs are no longer outline children — they render
        // inside `TabGroupCellView`'s inner table and surface their
        // active state via SwiftUI's per-cell `isActive` driver. The
        // outline selection therefore only needs to handle root-level
        // (ungrouped) rows.
        for item in allItems {
            if let tab = item as? Tab, tab.isActive {
                selectItem(tab, clearSelectionFirst: true)
                return
            }
        }
    }
    
    private func selectItem(_ item: SidebarItem?, clearSelectionFirst: Bool = true) {
        if item == nil || clearSelectionFirst {
            outlineView.deselectAll(nil)
        }
        if let item, item.isActive {
            let index = outlineView.row(forItem: item)
            outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func clearFocusingSelection() {
        lastScrolledFocusingTabId = nil
        selectItem(nil)
    }
    
    // MARK: - Actions
    @objc private func outlineViewClicked(_ sender: NSOutlineView) {
        let clickedRow = sender.clickedRow
        guard clickedRow != -1 else {
            cancelPendingBookmarkRenameClick()
            endBookmarkEditing(except: nil)
            return
        }

        if let bookmark = bookmarkForRow(clickedRow), !bookmark.isFolder {
            if shouldStartBookmarkRename(for: bookmark, event: NSApp.currentEvent) {
                requestBookmarkRename(bookmark)
                return
            }
            if bookmark.isEditing {
                cancelPendingBookmarkRenameClick()
                return
            }
            rememberBookmarkRenameClick(for: bookmark, event: NSApp.currentEvent)
        } else {
            cancelPendingBookmarkRenameClick()
        }
        
        if let item = outlineView.item(atRow: clickedRow) as? SidebarItem {
            // Cmd+click toggles tab multi-selection; the owner decides eligibility.
            let isCommandClick = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            if isCommandClick,
               handleMultiSelectionCommandClick(for: item) {
                return
            }
            if browserState.multiSelection.isActive {
                browserState.clearMultiSelection()
            }
            itemClicked(item)
        }
    }

    private func handleMultiSelectionCommandClick(for item: SidebarItem) -> Bool {
        if let tab = item as? Tab {
            return browserState.toggleMultiSelection(for: tab)
        }
        if let pair = item as? SplitPairSidebarItem {
            return browserState.toggleMultiSelectionForSplitPair(
                leftTab: pair.leftTab,
                rightTab: pair.rightTab
            )
        }
        return false
    }

    @objc private func outlineViewDoubleClicked(_ sender: NSOutlineView) {
        let clickedRow = sender.clickedRow
        guard clickedRow != -1 else { return }
        guard let bookmark = bookmarkForRow(clickedRow), !bookmark.isFolder else { return }
        guard !isSplitBookmark(bookmark) else { return }
        guard !bookmark.isEditing else { return }
        requestBookmarkRename(bookmark)
    }
    
    private func itemClicked(_ item: SidebarItem) {
        cancelPendingBookmarkEditRequest()
        endBookmarkEditing(except: bookmark(from: item))
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
        return bookmark(from: item)
    }

    private func bookmark(from item: SidebarItem) -> Bookmark? {
        if let bookmark = item as? Bookmark { return bookmark }
        if let provider = item as? UnderlyingBookmarkProviding { return provider.underlyingBookmark }
        return nil
    }

    private func isSplitBookmark(_ bookmark: Bookmark) -> Bool {
        guard let secondaryURL = bookmark.secondaryUrl else { return false }
        return !secondaryURL.isEmpty
    }

    private func shouldStartBookmarkRename(for bookmark: Bookmark, event: NSEvent?) -> Bool {
        guard !isSplitBookmark(bookmark) else { return false }
        if (event?.clickCount ?? 0) > 1 {
            return true
        }
        let timestamp = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        guard let last = lastBookmarkRenameClick, last.guid == bookmark.guid else {
            return false
        }
        return timestamp - last.timestamp <= Self.bookmarkRenameClickInterval
    }

    private func rememberBookmarkRenameClick(for bookmark: Bookmark, event: NSEvent?) {
        lastBookmarkRenameClick = (
            guid: bookmark.guid,
            timestamp: event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        )
    }

    private func cancelPendingBookmarkRenameClick() {
        lastBookmarkRenameClick = nil
    }

    private func requestBookmarkRename(_ bookmark: Bookmark) {
        cancelPendingBookmarkRenameClick()
        browserState.bookmarkManager.triggerRename(for: bookmark)
    }

    private func cancelPendingBookmarkEditRequest() {
        bookmarkEditRequestGeneration &+= 1
    }

    private func endBookmarkEditing(except keptBookmark: Bookmark?) {
        for bookmark in browserState.bookmarkManager.getAllBookmarks() {
            guard bookmark.isEditing else { continue }
            if bookmark.guid == keptBookmark?.guid { continue }
            bookmark.isEditing = false
        }
    }

    private static func dragThresholdLogDescription(for item: Any?) -> String {
        switch item {
        case let tab as Tab:
            return "tab(\(tab.guid))"
        case let groupItem as TabGroupSidebarItem:
            return "tabGroup(\(groupItem.group.token))"
        case let bookmark as Bookmark:
            return "bookmark(\(bookmark.guid))"
        case let sidebarItem as SidebarItem:
            return String(describing: sidebarItem.itemType)
        case .some(let value):
            return String(describing: type(of: value))
        case .none:
            return "nil"
        }
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

    private struct FavoriteGroupDropDestination {
        let token: String
        let normalTabsIndex: Int
        let groupIndex: Int
    }

    private func favoriteGroupDropDestination(
        outlineView: NSOutlineView,
        info: NSDraggingInfo,
        resolvedItem: Any?,
        resolvedIndex: Int
    ) -> FavoriteGroupDropDestination? {
        let dropCtx = buildDropContext(
            outlineView: outlineView,
            info: info,
            proposedItem: resolvedItem,
            proposedChildIndex: resolvedIndex
        )
        let intent = SidebarGroupDropResolver.resolve(dropCtx)
        let tokenAndIndex: (token: String, index: Int)?
        switch intent {
        case .joinAtFront(let token, let index),
             .reorderInGroup(let token, let index):
            tokenAndIndex = (token, index)
        case .rootInsert, .rejected:
            tokenAndIndex = nil
        }
        guard let tokenAndIndex else { return nil }
        return FavoriteGroupDropDestination(
            token: tokenAndIndex.token,
            normalTabsIndex: tokenAndIndex.index,
            groupIndex: groupInsertionIndex(
                token: tokenAndIndex.token,
                normalTabsIndex: tokenAndIndex.index
            )
        )
    }

    private func groupInsertionIndex(token: String, normalTabsIndex: Int) -> Int {
        let members = browserState.normalTabs.filter { $0.groupToken == token }
        guard !members.isEmpty,
              let groupLowerBound = browserState.normalTabs.firstIndex(where: { $0.groupToken == token }) else {
            return 0
        }
        return max(0, min(normalTabsIndex - groupLowerBound, members.count))
    }

    private func draggedBookmark(from pasteboard: NSPasteboard) -> Bookmark? {
        guard let guid = pasteboard.string(forType: .phiBookmark) else { return nil }
        return findBookmark(withId: guid)
    }

    private func canMoveBookmarkToGroup(_ bookmark: Bookmark) -> Bool {
        // Split-view bookmarks (non-empty `secondaryUrl`) are allowed too:
        // `moveBookmarkOut` folds them into the group as a split.
        !bookmark.isFolder
    }

    private func canMovePinnedTabToGroup(pinnedGuid: String) -> Bool {
        // Pinned splits (non-nil `splitPartnerGuid`) are allowed too:
        // `movePinnedTabOut` folds the pair into the group as a split.
        browserState.pinnedTabs.contains { $0.guidInLocalDB == pinnedGuid }
    }

    private func canMoveDraggedBookmarkToGroup(from pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.string(forType: .phiBookmark) != nil else { return true }
        guard let bookmark = draggedBookmark(from: pasteboard) else { return false }
        return canMoveBookmarkToGroup(bookmark)
    }

    private func canMoveDraggedPinnedTabToGroup(from pasteboard: NSPasteboard) -> Bool {
        guard let pinnedGuid = pasteboard.string(forType: .pinnedTab) else { return true }
        return canMovePinnedTabToGroup(pinnedGuid: pinnedGuid)
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

    private func configureNormalTabDragPayload(_ pasteboardItem: NSPasteboardItem,
                                               startingFrom tab: Tab) {
        pasteboardItem.setString(String(tab.guid), forType: .normalTab)
        pasteboardItem.setString(String(browserState.windowId), forType: .sourceWindowId)
        let batchIds = browserState.multiSelectionDragTabIds(startingFrom: tab)
        if let ids = batchIds {
            pasteboardItem.setString(ids.map(String.init).joined(separator: ","),
                                     forType: .normalTabs)
        }
        AppLogDebug(
            "[SidebarMultiDrag] payload windowId=\(browserState.windowId) " +
            "startTabId=\(tab.guid) batchIds=\(batchIds ?? []) " +
            "selectionActive=\(browserState.multiSelection.isActive)"
        )
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        let pasteboardItem = NSPasteboardItem()

        if let tab = sidebarItem as? Tab {
            // Phase 3: grouped tabs are draggable. Resolver decides drop intent.
            configureNormalTabDragPayload(pasteboardItem, startingFrom: tab)
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] pasteboardWriter normalTab " +
                "guid=\(tab.guid) windowId=\(browserState.windowId)"
            )
            return pasteboardItem
        }

        if let pair = sidebarItem as? SplitPairSidebarItem {
            // The merged split row drags as a unit. Write the left pane's
            // guid as `.normalTab`; downstream drop handlers already detect
            // that a dragged tab belongs to a split and move both panes
            // together (`moveSplitPairOrderLocally`,
            // `pinSplitInsertingAtPinnedIndex`, `addSplitBookmarkFromTab`).
            configureNormalTabDragPayload(pasteboardItem, startingFrom: pair.leftTab)
            return pasteboardItem
        }

        if let groupItem = sidebarItem as? TabGroupSidebarItem {
            // Whole-group drag: payload identifies the contiguous block
            // of tabs sharing this token. Drop targets call either
            // `moveNormalTabSlice` (root reorder) or
            // `convertGroupToBookmarks` (bookmark folder).
            pasteboardItem.setString(groupItem.group.token, forType: .tabGroup)
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

    /// Assembles a SidebarGroupDropContext from AppKit's drop input.
    /// Pre-queries the row geometry, normalTabs idx of any proposed
    /// Tab, and the current dragging tab so the resolver stays pure.
    private func buildDropContext(
        outlineView: NSOutlineView,
        info: NSDraggingInfo,
        proposedItem: Any?,
        proposedChildIndex: Int
    ) -> SidebarGroupDropContext {
        let pasteboard = info.draggingPasteboard
        let pasteboardKind: PasteboardKind = {
            if pasteboard.string(forType: .normalTab) != nil { return .normalTab }
            if pasteboard.string(forType: .pinnedTab) != nil { return .pinnedTab }
            if pasteboard.string(forType: .phiBookmark) != nil { return .phiBookmark }
            return .unknown
        }()

        // Source identification.
        let isCrossWindow = isCrossWindowDrag(pasteboard)
        let sourceState = sourceBrowserState(for: pasteboard) ?? browserState
        let crossWindowAccepted = !isCrossWindow ||
            browserState.canAcceptCrossWindowDrag(from: sourceState)

        let draggingTab: Tab? = {
            guard pasteboardKind == .normalTab,
                  let s = pasteboard.string(forType: .normalTab),
                  let guid = Int(s) else { return nil }
            return sourceState.tabs.first(where: { $0.guid == guid })
        }()
        let draggingTabIdx: Int? = draggingTab.flatMap { tab in
            browserState.normalTabs.firstIndex(of: tab)
        }

        // Geometry.
        let cursorYInOutline = outlineView.convert(info.draggingLocation, from: nil).y
        let rowFrame: CGRect? = {
            guard let item = proposedItem else { return nil }
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { return nil }
            var frame = outlineView.rect(ofRow: row)
            if item is TabGroupSidebarItem {
                frame.size.height = min(frame.height, TabGroupCellView.headerHeight)
            }
            return frame
        }()

        // Member metadata for proposed Tab.
        let memberIdx: Int? = {
            guard let tab = proposedItem as? Tab,
                  let token = tab.groupToken else { return nil }
            let members = browserState.normalTabs.filter { $0.groupToken == token }
            return members.firstIndex(of: tab)
        }()
        let normalTabsIdxForProposed: Int? = {
            guard let tab = proposedItem as? Tab else { return nil }
            return browserState.normalTabs.firstIndex(of: tab)
        }()

        return SidebarGroupDropContext(
            proposedItem: proposedItem,
            proposedChildIndex: proposedChildIndex,
            cursorYInOutline: cursorYInOutline,
            outlineIsFlipped: outlineView.isFlipped,
            rowFrameForProposedItem: rowFrame,
            pasteboardKind: pasteboardKind,
            isCrossWindow: isCrossWindow,
            crossWindowAccepted: crossWindowAccepted,
            draggingTab: draggingTab,
            memberIdxInGroupForProposedTab: memberIdx,
            groupRangeInNormalTabs: { [weak self] token in
                guard let self = self else { return nil }
                let firsts = self.browserState.normalTabs.enumerated()
                    .filter { $0.element.groupToken == token }
                    .map { $0.offset }
                guard let lower = firsts.first, let upper = firsts.last else { return nil }
                return lower..<(upper + 1)
            },
            resolveNormalTabsIdx: { [weak self] outlineIdx in
                guard let self = self else { return 0 }
                return self.calculateTabDestinationIndex(from: outlineIdx)
            },
            normalTabsIdxForProposedTab: normalTabsIdxForProposed,
            draggingTabNormalTabsIdx: draggingTabIdx
        )
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let result = _validateDropImpl(outlineView, info: info, proposedItem: item, proposedChildIndex: index)
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] outline.validateDrop item=\(String(describing: item)) " +
            "index=\(index) result=\(result.rawValue) types=\(info.draggingPasteboard.types?.map(\.rawValue) ?? [])"
        )
        return result
    }

    private func _validateDropImpl(_ outlineView: NSOutlineView, info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let originalResolvedItem: Any? = {
            if let provider = item as? UnderlyingBookmarkProviding { return provider.underlyingBookmark }
            return item
        }()
        var resolvedItem = originalResolvedItem
        var resolvedIndex = index

        let pasteboard = info.draggingPasteboard
        guard let pasteboardItem = pasteboard.pasteboardItems?.first else {
            clearDropFeedback()
            return []
        }

        if isCrossWindowDrag(pasteboard),
           let sourceState = sourceBrowserState(for: pasteboard),
           !browserState.canAcceptCrossWindowDrag(from: sourceState) {
            clearDropFeedback()
            return []
        }

        // Whole-group drag: validate before falling into the per-tab
        // resolver. Same-window: root reorder (`moveNormalTabSlice`) or
        // bookmark folder (convert-to-bookmarks). Cross-window onto
        // this sidebar's tab strip: `sourceState.moveGroupSliceToWindow`
        // mirrors `TabStrip.groupDragControllerCommitMoveCrossWindow`.
        if pasteboard.string(forType: .tabGroup) != nil {
            if isCrossWindowDrag(pasteboard) {
                guard let sourceState = sourceBrowserState(for: pasteboard),
                      browserState.canAcceptCrossWindowDrag(from: sourceState),
                      let draggedGroupToken = pasteboard.string(forType: .tabGroup),
                      sourceState.normalTabs.contains(where: {
                          $0.groupToken == draggedGroupToken
                      }) else {
                    clearDropFeedback()
                    return []
                }
                if let targetBookmark = originalResolvedItem as? Bookmark,
                   targetBookmark.isFolder {
                    clearDropFeedback()
                    return []
                }
                if originalResolvedItem is TabGroupSidebarItem {
                    setDropFeedback(.none)
                    return []
                }
                if let tab = originalResolvedItem as? Tab, tab.groupToken != nil {
                    setDropFeedback(.none)
                    return []
                }
                guard originalResolvedItem == nil else {
                    setDropFeedback(.none)
                    return []
                }
                let proposedRootRowCross = index == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : index
                if isRowInBookmarkSection(proposedRootRowCross) {
                    clearDropFeedback()
                    return []
                }
                guard !browserState.normalTabs.isEmpty else {
                    clearDropFeedback()
                    return []
                }
                setDropFeedback(.none)
                return .move
            }
            if let targetBookmark = originalResolvedItem as? Bookmark,
               targetBookmark.isFolder {
                setDropFeedback(.bookmarkFolder(guid: targetBookmark.guid))
                return .copy
            }
            if originalResolvedItem is TabGroupSidebarItem {
                setDropFeedback(.none)
                return []
            }
            if let tab = originalResolvedItem as? Tab, tab.groupToken != nil {
                setDropFeedback(.none)
                return []
            }
            setDropFeedback(.none)
            return .move
        }

        let proposedRootRow = index == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : index
        let isRootBookmarkSectionDrop = originalResolvedItem == nil
            && isRowInBookmarkSection(proposedRootRow)

        if SidebarGroupDropResolver.shouldResolve(
            proposedItem: originalResolvedItem,
            isRootBookmarkSectionDrop: isRootBookmarkSectionDrop) {
            // Phase 3: resolver-driven group drop classification.
            let dropCtx = buildDropContext(
                outlineView: outlineView,
                info: info,
                proposedItem: originalResolvedItem,
                proposedChildIndex: index)
            let intent = SidebarGroupDropResolver.resolve(dropCtx)

            AppLogDebug("[TAB_GROUPS][SIDEBAR_DRAG] validate intent=\(intent) " +
                        "windowId=\(browserState.windowId)")

            switch intent {
            case .joinAtFront(let token, _), .reorderInGroup(let token, _):
                if !canMoveDraggedPinnedTabToGroup(from: pasteboard)
                    || !canMoveDraggedBookmarkToGroup(from: pasteboard) {
                    setDropFeedback(.none)
                    return []
                }
                setDropFeedback(.tabGroup(token: token))
                // Let AppKit's native line indicator coexist with our highlight.
                return .move

            case .rootInsert:
                setDropFeedback(.none)
                // Fall through to existing root-insert handling below: that path
                // is correct for ungrouped placement, including the bookmark/
                // pinned section nuances handled further down.
                break

            case .rejected(let reason):
                AppLogDebug("[TAB_GROUPS][SIDEBAR_DRAG] reject reason=\(reason)")
                setDropFeedback(.none)
                return []
            }
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
                if isDragLocationPastLastRow(in: outlineView, dragY: dragLocationInOutline.y, lastRowRect: lastRowRect) {
                    outlineView.setDropItem(nil, dropChildIndex: maxRootDropIndex)
                    return .move
                }
            }
            
            if resolvedIndex > maxRootDropIndex {
                outlineView.setDropItem(nil, dropChildIndex: maxRootDropIndex)
                return .move
            }
        }

        // Keep the blue drop line from landing between the two panes of a
        // split pair. Snap to the side matching the pointer's vertical half so
        // the indicator and the eventual commit agree.
        if resolvedItem == nil,
           resolvedIndex != NSOutlineViewDropOnItemIndex,
           let snapped = snapDropChildIndexOutsideSplitPair(
               outlineView: outlineView,
               dragLocation: info.draggingLocation,
               proposedChildIndex: resolvedIndex) {
            outlineView.setDropItem(nil, dropChildIndex: snapped)
            resolvedIndex = snapped
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
            // Drop ON a tab: redirect to "insert before that tab" in the tab
            // section so the drop indicator and acceptDrop both treat it as a
            // tab-list move. Without this redirect the drop is rejected and
            // pinned→tab-list drags appear unsupported.
            if redirectDropOntoTabIntoTabSection(
                outlineView: outlineView,
                info: info,
                resolvedItem: resolvedItem,
                resolvedIndex: resolvedIndex) {
                return .move
            }
            // Drop ON a non-folder bookmark: redirect to "insert before that
            // bookmark" so pinned→bookmark drags land in the bookmark list
            // at the visible position instead of being rejected.
            if let targetBookmark = resolvedItem as? Bookmark, !targetBookmark.isFolder {
                if let parent = targetBookmark.parent {
                    if let targetIndex = parent.children.firstIndex(of: targetBookmark) {
                        outlineView.setDropItem(parent, dropChildIndex: targetIndex)
                    }
                } else if let targetIndex = bookmarkSectionController.bookmarkItems.firstIndex(where: { ($0 as? Bookmark)?.guid == targetBookmark.guid }) {
                    outlineView.setDropItem(nil, dropChildIndex: targetIndex)
                }
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

            if let targetBookmark = resolvedItem as? Bookmark,
               let insertion = bookmarkInsertionTarget(before: targetBookmark) {
                outlineView.setDropItem(insertion.parent, dropChildIndex: insertion.index)
                return .copy
            }
            
            // Dropping ON a tab (index == -1) would jump it to position 0;
            // redirect to insert before that tab. `outlineView.row(forItem:)`
            // returns a flat row index that includes expanded group children,
            // but `setDropItem(_:dropChildIndex:)` expects a root-child index
            // — the helper locates the target's position in `tabItems` and
            // snaps past any adjacent split-pair boundary.
            if redirectDropOntoTabIntoTabSection(
                outlineView: outlineView,
                info: info,
                resolvedItem: resolvedItem,
                resolvedIndex: resolvedIndex) {
                return .move
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

            // Drop ON a tab: redirect to "insert before that tab" so a
            // bookmark→tab-list drag commits as a tab-section drop instead
            // of falling through to []. Without this the user can only drop
            // in the narrow gap between tabs.
            if redirectDropOntoTabIntoTabSection(
                outlineView: outlineView,
                info: info,
                resolvedItem: resolvedItem,
                resolvedIndex: resolvedIndex) {
                return .move
            }

            AppLogDebug("[validateDrop] -> No matching condition, returning []")
        }

        return []
    }

    private func acceptNormalTabBatchDrop(tabIds: [Int],
                                          outlineView: NSOutlineView,
                                          info: NSDraggingInfo,
                                          resolvedItem: Any?,
                                          resolvedIndex: Int) -> Bool {
        guard !isCrossWindowDrag(info.draggingPasteboard),
              tabIds.count > 1 else {
            AppLogDebug(
                "[SidebarMultiDrag] batch drop rejected before resolve " +
                "crossWindow=\(isCrossWindowDrag(info.draggingPasteboard)) " +
                "tabIds=\(tabIds)"
            )
            return false
        }

        if let targetBookmark = resolvedItem as? Bookmark {
            if targetBookmark.isFolder {
                let insertion = resolvedIndex == NSOutlineViewDropOnItemIndex
                    ? nil
                    : resolvedIndex
                return browserState.moveNormalTabs(tabIds: tabIds,
                                                   toBookmark: targetBookmark.guid,
                                                   index: insertion)
            }
            if let insertion = bookmarkInsertionTarget(before: targetBookmark) {
                return browserState.moveNormalTabs(tabIds: tabIds,
                                                   toBookmark: insertion.parent?.guid,
                                                   index: insertion.index)
            }
            AppLogDebug(
                "[SidebarMultiDrag] batch drop rejected on bookmark " +
                "tabIds=\(tabIds)"
            )
            return false
        }

        if resolvedItem == nil {
            let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex
                ? outlineView.numberOfRows
                : resolvedIndex
            if isRowInBookmarkSection(proposedRow) {
                let insertion = resolvedIndex == NSOutlineViewDropOnItemIndex
                    ? nil
                    : resolvedIndex
                return browserState.moveNormalTabs(tabIds: tabIds,
                                                   toBookmark: nil,
                                                   index: insertion)
            }
        }

        let dropCtx = buildDropContext(
            outlineView: outlineView,
            info: info,
            proposedItem: resolvedItem,
            proposedChildIndex: resolvedIndex)
        let intent = SidebarGroupDropResolver.resolve(dropCtx)
        AppLogDebug("[TAB_GROUPS][SIDEBAR_DRAG] batch accept intent=\(intent) " +
                    "windowId=\(browserState.windowId) tabIds=\(tabIds)")

        let (newToken, targetIdx): (String?, Int) = {
            switch intent {
            case .joinAtFront(let token, let index):
                return (token, index)
            case .reorderInGroup(let token, let index):
                return (token, index)
            case .rootInsert(let index):
                return (nil, index)
            case .rejected:
                return (nil, -1)
            }
        }()
        guard targetIdx >= 0 else {
            setDropFeedback(.none)
            return false
        }
        return commitNormalTabBatchDrop(tabIds: tabIds,
                                        to: targetIdx,
                                        targetGroupToken: newToken)
    }

    private func commitNormalTabBatchDrop(tabIds: [Int],
                                          to targetIdx: Int,
                                          targetGroupToken: String?) -> Bool {
        let requestedSet = Set(tabIds)
        let draggedTabs = browserState.normalTabs.filter { requestedSet.contains($0.guid) }
        guard draggedTabs.count > 1 else { return false }
        let beforeOrder = browserState.normalTabs.map(\.guid)

        let desiredTokenById: [Int: String?] = Dictionary(
            uniqueKeysWithValues: draggedTabs.map { ($0.guid, targetGroupToken) }
        )
        let membershipUpdates: [(tabId: Int, newToken: String?)] = draggedTabs.compactMap { tab in
            let desired = desiredTokenById[tab.guid] ?? nil
            guard tab.groupToken != desired else { return nil }
            return (tab.guid, desired)
        }
        let membershipWillChange = !membershipUpdates.isEmpty

        AppLogDebug(
            "[SidebarMultiDrag] batch commit begin windowId=\(browserState.windowId) " +
            "tabIds=\(tabIds) draggedIds=\(draggedTabs.map(\.guid)) " +
            "targetIdx=\(targetIdx) targetGroupToken=\(targetGroupToken ?? "nil") " +
            "membershipWillChange=\(membershipWillChange) before=\(beforeOrder)"
        )
        browserState.moveNormalTabsLocally(tabIds: tabIds,
                                           to: targetIdx,
                                           syncChromiumOrder: !membershipWillChange)
        AppLogDebug(
            "[SidebarMultiDrag] batch commit local order " +
            "after=\(browserState.normalTabs.map(\.guid))"
        )

        if membershipWillChange {
            let removeIds = draggedTabs.compactMap { tab -> NSNumber? in
                let desired = desiredTokenById[tab.guid] ?? nil
                guard tab.groupToken != nil, tab.groupToken != desired else { return nil }
                return NSNumber(value: Int64(tab.guid))
            }
            let addIds = draggedTabs.compactMap { tab -> NSNumber? in
                let desired = desiredTokenById[tab.guid] ?? nil
                guard desired != nil, tab.groupToken != desired else { return nil }
                return NSNumber(value: Int64(tab.guid))
            }
            let bridge = ChromiumLauncher.sharedInstance().bridge
            if !removeIds.isEmpty {
                bridge?.removeTabsFromGroup(withWindowId: Int64(browserState.windowId),
                                            tabIds: removeIds)
            }
            if let targetGroupToken, !addIds.isEmpty {
                bridge?.addTabsToGroup(withWindowId: Int64(browserState.windowId),
                                       tabIds: addIds,
                                       tokenHex: targetGroupToken)
            }
            browserState.applyOptimisticGroupMembership(updates: membershipUpdates)
            browserState.syncNormalTabsRelativeOrderToChromium(tabIds: tabIds)
        }

        browserState.clearMultiSelection()
        setDropFeedback(.none)
        return true
    }
    
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] outline.acceptDrop item=\(String(describing: item)) " +
            "index=\(index) types=\(info.draggingPasteboard.types?.map(\.rawValue) ?? [])"
        )
        let resolvedItem: Any? = {
            if let provider = item as? UnderlyingBookmarkProviding { return provider.underlyingBookmark }
            return item
        }()
        let resolvedIndex = index
        
        defer {
            clearDropFeedback()
            restoreTemporarilyCollapsedGroupAfterDragIfNeeded()
        }

        let pasteboard = info.draggingPasteboard
        guard pasteboard.pasteboardItems?.isEmpty == false else {
            return false
        }
        
        browserState.tabDraggingSession.end()

        // Whole-group drag: drop on a bookmark folder converts the group
        // into a bookmark folder; drop at root reorders the group block
        // as a whole.
        if let token = pasteboard.string(forType: .tabGroup) {
            if isCrossWindowDrag(pasteboard) {
                guard let sourceState = sourceBrowserState(for: pasteboard),
                      browserState.canAcceptCrossWindowDrag(from: sourceState) else {
                    return false
                }
                if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                    return false
                }
                if resolvedItem is TabGroupSidebarItem {
                    return false
                }
                if let tab = resolvedItem as? Tab, tab.groupToken != nil {
                    return false
                }
                guard resolvedItem == nil else { return false }
                let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex
                    ? outlineView.numberOfRows
                    : resolvedIndex
                if isRowInBookmarkSection(proposedRow) {
                    return false
                }
                guard !browserState.normalTabs.isEmpty else {
                    AppLogWarn(
                        "[TAB_GROUPS][SIDEBAR_DRAG] cross-window group drop skipped: target has no normal tabs"
                    )
                    return false
                }
                let memberIds = sourceState.normalTabs
                    .filter { $0.groupToken == token }
                    .map(\.guid)
                guard !memberIds.isEmpty else {
                    AppLogWarn(
                        "[TAB_GROUPS][SIDEBAR_DRAG] cross-window group drop skipped: empty members token=\(token)"
                    )
                    return false
                }
                let destination = calculateTabDestinationIndex(from: resolvedIndex)
                AppLogDebug(
                    "[TAB_GROUPS][SIDEBAR_DRAG] cross-window group→moveGroupSliceToWindow " +
                    "srcWindow=\(sourceState.windowId) dstWindow=\(browserState.windowId) " +
                    "token=\(token) destination=\(destination) members=\(memberIds)"
                )
                sourceState.moveGroupSliceToWindow(
                    memberIds: memberIds,
                    targetState: browserState,
                    atIndex: destination
                )
                return true
            }
            if let targetFolder = resolvedItem as? Bookmark, targetFolder.isFolder {
                let insertion = resolvedIndex == NSOutlineViewDropOnItemIndex
                    ? nil
                    : resolvedIndex
                browserState.convertGroupToBookmarks(
                    token: token,
                    parentFolder: targetFolder,
                    at: insertion)
                return true
            }
            if resolvedItem == nil {
                let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex
                    ? outlineView.numberOfRows
                    : resolvedIndex
                if isRowInBookmarkSection(proposedRow) {
                    browserState.convertGroupToBookmarks(
                        token: token,
                        parentFolder: nil,
                        at: resolvedIndex)
                    return true
                }
                let destination = calculateTabDestinationIndex(from: resolvedIndex)
                let memberIds = browserState.normalTabs
                    .filter { $0.groupToken == token }
                    .map(\.guid)
                browserState.moveNormalTabSlice(memberIds: memberIds, to: destination)
                return true
            }
            return false
        }

        if let pinnedTabId = pasteboard.string(forType: .pinnedTab) {
            if let destination = favoriteGroupDropDestination(
                outlineView: outlineView,
                info: info,
                resolvedItem: resolvedItem,
                resolvedIndex: resolvedIndex) {
                guard canMovePinnedTabToGroup(pinnedGuid: pinnedTabId) else {
                    return false
                }
                return browserState.movePinnedTabOut(
                    pinnedGuid: pinnedTabId,
                    toGroup: destination.token,
                    groupIndex: destination.groupIndex,
                    normalTabsIndex: destination.normalTabsIndex,
                    focusAfterCreate: false
                )
            }

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
                // Pinned-split pair: open both URLs as a fresh split in the
                // destination window. The source's pinned record (and its live
                // tabs, if any) stay put — this is "open in another window",
                // not "move".
                if let urls = pinnedSplitURLs(in: sourceState, pinnedGuid: pinnedTabId) {
                    browserState.openTwoURLsAsSplit(primaryURL: urls.primary,
                                                   secondaryURL: urls.secondary)
                    return true
                }
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

        let batchTabIds = pasteboard.phiNormalTabIds()
        if batchTabIds.count > 1 {
            return acceptNormalTabBatchDrop(tabIds: batchTabIds,
                                            outlineView: outlineView,
                                            info: info,
                                            resolvedItem: resolvedItem,
                                            resolvedIndex: resolvedIndex)
        }

        if let draggedItemId = pasteboard.string(forType: .normalTab),
           let tabGuid = Int(draggedItemId) {
            let crossWindowSource = sourceBrowserState(for: pasteboard)
            if isCrossWindowDrag(pasteboard), let sourceState = crossWindowSource,
               let draggedTab = sourceState.tabs.first(where: { $0.guid == tabGuid }) {

                if let targetBookmark = resolvedItem as? Bookmark, targetBookmark.isFolder {
                    // Split-pair tabs become a single split-view bookmark in
                    // the destination window; fall through to `moveNormalTab`
                    // for plain tabs.
                    let dropIndex = resolvedIndex == NSOutlineViewDropOnItemIndex ? 0 : resolvedIndex
                    if let targetFolder = browserState.bookmarkManager.bookmark(withGuid: targetBookmark.guid),
                       sourceState.addSplitBookmarkFromTab(draggedTab, toFolder: targetFolder, targetIndex: dropIndex) {
                        return true
                    }
                    sourceState.moveNormalTab(
                        tabId: draggedTab.guid,
                        toBookmark: targetBookmark.guid,
                        index: dropIndex
                    )
                    return true
                }

                if let targetBookmark = resolvedItem as? Bookmark,
                   let insertion = bookmarkInsertionTarget(before: targetBookmark) {
                    sourceState.moveNormalTab(
                        tabId: draggedTab.guid,
                        toBookmark: insertion.parent?.guid,
                        index: insertion.index
                    )
                    return true
                }

                let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : resolvedIndex
                if isRowInBookmarkSection(proposedRow) {
                    if sourceState.addSplitBookmarkFromTab(draggedTab, toFolder: nil, targetIndex: resolvedIndex) {
                        return true
                    }
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
            } else if let targetBookmark = resolvedItem as? Bookmark,
                      let insertion = bookmarkInsertionTarget(before: targetBookmark) {
                return bookmarkSectionController.handleDrop(
                    of: draggedTab,
                    to: insertion.parent,
                    at: insertion.index)
            } else {
                // Bookmark-section drop only applies to true root-level drops
                // (resolvedItem == nil). When `resolvedItem` is a group wrapper,
                // a Tab, or any non-nil sidebar item, `resolvedIndex` is a
                // child-index relative to that item — small values would
                // erroneously match `isRowInBookmarkSection` (since
                // `bookmarkSectionEnd` is just `bookmarkItems.count`) and
                // route a tab→group drop into the bookmark section.
                // validateDrop's mirror check (line ~728) is correctly guarded
                // by `if resolvedItem == nil`; this branch must match.
                if resolvedItem == nil {
                    let proposedRow = resolvedIndex == NSOutlineViewDropOnItemIndex ? outlineView.numberOfRows : resolvedIndex
                    if isRowInBookmarkSection(proposedRow) {
                        return bookmarkSectionController.handleDrop(of: draggedTab, to: nil, at: resolvedIndex)
                    }
                }

                let dropCtx = buildDropContext(
                    outlineView: outlineView,
                    info: info,
                    proposedItem: resolvedItem,
                    proposedChildIndex: resolvedIndex)
                let intent = SidebarGroupDropResolver.resolve(dropCtx)
                AppLogDebug("[TAB_GROUPS][SIDEBAR_DRAG] accept intent=\(intent) " +
                            "windowId=\(browserState.windowId) " +
                            "tabId=\(draggedTab.guid) " +
                            "fromToken=\(draggedTab.groupToken ?? "nil")")

                if case .rejected = intent {
                    setDropFeedback(.none)
                    return false
                }

                let (newToken, targetIdx): (String?, Int) = {
                    switch intent {
                    case .joinAtFront(let t, let i):    return (t, i)
                    case .reorderInGroup(let t, let i): return (t, i)
                    case .rootInsert(let i):            return (nil, i)
                    case .rejected:                     return (nil, -1)
                    }
                }()

                let oldToken = draggedTab.groupToken
                let oldIdx = browserState.normalTabs.firstIndex(of: draggedTab)

                // Splits travel as a unit across the group boundary: if the
                // dragged tab is part of a non-pinned split, the partner
                // pane joins/leaves the group with it so the pair stays
                // adjacent and the merged-row presentation survives the
                // crossing. `moveNormalTabLocally` already handles the
                // split-as-block strip reorder; we extend the bridge
                // membership calls to include both ids and replay the
                // optimistic update on the partner too.
                let splitPartner: Tab? = {
                    guard let group = browserState.splitGroup(forTabId: draggedTab.guid),
                          !group.isPinned,
                          let partnerId = group.partnerTabId(of: draggedTab.guid) else {
                        return nil
                    }
                    return browserState.tabs.first(where: { $0.guid == partnerId })
                }()

                let membershipWillChange = oldToken != newToken
                let shouldDeferChromiumOrderSync =
                    membershipWillChange && splitPartner == nil
                if let oldIdx = oldIdx, oldIdx != targetIdx {
                    browserState.moveNormalTabLocally(
                        from: oldIdx,
                        to: targetIdx,
                        syncChromiumOrder: !shouldDeferChromiumOrderSync)
                }
                let memberTabIds: [Int] = {
                    var ids: [Int] = [draggedTab.guid]
                    if let partner = splitPartner {
                        ids.append(partner.guid)
                    }
                    return ids
                }()
                let memberIds = memberTabIds.map { NSNumber(value: Int64($0)) }
                if let bridge = ChromiumLauncher.sharedInstance().bridge,
                   let old = oldToken, membershipWillChange {
                    AppLogDebug("[TAB_GROUPS][SIDEBAR_DRAG] removeTabsFromGroup " +
                                "windowId=\(browserState.windowId) tabIds=\(memberIds) " +
                                "token=\(old)")
                    bridge.removeTabsFromGroup(
                        withWindowId: Int64(browserState.windowId),
                        tabIds: memberIds)
                }
                if let bridge = ChromiumLauncher.sharedInstance().bridge,
                   let new = newToken, membershipWillChange {
                    AppLogDebug("[TAB_GROUPS][SIDEBAR_DRAG] addTabsToGroup " +
                                "windowId=\(browserState.windowId) tabIds=\(memberIds) " +
                                "token=\(new)")
                    bridge.addTabsToGroup(
                        withWindowId: Int64(browserState.windowId),
                        tabIds: memberIds,
                        tokenHex: new)
                }
                // Mirror the membership change on the Mac side immediately
                // so a subsequent layout pass (e.g. switching to
                // Comfortable while `tabJoinedGroup`/`tabLeftGroup` is
                // still queued on EventBus) doesn't see the
                // [member, non-member, member] split this drop just made.
                if membershipWillChange {
                    var updates: [(tabId: Int, newToken: String?)] =
                        [(draggedTab.guid, newToken)]
                    if let partner = splitPartner {
                        updates.append((partner.guid, newToken))
                    }
                    browserState.applyOptimisticGroupMembership(
                        updates: updates)
                    if shouldDeferChromiumOrderSync {
                        browserState.syncNormalTabsRelativeOrderToChromium(
                            tabIds: memberTabIds)
                    }
                }

                setDropFeedback(.none)
                return true
            }
        }

        if let draggedBookmarkId = pasteboard.string(forType: .phiBookmark),
           let draggedBookmark = findBookmark(withId: draggedBookmarkId) {

            if let destination = favoriteGroupDropDestination(
                outlineView: outlineView,
                info: info,
                resolvedItem: resolvedItem,
                resolvedIndex: resolvedIndex) {
                guard canMoveBookmarkToGroup(draggedBookmark) else { return false }
                return browserState.moveBookmarkOut(
                    draggedBookmark,
                    toGroup: destination.token,
                    groupIndex: destination.groupIndex,
                    normalTabsIndex: destination.normalTabsIndex,
                    focusAfterCreate: false
                )
            }
            
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
                        // Split bookmark cross-window: open both URLs as a
                        // fresh split in the destination. Source bookmark and
                        // any live split stay put — this is "open in another
                        // window", not "move".
                        if let secondaryURL = draggedBookmark.secondaryUrl, !secondaryURL.isEmpty,
                           let primaryURL = draggedBookmark.url, !primaryURL.isEmpty {
                            browserState.openTwoURLsAsSplit(primaryURL: primaryURL,
                                                           secondaryURL: secondaryURL)
                            return true
                        }
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
        AppLogDebug(
            "[SIDEBAR_TAB_DRAG_THRESHOLD] outline.willBegin " +
            "firstItem=\(Self.dragThresholdLogDescription(for: draggedItems.first)) " +
            "screen=\(screenPoint)"
        )
        if let groupItem = draggedItems.first as? TabGroupSidebarItem {
            temporarilyCollapseGroupForDragIfNeeded(
                groupItem: groupItem,
                cell: nil)
            beginWholeGroupSidebarDragSessionRecording(session)
        }
        DispatchQueue.main.async { [weak self] in
            self?.expandFloatingBookmarkParentsIfNeeded()
            self?.browserState.isDraggingTab = true
        }
        browserState.tabDraggingSession.attachNativeSession(session)
        // Merged split rows are wrapped by `SplitPairSidebarItem`; the
        // `TabDraggingSession` tear-off path branches on the item's type
        // (Bookmark / Tab.isPinned / WebContentRepresentable). Unwrap to
        // the left pane's `Tab` so the live-wrapper path fires and
        // `moveSplit(toNewWindow:)` carries both panes along, matching
        // the bookmark / pinned-split tear-off branches.
        let sessionItem: Any?
        if let pair = draggedItems.first as? SplitPairSidebarItem {
            sessionItem = pair.leftTab
        } else {
            sessionItem = draggedItems.first
        }
        if let tab = sessionItem as? Tab,
           browserState.multiSelection.isActive,
           browserState.multiSelectionDragTabIds(startingFrom: tab) == nil {
            browserState.clearMultiSelection()
        }
        browserState.tabDraggingSession.begin(
            draggingItem: sessionItem,
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            containerView: hostVC?.view
        )
        if let draggedTab = sessionItem as? Tab {
            let didApplyMultiSelectionPreview = applyMultiSelectionDragImageIfNeeded(
                session: session,
                startingFrom: draggedTab,
                sourceImage: nil,
                sourceGroupCell: nil,
                browserState: browserState,
                outlineView: self.outlineView
            )
            // When dragging a tab that belongs to a split, override the default
            // single-row drag image with a composite that shows both pair members
            // stacked in their visual order, so the animation reads as "the whole
            // split is moving" (the drop layer already moves both members).
            if !didApplyMultiSelectionPreview {
                applySplitPairDragImageIfNeeded(session: session, draggedTab: draggedTab)
            }
        }
    }

    /// If the dragged tab is part of a split, replace the dragging image with
    /// a vertical composite of both row snapshots and expand the dragging
    /// frame to cover the pair. No-op for non-split tabs.
    private func applySplitPairDragImageIfNeeded(session: NSDraggingSession, draggedTab: Tab) {
        guard let group = browserState.splitGroup(forTabId: draggedTab.guid) else {
            return
        }
        guard let partnerId = group.partnerTabId(of: draggedTab.guid),
              let partner = browserState.normalTabs.first(where: { $0.guid == partnerId }) else {
            return
        }
        let draggedRow = outlineView.row(forItem: draggedTab)
        let partnerRow = outlineView.row(forItem: partner)
        guard draggedRow >= 0, partnerRow >= 0 else { return }
        guard let draggedCell = outlineView.view(atColumn: 0, row: draggedRow, makeIfNecessary: false) as? SidebarCellView,
              let partnerCell = outlineView.view(atColumn: 0, row: partnerRow, makeIfNecessary: false) as? SidebarCellView,
              let draggedSnapshot = draggedCell.createDraggingImage(),
              let partnerSnapshot = partnerCell.createDraggingImage() else {
            return
        }
        let upperSnapshot: NSImage
        let lowerSnapshot: NSImage
        if draggedRow < partnerRow {
            upperSnapshot = draggedSnapshot
            lowerSnapshot = partnerSnapshot
        } else {
            upperSnapshot = partnerSnapshot
            lowerSnapshot = draggedSnapshot
        }
        guard let composite = makeStackedSplitDragImage(upper: upperSnapshot, lower: lowerSnapshot) else {
            return
        }
        // Anchor the composite so the cursor stays over the originally-dragged
        // row. AppKit reports the original drag frame in window coordinates;
        // shift its origin up by the upper row's height when the dragged row
        // is the lower one so the pair lifts as a unit.
        let upperHeight = upperSnapshot.size.height
        let isDraggedUpper = draggedRow < partnerRow
        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { draggingItem, _, _ in
            var frame = draggingItem.draggingFrame
            if !isDraggedUpper {
                frame.origin.y -= upperHeight
            }
            frame.size = composite.size
            draggingItem.imageComponentsProvider = nil
            draggingItem.setDraggingFrame(frame, contents: composite)
        }
        // Cache the composite so the cross-window page-snapshot switcher in
        // TabDraggingSession can restore it when the cursor returns inside.
        browserState.tabDraggingSession.setOriginalDragImage(composite)
    }

    /// Stacks two row snapshots vertically into a single drag image, matching
    /// the way a split pair renders as a merged rounded bar in the sidebar.
    private func makeStackedSplitDragImage(upper: NSImage, lower: NSImage) -> NSImage? {
        let width = max(upper.size.width, lower.size.width)
        let height = upper.size.height + lower.size.height
        guard width > 0, height > 0 else { return nil }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }
        // Cocoa coordinates are flipped (origin at bottom-left), so the lower
        // row in screen terms is drawn at y=0 and the upper row above it.
        let lowerRect = NSRect(x: 0, y: 0, width: width, height: lower.size.height)
        let upperRect = NSRect(x: 0, y: lower.size.height, width: width, height: upper.size.height)
        lower.draw(in: lowerRect, from: NSRect(origin: .zero, size: lower.size), operation: .sourceOver, fraction: 1.0)
        upper.draw(in: upperRect, from: NSRect(origin: .zero, size: upper.size), operation: .sourceOver, fraction: 1.0)
        return image
    }

    func outlineView(_ outlineView: NSOutlineView,
                     draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        AppLogDebug(
            "[SIDEBAR_TAB_DRAG_THRESHOLD] outline.ended " +
            "screen=\(screenPoint) operation=\(operation.rawValue)"
        )
        finalizeWholeGroupSidebarTearOffIfNeeded(
            session: session,
            screenPoint: screenPoint,
            dragOperation: operation
        )
        clearDropFeedback()
        restoreTemporarilyCollapsedGroupAfterDragIfNeeded()
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

    private func isDragLocationPastLastRow(in outlineView: NSOutlineView, dragY: CGFloat, lastRowRect: NSRect) -> Bool {
        if outlineView.isFlipped {
            return dragY > lastRowRect.maxY
        }
        return dragY < lastRowRect.minY
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
    
    /// A drop landed directly ON a tab row (`dropChildIndex ==
    /// NSOutlineViewDropOnItemIndex`). Redirect the indicator to "insert
    /// before that tab" in tab-section coordinates, snapping past any
    /// adjacent split-pair boundary so the indicator and the eventual
    /// commit agree. Returns true when the redirect was applied — caller
    /// should then return its drag operation. Returns false for non-tab
    /// targets or unresolvable indices, letting caller continue.
    ///
    /// Shared by the pinned-tab, normal-tab, and bookmark validateDrop
    /// branches so the "treat splitviews as one" snap is consistent
    /// across every drag source.
    private func redirectDropOntoTabIntoTabSection(
        outlineView: NSOutlineView,
        info: NSDraggingInfo,
        resolvedItem: Any?,
        resolvedIndex: Int
    ) -> Bool {
        guard resolvedIndex == NSOutlineViewDropOnItemIndex else { return false }
        // SplitPair rows are merged-cell representations of two adjacent
        // panes; without an explicit redirect AppKit reports the drop as
        // landing ON the row and skips the gap indicator entirely, so the
        // user cannot see the insert line on either edge of a splitview
        // tab. Pick the leading or trailing side from the pointer's
        // vertical half within the row.
        //
        // Look the pair up by `id` against the data source rather than
        // via NSOutlineView's identity-keyed cache: `SplitPairSidebarItem`
        // is rebuilt on every `buildItems` pass (its `id` stays stable
        // off `groupId`), so `childIndex(forItem:)` can return -1 in
        // frames where AppKit's cached reference no longer matches the
        // newly-built instance.
        if let pair = resolvedItem as? SplitPairSidebarItem {
            let dragInOutline = outlineView.convert(info.draggingLocation, from: nil)
            let cursorRow = outlineView.row(at: dragInOutline)
            // Resolve the row from the cursor rather than `row(forItem:)`,
            // which can return -1 when AppKit's identity-keyed cache holds a
            // stale reference even though the row is still rendered here.
            guard cursorRow >= 0 else { return false }
            let rowRect = outlineView.rect(ofRow: cursorRow)
            let rootChildren = dataSourceChildren(of: nil)
            guard let pairChildIndex = rootChildren.firstIndex(where: { $0.id == pair.id }) else {
                return false
            }
            let dropAbove = outlineView.isFlipped
                ? dragInOutline.y < rowRect.midY
                : dragInOutline.y > rowRect.midY
            outlineView.setDropItem(nil, dropChildIndex: dropAbove ? pairChildIndex : pairChildIndex + 1)
            return true
        }
        guard let targetTab = resolvedItem as? Tab else { return false }
        let targetRootChildIndex = outlineView.childIndex(forItem: targetTab)
        guard targetRootChildIndex >= 0 else { return false }
        let finalIndex = snapDropChildIndexOutsideSplitPair(
            outlineView: outlineView,
            dragLocation: info.draggingLocation,
            proposedChildIndex: targetRootChildIndex
        ) ?? targetRootChildIndex
        outlineView.setDropItem(nil, dropChildIndex: finalIndex)
        return true
    }

    /// If the proposed drop child index would land strictly between the two
    /// members of an adjacent split pair in the tab section, return the
    /// adjusted child index on whichever side the pointer's vertical half
    /// indicates. Returns nil when the proposed index doesn't fall between a
    /// pair (in which case the original index is fine).
    private func snapDropChildIndexOutsideSplitPair(
        outlineView: NSOutlineView,
        dragLocation: NSPoint,
        proposedChildIndex: Int
    ) -> Int? {
        let tabDestination = calculateTabDestinationIndex(from: proposedChildIndex)
        let pairLowers = browserState.splitPairLowerIndicesInNormalTabs()
        let lo = tabDestination - 1
        guard pairLowers.contains(lo),
              lo >= 0,
              lo + 1 < browserState.normalTabs.count else {
            return nil
        }
        let loRow = outlineView.row(forItem: browserState.normalTabs[lo])
        let hiRow = outlineView.row(forItem: browserState.normalTabs[lo + 1])
        guard loRow >= 0, hiRow >= 0 else { return nil }
        let pairBoundaryY = (outlineView.rect(ofRow: loRow).midY + outlineView.rect(ofRow: hiRow).midY) / 2
        let dragInOutline = outlineView.convert(dragLocation, from: nil)
        let pointerOnUpperHalf = outlineView.isFlipped
            ? dragInOutline.y < pairBoundaryY
            : dragInOutline.y > pairBoundaryY
        return pointerOnUpperHalf ? proposedChildIndex - 1 : proposedChildIndex + 1
    }

    private func calculateTabDestinationIndex(from outlineViewIndex: Int) -> Int {
        // Translate an NSOutlineView root-row index (drop position) into a
        // `normalTabs` insertion index.
        //
        // Semantically the drop is "right before `tabItems[k]`", where
        // `k = outlineViewIndex - tabSectionStart`. The earlier approach
        // accumulated `1 per Tab item, memberCount per group wrapper`,
        // which is wrong during transient kJoined-before-kMoved frames
        // where group members are non-contiguous in `normalTabs`: the
        // wrapper visually represents only its FIRST occurrence in
        // `normalTabs` (later same-token tabs are skipped by `buildItems`
        // to keep one row per group), so summing the full `memberCount`
        // overshoots by the count of trailing non-contiguous members.
        //
        // Anchor on the visual-first-member instead: locate the target
        // entry in `tabItems` and return the strip index of the first
        // tab it represents. This is correct in both contiguous and
        // non-contiguous frames, and makes the drop's "land before X"
        // semantics survive a rebuild — after insertion + buildItems,
        // the new tab appears immediately ahead of the target entry.
        let positionInTabItems = max(0, outlineViewIndex - currentTabSectionStart())
        let items = tabSectionController.tabItems

        // Drop at or before the New-Tab-button row → very front of
        // `normalTabs`. (`tabItems[0]` is always the New-Tab-button.)
        if positionInTabItems <= 1 {
            return 0
        }
        // Drop past the last tab-section item → append to `normalTabs`.
        if positionInTabItems >= items.count {
            return browserState.normalTabs.count
        }

        let target = items[positionInTabItems]
        if let tab = target as? Tab {
            return browserState.normalTabs.firstIndex(of: tab)
                ?? browserState.normalTabs.count
        }
        if let groupItem = target as? TabGroupSidebarItem {
            let token = groupItem.group.token
            return browserState.normalTabs.firstIndex { $0.groupToken == token }
                ?? browserState.normalTabs.count
        }
        if let pair = target as? SplitPairSidebarItem {
            // The merged splitPair row represents its leading pane in the
            // strip — "drop before pair" means "drop before leftTab".
            // Without this branch the function falls through to the
            // "append at end" fallback and the blue indicator line can
            // never land on the leading edge of a splitview tab.
            return browserState.normalTabs.firstIndex(of: pair.leftTab)
                ?? browserState.normalTabs.count
        }
        // Unexpected item type (would be a bug elsewhere) — fall back to
        // append rather than dropping at a wrong index.
        return browserState.normalTabs.count
    }

    private func clearVisibleGroupInnerDropRows() {
        for row in 0..<outlineView.numberOfRows {
            guard let cell = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false) as? TabGroupCellView else {
                continue
            }
            cell.innerTable.setDropRow(-1, dropOperation: .on)
        }
    }

    private func findBookmark(withId id: String) -> Bookmark? {
        return browserState.bookmarkManager.bookmark(withGuid: id)
    }

    private func bookmarkInsertionTarget(before bookmark: Bookmark) -> (parent: Bookmark?, index: Int)? {
        if let parent = bookmark.parent {
            guard let index = parent.children.firstIndex(where: { $0.guid == bookmark.guid }) else {
                return nil
            }
            return (parent, index)
        }

        guard let index = bookmarkSectionController.bookmarkItems.firstIndex(where: { item in
            (item as? Bookmark)?.guid == bookmark.guid
        }) else {
            return nil
        }
        return (nil, index)
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
            clearDropFeedback()
            return
        }
        setDropFeedback(.bookmarkFolder(guid: folder.guid))
    }

    private func setDropFeedback(_ target: DropFeedbackTarget) {
        guard dropFeedbackTarget != target else { return }
        let previous = dropFeedbackTarget
        dropFeedbackTarget = target
        applyDropFeedback(previous, highlighted: false)
        applyDropFeedback(target, highlighted: true)
    }

    private func clearDropFeedback() {
        setDropFeedback(.none)
    }

    private func temporarilyCollapseGroupForDragIfNeeded(
        groupItem: TabGroupSidebarItem,
        cell: TabGroupCellView?
    ) {
        let token = groupItem.group.token
        guard !groupItem.group.isCollapsed else { return }

        if let activeToken = temporarilyCollapsedGroupTokenForDrag,
           activeToken != token {
            restoreTemporarilyCollapsedGroupAfterDragIfNeeded()
        }

        guard temporarilyCollapsedGroupTokenForDrag != token else { return }
        temporarilyCollapsedGroupTokenForDrag = token
        let targetCell = cell ?? visibleTabGroupCell(for: token)
        targetCell?.setTemporarilyCollapsedForDrag(true)
        noteTabGroupRowHeightChanged(for: groupItem, animated: false)
        AppLogDebug(
            "[TAB_GROUPS][GROUP_DRAG] temporarilyCollapse token=\(token)"
        )
    }

    private func restoreTemporarilyCollapsedGroupAfterDragIfNeeded() {
        guard let token = temporarilyCollapsedGroupTokenForDrag else { return }
        temporarilyCollapsedGroupTokenForDrag = nil

        guard let groupItem = tabGroupItem(for: token) else {
            AppLogDebug(
                "[TAB_GROUPS][GROUP_DRAG] restoreTemporaryCollapse skipped missing token=\(token)"
            )
            return
        }

        visibleTabGroupCell(for: token)?.setTemporarilyCollapsedForDrag(false)
        noteTabGroupRowHeightChanged(for: groupItem, animated: false)
        AppLogDebug(
            "[TAB_GROUPS][GROUP_DRAG] restoreTemporaryCollapse token=\(token)"
        )
    }

    private func beginWholeGroupSidebarDragSessionRecording(_ session: NSDraggingSession) {
        removeWholeGroupSidebarEscMonitorIfNeeded()
        wholeGroupSidebarEscSuppressedTearOff = false
        wholeGroupSidebarEndFinalizeDone = false
        activeWholeGroupSidebarDragSession = ObjectIdentifier(session)
        wholeGroupSidebarEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            self.wholeGroupSidebarEscSuppressedTearOff = true
            AppLogDebug(
                "[TAB_GROUPS][GROUP_DRAG] Esc → suppress whole-group sidebar tear-off"
            )
            return nil
        }
    }

    private func removeWholeGroupSidebarEscMonitorIfNeeded() {
        if let monitor = wholeGroupSidebarEscMonitor {
            NSEvent.removeMonitor(monitor)
            wholeGroupSidebarEscMonitor = nil
        }
        activeWholeGroupSidebarDragSession = nil
    }

    /// Runs before `tabDraggingSession.end(...)`. Uses the same coarse
    /// boundary rubric as `TabDraggingSession.shouldUsePageSnapshotPreview`:
    /// drop with no recipient **and** cursor not inside any Phi
    /// `containsTabDragBoundary` region ⇒ tear-off to new window
    /// (`BrowserState.moveGroupSliceToNewWindow`).
    private func finalizeWholeGroupSidebarTearOffIfNeeded(
        session: NSDraggingSession,
        screenPoint: NSPoint,
        dragOperation: NSDragOperation
    ) {
        guard activeWholeGroupSidebarDragSession == ObjectIdentifier(session) else {
            return
        }
        guard !wholeGroupSidebarEndFinalizeDone else { return }
        wholeGroupSidebarEndFinalizeDone = true

        defer {
            removeWholeGroupSidebarEscMonitorIfNeeded()
        }

        guard dragOperation.isEmpty else { return }
        guard !wholeGroupSidebarEscSuppressedTearOff else { return }
        guard let groupItem =
            browserState.tabDraggingSession.snapshot.draggingItem as? TabGroupSidebarItem
        else { return }

        let pt = CGPoint(x: screenPoint.x, y: screenPoint.y)
        let overPhiTabChrome = MainBrowserWindowControllersManager.shared.getAllWindows()
            .contains { $0.containsTabDragBoundary(at: pt) }
        guard !overPhiTabChrome else { return }

        let token = groupItem.group.token
        let memberIds = browserState.normalTabs
            .filter { $0.groupToken == token }
            .map(\.guid)
        guard !memberIds.isEmpty else { return }

        session.animatesToStartingPositionsOnCancelOrFail = false

        AppLogDebug(
            "[TAB_GROUPS][GROUP_DRAG] sidebar tear-off moveGroupSliceToNewWindow " +
            "windowId=\(browserState.windowId) token=\(token) members=\(memberIds)"
        )
        browserState.moveGroupSliceToNewWindow(
            memberIds: memberIds,
            dropScreenLocation: pt
        )
    }

    private func tabGroupItem(for token: String) -> TabGroupSidebarItem? {
        tabSectionController.tabItems
            .compactMap { $0 as? TabGroupSidebarItem }
            .first { $0.group.token == token }
    }

    private func visibleTabGroupCell(for token: String) -> TabGroupCellView? {
        guard let groupItem = tabGroupItem(for: token) else { return nil }
        let row = outlineView.row(forItem: groupItem)
        guard row >= 0 else { return nil }
        return outlineView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: false
        ) as? TabGroupCellView
    }

    private func updateVisibleGroupOverviewSelection() {
        let selectedToken = browserState.activeGroupOverviewToken
        for row in 0..<outlineView.numberOfRows {
            let view = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            )
            if let groupCell = view as? TabGroupCellView {
                groupCell.setOverviewSelected(!groupCell.token.isEmpty && groupCell.token == selectedToken)
            } else if let tabCell = view as? SidebarTabCellView {
                tabCell.setActiveSuppressed(selectedToken != nil)
            }
        }
    }

    private func noteTabGroupRowHeightChanged(for groupItem: TabGroupSidebarItem,
                                              animated: Bool) {
        let row = outlineView.row(forItem: groupItem)
        guard row >= 0 else { return }
        let updates = {
            self.outlineView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integer: row))
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                updates()
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                updates()
            }
        }
        outlineView.layoutSubtreeIfNeeded()
    }

    private func applyDropFeedback(_ target: DropFeedbackTarget, highlighted: Bool) {
        switch target {
        case .none:
            return
        case .bookmarkFolder(let guid):
            updateFolderDropFeedbackCell(guid: guid, highlighted: highlighted)
        case .tabGroup(let token):
            updateTabGroupDropFeedbackCell(token: token, highlighted: highlighted)
        }
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

    private func updateTabGroupDropFeedbackCell(token: String, highlighted: Bool) {
        guard let groupWrapper = tabSectionController.tabItems
                .compactMap({ $0 as? TabGroupSidebarItem })
                .first(where: { $0.group.token == token })
        else { return }
        let row = outlineView.row(forItem: groupWrapper)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                          as? TabGroupCellView
        else { return }
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
            guard parent.isExpandable else { return [] }
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

    /// If `pinnedGuid` identifies one pane of a pinned split, return both
    /// panes' URLs. Used to open the pair as a fresh split in another window
    /// without disturbing the source's pinned record or live tabs.
    private func pinnedSplitURLs(in state: BrowserState, pinnedGuid: String) -> (primary: String, secondary: String)? {
        guard let pinnedTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }),
              let partnerGuid = pinnedTab.splitPartnerGuid, !partnerGuid.isEmpty,
              let partner = state.pinnedTabs.first(where: { $0.guidInLocalDB == partnerGuid }),
              let primaryURL = pinnedTab.url, !primaryURL.isEmpty,
              let secondaryURL = partner.url, !secondaryURL.isEmpty else {
            return nil
        }
        return (primaryURL, secondaryURL)
    }
    
    private func moveTabToTargetWindow(_ tab: Tab, destinationIndex: Int, scheduleNormalInsertion: Bool) -> Bool {
        guard let wrapper = tab.webContentWrapper else { return false }
        let targetState = browserState
        // Split-aware: when the dragged tab belongs to a split, the Chromium
        // bridge re-creates the pair atomically at the requested index. Skip
        // the local schedule + tail-insert dance — its post-arrival per-tab
        // moveTab callback would yank the dragged half out of the new split
        // and break the pair.
        if tabIsInSplitInAnyWindow(tab) {
            let clampedIndex = max(0, min(destinationIndex, targetState.tabs.count))
            wrapper.moveSplit(toWindow: targetState.windowId.int64Value, at: clampedIndex)
            return true
        }
        if scheduleNormalInsertion {
            targetState.scheduleNormalTabInsertion(tabGuid: tab.guid, at: destinationIndex)
        }
        let insertIndex = max(0, targetState.tabs.count)
        wrapper.moveSplit(toWindow: targetState.windowId.int64Value, at: insertIndex)
        return true
    }

    private func tabIsInSplitInAnyWindow(_ tab: Tab) -> Bool {
        MainBrowserWindowControllersManager.shared.getAllWindows().contains {
            $0.browserState.splitGroup(forTabId: tab.guid) != nil
        }
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
        case .tab, .newTabButton, .separator, .tabGroup:
            return InsetTableRowView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        case .splitPair:
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
            bookmarkCell?.browserState = browserState
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
            newTabCell?.cleanupAction = farringdonCleanupActionIfVisible()
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
            let identifier = NSUserInterfaceItemIdentifier("TabGroupCell")
            let groupCell: TabGroupCellView
            if let existing = outlineView.makeView(
                withIdentifier: identifier, owner: self) as? TabGroupCellView {
                groupCell = existing
            } else {
                groupCell = TabGroupCellView()
                groupCell.identifier = identifier
            }
            groupCell.groupCellDelegate = self
            cellView = groupCell

        case .splitPair:
            let identifier = NSUserInterfaceItemIdentifier("SplitPairCell")
            let splitCell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarSplitPairCellView ?? {
                let c = SidebarSplitPairCellView()
                c.identifier = identifier
                return c
            }()
            splitCell.owner = self
            splitCell.browserState = browserState
            cellView = splitCell

        }
        
        cellView.isHidden = false
        cellView.configure(with: sidebarItem)
        if sidebarItem.itemType == .newTabButton {
            updateOriginalNewTabCellVisibility(cellView)
        }
        if let tabCell = cellView as? SidebarTabCellView {
            tabCell.setActiveSuppressed(browserState.groupOverviewState != nil)
        }
        if let bookmarkCell = cellView as? BookmarkCellView,
           let bookmark = sidebarItem as? Bookmark {
            bookmarkCell.setDropTargetHighlighted(bookmark.isFolder && dropFeedbackTarget == .bookmarkFolder(guid: bookmark.guid))
        }
        if let groupCell = cellView as? TabGroupCellView,
           let groupItem = sidebarItem as? TabGroupSidebarItem {
            groupCell.setTemporarilyCollapsedForDrag(
                temporarilyCollapsedGroupTokenForDrag == groupItem.group.token)
            groupCell.setDropTargetHighlighted(
                dropFeedbackTarget == .tabGroup(token: groupItem.group.token))
            groupCell.setOverviewSelected(
                browserState.isShowingGroupOverview(for: groupItem.group.token))
        }
        return cellView
    }
    
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let sidebarItem = item as? SidebarItem else { return 32.0 }
        
        switch sidebarItem.itemType {
        case .separator:
            return 16.0 // Smaller height for separator
        case .tabGroup:
            guard let groupItem = sidebarItem as? TabGroupSidebarItem else { return 36.0 }
            if temporarilyCollapsedGroupTokenForDrag == groupItem.group.token {
                return TabGroupCellView.collapsedRowHeight
            }
            return TabGroupCellView.desiredHeight(
                for: groupItem, browserState: browserState)
        default:
            return 36.0
        }
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        // Tab-group collapse is now driven by the SwiftUI chevron inside
        // `TabGroupCellView`; the outer outline no longer expands or
        // collapses tab-group rows (they are leaves with dynamic height).
        // Bookmark folders, etc. retain their default behavior.
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if browserState.isDraggingTab && !allowExpandDuringDrag {
            // Phase 3: TabGroupSidebarItem is allowed to spring-load
            // during drag so users can dive into a folded group's
            // children for precise placement; other rows still keep
            // the original "no expand during drag" guard.
            if !(item is TabGroupSidebarItem) {
                return false
            }
        }
        return (item as? SidebarItem)?.isExpandable ?? false
    }

    private func requestTabGroupCollapseChange(group: WebContentGroupInfo,
                                                collapsed: Bool) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug(
                "[TAB_GROUPS] setCollapsed: no bridge windowId=\(browserState.windowId) " +
                "token=\(group.token)"
            )
            return
        }
        AppLogDebug(
            "[TAB_GROUPS] setCollapsed→bridge windowId=\(browserState.windowId) " +
            "token=\(group.token) collapsed=\(collapsed)"
        )
        bridge.updateTabGroupCollapsed(withWindowId: Int64(browserState.windowId),
                                       tokenHex: group.token,
                                       isCollapsed: collapsed)
    }

    private func requestTabGroupClose(group: WebContentGroupInfo) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug(
                "[TAB_GROUPS] closeGroup: no bridge windowId=\(browserState.windowId) " +
                "token=\(group.token)"
            )
            return
        }
        AppLogDebug(
            "[TAB_GROUPS] closeGroup→bridge windowId=\(browserState.windowId) " +
            "token=\(group.token)"
        )
        bridge.closeGroup(withWindowId: Int64(browserState.windowId),
                          tokenHex: group.token)
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
            self.updateFloatingNewTabVisibility()
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
            self.updateFloatingNewTabVisibility()
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
                        syncDiffableSnapshotToCurrentDataSource()
                    } else {
                        focusedBookmarkPresentation = desired
                        outlineView.beginUpdates()
                        outlineView.insertItems(at: IndexSet(integer: desired.insertionIndex), inParent: desired.insertionParent, withAnimation: [.effectFade, .effectGap])
                        outlineView.endUpdates()
                        syncDiffableSnapshotToCurrentDataSource()
                    }
                } else {
                    focusedBookmarkPresentation = desired
                    outlineView.beginUpdates()
                    outlineView.insertItems(at: IndexSet(integer: desired.insertionIndex), inParent: desired.insertionParent, withAnimation: [.effectFade, .effectGap])
                    outlineView.endUpdates()
                    syncDiffableSnapshotToCurrentDataSource()
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

    private func triggerFarringdonCleanup() {
        FarringdonOrganizer.organizeFocusedWindow()
    }

    /// The broom (organize-tabs) action is only useful once the window has
    /// enough eligible tabs to organize.
    private func farringdonCleanupActionIfVisible() -> (() -> Void)? {
        guard FarringdonOrganizer.canOrganizeTabs(in: browserState) else { return nil }
        return { [weak self] in self?.triggerFarringdonCleanup() }
    }

    /// Reflects cleanup-button eligibility changes onto live New Tab cells without a reload.
    private func updateNewTabCleanupVisibility() {
        let action = farringdonCleanupActionIfVisible()
        if let item = newTabButtonItem {
            let row = outlineView.row(forItem: item)
            if row >= 0,
               let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                   as? NewTabButtonCellView {
                cell.cleanupAction = action
            }
        }
        floatingNewTabView?.cellView.cleanupAction = action
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

    /// Convenience: root-child index where the tab section begins, given
    /// the current visible state. All three drop-redirect call sites need
    /// this in root-child space (the same coordinate `setDropItem(_:dropChildIndex:)`
    /// expects), so they share one helper instead of recomputing inline.
    private func currentTabSectionStart() -> Int {
        guard showBookmarks else { return 0 }
        let bookmarkCount = bookmarkSectionController.bookmarkItems.count
        let separatorCount = (!bookmarkSectionController.bookmarkItems.isEmpty && !tabSectionController.tabItems.isEmpty) ? 1 : 0
        return tabSectionStartIndexInRootChildren(
            bookmarkCount: bookmarkCount,
            separatorCount: separatorCount)
    }
    
    func tabSectionDidUpdate(with change: TabSectionChange) {
        guard isActive else { return }
        refreshAllItems { [weak self] in
            guard let self else { return }
            self.pushMemberUpdatesToGroupCells(change.affectedGroupTokens)
            self.pushPaneUpdatesToSplitPairCells(change.affectedSplitIds)
            self.updateNewTabCleanupVisibility()
            self.clearFloatingProxyIfTabClosed()
        }
    }

    /// Push fresh member arrays into the affected `TabGroupCellView`
    /// instances so each cell's diffable inner table animates its row
    /// changes and notifies the outline of any height delta. Cells
    /// that aren't realized (off-screen, just-inserted root row) are
    /// skipped — they pull their initial members from `configure(with:)`.
    private func pushMemberUpdatesToGroupCells(_ tokens: Set<String>) {
        guard !tokens.isEmpty else { return }
        for case let groupItem as TabGroupSidebarItem in allItems
            where tokens.contains(groupItem.group.token) {
            let row = outlineView.row(forItem: groupItem)
            guard row >= 0,
                  let cell = outlineView.view(atColumn: 0,
                                              row: row,
                                              makeIfNecessary: false)
                            as? TabGroupCellView
            else { continue }
            let newMembers = browserState.normalTabs.filter {
                $0.groupToken == groupItem.group.token
            }
            cell.applyMembers(newMembers, animated: true)
        }
    }

    /// Split-pair analog of `pushMemberUpdatesToGroupCells`: a pane replace
    /// mutates the cached `SplitPairSidebarItem` in place and the row id
    /// survives, so the outline diff never reloads the merged cell. Re-bind
    /// the affected cells so their titles/favicons/subscriptions attach to
    /// the new pane's Tab.
    private func pushPaneUpdatesToSplitPairCells(_ splitIds: Set<String>) {
        guard !splitIds.isEmpty else { return }
        for case let pairItem as SplitPairSidebarItem in allItems
            where splitIds.contains(pairItem.groupId) {
            let row = outlineView.row(forItem: pairItem)
            guard row >= 0,
                  let cell = outlineView.view(atColumn: 0,
                                              row: row,
                                              makeIfNecessary: false)
                            as? SidebarSplitPairCellView
            else { continue }
            cell.rebindPanesIfNeeded()
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
            syncDiffableSnapshotToCurrentDataSource()
            return
        }
        if old == nil, new == nil {
            syncDiffableSnapshotToCurrentDataSource()
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
        syncDiffableSnapshotToCurrentDataSource()
    }
    private func nextFloatingBookmarkPresentationState(rootItems: [SidebarItem]) -> FloatingBookmarkPresentationState {
        guard let bookmarkGuid = floatingBookmarkGuid,
              let bookmark = browserState.bookmarkManager.bookmark(withGuid: bookmarkGuid) else {
            return .cleared
        }
        
        var parents: [Bookmark] = []
        var current = bookmark.parent
        while let p = current {
            parents.insert(p, at: 0)
            current = p.parent
        }
        
        guard let firstCollapsed = parents.first(where: { $0.isFolder && !outlineView.isItemExpanded($0) }) else {
            return .cleared
        }
        
        guard let expected = expectedProxyInsertionAfterCollapsedFolder(firstCollapsed, rootItems: rootItems) else {
            return .cleared
        }
        
        let indentationLevel = max(0, firstCollapsed.depth) + 1
        let proxy = FocusedBookmarkSidebarItem(bookmark: bookmark, indentationLevelOverride: indentationLevel)
        return FloatingBookmarkPresentationState(
            focusedPresentation: (
                proxy: proxy,
                insertionParent: expected.insertionParent,
                insertionIndex: expected.insertionIndex
            ),
            floatingBookmarkGuid: bookmarkGuid,
            floatingAnchorFolderGuid: firstCollapsed.guid
        )
    }

    private func rebuildFloatingBookmarkPresentationIfNeeded() {
        let state = nextFloatingBookmarkPresentationState(rootItems: allItems)
        focusedBookmarkPresentation = state.focusedPresentation
        floatingBookmarkGuid = state.floatingBookmarkGuid
        floatingAnchorFolderGuid = state.floatingAnchorFolderGuid
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
    private func expectedProxyInsertionAfterCollapsedFolder(
        _ folder: Bookmark,
        rootItems: [SidebarItem]? = nil
    ) -> (insertionParent: SidebarItem?, insertionIndex: Int)? {
        if let parent = folder.parent {
            let siblings = visibleChildren(for: parent)
            let idx = siblings.firstIndex(where: { $0.id == folder.id }) ?? siblings.count
            return (insertionParent: parent, insertionIndex: min(idx + 1, siblings.count))
        } else {
            let effectiveRootItems = rootItems ?? allItems
            let idx = effectiveRootItems.firstIndex(where: { $0.id == folder.id }) ?? 0
            return (insertionParent: nil, insertionIndex: min(idx + 1, effectiveRootItems.count))
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
            syncDiffableSnapshotToCurrentDataSource()
            applyFocusingSelection(for: tab)
            updateVisibleBookmarkTabs()
            return
        }
        if old == nil, new == nil {
            syncDiffableSnapshotToCurrentDataSource()
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
        syncDiffableSnapshotToCurrentDataSource()
        
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
        syncDiffableSnapshotToCurrentDataSource()

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

    private var newTabButtonItem: SidebarItem? {
        tabSectionController.tabItems.first { $0.itemType == .newTabButton }
    }

    private func updateFloatingNewTabVisibility() {
        guard isViewLoaded, isActive, !suppressesFloatingNewTabDuringDrag, let item = newTabButtonItem else {
            removeFloatingNewTabCell()
            outlineView.dragAutoscrollTopObstructionHeight = 0
            return
        }

        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            removeFloatingNewTabCell()
            outlineView.dragAutoscrollTopObstructionHeight = 0
            return
        }

        let rowRect = outlineView.rect(ofRow: row)
        let visibleRect = scrollView.contentView.documentVisibleRect
        let shouldShow = SidebarNewTabStickyResolver.shouldShowFloatingNewTab(
            rowRect: rowRect,
            visibleRect: visibleRect
        )

        if shouldShow {
            showFloatingNewTabCell(for: item, rowRect: rowRect)
        } else {
            removeFloatingNewTabCell()
        }

        outlineView.dragAutoscrollTopObstructionHeight = shouldShow ? rowRect.height : 0
        setOriginalNewTabCellHidden(shouldShow)
    }

    private func showFloatingNewTabCell(for item: SidebarItem, rowRect: NSRect) {
        let floatingView = floatingNewTabView ?? makeFloatingNewTabView(for: item)
        floatingNewTabView = floatingView

        if floatingView.superview == nil {
            scrollView.addFloatingSubview(floatingView, for: .vertical)
        }

        layoutFloatingNewTabView(floatingView, rowHeight: rowRect.height)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeFloatingNewTabView(for item: SidebarItem) -> FloatingNewTabView {
        let floatingView = FloatingNewTabView(frame: .zero)
        floatingView.cellView.configure(with: item)
        floatingView.cellView.clickAction = { [weak self] in
            self?.browserState.windowController?.newBrowserTab(nil)
        }
        floatingView.cellView.cleanupAction = farringdonCleanupActionIfVisible()
        floatingView.hoverStateChanged = { [weak self] hovering in
            self?.setVisibleTabHoverSuppressed(hovering)
        }
        return floatingView
    }

    private func layoutFloatingNewTabView(_ floatingView: FloatingNewTabView, rowHeight: CGFloat) {
        let size = scrollView.contentSize
        let height = max(0, rowHeight)
        let y: CGFloat
        if let superview = floatingView.superview, !superview.isFlipped {
            y = max(0, size.height - height)
        } else {
            y = 0
        }

        floatingView.frame = NSRect(x: 0, y: y, width: size.width, height: height)
    }

    private func removeFloatingNewTabCell() {
        guard floatingNewTabView != nil else { return }
        setVisibleTabHoverSuppressed(false)
        floatingNewTabView?.removeFromSuperview()
        floatingNewTabView = nil
        setOriginalNewTabCellHidden(false)
    }

    private func beginOutlineDestinationDrag() {
        guard suppressesFloatingNewTabDuringDrag == false else { return }
        suppressesFloatingNewTabDuringDrag = true
        removeFloatingNewTabCell()
        outlineView.dragAutoscrollTopObstructionHeight = 0
    }

    private func endOutlineDestinationDrag() {
        guard suppressesFloatingNewTabDuringDrag else { return }
        suppressesFloatingNewTabDuringDrag = false
        updateFloatingNewTabVisibility()
    }

    private func updateOriginalNewTabCellVisibility(_ cell: NSView) {
        cell.isHidden = floatingNewTabView?.superview != nil
    }

    private func setOriginalNewTabCellHidden(_ hidden: Bool) {
        guard let item = newTabButtonItem else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else {
            return
        }
        cell.isHidden = hidden
    }

    private var floatingNewTabTopOverlayHeight: CGFloat {
        guard floatingNewTabView?.superview != nil else { return 0 }
        if let height = floatingNewTabView?.bounds.height, height > 0 {
            return height
        }
        guard let item = newTabButtonItem else { return 0 }
        let row = outlineView.row(forItem: item)
        return row >= 0 ? outlineView.rect(ofRow: row).height : 0
    }

    private func setVisibleTabHoverSuppressed(_ suppressed: Bool) {
        for row in 0..<outlineView.numberOfRows {
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTabCellView else {
                continue
            }
            cell.setHoverSuppressed(suppressed)
            if !suppressed {
                cell.setHovered(false)
            }
        }

        if !suppressed {
            updateVisibleTabHoverForCurrentMouseLocation()
        }
    }

    private func updateVisibleTabHoverForCurrentMouseLocation() {
        guard let window = view.window else { return }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let outlinePoint = outlineView.convert(windowPoint, from: nil)
        let row = outlineView.row(at: outlinePoint)
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? SidebarItem,
              item.itemType == .tab,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTabCellView else {
            return
        }

        cell.setHovered(true)
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
        let topOverlayHeight = floatingNewTabTopOverlayHeight
        let unobscuredVisibleRect = SidebarNewTabStickyResolver.visibleRectExcludingTopOverlay(
            visibleRect: visibleRect,
            overlayHeight: topOverlayHeight
        )

        var targetY = visibleRect.origin.y
        if rowRect.minY < unobscuredVisibleRect.minY {
            targetY = rowRect.minY - topOverlayHeight
        } else if rowRect.maxY > unobscuredVisibleRect.maxY {
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
            clearFocusingSelection()
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

        // Grouped tabs render inside `TabGroupCellView`'s inner table —
        // no outline child to select. If the focusing tab belongs to a
        // visible group, scroll the group's row into view so the user
        // sees the active tab inside the cell, but skip outline
        // selection (the inner table drives its own active highlight
        // via SwiftUI).
        for case let groupItem as TabGroupSidebarItem in allItems
        where browserState.normalTabs.contains(where: {
            $0.guid == tab.guid && $0.groupToken == groupItem.group.token
        }) {
            if shouldScroll {
                lastScrolledFocusingTabId = tab.id
                scheduleScrollToVisible(forItem: groupItem)
            }
            selectItem(nil)
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
                clearFocusingSelection()
            }
            return
        }
        
        guard let localGuid = tab.guidInLocalDB,
              let bookmark = browserState.bookmarkManager.bookmark(withGuid: localGuid) else {
            clearFocusingSelection()
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
            clearFocusingSelection()
        }
    }
}

// MARK: - right click menu
extension SidebarTabListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.contextMenu else {
            return
        }
        
        guard let clickedRow = outlineView.rightClickedRow else {
            defultMenu(on: menu)
            return
        }

        let menuTarget: ContextMenuRepresentable? = {
            if let groupItem = outlineView.item(atRow: clickedRow) as? TabGroupSidebarItem,
               let location = outlineView.rightClickedLocation,
               let cell = outlineView.view(
                atColumn: 0,
                row: clickedRow,
                makeIfNecessary: false) as? TabGroupCellView {
                let pointInCell = cell.convert(location, from: outlineView)
                return cell.contextMenuTarget(at: pointInCell) ?? groupItem
            }
            return outlineView.item(atRow: clickedRow) as? ContextMenuRepresentable
        }()

        guard let item = menuTarget else {
            defultMenu(on: menu)
            return
        }

        if item is Tab, TabMultiSelectionMenu.populateIfNeeded(menu, browserState: browserState) {
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

// MARK: - TabGroupCellViewDelegate

extension SidebarTabListViewController: TabGroupCellViewDelegate {
    func tabGroupCellNeedsHeightUpdate(_ cell: TabGroupCellView, for token: String) {
        guard let item = cell.item else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    func tabGroupCellDidToggleCollapse(_ cell: TabGroupCellView,
                                       group: WebContentGroupInfo) {
        // Idempotent gestures (already in the requested state) are
        // unreachable here because the chevron always toggles. Just
        // dispatch the inverse to the bridge; Chromium's
        // kVisualsChanged echo updates `group.isCollapsed`, which the
        // cell already subscribes to.
        requestTabGroupCollapseChange(group: group, collapsed: !group.isCollapsed)
    }

    func tabGroupCellDidRequestCloseGroup(_ cell: TabGroupCellView,
                                          group: WebContentGroupInfo) {
        requestTabGroupClose(group: group)
    }

    func tabGroupCellDidRequestOverview(_ cell: TabGroupCellView,
                                        group: WebContentGroupInfo) {
        browserState.showGroupOverview(token: group.token)
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      beginDraggingGroup group: WebContentGroupInfo,
                      from headerView: NSView,
                      mouseDownEvent: NSEvent) {
        AppLogDebug(
            "[TAB_GROUPS][GROUP_DRAG] controller.beginDraggingGroup " +
            "token=\(group.token) eventWindowPoint=\(mouseDownEvent.locationInWindow)"
        )
        guard let groupItem = cell.item as? TabGroupSidebarItem else {
            return
        }
        temporarilyCollapseGroupForDragIfNeeded(groupItem: groupItem, cell: cell)

        let isCollapsedForDrag = group.isCollapsed
            || temporarilyCollapsedGroupTokenForDrag == group.token
        let draggingView: NSView = isCollapsedForDrag ? headerView : cell
        guard let image = draggingView.createDraggingSnapshot() else {
            restoreTemporarilyCollapsedGroupAfterDragIfNeeded()
            return
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(group.token, forType: .tabGroup)
        pasteboardItem.setString(String(browserState.windowId), forType: .sourceWindowId)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let frame = outlineView.convert(draggingView.bounds, from: draggingView)
        draggingItem.setDraggingFrame(frame, contents: image)

        let session = outlineView.beginDraggingSession(
            with: [draggingItem],
            event: mouseDownEvent,
            source: self)
        beginWholeGroupSidebarDragSessionRecording(session)

        let screenPoint = mouseDownEvent.window?
            .convertPoint(toScreen: mouseDownEvent.locationInWindow) ?? NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            self?.expandFloatingBookmarkParentsIfNeeded()
            self?.browserState.isDraggingTab = true
        }
        browserState.tabDraggingSession.attachNativeSession(session)
        browserState.tabDraggingSession.begin(
            draggingItem: groupItem,
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            containerView: hostVC?.view
        )
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      tabDidRequestClose tab: Tab) {
        tabSectionController.closeTab(tab)
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      beginDragging tab: Tab,
                      from rowView: SidebarCellView,
                      mouseDownEvent: NSEvent) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] controller.beginDragging tab=\(tab.guid) " +
            "token=\(tab.groupToken ?? "nil") eventWindowPoint=\(mouseDownEvent.locationInWindow)"
        )
        let multiDragIds = browserState.multiSelectionDragTabIds(startingFrom: tab)
        if browserState.multiSelection.isActive, multiDragIds == nil {
            browserState.clearMultiSelection()
        }
        guard let image = rowView.createDraggingImage() else { return }
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] controller.dragImage size=\(image.size) " +
            "rowBounds=\(rowView.bounds)"
        )

        let pasteboardItem = NSPasteboardItem()
        configureNormalTabDragPayload(pasteboardItem, startingFrom: tab)
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] controller.pasteboard " +
            "types=\(pasteboardItem.types.map(\.rawValue)) windowId=\(browserState.windowId)"
        )

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let frame = outlineView.convert(rowView.bounds, from: rowView)
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] controller.dragFrameInOutline=\(frame)")
        draggingItem.setDraggingFrame(frame, contents: image)

        let session = outlineView.beginDraggingSession(
            with: [draggingItem],
            event: mouseDownEvent,
            source: self)
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] controller.beginDraggingSession session=\(session)")

        let screenPoint = mouseDownEvent.window?
            .convertPoint(toScreen: mouseDownEvent.locationInWindow) ?? NSEvent.mouseLocation
        tabGroupCell(cell,
                     draggingSessionWillBegin: session,
                     at: screenPoint,
                     for: tab)
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      draggingSessionWillBegin session: NSDraggingSession,
                      at screenPoint: NSPoint,
                      for tab: Tab) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] controller.willBegin session=\(session) " +
            "screen=\(screenPoint) tab=\(tab.guid)"
        )
        DispatchQueue.main.async { [weak self] in
            self?.expandFloatingBookmarkParentsIfNeeded()
            self?.browserState.isDraggingTab = true
        }
        browserState.tabDraggingSession.attachNativeSession(session)
        browserState.tabDraggingSession.begin(
            draggingItem: tab,
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            containerView: hostVC?.view
        )
        _ = applyMultiSelectionDragImageIfNeeded(
            session: session,
            startingFrom: tab,
            sourceImage: nil,
            sourceGroupCell: cell,
            browserState: browserState,
            outlineView: outlineView
        )
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      draggingSessionEnded session: NSDraggingSession,
                      at screenPoint: NSPoint,
                      operation: NSDragOperation) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] controller.innerEnded session=\(session) " +
            "screen=\(screenPoint) op=\(operation.rawValue)"
        )
        clearDropFeedback()
        clearVisibleGroupInnerDropRows()
        restoreTemporarilyCollapsedGroupAfterDragIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.browserState.isDraggingTab = false
        }
        browserState.tabDraggingSession.end(
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            dragOperation: operation
        )
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      didUpdateDropTargetHighlight highlighted: Bool,
                      for group: WebContentGroupInfo) {
        if highlighted {
            setDropFeedback(.tabGroup(token: group.token))
        } else if dropFeedbackTarget == .tabGroup(token: group.token) {
            setDropFeedback(.none)
        }
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptTab tab: Tab,
                      intoGroupToken token: String,
                      atNormalTabsIdx targetIdx: Int) -> Bool {
        let oldToken = tab.groupToken
        let oldIdx = browserState.normalTabs.firstIndex(of: tab)

        // Splits travel as a unit. When the dragged tab is part of a
        // non-pinned split, the partner pane joins the group with it so
        // both panes share the same group token and stay adjacent — the
        // merged in-group split row only renders when that invariant
        // holds.
        let splitPartner: Tab? = {
            guard let group = browserState.splitGroup(forTabId: tab.guid),
                  !group.isPinned,
                  let partnerId = group.partnerTabId(of: tab.guid) else {
                return nil
            }
            return browserState.tabs.first(where: { $0.guid == partnerId })
        }()

        let membershipWillChange = oldToken != token
        let shouldDeferChromiumOrderSync =
            membershipWillChange && splitPartner == nil
        if let oldIdx, oldIdx != targetIdx {
            browserState.moveNormalTabLocally(
                from: oldIdx,
                to: targetIdx,
                syncChromiumOrder: !shouldDeferChromiumOrderSync)
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            return true
        }
        let memberTabIds: [Int] = {
            var ids: [Int] = [tab.guid]
            if let partner = splitPartner {
                ids.append(partner.guid)
            }
            return ids
        }()
        let memberIds = memberTabIds.map { NSNumber(value: Int64($0)) }
        if let old = oldToken, membershipWillChange {
            AppLogDebug(
                "[TAB_GROUPS][SIDEBAR_DRAG] removeTabsFromGroup " +
                "windowId=\(browserState.windowId) tabIds=\(memberIds) " +
                "token=\(old)"
            )
            bridge.removeTabsFromGroup(
                withWindowId: Int64(browserState.windowId),
                tabIds: memberIds)
        }
        if membershipWillChange {
            AppLogDebug(
                "[TAB_GROUPS][SIDEBAR_DRAG] addTabsToGroup " +
                "windowId=\(browserState.windowId) tabIds=\(memberIds) " +
                "token=\(token)"
            )
            bridge.addTabsToGroup(
                withWindowId: Int64(browserState.windowId),
                tabIds: memberIds,
                tokenHex: token)
        }
        // See sibling site (~Line 1057) for rationale: mirror group
        // membership locally so a layout-switch race can't observe the
        // transient split.
        if membershipWillChange {
            var updates: [(tabId: Int, newToken: String?)] =
                [(tab.guid, token)]
            if let partner = splitPartner {
                updates.append((partner.guid, token))
            }
            browserState.applyOptimisticGroupMembership(
                updates: updates)
            if shouldDeferChromiumOrderSync {
                browserState.syncNormalTabsRelativeOrderToChromium(
                    tabIds: memberTabIds)
            }
        }
        setDropFeedback(.none)
        return true
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptTabsWithGuids tabIds: [Int],
                      intoGroupToken token: String,
                      atNormalTabsIdx normalTabsIdx: Int) -> Bool {
        commitNormalTabBatchDrop(tabIds: tabIds,
                                 to: normalTabsIdx,
                                 targetGroupToken: token)
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      canAcceptBookmarkWithGuid guid: String) -> Bool {
        guard let bookmark = findBookmark(withId: guid) else {
            return false
        }
        return canMoveBookmarkToGroup(bookmark)
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      canAcceptPinnedTabWithGuid pinnedGuid: String) -> Bool {
        canMovePinnedTabToGroup(pinnedGuid: pinnedGuid)
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptPinnedTabWithGuid pinnedGuid: String,
                      intoGroupToken token: String,
                      atNormalTabsIdx normalTabsIdx: Int,
                      groupIndex: Int) -> Bool {
        guard canMovePinnedTabToGroup(pinnedGuid: pinnedGuid) else {
            setDropFeedback(.none)
            return false
        }
        let accepted = browserState.movePinnedTabOut(
            pinnedGuid: pinnedGuid,
            toGroup: token,
            groupIndex: groupIndex,
            normalTabsIndex: normalTabsIdx,
            focusAfterCreate: false
        )
        setDropFeedback(.none)
        return accepted
    }

    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptBookmarkWithGuid bookmarkGuid: String,
                      intoGroupToken token: String,
                      atNormalTabsIdx normalTabsIdx: Int,
                      groupIndex: Int) -> Bool {
        guard let bookmark = findBookmark(withId: bookmarkGuid),
              canMoveBookmarkToGroup(bookmark) else {
            setDropFeedback(.none)
            return false
        }
        let accepted = browserState.moveBookmarkOut(
            bookmark,
            toGroup: token,
            groupIndex: groupIndex,
            normalTabsIndex: normalTabsIdx,
            focusAfterCreate: false
        )
        setDropFeedback(.none)
        return accepted
    }
}

// MARK: - Middle Click to Close Tab
extension SidebarTabListViewController: SideBarOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, draggingEntered sender: any NSDraggingInfo) {
        beginOutlineDestinationDrag()
        expandFloatingBookmarkParentsIfNeeded()
    }

    func outlineView(_ outlineView: NSOutlineView, draggingExited sender: (any NSDraggingInfo)?) {
        endOutlineDestinationDrag()
    }

    func outlineView(_ outlineView: NSOutlineView, draggingEnded sender: any NSDraggingInfo) {
        endOutlineDestinationDrag()
    }
    
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        browserState.tabDraggingSession.attachNativeSession(session)
        browserState.tabDraggingSession.update(
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y)
        )
    }

    func outlineView(_ outlineView: SideBarOutlineView, didClickRow row: Int) {
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? SidebarItem else {
            return
        }
        // Normal tab rows are delivered here (the outline view's standard
        // action never fires for them), so multi-selection must be handled
        // on this path rather than `outlineViewClicked`.
        let isCommandClick = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if isCommandClick,
           handleMultiSelectionCommandClick(for: item) {
            return
        }
        if browserState.multiSelection.isActive {
            browserState.clearMultiSelection()
        }
        itemClicked(item)
    }

    func outlineView(_ outlineView: SideBarOutlineView,
                     beginDraggingTabAtRow row: Int,
                     with mouseDownEvent: NSEvent) {
        guard row >= 0,
              let tab = outlineView.item(atRow: row) as? Tab,
              let rowView = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false) as? SidebarTabCellView else {
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] manual drag failed row=\(row)"
            )
            return
        }
        let multiDragIds = browserState.multiSelectionDragTabIds(startingFrom: tab)
        if browserState.multiSelection.isActive, multiDragIds == nil {
            browserState.clearMultiSelection()
        }
        guard let image = rowView.createDraggingImage() else {
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] manual drag image failed row=\(row)"
            )
            return
        }

        let pasteboardItem = NSPasteboardItem()
        configureNormalTabDragPayload(pasteboardItem, startingFrom: tab)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let frame = outlineView.convert(rowView.bounds, from: rowView)
        draggingItem.setDraggingFrame(frame, contents: image)

        let session = outlineView.beginDraggingSession(
            with: [draggingItem],
            event: mouseDownEvent,
            source: self)
        let screenPoint = mouseDownEvent.window?
            .convertPoint(toScreen: mouseDownEvent.locationInWindow) ?? NSEvent.mouseLocation
        AppLogDebug(
            "[SIDEBAR_TAB_DRAG_THRESHOLD] manual drag begin " +
            "row=\(row) tab=\(tab.guid) screen=\(screenPoint)"
        )
        DispatchQueue.main.async { [weak self] in
            self?.expandFloatingBookmarkParentsIfNeeded()
            self?.browserState.isDraggingTab = true
        }
        browserState.tabDraggingSession.attachNativeSession(session)
        browserState.tabDraggingSession.begin(
            draggingItem: tab,
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            containerView: hostVC?.view
        )
        _ = applyMultiSelectionDragImageIfNeeded(
            session: session,
            startingFrom: tab,
            sourceImage: image,
            sourceGroupCell: nil,
            browserState: browserState,
            outlineView: outlineView
        )
    }
    
    func outlineView(_ outlineView: SideBarOutlineView,
                     didMiddleClickRow row: Int,
                     at location: NSPoint) {
        guard row >= 0 else { return }
        guard let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        if let pair = item as? SplitPairSidebarItem {
            // Merged split row renders both panes side-by-side — route the
            // close to the pane whose half the click landed in. Use the
            // cell frame (not the row rect) so the indent area on the left
            // doesn't shift midX into the visible left pane.
            let cellRect = outlineView.frameOfCell(atColumn: 0, row: row)
            let target = location.x < cellRect.midX ? pair.leftTab : pair.rightTab
            tabSectionController.closeTab(target)
            return
        }
        guard let tab = item as? Tab, !tab.isPinned else { return }
        tabSectionController.closeTab(tab)
    }
}

// MARK: - Inner Group Tab Drag Source
extension SidebarTabListViewController: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] controller.sourceMask context=\(context.rawValue)"
        )
        return [.move, .copy]
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] controller.ignoreModifierKeys")
        return false
    }

    func draggingSession(_ session: NSDraggingSession,
                         movedTo screenPoint: NSPoint) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] controller.sourceMoved screen=\(screenPoint)"
        )
        browserState.tabDraggingSession.attachNativeSession(session)
        browserState.tabDraggingSession.update(
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y))
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] controller.sourceEnded screen=\(screenPoint) " +
            "op=\(operation.rawValue)"
        )
        finalizeWholeGroupSidebarTearOffIfNeeded(
            session: session,
            screenPoint: screenPoint,
            dragOperation: operation
        )
        clearDropFeedback()
        clearVisibleGroupInnerDropRows()
        restoreTemporarilyCollapsedGroupAfterDragIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.browserState.isDraggingTab = false
        }
        browserState.tabDraggingSession.end(
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            dragOperation: operation)
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
