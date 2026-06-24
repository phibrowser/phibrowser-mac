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
        view.layer?.cornerRadius = 7
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

    private lazy var detailLabel: NSTextField = {
        let label = SearchTabsResultCellView.makeLabel(font: .systemFont(ofSize: 12, weight: .regular))
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var closeButtonHostingView: ZeroSafeAreaHostingView<AnyView> = {
        let view = ZeroSafeAreaHostingView(rootView: makeCloseButtonRootView())
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.toolTip = NSLocalizedString("Close Tab", comment: "Search Tabs - Close open tab button tooltip")
        view.isHidden = true
        return view
    }()

    private var titleTrailingToSuperviewConstraint: Constraint?
    private var titleTrailingToCloseButtonConstraint: Constraint?

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
        updateFavicon(for: item, profileId: profileId)
        let title = Self.title(for: item)
        let detail = Self.detailText(for: item)
        let highlightColor = ThemedColor.themeColor
            .resolve(in: self)
            .withAlphaComponent(selected ? 0.45 : 0.32)
        titleLabel.attributedStringValue = Self.highlightedString(
            title,
            query: query,
            font: titleLabel.font ?? .systemFont(ofSize: 13, weight: .regular),
            textColor: titleLabel.textColor ?? .labelColor,
            highlightColor: highlightColor
        )
        detailLabel.attributedStringValue = Self.highlightedString(
            detail,
            query: query,
            font: detailLabel.font ?? .systemFont(ofSize: 12, weight: .regular),
            textColor: detailLabel.textColor ?? .secondaryLabelColor,
            highlightColor: highlightColor
        )
        detailLabel.isHidden = detail.isEmpty
        updateSelected(selected)
    }

    func updateSelected(_ selected: Bool) {
        isSelected = selected
        updateAppearance()
    }

    private func setupViews() {
        wantsLayer = true
        addSubview(backgroundView)
        backgroundView.addSubview(iconView)
        backgroundView.addSubview(titleLabel)
        backgroundView.addSubview(detailLabel)
        backgroundView.addSubview(closeButtonHostingView)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(18)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(12)
            make.top.equalToSuperview().offset(7)
            self.titleTrailingToSuperviewConstraint = make.trailing.equalToSuperview().offset(-12).constraint
            self.titleTrailingToCloseButtonConstraint = make.trailing.equalTo(closeButtonHostingView.snp.leading).offset(-8).constraint
        }
        detailLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.top.equalTo(titleLabel.snp.bottom).offset(3)
            make.trailing.equalTo(titleLabel)
            make.bottom.equalToSuperview().offset(-7)
        }
        closeButtonHostingView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(24)
        }

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closeButtonHostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeButtonHostingView.setContentHuggingPriority(.required, for: .horizontal)
        titleTrailingToCloseButtonConstraint?.isActive = false
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        if isSelected {
            backgroundColor = ThemedColor.themeColor.resolve(in: self).withAlphaComponent(0.32)
        } else if isHovered {
            backgroundColor = ThemedColor.themeColor.resolve(in: self).withAlphaComponent(0.16)
        } else {
            backgroundColor = .clear
        }
        backgroundView.layer?.backgroundColor = backgroundColor.cgColor

        let shouldShowCloseButton = (isHovered || isSelected) && (item?.isClosableOpenTab ?? false)
        closeButtonHostingView.isHidden = !shouldShowCloseButton
        titleTrailingToSuperviewConstraint?.isActive = !shouldShowCloseButton
        titleTrailingToCloseButtonConstraint?.isActive = shouldShowCloseButton
        backgroundView.layoutSubtreeIfNeeded()
    }

    private func makeCloseButtonRootView() -> AnyView {
        AnyView(
            UnifiedTabCloseButton { [weak self] in
                self?.closeButtonClicked()
            }
            .foregroundColor(Color(nsColor: .labelColor))
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

    private static func detail(for item: SearchTabsItem) -> String {
        if let relation = item.splitRelation {
            return NSLocalizedString(
                "Split with",
                comment: "Search Tabs - Prefix for the split partner shown in a result row"
            ) + " \(relation.partnerTitle)"
        }

        if item.displayMode == .split, let secondary = item.secondary {
            return [displayURLText(for: item.primary.url), displayURLText(for: secondary.url)]
                .filter { !$0.isEmpty }
                .joined(separator: "  •  ")
        }

        return displayURLText(for: item.primary.url)
    }

    private static func detailText(for item: SearchTabsItem) -> String {
        [detail(for: item), dateText(for: item)]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private static func dateText(for item: SearchTabsItem) -> String {
        if item.state.isActive {
            return NSLocalizedString("Active", comment: "Search Tabs - Trailing label for the active tab result")
        }
        return item.state.lastActiveElapsedText ?? ""
    }

    private static func displayTitle(for pane: SearchTabsPane) -> String {
        guard let rawURL = pane.url, rawURL.hasPrefix("chrome://") else {
            return pane.title
        }
        return URLProcessor.phiBrandEnsuredUrlString(pane.title)
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
