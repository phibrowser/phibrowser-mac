// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine

/// A lightweight protocol to allow the sidebar to show "virtual" bookmark items
/// while still rendering and operating on the underlying real `Bookmark`.
protocol UnderlyingBookmarkProviding {
    var underlyingBookmark: Bookmark { get }
}

/// Delegate for bookmark title edits.
protocol BookmarkCellViewDelegate: AnyObject {
    func bookmarkCellDidEndEditing(_ bookmark: Bookmark, newTitle: String)
}

class BookmarkCellView: SidebarCellView {
    private var iconImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var editField: NSTextField!
    private var faviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private var isHovered = false
    private var isActiveBookmark = false
    private var isDropTargetHighlighted = false
    
    /// Whether editing became active after focus was actually assigned.
    private var isEditingActive = false
    
    weak var editDelegate: BookmarkCellViewDelegate?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        iconImageView.image = nil
    }
    
    private func setupViews() {
        // Background view drives hover and selection styling.
        addSubview(backgoundView)
        backgoundView.snp.makeConstraints { make in
            make.left.equalToSuperview().inset(10)
            make.top.bottom.trailing.equalToSuperview().inset(2)
        }
        backgoundView.layer?.cornerRadius = 8
        backgoundView.layer?.cornerCurve = .continuous
        backgoundView.shadow = nil
        
        // Configure hover styling.
        backgoundView.selectedColor = NSColor(resource: .sidebarTabSelected)
        backgoundView.backgroundColor = .clear
        backgoundView.hoveredColor = NSColor(resource: .sidebarTabHovered)
        backgoundView.hoverStateChanged = { [weak self] hovered in
            self?.isHovered = hovered
        }
        
        // Icon
        iconImageView = NSImageView()
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.wantsLayer = true
        iconImageView.layer?.cornerRadius = 4
        iconImageView.layer?.cornerCurve = .continuous
        iconImageView.layer?.masksToBounds = true
        backgoundView.addSubview(iconImageView)
        
        // Title (display mode)
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        backgoundView.addSubview(titleLabel)
        
        // Edit field (edit mode)
        editField = NSTextField()
        editField.font = NSFont.systemFont(ofSize: 13)
        editField.textColor = NSColor.labelColor
        editField.isBordered = false
        editField.drawsBackground = false
        editField.focusRingType = .none
        editField.isHidden = true
        editField.delegate = self
        // Keep editing in a single-line field aligned with the title label.
        editField.usesSingleLineMode = true
        editField.cell?.isScrollable = true
        editField.cell?.wraps = false
        backgoundView.addSubview(editField)
        
        setupConstraints()
    }
    
    private func setupConstraints() {
        iconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(6)
            make.centerY.equalToSuperview()
            make.size.equalTo(20)
        }
        
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(8)
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
        }
        
        editField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editField.snp.makeConstraints { make in
            // Match the title-label constraints so edit mode does not jump.
            make.leading.equalTo(iconImageView.snp.trailing).offset(8)
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
        }
    }
    
    override func configureAppearance() {
        let bookmark: Bookmark
        if let direct = item as? Bookmark {
            bookmark = direct
        } else if let provider = item as? UnderlyingBookmarkProviding {
            bookmark = provider.underlyingBookmark
        } else {
            return
        }
        
        isEditingActive = false
        
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        isDropTargetHighlighted = false
        
        bookmark.$title
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.titleLabel.stringValue = title
                self?.titleLabel.toolTip = title
            }
            .store(in: &cancellables)

        bookmark.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.updateFavicon(bookmark: bookmark, pageUrl: url)
            }
            .store(in: &cancellables)

        bookmark.$liveFaviconData
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)

        bookmark.$cachedFaviconData
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)
        
        bookmark.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.updateActiveState(isActive)
            }
            .store(in: &cancellables)
        
        bookmark.$isExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFolderIcon(bookmark: bookmark)
            }
            .store(in: &cancellables)
        
        bookmark.$isEditing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEditing in
                self?.updateEditingState(isEditing, bookmark: bookmark)
            }
            .store(in: &cancellables)
        
        titleLabel.phi.setTextColor(bookmark.isFolder ? .textPrimaryStrong : .textPrimary)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: bookmark.isFolder ? .medium : .regular)
        titleLabel.stringValue = bookmark.title
        titleLabel.toolTip = bookmark.title
        if bookmark.isFolder {
            updateFolderIcon(bookmark: bookmark)
        }
        updateActiveState(bookmark.isActive)
        updateEditingState(bookmark.isEditing, bookmark: bookmark)
        
        let iconSize = bookmark.isFolder ? 20 : 16
        iconImageView.snp.updateConstraints { make in
            make.size.equalTo(iconSize)
        }
    }
    
    private func updateActiveState(_ isActive: Bool) {
        isActiveBookmark = isActive
        applySelectionStyle()
    }

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard isDropTargetHighlighted != highlighted else { return }
        isDropTargetHighlighted = highlighted
        applySelectionStyle()
    }

    private func applySelectionStyle() {
        let shouldHighlight = isActiveBookmark || isDropTargetHighlighted
        backgoundView.isSelected = shouldHighlight
        backgoundView.shadow = shouldHighlight ? selectedShadow : nil
    }
    
    private func updateFavicon(bookmark: Bookmark, pageUrl: String?) {
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil

        if bookmark.isFolder {
            updateFolderIcon(bookmark: bookmark)
            return
        }

        if let liveFaviconData = bookmark.liveFaviconData,
           let image = NSImage(data: liveFaviconData) {
            iconImageView.image = image
            return
        }

        let request = ProfileScopedFaviconRequest(
            profileId: bookmark.profileId,
            pageURLString: pageUrl,
            snapshotData: bookmark.cachedFaviconData
        )

        faviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self, weak bookmark] result in
            self?.iconImageView.image = result.image
            if result.source == .chromium, let data = result.data {
                bookmark?.updateCachedFaviconData(data)
            }
        }
    }
    
    private func updateFolderIcon(bookmark: Bookmark) {
        guard bookmark.isFolder else { return }
        iconImageView.image = NSImage(resource: bookmark.isExpanded ? .foderOpen : .foderClose)
    }
    
    // MARK: - Editing State
    
    private func updateEditingState(_ isEditing: Bool, bookmark: Bookmark) {
        titleLabel.isHidden = isEditing
        editField.isHidden = !isEditing
        
        if isEditing {
            editField.stringValue = bookmark.title
            // Wait one runloop so the field is visible before focusing and selecting.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Bail out if editing was cancelled before focus could be assigned.
                guard bookmark.isEditing else { return }
                self.window?.makeFirstResponder(self.editField)
                self.editField.selectText(nil)
                // Mark editing active only after focus assignment succeeds.
                self.isEditingActive = true
            }
        } else {
            isEditingActive = false
        }
    }
    
    /// Ends editing and persists the updated title if needed.
    private func commitEditing() {
        let bookmark: Bookmark
        if let direct = item as? Bookmark {
            bookmark = direct
        } else if let provider = item as? UnderlyingBookmarkProviding {
            bookmark = provider.underlyingBookmark
        } else {
            return
        }
        
        let newTitle = editField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Exit editing mode before applying title changes.
        isEditingActive = false
        bookmark.isEditing = false
        
        // Empty input falls back to the previous title.
        if newTitle.isEmpty {
            editField.stringValue = bookmark.title
            return
        }
        
        // Persist only when the title actually changed.
        if newTitle != bookmark.title {
            editDelegate?.bookmarkCellDidEndEditing(bookmark, newTitle: newTitle)
        }
    }
    
    /// Cancels editing and restores the previous title.
    private func cancelEditing() {
        let bookmark: Bookmark
        if let direct = item as? Bookmark {
            bookmark = direct
        } else if let provider = item as? UnderlyingBookmarkProviding {
            bookmark = provider.underlyingBookmark
        } else {
            return
        }
        isEditingActive = false
        bookmark.isEditing = false
        editField.stringValue = bookmark.title
    }
}

// MARK: - NSTextFieldDelegate
extension BookmarkCellView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        // Ignore end-editing events fired during cell reuse or failed activation.
        guard isEditingActive else { return }
        commitEditing()
    }
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Commit on Enter.
            commitEditing()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Cancel on Escape.
            cancelEditing()
            return true
        }
        return false
    }
}
