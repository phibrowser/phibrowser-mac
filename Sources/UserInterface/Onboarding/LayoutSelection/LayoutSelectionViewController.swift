// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class LayoutSelectionViewController: OnboardingBaseViewController {

    private var selectedMode: LayoutMode = .balanced

    private let optionWidth: CGFloat = 456
    private let optionHeight: CGFloat = 116
    private let optionSpacing: CGFloat = 8
    private let containerWidth: CGFloat = 472
    private let containerLeftOffset: CGFloat = 84
    private let containerCornerRadius: CGFloat = 14
    private let containerPadding: CGFloat = 8

    private lazy var optionsContainer: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = containerCornerRadius
        return container
    }()

    private lazy var optionsStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = optionSpacing
        stackView.alignment = .centerX
        stackView.distribution = .fill
        return stackView
    }()

    private lazy var performanceOptionView: LayoutOptionView = {
        let view = LayoutOptionView(
            title: NSLocalizedString("Performance", comment: "Onboarding layout selection - Performance option"),
            previewImage: NSImage(resource: .tabLayoutPerformanceOobe),
            isSelected: selectedMode == .performance
        )
        view.onTap = { [weak self] in
            self?.selectMode(.performance)
        }
        return view
    }()

    private lazy var balancedOptionView: LayoutOptionView = {
        let view = LayoutOptionView(
            title: NSLocalizedString("Balanced", comment: "Onboarding layout selection - Balanced option"),
            previewImage: NSImage(resource: .tabLayoutBalancedOobe),
            isSelected: selectedMode == .balanced
        )
        view.onTap = { [weak self] in
            self?.selectMode(.balanced)
        }
        return view
    }()

    private lazy var comfortableOptionView: LayoutOptionView = {
        let view = LayoutOptionView(
            title: NSLocalizedString("Comfortable", comment: "Onboarding layout selection - Comfortable option"),
            previewImage: NSImage(resource: .tabLayoutComfortableOobe),
            isSelected: selectedMode == .comfortable
        )
        view.onTap = { [weak self] in
            self?.selectMode(.comfortable)
        }
        return view
    }()

    // MARK: - Lifecycle

    override func loadView() {
        super.loadView()
        titleLabel.stringValue = NSLocalizedString(
            "Layout selection",
            comment: "Onboarding layout selection - Page title"
        )
        skipButton.isHidden = true
        setupLayoutOptions()
    }

    // MARK: - Options Setup

    private func setupLayoutOptions() {
        view.addSubview(optionsContainer)
        optionsContainer.addSubview(optionsStackView)

        let optionViews = [balancedOptionView, performanceOptionView, comfortableOptionView]
        for optionView in optionViews {
            optionsStackView.addArrangedSubview(optionView)
            optionView.snp.makeConstraints { make in
                make.width.equalTo(optionWidth)
                make.height.equalTo(optionHeight)
            }
        }

        optionsContainer.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(containerLeftOffset)
            make.centerY.equalToSuperview()
            make.width.equalTo(containerWidth)
        }

        optionsStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(containerPadding)
        }
    }

    private func selectMode(_ mode: LayoutMode) {
        selectedMode = mode
        performanceOptionView.setSelected(mode == .performance)
        balancedOptionView.setSelected(mode == .balanced)
        comfortableOptionView.setSelected(mode == .comfortable)
    }

    // MARK: - Actions

    override func nextButtonTapped(_ sender: NSButton? = nil) {
        PhiPreferences.GeneralSettings.saveLayoutMode(selectedMode)
        nextClosure?(true)
    }
}

// MARK: - LayoutOptionView

class LayoutOptionView: NSView {
    var onTap: (() -> Void)?
    private var isSelected: Bool

    private let titleLabel: NSTextField
    private let previewImageView: NSImageView
    private let checkmarkImageView: NSImageView
    var selectedColor = NSColor.white.withAlphaComponent(0.1)
    var deselectedColor = NSColor.clear

    private let cornerRadius: CGFloat = 8
    private let titleFontSize: CGFloat = 18
    private let horizontalPadding: CGFloat = 18
    private let previewWidth: CGFloat = 140
    private let previewHeight: CGFloat = 81
    private let previewCornerRadius: CGFloat = 6
    private let previewBorderInset: CGFloat = 1
    private let previewToCheckmarkSpacing: CGFloat = 16
    private let checkmarkSize: CGFloat = 18

    init(title: String, previewImage: NSImage, isSelected: Bool) {
        self.isSelected = isSelected

        self.titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: titleFontSize, weight: .regular)
        titleLabel.textColor = .white

        self.previewImageView = NSImageView(image: previewImage)
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = previewCornerRadius
        previewImageView.layer?.masksToBounds = true
        previewImageView.layer?.borderWidth = 1
        previewImageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        self.checkmarkImageView = NSImageView()

        super.init(frame: .zero)

        setupUI()
        updateSelection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        addSubview(titleLabel)
        addSubview(previewImageView)
        addSubview(checkmarkImageView)

        titleLabel.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(horizontalPadding)
            make.centerY.equalToSuperview()
        }

        previewImageView.snp.makeConstraints { make in
            make.right.equalTo(checkmarkImageView.snp.left).offset(-previewToCheckmarkSpacing)
            make.centerY.equalToSuperview()
            make.width.equalTo(previewWidth)
            make.height.equalTo(previewHeight)
        }

        checkmarkImageView.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(checkmarkSize)
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(click)
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        updateSelection()
    }

    private func updateSelection() {
        if isSelected {
            layer?.backgroundColor = selectedColor.cgColor
            checkmarkImageView.image = NSImage(resource: .check)
        } else {
            layer?.backgroundColor = deselectedColor.cgColor
            checkmarkImageView.image = NSImage(resource: .uncheck)
        }
    }

    @objc private func handleTap() {
        onTap?()
    }
}
