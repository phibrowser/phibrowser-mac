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

    private let primaryIconView = BookmarkManagerCellView.makeIconView()
    private let secondaryIconView = BookmarkManagerCellView.makeIconView()
    private let splitMarkerView = NSImageView()
    private let valueField = NSTextField()
    private let secondaryValueField = NSTextField()
    private let laneSeparator = NSBox()
    private let primaryLaneGuide = NSLayoutGuide()
    private let secondaryLaneGuide = NSLayoutGuide()

    private var activeLayoutConstraints: [NSLayoutConstraint] = []
    private var primaryFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var secondaryFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var representedScope: BookmarkManagementScope?
    private var configuredColumn: Column = .website
    private var configuredEditableValue: String?
    private var originalEditingValue = ""
    private var commitHandler: ((String) -> Bool)?
    private var isEditingValue = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    deinit {
        primaryFaviconHandle?.cancel()
        secondaryFaviconHandle?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopEditingWithoutCommit()
        cancelFaviconLoads()
        representedBookmarkGuid = nil
        representedScope = nil
        configuredEditableValue = nil
        commitHandler = nil
        primaryIconView.image = nil
        secondaryIconView.image = nil
        secondaryIconView.isHidden = true
        splitMarkerView.isHidden = true
        valueField.stringValue = ""
        valueField.toolTip = nil
        secondaryValueField.stringValue = ""
        secondaryValueField.toolTip = nil
        secondaryValueField.isHidden = true
        laneSeparator.isHidden = true
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
        updateLayout(column: column, isSplit: isSplit)
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

        valueField.toolTip = valueField.stringValue
        secondaryValueField.toolTip = isSplit ? secondaryValueField.stringValue : nil
        updateEditingAppearance(isEditing: false)
    }

    func beginEditing() {
        guard !isEditingValue,
              let editableValue = configuredEditableValue,
              let window else {
            return
        }

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
        if let movement = notification.userInfo?["NSTextMovement"] as? Int,
           movement == NSTextMovement.cancel.rawValue {
            cancelEditing()
            return
        }
        commitEditing(valueField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === valueField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitEditing(textView.string)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        return false
    }

    private func buildLayout() {
        configureValueField(valueField)
        valueField.delegate = self
        configureValueField(secondaryValueField)

        splitMarkerView.translatesAutoresizingMaskIntoConstraints = false
        splitMarkerView.image = NSImage(
            systemSymbolName: "rectangle.split.2x1",
            accessibilityDescription: nil
        )
        splitMarkerView.imageScaling = .scaleProportionallyDown
        splitMarkerView.contentTintColor = .secondaryLabelColor

        laneSeparator.translatesAutoresizingMaskIntoConstraints = false
        laneSeparator.boxType = .separator
        laneSeparator.alphaValue = 0.45

        addLayoutGuide(primaryLaneGuide)
        addLayoutGuide(secondaryLaneGuide)
        addSubview(splitMarkerView)
        addSubview(primaryIconView)
        addSubview(secondaryIconView)
        addSubview(valueField)
        addSubview(secondaryValueField)
        addSubview(laneSeparator)
        textField = valueField
        imageView = primaryIconView

        NSLayoutConstraint.activate([
            primaryLaneGuide.topAnchor.constraint(equalTo: topAnchor),
            primaryLaneGuide.bottomAnchor.constraint(equalTo: centerYAnchor),
            primaryLaneGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            primaryLaneGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            secondaryLaneGuide.topAnchor.constraint(equalTo: centerYAnchor),
            secondaryLaneGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
            secondaryLaneGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            secondaryLaneGuide.trailingAnchor.constraint(equalTo: trailingAnchor),

            primaryIconView.widthAnchor.constraint(equalToConstant: 16),
            primaryIconView.heightAnchor.constraint(equalToConstant: 16),
            secondaryIconView.widthAnchor.constraint(equalToConstant: 16),
            secondaryIconView.heightAnchor.constraint(equalToConstant: 16),
            splitMarkerView.widthAnchor.constraint(equalToConstant: 16),
            splitMarkerView.heightAnchor.constraint(equalToConstant: 16),
            laneSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
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

    private func updateLayout(column: Column, isSplit: Bool) {
        NSLayoutConstraint.deactivate(activeLayoutConstraints)

        splitMarkerView.isHidden = column != .website || !isSplit
        primaryIconView.isHidden = column != .website
        secondaryIconView.isHidden = column != .website || !isSplit
        secondaryValueField.isHidden = !isSplit
        laneSeparator.isHidden = !isSplit

        switch (column, isSplit) {
        case (.website, false):
            activeLayoutConstraints = [
                primaryIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                primaryIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                valueField.leadingAnchor.constraint(equalTo: primaryIconView.trailingAnchor, constant: 8),
                valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]

        case (.website, true):
            activeLayoutConstraints = [
                splitMarkerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                splitMarkerView.centerYAnchor.constraint(equalTo: primaryLaneGuide.centerYAnchor),
                primaryIconView.leadingAnchor.constraint(equalTo: splitMarkerView.trailingAnchor, constant: 8),
                primaryIconView.centerYAnchor.constraint(equalTo: primaryLaneGuide.centerYAnchor),
                secondaryIconView.leadingAnchor.constraint(equalTo: primaryIconView.leadingAnchor),
                secondaryIconView.centerYAnchor.constraint(equalTo: secondaryLaneGuide.centerYAnchor),
                valueField.leadingAnchor.constraint(equalTo: primaryIconView.trailingAnchor, constant: 8),
                valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                valueField.centerYAnchor.constraint(equalTo: primaryLaneGuide.centerYAnchor),
                secondaryValueField.leadingAnchor.constraint(equalTo: secondaryIconView.trailingAnchor, constant: 8),
                secondaryValueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                secondaryValueField.centerYAnchor.constraint(equalTo: secondaryLaneGuide.centerYAnchor),
                laneSeparator.leadingAnchor.constraint(equalTo: valueField.leadingAnchor),
                laneSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                laneSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]

        case (.address, false):
            activeLayoutConstraints = [
                valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]

        case (.address, true):
            activeLayoutConstraints = [
                valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                valueField.centerYAnchor.constraint(equalTo: primaryLaneGuide.centerYAnchor),
                secondaryValueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                secondaryValueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                secondaryValueField.centerYAnchor.constraint(equalTo: secondaryLaneGuide.centerYAnchor),
                laneSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                laneSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                laneSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }

        NSLayoutConstraint.activate(activeLayoutConstraints)
    }

    private func configureWebsite(
        bookmark: Bookmark,
        scope: BookmarkManagementScope,
        isSplit: Bool
    ) {
        valueField.stringValue = Self.laneTitle(
            title: bookmark.title,
            fallbackURLString: bookmark.url
        )
        secondaryValueField.stringValue = isSplit
            ? Self.laneTitle(title: bookmark.secondaryTitle, fallbackURLString: bookmark.secondaryUrl)
            : ""
        valueField.textColor = .labelColor
        secondaryValueField.textColor = .labelColor

        if bookmark.isFolder {
            primaryIconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            primaryIconView.contentTintColor = .secondaryLabelColor
            secondaryIconView.image = nil
            secondaryIconView.isHidden = true
            return
        }

        primaryIconView.contentTintColor = nil
        secondaryIconView.contentTintColor = nil
        secondaryIconView.isHidden = !isSplit
        loadFavicon(
            into: primaryIconView,
            pageURLString: bookmark.url,
            snapshotData: bookmark.liveFaviconData ?? bookmark.cachedFaviconData,
            scope: scope,
            expectedGuid: bookmark.guid,
            isPrimary: true
        )
        if isSplit {
            loadFavicon(
                into: secondaryIconView,
                pageURLString: bookmark.secondaryUrl,
                snapshotData: nil,
                scope: scope,
                expectedGuid: bookmark.guid,
                isPrimary: false
            )
        } else {
            secondaryIconView.image = nil
        }
    }

    private func configureAddress(bookmark: Bookmark, isSplit: Bool) {
        valueField.textColor = .secondaryLabelColor
        secondaryValueField.textColor = .secondaryLabelColor
        primaryIconView.image = nil
        secondaryIconView.image = nil

        if bookmark.isFolder {
            valueField.stringValue = Self.localizedChildCount(bookmark.children.count)
        } else if isSplit {
            valueField.stringValue = Self.displayURL(bookmark.url)
            secondaryValueField.stringValue = Self.displayURL(bookmark.secondaryUrl)
        } else {
            valueField.stringValue = Self.displayURL(bookmark.url)
        }
        if !isSplit {
            secondaryValueField.stringValue = ""
        }
    }

    private func loadFavicon(
        into imageView: NSImageView,
        pageURLString: String?,
        snapshotData: Data?,
        scope: BookmarkManagementScope,
        expectedGuid: String,
        isPrimary: Bool
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
        if isPrimary {
            primaryFaviconHandle = handle
        } else {
            secondaryFaviconHandle = handle
        }
    }

    private func cancelFaviconLoads() {
        primaryFaviconHandle?.cancel()
        primaryFaviconHandle = nil
        secondaryFaviconHandle?.cancel()
        secondaryFaviconHandle = nil
    }

    private func commitEditing(_ value: String) {
        guard isEditingValue else { return }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            NSSound.beep()
            finishEditing(displayedValue: originalEditingValue)
            return
        }

        guard commitHandler?(trimmedValue) == true else {
            NSSound.beep()
            finishEditing(displayedValue: originalEditingValue)
            return
        }

        configuredEditableValue = trimmedValue
        finishEditing(displayedValue: trimmedValue)
    }

    private func cancelEditing() {
        guard isEditingValue else { return }
        finishEditing(displayedValue: originalEditingValue)
    }

    private func finishEditing(displayedValue: String) {
        isEditingValue = false
        valueField.stringValue = displayedValue
        valueField.toolTip = displayedValue
        updateEditingAppearance(isEditing: false)
        if valueField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
    }

    private func stopEditingWithoutCommit() {
        guard isEditingValue else { return }
        isEditingValue = false
        valueField.stringValue = originalEditingValue
        updateEditingAppearance(isEditing: false)
        if valueField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
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
