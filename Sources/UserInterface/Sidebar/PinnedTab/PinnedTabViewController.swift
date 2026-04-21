// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

class PinnedTabViewController: NSViewController {
    private lazy var customLayout: PinnedTabLayout = {
        let layout = PinnedTabLayout()
        return layout
    }()

    private lazy var collectionView: ReorderingCollectionView = {
        let collectionView = ReorderingCollectionView()
        collectionView.allowsEmptySelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.collectionViewLayout = customLayout
        collectionView.delegate = self
        collectionView.reorderDelegate = self

        collectionView.isSelectable = true
        collectionView.registerForDraggedTypes([.pinnedTab, .normalTab, .phiBookmark])

        collectionView.backgroundColors = [.clear]
        collectionView.register(PinnedTabItem.self, forItemWithIdentifier: PinnedTabItem.reuseIdentifier)
        collectionView.register(PinnedExtensionItem.self, forItemWithIdentifier: PinnedExtensionItem.reuseIdentifier)
        return collectionView
    }()
    
    private lazy var dataSource: NSCollectionViewDiffableDataSource<Section, Item> = {
        let dataSource = NSCollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            guard let self else { return NSCollectionViewItem() }

            switch item {
            case .extensionItem(let model):
                guard let pinnedItem = collectionView.makeItem(withIdentifier: PinnedExtensionItem.reuseIdentifier, for: indexPath) as? PinnedExtensionItem else {
                    return NSCollectionViewItem()
                }
                pinnedItem.configure(with: model)
                pinnedItem.itemClicked = { [weak self] model, view in
                    self?.handleExtensionClicked(model, anchor: view)
                }
                pinnedItem.secondaryItemClicked = { [weak self] model in
                    self?.handleExtensionSecondaryClicked(model)
                }
                return pinnedItem

            case .tabItem(let tab):
                guard let tabItem = collectionView.makeItem(withIdentifier: PinnedTabItem.reuseIdentifier, for: indexPath) as? PinnedTabItem else {
                    return NSCollectionViewItem()
                }
                tabItem.configure(with: tab)
                tabItem.itemClicked = { [weak self] tab in
                    guard let tab else { return }
                    self?.handleTabClicked(tab)
                }
                return tabItem
            }
        }
        return dataSource
    }()
    
    private enum Section: Int, CaseIterable {
        case extensions = 0
        case tabs = 1
    }

    private enum Item: Hashable {
        case extensionItem(PinnedTabItemModel)
        case tabItem(Tab)

        private static func stableTabIdentifier(for tab: Tab) -> String {
            if let localGuid = tab.guidInLocalDB, localGuid.isEmpty == false {
                return localGuid
            }
            if tab.guid >= 0 {
                return "chromium:\(tab.guid)"
            }
            return "object:\(ObjectIdentifier(tab).hashValue)"
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .extensionItem(let model):
                hasher.combine("extension")
                hasher.combine(model)
            case .tabItem(let tab):
                hasher.combine("tab")
                hasher.combine(Self.stableTabIdentifier(for: tab))
            }
        }

        static func == (lhs: Item, rhs: Item) -> Bool {
            switch (lhs, rhs) {
            case (.extensionItem(let a), .extensionItem(let b)):
                return a == b
            case (.tabItem(let a), .tabItem(let b)):
                return stableTabIdentifier(for: a) == stableTabIdentifier(for: b)
            default:
                return false
            }
        }
    }
    
    private lazy var scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = collectionView
        return scrollView
    }()

    private lazy var emptyView: DragAwareView = {
        let containerView = DragAwareView()
        containerView.dragController = self
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 6

        let iconImageView = NSImageView()
        if let starImage = NSImage(systemSymbolName: "star.circle", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
            iconImageView.image = starImage.withSymbolConfiguration(config)
        }
        iconImageView.contentTintColor = .tertiaryLabelColor

        let sublabel = NSTextField()
        sublabel.stringValue = NSLocalizedString("Drag tabs here or pin them from the tab list", comment: "Drag tabs here or pin them from the tab list")
        sublabel.font = NSFont.systemFont(ofSize: 11)
        sublabel.textColor = .secondaryLabelColor
        sublabel.alignment = .center
        sublabel.isBordered = false
        sublabel.isEditable = false
        sublabel.backgroundColor = .clear

        containerView.addSubview(iconImageView)
        containerView.addSubview(sublabel)

        iconImageView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview()
            make.size.equalTo(CGSize(width: 32, height: 32))
        }


        sublabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sublabel.snp.makeConstraints { make in
            make.top.equalTo(iconImageView.snp.bottom).offset(4)
            make.centerX.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalToSuperview()
        }

        return containerView
    }()

    private weak var browserState: BrowserState?
    private weak var hostVC: NSViewController?
    private var pinnedTabs: [Tab] = []
    private var pinnedExtensionItems: [PinnedTabItemModel] = []
    private var cancellables = Set<AnyCancellable>()
    private var isDragging = false
    /// Placeholder item used while dragging a normal tab into pinned tabs.
    private var placeholderTab: Tab?
    private var isExternalDrag = false
    private var hasAppliedInitialContentSnapshot = false
    private var isActive = false

    @Published var contentHeight: CGFloat = 10
    
    init(state: BrowserState?, hostVC: NSViewController? = nil) {
        self.browserState = state
        self.hostVC = hostVC
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // make sure root view can accept drag/drop event
        view.wantsLayer = true
        setupDragDestination()

        // Seed an empty snapshot before the collection view starts reading sections.
        applySnapshot(animatingDifferences: false)
    }

    override func loadView() {
        let dragDestination = DragAwareView()
        dragDestination.dragController = self
        view = dragDestination
        
        setupScrollView()
    }

    private func setupScrollView() {
        view.addSubview(scrollView)
        view.addSubview(emptyView)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        emptyView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.equalToSuperview().offset(16)
            make.trailing.equalToSuperview().offset(-16)
        }

        updateEmptyViewVisibility()
    }

    private func setupDragDestination() {
        view.registerForDraggedTypes([.normalTab, .phiBookmark])
        view.wantsLayer = true
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
            syncCurrentState()
            return
        }
        isActive = true
        guard let browserState else {
            #if DEBUG
            loadMockDataIfNeeded()
            #endif
            return
        }
        cancellables.removeAll()
        // Refresh the snapshot only when the pinned-tab collection actually changes.
        browserState.$pinnedTabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                guard let self else {
                    return
                }
                guard tabs != self.pinnedTabs else {
                    self.updateAllItemsSelectionState(browserState.focusingTab)
                    return
                }
                self.pinnedTabs = tabs
                guard self.isDragging == false else {
                    return
                }
                self.applySnapshot(animatingDifferences: true)
                self.updateEmptyViewVisibility()
                self.updateAllItemsSelectionState(browserState.focusingTab)
            }
            .store(in: &cancellables)

        // Focus changes only affect selection state, not the data snapshot.
        browserState.$focusingTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] focusingTab in
                self?.updateAllItemsSelectionState(focusingTab)
            }
            .store(in: &cancellables)

        browserState.$isDraggingTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                self?.updateEmptyViewVisibility(isDraggingTab: dragging)
            }
            .store(in: &cancellables)
        
        browserState.extensionManager.$pinedExtensions
            .combineLatest(browserState.extensionManager.$shouldDisplayExtensionsWithinSidebar.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] extensions, show in
                if show {
                    self?.handlePinnedExtensionsUpdate(extensions)
                } else {
                    self?.handlePinnedExtensionsUpdate([])
                }
            }
            .store(in: &cancellables)

        syncCurrentState()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        cancellables.removeAll()
        clearInactiveContent()
    }

    private func syncCurrentState() {
        guard let browserState else { return }
        pinnedTabs = browserState.pinnedTabs
        let showExtensions = browserState.extensionManager.shouldDisplayExtensionsWithinSidebar
        let extensions = showExtensions ? browserState.extensionManager.pinedExtensions : []
        pinnedExtensionItems = extensions.map {
            PinnedTabItemModel(id: $0.id, title: $0.name, icon: $0.icon, tooltip: $0.name)
        }
        applySnapshot(animatingDifferences: false)
        updateEmptyViewVisibility(isDraggingTab: browserState.isDraggingTab)
        updateAllItemsSelectionState(browserState.focusingTab)
    }

    private func clearInactiveContent() {
        pinnedTabs = []
        pinnedExtensionItems = []
        placeholderTab = nil
        isDragging = false
        isExternalDrag = false
        hasAppliedInitialContentSnapshot = false
        applySnapshot(animatingDifferences: false)
        updateEmptyViewVisibility(isDraggingTab: false)
        collectionView.visibleItems().forEach {
            $0.isSelected = false
            $0.view.isHidden = false
        }
        if contentHeight != 10 {
            contentHeight = 10
        }
    }

    private func handlePinnedExtensionsUpdate(_ extensions: [Extension]) {
        let mappedItems = extensions.map {
            PinnedTabItemModel(id: $0.id, title: $0.name, icon: $0.icon, tooltip: $0.name)
        }
        guard mappedItems != pinnedExtensionItems else {
            updateEmptyViewVisibility()
            return
        }
        pinnedExtensionItems = mappedItems
        applySnapshot(animatingDifferences: true)
        updateEmptyViewVisibility()
    }

    private func loadMockDataIfNeeded() {
        guard pinnedTabs.isEmpty, pinnedExtensionItems.isEmpty else {
            return
        }

        let mockTabs = (0..<7).map { index -> Tab in
            let title = "Mock Tab \(index + 1)"
            return Tab(
                guid: index + 1000,
                url: "https://example.com/\(index + 1)",
                isActive: index == 0,
                index: index,
                title: title,
                webContentView: nil,
                customGuid: "mock-\(index + 1)"
            )
        }
        pinnedTabs = mockTabs

        let mockExtensions = (0..<17).map {
            PinnedTabItemModel(id: "mock-extension-\($0)", title: "Mock Extension \($0)", icon: nil)
        }
        pinnedExtensionItems = mockExtensions
        applySnapshot(animatingDifferences: false)
        updateEmptyViewVisibility()
    }
    
    private func applySnapshot(animatingDifferences: Bool = true) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        if !pinnedExtensionItems.isEmpty {
            snapshot.appendItems(pinnedExtensionItems.map { .extensionItem($0) }, toSection: .extensions)
        }
        if !pinnedTabs.isEmpty {
            snapshot.appendItems(pinnedTabs.map { .tabItem($0) }, toSection: .tabs)
        }

        let hasAnyContent = !pinnedTabs.isEmpty || !pinnedExtensionItems.isEmpty
        let shouldAnimate = animatingDifferences && (hasAppliedInitialContentSnapshot || !hasAnyContent)

        dataSource.apply(snapshot, animatingDifferences: shouldAnimate) { [weak self] in
            guard let self else { return }
            if hasAnyContent {
                self.hasAppliedInitialContentSnapshot = true
            }
            self.updateAllItemsSelectionState(self.browserState?.focusingTab)
        }
        updateLayout()
    }

    private func updateEmptyViewVisibility(isDraggingTab: Bool = false) {
        let isEmpty = pinnedTabs.isEmpty && pinnedExtensionItems.isEmpty
        let showEmptyView = isEmpty && isDraggingTab
        emptyView.isHidden = !showEmptyView
        scrollView.isHidden = showEmptyView
    }

    private func updateAllItemsSelectionState(_ focusing: Tab?) {
        guard let focusingTab = focusing, focusingTab.guidInLocalDB?.isEmpty ?? true == false else {
            collectionView.visibleItems().compactMap { $0 as? PinnedTabItem }.forEach {
                $0.isSelected = false
            }
            return
        }
        for (index, tab) in pinnedTabs.enumerated() {
            let indexPath = IndexPath(item: index, section: Section.tabs.rawValue)
            if let item = collectionView.item(at: indexPath) as? PinnedTabItem {
                item.isSelected = tab.guidInLocalDB == focusing?.guidInLocalDB
            }
        }
    }

    private func updateLayout() {
        let parentWidth = view.bounds.width
        customLayout.configure(parentWidth: parentWidth, tabCount: pinnedTabs.count, extensionCount: pinnedExtensionItems.count)

        collectionView.collectionViewLayout?.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()

        let newHeight = customLayout.contentHeight
        if newHeight != contentHeight {
            contentHeight = newHeight
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateLayout()
    }

    private func handleTabClicked(_ tab: Tab) {
        browserState?.openOrFocusPinnedTab(tab)
    }

    private func handleExtensionClicked(_ item: PinnedTabItemModel, anchor view: NSView) {
        let point = ExtensionPopupAnchor.pointBelowView(view)
            ?? ExtensionPopupAnchor.mouseFallback()
        let windowId = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.windowId
        ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
            withId: item.id,
            pointInScreen: point,
            windowId: windowId?.int64Value ?? 0
        )
    }

    private func handleExtensionSecondaryClicked(_ item: PinnedTabItemModel) {
        let point = ExtensionPopupAnchor.mouseFallback()
        let windowId = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.windowId
        ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
            withId: item.id,
            pointInScreen: point,
            windowId: windowId?.int64Value ?? 0
        )
    }
}

extension PinnedTabViewController: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        return Set()
        
    }
    
    func collectionView(_ collectionView: NSCollectionView, shouldDeselectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        return Set()
    }
}

// MARK: - Drag and Drop Support
extension PinnedTabViewController {
    func collectionView(_ collectionView: NSCollectionView, writeItemsAt indexPaths: Set<IndexPath>, to pasteboard: NSPasteboard) -> Bool {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath),
              case .tabItem(let tab) = item else { return false }

        // Publish both pinned-tab and normal-tab identifiers to the pasteboard.
        pasteboard.setString("\(tab.guidInLocalDB ?? "")", forType: .pinnedTab)
        pasteboard.setString("\(tab.guid)", forType: .normalTab)
        if let windowId = browserState?.windowId {
            pasteboard.setString(String(windowId), forType: .sourceWindowId)
        }
        return true
    }
    
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        isDragging = true
        placeholderTab = nil
        isExternalDrag = false

        browserState?.tabDraggingSession.attachNativeSession(session)
        let draggingItem: Any? = {
            guard let indexPath = indexPaths.first,
                  let item = dataSource.itemIdentifier(for: indexPath),
                  case .tabItem(let tab) = item else {
                return nil
            }
            return tab
        }()
        browserState?.tabDraggingSession.begin(
            draggingItem: draggingItem,
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            containerView: hostVC?.view
        )

        // Asynchronously hide the source item's view after the system has captured the drag image.
        if let indexPath = indexPaths.first {
            DispatchQueue.main.async {
                if let item = collectionView.item(at: indexPath) {
                    item.view.isHidden = true
                }
            }
        }

        collectionView.visibleItems().forEach {
            $0.isSelected = false
        }
    }
    
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        isDragging = false
        browserState?.tabDraggingSession.end(
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y),
            dragOperation: operation
        )

        // If the drop was cancelled, remove the placeholder
        if isExternalDrag, let placeholder = placeholderTab {
            pinnedTabs.removeAll { $0 == placeholder }
        }
        placeholderTab = nil
        isExternalDrag = false

        // Sync UI with the latest data, as snapshot apply may have been
        // skipped while isDragging was true.
        if let latestTabs = browserState?.pinnedTabs {
            pinnedTabs = latestTabs
        }
        applySnapshot(animatingDifferences: true)
        updateEmptyViewVisibility()

        // Unhide all items to ensure the dragged item reappears and the UI is clean.
        for item in collectionView.visibleItems() {
            item.view.isHidden = false
        }
        DispatchQueue.main.async {
            for item in collectionView.visibleItems() {
                item.view.isHidden = false
            }
        }

        updateAllItemsSelectionState(browserState?.focusingTab)
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        updateDraggingSession(from: draggingInfo)
        let dropIndexPath = proposedDropIndexPath.pointee as IndexPath
        guard let targetSection = Section(rawValue: dropIndexPath.section),
              targetSection == .tabs else {
            return []
        }
        
        let pasteboard = draggingInfo.draggingPasteboard
        
        if isCrossWindowDrag(pasteboard),
           let sourceState = sourceBrowserState(for: pasteboard),
           let targetState = browserState,
           !targetState.canAcceptCrossWindowDrag(from: sourceState) {
            return []
        }
        
        // Accept non-folder bookmarks.
        if let bookmarkId = pasteboard.string(forType: .phiBookmark),
           let bookmark = browserState?.bookmarkManager.bookmark(withGuid: bookmarkId),
           !bookmark.isFolder {
            proposedDropOperation.pointee = .on
            return .move
        }
        
        // Accept pinned tabs and normal tabs.
        if pasteboard.string(forType: .pinnedTab) != nil || pasteboard.string(forType: .normalTab) != nil {
            proposedDropOperation.pointee = .on
            return .move
        }
        
        return []
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        updateDraggingSession(from: draggingInfo)
        guard indexPath.section == Section.tabs.rawValue else {
            return false
        }
        
        let pasteboard = draggingInfo.draggingPasteboard
        var finalDestinationIndex = indexPath.item
        let isCrossWindow = isCrossWindowDrag(pasteboard)
        let sourceState = isCrossWindow ? sourceBrowserState(for: pasteboard) : nil

        // If it was an external drag, remove the placeholder before calculating the final index.
        if isExternalDrag, let placeholder = placeholderTab {
            if let placeholderIndex = pinnedTabs.firstIndex(of: placeholder) {
                if indexPath.item > placeholderIndex {
                    finalDestinationIndex -= 1
                }
                pinnedTabs.removeAll { $0 == placeholder }
            }
        }
        
        isDragging = false // Set isDragging to false before browserState updates.
        browserState?.tabDraggingSession.end()

        if isCrossWindow, let sourceState {
            if let guidString = pasteboard.string(forType: .pinnedTab) {
                return handleCrossWindowPinnedDrop(pinnedGuid: guidString, sourceState: sourceState, destinationIndex: finalDestinationIndex)
            }
            
            if let guidString = pasteboard.string(forType: .normalTab), let guid = Int(guidString) {
                return handleCrossWindowNormalTabDropToFavorites(tabGuid: guid, sourceState: sourceState, destinationIndex: finalDestinationIndex)
            }
            
            if let bookmarkId = pasteboard.string(forType: .phiBookmark) {
                return handleCrossWindowBookmarkDropToFavorites(bookmarkGuid: bookmarkId, sourceState: sourceState, destinationIndex: finalDestinationIndex)
            }
        }

        // Handle internal reorder
        if !isCrossWindow, !isExternalDrag, let guidString = pasteboard.string(forType: .pinnedTab) {
            guard let sourceTab = browserState?.pinnedTabs.first(where: { $0.guidInLocalDB == guidString }),
                  let sourceIndex = browserState?.pinnedTabs.firstIndex(of: sourceTab) else {
                return false
            }
            
            guard let destinationIndex = self.pinnedTabs.firstIndex(where: { $0.guidInLocalDB == guidString }) else {
                return false
            }

            var adjustedDestinationIndex = destinationIndex
            if sourceIndex < destinationIndex {
                adjustedDestinationIndex += 1
            }

            browserState?.movePinnedTab(tab: sourceTab, to: adjustedDestinationIndex, selectAfterMove: sourceTab.isActive)
            return true
        }

        // Handle drop from normal tab
        if pasteboard.string(forType: .pinnedTab) == nil,
           let guidString = pasteboard.string(forType: .normalTab),
           let guid = Int(guidString) {
            let destinationIndex = min(finalDestinationIndex, pinnedTabs.count)
            return handleNormalTabDropToFavorites(tabGuid: guid, destinationIndex: destinationIndex)
        }
        
        // Handle drop from bookmark
        if pasteboard.string(forType: .pinnedTab) == nil,
           let bookmarkId = pasteboard.string(forType: .phiBookmark) {
            let destinationIndex = min(finalDestinationIndex, pinnedTabs.count)
            return handleBookmarkDropToFavorites(bookmarkGuid: bookmarkId, destinationIndex: destinationIndex)
        }

        return false
    }

    private func handleNormalTabDropToFavorites(tabGuid: Int, destinationIndex: Int) -> Bool {
        browserState?.moveNormalTab(tabId: tabGuid, toPinnd: destinationIndex)
        return true
    }
    
    private func handleBookmarkDropToFavorites(bookmarkGuid: String, destinationIndex: Int) -> Bool {
        guard let bookmark = browserState?.bookmarkManager.bookmark(withGuid: bookmarkGuid),
              !bookmark.isFolder else {
            return false
        }
        browserState?.moveBookmarkOut(bookmark, toPinnedTabs: destinationIndex)
        return true
    }
    
    private func handleCrossWindowPinnedDrop(pinnedGuid: String, sourceState: BrowserState, destinationIndex: Int) -> Bool {
        guard let targetState = browserState else { return false }
        if let targetPinned = targetState.pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }),
           let sourceIndex = targetState.pinnedTabs.firstIndex(of: targetPinned) {
            var adjustedDestinationIndex = destinationIndex
            if sourceIndex < destinationIndex {
                adjustedDestinationIndex += 1
            }
            targetState.movePinnedTab(tab: targetPinned, to: adjustedDestinationIndex, selectAfterMove: targetPinned.isActive)
        }
        if let openTab = findOpenTab(in: sourceState, matchingLocalGuid: pinnedGuid) {
            return moveTabToTargetWindow(openTab)
        }
        return true
    }
    
    private func handleCrossWindowNormalTabDropToFavorites(tabGuid: Int, sourceState: BrowserState, destinationIndex: Int) -> Bool {
        guard let tab = sourceState.tabs.first(where: { $0.guid == tabGuid }) else { return false }
        sourceState.moveNormalTab(tabId: tabGuid, toPinnd: destinationIndex)
        return moveTabToTargetWindow(tab)
    }
    
    private func handleCrossWindowBookmarkDropToFavorites(bookmarkGuid: String, sourceState: BrowserState, destinationIndex: Int) -> Bool {
        guard let bookmark = browserState?.bookmarkManager.bookmark(withGuid: bookmarkGuid),
              !bookmark.isFolder else {
            return false
        }
        if let openTab = findOpenTab(in: sourceState, matchingLocalGuid: bookmarkGuid) {
            sourceState.moveBookmarkOut(bookmark, toPinnedTabs: destinationIndex)
            return moveTabToTargetWindow(openTab)
        }
        browserState?.moveBookmarkOut(bookmark, toPinnedTabs: destinationIndex)
        return true
    }
}

// MARK: - ReorderingCollectionViewDelegate
extension PinnedTabViewController: ReorderingCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, draggingExited info: NSDraggingInfo?) {
        // If it was an external drag, remove the placeholder when the drag exits the view.
        if isExternalDrag, let placeholder = placeholderTab {
            pinnedTabs.removeAll { $0 == placeholder }
            applySnapshot(animatingDifferences: true)
            self.placeholderTab = nil
        }
    }

    func collectionView(_ collectionView: NSCollectionView, draggingInfo: NSDraggingInfo, movedTo indexPath: IndexPath) {
        updateDraggingSession(from: draggingInfo)
        guard let targetSection = Section(rawValue: indexPath.section), targetSection == .tabs else { return }
        let pasteboard = draggingInfo.draggingPasteboard
        let isCrossWindow = isCrossWindowDrag(pasteboard)
        
        // Case 1: Internal Reorder
        if let guidString = pasteboard.string(forType: .pinnedTab),
           let sourceIndex = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == guidString }) {
            
            if isCrossWindow {
                isExternalDrag = true
                if let placeholder = self.placeholderTab {
                    self.pinnedTabs.removeAll { $0 == placeholder }
                    self.placeholderTab = nil
                }
                let sourceIndexPath = IndexPath(item: sourceIndex, section: Section.tabs.rawValue)
                if sourceIndexPath == indexPath { return }
                
                let movedTab = self.pinnedTabs.remove(at: sourceIndexPath.item)
                let targetIndex = min(indexPath.item, self.pinnedTabs.count)
                self.pinnedTabs.insert(movedTab, at: targetIndex)
                applySnapshot(animatingDifferences: true)
                return
            }
            
            isExternalDrag = false
            if let placeholder = self.placeholderTab {
                self.pinnedTabs.removeAll { $0 == placeholder }
                self.placeholderTab = nil
            }
            
            let sourceIndexPath = IndexPath(item: sourceIndex, section: Section.tabs.rawValue)
            if sourceIndexPath == indexPath { return }

            let movedTab = self.pinnedTabs.remove(at: sourceIndexPath.item)
            let index = min(indexPath.item, self.pinnedTabs.count)
            self.pinnedTabs.insert(movedTab, at: index)
            applySnapshot(animatingDifferences: true)
            return
        }
        
        // Case 2: External Drag from normal tab
        if let guidString = pasteboard.string(forType: .normalTab), let guid = Int(guidString) {
            isExternalDrag = true
            
            var newTabs = self.pinnedTabs
            if let placeholder = self.placeholderTab {
                newTabs.removeAll { $0 == placeholder }
            }
            
            if self.placeholderTab == nil {
                self.placeholderTab = Tab(guid: guid, url: "", isActive: false, index: -1, title: "placeholder", webContentView: nil, customGuid: "placeholder-\(guid)")
            }
            
            let destinationIndex = min(indexPath.item, newTabs.count)
            newTabs.insert(self.placeholderTab!, at: destinationIndex)

            self.pinnedTabs = newTabs
            applySnapshot(animatingDifferences: true)
            
            DispatchQueue.main.async {
                if let placeholder = self.placeholderTab,
                   let placeholderIndex = self.pinnedTabs.firstIndex(of: placeholder),
                   let item = self.collectionView.item(at: IndexPath(item: placeholderIndex, section: Section.tabs.rawValue)) {
                    item.view.isHidden = true
                }
            }
            return
        }
        
        // Case 3: External Drag from bookmark
        if let bookmarkId = pasteboard.string(forType: .phiBookmark) {
            isExternalDrag = true
            
            var newTabs = self.pinnedTabs
            if let placeholder = self.placeholderTab {
                newTabs.removeAll { $0 == placeholder }
            }
            
            if self.placeholderTab == nil {
                self.placeholderTab = Tab(guid: bookmarkId.hashValue, url: "", isActive: false, index: -1, title: "placeholder", webContentView: nil, customGuid: "placeholder-\(bookmarkId)")
            }
            
            let destinationIndex = min(indexPath.item, newTabs.count)
            newTabs.insert(self.placeholderTab!, at: destinationIndex)

            self.pinnedTabs = newTabs
            applySnapshot(animatingDifferences: true)
            
            DispatchQueue.main.async {
                if let placeholder = self.placeholderTab,
                   let placeholderIndex = self.pinnedTabs.firstIndex(of: placeholder),
                   let item = self.collectionView.item(at: IndexPath(item: placeholderIndex, section: Section.tabs.rawValue)) {
                    item.view.isHidden = true
                }
            }
        }
    }
}

// MARK: - NSDraggingDestination (for empty view)
extension PinnedTabViewController: NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDraggingSession(from: sender)
        // Only use the empty-state drop target when there are no pinned tabs yet.
        guard pinnedTabs.isEmpty else {
            return []
        }

        let pasteboard = sender.draggingPasteboard
        
        if isCrossWindowDrag(pasteboard),
           let sourceState = sourceBrowserState(for: pasteboard),
           let targetState = browserState,
           !targetState.canAcceptCrossWindowDrag(from: sourceState) {
            return []
        }
        
        // Accept normal tabs.
        if pasteboard.string(forType: .normalTab) != nil {
            // Add visual feedback for the empty drop target.
            emptyView.layer?.backgroundColor = NSColor.selectedControlColor.withAlphaComponent(0.4).cgColor
            return .copy
        }
        
        // Accept non-folder bookmarks.
        if let bookmarkId = pasteboard.string(forType: .phiBookmark),
           let bookmark = browserState?.bookmarkManager.bookmark(withGuid: bookmarkId),
           !bookmark.isFolder {
            emptyView.layer?.backgroundColor = NSColor.selectedControlColor.withAlphaComponent(0.4).cgColor
            return .copy
        }
        
        return []
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDraggingSession(from: sender)
        guard pinnedTabs.isEmpty else { return [] }
        return draggingEntered(sender)
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        // Clear the empty-state highlight.
        emptyView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateDraggingSession(from: sender)
        // Clear the empty-state highlight.
        emptyView.layer?.backgroundColor = NSColor.clear.cgColor

        // Only handle drops on the empty-state target while it is visible.
        guard pinnedTabs.isEmpty else { return false }

        let pasteboard = sender.draggingPasteboard
        defer {
            self.browserState?.tabDraggingSession.end()
        }
        
        if isCrossWindowDrag(pasteboard),
           let sourceState = sourceBrowserState(for: pasteboard),
           let targetState = browserState,
           !targetState.canAcceptCrossWindowDrag(from: sourceState) {
            return false
        }
        
        // Handle normal-tab drops.
        if let guidString = pasteboard.string(forType: .normalTab),
           let guid = Int(guidString) {
            // Insert at the first pinned position.
            if isCrossWindowDrag(pasteboard), let sourceState = sourceBrowserState(for: pasteboard) {
                return handleCrossWindowNormalTabDropToFavorites(tabGuid: guid, sourceState: sourceState, destinationIndex: 0)
            }
            return handleNormalTabDropToFavorites(tabGuid: guid, destinationIndex: 0)
        }
        
        // Handle bookmark drops.
        if let bookmarkId = pasteboard.string(forType: .phiBookmark) {
            if isCrossWindowDrag(pasteboard), let sourceState = sourceBrowserState(for: pasteboard) {
                return handleCrossWindowBookmarkDropToFavorites(bookmarkGuid: bookmarkId, sourceState: sourceState, destinationIndex: 0)
            }
            return handleBookmarkDropToFavorites(bookmarkGuid: bookmarkId, destinationIndex: 0)
        }
        
        return false
    }
}

// MARK: - Drag session helpers
extension PinnedTabViewController {
    private func updateDraggingSession(from info: NSDraggingInfo) {
        guard let browserState else { return }
        let windowPoint = info.draggingLocation
        let screenPoint: CGPoint? = view.window.map { window in
            let sp = window.convertPoint(toScreen: windowPoint)
            return CGPoint(x: sp.x, y: sp.y)
        }
        browserState.tabDraggingSession.update(screenLocation: screenPoint)
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
        guard let sourceId = dragSourceWindowId(from: pasteboard),
              let targetId = browserState?.windowId else {
            return false
        }
        return sourceId != targetId
    }
    
    private func findOpenTab(in state: BrowserState, matchingLocalGuid guid: String) -> Tab? {
        return state.tabs.first { $0.guidInLocalDB == guid }
    }
    
    private func moveTabToTargetWindow(_ tab: Tab) -> Bool {
        guard let targetState = browserState, let wrapper = tab.webContentWrapper else { return false }
        let insertIndex = max(0, targetState.tabs.count)
        wrapper.moveSelf(toWindow: targetState.windowId.int64Value, at: insertIndex)
        return true
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let switchToTab = Notification.Name("switchToTab")
}

class DragAwareView: NSView {
    weak var dragController: (any NSDraggingDestination)?
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let result = dragController?.draggingEntered?(sender) {
            return result
        }
        return super.draggingEntered(sender)
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let result = dragController?.draggingUpdated?(sender) {
            return result
        }
        return super.draggingUpdated(sender)
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragController?.draggingExited?(sender)
    }
    
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let result = dragController?.prepareForDragOperation?(sender) {
            return result
        }
        return super.prepareForDragOperation(sender)
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let result = dragController?.performDragOperation?(sender) {
            return result
        }
        return super.performDragOperation(sender)
    }
    
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dragController?.concludeDragOperation?(sender)
    }
    
    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragController?.draggingEnded?(sender)
    }
}
