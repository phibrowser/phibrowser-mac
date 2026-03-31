// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class PasswordManagerViewController: OnboardingBaseViewController {

    // MARK: - Types

    enum PasswordManager {
        case icloudPasswords
        case manual

        var extensionId: String? {
            switch self {
            case .icloudPasswords:
                return "pejdijmoenmkgeppbflobdenhhabjlaj"
            case .manual:
                return nil
            }
        }
    }

    // MARK: - State

    private var selectedManager: PasswordManager = .icloudPasswords

    // MARK: - Dimension Constants

    private let optionWidth: CGFloat = 456
    private let optionHeight: CGFloat = 68
    private let optionSpacing: CGFloat = 8
    private let containerWidth: CGFloat = 472
    private let containerLeftOffset: CGFloat = 84
    private let containerCornerRadius: CGFloat = 14
    private let containerPadding: CGFloat = 8
    private let thirdPartyIconSize: CGFloat = 20
    private let thirdPartyIconSpacing: CGFloat = 10
    private let thirdPartyIconAlpha: CGFloat = 0.6

    // MARK: - Subviews

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

    private lazy var icloudOptionView: PasswordManagerOptionView = {
        let view = PasswordManagerOptionView(
            icon: NSImage(resource: .icloudPasswordsIcon),
            title: NSLocalizedString(
                "iCloud Passwords",
                comment: "Onboarding password manager - iCloud Passwords option"
            ),
            subtitle: NSLocalizedString(
                "Recommended",
                comment: "Onboarding password manager - Recommended label for iCloud Passwords"
            ),
            isSelected: selectedManager == .icloudPasswords
        )
        view.onTap = { [weak self] in
            self?.selectManager(.icloudPasswords)
        }
        return view
    }()

    private lazy var manualOptionView: PasswordManagerOptionView = {
        let icons: [NSImage] = [
            NSImage(resource: .onepasswordIcon),
            NSImage(resource: .bitwardenIcon),
            NSImage(resource: .lastpassIcon),
            NSImage(resource: .enpassIcon)
        ]
        let iconsStack = NSStackView()
        iconsStack.orientation = .horizontal
        iconsStack.spacing = thirdPartyIconSpacing
        iconsStack.alignment = .centerY
        for img in icons {
            let iv = NSImageView(image: img)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.alphaValue = thirdPartyIconAlpha
            iv.snp.makeConstraints { make in
                make.width.height.equalTo(thirdPartyIconSize)
            }
            iconsStack.addArrangedSubview(iv)
        }

        let view = PasswordManagerOptionView(
            trailingIconView: iconsStack,
            title: NSLocalizedString(
                "I'll setup my own",
                comment: "Onboarding password manager - Manual setup option"
            ),
            subtitle: nil,
            isSelected: selectedManager == .manual
        )
        view.onTap = { [weak self] in
            self?.selectManager(.manual)
        }
        return view
    }()

    // MARK: - Lifecycle

    override func loadView() {
        super.loadView()
        titleLabel.stringValue = NSLocalizedString(
            "Passwords Manager",
            comment: "Onboarding password manager - Page title"
        )
        skipButton.isHidden = true
        nextButton.title = NSLocalizedString("Finish", comment: "Onboarding password manager - Finish button")
        setupOptions()
    }

    // MARK: - Options Setup

    private func setupOptions() {
        view.addSubview(optionsContainer)
        optionsContainer.addSubview(optionsStackView)

        let optionViews = [icloudOptionView, manualOptionView]
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

    private func selectManager(_ manager: PasswordManager) {
        selectedManager = manager
        icloudOptionView.setSelected(manager == .icloudPasswords)
        manualOptionView.setSelected(manager == .manual)
        AppLogInfo("[PasswordManager] Selected: \(manager)")
    }

    // MARK: - Actions

    override func nextButtonTapped(_ sender: NSButton? = nil) {
        if selectedManager == .icloudPasswords {
            installExtension()
        }
        nextClosure?(true)
    }

    // MARK: - Extension Installation

    private func installExtension() {
        guard let extensionId = selectedManager.extensionId else { return }
        guard let windowId = MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() else {
            AppLogWarn("[PasswordManager] No available window ID for extension install")
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.installExtensions(
            withIds: [extensionId],
            windowId: Int64(windowId)
        )
        AppLogInfo("[PasswordManager] Requested install of extension: \(extensionId)")
    }
}

// MARK: - PasswordManagerOptionView

class PasswordManagerOptionView: NSView {
    var onTap: (() -> Void)?
    private var isSelected: Bool

    private let trailingIconView: NSView?
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField?
    private let checkmarkImageView: NSImageView

    var selectedColor = NSColor.white.withAlphaComponent(0.1)
    var deselectedColor = NSColor.clear

    private let cornerRadius: CGFloat = 8
    private let titleFontSize: CGFloat = 18
    private let subtitleFontSize: CGFloat = 12
    private let horizontalPadding: CGFloat = 18
    private let iconSize: CGFloat = 32
    private let iconToCheckmarkSpacing: CGFloat = 16
    private let checkmarkSize: CGFloat = 18

    /// Init with an NSImage icon (convenience for single-icon options)
    convenience init(icon: NSImage?, title: String, subtitle: String? = nil, isSelected: Bool) {
        var iconView: NSView?
        if let icon {
            let iv = NSImageView(image: icon)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iconView = iv
        }
        self.init(trailingIconView: iconView, title: title, subtitle: subtitle, isSelected: isSelected)
    }

    /// Init with a custom trailing icon view (e.g. a stack of small icons)
    init(trailingIconView: NSView?, title: String, subtitle: String? = nil, isSelected: Bool) {
        self.isSelected = isSelected
        self.trailingIconView = trailingIconView

        self.titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: titleFontSize, weight: .regular)
        titleLabel.textColor = .white

        if let subtitle {
            let sl = NSTextField(labelWithString: subtitle)
            sl.font = NSFont.systemFont(ofSize: subtitleFontSize, weight: .regular)
            sl.textColor = NSColor.white.withAlphaComponent(0.5)
            self.subtitleLabel = sl
        } else {
            self.subtitleLabel = nil
        }

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
        addSubview(checkmarkImageView)

        // Checkmark at far right
        checkmarkImageView.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(checkmarkSize)
        }

        // Icons to the left of checkmark, right-aligned
        if let trailingIconView {
            addSubview(trailingIconView)
            trailingIconView.snp.makeConstraints { make in
                make.right.equalTo(checkmarkImageView.snp.left).offset(-iconToCheckmarkSpacing)
                make.centerY.equalToSuperview()
                if trailingIconView is NSImageView {
                    make.width.height.equalTo(iconSize)
                }
            }
        }

        // Text on the left
        if let subtitleLabel {
            addSubview(subtitleLabel)
            titleLabel.snp.makeConstraints { make in
                make.left.equalToSuperview().offset(horizontalPadding)
                make.bottom.equalTo(self.snp.centerY).offset(-1)
            }
            subtitleLabel.snp.makeConstraints { make in
                make.left.equalTo(titleLabel)
                make.top.equalTo(self.snp.centerY).offset(2)
            }
        } else {
            titleLabel.snp.makeConstraints { make in
                make.left.equalToSuperview().offset(horizontalPadding)
                make.centerY.equalToSuperview()
            }
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
