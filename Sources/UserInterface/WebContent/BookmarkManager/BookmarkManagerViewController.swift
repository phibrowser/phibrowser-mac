// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import PostHog

final class BookmarkManagerAnalyticsSession {
    typealias Capture = (_ event: String, _ properties: [String: Any]) -> Void

    private let capture: Capture
    private var didEdit = false
    private var hasStarted = false
    private var hasFinished = false

    init(capture: @escaping Capture = { event, properties in
        PostHogSDK.shared.capture(event, properties: properties)
    }) {
        self.capture = capture
    }

    func start() {
        guard !hasStarted, !hasFinished else { return }
        hasStarted = true
        capture("bookmark_manager_opened", [:])
    }

    func markEdited() {
        guard hasStarted, !hasFinished else { return }
        didEdit = true
    }

    func finish() {
        guard hasStarted, !hasFinished else { return }
        hasFinished = true
        guard didEdit else { return }
        capture("bookmark_manager_edited", [:])
    }
}

private final class BookmarkManagerOutlineView: DiffableOutlineView {
    var contextMenuProvider: (() -> NSMenu?)?
    var deleteSelectionHandler: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), (event.keyCode == 51 || event.keyCode == 117) {
            deleteSelectionHandler?()
            return
        }
        super.keyDown(with: event)
    }
}

final class BookmarkManagerViewController: NSViewController {
    private enum Column {
        static let website = NSUserInterfaceItemIdentifier("BookmarkManagerWebsite")
        static let address = NSUserInterfaceItemIdentifier("BookmarkManagerAddress")
        static let minimumWidth: CGFloat = 100
        static let defaultWidthDifference: CGFloat = 160
    }

    private enum Row {
        static let regularHeight: CGFloat = 30
        static let splitHeight: CGFloat = 58
    }

    private enum Header {
        static let compactLayoutWidth: CGFloat = 600
        static let ultraCompactLayoutWidth: CGFloat = 300
        static let horizontalInset: CGFloat = 24
        static let topInset: CGFloat = 24
        static let rowSpacing: CGFloat = 12
        static let contentSpacing: CGFloat = 24
        static let wideSearchWidth: CGFloat = 224
        static let compactSearchMinimumWidth: CGFloat = 120
    }

    private final class BookmarkActionContext: NSObject {
        let guids: [String]

        init(guids: [String]) {
            self.guids = guids
        }
    }

    private final class SpaceTransferActionContext: NSObject {
        let guids: [String]
        let targetSpaceId: String

        init(guids: [String], targetSpaceId: String) {
            self.guids = guids
            self.targetSpaceId = targetSpaceId
        }
    }

    private final class GroupActionContext: NSObject {
        let guids: [String]
        let groupToken: String

        init(guids: [String], groupToken: String) {
            self.guids = guids
            self.groupToken = groupToken
        }
    }

    private final class CopyActionContext: NSObject {
        let url: String

        init(url: String) {
            self.url = url
        }
    }

    private let browserState: BrowserState
    private let manager: BookmarkManager
    private let scope: BookmarkManagementScope
    private var projection: BookmarkManagerProjection?
    private var projectionGeneration = 0
    private var pendingEditGuid: String?
    private var didConfigureInitialColumnWidths = false
    private var cancellables = Set<AnyCancellable>()
    private let analyticsSession = BookmarkManagerAnalyticsSession()

    private let outlineView = BookmarkManagerOutlineView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let headerLeadingStack = NSStackView()
    private let headerControlsStack = NSStackView()
    private let searchField = NSSearchField()
    private let newFolderButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let spaceIndicatorView = NSStackView()
    private let spaceIndicatorImageView = NSImageView()
    private let spaceIndicatorLabel = NSTextField(labelWithString: "")
    private var wideHeaderConstraints: [NSLayoutConstraint] = []
    private var compactHeaderConstraints: [NSLayoutConstraint] = []
    private var usesCompactHeaderLayout: Bool?
    private var usesUltraCompactHeaderLayout = false
    private var newFolderButtonTitle = ""

    init(browserState: BrowserState) {
        self.browserState = browserState
        self.manager = browserState.bookmarkManager
        self.scope = browserState.bookmarkManager.scope
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.windowBackground)
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        analyticsSession.start()
        bindModel()
        rebuildProjection(animated: false)
    }

    deinit {
        analyticsSession.finish()
    }

    override func viewWillLayout() {
        updateHeaderLayoutIfNeeded()
        super.viewWillLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        configureInitialColumnWidthsIfNeeded()
    }

    func focusContent() {
        view.window?.makeFirstResponder(outlineView)
    }

    func finishAnalyticsSession() {
        analyticsSession.finish()
    }

    private func buildLayout() {
        titleLabel.stringValue = NSLocalizedString(
            "bookmarkManager.header.title",
            value: "Bookmarks",
            comment: "Bookmark manager - Page title"
        )
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        spaceIndicatorImageView.imageScaling = .scaleProportionallyDown
        spaceIndicatorImageView.contentTintColor = .secondaryLabelColor
        spaceIndicatorImageView.setAccessibilityElement(false)
        spaceIndicatorImageView.translatesAutoresizingMaskIntoConstraints = false

        spaceIndicatorLabel.font = .systemFont(ofSize: 13, weight: .medium)
        spaceIndicatorLabel.textColor = .secondaryLabelColor
        spaceIndicatorLabel.lineBreakMode = .byTruncatingTail
        spaceIndicatorLabel.maximumNumberOfLines = 1
        spaceIndicatorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spaceIndicatorView.orientation = .horizontal
        spaceIndicatorView.alignment = .centerY
        spaceIndicatorView.spacing = 5
        spaceIndicatorView.addArrangedSubview(spaceIndicatorImageView)
        spaceIndicatorView.addArrangedSubview(spaceIndicatorLabel)
        spaceIndicatorView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spaceIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        spaceIndicatorView.isHidden = true

        headerLeadingStack.orientation = .horizontal
        headerLeadingStack.alignment = .bottom
        headerLeadingStack.spacing = 12
        headerLeadingStack.addArrangedSubview(titleLabel)
        headerLeadingStack.addArrangedSubview(spaceIndicatorView)
        headerLeadingStack.translatesAutoresizingMaskIntoConstraints = false

        newFolderButtonTitle = NSLocalizedString(
            "bookmarkManager.header.newFolderAction",
            value: "New Folder",
            comment: "Bookmark manager - Button that creates a folder at the root or inside the selected folder"
        )
        newFolderButton.title = newFolderButtonTitle
        newFolderButton.bezelStyle = .rounded
        newFolderButton.target = self
        newFolderButton.action = #selector(createFolderFromHeader(_:))
        newFolderButton.setContentHuggingPriority(.required, for: .horizontal)
        newFolderButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        newFolderButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.backgroundColor = .clear
        searchField.placeholderString = NSLocalizedString(
            "bookmarkManager.header.searchPlaceholder",
            value: "Search",
            comment: "Bookmark manager - Search field placeholder"
        )
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        headerControlsStack.orientation = .horizontal
        headerControlsStack.alignment = .centerY
        headerControlsStack.distribution = .fill
        headerControlsStack.spacing = Header.rowSpacing
        headerControlsStack.addArrangedSubview(newFolderButton)
        headerControlsStack.addArrangedSubview(searchField)
        headerControlsStack.translatesAutoresizingMaskIntoConstraints = false

        configureOutlineView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerLeadingStack)
        view.addSubview(headerControlsStack)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerLeadingStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Header.horizontalInset),
            headerLeadingStack.topAnchor.constraint(equalTo: view.topAnchor, constant: Header.topInset),
            spaceIndicatorImageView.widthAnchor.constraint(equalToConstant: 16),
            spaceIndicatorImageView.heightAnchor.constraint(equalToConstant: 16),
            spaceIndicatorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            spaceIndicatorLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -2),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Header.horizontalInset),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Header.horizontalInset),
        ])

        wideHeaderConstraints = [
            headerLeadingStack.trailingAnchor.constraint(
                lessThanOrEqualTo: headerControlsStack.leadingAnchor,
                constant: -16
            ),
            headerControlsStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Header.horizontalInset
            ),
            headerControlsStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: Header.wideSearchWidth),
            scrollView.topAnchor.constraint(
                equalTo: headerLeadingStack.bottomAnchor,
                constant: Header.contentSpacing
            ),
        ]
        let compactSearchMinimumWidth = searchField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Header.compactSearchMinimumWidth
        )
        compactSearchMinimumWidth.priority = .defaultHigh
        compactHeaderConstraints = [
            headerLeadingStack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -Header.horizontalInset
            ),
            headerControlsStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Header.horizontalInset
            ),
            headerControlsStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Header.horizontalInset
            ),
            headerControlsStack.topAnchor.constraint(
                equalTo: headerLeadingStack.bottomAnchor,
                constant: Header.rowSpacing
            ),
            compactSearchMinimumWidth,
            scrollView.topAnchor.constraint(
                equalTo: headerControlsStack.bottomAnchor,
                constant: Header.contentSpacing
            ),
        ]
        updateSpaceIndicator(spaces: SpaceManager.shared.spaces)
    }

    private func updateHeaderLayoutIfNeeded() {
        guard view.bounds.width > 0 else { return }
        let shouldUseCompactLayout = view.bounds.width < Header.compactLayoutWidth
        if shouldUseCompactLayout != usesCompactHeaderLayout {
            if let usesCompactHeaderLayout {
                NSLayoutConstraint.deactivate(
                    usesCompactHeaderLayout ? compactHeaderConstraints : wideHeaderConstraints
                )
            }
            NSLayoutConstraint.activate(
                shouldUseCompactLayout ? compactHeaderConstraints : wideHeaderConstraints
            )
            usesCompactHeaderLayout = shouldUseCompactLayout
        }

        let shouldUseUltraCompactLayout = view.bounds.width < Header.ultraCompactLayoutWidth
        guard shouldUseUltraCompactLayout != usesUltraCompactHeaderLayout else { return }
        usesUltraCompactHeaderLayout = shouldUseUltraCompactLayout
        titleLabel.setContentCompressionResistancePriority(
            shouldUseUltraCompactLayout ? .defaultHigh : .required,
            for: .horizontal
        )
        newFolderButton.setContentCompressionResistancePriority(
            shouldUseUltraCompactLayout ? .defaultHigh : .required,
            for: .horizontal
        )
        if shouldUseUltraCompactLayout {
            newFolderButton.title = ""
            newFolderButton.image = NSImage(
                systemSymbolName: "folder.badge.plus",
                accessibilityDescription: newFolderButtonTitle
            )
            newFolderButton.toolTip = newFolderButtonTitle
        } else {
            newFolderButton.title = newFolderButtonTitle
            newFolderButton.image = nil
            newFolderButton.toolTip = nil
        }
    }

    private func configureOutlineView() {
        let websiteColumn = NSTableColumn(identifier: Column.website)
        websiteColumn.title = NSLocalizedString(
            "bookmarkManager.column.websiteTitle",
            value: "Website",
            comment: "Bookmark manager - Header for the bookmark name column"
        )
        websiteColumn.minWidth = Column.minimumWidth
        websiteColumn.width = Column.minimumWidth
        websiteColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let addressColumn = NSTableColumn(identifier: Column.address)
        addressColumn.title = NSLocalizedString(
            "bookmarkManager.column.addressTitle",
            value: "Address",
            comment: "Bookmark manager - Header for the bookmark address column"
        )
        addressColumn.minWidth = Column.minimumWidth
        addressColumn.width = Column.minimumWidth
        addressColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        outlineView.addTableColumn(websiteColumn)
        outlineView.addTableColumn(addressColumn)
        outlineView.outlineTableColumn = websiteColumn
        outlineView.headerView = NSTableHeaderView()
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.rowHeight = Row.regularHeight
        outlineView.indentationPerLevel = 18
        outlineView.intercellSpacing = .zero
        outlineView.gridStyleMask = .solidHorizontalGridLineMask
        outlineView.gridColor = .separatorColor
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.autoresizingMask = [.width]
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineDoubleClicked(_:))
        outlineView.registerForDraggedTypes([.phiBookmark, .bookmarks, .sourceWindowId])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        outlineView.deleteSelectionHandler = { [weak self] in
            self?.requestDelete(guids: self?.selectedBookmarkGuids() ?? [])
        }
    }

    private func configureInitialColumnWidthsIfNeeded() {
        guard !didConfigureInitialColumnWidths,
              scrollView.contentSize.width > 0,
              let websiteColumn = outlineView.tableColumn(withIdentifier: Column.website),
              let addressColumn = outlineView.tableColumn(withIdentifier: Column.address) else {
            return
        }

        outlineView.sizeLastColumnToFit()
        let totalWidth = websiteColumn.width + addressColumn.width
        let maximumDifference = max(0, totalWidth - Column.minimumWidth * 2)
        let widthDifference = min(Column.defaultWidthDifference, maximumDifference)

        // Uniform autoresizing preserves this initial difference while both
        // columns continue to grow and shrink with the container.
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        websiteColumn.width = (totalWidth - widthDifference) / 2
        addressColumn.width = totalWidth - websiteColumn.width
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        didConfigureInitialColumnWidths = true
    }

    private func bindModel() {
        SpaceManager.shared.$spaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spaces in
                self?.updateSpaceIndicator(spaces: spaces)
            }
            .store(in: &cancellables)

        manager.$rootFolder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildProjection(animated: true)
            }
            .store(in: &cancellables)

        browserState.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.searchField.needsDisplay = true
                self.updateSpaceIndicator(spaces: SpaceManager.shared.spaces)
            }
            .store(in: &cancellables)
    }

    private func updateSpaceIndicator(spaces: [SpaceModel]) {
        let userSpaceCount = spaces.lazy.filter {
            !SpaceManager.isIncognitoSpaceId($0.spaceId) && !$0.isAgentSpace
        }.count
        guard userSpaceCount > 1,
              let currentSpace = spaces.first(where: { $0.spaceId == scope.spaceId }) else {
            spaceIndicatorView.isHidden = true
            return
        }

        spaceIndicatorImageView.image = SpaceIconView.menuImage(for: currentSpace.iconName)
        spaceIndicatorLabel.stringValue = currentSpace.name
        spaceIndicatorView.isHidden = false
    }

    private func rebuildProjection(animated: Bool, completion: (() -> Void)? = nil) {
        guard isViewLoaded else { return }
        let selectedGuids = selectedBookmarkGuids()
        let next = BookmarkManagerProjection.make(
            scope: scope,
            rootBookmarks: manager.rootFolder.children,
            searchText: searchField.stringValue,
            previous: projection
        )
        projectionGeneration += 1
        let generation = projectionGeneration
        let usesFullReload = isSearchMode(projection?.mode) || isSearchMode(next.mode)
        if usesFullReload {
            outlineView.resetDiffableSnapshot()
        }

        outlineView.reloadWith(
            next.snapshot,
            animated: usesFullReload ? false : animated,
            updateDataSource: { [weak self] in
                guard let self else { return }
                self.projection = next
                self.updateEmptyState(for: next)
            },
            completion: { [weak self] in
                guard let self, self.projectionGeneration == generation else { return }
                self.restoreExpandedFolders()
                self.restoreSelection(guids: selectedGuids)
                self.beginPendingEditIfPossible()
                completion?()
            }
        )
    }

    private func isSearchMode(_ mode: BookmarkManagerProjection.Mode?) -> Bool {
        guard let mode else { return false }
        switch mode {
        case .tree:
            return false
        case .search:
            return true
        }
    }

    private func updateEmptyState(for projection: BookmarkManagerProjection) {
        let isEmpty = projection.rootIDs.isEmpty
        scrollView.isHidden = isEmpty
        emptyLabel.isHidden = !isEmpty
        guard isEmpty else { return }
        switch projection.mode {
        case .tree:
            emptyLabel.stringValue = NSLocalizedString(
                "bookmarkManager.emptyState.message",
                value: "No bookmarks in this Space",
                comment: "Bookmark manager - Empty state when the current Space has no bookmarks"
            )
        case .search:
            emptyLabel.stringValue = NSLocalizedString(
                "bookmarkManager.search.emptyState",
                value: "No matching bookmarks",
                comment: "Bookmark manager - Empty state when a search has no results"
            )
        }
    }

    private func restoreExpandedFolders() {
        guard projection?.mode == .tree else { return }
        for bookmark in manager.getAllBookmarks() where bookmark.isFolder && bookmark.isExpanded {
            outlineView.expandItem(bookmark)
        }
    }

    private func restoreSelection(guids: [String]) {
        let selected = Set(guids)
        var indexes = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            guard let bookmark = outlineView.item(atRow: row) as? Bookmark,
                  selected.contains(bookmark.guid) else { continue }
            indexes.insert(row)
        }
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func selectedBookmarkGuids() -> [String] {
        outlineView.selectedRowIndexes.compactMap { row in
            (outlineView.item(atRow: row) as? Bookmark)?.guid
        }
    }

    private func bookmarks(for guids: [String]) -> [Bookmark] {
        var seen = Set<String>()
        return guids.compactMap { guid in
            guard seen.insert(guid).inserted else { return nil }
            return manager.bookmark(withGuid: guid)
        }
    }

    private func rootBookmarks(for guids: [String]) -> [Bookmark] {
        let candidates = bookmarks(for: guids)
        let selected = Set(candidates.map(\.guid))
        return candidates.filter { bookmark in
            var parent = bookmark.parent
            while let current = parent {
                if selected.contains(current.guid) { return false }
                parent = current.parent
            }
            return true
        }
    }

    private func startEditing(guid: String, column: BookmarkManagerCellView.Column) {
        guard let bookmark = manager.bookmark(withGuid: guid) else { return }
        let row = outlineView.row(forItem: bookmark)
        guard row >= 0 else { return }
        let columnIndex = column == .website ? 0 : 1
        let cell = outlineView.view(atColumn: columnIndex, row: row, makeIfNecessary: true)
            as? BookmarkManagerCellView
        cell?.beginEditing()
    }

    private func beginPendingEditIfPossible() {
        guard let guid = pendingEditGuid,
              let bookmark = manager.bookmark(withGuid: guid) else { return }
        let ancestorGuids = ancestorFolderGuids(for: bookmark)
        for ancestorGuid in ancestorGuids {
            guard let folder = manager.bookmark(withGuid: ancestorGuid) else { continue }
            folder.isExpanded = true
            outlineView.expandItem(folder)
        }
        pendingEditGuid = nil
        DispatchQueue.main.async { [weak self] in
            self?.revealBookmark(guid: guid, ancestorGuids: ancestorGuids)
            self?.startEditing(guid: guid, column: .website)
        }
    }

    @objc private func createFolderFromHeader(_ sender: Any?) {
        let selected = bookmarks(for: selectedBookmarkGuids())
        let parent = selected.count == 1 && selected[0].isFolder ? selected[0] : nil
        createFolder(in: parent, targetIndex: parent == nil ? nil : 0)
    }

    private func createFolder(in parent: Bookmark?, targetIndex: Int? = nil) {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            rebuildProjection(animated: true)
        }
        let guid = UUID().uuidString
        pendingEditGuid = guid
        parent?.isExpanded = true
        manager.addFolder(
            title: NSLocalizedString(
                "sidebar.bookmarkFolder.defaultName",
                value: "Untitled",
                comment: "Default name for new bookmark folder"
            ),
            to: parent,
            guid: guid,
            targetIndex: targetIndex
        )
        analyticsSession.markEdited()
    }

    @objc private func outlineDoubleClicked(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0, let bookmark = sender.item(atRow: row) as? Bookmark else { return }
        if bookmark.isFolder {
            sender.isItemExpanded(bookmark) ? sender.collapseItem(bookmark) : sender.expandItem(bookmark)
            return
        }
        let isSplit = bookmark.secondaryUrl?.isEmpty == false
        if sender.clickedColumn == 1, !isSplit {
            startEditing(guid: bookmark.guid, column: .address)
            return
        }
        browserState.openBookmark(bookmark)
    }

    private func makeContextMenu() -> NSMenu? {
        let guids = selectedBookmarkGuids()
        let selected = bookmarks(for: guids)
        guard !selected.isEmpty else { return nil }

        let menu = NSMenu()
        if selected.count > 1 {
            appendMultiSelectionActions(to: menu, guids: guids, bookmarks: selected)
            appendSpaceTransferMenus(to: menu, guids: guids, isMultiple: true)
            appendDeleteItem(to: menu, bookmarks: selected, isMultiple: true)
            return menu
        }

        guard let bookmark = selected.first else { return nil }
        if bookmark.isFolder {
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "sidebar.bookmarkContextMenu.renameAction",
                    value: "Rename...",
                    comment: "Bookmark Rename menu item"
                ),
                action: #selector(renameMenuItem(_:)),
                context: BookmarkActionContext(guids: [bookmark.guid])
            ))
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "sidebar.bookmarkContextMenu.newNestedFolderAction",
                    value: "New Nested Folder...",
                    comment: "Bookmark New Folder menu item"
                ),
                action: #selector(newNestedFolderMenuItem(_:)),
                context: BookmarkActionContext(guids: [bookmark.guid])
            ))
        } else {
            if let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty {
                let isStacked = (bookmark.layout ?? .vertical) == .horizontal
                if let primaryURL = bookmark.url {
                    menu.addItem(copyItem(
                        title: isStacked
                            ? NSLocalizedString(
                                "sidebar.bookmarkContextMenu.copyTopPrimaryUrl",
                                value: "Copy Top URL",
                                comment: "Bookmark context menu - Copy the top (primary) URL of a stacked split-view bookmark"
                            )
                            : NSLocalizedString(
                                "sidebar.bookmarkContextMenu.copyLeftPrimaryUrl",
                                value: "Copy Left URL",
                                comment: "Bookmark context menu - Copy the left (primary) URL of a side-by-side split-view bookmark"
                            ),
                        url: primaryURL
                    ))
                }
                menu.addItem(copyItem(
                    title: isStacked
                        ? NSLocalizedString(
                            "sidebar.bookmarkContextMenu.copyBottomSecondaryUrl",
                            value: "Copy Bottom URL",
                            comment: "Bookmark context menu - Copy the bottom (secondary) URL of a stacked split-view bookmark"
                        )
                        : NSLocalizedString(
                            "sidebar.bookmarkContextMenu.copyRightSecondaryUrl",
                            value: "Copy Right URL",
                            comment: "Bookmark context menu - Copy the right (secondary) URL of a side-by-side split-view bookmark"
                        ),
                    url: secondaryURL
                ))
            } else if let url = bookmark.url {
                menu.addItem(copyItem(
                    title: NSLocalizedString(
                        "sidebar.bookmarkContextMenu.copyLinkAction",
                        value: "Copy Link",
                        comment: "Bookmark Copy Link menu item"
                    ),
                    url: url
                ))
            }

            if bookmark.secondaryUrl?.isEmpty != false {
                menu.addItem(actionItem(
                    title: NSLocalizedString(
                        "sidebar.bookmarkContextMenu.renameAction",
                        value: "Rename...",
                        comment: "Bookmark Rename menu item"
                    ),
                    action: #selector(renameMenuItem(_:)),
                    context: BookmarkActionContext(guids: [bookmark.guid])
                ))
            }
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "sidebar.bookmarkContextMenu.editAction",
                    value: "Edit...",
                    comment: "Edit bookmark url menu item title"
                ),
                action: #selector(editMenuItem(_:)),
                context: BookmarkActionContext(guids: [bookmark.guid])
            ))
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "sidebar.bookmarkContextMenu.openInNewTabAction",
                    value: "Open in New Tab",
                    comment: "Open in New Tab menu item"
                ),
                action: #selector(openInNewTabMenuItem(_:)),
                context: BookmarkActionContext(guids: [bookmark.guid])
            ))
            if isSearchMode(projection?.mode) {
                menu.addItem(actionItem(
                    title: NSLocalizedString(
                        "bookmarkManager.contextMenu.showInFolderAction",
                        value: "Show in Folder",
                        comment: "Bookmark manager context menu - Reveal a bookmark search result in its containing folder"
                    ),
                    action: #selector(showInFolderMenuItem(_:)),
                    context: BookmarkActionContext(guids: [bookmark.guid])
                ))
            }
        }

        appendSpaceTransferMenus(to: menu, guids: guids, isMultiple: false)
        appendDeleteItem(to: menu, bookmarks: selected, isMultiple: false)
        return menu
    }

    private func appendMultiSelectionActions(
        to menu: NSMenu,
        guids: [String],
        bookmarks: [Bookmark]
    ) {
        let roots = rootBookmarks(for: guids)
        if roots.contains(where: { !$0.isFolder }) {
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "common.tabMultiSelectionContextMenu.duplicateTabsAction",
                    value: "Duplicate Tabs",
                    comment: "Tab multi-selection context menu - duplicate all selected tabs"
                ),
                action: #selector(duplicateBookmarksMenuItem(_:)),
                context: BookmarkActionContext(guids: guids)
            ))
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "common.tabMultiSelectionContextMenu.copyLinksAction",
                    value: "Copy Links",
                    comment: "Tab multi-selection context menu - copy links of all selected tabs"
                ),
                action: #selector(copyBookmarkLinksMenuItem(_:)),
                context: BookmarkActionContext(guids: guids)
            ))
        }

        guard !bookmarks.contains(where: \.isFolder) else { return }
        appendSeparatorIfNeeded(to: menu)

        if browserState.canCreateGroupFromBookmarks(bookmarkGuids: guids) {
            menu.addItem(actionItem(
                title: NSLocalizedString(
                    "common.tabMultiSelectionContextMenu.addToNewGroupAction",
                    value: "Add Tabs to New Group",
                    comment: "Tab multi-selection context menu - create a new tab group from selected tabs"
                ),
                action: #selector(createGroupFromBookmarksMenuItem(_:)),
                context: BookmarkActionContext(guids: guids)
            ))
        }

        let groups = orderedGroupsInStripOrder().filter {
            browserState.canAddBookmarks(bookmarkGuids: guids, toGroup: $0.token)
        }
        guard !groups.isEmpty else { return }
        let parent = NSMenuItem(
            title: NSLocalizedString(
                "common.tabMultiSelectionContextMenu.moveToGroupSubmenu",
                value: "Move Tabs to Group",
                comment: "Tab multi-selection context menu - submenu to move selected tabs to an existing tab group"
            ),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        for group in groups {
            let memberCount = browserState.normalTabs.lazy.filter { $0.groupToken == group.token }.count
            let item = actionItem(
                title: group.displayTitle(memberCount: memberCount),
                action: #selector(addBookmarksToGroupMenuItem(_:)),
                context: GroupActionContext(guids: guids, groupToken: group.token)
            )
            item.image = NSImage.tabGroupColorSwatch(for: group.color)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func orderedGroupsInStripOrder() -> [WebContentGroupInfo] {
        var seen = Set<String>()
        var ordered: [WebContentGroupInfo] = []
        for tab in browserState.normalTabs {
            guard let token = tab.groupToken,
                  seen.insert(token).inserted,
                  let group = browserState.groups[token] else { continue }
            ordered.append(group)
        }
        return ordered
    }

    private func actionItem(
        title: String,
        action: Selector,
        context: Any
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = context
        return item
    }

    private func copyItem(title: String, url: String) -> NSMenuItem {
        actionItem(
            title: title,
            action: #selector(copyURLMenuItem(_:)),
            context: CopyActionContext(url: url)
        )
    }

    private func appendSpaceTransferMenus(to menu: NSMenu, guids: [String], isMultiple: Bool) {
        let spaces = SpaceManager.shared.spaces
        let moveTargets = spaces.filter { browserState.canMoveBookmarks(bookmarkGuids: guids, to: $0) }
        let cloneTargets = spaces.filter { browserState.canCloneBookmarks(bookmarkGuids: guids, to: $0) }
        guard !moveTargets.isEmpty || !cloneTargets.isEmpty else { return }

        appendSeparatorIfNeeded(to: menu)
        if !moveTargets.isEmpty {
            appendSpaceSubmenu(
                to: menu,
                title: NSLocalizedString(
                    isMultiple
                        ? "common.tabMultiSelectionContextMenu.moveToSpaceSubmenu"
                        : "sidebar.bookmarkContextMenu.moveToSpaceSubmenu",
                    value: "Move to Space",
                    comment: isMultiple
                        ? "Tab multi-selection context menu - Submenu to move selected tabs and bookmarks to another Space"
                        : "Bookmark context menu - Submenu to move this bookmark or folder to another Space"
                ),
                spaces: moveTargets,
                guids: guids,
                action: #selector(moveToSpaceMenuItem(_:))
            )
        }
        if !cloneTargets.isEmpty {
            appendSpaceSubmenu(
                to: menu,
                title: NSLocalizedString(
                    isMultiple
                        ? "common.tabMultiSelectionContextMenu.cloneToSpaceSubmenu"
                        : "sidebar.bookmarkContextMenu.cloneToSpaceSubmenu",
                    value: "Clone to Space",
                    comment: isMultiple
                        ? "Tab multi-selection context menu - Submenu to clone selected tabs and bookmarks to another Space"
                        : "Bookmark context menu - Submenu to clone this bookmark or folder to another Space"
                ),
                spaces: cloneTargets,
                guids: guids,
                action: #selector(cloneToSpaceMenuItem(_:))
            )
        }
    }

    private func appendSpaceSubmenu(
        to menu: NSMenu,
        title: String,
        spaces: [SpaceModel],
        guids: [String],
        action: Selector
    ) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for space in spaces {
            let item = actionItem(
                title: space.name,
                action: action,
                context: SpaceTransferActionContext(guids: guids, targetSpaceId: space.spaceId)
            )
            item.image = SpaceIconView.menuImage(for: space.iconName)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func appendSeparatorIfNeeded(to menu: NSMenu) {
        guard !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true else { return }
        menu.addItem(.separator())
    }

    private func appendDeleteItem(
        to menu: NSMenu,
        bookmarks: [Bookmark],
        isMultiple: Bool
    ) {
        if isMultiple {
            appendSeparatorIfNeeded(to: menu)
        } else if menu.items.last?.submenu != nil {
            menu.addItem(.separator())
        }
        let title: String
        if isMultiple {
            title = multiSelectionDeleteTitle(bookmarks: bookmarks)
        } else {
            title = NSLocalizedString(
                "sidebar.bookmarkContextMenu.deleteAction",
                value: "Delete",
                comment: "Delete bookmark menu item"
            )
        }
        let item = actionItem(
            title: title,
            action: #selector(deleteMenuItem(_:)),
            context: BookmarkActionContext(guids: bookmarks.map(\.guid))
        )
        if isMultiple {
            item.keyEquivalent = "d"
            item.keyEquivalentModifierMask = [.command]
        }
        menu.addItem(item)
    }

    private func multiSelectionDeleteTitle(bookmarks: [Bookmark]) -> String {
        let folderCount = bookmarks.filter(\.isFolder).count
        let bookmarkCount = bookmarks.count - folderCount
        if folderCount > 0, bookmarkCount == 0 {
            let format = folderCount == 1
                ? NSLocalizedString(
                    "common.tabMultiSelectionContextMenu.deleteSingleFolderAction",
                    value: "Delete %d Folder",
                    comment: "Tab multi-selection context menu - delete selected bookmark folder"
                )
                : NSLocalizedString(
                    "common.tabMultiSelectionContextMenu.deleteMultipleFoldersAction",
                    value: "Delete %d Folders",
                    comment: "Tab multi-selection context menu - delete selected bookmark folders"
                )
            return String(format: format, folderCount)
        }
        if bookmarkCount > 0, folderCount == 0 {
            let format = bookmarkCount == 1
                ? NSLocalizedString(
                    "common.tabMultiSelectionContextMenu.deleteSingleBookmarkAction",
                    value: "Delete %d Bookmark",
                    comment: "Tab multi-selection context menu - delete selected bookmark"
                )
                : NSLocalizedString(
                    "common.tabMultiSelectionContextMenu.deleteMultipleBookmarksAction",
                    value: "Delete %d Bookmarks",
                    comment: "Tab multi-selection context menu - delete selected bookmarks"
                )
            return String(format: format, bookmarkCount)
        }
        let totalCount = folderCount + bookmarkCount
        let format = totalCount == 1
            ? NSLocalizedString(
                "common.tabMultiSelectionContextMenu.deleteSingleItemAction",
                value: "Delete %d Item",
                comment: "Tab multi-selection context menu - delete selected bookmark item"
            )
            : NSLocalizedString(
                "common.tabMultiSelectionContextMenu.deleteMultipleItemsAction",
                value: "Delete %d Items",
                comment: "Tab multi-selection context menu - delete selected bookmark items"
            )
        return String(format: format, totalCount)
    }

    @objc private func openInNewTabMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext,
              let bookmark = bookmarks(for: context.guids).first,
              !bookmark.isFolder,
              let primaryURL = bookmark.url,
              !primaryURL.isEmpty else { return }
        if let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty {
            browserState.openTwoURLsAsSplit(primaryURL: primaryURL, secondaryURL: secondaryURL)
        } else {
            browserState.createTab(primaryURL)
        }
    }

    @objc private func showInFolderMenuItem(_ sender: NSMenuItem) {
        guard isSearchMode(projection?.mode),
              let context = sender.representedObject as? BookmarkActionContext,
              let guid = context.guids.first,
              let bookmark = manager.bookmark(withGuid: guid),
              !bookmark.isFolder else { return }

        let ancestorGuids = ancestorFolderGuids(for: bookmark)
        for ancestorGuid in ancestorGuids {
            manager.bookmark(withGuid: ancestorGuid)?.isExpanded = true
        }
        searchField.stringValue = ""
        rebuildProjection(animated: false) { [weak self] in
            self?.revealBookmark(guid: guid, ancestorGuids: ancestorGuids)
        }
    }

    private func ancestorFolderGuids(for bookmark: Bookmark) -> [String] {
        var ancestorGuids: [String] = []
        var parent = bookmark.parent
        while let candidate = parent {
            if candidate.isFolder, manager.bookmark(withGuid: candidate.guid) != nil {
                ancestorGuids.append(candidate.guid)
            }
            parent = candidate.parent
        }
        return Array(ancestorGuids.reversed())
    }

    private func revealBookmark(guid: String, ancestorGuids: [String]) {
        for ancestorGuid in ancestorGuids {
            guard let folder = manager.bookmark(withGuid: ancestorGuid), folder.isFolder else { continue }
            folder.isExpanded = true
            outlineView.expandItem(folder)
        }
        guard let bookmark = manager.bookmark(withGuid: guid) else { return }
        let row = outlineView.row(forItem: bookmark)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        view.window?.makeFirstResponder(outlineView)
    }

    @objc private func copyURLMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? CopyActionContext else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            URLProcessor.phiBrandEnsuredUrlString(context.url),
            forType: .string
        )
    }

    @objc private func duplicateBookmarksMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext else { return }
        browserState.duplicateBookmarks(bookmarkGuids: context.guids)
    }

    @objc private func copyBookmarkLinksMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext else { return }
        browserState.copyBookmarkLinks(bookmarkGuids: context.guids)
    }

    @objc private func createGroupFromBookmarksMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext else { return }
        if browserState.createGroupFromBookmarks(bookmarkGuids: context.guids) {
            analyticsSession.markEdited()
        }
    }

    @objc private func addBookmarksToGroupMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? GroupActionContext else { return }
        if browserState.addBookmarks(bookmarkGuids: context.guids, toGroup: context.groupToken) {
            analyticsSession.markEdited()
        }
    }

    @objc private func renameMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext,
              let bookmark = bookmarks(for: context.guids).first,
              bookmark.secondaryUrl?.isEmpty != false else { return }
        startEditing(guid: bookmark.guid, column: .website)
    }

    @objc private func editMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext,
              let bookmark = bookmarks(for: context.guids).first,
              !bookmark.isFolder else { return }
        presentBookmarkEditor(for: bookmark)
    }

    @objc private func newNestedFolderMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext,
              let folder = bookmarks(for: context.guids).first,
              folder.isFolder else { return }
        createFolder(in: folder)
    }

    @objc private func moveToSpaceMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? SpaceTransferActionContext else { return }
        if browserState.moveBookmarks(
            bookmarkGuids: context.guids,
            toSpaceId: context.targetSpaceId
        ) {
            analyticsSession.markEdited()
        }
    }

    @objc private func cloneToSpaceMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? SpaceTransferActionContext else { return }
        if browserState.cloneBookmarks(
            bookmarkGuids: context.guids,
            toSpaceId: context.targetSpaceId
        ) {
            analyticsSession.markEdited()
        }
    }

    @objc private func deleteMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? BookmarkActionContext else { return }
        requestDelete(guids: context.guids)
    }

    private func presentBookmarkEditor(for bookmark: Bookmark) {
        let bookmarkGuid = bookmark.guid
        let originalTitle = bookmark.title
        let originalURL = bookmark.url
        let originalParentGuid = bookmark.parent?.guid
        let originalSecondaryURL = bookmark.secondaryUrl
        let originalSecondaryTitle = bookmark.secondaryTitle
        EditPinnedTabPresenter.presentModal(
            mode: .bookmark,
            title: bookmark.title,
            urlString: bookmark.url ?? "",
            secondaryUrlString: originalSecondaryURL,
            secondaryTitleString: bookmark.secondaryTitle,
            modelContainer: browserState.localStore.container,
            profileId: scope.profileId,
            spaceId: scope.spaceId,
            initialFolderGuid: originalParentGuid,
            from: view.window,
            onCreateFolder: { [weak self] folderName in
                guard let self else { return nil }
                let guid = UUID().uuidString
                self.browserState.localStore.createDirectory(
                    title: folderName,
                    profileId: self.scope.profileId,
                    parentId: nil,
                    guid: guid,
                    spaceId: self.scope.spaceId
                )
                self.analyticsSession.markEdited()
                return guid
            },
            onValidate: { [weak self] result in
                guard let self,
                      let primaryURL = result.url,
                      self.browserState.localStore.normalizedURL(from: primaryURL) != nil else {
                    NSSound.beep()
                    return false
                }
                if originalSecondaryURL != nil {
                    guard let secondaryURL = result.secondaryUrl,
                          self.browserState.localStore.normalizedURL(from: secondaryURL) != nil else {
                        NSSound.beep()
                        return false
                    }
                }
                return true
            }
        ) { [weak self] result in
            guard let self else { return }
            let secondaryURLUpdate: String?? = originalSecondaryURL == nil
                ? nil
                : .some(result.secondaryUrl ?? "")
            let secondaryTitleUpdate: String?? = originalSecondaryURL == nil
                ? nil
                : .some(result.secondaryTitle ?? "")
            self.manager.updateBookmark(
                guid: bookmarkGuid,
                title: result.title,
                url: result.url,
                secondaryUrl: secondaryURLUpdate,
                secondaryTitle: secondaryTitleUpdate
            )
            let didUpdateFields = result.title != originalTitle
                || result.url != originalURL
                || (originalSecondaryURL != nil && result.secondaryUrl != originalSecondaryURL)
                || (originalSecondaryURL != nil && result.secondaryTitle != originalSecondaryTitle)
            if didUpdateFields {
                self.analyticsSession.markEdited()
            }
            guard result.parentFolderGuid != originalParentGuid else { return }
            if let targetGuid = result.parentFolderGuid {
                if let target = self.manager.bookmark(withGuid: targetGuid) {
                    if self.browserState.moveSelectedBookmarks(
                        bookmarkGuids: [bookmarkGuid],
                        to: target,
                        index: Int.max
                    ) {
                        self.analyticsSession.markEdited()
                    }
                } else {
                    self.browserState.localStore.moveBookmark(
                        bookmarkGuid,
                        profileId: self.scope.profileId,
                        to: targetGuid,
                        newIndex: Int.max
                    )
                    self.analyticsSession.markEdited()
                }
                return
            }
            if self.browserState.moveSelectedBookmarks(
                bookmarkGuids: [bookmarkGuid],
                to: nil,
                index: Int.max
            ) {
                self.analyticsSession.markEdited()
            }
        }
    }

    private func requestDelete(guids: [String]) {
        let roots = rootBookmarks(for: guids)
        guard !roots.isEmpty else { return }
        let requiresConfirmation = roots.count > 1 || roots.contains(where: \.isFolder)
        guard requiresConfirmation else {
            roots.forEach(manager.removeBookmark)
            analyticsSession.markEdited()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "bookmarkManager.deleteConfirmation.title",
            value: "Delete selected bookmarks?",
            comment: "Bookmark manager - Title of the confirmation shown before deleting multiple bookmarks or a folder"
        )
        alert.informativeText = NSLocalizedString(
            "bookmarkManager.deleteConfirmation.message",
            value: "Folders and everything inside them will be removed.",
            comment: "Bookmark manager - Explanation shown before deleting bookmark folders"
        )
        alert.addButton(withTitle: NSLocalizedString(
            "bookmarkManager.deleteConfirmation.deleteAction",
            value: "Delete",
            comment: "Bookmark manager delete confirmation - Destructive button title"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "bookmarkManager.deleteConfirmation.cancelAction",
            value: "Cancel",
            comment: "Bookmark manager delete confirmation - Cancel button title"
        ))

        let commit = { [weak self] in
            guard let self else { return }
            var didDelete = false
            for root in roots {
                guard let current = self.manager.bookmark(withGuid: root.guid) else { continue }
                self.manager.removeBookmark(current)
                didDelete = true
            }
            if didDelete {
                self.analyticsSession.markEdited()
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { commit() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            commit()
        }
    }

    private func dropTarget(item: Any?, childIndex: Int) -> BookmarkManagerDropTarget? {
        if childIndex == NSOutlineViewDropOnItemIndex {
            guard let folder = item as? Bookmark, folder.isFolder else { return nil }
            return .onFolder(guid: folder.guid)
        }
        if let folder = item as? Bookmark, folder.isFolder {
            return .betweenSiblings(parentGuid: folder.guid, index: childIndex)
        }
        if item == nil {
            return .atRoot(index: childIndex)
        }
        return nil
    }

    private func dropResolution(
        info: NSDraggingInfo,
        item: Any?,
        childIndex: Int
    ) -> BookmarkManagerDropResolution? {
        let pasteboard = info.draggingPasteboard
        guard pasteboard.string(forType: .sourceWindowId) == String(browserState.windowId),
              let target = dropTarget(item: item, childIndex: childIndex) else {
            return nil
        }
        var guids = pasteboard.phiBookmarkGuids()
        if guids.isEmpty, let guid = pasteboard.string(forType: .phiBookmark) {
            guids = [guid]
        }
        return BookmarkManagerDropResolver.resolve(
            orderedBookmarkGuids: guids,
            target: target,
            rootFolder: manager.rootFolder,
            isSearchActive: projection?.mode != .tree
        )
    }
}

extension BookmarkManagerViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        rebuildProjection(animated: false)
    }
}

extension BookmarkManagerViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let projection else { return 0 }
        if let bookmark = item as? Bookmark {
            return projection.snapshot.childIDs(of: AnyHashable(projection.itemID(for: bookmark))).count
        }
        return projection.snapshot.rootIDs.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let projection else { return manager.rootFolder }
        let ids: [AnyHashable]
        if let bookmark = item as? Bookmark {
            ids = projection.snapshot.childIDs(of: AnyHashable(projection.itemID(for: bookmark)))
        } else {
            ids = projection.snapshot.rootIDs
        }
        guard ids.indices.contains(index), let child = projection.snapshot.item(for: ids[index]) else {
            return manager.rootFolder
        }
        return child
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard projection?.mode == .tree, let bookmark = item as? Bookmark else { return false }
        return bookmark.isFolder
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let bookmark = item as? Bookmark else { return nil }
        let row = outlineView.row(forItem: bookmark)
        let selected = row >= 0 && outlineView.selectedRowIndexes.contains(row)
        let guids = selected ? selectedBookmarkGuids() : [bookmark.guid]
        guard !guids.isEmpty else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(guids[0], forType: .phiBookmark)
        pasteboardItem.setString(guids.joined(separator: ","), forType: .bookmarks)
        pasteboardItem.setString(String(browserState.windowId), forType: .sourceWindowId)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard case .move = dropResolution(info: info, item: item, childIndex: index) else {
            return []
        }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard case .move(let plan) = dropResolution(
            info: info,
            item: item,
            childIndex: index
        ) else { return false }
        let targetFolder = plan.destinationParentGuid.flatMap {
            manager.bookmark(withGuid: $0)
        }
        let didMove = browserState.moveSelectedBookmarks(
            bookmarkGuids: plan.orderedBookmarkGuids,
            to: targetFolder,
            index: plan.destinationIndex
        )
        if didMove {
            analyticsSession.markEdited()
        }
        return didMove
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }
}

extension BookmarkManagerViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let bookmark = item as? Bookmark,
              bookmark.secondaryUrl?.isEmpty == false else {
            return Row.regularHeight
        }
        return Row.splitHeight
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let bookmark = item as? Bookmark,
              let identifier = tableColumn?.identifier else { return nil }
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self)
            as? BookmarkManagerCellView) ?? BookmarkManagerCellView(frame: .zero)
        cell.identifier = identifier
        if identifier == Column.website {
            cell.configure(
                bookmark: bookmark,
                scope: scope,
                column: .website,
                onCommit: { [weak self] title in
                    guard let self else { return false }
                    if title != bookmark.title {
                        self.manager.updateBookmark(guid: bookmark.guid, title: title)
                        self.analyticsSession.markEdited()
                    }
                    return true
                }
            )
        } else {
            cell.configure(
                bookmark: bookmark,
                scope: scope,
                column: .address,
                onCommit: bookmark.isFolder || bookmark.secondaryUrl?.isEmpty == false
                    ? nil
                    : { [weak self] url in
                        guard let self,
                              self.browserState.localStore.normalizedURL(from: url) != nil else {
                            return false
                        }
                        if url != bookmark.url {
                            self.manager.updateBookmark(guid: bookmark.guid, url: url)
                            self.analyticsSession.markEdited()
                        }
                        return true
                    }
            )
        }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? Bookmark)?.isExpanded = true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? Bookmark)?.isExpanded = false
    }
}
