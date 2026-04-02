// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import AVFoundation

class ImportFromOtherBrowserViewController: OnboardingBaseViewController {
    enum Phase {
        case importor, permision
    }
    
    enum DisplayMode {
        case login   // 640x800 for onboarding.
        case normal  // 500x650 for the standalone window.
    }
    
    var onCompletion: (() -> Void)?
    /// Called when user taps a browser row to enter data type selection.
    var onBrowserSelected: ((_ browser: BrowserType, _ chromeProfileDir: String?) -> Void)?
    /// Data types selected per browser, set by the window controller before import.
    var dataTypesPerBrowser: [BrowserType: [String]]?
    var phase = Phase.importor
    private let displayMode: DisplayMode
    private let targetProfileId: String
    private let targetWindowId: Int?
    
    private var viewWidth: CGFloat { displayMode == .login ? 640 : 500 }
    private var viewHeight: CGFloat { displayMode == .login ? 800 : 625 }
    private var titleFontSize: CGFloat { displayMode == .login ? 46 : 32 }
    private var titleTopOffset: CGFloat { displayMode == .login ? 96 : 56 }
    private var optionsTopOffset: CGFloat { displayMode == .login ? 100 : 70 }
    private var optionWidth: CGFloat { displayMode == .login ? 472 : 380 }
    private var optionHeight: CGFloat { displayMode == .login ? 68 : 56 }
    private let optionIconSize: CGFloat = 32
    private var optionFontSize: CGFloat { displayMode == .login ? 18 : 15 }
    private var buttonBottomOffset: CGFloat { displayMode == .login ? -96 : -56 }
    private var permissionImageWidth: CGFloat { displayMode == .login ? 472 : 380 }
    private var permissionImageHeight: CGFloat { displayMode == .login ? 248 : 200 }
    private var permissionImageTopOffset: CGFloat { displayMode == .login ? 264 : 200 }
    private var descriptionFontSize: CGFloat { displayMode == .login ? 15 : 13 }
    
    init(
        displayMode: DisplayMode = .login,
        targetProfileId: String = LocalStore.defaultProfileId,
        targetWindowId: Int? = nil
    ) {
        self.displayMode = displayMode
        self.targetProfileId = targetProfileId
        self.targetWindowId = targetWindowId
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        self.displayMode = .login
        self.targetProfileId = LocalStore.defaultProfileId
        self.targetWindowId = nil
        super.init(coder: coder)
    }
    
    private lazy var importer = BrowserDataImporter(
        targetProfileId: targetProfileId,
        targetWindowId: targetWindowId
    )
    /// Browsers that have been configured with data types (returned from data type page).
    private(set) var configuredBrowsers: Set<BrowserType> = []
    private var chromeProfiles: [BrowserDataImporter.ChromeProfileInfo] = []
    private var selectedChromeProfile: BrowserDataImporter.ChromeProfileInfo?
    
    private lazy var permisionImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = .permission
        imageView.isHidden = true
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        return imageView
    }()
    
    private lazy var desLabel: NSTextField = {
        let label = NSTextField(labelWithString: NSLocalizedString("Phi needs Full Disk Access to import your data from Safari.", comment: "Import browser data page - Description explaining why Full Disk Access permission is needed"))
        label.textColor = NSColor.white
        label.font = NSFont.systemFont(ofSize: descriptionFontSize)
        label.isHidden = true
        return label
    }()
    
    private var containerWidth: CGFloat { displayMode == .login ? 472 : 396 }
    private var containerLeftOffset: CGFloat { displayMode == .login ? 84 : 52 }
    private let containerCornerRadius: CGFloat = 14
    private let containerPadding: CGFloat = 8
    private let optionSpacing: CGFloat = 8

    private lazy var optionsContainer: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = containerCornerRadius
        return container
    }()

    private lazy var browserOptionsStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = optionSpacing
        stackView.alignment = .centerX
        stackView.distribution = .fill
        return stackView
    }()
    
    private lazy var chromeOptionView: BrowserOptionView = {
        let view = BrowserOptionView(
            icon: .chromeIcon,
            title: NSLocalizedString("From Chrome", comment: "Import browser data page - Option label to import data from Chrome browser"),
            isSelected: false
        )
        view.onTap = { [weak self] in
            self?.selectBrowser(.chrome)
        }
        view.onProfileSelection = { [weak self] index in
            guard let self, index >= 0, index < self.chromeProfiles.count else {
                return
            }
            let newProfile = self.chromeProfiles[index]
            if self.selectedChromeProfile?.directory != newProfile.directory {
                self.selectedChromeProfile = newProfile
                self.unmarkBrowserConfigured(.chrome)
            }
        }
        
        view.wantsLayer = true
        return view
    }()
    
    private lazy var safariOptionView: BrowserOptionView = {
        let view = BrowserOptionView(
            icon: .safariIcon,
            title: NSLocalizedString("From Safari", comment: "Import browser data page - Option label to import data from Safari browser"),
            isSelected: false
        )
        
        view.wantsLayer = true
        
        view.onTap = { [weak self] in
            self?.selectBrowser(.safari)
        }
        return view
    }()
    
    private lazy var arcOptionView: BrowserOptionView = {
        let view = BrowserOptionView(
            icon: .arcIcon,
            title: NSLocalizedString("From Arc", comment: "Import browser data page - Option label to import data from Arc browser"),
            isSelected: false
        )
        
        view.wantsLayer = true
        
        view.onTap = { [weak self] in
            self?.selectBrowser(.arc)
        }
        return view
    }()
    
    private lazy var importStatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.textColor = NSColor.white
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .center
        label.isHidden = true
        return label
    }()
    
    private var cancelables = Set<AnyCancellable>()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.stringValue = NSLocalizedString("Browser data", comment: "Import browser data page - Page title")
        applyDisplayModeLayout()
        setupBrowserOptions()
        updateNextButtonState()
        
        importer.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else {
                    return
                }
                if phase != .done && phase != .waiting {
                    nextButton.isEnabled = false
                    skipButton.isEnabled = false
                }
        }
            .store(in: &cancelables)
        
        importer.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateImportStatus(status)
            }
            .store(in: &cancelables)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKeyAndOrderFront(nil)
    }
    
    private func updateImportStatus(_ status: String) {
        importStatusLabel.stringValue = status
        importStatusLabel.isHidden = status.isEmpty
    }
    
    private func setupBrowserOptions() {
        view.addSubview(optionsContainer)
        optionsContainer.addSubview(browserOptionsStackView)
        view.addSubview(importStatusLabel)
        view.addSubview(permisionImageView)
        view.addSubview(desLabel)

        applyOptionViewStyle(chromeOptionView)
        applyOptionViewStyle(safariOptionView)
        applyOptionViewStyle(arcOptionView)

        let hasChrome = hasChromeData()
        let hasArc = hasArcData()
        if hasChrome {
            browserOptionsStackView.addArrangedSubview(chromeOptionView)
            chromeOptionView.snp.makeConstraints { make in
                make.width.equalTo(optionWidth)
                make.height.equalTo(optionHeight)
            }
            refreshChromeProfilesIfNeeded()
        }

        if hasArc {
            browserOptionsStackView.addArrangedSubview(arcOptionView)
            arcOptionView.snp.makeConstraints { make in
                make.width.equalTo(optionWidth)
                make.height.equalTo(optionHeight)
            }
        }

        browserOptionsStackView.addArrangedSubview(safariOptionView)
        safariOptionView.snp.makeConstraints { make in
            make.width.equalTo(optionWidth)
            make.height.equalTo(optionHeight)
        }

        optionsContainer.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(containerLeftOffset)
            make.centerY.equalToSuperview()
            make.width.equalTo(containerWidth)
        }

        browserOptionsStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(containerPadding)
        }

        importStatusLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(optionsContainer.snp.bottom).offset(16)
            make.width.lessThanOrEqualTo(optionWidth)
        }
        
        permisionImageView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.size.equalTo(NSSize(width: permissionImageWidth, height: permissionImageHeight))
            make.top.equalToSuperview().offset(permissionImageTopOffset)
        }
        
        desLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(titleLabel.snp.bottom).offset(3)
        }
    }
    
    private func applyOptionViewStyle(_ optionView: BrowserOptionView) {
        optionView.applyStyle(iconSize: optionIconSize, fontSize: optionFontSize)
    }
    
    private func selectBrowser(_ browser: BrowserType) {
        let chromeDir = (browser == .chrome) ? selectedChromeProfile?.directory : nil
        onBrowserSelected?(browser, chromeDir)
    }

    /// Called by the window controller when user returns from data type page after configuring.
    func markBrowserConfigured(_ browser: BrowserType) {
        configuredBrowsers.insert(browser)
        updateConfiguredAppearance()
        updateNextButtonState()
    }

    /// Called by the window controller when user changed Chrome profile, invalidating previous config.
    func unmarkBrowserConfigured(_ browser: BrowserType) {
        configuredBrowsers.remove(browser)
        updateConfiguredAppearance()
        updateNextButtonState()
    }

    private func updateConfiguredAppearance() {
        chromeOptionView.setConfigured(configuredBrowsers.contains(.chrome))
        safariOptionView.setConfigured(configuredBrowsers.contains(.safari))
        arcOptionView.setConfigured(configuredBrowsers.contains(.arc))
    }

    private func updateNextButtonState() {
        nextButton.isEnabled = !configuredBrowsers.isEmpty
        nextButton.alphaValue = configuredBrowsers.isEmpty ? 0.5 : 1.0
    }
    
    private func applyDisplayModeLayout() {
        view.snp.remakeConstraints { make in
            make.width.equalTo(viewWidth)
            make.height.equalTo(viewHeight)
        }
        
        titleLabel.font = NSFont(name: "IvyPresto Headline", size: titleFontSize)
        titleLabel.snp.remakeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(titleTopOffset)
        }
        
        nextButton.snp.remakeConstraints { make in
            make.bottom.equalToSuperview().offset(buttonBottomOffset)
            make.centerX.equalToSuperview()
            make.width.equalTo(120)
            make.height.equalTo(40)
        }
        
        if displayMode == .login {
            skipButton.snp.remakeConstraints { make in
                make.top.equalTo(nextButton.snp.bottom).offset(8)
                make.centerX.equalToSuperview()
            }
        } else {
            skipButton.isHidden = true
        }
    }
    
    /// A lightweight check to infer whether the app has Full Disk Access.
    /// We try to see if a Safari data file is readable. If not, we assume
    /// Full Disk Access has not been granted yet.
    private func hasFullDiskAccess() -> Bool {
        let homeDirectory = NSHomeDirectory()
        let safariHistoryPath = (homeDirectory as NSString).appendingPathComponent("Library/Safari/History.db")
        return FileManager.default.isReadableFile(atPath: safariHistoryPath)
    }
    
    private func hasChromeData () -> Bool {
        let library = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0] as NSString
        let chromePath = library.appendingPathComponent("Google/Chrome")
        return FileManager.default.fileExists(atPath: chromePath)
    }
    
    private func hasArcData () -> Bool {
        let library = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0] as NSString
        let chromePath = library.appendingPathComponent("Arc/User Data")
        return FileManager.default.fileExists(atPath: chromePath)
    }


    private func refreshChromeProfilesIfNeeded() {
        guard hasChromeData() else {
            chromeOptionView.setProfileSelectorVisible(false)
            return
        }
        chromeProfiles = importer.loadChromeProfiles()
        if chromeProfiles.count > 1 {
            chromeOptionView.setProfileSelectorVisible(true)
            let names = chromeProfiles.map { $0.name }
            let menuTitles = chromeProfiles.map { chromeProfileMenuTitle($0) }
            let selectedIndex = selectedChromeProfileIndex(in: chromeProfiles) ?? 0
            chromeOptionView.updateProfileOptions(
                buttonTitles: names,
                menuTitles: menuTitles,
                selectedIndex: selectedIndex
            )
            selectedChromeProfile = chromeProfiles[selectedIndex]
        } else if chromeProfiles.count == 1 {
            chromeOptionView.setProfileSelectorVisible(false)
            selectedChromeProfile = chromeProfiles.first
        } else {
            chromeOptionView.setProfileSelectorVisible(false)
            selectedChromeProfile = nil
        }
    }

    private func chromeProfileMenuTitle(_ profile: BrowserDataImporter.ChromeProfileInfo) -> String {
        guard let email = profile.email, !email.isEmpty else {
            return profile.name
        }
        return "\(profile.name) (\(email))"
    }

    private func selectedChromeProfileIndex(in profiles: [BrowserDataImporter.ChromeProfileInfo]) -> Int? {
        guard let selected = selectedChromeProfile else {
            return nil
        }
        return profiles.firstIndex { $0.directory == selected.directory }
    }

    private func showPermissionView() {
        optionsContainer.isHidden = true
        importStatusLabel.isHidden = true
        permisionImageView.isHidden = false
        browserOptionsStackView.isHidden = true
        titleLabel.stringValue = NSLocalizedString("Permissions", comment: "Import browser data page - Page title when showing permission request")
        desLabel.isHidden = false
        nextButton.title = NSLocalizedString("Open Settings", comment: "Import browser data page - Button to open system settings for granting permissions")
        phase = .permision
        nextButton.snp.remakeConstraints { make in
            make.bottom.equalToSuperview().offset(buttonBottomOffset)
            make.centerX.equalToSuperview()
            make.width.equalTo(148)
            make.height.equalTo(40)
        }
    }
    
    private func openFullDiskAccessSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    override func nextButtonTapped(_ sender: NSButton? = nil) {
        if phase == .permision, !hasFullDiskAccess() {
            openFullDiskAccessSettings()
            return
        } else if phase == .importor,
                  configuredBrowsers.contains(.safari),
                  !hasFullDiskAccess() {
            showPermissionView()
            return
        }

        // Reset phase after FDA was granted so import can proceed
        phase = .importor

        if !configuredBrowsers.isEmpty {
            Task {
                await importer.startImportData(
                    Array(configuredBrowsers),
                    chromeProfileDirectory: selectedChromeProfile?.directory,
                    dataTypesPerBrowser: dataTypesPerBrowser
                )
                await MainActor.run {
                    onCompletion?()
                }
            }
        } else {
            onCompletion?()
        }
    }
}

class BrowserOptionView: NSView {
    var onTap: (() -> Void)?
    var onProfileSelection: ((Int) -> Void)?
    private var isSelected: Bool
    
    private let iconImageView: NSImageView
    private let titleLabel: NSTextField
    private let chevronImageView: NSImageView
    private let profileSelectorButton: ProfileSelectionButton
    private var profileButtonTitles: [String] = []
    private var selectedProfileIndex: Int = 0
    var configuredColor = NSColor.white.withAlphaComponent(0.1)
    var normalColor = NSColor.clear
   
    init(icon: NSImage, title: String, isSelected: Bool) {
        self.isSelected = isSelected
        self.iconImageView = NSImageView(image: icon)
        
        self.titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        titleLabel.textColor = .white
        
        self.chevronImageView = NSImageView()
        if let chevronImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            chevronImageView.image = chevronImage.withSymbolConfiguration(config)
        }
        chevronImageView.contentTintColor = .white
        self.profileSelectorButton = ProfileSelectionButton(title: "Profile")
        profileSelectorButton.isHidden = true
        
        super.init(frame: .zero)
        
        setupUI()
        updateAppearance()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private let horizontalPadding: CGFloat = 18
    private let iconToTitleSpacing: CGFloat = 16
    private let chevronSize: CGFloat = 24
    private let cornerRadius: CGFloat = 8

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        addSubview(iconImageView)
        addSubview(titleLabel)
        addSubview(chevronImageView)
        addSubview(profileSelectorButton)

        iconImageView.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(iconImageView.image?.size.width ?? 32)
        }

        titleLabel.snp.makeConstraints { make in
            make.left.equalTo(iconImageView.snp.right).offset(iconToTitleSpacing)
            make.centerY.equalToSuperview()
        }

        chevronImageView.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-horizontalPadding)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(chevronSize)
        }

        profileSelectorButton.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.right.equalTo(chevronImageView.snp.left).offset(-12)
        }
        
        profileSelectorButton.setContentHuggingPriority(.required, for: .horizontal)
        profileSelectorButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        profileSelectorButton.target = self
        profileSelectorButton.action = #selector(showProfileMenu(_:))
        
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
    
    func setConfigured(_ configured: Bool) {
        isSelected = configured
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isSelected ? configuredColor.cgColor : normalColor.cgColor
    }
    
    func setProfileSelectorVisible(_ visible: Bool) {
        profileSelectorButton.isHidden = !visible
    }
    
    func applyStyle(iconSize: CGFloat, fontSize: CGFloat) {
        iconImageView.snp.updateConstraints { make in
            make.width.height.equalTo(iconSize)
        }
        titleLabel.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
    }
    
    func updateProfileOptions(buttonTitles: [String], menuTitles: [String], selectedIndex: Int) {
        profileButtonTitles = buttonTitles
        selectedProfileIndex = max(0, min(selectedIndex, buttonTitles.count - 1))
        let menu = NSMenu()
        for (index, title) in menuTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(profileMenuItemSelected(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = (index == selectedProfileIndex) ? .on : .off
            menu.addItem(item)
        }
        profileSelectorButton.menu = menu
        if selectedProfileIndex >= 0 && selectedProfileIndex < buttonTitles.count {
            profileSelectorButton.title = buttonTitles[selectedProfileIndex]
        }
    }
    
    @objc private func showProfileMenu(_ sender: NSButton) {
        guard let menu = profileSelectorButton.menu else {
            return
        }
        for item in menu.items {
            item.state = (item.tag == selectedProfileIndex) ? .on : .off
        }
        let location = NSPoint(x: 0, y: profileSelectorButton.bounds.height + 4)
        let selectedItem = menu.item(at: selectedProfileIndex)
        menu.popUp(positioning: selectedItem, at: location, in: profileSelectorButton)
    }
    
    @objc private func profileMenuItemSelected(_ sender: NSMenuItem) {
        let index = sender.tag
        selectedProfileIndex = index
        if index >= 0 && index < profileButtonTitles.count {
            profileSelectorButton.title = profileButtonTitles[index]
        }
        onProfileSelection?(index)
    }
}

final class ProfileSelectionButton: NSButton {
    private let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let padding = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    private let chevronSymbolName = "chevron.down"
    private let chevronPointSize: CGFloat = 10
    private let titleImageSpacing: CGFloat = 6
    
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            updateAttributedTitle()
            updateChevronImage()
            needsDisplay = true
        }
    }
    
    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont]
        let size = (title as NSString).size(withAttributes: attributes)
        let imageWidth = image?.size.width ?? 0
        let spacing = imageWidth > 0 ? titleImageSpacing : 0
        let width = size.width + padding.left + padding.right + spacing + imageWidth + 2
        return NSSize(
            width: min(width, 120),
            height: max(size.height, image?.size.height ?? 0) + padding.top + padding.bottom
        )
    }
    
    private func commonInit() {
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.6).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        
        imagePosition = .imageRight
        imageScaling = .scaleProportionallyDown

        let profileCell = ProfileSelectionButtonCell(padding: padding, titleImageSpacing: titleImageSpacing)
        profileCell.font = titleFont
        cell = profileCell
        
        updateAttributedTitle()
        updateChevronImage()
    }
    
    private func updateAttributedTitle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: titleFont,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
        )
    }
    
    private func updateChevronImage() {
        let titleColor: NSColor
        if attributedTitle.length > 0,
           let color = attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            titleColor = color
        } else {
            titleColor = .white
        }
        image = NSImage.configureSymbolImage(
            systemName: chevronSymbolName,
            pointSize: chevronPointSize,
            weight: .medium,
            color: titleColor
        )
    }
}

final class ProfileSelectionButtonCell: NSButtonCell {
    private let padding: NSEdgeInsets
    private let titleImageSpacing: CGFloat
    
    init(padding: NSEdgeInsets, titleImageSpacing: CGFloat) {
        self.padding = padding
        self.titleImageSpacing = titleImageSpacing
        super.init(textCell: "")
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let imageWidth = image?.size.width ?? 0
        let spacing = imageWidth > 0 ? titleImageSpacing : 0
        
        let availableWidth = max(0, rect.width - padding.left - padding.right - imageWidth - spacing)
        let titleSize = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)])
        let width = min(titleSize.width, availableWidth)
        let height = titleSize.height
        let x = rect.minX + padding.left
        let y = rect.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let image else {
            return .zero
        }
        let titleRect = titleRect(forBounds: rect)
        let xIdeal = titleRect.maxX + titleImageSpacing
        let xMax = rect.maxX - padding.right - image.size.width
        let x = min(xIdeal, xMax)
        let y = rect.midY - image.size.height / 2
        return NSRect(x: x, y: y, width: image.size.width, height: image.size.height)
    }
}

class OnboardingBaseViewController: NSViewController {
    var nextClosure: ((Bool) -> Void)?
    
    // MARK: - Video Background
    private var videoPlayer: AVPlayer?
    private var videoPlayerLayer: AVPlayerLayer?
    private var loopObserver: Any?
    
    /// If true, will try to make window center
    var isFisrtPage = false
    
    // Placeholder to hide gray flash while video loads
    private var placeholderView: NSImageView = {
        let image = NSImage(resource: .loginWallpaper)
        let imageView = NSImageView(image: image)
        return imageView
    }()
    
    var dotView: NSImageView = {
        let dot = NSImage(resource: .dotBg)
        let imageView = NSImageView(image: dot)
        imageView.alphaValue = 0.08
        return imageView
    }()
            
    var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont(name: "IvyPrestoDisplay-SemiBoldItalic", size: 46)
        label.textColor = .white
        label.alignment = .center
        return label
    }()
    
    lazy var nextButton: GradientBorderButton = {
        let button = GradientBorderButton()
        button.title = NSLocalizedString("Next", comment: "Onboarding base - Next button to proceed to next step")
        button.clickAction = { [weak self] in
            self?.nextButtonTapped()
        }
        return button
    }()
    
    lazy var skipButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.title = NSLocalizedString("Skip", comment: "Onboarding base - Skip button to bypass current step")
        button.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        button.contentTintColor = NSColor.gray
        button.target = self
        button.action = #selector(skipButtonTapped(_:))
        return button
    }()
    
    @objc func skipButtonTapped(_ sender: NSButton) {
        nextClosure?(false)
    }
       
    
    @objc func nextButtonTapped(_ sender: NSButton? = nil) {
        nextClosure?(true)
    }
    
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addSubview(placeholderView)
        view.addSubview(dotView)
        view.addSubview(titleLabel)
        view.addSubview(nextButton)
        view.addSubview(skipButton)
        
        // Set fixed size for the view
        view.snp.makeConstraints { make in
            make.width.equalTo(640)
            make.height.equalTo(800)
        }
        
        placeholderView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        dotView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        titleLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(96)
        }
        
        nextButton.snp.makeConstraints { make in
            make.bottom.equalToSuperview().offset(-96)
            make.centerX.equalToSuperview()
            make.width.equalTo(120)
            make.height.equalTo(40)
        }
    
        skipButton.snp.makeConstraints { make in
            make.top.equalTo(nextButton.snp.bottom).offset(8)
            make.centerX.equalToSuperview()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupVideoBackground()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        startVideoPlayback()
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopVideoPlayback()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.layoutSubtreeIfNeeded()
        if isFisrtPage {
            view.window?.center()
        }
    }
    
    // MARK: - Video Background
    private var statusObservation: NSKeyValueObservation?
    
    private func setupVideoBackground() {
        guard videoPlayer == nil else { return }
        
        guard let url = Bundle.main.url(forResource: "login-dot-bg", withExtension: "mp4") else {
            return
        }
        
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        
        // Observe player item status to know when first frame is ready
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            if item.status == .readyToPlay {
                DispatchQueue.main.async {
                    // Fade out placeholder when video is ready
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.3
                        self.placeholderView.animator().alphaValue = 0
                    } completionHandler: {
                        self.placeholderView.isHidden = true
                    }
                }
            }
        }
        
        let layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspectFill
        
        if let rootLayer = view.layer {
            rootLayer.insertSublayer(layer, at: 0)
        }
        
        self.videoPlayer = player
        self.videoPlayerLayer = layer
        
        // Setup loop observer
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }
    
    private func startVideoPlayback() {
        videoPlayer?.seek(to: .zero)
        videoPlayer?.play()
    }
    
    private func stopVideoPlayback() {
        videoPlayer?.pause()
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
    }
}
