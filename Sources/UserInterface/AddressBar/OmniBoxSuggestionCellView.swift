// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Kingfisher
protocol OmniBoxSuggestionCellViewDelegate: AnyObject {
    func suggestionCellView(_ cellView: OmniBoxSuggestionCellView, didClick suggestion: OmniBoxSuggestion, at index: Int)
    func suggestionCellView(_ cellView: OmniBoxSuggestionCellView, didRequestDelete suggestion: OmniBoxSuggestion, at index: Int)
}

class OmniBoxSuggestionCellView: NSTableCellView {
    weak var delegate: OmniBoxSuggestionCellViewDelegate?
    
    private var suggestion: OmniBoxSuggestion?
    private var index: Int = 0
    private let showsSwitchToTabHint: Bool
    private let switchToTabAddsSplit: Bool
    private var isHovered: Bool = false {
        didSet {
            updateAppearance()
        }
    }
    
    private lazy var hoverableBg: HoverableView = {
        let bg = HoverableView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.cornerCurve = .continuous
        bg.backgroundColor = .clear
        
        bg.hoverStateChanged = { [weak self] hovered in
            self?.isHovered = hovered
        }
        return bg
    }()
    
    private lazy var iconImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        return imageView
    }()

    private lazy var splitFaviconView = OmniboxSplitFaviconView()
    
    private lazy var titleLabel: NSTextField = {
        let label = NSTextField()
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = NSColor.clear
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.9)
        label.phi.textColor = NSColor.black.withAlphaComponent(0.85) <> NSColor.white.withAlphaComponent(0.85)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.usesSingleLineMode = true
        return label
    }()
    
    private lazy var subtitleLabel: NSTextField = {
        let label = NSTextField()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = NSColor.clear
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.phi.textColor = NSColor.black.withAlphaComponent(0.3) <> NSColor.white.withAlphaComponent(0.3)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.usesSingleLineMode = true
        return label
    }()
    
    private lazy var deleteButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(deleteButtonClicked)
        return button
    }()
    
    private lazy var switchToTabView: SwitchToTabView = {
        let view = SwitchToTabView()
        view.wantsLayer = true
        view.addsSplit = switchToTabAddsSplit
        if let entityHint { view.text = entityHint }
        return view
    }()
    
    private var subTitleTrailingConstraintToSwitchTabView: Constraint?
    private var subTitleTrailingConstraintToSuperView: Constraint?
    private var subTitleTrailingConstraintToCloseButton: Constraint?
    private var switchTabTrailingConstraintToCloseButton: Constraint?
    private var switchTabTrailingConstraintToSuperView: Constraint?
    
    init(
        suggestion: OmniBoxSuggestion,
        index: Int,
        showsSwitchToTabHint: Bool,
        switchToTabAddsSplit: Bool = false
    ) {
        self.showsSwitchToTabHint = showsSwitchToTabHint
        self.switchToTabAddsSplit = switchToTabAddsSplit
        super.init(frame: .zero)
        self.suggestion = suggestion
        self.index = index
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var entityHint: String? {
        switch suggestion?.v2Kind {
        case "pin":
            return NSLocalizedString("addressBar.suggestions.holdCommandToSwitchToPinHint", value: "Hold ⌘ to switch to Pin →", comment: "Omnibox suggestion - Trailing hint on a pinned tab result; choosing it with Command held opens or focuses that pin, without it opens the page in a new tab")
        case "bookmark":
            return NSLocalizedString("addressBar.suggestions.holdCommandToSwitchToBookmarkHint", value: "Hold ⌘ to switch to Bookmark →", comment: "Omnibox suggestion - Trailing hint on a bookmark result; choosing it with Command held opens or focuses that bookmark, without it opens the page in a new tab")
        default:
            return nil
        }
    }

    var isSwitchToTabViewHiddenForTesting: Bool {
        switchToTabView.isHidden
    }
    
    private func setupViews() {
        wantsLayer = true
        addSubview(hoverableBg)
        hoverableBg.addSubview(iconImageView)
        hoverableBg.addSubview(splitFaviconView)
        hoverableBg.addSubview(titleLabel)
        hoverableBg.addSubview(subtitleLabel)
        hoverableBg.addSubview(deleteButton)
        hoverableBg.addSubview(switchToTabView)
        
        hoverableBg.snp.makeConstraints { make in
            make.leading.trailing.top.bottom.equalToSuperview()
        }
        
        iconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(14)
        }

        // Larger than the 14pt icon so four panes stay legible; centered on
        // it so titles stay aligned with the other rows.
        splitFaviconView.snp.makeConstraints { make in
            make.center.equalTo(iconImageView)
            make.width.height.equalTo(18)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(5)
            make.centerY.equalToSuperview()
            make.width.lessThanOrEqualToSuperview().multipliedBy(0.4)
        }
        
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        // Below the row's width so an uncapped split title truncates instead of widening the row;
        // above the subtitle so the subtitle truncates first.
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        
        subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        deleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }
        
        switchToTabView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.height.equalTo(26)
            // Fits the hint text; the title and subtitle truncate first.
            make.width.equalTo(max(128, switchToTabView.labelWidth))
        }
        // The trailing alternatives are mutually exclusive, so they start inactive and
        // updateTrailingConstraints activates one of them.
        switchToTabView.snp.prepareConstraints { make in
            self.switchTabTrailingConstraintToCloseButton = make.trailing.equalTo(deleteButton.snp.leading).offset(-5).constraint
            self.switchTabTrailingConstraintToSuperView = make.trailing.equalToSuperview().offset(-5).constraint
        }

        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel.snp.trailing).offset(2)
            make.centerY.equalToSuperview()
        }
        subtitleLabel.snp.prepareConstraints { make in
            self.subTitleTrailingConstraintToSuperView = make.trailing.equalToSuperview().offset(-5).constraint
            self.subTitleTrailingConstraintToCloseButton = make.trailing.equalTo(deleteButton.snp.leading).offset(-5).constraint
            self.subTitleTrailingConstraintToSwitchTabView = make.trailing.equalTo(switchToTabView.snp.leading).offset(-5).constraint
        }
        
        updateAppearance()
    }
    
    private func updateConstraint(canDelete: Bool, canSwitch: Bool, hovered: Bool) {
        let showDeleteBtn = hovered && canDelete
        
        if showDeleteBtn && canSwitch {
            updateTrailingConstraints(toSuperViewEnabled: false, closeButtonEnabled: false, canShowDeleteBtn: showDeleteBtn, switchViewEnabled: true)
        } else if showDeleteBtn && !canSwitch {
            updateTrailingConstraints(toSuperViewEnabled: false, closeButtonEnabled: true, canShowDeleteBtn: showDeleteBtn, switchViewEnabled: false)
        }
        else if !showDeleteBtn && canSwitch {
            updateTrailingConstraints(toSuperViewEnabled: false, closeButtonEnabled: false, canShowDeleteBtn: false, switchViewEnabled: true)
        } else {
            updateTrailingConstraints(toSuperViewEnabled: true, closeButtonEnabled: false, canShowDeleteBtn: showDeleteBtn, switchViewEnabled: false)
        }
    }
    
    private func updateTrailingConstraints(toSuperViewEnabled superViewEnabled: Bool, closeButtonEnabled: Bool, canShowDeleteBtn: Bool, switchViewEnabled: Bool) {
        AppLogDebug("title: \(titleLabel.stringValue) superViewEnabled: \(superViewEnabled), close: \(closeButtonEnabled), switch: \(switchViewEnabled)")
        
        let trailingConstraints: [(Constraint?, Bool)] = [
            (subTitleTrailingConstraintToSuperView, superViewEnabled),
            (subTitleTrailingConstraintToCloseButton, closeButtonEnabled),
            (subTitleTrailingConstraintToSwitchTabView, switchViewEnabled),
            (switchTabTrailingConstraintToSuperView, !canShowDeleteBtn),
            (switchTabTrailingConstraintToCloseButton, canShowDeleteBtn),
        ]
        // Deactivate first so two exclusive trailing constraints are never active together.
        for (constraint, isActive) in trailingConstraints where !isActive {
            constraint?.isActive = false
        }
        for (constraint, isActive) in trailingConstraints where isActive {
            constraint?.isActive = true
        }

        deleteButton.isHidden = !canShowDeleteBtn
        switchToTabView.isHidden = !switchViewEnabled
        
        hoverableBg.layoutSubtreeIfNeeded()
    }
    
    func configure(with suggestion: OmniBoxSuggestion, index: Int) {
        self.suggestion = suggestion
        self.index = index
        
        let title = suggestion.swapContentsAndDescription ? suggestion.subtitle : suggestion.title
        // A split's joined title names its pages; one pane's URL would mislead.
        let subtitle = suggestion.isNativeSplit ? nil
            : suggestion.swapContentsAndDescription ? suggestion.title : suggestion.subtitle
        titleLabel.stringValue = title ?? ""

        let titleSize = titleLabel.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: titleLabel.frame.height))
        let maxTitleWidth: CGFloat = 200

        titleLabel.snp.remakeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(5)
            make.centerY.equalToSuperview()
            if !suggestion.isNativeSplit, titleSize.width > maxTitleWidth {
                make.width.equalTo(maxTitleWidth)
            }
        }

        if let subtitle, !subtitle.isEmpty {
            subtitleLabel.stringValue = "- \(subtitle)"
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.stringValue = ""
            subtitleLabel.isHidden = true
        }
        
        deleteButton.isHidden = !suggestion.canDelete

        if let panes = suggestion.v2Panes, suggestion.isNativeSplit {
            iconImageView.kf.cancelDownloadTask()
            iconImageView.image = nil
            iconImageView.isHidden = true
            splitFaviconView.isHidden = false
            splitFaviconView.configure(pageURLs: panes.map(\.url))
        } else {
            iconImageView.isHidden = false
            splitFaviconView.isHidden = true
            splitFaviconView.configure(pageURLs: [])
            OmniSuggestionIconProvier.updateImage(for: iconImageView, with: suggestion)
        }

        updateAppearance()
    }
    
    // MARK: - Actions
    
    @objc private func viewClicked() {
        guard let suggestion = suggestion else { return }
        delegate?.suggestionCellView(self, didClick: suggestion, at: index)
    }
    
    @objc private func deleteButtonClicked() {
        guard let suggestion = suggestion else { return }
        delegate?.suggestionCellView(self, didRequestDelete: suggestion, at: index)
    }
    
    // MARK: - Appearance
    
    func updateAppearance() {
        let engine = suggestion?.keywordSearchEngine
        let accent = engine?.accentColor ?? .themeColor
        hoverableBg.phi.selectedColor = accent.mapper
        hoverableBg.phi.hoveredColor = accent.opacity(0.16).mapper
        let rowView = superview as? NSTableRowView
        let isSelected = rowView?.isSelected ?? false
        let canShowSwitchToTab = entityHint != nil || (showsSwitchToTabHint
            && (suggestion?.hasTabMatch ?? false))
        hoverableBg.isSelected = isSelected
        updateConstraint(
            canDelete: suggestion?.canDelete ?? false,
            canSwitch: canShowSwitchToTab,
            hovered: isHovered
        )
        if canShowSwitchToTab {
            switchToTabView.setEmphasized(isSelected || isHovered)
        }
        
        let isLightMode = (currentAppearance == .light)
        
        let isBuiltInIcon: Bool = {
            guard let suggestion else { return false }
            if suggestion.faviconPageURL != nil || suggestion.keywordSearchFaviconURL != nil { return false }
            return suggestion.iconName != nil || suggestion.iconURL == nil || (suggestion.iconURL?.isEmpty ?? false)
        }()
        if !isBuiltInIcon { iconImageView.contentTintColor = nil }
        
        if isSelected, engine?.brandColor != nil {
            // Spotify's bright green needs dark text; other brand fills use white.
            let foreground: NSColor = engine?.keyword.lowercased() == "spotify.com" ? .black : .white
            titleLabel.phi.textColor = ThemedColor(foreground).nsColorMapper
            subtitleLabel.phi.textColor = ThemedColor(foreground.withAlphaComponent(0.85)).nsColorMapper
            deleteButton.contentTintColor = foreground
            if isBuiltInIcon {
                iconImageView.contentTintColor = foreground
            }
        } else if isSelected && isLightMode {
            titleLabel.phi.textColor = ThemedColor(.white.withAlphaComponent(0.85)).nsColorMapper
            subtitleLabel.phi.textColor = ThemedColor(.white.withAlphaComponent(0.4)).nsColorMapper
            deleteButton.contentTintColor = .white
            if isBuiltInIcon {
                iconImageView.contentTintColor = .white
            }
        } else {
            titleLabel.phi.textColor = NSColor.black.withAlphaComponent(0.85) <> NSColor.white.withAlphaComponent(0.85)
            subtitleLabel.phi.textColor = NSColor.black.withAlphaComponent(0.3) <> NSColor.white.withAlphaComponent(0.3)
            deleteButton.contentTintColor = .labelColor
            if isBuiltInIcon {
                iconImageView.contentTintColor = .labelColor
            }
        }
    }
    
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateAppearance()
    }
}

/// The favicons of a split's panes in one tile: two side by side, three as a
/// stacked pair beside the third, four in a grid.
final class OmniboxSplitFaviconView: NSView {
    private var pageURLs: [String] = []
    private var imageViews: [NSImageView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(pageURLs: [String]) {
        let urls = Array(pageURLs.prefix(4))
        guard urls != self.pageURLs else { return }
        self.pageURLs = urls
        imageViews.forEach {
            $0.kf.cancelDownloadTask()
            $0.removeFromSuperview()
        }
        imageViews = urls.map { url in
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.setFavicon(for: url, configuration: .noCornerRadius)
            addSubview(imageView)
            return imageView
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (imageView, frame) in zip(imageViews, Self.paneFrames(count: imageViews.count, in: bounds)) {
            imageView.frame = frame
        }
    }

    static func paneFrames(count: Int, in bounds: NSRect, gap: CGFloat = 1) -> [NSRect] {
        let width = (bounds.width - gap) / 2
        let height = (bounds.height - gap) / 2
        let left = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let right = NSRect(x: width + gap, y: 0, width: width, height: bounds.height)
        let topLeft = NSRect(x: 0, y: 0, width: width, height: height)
        let topRight = NSRect(x: width + gap, y: 0, width: width, height: height)
        let bottomLeft = NSRect(x: 0, y: height + gap, width: width, height: height)
        let bottomRight = NSRect(x: width + gap, y: height + gap, width: width, height: height)
        switch count {
        case 2: return [left, right]
        case 3: return [topLeft, bottomLeft, right]
        case 4: return [topLeft, topRight, bottomLeft, bottomRight]
        default: return []
        }
    }
}

class SwitchToTabView: NSView {
    private lazy var label: NSTextField = {
        let l = NSTextField()
        l.isEditable = false
        l.isBordered = false
        l.drawsBackground = false
        l.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        l.textColor = .tertiaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        l.usesSingleLineMode = true
        l.stringValue = NSLocalizedString("addressBar.suggestions.switchToOpenTabHint", value: "Hold ⌘ to switch →", comment: "Omnibox suggestion - Hint shown for suggestions that can switch to an open tab")
        l.alignment = .right
        return l
    }()

    /// Split with New Tab preview: Hold-⌘ pairs the open tab into the split.
    var addsSplit = false {
        didSet {
            label.stringValue = addsSplit
                ? NSLocalizedString("addressBar.suggestions.addOpenTabToSplitHint", value: "Hold ⌘ to add split", comment: "Omnibox suggestion - Hint shown for an open-tab suggestion while choosing the second pane of a new split; holding Command pairs that open tab into the split")
                : NSLocalizedString("addressBar.suggestions.switchToOpenTabHint", value: "Hold ⌘ to switch →", comment: "Omnibox suggestion - Hint shown for suggestions that can switch to an open tab")
        }
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(label)

        label.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
        }

        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    var labelWidth: CGFloat {
        ceil(label.intrinsicContentSize.width)
    }

    func setEmphasized(_ emphasized: Bool) {
        let isLightMode = (currentAppearance == .light)
        if isLightMode && emphasized {
            label.textColor = NSColor.white.withAlphaComponent(0.85)
        } else if emphasized {
            label.textColor = .labelColor
        } else {
            label.textColor = .secondaryLabelColor
        }
    }
}
