// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SnapKit
import Combine

class BookmarkItemView: NSView {
    // MARK: - Constants
    let maxWidth: CGFloat = 160
    let cornerRadius: CGFloat = 8

    let horizontalPadding: CGFloat = 6
    let spacing: CGFloat = 4
    let faviconSize: CGFloat = 16

    // MARK: - Properties
    let bookmark: Bookmark
    private var cancellables = Set<AnyCancellable>()
    private var themeObservation: AnyObject?
    private var faviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private var secondaryFaviconLoadHandle: ProfileScopedFaviconLoadHandle?
    // Reports the clicked bookmark to the container view.
    var onClick: ((Bookmark) -> Void)?

    // Tracks hover state for background updates.
    private var isHovered = false {
        didSet {
            updateAppearance()
        }
    }

    // Drag gesture state.
    private var mouseDownPoint: CGPoint?
    private var isDragging = false
    private let dragThreshold: CGFloat = 5

    // MARK: - UI Components
    private lazy var faviconImageView: NSImageView = {
        let faviconImageView = NSImageView()
        faviconImageView.imageScaling = .scaleProportionallyUpOrDown
        faviconImageView.wantsLayer = true
        faviconImageView.layer?.cornerRadius = 4
        faviconImageView.layer?.cornerCurve = .continuous
        faviconImageView.layer?.masksToBounds = true
        return faviconImageView
    }()

    /// Second favicon shown only when the bookmark represents a split view
    /// (`bookmark.secondaryUrl` is set). Sits to the right of the primary
    /// favicon and mirrors its styling so the pair reads as a single icon
    /// composed of two halves.
    private lazy var secondaryFaviconImageView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.isHidden = true
        return view
    }()

    private lazy var titleLabel: NSTextField = {
        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        return titleLabel
    }()

    // MARK: - Initialization
    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        super.init(frame: .zero)
        setupUI()
        bindData()
        bindTheme()
        // Expose each bar item to UI testing as a button; the bookmark bar
        // otherwise has no stable query surface for the test reset to clear.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(BookmarkItemView.accessibilityIdentifier)
        setAccessibilityLabel(bookmark.title)
    }

    /// Identifier stamped on every bookmark-bar item.
    static let accessibilityIdentifier = "bookmarkBarItem"

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        faviconLoadHandle?.cancel()
        secondaryFaviconLoadHandle?.cancel()
    }

    // MARK: - Data Binding
    private func bindData() {
        if bookmark.isFolder {
            self.faviconImageView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            bookmark.$title
                .receive(on: DispatchQueue.main)
                .sink { [weak self] title in
                    self?.titleLabel.stringValue = title
                }
                .store(in: &cancellables)
            return
        }

        bookmark.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self else { return }
                self.updateFavicon(bookmark: self.bookmark, pageUrl: url)
            }
            .store(in: &cancellables)

        bookmark.$liveFaviconData
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateFavicon(bookmark: self.bookmark, pageUrl: self.bookmark.url)
            }
            .store(in: &cancellables)

        bookmark.$cachedFaviconData
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateFavicon(bookmark: self.bookmark, pageUrl: self.bookmark.url)
            }
            .store(in: &cancellables)

        // The display title and the secondary favicon both depend on the
        // split-pair fields. CombineLatest keeps the title rendering and the
        // second favicon in sync no matter which side updates first.
        Publishers.CombineLatest4(bookmark.$title,
                                  bookmark.$secondaryUrl,
                                  bookmark.$secondaryTitle,
                                  bookmark.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] primaryTitle, secondaryUrl, secondaryTitle, _ in
                guard let self else { return }
                self.applySplitState(bookmark: self.bookmark,
                                     primaryTitle: primaryTitle,
                                     secondaryUrl: secondaryUrl,
                                     secondaryTitle: secondaryTitle)
            }
            .store(in: &cancellables)
    }

    /// True while the bound bookmark is a split-view bookmark. Drives both
    /// the visibility of the secondary favicon and its zero-width collapse so
    /// non-split bookmarks lay out as before.
    private var isShowingSecondaryFavicon = false

    private func updateFavicon(bookmark: Bookmark, pageUrl: String?) {
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil

        faviconLoadHandle = BookmarkFaviconLoader.loadPrimaryFavicon(for: bookmark,
                                                                     pageURLString: pageUrl) { [weak self] image in
            self?.faviconImageView.image = image
        }
    }

    /// Joins both pane names into a single bookmark-bar label and toggles the
    /// secondary favicon. Falls back to the secondary URL's host when no
    /// explicit secondary title is stored (e.g. legacy split bookmarks saved
    /// before the title field existed).
    private func applySplitState(bookmark: Bookmark,
                                 primaryTitle: String,
                                 secondaryUrl: String?,
                                 secondaryTitle: String?) {
        guard let secondaryUrl, !secondaryUrl.isEmpty else {
            // Plain single-URL bookmark.
            setSecondaryFavicon(visible: false)
            secondaryFaviconLoadHandle?.cancel()
            secondaryFaviconLoadHandle = nil
            secondaryFaviconImageView.image = nil
            titleLabel.stringValue = primaryTitle
            invalidateIntrinsicContentSize()
            return
        }
        setSecondaryFavicon(visible: true)
        loadSecondaryFavicon(bookmark: bookmark, pageUrl: secondaryUrl)
        let resolvedSecondary = Self.displayName(forSecondaryTitle: secondaryTitle, url: secondaryUrl)
        // "•" separates the two pane names so the bookmark bar makes the
        // split nature visible without taking much extra width.
        if resolvedSecondary.isEmpty {
            titleLabel.stringValue = primaryTitle
        } else {
            titleLabel.stringValue = "\(primaryTitle) • \(resolvedSecondary)"
        }
        invalidateIntrinsicContentSize()
    }

    /// Collapses the secondary favicon to zero width when hidden so non-split
    /// bookmarks don't carry the visual gap reserved for the second icon.
    /// `NSView.isHidden` alone does not affect Auto Layout participation.
    private func setSecondaryFavicon(visible: Bool) {
        guard isShowingSecondaryFavicon != visible else {
            secondaryFaviconImageView.isHidden = !visible
            return
        }
        isShowingSecondaryFavicon = visible
        secondaryFaviconImageView.isHidden = !visible
        secondaryFaviconImageView.snp.updateConstraints { make in
            make.width.equalTo(visible ? self.faviconSize : 0)
        }
    }

    private func loadSecondaryFavicon(bookmark: Bookmark, pageUrl: String) {
        secondaryFaviconLoadHandle?.cancel()
        secondaryFaviconLoadHandle = nil
        secondaryFaviconLoadHandle = BookmarkFaviconLoader.loadFavicon(profileId: bookmark.profileId,
                                                                       pageURLString: pageUrl) { [weak self] result in
            self?.secondaryFaviconImageView.image = result.image
        }
    }

    /// Returns the best display label for the secondary pane: the stored title
    /// if present, otherwise the URL's host with any leading `www.` stripped.
    private static func displayName(forSecondaryTitle title: String?, url: String) -> String {
        if let title, !title.isEmpty { return title }
        guard let parsed = URL(string: url), let host = parsed.host else { return "" }
        if host.hasPrefix("www."), host.count > 4 {
            return String(host.dropFirst(4))
        }
        return host
    }
    
    private func bindTheme() {
        themeObservation = subscribe { [weak self] _, _ in
            self?.updateAppearance()
        }
    }

    private func updateAppearance() {
        if isHovered {
            layer?.backgroundColor = ThemedColor.hover.resolve(in: self).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // MARK: - Setup
    private func setupUI() {
        self.wantsLayer = true
        self.layer?.cornerRadius = self.cornerRadius
        self.layer?.masksToBounds = true

        addSubview(faviconImageView)
        addSubview(secondaryFaviconImageView)
        addSubview(titleLabel)

        faviconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(self.horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(self.faviconSize)
        }

        // Sits flush against the primary favicon when visible. The 2pt gap
        // matches the eye-spacing used by the edit-dialog SplitFaviconView.
        // Starts with width=0 so non-split bookmarks lay out unchanged from
        // before this view supported a second favicon; `applySplitState`
        // grows the width when the bookmark turns out to be a split.
        secondaryFaviconImageView.snp.makeConstraints { make in
            make.leading.equalTo(faviconImageView.snp.trailing).offset(2)
            make.centerY.equalToSuperview()
            make.height.equalTo(self.faviconSize)
            make.width.equalTo(0)
        }

        titleLabel.snp.makeConstraints { make in
            // Anchor to whichever favicon ends up rightmost. Hidden views
            // still participate in Auto Layout, so this constraint correctly
            // tracks the secondary favicon when it's the visible right edge
            // and collapses back when the secondary is hidden via the
            // intrinsic-size update below.
            make.leading.equalTo(secondaryFaviconImageView.snp.trailing).offset(self.spacing)
            make.trailing.equalToSuperview().offset(-1 * self.horizontalPadding)
            make.centerY.equalToSuperview()
        }

        self.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(self.maxWidth)
        }
    }

    // MARK: - Actions
    @objc private func handleClick() {
        onClick?(bookmark)
    }

    // MARK: - NSView Overrides
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            let location = convert(event.locationInWindow, from: nil)
            if self.bounds.contains(location) {
                self.handleClick()
            }
        }
        mouseDownPoint = nil
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = mouseDownPoint else { return }

        if !isDragging {
            let currentPoint = convert(event.locationInWindow, from: nil)
            let dx = abs(currentPoint.x - startPoint.x)
            let dy = abs(currentPoint.y - startPoint.y)
            if dx > dragThreshold || dy > dragThreshold {
                isDragging = true
                startDraggingSession(with: event)
            }
        }
    }

    private func startDraggingSession(with event: NSEvent) {
        let pbItem = NSPasteboardItem()
        pbItem.setString(bookmark.guid, forType: .phiBookmark)

        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        let bounds = self.bounds
        if let bitmap = self.bitmapImageRepForCachingDisplay(in: bounds) {
            self.cacheDisplay(in: bounds, to: bitmap)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(bitmap)
            draggingItem.setDraggingFrame(bounds, contents: image)
        }
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        bookmark.makeContextMenu(on: menu, source: .bookmarkBar)
        return menu.items.isEmpty ? nil : menu
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        // Secondary favicon adds 2pt gap + 16pt icon when it's visible.
        let secondaryFaviconWidth: CGFloat = isShowingSecondaryFavicon ? (2 + self.faviconSize) : 0
        let totalWidth = self.horizontalPadding + self.faviconSize + secondaryFaviconWidth + self.spacing + titleWidth + self.horizontalPadding
        return NSSize(width: min(totalWidth, maxWidth), height: NSView.noIntrinsicMetric)
    }
}

extension BookmarkItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownPoint = nil
        isDragging = false
    }
}
