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
        collectionView.clipsToBounds = true
        collectionView.register(PinnedTabItem.self, forItemWithIdentifier: PinnedTabItem.reuseIdentifier)
        collectionView.register(PinnedSplitItem.self, forItemWithIdentifier: PinnedSplitItem.reuseIdentifier)
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
                // Resolved icon (dynamic override + disabled graying) looked up
                // by id. The badge is a self-observing overlay in the cell, so it
                // updates without reloading; reloadItems is only needed for icon
                // changes (see the $dynamicIcons and render-state subscriptions).
                let manager = browserState?.extensionManager
                pinnedItem.configure(with: model,
                                     icon: manager?.iconImage(extensionId: model.id,
                                                              staticIcon: model.icon),
                                     manager: manager)
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
                tabItem.configure(
                    with: tab,
                    themeProvider: browserState?.themeContext ?? ThemeManager.shared
                )
                tabItem.itemClicked = { [weak self] tab in
                    guard let tab else { return }
                    self?.handleTabClicked(tab)
                }
                return tabItem

            case .splitItem(let group):
                guard let splitItem = collectionView.makeItem(withIdentifier: PinnedSplitItem.reuseIdentifier, for: indexPath) as? PinnedSplitItem else {
                    return NSCollectionViewItem()
                }
                splitItem.configure(
                    leftTab: group.leftTab,
                    rightTab: group.rightTab,
                    themeProvider: browserState?.themeContext ?? ThemeManager.shared
                )
                splitItem.itemClicked = { [weak self] tab in
                    self?.handleSplitCellClicked(group: group, preferredTab: tab)
                }
                return splitItem
            }
        }
        return dataSource
    }()
    
    private enum Section: Int, CaseIterable {
        case extensions = 0
        case tabs = 1
    }

    /// One pinned split represented as a single grid cell with both panes.
    /// Identified by the split's stable Chromium id so the diffable snapshot
    /// can detect when the same split is rebuilt with new tab instances.
    struct PinnedSplitGroupItem: Hashable {
        let splitId: String
        let leftTab: Tab
        let rightTab: Tab

        func hash(into hasher: inout Hasher) {
            hasher.combine(splitId)
        }

        static func == (lhs: PinnedSplitGroupItem, rhs: PinnedSplitGroupItem) -> Bool {
            lhs.splitId == rhs.splitId
        }
    }

    private enum Item: Hashable {
        case extensionItem(PinnedTabItemModel)
        case tabItem(Tab)
        case splitItem(PinnedSplitGroupItem)

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
            case .splitItem(let group):
                hasher.combine("split")
                hasher.combine(group.splitId)
            }
        }

        static func == (lhs: Item, rhs: Item) -> Bool {
            switch (lhs, rhs) {
            case (.extensionItem(let a), .extensionItem(let b)):
                return a == b
            case (.tabItem(let a), .tabItem(let b)):
                return stableTabIdentifier(for: a) == stableTabIdentifier(for: b)
            case (.splitItem(let a), .splitItem(let b)):
                return a == b
            default:
                return false
            }
        }
    }
    
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
    /// Last applied left|right DB-guid pair per splitId. `PinnedSplitGroupItem`
    /// hashes on `splitId` alone (so a Tab-instance churn doesn't recycle the
    /// cell), which means `apply()` skips items whose pair flipped via
    /// `reverseTabsInSplit`. We compare against this and reconfigure the
    /// affected items so the icons follow the rendered pane order.
    private var lastSplitItemPairs: [String: String] = [:]

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
        
        setupPinnedCollectionArea()
    }

    private func setupPinnedCollectionArea() {
        view.addSubview(collectionView)
        view.addSubview(emptyView)

        collectionView.snp.makeConstraints { make in
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

        browserState.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak browserState] _ in
                self?.updateAllItemsSelectionState(browserState?.focusingTab)
            }
            .store(in: &cancellables)

        // Split membership / pin flag changes can flip a pair of pinnedTabs
        // entries into a single .splitItem (and back) without changing the
        // pinnedTabs array itself. Rebuild the snapshot when splits change so
        // the collapsed-vs-expanded representation stays in sync.
        browserState.$splits
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isDragging == false else { return }
                self.applySnapshot(animatingDifferences: true)
            }
            .store(in: &cancellables)

        browserState.$isDraggingTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                self?.updateEmptyViewVisibility(isDraggingTab: dragging)
            }
            .store(in: &cancellables)
        
        browserState.extensionManager.$pinedExtensions
            .combineLatest(
                browserState.extensionManager.$shouldDisplayExtensionsWithinSidebar.removeDuplicates(),
                browserState.$isInPlaceholderMode.removeDuplicates()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] extensions, show, isPlaceholder in
                if isPlaceholder || !show {
                    self?.handlePinnedExtensionsUpdate([])
                } else {
                    self?.handlePinnedExtensionsUpdate(extensions)
                }
            }
            .store(in: &cancellables)

        // A dynamic-icon change doesn't change the pinned set, and the id-only
        // model equality means a plain re-apply won't refresh cells, so reload
        // the extension items to re-run the cell provider with the new icon.
        // (Badge changes are handled by the self-observing overlay in the cell,
        // so they need no reload here.)
        browserState.extensionManager.$dynamicIcons
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadExtensionItems()
            }
            .store(in: &cancellables)

        // React when an extension's render state flips. A page action hidden/
        // shown changes the displayed set (snapshot re-apply); an action
        // disabled/enabled keeps the set identical — the id-only model equality
        // means the snapshot won't reconfigure cells — so also reload the
        // extension items to re-bake the (grayed) icon. Gated on the render-
        // state set so a rapid badge-text tick (e.g. a blocked-count) does NOT
        // rebuild (that would be the deferred rebuild-all churn).
        browserState.extensionManager.$badges
            .map(ExtensionManager.actionRenderStates)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.handlePinnedExtensionsUpdate(self.currentPinnedExtensionsForDisplay())
                self.reloadExtensionItems()
            }
            .store(in: &cancellables)

        syncCurrentState()
    }

    private func reloadExtensionItems() {
        // Skip mid-drag snapshot apply (re-synced on drag end), matching the
        // isDragging invariant the tab/split sinks honor.
        guard !isDragging else { return }
        var snapshot = dataSource.snapshot()
        let extensionItems = snapshot.itemIdentifiers(inSection: .extensions)
        guard !extensionItems.isEmpty else { return }
        // reloadItems re-runs the cell provider for these identifiers even though
        // the model equality is id-only, so the provider picks up the new icon.
        snapshot.reloadItems(extensionItems)
        dataSource.apply(snapshot, animatingDifferences: false)
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
        pinnedExtensionItems = visibleExtensionItems(currentPinnedExtensionsForDisplay())
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

    /// Hide page actions reporting visible == false on the current tab (spec
    /// §4.3), mapping the rest to display models. Reused by the pinned-set, sync,
    /// and visibility-change paths so all three agree.
    private func visibleExtensionItems(_ extensions: [Extension]) -> [PinnedTabItemModel] {
        let manager = browserState?.extensionManager
        return extensions
            .filter { manager?.badges[$0.id]?.visible != false }
            .map { PinnedTabItemModel(id: $0.id, title: $0.name, icon: $0.icon, tooltip: $0.name) }
    }

    /// The pinned extensions to display, honoring the sidebar-display +
    /// placeholder gating (before the per-tab visibility filter).
    private func currentPinnedExtensionsForDisplay() -> [Extension] {
        guard let browserState else { return [] }
        let show = browserState.extensionManager.shouldDisplayExtensionsWithinSidebar
            && !browserState.isInPlaceholderMode
        return show ? browserState.extensionManager.pinedExtensions : []
    }

    private func handlePinnedExtensionsUpdate(_ extensions: [Extension]) {
        let mappedItems = visibleExtensionItems(extensions)
        guard mappedItems != pinnedExtensionItems else {
            updateEmptyViewVisibility()
            return
        }
        pinnedExtensionItems = mappedItems
        // Match the $pinnedTabs / $splits sinks: keep the data current but skip
        // the visual apply during a drag (endedAt re-applies on drag end), so an
        // async page-action visibility flip can't reflow the grid under the
        // cursor mid-reorder.
        guard !isDragging else { return }
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
    
    /// Build the tabs-section items by collapsing each pinned split's two
    /// records into one `.splitItem`. Iteration follows `pinnedTabs` order;
    /// the first pane encountered emits the combined item, the partner is
    /// consumed and skipped. Tabs without a pinned-split membership stay as
    /// regular `.tabItem`s.
    ///
    /// Pairing source order:
    ///   1. Live `SplitGroup` flagged `isPinned` — used while both panes are
    ///      currently open Chromium tabs.
    ///   2. Persisted `Tab.splitPartnerGuid` — survives across restarts and
    ///      covers the case where one or both panes are closed pinned-tab
    ///      records waiting to be reopened.
    private func buildTabSectionItems() -> [Item] {
        guard let state = browserState else {
            return pinnedTabs.map { .tabItem($0) }
        }
        // Pre-compute lookup dictionaries so the per-tab loop runs O(1) per
        // entry instead of repeating `first(where:)` scans against `tabs`,
        // `splits`, and `pinnedTabs`. Snapshot rebuilds fire on every
        // `$pinnedTabs` / `$splits` / `$focusingTab` emission, so the
        // savings compound during normal interaction.
        let pinnedByDB: [String: Tab] = Dictionary(uniqueKeysWithValues:
            pinnedTabs.compactMap { tab in tab.guidInLocalDB.map { ($0, tab) } }
        )
        let liveByDB: [String: Tab] = Dictionary(
            state.tabs.compactMap { tab in tab.guidInLocalDB.map { ($0, tab) } },
            uniquingKeysWith: { first, _ in first }
        )
        let pinnedSplitByLiveTabId: [Int: SplitGroup] = state.splits
            .filter(\.isPinned)
            .reduce(into: [:]) { result, group in
                result[group.primaryTabId] = group
                result[group.secondaryTabId] = group
            }

        // Bidirectional persisted-partner map. Each pinned-split pane persists
        // its own `splitPartnerGuid`, but the two writes are async and the
        // second can be dropped if the app quits before it flushes — leaving a
        // half-linked pair (only A->B on disk). Resolving pairing off a single
        // record's `splitPartnerGuid` then splinters the cell into two on the
        // next launch when the unlinked record sorts first. Mirroring every
        // link so either direction pairs both panes makes the merge
        // order-independent and tolerant of a half-persisted link.
        var persistedPartnerByDB: [String: String] = [:]
        for tab in pinnedTabs {
            guard let db = tab.guidInLocalDB,
                  let partner = tab.splitPartnerGuid, !partner.isEmpty else { continue }
            persistedPartnerByDB[db] = partner
            if persistedPartnerByDB[partner] == nil {
                persistedPartnerByDB[partner] = db
            }
        }

        var consumedDBGuids = Set<String>()
        var items: [Item] = []
        for tab in pinnedTabs {
            guard let myDBGuid = tab.guidInLocalDB, !consumedDBGuids.contains(myDBGuid) else { continue }

            // Prefer the live SplitGroup id when one exists so the same
            // splitId is used while the split is open and the diffable
            // snapshot does not flicker between live/persisted forms.
            var combined: PinnedSplitGroupItem?
            if let liveTab = liveByDB[myDBGuid],
               let group = pinnedSplitByLiveTabId[liveTab.guid],
               let partnerLiveId = group.partnerTabId(of: liveTab.guid),
               let partnerLive = state.tabs.first(where: { $0.guid == partnerLiveId }),
               let partnerDBGuid = partnerLive.guidInLocalDB,
               let partnerPinned = pinnedByDB[partnerDBGuid] {
                // Mirror the rendered pane order: `SplitPaneHostView` puts
                // `primaryTabId` on the left (vertical) / top (horizontal),
                // so `leftTab` must be the pinned record of the primary pane.
                // Iteration order alone would lock the icons to `pinnedTabs`
                // order and desync after `reverseTabsInSplit`.
                let currentIsPrimary = liveTab.guid == group.primaryTabId
                combined = PinnedSplitGroupItem(splitId: group.id,
                                                leftTab: currentIsPrimary ? tab : partnerPinned,
                                                rightTab: currentIsPrimary ? partnerPinned : tab)
                consumedDBGuids.insert(partnerDBGuid)
            } else if let partnerDBGuid = persistedPartnerByDB[myDBGuid],
                      !consumedDBGuids.contains(partnerDBGuid),
                      let partnerPinned = pinnedByDB[partnerDBGuid] {
                // Persisted pair (bidirectional — see `persistedPartnerByDB`).
                // Synthesize a stable splitId from both DB guids so the
                // diffable snapshot identifies the same item across re-renders.
                let sortedPair = [myDBGuid, partnerDBGuid].sorted()
                let stableId = "persisted-split:\(sortedPair[0])|\(sortedPair[1])"
                combined = PinnedSplitGroupItem(splitId: stableId,
                                                leftTab: tab,
                                                rightTab: partnerPinned)
                consumedDBGuids.insert(partnerDBGuid)
            }

            if let combined {
                items.append(.splitItem(combined))
            } else {
                items.append(.tabItem(tab))
            }
            consumedDBGuids.insert(myDBGuid)
        }
        return items
    }

    private func applySnapshot(animatingDifferences: Bool = true) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        if !pinnedExtensionItems.isEmpty {
            snapshot.appendItems(pinnedExtensionItems.map { .extensionItem($0) }, toSection: .extensions)
        }
        let tabSectionItems = buildTabSectionItems()
        if !tabSectionItems.isEmpty {
            snapshot.appendItems(tabSectionItems, toSection: .tabs)
        }

        var newSplitPairs: [String: String] = [:]
        var splitItemsToReconfigure: [Item] = []
        for item in tabSectionItems {
            guard case .splitItem(let group) = item else { continue }
            let pairKey = "\(group.leftTab.guidInLocalDB ?? "")|\(group.rightTab.guidInLocalDB ?? "")"
            newSplitPairs[group.splitId] = pairKey
            if let previous = lastSplitItemPairs[group.splitId], previous != pairKey {
                splitItemsToReconfigure.append(item)
            }
        }
        if !splitItemsToReconfigure.isEmpty {
            // AppKit's `NSDiffableDataSourceSnapshot` only exposes
            // `reloadItems` (no `reconfigureItems`), which is fine here:
            // we only land in this branch for the rare reverse path.
            snapshot.reloadItems(splitItemsToReconfigure)
        }
        lastSplitItemPairs = newSplitPairs

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
        collectionView.isHidden = showEmptyView
    }

    private func updateAllItemsSelectionState(_ focusing: Tab?) {
        let focusingDBGuid: String? = {
            guard let guid = focusing?.guidInLocalDB, !guid.isEmpty else { return nil }
            return guid
        }()

        guard browserState?.groupOverviewState == nil else {
            collectionView.visibleItems().forEach { visible in
                if let tabItem = visible as? PinnedTabItem { tabItem.isSelected = false }
                if let splitItem = visible as? PinnedSplitItem { splitItem.isSelected = false }
            }
            return
        }

        guard focusingDBGuid != nil else {
            collectionView.visibleItems().forEach { visible in
                if let tabItem = visible as? PinnedTabItem { tabItem.isSelected = false }
                if let splitItem = visible as? PinnedSplitItem { splitItem.isSelected = false }
            }
            return
        }

        // Snapshot order matches the collection view's index paths; iterate
        // by snapshot index so split-collapsed items align with their cells.
        let tabItems = dataSource.snapshot().itemIdentifiers(inSection: .tabs)
        for (index, item) in tabItems.enumerated() {
            let indexPath = IndexPath(item: index, section: Section.tabs.rawValue)
            switch item {
            case .tabItem(let tab):
                if let cell = collectionView.item(at: indexPath) as? PinnedTabItem {
                    cell.isSelected = tab.guidInLocalDB == focusingDBGuid
                }
            case .splitItem(let group):
                if let cell = collectionView.item(at: indexPath) as? PinnedSplitItem {
                    cell.isSelected = group.leftTab.guidInLocalDB == focusingDBGuid
                        || group.rightTab.guidInLocalDB == focusingDBGuid
                }
            case .extensionItem:
                break
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
        browserState?.clearGroupOverview()
        browserState?.openOrFocusPinnedTab(tab)
    }

    /// Click handler for a merged pinned-split cell. Opens whichever pane is
    /// currently closed so the auto-pair logic can recreate the `SplitGroup`,
    /// then activates the pane the user clicked closer to.
    private func handleSplitCellClicked(group: PinnedSplitGroupItem, preferredTab: Tab?) {
        guard let state = browserState,
              let leftGuid = group.leftTab.guidInLocalDB,
              let rightGuid = group.rightTab.guidInLocalDB else {
            return
        }
        let focusRight = preferredTab?.guidInLocalDB == rightGuid
        state.openPinnedSplit(leftPinnedGuid: leftGuid,
                              rightPinnedGuid: rightGuid,
                              focusRight: focusRight)
    }

    private func handleExtensionClicked(_ item: PinnedTabItemModel, anchor view: NSView) {
        // A disabled action doesn't run; fall back to the context menu like
        // Chrome (ExecuteUserAction).
        if browserState?.extensionManager.badges[item.id]?.enabled == false {
            handleExtensionSecondaryClicked(item)
            return
        }
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
              let item = dataSource.itemIdentifier(for: indexPath) else { return false }

        // Pinned splits render as a single merged cell, so use the left pane
        // as the drag handle. Drop handlers detect split membership via the
        // pinned tab's `splitPartnerGuid` / live `splitGroup` and operate on
        // the whole pair where appropriate.
        let tab: Tab
        switch item {
        case .tabItem(let t):
            tab = t
        case .splitItem(let group):
            tab = group.leftTab
        case .extensionItem:
            return false
        }

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
                  let item = dataSource.itemIdentifier(for: indexPath) else {
                return nil
            }
            switch item {
            case .tabItem(let tab):
                return tab
            case .splitItem(let group):
                return group.leftTab
            case .extensionItem:
                return nil
            }
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
        let initialDropIndexPath = proposedDropIndexPath.pointee as IndexPath
        // When the system proposes a target outside the tabs section (e.g.
        // hovering above the first row, over the extensions row, or in a
        // boundary gap), redirect to the end of the tabs section so the
        // drop is accepted instead of silently rejected. Otherwise external
        // bookmark/tab drags onto the pinned area look unsupported.
        let dropIndexPath: IndexPath
        if let targetSection = Section(rawValue: initialDropIndexPath.section),
           targetSection == .tabs {
            dropIndexPath = initialDropIndexPath
        } else {
            let tabsCount = collectionView.numberOfItems(inSection: Section.tabs.rawValue)
            dropIndexPath = IndexPath(item: tabsCount, section: Section.tabs.rawValue)
            proposedDropIndexPath.pointee = dropIndexPath as NSIndexPath
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
        guard let state = browserState else { return false }
        // Split-aware: when the dropped tab is one pane of a split, pin the
        // whole pair as a single pinned-split unit instead of pinning just
        // the dropped pane and leaving the other behind in the strip.
        if let splitGroup = state.splitGroup(forTabId: tabGuid) {
            state.pinSplitInsertingAtPinnedIndex(splitGroup.id, atIndex: destinationIndex)
            return true
        }
        state.moveNormalTab(tabId: tabGuid, toPinnd: destinationIndex)
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
        // Split-aware: keep both halves of a split together on cross-window
        // moves. The bridge falls back to the single-tab path for non-split
        // tabs (the common pinned-sidebar case).
        wrapper.moveSplit(toWindow: targetState.windowId.int64Value, at: insertIndex)
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
