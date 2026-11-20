// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

struct BookmarkFolderPreviewItem {
    let bookmark: Bookmark
    let paneIndex: Int
    let title: String
    let url: String

    static func contents(of folder: Bookmark) -> [Self] {
        folder.children.flatMap { child -> [Self] in
            if child.isFolder { return contents(of: child) }
            let panes = child.splitPanes
            if !panes.isEmpty {
                return panes.enumerated().map {
                    Self(bookmark: child, paneIndex: $0.offset, title: $0.element.title, url: $0.element.url)
                }
            }
            guard let url = child.url, !url.isEmpty else { return [] }
            return [Self(bookmark: child, paneIndex: 0, title: child.title, url: url)]
        }
    }

    /// The row label: the page title, or the host when the title is missing or just repeats the URL.
    var displayTitle: String {
        guard title.isEmpty || title == url else { return title }
        return URL(string: url)?.host ?? (title.isEmpty ? url : title)
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedStandardContains(query) || url.localizedStandardContains(query)
    }
}

/// The collapsed sidebar row a preview lists: a bookmark folder, or the
/// Space header with every bookmark of the Space.
@MainActor
enum BookmarkFolderPreviewSource {
    case folder(Bookmark)
    case space(SpaceRootSidebarItem)

    var title: String {
        switch self {
        case .folder(let folder): folder.title
        case .space(let root): root.title
        }
    }

    /// Whether the row still hides its contents, which is when a preview is useful.
    var isCollapsed: Bool {
        switch self {
        case .folder(let folder):
            folder.isFolder && !folder.isExpanded && !folder.isEditing
        case .space(let root):
            root.browserState?.isBookmarkRootExpanded == false
        }
    }

    var items: [BookmarkFolderPreviewItem] {
        switch self {
        case .folder(let folder):
            BookmarkFolderPreviewItem.contents(of: folder)
        case .space(let root):
            root.browserState.map { BookmarkFolderPreviewItem.contents(of: $0.bookmarkManager.rootFolder) } ?? []
        }
    }
}

/// Elapsed time since a bookmark was last opened: minutes within the hour,
/// hours within the same day, then "Yesterday" and whole days.
enum BookmarkFolderPreviewLastOpened {
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 3600 {
            return String.localizedStringWithFormat(NSLocalizedString(
                "sidebar.folderPreview.lastOpened.minutes", value: "%d min ago",
                comment: "Sidebar folder preview - Time since a bookmarked page was last opened, shown on the second line of its row under the title; %d is the number of minutes (1-59)"
            ), max(1, Int(elapsed / 60)))
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return String.localizedStringWithFormat(NSLocalizedString(
                "sidebar.folderPreview.lastOpened.hours", value: "%d hours ago",
                comment: "Sidebar folder preview - Time since a bookmarked page was last opened earlier today, shown on the second line of its row under the title; %d is the number of hours"
            ), Int(elapsed / 3600))
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 1 {
            return NSLocalizedString(
                "sidebar.folderPreview.lastOpened.yesterday", value: "Yesterday",
                comment: "Sidebar folder preview - Shown on the second line of a page row, under the title, when the page was last opened yesterday"
            )
        }
        return String.localizedStringWithFormat(NSLocalizedString(
            "sidebar.folderPreview.lastOpened.days", value: "%d days ago",
            comment: "Sidebar folder preview - Time since a bookmarked page was last opened, shown on the second line of its row under the title; %d is the number of calendar days"
        ), days)
    }
}

/// Geometry of the folder preview. The panel has a fixed width; its height is
/// the search header plus up to `maximumVisibleRows` rows, so fewer results
/// shrink it and more scroll inside it.
enum BookmarkFolderPreviewLayout {
    static let width: CGFloat = 280
    static let cornerRadius: CGFloat = 12
    static let headerHeight: CGFloat = 48
    static let separatorHeight: CGFloat = 1
    static let rowHeight: CGFloat = 44
    static let maximumVisibleRows = 5
    static let listVerticalInset: CGFloat = 4
    static let rowHorizontalInset: CGFloat = 4
    static let rowCornerRadius: CGFloat = 6
    /// Leading edge of the search glyph and the favicons.
    static let iconLeading: CGFloat = 12
    static let iconSize: CGFloat = 16
    /// Leading edge shared by the search text and the row titles.
    static let textLeading: CGFloat = 36
    static let textTrailing: CGFloat = 12
    static let lastOpenedSpacing: CGFloat = 2
    static let emptyStateHeight: CGFloat = 40
    static let anchorGap: CGFloat = 4
    static let screenMargin: CGFloat = 4

    static func listHeight(resultCount: Int) -> CGFloat {
        guard resultCount > 0 else { return emptyStateHeight }
        return CGFloat(min(resultCount, maximumVisibleRows)) * rowHeight + listVerticalInset * 2
    }

    static func contentHeight(resultCount: Int) -> CGFloat {
        headerHeight + separatorHeight + listHeight(resultCount: resultCount)
    }

    /// Distance from the panel's top edge to the first row's vertical center.
    static let firstRowCenterFromTop = headerHeight + separatorHeight + listVerticalInset + rowHeight / 2

    /// Places the panel beside the anchor (the row's visible background), on
    /// the side facing the window content, with its first row level with the
    /// anchor row, kept on screen.
    static func initialFrame(contentHeight: CGFloat,
                             anchorScreenRect anchor: CGRect,
                             visibleFrame: CGRect?,
                             opensTowardMaxX: Bool) -> CGRect {
        let maxXOrigin = anchor.maxX + anchorGap
        let minXOrigin = anchor.minX - anchorGap - width
        var origin = CGPoint(x: opensTowardMaxX ? maxXOrigin : minXOrigin,
                             y: anchor.midY + firstRowCenterFromTop - contentHeight)
        if let visibleFrame {
            let minX = visibleFrame.minX + screenMargin
            let maxX = visibleFrame.maxX - screenMargin
            if opensTowardMaxX, origin.x + width > maxX, minXOrigin >= minX {
                origin.x = minXOrigin
            } else if !opensTowardMaxX, origin.x < minX, maxXOrigin + width <= maxX {
                origin.x = maxXOrigin
            }
            origin.x = min(max(origin.x, minX), max(minX, maxX - width))
            origin.y = clampedOriginY(origin.y, height: contentHeight, visibleFrame: visibleFrame)
        }
        return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: contentHeight)
    }

    /// Resizes while keeping the top edge — and so the search field — still,
    /// moving up only when the bottom would leave the screen.
    static func resizedFrame(_ frame: CGRect, contentHeight: CGFloat, visibleFrame: CGRect?) -> CGRect {
        var originY = frame.maxY - contentHeight
        if let visibleFrame {
            originY = clampedOriginY(originY, height: contentHeight, visibleFrame: visibleFrame)
        }
        return CGRect(x: frame.minX, y: originY, width: frame.width, height: contentHeight)
    }

    /// Whether the pointer is over the row, the panel, or the gap between
    /// them at the row's height — the path a pointer takes into the panel.
    static func hoverRegionContains(_ point: CGPoint, anchorScreenRect anchor: CGRect, panelFrame panel: CGRect) -> Bool {
        if anchor.contains(point) || panel.contains(point) { return true }
        let gapMinX: CGFloat
        let gapMaxX: CGFloat
        if panel.minX >= anchor.maxX {
            gapMinX = anchor.maxX
            gapMaxX = panel.minX
        } else if panel.maxX <= anchor.minX {
            gapMinX = panel.maxX
            gapMaxX = anchor.minX
        } else {
            return false
        }
        return point.x >= gapMinX && point.x <= gapMaxX && point.y >= anchor.minY && point.y <= anchor.maxY
    }

    private static func clampedOriginY(_ y: CGFloat, height: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let minY = visibleFrame.minY + screenMargin
        let maxY = max(minY, visibleFrame.maxY - screenMargin - height)
        return min(max(y, minY), maxY)
    }
}

extension Notification.Name {
    /// Posted with the `BookmarkFolderPreview` as object when its panel shows
    /// or closes. The floating sidebar stays open while a preview anchored in
    /// it is up, as it does for its popovers.
    static let bookmarkFolderPreviewWillShow = Notification.Name("BookmarkFolderPreviewWillShow")
    static let bookmarkFolderPreviewDidClose = Notification.Name("BookmarkFolderPreviewDidClose")
}

/// Owned by the reusable sidebar cell, which feeds it the row's hover and
/// keeps the row highlighted while `isPresented`.
///
/// The preview is a borderless child panel instead of an `NSPopover`: a
/// popover adds an arrow and its own chrome, and resizing its content view
/// re-anchors the popover so the search field does not stay put. The panel
/// is non-activating, so taking key for the search field leaves the app and
/// the browser window's main status alone.
@MainActor
final class BookmarkFolderPreview: NSObject, NSWindowDelegate {
    private static let showDelay: TimeInterval = 0.4
    private static let exitGrace: TimeInterval = 0.3
    private static let pointerCheckInterval: TimeInterval = 0.1

    var onPresentationChange: ((Bool) -> Void)?
    var isPresented: Bool { panel != nil }

    private var pending: DispatchWorkItem?
    private var panel: BookmarkFolderPreviewPanel?
    private weak var content: BookmarkFolderPreviewContentView?
    private var pointerTimer: Timer?
    private var outsideSince: Date?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) weak var anchor: NSView?
    private var anchorInsets = NSEdgeInsetsZero
    private var source: BookmarkFolderPreviewSource?

    /// `anchorInsets` trims the anchor view to the row's visible background,
    /// which the panel is placed against.
    func setHovering(_ hovering: Bool, source: BookmarkFolderPreviewSource, anchor: NSView,
                     anchorInsets: NSEdgeInsets = NSEdgeInsetsZero, browserState: BrowserState) {
        pending?.cancel()
        pending = nil
        guard hovering, panel == nil, source.isCollapsed else { return }
        let work = DispatchWorkItem { [weak self, weak anchor, weak browserState] in
            guard let self, let anchor, let browserState else { return }
            self.pending = nil
            self.anchorInsets = anchorInsets
            self.present(source: source, anchor: anchor, browserState: browserState)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    private func present(source: BookmarkFolderPreviewSource, anchor: NSView, browserState: BrowserState) {
        guard panel == nil,
              let window = anchor.window, window.isKeyWindow, NSApp.isActive,
              !Self.isEditingText(in: window),
              !anchor.isHiddenOrHasHiddenAncestor,
              source.isCollapsed,
              NSEvent.pressedMouseButtons == 0,
              let anchorRect = Self.screenRect(of: anchor),
              anchorRect.contains(NSEvent.mouseLocation) else { return }
        let items = source.items
        guard !items.isEmpty else { return }

        let content = BookmarkFolderPreviewContentView(items: items, placeholder: Self.searchPlaceholder(for: source.title))
        content.onActivate = { [weak self, weak browserState] item in
            self?.invalidate()
            browserState?.openBookmark(item.bookmark)
        }
        content.onDismiss = { [weak self] in self?.invalidate() }
        content.onPreferredHeightChange = { [weak self] height in self?.resizePanel(toContentHeight: height) }

        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorRect.midX, y: anchorRect.midY)) }
            ?? window.screen
        let frame = BookmarkFolderPreviewLayout.initialFrame(
            contentHeight: content.preferredHeight,
            anchorScreenRect: Self.inset(anchorRect, by: anchorInsets),
            visibleFrame: screen?.visibleFrame,
            // A left sidebar opens the preview to its right, a right sidebar to its left.
            opensTowardMaxX: anchorRect.midX < window.frame.midX
        )
        let panel = BookmarkFolderPreviewPanel(contentRect: frame)
        panel.appearance = anchor.themeStateProvider.currentAppearance.nsAppearance
        content.frame = NSRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        panel.onCancel = { [weak self] in self?.invalidate() }
        panel.delegate = self
        panel.setFrame(frame, display: false)

        self.panel = panel
        self.content = content
        self.anchor = anchor
        self.source = source
        NotificationCenter.default.post(name: .bookmarkFolderPreviewWillShow, object: self)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content.searchField)
        panel.display()
        panel.invalidateShadow()
        startMonitoring(window: window)
        onPresentationChange?(true)
    }

    private func resizePanel(toContentHeight height: CGFloat) {
        guard let panel else { return }
        let frame = BookmarkFolderPreviewLayout.resizedFrame(
            panel.frame, contentHeight: height, visibleFrame: panel.screen?.visibleFrame
        )
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func startMonitoring(window: NSWindow) {
        outsideSince = nil
        let timer = Timer(timeInterval: Self.pointerCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside(event) }
            return event
        }

        let lifecycle: [(Notification.Name, AnyObject?)] = [
            (NSWindow.willCloseNotification, window),
            (NSWindow.didMiniaturizeNotification, window),
            (NSApplication.didResignActiveNotification, NSApp),
            (NSApplication.didHideNotification, NSApp)
        ]
        for (name, object) in lifecycle {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: object, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            })
        }
        // Covers overlays that leave key with the panel; the omnibox takes
        // key back itself before focusing its field.
        observers.append(NotificationCenter.default.addObserver(
            forName: .phiInWindowOverlayVisibilityChanged, object: window, queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?["visible"] as? Bool == true else { return }
            MainActor.assumeIsolated { self?.invalidate() }
        })
    }

    private func dismissIfOutside(_ event: NSEvent) {
        guard let panel, event.window !== panel else { return }
        invalidate()
    }

    private func checkPointer() {
        guard let panel, let anchor, source?.isCollapsed == true,
              let window = anchor.window, window.isVisible,
              !anchor.isHiddenOrHasHiddenAncestor,
              let anchorRect = Self.screenRect(of: anchor) else {
            invalidate()
            return
        }
        // Once a query is typed, only Escape, an outside click, or losing key
        // closes the preview.
        let isEngaged = content?.hasQuery == true || NSEvent.pressedMouseButtons != 0
        if isEngaged || BookmarkFolderPreviewLayout.hoverRegionContains(
            NSEvent.mouseLocation, anchorScreenRect: anchorRect, panelFrame: panel.frame
        ) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > Self.exitGrace { invalidate() }
        } else {
            outsideSince = Date()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        invalidate()
    }

    func invalidate() {
        pending?.cancel()
        pending = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        outsideSince = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let panel else { return }
        self.panel = nil
        source = nil
        let wasKey = panel.isKeyWindow
        panel.delegate = nil
        panel.onCancel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if wasKey, NSApp.isActive, let window = anchor?.window, window.isVisible {
            window.makeKey()
        }
        NotificationCenter.default.post(name: .bookmarkFolderPreviewDidClose, object: self)
        onPresentationChange?(false)
    }

    deinit {
        pending?.cancel()
        pointerTimer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private static func screenRect(of view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        let visible = view.bounds.intersection(view.visibleRect)
        guard !visible.isEmpty else { return nil }
        return window.convertToScreen(view.convert(visible, to: nil))
    }

    /// The preview takes key for its search field, so it must not open over
    /// native text input in progress, such as the omnibox or tab search.
    static func isEditingText(in window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.isEditable == true
    }

    private static func inset(_ rect: CGRect, by insets: NSEdgeInsets) -> CGRect {
        let inset = CGRect(x: rect.minX + insets.left, y: rect.minY + insets.bottom,
                           width: rect.width - insets.left - insets.right,
                           height: rect.height - insets.top - insets.bottom)
        return inset.isEmpty ? rect : inset
    }

    private static func searchPlaceholder(for title: String) -> String {
        String(format: NSLocalizedString(
            "sidebar.folderPreview.searchPlaceholder", value: "Search %@…",
            comment: "Sidebar folder preview - Placeholder of the search field shown when hovering a closed bookmark folder or Space header; searches page titles and URLs in the folder or Space, including subfolders. %@ is the folder or Space name."
        ), title)
    }
}

private final class BookmarkFolderPreviewPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        isMovable = false
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The preview's whole surface: rounded background, flat search header,
/// divider, and result list. It lays out with frames in flipped coordinates,
/// so the header is pinned to the top whatever height the panel takes.
final class BookmarkFolderPreviewContentView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias FaviconLoader = @MainActor (BookmarkFolderPreviewItem, @escaping (NSImage) -> Void) -> ProfileScopedFaviconLoadHandle?
    private typealias Layout = BookmarkFolderPreviewLayout

    var onActivate: ((BookmarkFolderPreviewItem) -> Void)?
    var onDismiss: (() -> Void)?
    var onPreferredHeightChange: ((CGFloat) -> Void)?

    private let items: [BookmarkFolderPreviewItem]
    private(set) var results: [BookmarkFolderPreviewItem]
    private(set) var highlightedRow: Int?
    private let faviconLoader: FaviconLoader
    /// Set while the list scrolls to the keyboard highlight, so the row that
    /// scrolls under a still pointer does not take the highlight over.
    private var isScrollingToHighlight = false

    private let background = BookmarkFolderPreviewContentView.makeBackground()
    private let searchIcon = NSImageView()
    let searchField = NSTextField()
    private let separator = BookmarkFolderPreviewSeparatorView()
    let scrollView = NSScrollView()
    let tableView = BookmarkFolderPreviewTableView()
    let emptyLabel = NSTextField(labelWithString: NSLocalizedString(
        "sidebar.folderPreview.noResults", value: "No Matching Pages",
        comment: "Sidebar folder preview - Shown in place of the page list when no page title or URL in the folder or Space matches the search"
    ))

    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("folderPreviewRow")
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("folderPreviewPage")

    var preferredHeight: CGFloat { Layout.contentHeight(resultCount: results.count) }
    var hasQuery: Bool { !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    override var isFlipped: Bool { true }

    init(items: [BookmarkFolderPreviewItem],
         placeholder: String,
         faviconLoader: @escaping FaviconLoader = BookmarkFolderPreviewContentView.loadRepositoryFavicon) {
        self.items = items
        self.results = items
        self.faviconLoader = faviconLoader
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width,
                                 height: Layout.contentHeight(resultCount: items.count)))
        wantsLayer = true
        layer?.cornerRadius = Layout.cornerRadius
        layer?.masksToBounds = true
        addSubview(background)
        setUpSearchHeader(placeholder: placeholder)
        setUpList()
        updateEmptyState()
        tableView.reloadData()
        layoutSubtreeIfNeeded()
        scrollListToTop()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUpSearchHeader(placeholder: String) {
        let font = NSFont.systemFont(ofSize: 13)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleNone
        addSubview(searchIcon)

        // A plain borderless field: no bezel, capsule, clear button, or focus ring.
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.font = font
        searchField.textColor = .labelColor
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        searchField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        searchField.delegate = self
        addSubview(searchField)
        addSubview(separator)
    }

    private func setUpList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.style = .plain
        tableView.headerView = nil
        tableView.rowHeight = Layout.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.refusesFirstResponder = true
        tableView.allowsColumnResizing = false
        tableView.allowsColumnReordering = false
        tableView.allowsEmptySelection = true
        // The single column always spans the clip view, so a long title is
        // truncated inside its row instead of running under the scroller.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateClickedRow)
        tableView.onPointerRowChange = { [weak self] row in self?.setHighlightedRow(row) }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Layout.listVerticalInset, left: 0,
                                                bottom: Layout.listVerticalInset, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        addSubview(emptyLabel)
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        background.frame = bounds

        let header = Layout.headerHeight
        searchIcon.frame = NSRect(x: Layout.iconLeading, y: ((header - Layout.iconSize) / 2).rounded(),
                                  width: Layout.iconSize, height: Layout.iconSize)
        let fieldHeight = ceil(searchField.intrinsicContentSize.height)
        searchField.frame = NSRect(x: Layout.textLeading, y: ((header - fieldHeight) / 2).rounded(),
                                   width: max(0, bounds.width - Layout.textLeading - Layout.textTrailing),
                                   height: fieldHeight)
        separator.frame = NSRect(x: 0, y: header, width: bounds.width, height: Layout.separatorHeight)

        let listTop = header + Layout.separatorHeight
        let list = NSRect(x: 0, y: listTop, width: bounds.width, height: max(0, bounds.height - listTop))
        scrollView.frame = list
        tableView.tableColumns.first?.width = scrollView.contentSize.width
        let labelHeight = ceil(emptyLabel.intrinsicContentSize.height)
        emptyLabel.frame = NSRect(x: Layout.textTrailing, y: (list.midY - labelHeight / 2).rounded(),
                                  width: max(0, bounds.width - Layout.textTrailing * 2), height: labelHeight)
    }

    // MARK: Search and keyboard

    /// Replaces the search text as if typed.
    func setSearchText(_ text: String) {
        searchField.stringValue = text
        applyQuery(text)
    }

    func controlTextDidChange(_ obj: Notification) {
        applyQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveHighlight(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveHighlight(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            activateHighlightedRow()
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
        default:
            return false
        }
        return true
    }

    private func applyQuery(_ query: String) {
        let isFiltering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        results = items.filter { $0.matches(query) }
        highlightedRow = isFiltering && !results.isEmpty ? 0 : nil
        tableView.reloadData()
        updateEmptyState()
        needsLayout = true
        onPreferredHeightChange?(preferredHeight)
        layoutSubtreeIfNeeded()
        scrollListToTop()
    }

    /// The top content inset is scrollable padding, so "top" is above row 0.
    private func scrollListToTop() {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -Layout.listVerticalInset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func updateEmptyState() {
        scrollView.isHidden = results.isEmpty
        emptyLabel.isHidden = !results.isEmpty
    }

    /// Wraps past either end of the results.
    func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        let next = highlightedRow.map { (($0 + delta) % count + count) % count }
            ?? (delta > 0 ? 0 : count - 1)
        setHighlightedRow(next)
        isScrollingToHighlight = true
        tableView.scrollRowToVisible(next)
        isScrollingToHighlight = false
    }

    func activateHighlightedRow() {
        let row = highlightedRow ?? 0
        guard results.indices.contains(row) else { return }
        onActivate?(results[row])
    }

    @objc private func activateClickedRow() {
        let row = tableView.clickedRow
        guard results.indices.contains(row) else { return }
        onActivate?(results[row])
    }

    @objc private func listDidScroll() {
        guard !isScrollingToHighlight else { return }
        tableView.refreshPointerRow()
    }

    private func setHighlightedRow(_ row: Int?) {
        let row = row.flatMap { results.indices.contains($0) ? $0 : nil }
        guard row != highlightedRow else { return }
        let previous = highlightedRow
        highlightedRow = row
        for index in [previous, row].compactMap({ $0 }) where index < tableView.numberOfRows {
            (tableView.rowView(atRow: index, makeIfNecessary: false) as? BookmarkFolderPreviewRowView)?
                .showsHighlight = index == row
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? BookmarkFolderPreviewRowView
            ?? BookmarkFolderPreviewRowView()
        view.identifier = Self.rowViewIdentifier
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? BookmarkFolderPreviewRowView)?.showsHighlight = row == highlightedRow
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? BookmarkFolderPreviewCell
            ?? BookmarkFolderPreviewCell()
        cell.identifier = Self.cellIdentifier
        cell.configure(results[row], faviconLoader: faviconLoader)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Helpers

    static func loadRepositoryFavicon(
        _ item: BookmarkFolderPreviewItem,
        completion: @escaping (NSImage) -> Void
    ) -> ProfileScopedFaviconLoadHandle? {
        ProfileScopedFaviconRepository.shared.loadFavicon(for: ProfileScopedFaviconRequest(
            profileId: item.bookmark.profileId,
            pageURLString: item.url,
            snapshotData: item.paneIndex == 0 ? item.bookmark.cachedFaviconData : nil
        )) { result in
            completion(result.image)
        }
    }

    /// Liquid Glass on macOS 26+, a behind-window blur before it.
    private static func makeBackground() -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Layout.cornerRadius
            // The rows are siblings above the glass; it still requires a content view.
            glass.contentView = NSView()
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        // The mask gives the window shadow the panel's rounded outline.
        blur.maskImage = roundedMask(radius: Layout.cornerRadius)
        return blur
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class BookmarkFolderPreviewSeparatorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// Reports which row is under the pointer, even while the panel is not key.
final class BookmarkFolderPreviewTableView: NSTableView {
    var onPointerRowChange: ((Int?) -> Void)?
    /// The pointer in window coordinates; replaced in tests.
    var pointerLocationInWindow: (NSWindow) -> NSPoint = { $0.mouseLocationOutsideOfEventStream }
    private var pointerTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        reportRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        reportRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onPointerRowChange?(nil)
    }

    /// Scrolling moves rows under a still pointer without a mouse-moved event.
    func refreshPointerRow() {
        guard let window else { return }
        let point = convert(pointerLocationInWindow(window), from: nil)
        guard visibleRect.contains(point) else { return }
        reportRow(at: point)
    }

    private func reportRow(at point: NSPoint) {
        let row = row(at: point)
        onPointerRowChange?(row >= 0 ? row : nil)
    }
}

/// Draws the hover / keyboard highlight as an inset rounded rectangle; the
/// table's own selection styling is disabled.
final class BookmarkFolderPreviewRowView: NSTableRowView {
    private static let highlightColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1)
            : NSColor.black.withAlphaComponent(0.06)
    }

    var showsHighlight = false {
        didSet { if oldValue != showsHighlight { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard showsHighlight else { return }
        let radius = BookmarkFolderPreviewLayout.rowCornerRadius
        let rect = bounds.insetBy(dx: BookmarkFolderPreviewLayout.rowHorizontalInset, dy: 0)
        Self.highlightColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

final class BookmarkFolderPreviewCell: NSTableCellView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let lastOpenedLabel = NSTextField(labelWithString: "")
    private var faviconLoad: ProfileScopedFaviconLoadHandle?

    init() {
        super.init(frame: .zero)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        lastOpenedLabel.font = .systemFont(ofSize: 11)
        lastOpenedLabel.textColor = .secondaryLabelColor
        lastOpenedLabel.lineBreakMode = .byTruncatingTail
        lastOpenedLabel.usesSingleLineMode = true
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(lastOpenedLabel)
        imageView = iconView
        textField = titleLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Frame layout bounded by the cell width: a long title can never widen
    /// the row, so it always tail-truncates before the trailing inset. The
    /// last-opened time is a second line under the title; the pair is
    /// vertically centered, and a lone title is centered on its own.
    override func layout() {
        super.layout()
        let metrics = BookmarkFolderPreviewLayout.self
        iconView.frame = NSRect(x: metrics.iconLeading, y: ((bounds.height - metrics.iconSize) / 2).rounded(),
                                width: metrics.iconSize, height: metrics.iconSize)
        let textWidth = max(0, bounds.width - metrics.textLeading - metrics.textTrailing)
        let titleHeight = ceil(titleLabel.cell?.cellSize.height ?? titleLabel.intrinsicContentSize.height)
        let subtitleHeight = lastOpenedLabel.isHidden
            ? 0 : ceil(lastOpenedLabel.cell?.cellSize.height ?? lastOpenedLabel.intrinsicContentSize.height)
        let blockHeight = lastOpenedLabel.isHidden
            ? titleHeight : titleHeight + metrics.lastOpenedSpacing + subtitleHeight
        let titleY = ((bounds.height - blockHeight) / 2).rounded()
        titleLabel.frame = NSRect(x: metrics.textLeading, y: titleY, width: textWidth, height: titleHeight)
        lastOpenedLabel.frame = NSRect(x: metrics.textLeading, y: titleY + titleHeight + metrics.lastOpenedSpacing,
                                       width: textWidth, height: subtitleHeight)
    }

    override var isFlipped: Bool { true }

    func configure(_ item: BookmarkFolderPreviewItem,
                   faviconLoader: BookmarkFolderPreviewContentView.FaviconLoader) {
        faviconLoad?.cancel()
        titleLabel.stringValue = item.displayTitle
        let lastSeen = item.bookmark.lastSeen
        lastOpenedLabel.stringValue = lastSeen.map { BookmarkFolderPreviewLastOpened.text(for: $0) } ?? ""
        lastOpenedLabel.isHidden = lastSeen == nil
        iconView.image = Self.placeholderIcon(for: item)
        faviconLoad = faviconLoader(item) { [weak self] image in
            self?.iconView.image = image
        }
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faviconLoad?.cancel()
        faviconLoad = nil
    }

    private static func placeholderIcon(for item: BookmarkFolderPreviewItem) -> NSImage? {
        if item.paneIndex == 0, let data = item.bookmark.cachedFaviconData, let image = NSImage(data: data) {
            return image
        }
        if let url = URL(string: item.url), FaviconConfiguration.shouldUseDefaultFavicon(for: url) {
            return .phiDefaultFavicon
        }
        return FaviconConfiguration.default.placeholder
    }

    deinit { faviconLoad?.cancel() }
}
