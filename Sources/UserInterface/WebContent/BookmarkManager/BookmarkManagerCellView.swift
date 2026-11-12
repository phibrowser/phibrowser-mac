// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// A native two-column bookmark row used by the bookmark manager outline.
final class BookmarkManagerCellView: NSTableCellView, NSTextFieldDelegate {
    enum Column {
        case website
        case address
    }

    private(set) var representedBookmarkGuid: String?

    private let iconViews = (0..<4).map { _ in BookmarkManagerCellView.makeIconView() }
    private let valueFields = (0..<4).map { _ in NSTextField() }
    private let laneGuides = (0..<4).map { _ in NSLayoutGuide() }
    private let laneSeparators = (0..<3).map { _ in NSBox() }
    private let splitMarkerView = NSImageView()
    private var valueField: NSTextField { valueFields[0] }

    private var activeLayoutConstraints: [NSLayoutConstraint] = []
    private var faviconHandles: [ProfileScopedFaviconLoadHandle] = []
    private var representedScope: BookmarkManagementScope?
    private var configuredColumn: Column = .website
    private var configuredEditableValue: String?
    private var originalEditingValue = ""
    private var commitHandler: ((String) -> Bool)?
    private var isEditingValue = false
    private var editingGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    deinit {
        faviconHandles.forEach { $0.cancel() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopEditingWithoutCommit()
        cancelFaviconLoads()
        representedBookmarkGuid = nil
        representedScope = nil
        configuredEditableValue = nil
        commitHandler = nil
        for icon in iconViews {
            icon.image = nil
            icon.isHidden = true
        }
        for field in valueFields {
            field.stringValue = ""
            field.toolTip = nil
            field.isHidden = true
        }
        laneSeparators.forEach { $0.isHidden = true }
        splitMarkerView.isHidden = true
    }

    func configure(
        bookmark: Bookmark,
        scope: BookmarkManagementScope,
        column: Column,
        onCommit: ((String) -> Bool)?
    ) {
        stopEditingWithoutCommit()
        cancelFaviconLoads()

        representedBookmarkGuid = bookmark.guid
        representedScope = scope
        configuredColumn = column
        commitHandler = onCommit

        let isSplit = bookmark.secondaryUrl?.isEmpty == false
        splitMarkerView.image = NSImage(
            systemSymbolName: Self.splitMarkerSymbolName(for: bookmark.layout),
            accessibilityDescription: nil
        )
        updateLayout(column: column, laneCount: isSplit ? 2 + bookmark.splitExtraPanes.count : 1)
        switch column {
        case .website:
            configureWebsite(bookmark: bookmark, scope: scope, isSplit: isSplit)
            configuredEditableValue = (isSplit || onCommit == nil) ? nil : bookmark.title
        case .address:
            configureAddress(bookmark: bookmark, isSplit: isSplit)
            configuredEditableValue = (onCommit != nil && !bookmark.isFolder && !isSplit)
                ? Self.displayURL(bookmark.url)
                : nil
        }

        for field in valueFields {
            field.toolTip = field.isHidden ? nil : field.stringValue
        }
        updateEditingAppearance(isEditing: false)
    }

    func beginEditing() {
        guard !isEditingValue,
              let editableValue = configuredEditableValue,
              let window else {
            return
        }

        editingGeneration += 1
        isEditingValue = true
        originalEditingValue = editableValue
        valueField.stringValue = editableValue
        updateEditingAppearance(isEditing: true)

        window.makeFirstResponder(valueField)
        valueField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditingValue, notification.object as? NSTextField === valueField else {
            return
        }
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        endEditing(
            value: movement == NSTextMovement.cancel.rawValue ? nil : valueField.stringValue,
            deferUntilResigned: true
        )
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === valueField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endEditing(value: textView.string)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(value: nil)
            return true
        }
        return false
    }

    private func buildLayout() {
        for field in valueFields {
            configureValueField(field)
            addSubview(field)
        }
        valueField.delegate = self
        for icon in iconViews {
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
            ])
        }
        for guide in laneGuides { addLayoutGuide(guide) }
        for separator in laneSeparators {
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.boxType = .separator
            separator.alphaValue = 0.45
            addSubview(separator)
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        splitMarkerView.translatesAutoresizingMaskIntoConstraints = false
        splitMarkerView.imageScaling = .scaleProportionallyDown
        splitMarkerView.contentTintColor = .secondaryLabelColor
        addSubview(splitMarkerView)
        NSLayoutConstraint.activate([
            splitMarkerView.widthAnchor.constraint(equalToConstant: 16),
            splitMarkerView.heightAnchor.constraint(equalToConstant: 16),
        ])
        textField = valueField
        imageView = iconViews[0]
    }

    private func configureValueField(_ field: NSTextField) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 13)
        field.alignment = .left
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    private func updateLayout(column: Column, laneCount: Int) {
        NSLayoutConstraint.deactivate(activeLayoutConstraints)
        activeLayoutConstraints = []
        let count = min(laneCount, valueFields.count)
        let isSplit = count > 1
        splitMarkerView.isHidden = column != .website || !isSplit

        for index in valueFields.indices {
            let field = valueFields[index]
            let icon = iconViews[index]
            field.isHidden = index >= count
            icon.isHidden = index >= count || column != .website
            guard index < count else { continue }
            let guide = laneGuides[index]
            activeLayoutConstraints += [
                guide.topAnchor.constraint(equalTo: index == 0 ? topAnchor : laneGuides[index - 1].bottomAnchor),
                guide.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 1 / CGFloat(count)),
                guide.leadingAnchor.constraint(equalTo: leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: trailingAnchor),
                field.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ]
            if column == .website {
                activeLayoutConstraints += [
                    icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: isSplit ? 32 : 8),
                    icon.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
                    field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                ]
            } else {
                activeLayoutConstraints.append(field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8))
            }
        }
        for (index, separator) in laneSeparators.enumerated() {
            separator.isHidden = index >= count - 1
            guard !separator.isHidden else { continue }
            activeLayoutConstraints += [
                separator.leadingAnchor.constraint(equalTo: valueField.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                separator.centerYAnchor.constraint(equalTo: laneGuides[index].bottomAnchor),
            ]
        }
        if column == .website && isSplit {
            activeLayoutConstraints += [
                splitMarkerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                splitMarkerView.centerYAnchor.constraint(equalTo: laneGuides[0].centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(activeLayoutConstraints)
    }

    private func paneValues(for bookmark: Bookmark, isSplit: Bool) -> [(url: String?, title: String?)] {
        var panes: [(url: String?, title: String?)] = [(bookmark.url, bookmark.title)]
        if isSplit {
            panes.append((bookmark.secondaryUrl, bookmark.secondaryTitle))
            panes += bookmark.splitExtraPanes.map { ($0.url, $0.title) }
        }
        return Array(panes.prefix(valueFields.count))
    }

    private func configureWebsite(
        bookmark: Bookmark,
        scope: BookmarkManagementScope,
        isSplit: Bool
    ) {
        for (index, pane) in paneValues(for: bookmark, isSplit: isSplit).enumerated() {
            let field = valueFields[index]
            let icon = iconViews[index]
            field.stringValue = Self.laneTitle(title: pane.title, fallbackURLString: pane.url)
            field.textColor = .labelColor
            if bookmark.isFolder {
                icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                icon.contentTintColor = .secondaryLabelColor
            } else {
                icon.contentTintColor = nil
                loadFavicon(
                    into: icon,
                    pageURLString: pane.url,
                    snapshotData: index == 0 ? bookmark.liveFaviconData ?? bookmark.cachedFaviconData : nil,
                    scope: scope,
                    expectedGuid: bookmark.guid
                )
            }
        }
    }

    private func configureAddress(bookmark: Bookmark, isSplit: Bool) {
        iconViews.forEach { $0.image = nil }
        for (index, pane) in paneValues(for: bookmark, isSplit: isSplit).enumerated() {
            valueFields[index].textColor = .secondaryLabelColor
            valueFields[index].stringValue = bookmark.isFolder
                ? Self.localizedChildCount(bookmark.children.count)
                : Self.displayURL(pane.url)
        }
    }

    private func loadFavicon(
        into imageView: NSImageView,
        pageURLString: String?,
        snapshotData: Data?,
        scope: BookmarkManagementScope,
        expectedGuid: String
    ) {
        imageView.image = Self.faviconPlaceholder
        let request = ProfileScopedFaviconRequest(
            profileId: scope.profileId,
            pageURLString: pageURLString,
            snapshotData: snapshotData
        )
        let handle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self, weak imageView] result in
            guard let self,
                  self.representedBookmarkGuid == expectedGuid,
                  self.representedScope == scope,
                  self.configuredColumn == .website else {
                return
            }
            imageView?.image = result.image
        }
        if let handle {
            faviconHandles.append(handle)
        }
    }

    private func cancelFaviconLoads() {
        faviconHandles.forEach { $0.cancel() }
        faviconHandles.removeAll()
        for icon in iconViews { icon.image = nil }
        for field in valueFields {
            field.stringValue = ""
            field.toolTip = nil
        }
    }

    private func endEditing(value: String?, deferUntilResigned: Bool = false) {
        guard isEditingValue else { return }
        isEditingValue = false
        let generation = editingGeneration
        let originalValue = originalEditingValue
        let handler = commitHandler

        // Preserve the original commit even if removing the row reuses or releases this cell.
        let finish = { [weak self] in
            var displayedValue = originalValue
            if let value {
                let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedValue.isEmpty, handler?(trimmedValue) == true {
                    displayedValue = trimmedValue
                } else {
                    NSSound.beep()
                }
            }

            // A commit can synchronously reconfigure the cell or begin another edit.
            guard let self, self.editingGeneration == generation else { return }
            self.configuredEditableValue = displayedValue
            self.finishEditing(displayedValue: displayedValue)
        }

        if deferUntilResigned {
            // AppKit may be removing rows while delivering the end-editing notification.
            // Changing isEditable here restarts its field editor and reenters row lookup.
            DispatchQueue.main.async(execute: finish)
        } else {
            if valueField.currentEditor() != nil {
                window?.makeFirstResponder(nil)
            }
            finish()
        }
    }

    private func finishEditing(displayedValue: String) {
        valueField.stringValue = displayedValue
        valueField.toolTip = displayedValue
        updateEditingAppearance(isEditing: false)
    }

    private func stopEditingWithoutCommit() {
        editingGeneration += 1
        isEditingValue = false
        if valueField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
        finishEditing(displayedValue: originalEditingValue)
    }

    private func updateEditingAppearance(isEditing: Bool) {
        valueField.isEditable = isEditing
        valueField.isSelectable = isEditing
        valueField.drawsBackground = isEditing
        valueField.backgroundColor = isEditing ? .textBackgroundColor : .clear
        valueField.focusRingType = isEditing ? .default : .none
    }

    private static func makeIconView() -> NSImageView {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 3
        imageView.layer?.masksToBounds = true
        return imageView
    }

    private static func laneTitle(title: String?, fallbackURLString: String?) -> String {
        if let title {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }
        }
        guard let fallbackURLString, !fallbackURLString.isEmpty else { return "" }
        return URL(string: fallbackURLString)?.host ?? fallbackURLString
    }

    private static func displayURL(_ rawURL: String?) -> String {
        rawURL.map(URLProcessor.phiBrandEnsuredUrlString) ?? ""
    }

    static func splitMarkerSymbolName(for layout: SplitLayout?) -> String {
        (layout ?? .vertical) == .horizontal
            ? "square.split.1x2"
            : "rectangle.split.2x1"
    }

    private static func localizedChildCount(_ count: Int) -> String {
        if count == 1 {
            return NSLocalizedString(
                "bookmarkManager.folder.singleChildCount",
                value: "1 item",
                comment: "Bookmark manager Address column - child count for a folder containing one item"
            )
        }
        let format = NSLocalizedString(
            "bookmarkManager.folder.multipleChildCount",
            value: "%d items",
            comment: "Bookmark manager Address column - child count for a folder containing zero or multiple items"
        )
        return String.localizedStringWithFormat(format, count)
    }

    private static let faviconPlaceholder = NSImage(
        systemSymbolName: "globe",
        accessibilityDescription: NSLocalizedString(
            "bookmarkManager.faviconPlaceholderAccessibilityLabel",
            value: "Website",
            comment: "Bookmark manager - Accessibility description for a placeholder website favicon"
        )
    ) ?? NSImage()
}
