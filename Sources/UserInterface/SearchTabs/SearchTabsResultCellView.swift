// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import SwiftUI

protocol SearchTabsResultCellViewDelegate: AnyObject {
    func searchTabsResultCellViewDidHoverBookmarkRoot(_ cellView: SearchTabsResultCellView, item: SearchTabsItem)
    func searchTabsResultCellViewDidRequestClose(_ cellView: SearchTabsResultCellView, item: SearchTabsItem)
}

final class SearchTabsResultCellView: NSTableCellView {
    weak var delegate: SearchTabsResultCellViewDelegate?

    private var item: SearchTabsItem?
    private var trackingArea: NSTrackingArea?
    private var themeObserver = ThemeObserver.shared
    private var themeObservation: AnyObject?
    private var faviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private var faviconItemID: String?
    private var isSelected = false
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else {
                return
            }
            updateAppearance()
        }
    }

    private lazy var backgroundView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.cornerCurve = .continuous
        return view
    }()

    private lazy var iconView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        return imageView
    }()

    private lazy var titleLabel: NSTextField = {
        let label = SearchTabsResultCellView.makeLabel(
            font: .systemFont(ofSize: 13, weight: .regular),
            textField: TrailingFadeTextField(),
            lineBreakMode: .byClipping,
            truncatesLastVisibleLine: false
        )
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        return label
    }()

    private lazy var activeTimeLabel: NSTextField = {
        let label = SearchTabsResultCellView.makeLabel(font: .systemFont(ofSize: 13, weight: .regular))
        label.textColor = ThemedColor.textTertiary.resolve(in: self)
        label.isHidden = true
        return label
    }()

    private lazy var closeButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeCloseButtonRootView())
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.toolTip = NSLocalizedString("searchTabs.result.closeTabButtonTooltip", value: "Close Tab", comment: "Search Tabs - Close open tab button tooltip")
        view.isHidden = true
        return view
    }()

    private var titleTrailingToSuperviewConstraint: Constraint?
    private var titleTrailingToActiveTimeConstraint: Constraint?
    private var titleTrailingToCloseButtonConstraint: Constraint?
    private var titleText = ""
    private var query = ""
    private var closeButtonUsesSelectedColor = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        faviconLoadHandle?.cancel()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        updateHoverStateFromCurrentMouseLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        themeObserver.rebind(to: themeStateProvider)
        updateAppearance()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if let item, item.kind == .bookmarkRoot {
            delegate?.searchTabsResultCellViewDidHoverBookmarkRoot(self, item: item)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    func configure(with item: SearchTabsItem, profileId: String?, selected: Bool, query: String) {
        self.item = item
        self.titleText = Self.title(for: item)
        self.query = query
        activeTimeLabel.stringValue = Self.dateText(for: item)
        updateFavicon(for: item, profileId: profileId)
        updateSelected(selected)
    }

    func updateSelected(_ selected: Bool) {
        isSelected = selected
        updateAppearance()
    }

    private func setupViews() {
        themeObserver = ThemeObserver(themeSource: themeStateProvider)
        wantsLayer = true
        addSubview(backgroundView)
        backgroundView.addSubview(iconView)
        backgroundView.addSubview(titleLabel)
        backgroundView.addSubview(activeTimeLabel)
        backgroundView.addSubview(closeButtonHostingView)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(16)
            make.centerY.equalToSuperview()
            self.titleTrailingToSuperviewConstraint = make.trailing.equalToSuperview().offset(-12).constraint
            self.titleTrailingToActiveTimeConstraint = make.trailing.equalTo(activeTimeLabel.snp.leading).offset(-16).constraint
            self.titleTrailingToCloseButtonConstraint = make.trailing.equalTo(closeButtonHostingView.snp.leading).offset(-8).constraint
        }
        activeTimeLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
        }
        closeButtonHostingView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(24)
        }

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        activeTimeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        activeTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        closeButtonHostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeButtonHostingView.setContentHuggingPriority(.required, for: .horizontal)
        titleTrailingToActiveTimeConstraint?.isActive = false
        titleTrailingToCloseButtonConstraint?.isActive = false

        themeObservation = subscribe { [weak self] _, _ in
            self?.updateAppearance()
        }
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        if isSelected {
            backgroundColor = ThemedColor.themeColor.resolve(in: self)
        } else if isHovered {
            backgroundColor = ThemedColor.themeColor.resolve(in: self).withAlphaComponent(0.16)
        } else {
            backgroundColor = .clear
        }
        backgroundView.layer?.backgroundColor = backgroundColor.cgColor

        let shouldShowCloseButton = (isHovered || isSelected) && (item?.isClosableOpenTab ?? false)
        let shouldShowActiveTime = !shouldShowCloseButton && !activeTimeLabel.stringValue.isEmpty
        closeButtonHostingView.isHidden = !shouldShowCloseButton
        activeTimeLabel.isHidden = !shouldShowActiveTime

        titleTrailingToSuperviewConstraint?.isActive = false
        titleTrailingToActiveTimeConstraint?.isActive = false
        titleTrailingToCloseButtonConstraint?.isActive = false
        if shouldShowCloseButton {
            titleTrailingToCloseButtonConstraint?.isActive = true
        } else if shouldShowActiveTime {
            titleTrailingToActiveTimeConstraint?.isActive = true
        } else {
            titleTrailingToSuperviewConstraint?.isActive = true
        }

        updateTextAppearance()
        updateCloseButtonAppearance()
        backgroundView.layoutSubtreeIfNeeded()
    }

    private func updateTextAppearance() {
        let textColor = isSelected
            ? NSColor.white.withAlphaComponent(0.85)
            : ThemedColor.textPrimary.resolve(in: self)
        let highlightColor = isSelected
            ? NSColor.white.withAlphaComponent(0.16)
            : ThemedColor.themeColor.resolve(in: self).withAlphaComponent(0.32)
        titleLabel.attributedStringValue = Self.highlightedString(
            titleText,
            query: query,
            font: titleLabel.font ?? .systemFont(ofSize: 13, weight: .regular),
            textColor: textColor,
            highlightColor: highlightColor
        )
        activeTimeLabel.textColor = isSelected
            ? .white.withAlphaComponent(currentAppearance == .light ? 0.4 : 0.3)
            : ThemedColor.textTertiary.resolve(in: self)
    }

    private func updateCloseButtonAppearance() {
        guard closeButtonUsesSelectedColor != isSelected else {
            return
        }
        closeButtonUsesSelectedColor = isSelected
        closeButtonHostingView.rootView = makeCloseButtonRootView()
    }

    private func makeCloseButtonRootView() -> AnyView {
        AnyView(
            UnifiedTabCloseButton { [weak self] in
                self?.closeButtonClicked()
            }
            .themedForeground(isSelected ? .white : .textPrimaryStrong)
            .phiThemeObserver(themeObserver)
        )
    }

    private func closeButtonClicked() {
        guard let item, item.isClosableOpenTab else {
            return
        }
        delegate?.searchTabsResultCellViewDidRequestClose(self, item: item)
    }

    private func updateHoverStateFromCurrentMouseLocation() {
        guard let window else {
            isHovered = false
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let windowRect = window.convertFromScreen(NSRect(x: screenPoint.x, y: screenPoint.y, width: 1, height: 1))
        let localPoint = convert(windowRect.origin, from: nil)
        isHovered = bounds.contains(localPoint)
    }

    private func updateFavicon(for item: SearchTabsItem, profileId: String?) {
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        faviconItemID = item.id
        iconView.image = Self.placeholderIcon

        let request = ProfileScopedFaviconRequest(
            profileId: profileId,
            pageURLString: item.primary.url,
            snapshotData: item.primary.faviconData
        )
        faviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self] result in
            guard let self, self.faviconItemID == item.id else {
                return
            }
            self.iconView.image = result.image
        }
    }

    private static func makeLabel(
        font: NSFont,
        textField: NSTextField = NSTextField(),
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
        truncatesLastVisibleLine: Bool = true
    ) -> NSTextField {
        let label = textField
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = font
        label.lineBreakMode = lineBreakMode
        label.cell?.lineBreakMode = lineBreakMode
        label.cell?.truncatesLastVisibleLine = truncatesLastVisibleLine
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        return label
    }

    private static func title(for item: SearchTabsItem) -> String {
        if item.displayMode == .split, let secondary = item.secondary {
            return "\(displayTitle(for: item.primary)) / \(displayTitle(for: secondary))"
        }
        return displayTitle(for: item.primary)
    }

    private static func dateText(for item: SearchTabsItem) -> String {
        if item.state.isActive {
            return NSLocalizedString("searchTabs.result.activeStatus", value: "Active", comment: "Search Tabs - Trailing label for the active tab result")
        }
        return item.state.lastActiveElapsedText ?? ""
    }

    private static func displayTitle(for pane: SearchTabsPane) -> String {
        let title: String
        if let rawURL = pane.url, rawURL.hasPrefix("chrome://") {
            title = URLProcessor.phiBrandEnsuredUrlString(pane.title)
        } else {
            title = pane.title
        }

        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return title
        }
        return displayURLText(for: pane.url)
    }

    private static func displayURLText(for rawURL: String?) -> String {
        guard let rawURL, !rawURL.isEmpty else {
            return ""
        }
        guard rawURL.hasPrefix("chrome://") else {
            return hostText(for: rawURL)
        }
        return URLProcessor.phiBrandEnsuredUrlString(rawURL)
    }

    private static func hostText(for rawURL: String?) -> String {
        guard let rawURL, !rawURL.isEmpty else {
            return ""
        }
        if let host = URL(string: rawURL)?.host, !host.isEmpty {
            return host
        }

        var candidate = rawURL
        if let schemeRange = candidate.range(of: "://") {
            candidate = String(candidate[schemeRange.upperBound...])
        }
        while candidate.hasPrefix("/") {
            candidate.removeFirst()
        }
        for separator in ["/", "?", "#"] {
            if let separatorRange = candidate.range(of: separator) {
                candidate = String(candidate[..<separatorRange.lowerBound])
            }
        }
        return candidate.isEmpty ? rawURL : candidate
    }

    private static var placeholderIcon: NSImage? {
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return image?.withSymbolConfiguration(configuration)
    }

    private static func highlightedString(
        _ string: String,
        query: String,
        font: NSFont,
        textColor: NSColor,
        highlightColor: NSColor
    ) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
            ]
        )
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !string.isEmpty else {
            return attributedString
        }

        let source = string as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.location < source.length {
            let matchRange = source.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard matchRange.location != NSNotFound, matchRange.length > 0 else {
                break
            }
            attributedString.addAttribute(.backgroundColor, value: highlightColor, range: matchRange)

            let nextLocation = matchRange.location + matchRange.length
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return attributedString
    }
}
