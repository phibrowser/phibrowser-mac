// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import Kingfisher

class BookmarkBar: NSView {
    // MARK: - Properties
    private let state: BrowserState
    private var cancellables = Set<AnyCancellable>()
    private var isActive = false

    // Bookmarks currently rendered in the bar.
    private var bookmarks: [Bookmark] = []

    /// Read-only count used by the shared host when deciding visibility.
    var bookmarkCount: Int { state.bookmarkManager.rootFolder.children.count }

    // Bookmarks that overflow into the More menu.
    private var overflowBookmarks: [Bookmark] = []

    // Tracks the current drop index during drag-and-drop.
    private var lastDropIndex: Int = 0

    var showSeparator: Bool = false {
        didSet {
            separatorView.isHidden = !showSeparator
        }
    }
    var onBookmarksChanged: ((Int) -> Void)?

    // MARK: - Layout Constants
    private let barHeight: CGFloat = 32
    private let itemSpacing: CGFloat = 8
    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 4
    private let moreButtonWidth: CGFloat = 32
    private let faviconSize: CGFloat = 16

    // MARK: - Subviews
    /// Container for visible bookmark items.
    private lazy var stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = itemSpacing
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.detachesHiddenViews = true
        return stack
    }()

    /// Button that reveals overflow bookmarks.
    private lazy var moreButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(
                image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "More Bookmarks"),
                imageSize: NSSize(width: 14, height: 14),
                displayMode: .imageOnly,
                hoverBackgroundColor: .sidebarTabHoveredBackground,
                cornerRadius: 8
        )
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(showMoreMenu))
        button.isHidden = true
        return button
    }()

    /// Visual indicator for bookmark drag-and-drop.
    private lazy var dropIndicator: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.isHidden = true
        return view
    }()

    private lazy var separatorView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.separator)
        view.isHidden = showSeparator
        return view
    }()

    // MARK: - Initialization
    init(browserState: BrowserState) {
        self.state = browserState
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Data Binding
    func setActive(_ active: Bool) {
        if active {
            activate()
        } else {
            deactivate()
        }
    }

    private func activate() {
        guard isActive == false else { return }
        isActive = true
        bindData()
        syncCurrentState()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        cancellables.removeAll()
        clearRenderedBookmarks()
    }

    private func bindData() {
        cancellables.removeAll()
        state.bookmarkManager.$rootFolder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rootFolder in
                self?.updateBookmarks(rootFolder.children)
            }
            .store(in: &cancellables)

        state.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyThemeAppearance()
            }
            .store(in: &cancellables)
    }

    private func syncCurrentState() {
        updateBookmarks(state.bookmarkManager.rootFolder.children)
        applyThemeAppearance()
    }

    private func clearRenderedBookmarks() {
        bookmarks = []
        overflowBookmarks = []
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        moreButton.isHidden = true
        needsLayout = true
    }

    private func updateBookmarks(_ bookmarks: [Bookmark]) {
        self.bookmarks = bookmarks
        onBookmarksChanged?(bookmarkCount)
        AppLogDebug("Bookmarks updated bookmarks: \(bookmarkCount)")

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for bookmark in bookmarks {
            let itemView = BookmarkItemView(bookmark: bookmark)
            itemView.onClick = { [weak self] clickedBookmark in
                self?.handleBookmarkClick(clickedBookmark, itemView: itemView)
            }
            stackView.addArrangedSubview(itemView)
        }

        self.needsLayout = true
    }

    private func applyThemeAppearance() {
        phiLayer?.setBackgroundColor(ThemedColor.contentOverlayBackground)
        updateDropIndicatorColor()
    }

    private func updateDropIndicatorColor() {
        let theme = state.themeContext.currentTheme
        let appearance = state.themeContext.currentAppearance
        dropIndicator.layer?.backgroundColor = ThemedColor.themeColor
            .resolve(theme: theme, appearance: appearance)
            .cgColor
    }

    // MARK: -Setup
    private func setupUI() {
        wantsLayer = true
        layer?.masksToBounds = true
        applyThemeAppearance()

        addSubview(stackView)
        addSubview(dropIndicator)
        addSubview(moreButton)

        moreButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(moreButtonWidth)
        }
        stackView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(horizontalPadding)
            // make.trailing.lessThanOrEqualTo(moreButton.snp.leading).offset(-itemSpacing)
            make.top.bottom.equalToSuperview().inset(verticalPadding)
        }

        addSubview(separatorView)
        separatorView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(1)
        }

        // Also accept tabs and pinned tabs so the user can drag any tab from
        // the sidebar / tab strip onto the bar to create a bookmark. Split-
        // pair tabs become one split-view bookmark via
        // `BrowserState.addSplitBookmarkFromTab`.
        registerForDraggedTypes([.phiBookmark, .normalTab, .pinnedTab])
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func layout() {
        super.layout()

        let availableWidth = bounds.width
        let moreAreaWidth = moreButtonWidth + itemSpacing + horizontalPadding
        let maxDisplayWidth = availableWidth - moreAreaWidth

        var currentX: CGFloat = horizontalPadding
        var newOverflow: [Bookmark] = []

        let items = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }

        var hasOverflowed = false

        for item in items {
            let itemW = item.intrinsicContentSize.width

            if currentX + itemW > maxDisplayWidth {
                hasOverflowed = true
            }
            if hasOverflowed {
                item.isHidden = true
                newOverflow.append(item.bookmark)
            } else {
                item.isHidden = false
                currentX += (itemW + itemSpacing)
            }
        }

        self.overflowBookmarks = newOverflow
        self.moreButton.isHidden = newOverflow.isEmpty
    }

    // MARK: - Helper Methods
    private func createMenuItem(for bookmark: Bookmark) -> NSMenuItem {
        let item = NSMenuItem(title: bookmark.title, action: #selector(menuItemClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = bookmark

        if bookmark.isFolder {
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.submenu = createMenu(for: bookmark)
            return item
        }

        if let secondaryUrl = bookmark.secondaryUrl, !secondaryUrl.isEmpty {
            // Split-view bookmark: mirror the in-bar rendering so the folder
            // dropdown also reads as a split — combined "primary • secondary"
            // label and a dual favicon. Without this, both panes collapse to a
            // single globe icon and the menu looks like a plain bookmark.
            let secondaryDisplay = Self.displayName(forSecondaryTitle: bookmark.secondaryTitle, url: secondaryUrl)
            item.title = secondaryDisplay.isEmpty ? bookmark.title : "\(bookmark.title) • \(secondaryDisplay)"
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            loadSplitFavicons(primaryUrl: bookmark.url, secondaryUrl: secondaryUrl) { [weak item] image in
                item?.image = image
            }
            return item
        }

        item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        loadFavicon(for: bookmark.url) { [weak item] image in
            guard let image = image else { return }
            DispatchQueue.main.async {
                image.size = NSSize(width: self.faviconSize, height: self.faviconSize)
                item?.image = image
            }
        }
        return item
    }

    /// Returns the best display label for the secondary pane: the stored title
    /// if present, otherwise the URL's host with any leading `www.` stripped.
    /// Mirrors `BookmarkItemView.displayName` so the folder dropdown and the
    /// in-bar item stay visually consistent.
    private static func displayName(forSecondaryTitle title: String?, url: String) -> String {
        if let title, !title.isEmpty { return title }
        guard let parsed = URL(string: url), let host = parsed.host else { return "" }
        if host.hasPrefix("www."), host.count > 4 {
            return String(host.dropFirst(4))
        }
        return host
    }

    /// Loads both favicons of a split bookmark and composes them into a single
    /// side-by-side image suitable for use as an `NSMenuItem.image`. Missing
    /// favicons fall back to the globe symbol so the layout slot still renders.
    private func loadSplitFavicons(primaryUrl: String?,
                                   secondaryUrl: String,
                                   completion: @escaping (NSImage) -> Void) {
        let iconSize = self.faviconSize
        loadFavicon(for: primaryUrl) { [weak self] primaryImage in
            self?.loadFavicon(for: secondaryUrl) { secondaryImage in
                DispatchQueue.main.async {
                    let composed = BookmarkBar.composeSplitFavicon(primary: primaryImage,
                                                                   secondary: secondaryImage,
                                                                   iconSize: iconSize)
                    completion(composed)
                }
            }
        }
    }

    /// Draws two favicons side-by-side with a 2pt gap (matches
    /// `BookmarkItemView`'s in-bar layout) into a single NSImage.
    private static func composeSplitFavicon(primary: NSImage?,
                                            secondary: NSImage?,
                                            iconSize: CGFloat) -> NSImage {
        let gap: CGFloat = 2
        let totalSize = NSSize(width: iconSize * 2 + gap, height: iconSize)
        let composed = NSImage(size: totalSize)
        let fallback = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        composed.lockFocus()
        (primary ?? fallback)?.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))
        (secondary ?? fallback)?.draw(in: NSRect(x: iconSize + gap, y: 0, width: iconSize, height: iconSize))
        composed.unlockFocus()
        return composed
    }

    private func createMenu(for folder: Bookmark) -> NSMenu {
        let menu = NSMenu(title: folder.title)
        menu.autoenablesItems = true
        for child in folder.children {
            let item = self.createMenuItem(for: child)
            menu.addItem(item)
        }
        return menu
    }

    private func loadFavicon(for urlString: String?, completion: @escaping (NSImage?) -> Void) {
        let defaultIcon = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
        guard let urlString = urlString, let url = URL(string: urlString) else {
            completion(defaultIcon)
            return
        }

        let provider = FaviconDataProvider(pageURL: url)
        let options: KingfisherOptionsInfo = [
            .cacheOriginalImage
        ]

        KingfisherManager.shared.retrieveImage(with: .provider(provider), options: options) { result in
            switch result {
            case .success(let value):
                completion(value.image)
            case .failure:
                completion(defaultIcon)
            }
        }
    }

    // MARK: - NSDraggingDestination
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        let types = pasteboard.types ?? []
        if types.contains(.phiBookmark) {
            return .move
        }
        if types.contains(.normalTab) || types.contains(.pinnedTab) {
            // Use `.copy` for tab → bookmark so the macOS drag cursor shows a
            // "+" badge: the existing tab keeps running and a new bookmark is
            // added on top.
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        let operation: NSDragOperation
        if types.contains(.phiBookmark) {
            operation = .move
        } else if types.contains(.normalTab) || types.contains(.pinnedTab) {
            operation = .copy
        } else {
            return []
        }

        let locationInStack = stackView.convert(sender.draggingLocation, from: nil)
        let visibleItems = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }.filter { !$0.isHidden }

        var targetX: CGFloat = horizontalPadding
        var insertIndex: Int = 0
        if visibleItems.isEmpty {
            targetX = horizontalPadding
            insertIndex = 0
        } else {
            var found = false
            for (index, item) in visibleItems.enumerated() {
                if locationInStack.x < (item.frame.minX + item.frame.width / 2) {
                    targetX = item.frame.minX - (itemSpacing / 2)
                    insertIndex = index
                    found = true
                    break
                }
            }

            if !found, let last = visibleItems.last {
                targetX = last.frame.maxX + (itemSpacing / 2)
                insertIndex = visibleItems.count
            }
        }
        self.lastDropIndex = insertIndex

        let targetPointInStack = CGPoint(x: targetX - 1, y: 0)
        let targetPointInBar = convert(targetPointInStack, from: stackView)

        dropIndicator.frame = CGRect(x: targetPointInBar.x, y: verticalPadding, width: 2, height: bounds.height - verticalPadding * 2)
        dropIndicator.isHidden = false
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true

        guard let pasteboardItem = sender.draggingPasteboard.pasteboardItems?.first else {
            return false
        }

        // Reorder existing bookmark — current behavior. Computed targetIndex
        // is *post-removal* because `moveBookmark` removes-then-inserts.
        if let guid = pasteboardItem.string(forType: .phiBookmark),
           let draggedBookmark = state.bookmarkManager.bookmark(withGuid: guid),
           let currentIndex = bookmarks.firstIndex(of: draggedBookmark) {
            var targetIndex = resolvedDropIndex()
            if targetIndex > currentIndex {
                targetIndex -= 1
            }
            state.bookmarkManager.moveBookmark(draggedBookmark, to: state.bookmarkManager.rootFolder, at: targetIndex)
            return true
        }

        // Tab → bookmark. Drop index here is an *insertion* index (pre-add),
        // so no off-by-one adjustment is needed.
        let sourceState = sourceBrowserState(for: sender.draggingPasteboard) ?? state
        let dropIndex = resolvedDropIndex()

        if let guidString = pasteboardItem.string(forType: .normalTab),
           let tabGuid = Int(guidString),
           let draggedTab = sourceState.tabs.first(where: { $0.guid == tabGuid }) {
            return performTabDrop(draggedTab, sourceState: sourceState, at: dropIndex)
        }

        if let pinnedGuid = pasteboardItem.string(forType: .pinnedTab) {
            return performPinnedTabDrop(pinnedGuid: pinnedGuid,
                                        sourceState: sourceState,
                                        at: dropIndex)
        }

        return false
    }

    /// Translates `lastDropIndex` (visible-row index) back into a position in
    /// the canonical `bookmarks` array used for insertion / move.
    private func resolvedDropIndex() -> Int {
        let visibleItems = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }.filter { !$0.isHidden }
        let hiddenItems = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }.filter { $0.isHidden }
        if lastDropIndex < visibleItems.count {
            let anchorBookmark = visibleItems[lastDropIndex].bookmark
            return bookmarks.firstIndex(of: anchorBookmark) ?? 0
        }
        if let firstHidden = hiddenItems.first {
            return bookmarks.firstIndex(of: firstHidden.bookmark) ?? bookmarks.count
        }
        return bookmarks.count
    }

    /// Creates a bookmark from a tab. Split-pair tabs become one split-view
    /// bookmark (both panes saved together); ordinary tabs go through the
    /// migrating `moveNormalTab` path so the open tab gets bound to the new
    /// bookmark.
    private func performTabDrop(_ tab: Tab, sourceState: BrowserState, at index: Int) -> Bool {
        if sourceState.addSplitBookmarkFromTab(tab, toFolder: nil, targetIndex: index) {
            return true
        }
        sourceState.moveNormalTab(tabId: tab.guid, toBookmark: nil, index: index)
        return true
    }

    /// Pinned tabs can never be in a split (the right-click "Open as Split"
    /// entry is suppressed for pinned tabs), so the drop always reuses the
    /// existing single-URL conversion path.
    private func performPinnedTabDrop(pinnedGuid: String, sourceState: BrowserState, at index: Int) -> Bool {
        sourceState.movePinnedTabOut(pinnedGuid: pinnedGuid, toBookmark: nil, index: index)
        return true
    }

    /// Resolves the source window's `BrowserState` from the pasteboard's
    /// `.sourceWindowId` entry. Falls back to nil for same-window drags.
    private func sourceBrowserState(for pasteboard: NSPasteboard) -> BrowserState? {
        guard let idString = pasteboard.string(forType: .sourceWindowId),
              let sourceId = Int(idString),
              sourceId != state.windowId else {
            return nil
        }
        return MainBrowserWindowControllersManager.shared.getBrowserState(for: sourceId)
    }

    // MARK: - Actions
    @objc private func showMoreMenu() {
        let menu = NSMenu(title: "More")
        menu.autoenablesItems = true
        for bookmark in overflowBookmarks {
            menu.addItem(createMenuItem(for: bookmark))
        }
        let origin = NSPoint(x: moreButton.bounds.width, y: 6)
        menu.popUp(positioning: nil, at: origin, in: moreButton)
    }

    private func handleBookmarkClick(_ bookmark: Bookmark, itemView: NSView) {
        AppLogDebug("Bookmark clicked: \(bookmark.title)")
        if bookmark.isFolder {
            showFolderMenu(for: bookmark, relativeTo: itemView)
        } else {
            openBookmark(bookmark)
        }
    }

    private func openBookmark(_ bookmark: Bookmark) {
        state.openBookmark(bookmark)
    }

    private func showFolderMenu(for folder: Bookmark, relativeTo itemView: NSView) {
        let menu = createMenu(for: folder)
        let origin = NSPoint(x: 0, y: -6)
        menu.popUp(positioning: nil, at: origin, in: itemView)
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        if let bookmark = sender.representedObject as? Bookmark {
            if !bookmark.isFolder {
                openBookmark(bookmark)
            }
        }
    }

    // MARK: - Context Menu
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let superview = self.superview else { return nil }
        let locationInSuperview = superview.convert(event.locationInWindow, from: nil)
        let hit = hitTest(locationInSuperview)
        if hit !== self && hit !== stackView {
            return nil
        }

        let menu = NSMenu()
        let newFolderItem = NSMenuItem(
            title: NSLocalizedString("New Folder", comment: "Bookmark New Folder menu item"),
            action: #selector(newFolderAction),
            keyEquivalent: ""
        )
        newFolderItem.target = self
        menu.addItem(newFolderItem)
        return menu
    }

    @MainActor @objc private func newFolderAction() {
        EditPinnedTabPresenter.presentModal(
            mode: .newFolder,
            from: state.windowController?.window
        ) { [weak self] result in
            guard let self, let folderName = result.title, !folderName.isEmpty else { return }
            self.state.bookmarkManager.addFolder(title: folderName)
        }
    }
}
