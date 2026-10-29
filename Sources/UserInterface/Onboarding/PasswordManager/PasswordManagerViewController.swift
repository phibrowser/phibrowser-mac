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
                return PhiExtensionID.icloudPasswords
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
    private let thirdPartyIconSize: CGFloat = 28
    private let thirdPartyIconSpacing: CGFloat = 10

    // MARK: - Subviews

    private lazy var optionsContainer: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = containerCornerRadius
        return container
    }()

    private lazy var optionsStackView: OnboardingOptionStackView = {
        let stackView = OnboardingOptionStackView()
        stackView.onMoveSelection = { [weak self] offset in
            guard let self else { return }
            let managers: [PasswordManager] = [.icloudPasswords, .manual]
            guard let index = managers.firstIndex(of: selectedManager) else { return }
            selectManager(managers[(index + offset + managers.count) % managers.count])
        }
        stackView.orientation = .vertical
        stackView.spacing = optionSpacing
        stackView.alignment = .centerX
        stackView.distribution = .fill
        return stackView
    }()

    private lazy var icloudOptionView: PasswordManagerOptionView = {
        let view = PasswordManagerOptionView(
            icon: NSImage(resource: .icloudPasswordsIcon),
            title: NSLocalizedString("oobe.passwordManager.icloudPasswordsOption", value: "iCloud Passwords",
                comment: "Onboarding password manager - iCloud Passwords option"
            ),
            subtitle: NSLocalizedString("oobe.passwordManager.recommendedBadge", value: "Recommended",
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
            iv.snp.makeConstraints { make in
                make.width.height.equalTo(thirdPartyIconSize)
            }
            iconsStack.addArrangedSubview(iv)
        }

        let view = PasswordManagerOptionView(
            trailingIconView: iconsStack,
            title: NSLocalizedString("oobe.passwordManager.manualSetupOption", value: "I'll setup my own",
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
        setTitle(NSLocalizedString("oobe.passwordManager.title", value: "Passwords Manager",
            comment: "Onboarding password manager - Page title"
        ))
        configureFooterButtons(.init(
            leftTitle: NSLocalizedString(
                "oobe.navigation.backButton",
                value: "Back",
                comment: "OOBE navigation - Button to return to the previous step"
            ),
            rightTitle: nextButton.title
        ))
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
        let wantsICloud = (selectedManager == .icloudPasswords)
        PhiPreferences.PasswordManagerSettings.autoInstallICloudPasswords.save(wantsICloud)
        if wantsICloud {
            installExtension()
        }
        nextClosure?(true)
    }

    // MARK: - Extension Installation

    private func installExtension() {
        guard let extensionId = selectedManager.extensionId else { return }
        guard let windowId = SpaceSessionControllersManager.shared.getFirstAvailableWindowId() else {
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
    private let subtitleFontSize: CGFloat = 16
    private let horizontalPadding: CGFloat = 18
    private let iconSize: CGFloat = 28
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
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        if let subtitle {
            let sl = NSTextField(labelWithString: "(\(subtitle))")
            sl.font = NSFont.systemFont(ofSize: subtitleFontSize, weight: .regular)
            sl.textColor = NSColor.white.withAlphaComponent(0.8)
            sl.maximumNumberOfLines = 1
            sl.lineBreakMode = .byTruncatingTail
            sl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
                make.right.equalTo(checkmarkImageView.snp.left).offset(
                    -(subtitleLabel == nil ? iconToCheckmarkSpacing : 10)
                )
                make.centerY.equalToSuperview()
                if trailingIconView is NSImageView {
                    make.width.height.equalTo(iconSize)
                }
            }
        }

        // Keep the title and recommendation on one line, clear of the trailing icons.
        titleLabel.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(horizontalPadding)
            make.centerY.equalToSuperview()
        }
        let textTrailingView = trailingIconView ?? checkmarkImageView
        if let subtitleLabel {
            addSubview(subtitleLabel)
            subtitleLabel.snp.makeConstraints { make in
                make.left.equalTo(titleLabel.snp.right).offset(5)
                make.centerY.equalToSuperview()
                make.right.lessThanOrEqualTo(textTrailingView.snp.left).offset(-10)
            }
        } else {
            titleLabel.snp.makeConstraints { make in
                make.right.lessThanOrEqualTo(textTrailingView.snp.left).offset(-10)
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
