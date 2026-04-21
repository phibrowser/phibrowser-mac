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
        view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
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
                self?.setBackgroundColor()
            }
            .store(in: &cancellables)
    }

    private func syncCurrentState() {
        updateBookmarks(state.bookmarkManager.rootFolder.children)
        setBackgroundColor()
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

    private func setBackgroundColor() {
        phiLayer?.setBackgroundColor(ThemedColor.contentOverlayBackground)
    }

    // MARK: -Setup
    private func setupUI() {
        wantsLayer = true
        layer?.masksToBounds = true
        setBackgroundColor()

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

        registerForDraggedTypes([.phiBookmark])
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
        } else {
            item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            loadFavicon(for: bookmark.url) { [weak item] image in
                guard let image = image else { return }
                DispatchQueue.main.async {
                    image.size = NSSize(width: self.faviconSize, height: self.faviconSize)
                    item?.image = image
                }
            }
        }
        return item
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
        if pasteboard.types?.contains(.phiBookmark) == true {
            return .move
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
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
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true

        guard let pasteboard = sender.draggingPasteboard.pasteboardItems?.first,
              let guid = pasteboard.string(forType: .phiBookmark),
              let draggedBookmark = state.bookmarkManager.bookmark(withGuid: guid),
              let currentIndex = bookmarks.firstIndex(of: draggedBookmark) else {
            return false
        }

        let visibleItems = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }.filter { !$0.isHidden }
        let hiddenItems = stackView.arrangedSubviews.compactMap { $0 as? BookmarkItemView }.filter { $0.isHidden }

        var targetIndex = 0

        if lastDropIndex < visibleItems.count {
            let anchorBookmark = visibleItems[lastDropIndex].bookmark
            targetIndex = bookmarks.firstIndex(of: anchorBookmark) ?? 0
        } else {
            if let firstHidden = hiddenItems.first {
                targetIndex = bookmarks.firstIndex(of: firstHidden.bookmark) ?? bookmarks.count
            } else {
                targetIndex = bookmarks.count
            }
        }

        if targetIndex > currentIndex {
            targetIndex -= 1
        }

        state.bookmarkManager.moveBookmark(draggedBookmark, to: state.bookmarkManager.rootFolder, at: targetIndex)
        return true
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
