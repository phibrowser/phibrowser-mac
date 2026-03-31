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
        bg.phi.selectedColor = ThemedColor.themeColor.mapper
        bg.phi.hoveredColor = ThemedColor.themeColor.opacity(0.16).mapper
        
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
        return view
    }()
    
    private var subTitleTrailingConstraintToSwitchTabView: Constraint?
    private var subTitleTrailingConstraintToSuperView: Constraint?
    private var subTitleTrailingConstraintToCloseButton: Constraint?
    private var switchTabTrailingConstraintToCloseButton: Constraint?
    private var switchTabTrailingConstraintToSuperView: Constraint?
    
    init(suggestion: OmniBoxSuggestion, index: Int) {
        super.init(frame: .zero)
        self.suggestion = suggestion
        self.index = index
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        wantsLayer = true
        addSubview(hoverableBg)
        hoverableBg.addSubview(iconImageView)
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
        
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(5)
            make.centerY.equalToSuperview()
            make.width.lessThanOrEqualToSuperview().multipliedBy(0.4)
        }
        
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        
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
            self.switchTabTrailingConstraintToCloseButton = make.trailing.equalTo(deleteButton.snp.leading).offset(-5).constraint
            self.switchTabTrailingConstraintToSuperView = make.trailing.equalToSuperview().offset(-5).constraint
            make.height.equalTo(26)
            make.width.equalTo(55)
        }
        
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel.snp.trailing).offset(2)
            make.centerY.equalToSuperview()
            self.subTitleTrailingConstraintToSuperView = make.trailing.equalToSuperview().offset(-5).constraint
            self.subTitleTrailingConstraintToCloseButton = make.trailing.equalTo(deleteButton.snp.leading).offset(-5).constraint
            self.subTitleTrailingConstraintToSwitchTabView = make.trailing.equalTo(switchToTabView.snp.leading).offset(-5).constraint
        }
        
        updateAppearance()
    }
    
    private func updateConstraint(canDelete: Bool, canSwitch: Bool, hovered: Bool, selected: Bool) {
        let canShowDelete = hovered || selected
        let showDeleteBtn = canShowDelete && canDelete
        
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
        
        subTitleTrailingConstraintToSuperView?.isActive = superViewEnabled
        subTitleTrailingConstraintToCloseButton?.isActive = closeButtonEnabled
        subTitleTrailingConstraintToSwitchTabView?.isActive = switchViewEnabled
        switchTabTrailingConstraintToSuperView?.isActive = !canShowDeleteBtn
        switchTabTrailingConstraintToCloseButton?.isActive = canShowDeleteBtn
        
        deleteButton.isHidden = !canShowDeleteBtn
        switchToTabView.isHidden = !switchViewEnabled
        
        hoverableBg.layoutSubtreeIfNeeded()
    }
    
    func configure(with suggestion: OmniBoxSuggestion, index: Int) {
        self.suggestion = suggestion
        self.index = index
        
        let title = suggestion.swapContentsAndDescription ? suggestion.subtitle : suggestion.title
        let subtitle = suggestion.swapContentsAndDescription ? suggestion.title : suggestion.subtitle
        titleLabel.stringValue = title ?? ""
        
        let titleSize = titleLabel.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: titleLabel.frame.height))
        let maxTitleWidth: CGFloat = 200
        
        titleLabel.snp.remakeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(5)
            make.centerY.equalToSuperview()
            if titleSize.width > maxTitleWidth {
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
        
        OmniSuggestionIconProvier.updateImage(for: iconImageView, with: suggestion)
        
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
        let rowView = superview as? NSTableRowView
        let isSelected = rowView?.isSelected ?? false
        hoverableBg.isSelected = isSelected
        updateConstraint(canDelete: suggestion?.canDelete ?? false, canSwitch: suggestion?.hasTabMatch ?? false, hovered: isHovered, selected: isSelected)
        if suggestion?.hasTabMatch ?? false {
            switchToTabView.setEmphasized(isSelected || isHovered)
        }
        
        let isLightMode = (ThemeManager.shared.currentAppearance == .light)
        
        let isBuiltInIcon: Bool = {
            guard let suggestion else { return false }
            if suggestion.type == .history { return false }
            return suggestion.iconName != nil || suggestion.iconURL == nil || (suggestion.iconURL?.isEmpty ?? false)
        }()
        
        if isSelected && isLightMode {
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
        l.stringValue = NSLocalizedString("Tab ⇥", comment: "Tab")
        l.alignment = .center
        return l
    }()

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
        layer?.borderWidth = 1
        phiLayer?.setBorderColor(.textTertiary)

        addSubview(label)

        // Layout with SnapKit
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
        }

        // Hugging/Compression for tidy intrinsic sizing
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    // Optional: a simple highlight to use when the row is selected/hovered
    func setEmphasized(_ emphasized: Bool) {
        let isLightMode = (ThemeManager.shared.currentAppearance == .light)
        if isLightMode && emphasized {
            label.textColor = NSColor.white.withAlphaComponent(0.85)
            phiLayer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor <> nil
        } else if emphasized {
            phiLayer?.setBorderColor(.textTertiary)
            label.textColor = .labelColor
        } else {
            phiLayer?.setBorderColor(.textTertiary)
            label.textColor = .secondaryLabelColor
        }
    }
}
