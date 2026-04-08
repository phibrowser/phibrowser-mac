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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Data Binding
    private func bindData() {
        bookmark.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.titleLabel.stringValue = title
            }
            .store(in: &cancellables)

        if bookmark.isFolder {
            self.faviconImageView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        } else {
            bookmark.$url
                .receive(on: DispatchQueue.main)
                .sink { [weak self] url in
                    self?.faviconImageView.loadFavicon(from: url, cornerRadius: 4)
                }
                .store(in: &cancellables)
        }
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
        addSubview(titleLabel)

        faviconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(self.horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(self.faviconSize)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(faviconImageView.snp.trailing).offset(self.spacing)
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
        let totalWidth = self.horizontalPadding + self.faviconSize + self.spacing + titleWidth + self.horizontalPadding
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
