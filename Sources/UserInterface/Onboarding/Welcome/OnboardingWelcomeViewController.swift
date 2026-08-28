// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import SwiftUI
import PostHog

class OnboardingWelcomeViewController: ConchFrameAnimationBaseViewController {
    override var imageNamagePrefix: String { "oobe-" }
    override var preAnimationImagePrefix: String { "oobe-pre-" }
    
    private let dateLabel: NSTextField = {
        let label = NSTextField(labelWithString: "2025.1.1")
        label.font = NSFont(name: "Impact", size: 200)
        label.textColor = .white
        label.alignment = .center
        return label
    }()
    
    private let titleLabel: NSTextField = {
        let title = NSLocalizedString("oobe.welcome.title", value: "Welcome", comment: "Onboarding welcome page - Main title greeting the user")
        let label = NSTextField(labelWithString: title)
        label.font = .brandDisplay("IvyPrestoDisplay-SemiBoldItalic", size: 46, renders: title)
        label.textColor = NSColor(red: 0.18, green: 0.42, blue: 0.49, alpha: 1.0) // #2D6F7D
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()
    
    private lazy var themeStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.alignment = .top
        stackView.distribution = .gravityAreas
        stackView.spacing = 12
        return stackView
    }()
    
    private var coloredBgView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.alphaValue = 0.1
        return view
    }()
    
    private let dotBg: NSImage = {
        return .dotBg
    }()
    
    private lazy var dotBackgroundImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = dotBg
        imageView.alphaValue = 0.15
        return imageView
    }()
    
    private lazy var nextButton: GradientBorderButton = {
        let button = GradientBorderButton()
        button.title = NSLocalizedString("oobe.welcome.nextButton", value: "Next", comment: "Onboarding welcome page - Next button to proceed to next step")
        button.clickAction = { [weak self] in
            self?.nextButtonTapped()
        }
        button.cornerRadius = 999
        return button
    }()
    
    private let backgroundImageView: NSImageView = {
        let bg = NSImageView()
        return bg
    }()
    
    private let backgroundImage: NSImage = {
        return .welcomeBg
    }()
    
    var nextClosure: ((Bool) -> Void)?
    private var accentColor: NSColor?
    private var selectedThemeId: String = ThemeManager.shared.currentTheme.id
    private var themeButtons: [String: OnboardingThemeSwatchButton] = [:]
    
    private var themes: [Theme] {
        Theme.builtInThemes.map { builtInTheme in
            ThemeManager.shared.registeredThemes[builtInTheme.id] ?? builtInTheme
        }
    }
    
    var userName: String? {
        didSet {
            let title = String(format: NSLocalizedString("oobe.welcome.personalizedTitle", value: "Welcome %@", comment: "Onboarding welcome page - Personalized welcome title with user name"), userName ?? "")
            titleLabel.stringValue = title
            // The name is user-supplied and the greeting is localized, so
            // neither is guaranteed to be Latin — see NSFont.brandDisplay.
            titleLabel.font = .brandDisplay("IvyPrestoDisplay-SemiBoldItalic", size: 46, renders: title)
        }
    }
    
    // MARK: - Lifecycle
    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.white.cgColor
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        selectedThemeId = ThemeManager.shared.currentTheme.id
        updateThemeSelection()
        if let theme = themes.first(where: { $0.id == selectedThemeId }) ?? themes.first {
            themeChanged(theme)
        }
    }
    
    override func viewDidDisappear() {
        super.viewDidDisappear()
    }
    
    private func requesetProfile() async {
        let accountUserID = await MainActor.run {
            LoginController.shared.accountForOnboarding?.userID
        }
        guard let accountUserID else {
            return
        }
        let response = try? await APIClient.shared
            .getOnboardingAccountProfile(accountUserID: accountUserID)
        if let profile = response?.data {
            await MainActor.run {
                let dateString = formatToLocalDate(profile.created_at)
                if !dateString.isEmpty {
                    dateLabel.stringValue = formatToLocalDate(profile.created_at)
                    adjustDateLabelFontSize()
                }
            }
        }
    }
    
    private func formatToLocalDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        guard let date = formatter.date(from: isoString) else {
            return ""
        }

        let outputFormatter = DateFormatter()
        outputFormatter.timeZone = .current
        outputFormatter.dateFormat = "yyyy.M.d"

        return outputFormatter.string(from: date)
    }
    
    // MARK: - Setup
    private func setupUI() {
        view.addSubview(imageView)
        view.addSubview(coloredBgView)
        view.addSubview(dotBackgroundImageView)
        view.addSubview(titleLabel)
        view.addSubview(themeStackView)
        view.addSubview(nextButton)
        
        view.snp.makeConstraints { make in
            make.width.equalTo(640)
            make.height.equalTo(800)
        }
        view.layoutSubtreeIfNeeded()
        
        coloredBgView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        dotBackgroundImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        backgroundImageView.image = backgroundImage
        
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(45)
            make.centerX.equalToSuperview()
            make.leading.trailing.lessThanOrEqualToSuperview().inset(30)
        }
        
        setupThemeButtons()
        
        themeStackView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(22)
            make.centerX.equalToSuperview()
            make.height.equalTo(26)
        }
        
        nextButton.snp.makeConstraints { make in
            make.bottom.equalToSuperview().offset(-96)
            make.centerX.equalToSuperview()
            make.width.equalTo(120)
            make.height.equalTo(40)
        }
    }
    
    // MARK: - Actions
    @objc private func themeButtonClicked(_ sender: NSButton) {
        guard let button = sender as? OnboardingThemeSwatchButton else { return }
        themeChanged(button.theme)
    }
    
    private func themeChanged(_ theme: Theme) {
        selectedThemeId = theme.id
        ThemeManager.shared.switchTheme(to: theme.id)
        updateThemeSelection()
        
        let appearance = ThemeManager.shared.currentAppearance
        let overlayColor = normalizedOverlayColor(for: theme, appearance: appearance)
        let resolvedOverlayColor = overlayColor.usingColorSpace(.deviceRGB)
        let hue = resolvedOverlayColor?.hueComponent ?? 0
        let overridedSaturation: CGFloat? = theme == .pure ? 0 : nil
        let overridedBrightness: CGFloat? = theme == .pure ? 0.5 : nil
        let accentColor = theme == .pure ?
        NSColor.black :
        NSColor(hue: hue,
                saturation: 1,
                brightness: 0.37,
                alpha: 1)
        self.accentColor = accentColor

        titleLabel.textColor = accentColor

        nextButton.titleColor = Color(nsColor: accentColor)
        nextButton.borderColors = [Color(nsColor: accentColor)]
        nextButton.backgroundColor = Color(nsColor: NSColor(hue: hue,
                                                            saturation: overridedSaturation ?? 0.85,
                                                            brightness: overridedBrightness ?? 0.75,
                                                            alpha: 0.1))
        
        dotBackgroundImageView.image = dotBg.tinted(with: accentColor)
        
        coloredBgView.layer?.backgroundColor = NSColor(hue: hue,
                                                       saturation: overridedSaturation ?? 0.85,
                                                       brightness: overridedBrightness ?? 0.75,
                                                       alpha: 1).cgColor
        themChanged(h: hue, s: overridedSaturation, b: overridedBrightness)
    }
    
    private func drawConch(with color: NSColor) {
        let color0 = NSColor.white
        let color57 = color
        let colors = [color0, color57]
        let positions: [CGFloat] = [0.0, 0.1]
        guard let gradient = GradientMapper.makeGradient(colors: colors,
                                                         positions: positions) else {
            return
        }
        guard let strip = GradientMapper.makeStrip(from: gradient) else {
    
            return
        }
        
        guard let mapped = GradientMapper.apply(to: backgroundImage, using: strip) else {
            return
        }
        backgroundImageView.image = mapped
    }
    
    private func nextButtonTapped() {
        PostHogSDK.shared.capture("onboarding_completed", properties: [
            "theme_id": selectedThemeId,
            "accent_color": accentColor.map(colorToHex) ?? "",
        ])
        nextClosure?(true)
    }
    
    // MARK: - Helpers
    private func setupThemeButtons() {
        themeStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        themeButtons.removeAll()
        
        for theme in themes {
            let button = OnboardingThemeSwatchButton(theme: theme)
            button.target = self
            button.action = #selector(themeButtonClicked(_:))
            themeButtons[theme.id] = button
            themeStackView.addArrangedSubview(button)
        }
        
        updateThemeSelection()
    }
    
    private func updateThemeSelection() {
        let appearance = ThemeManager.shared.currentAppearance
        themeButtons.forEach { themeId, button in
            button.updateSelection(themeId == selectedThemeId, appearance: appearance)
        }
    }
    
    private func normalizedOverlayColor(for theme: Theme, appearance: Appearance) -> NSColor {
        theme.color(for: .windowOverlayBackground, appearance: appearance).withAlphaComponent(1)
    }
    
    private func colorToHex(_ color: NSColor) -> String {
        guard let rgbColor = color.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }

        let red = Int(rgbColor.redComponent * 255)
        let green = Int(rgbColor.greenComponent * 255)
        let blue = Int(rgbColor.blueComponent * 255)

        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private func adjustDateLabelFontSize() {
        let maxWidth = view.bounds.width
        var fontSize: CGFloat = 200
        
        dateLabel.font = NSFont(name: "Impact", size: fontSize)
        var textWidth = dateLabel.intrinsicContentSize.width
        
        while textWidth > maxWidth && fontSize > 20 {
            fontSize -= 1
            dateLabel.font = NSFont(name: "Impact", size: fontSize)
            textWidth = dateLabel.intrinsicContentSize.width
        }
    }
    
}

private final class OnboardingThemeSwatchButton: NSButton {
    let theme: Theme
    
    private let swatchView = NSView()
    
    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        isBordered = false
        title = ""
        wantsLayer = true
        
        swatchView.wantsLayer = true
        swatchView.layer?.cornerRadius = 13
        swatchView.layer?.masksToBounds = false
        swatchView.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            return shadow
        }()
        
        addSubview(swatchView)
        
        snp.makeConstraints { make in
            make.width.height.equalTo(26)
        }
        
        swatchView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
    
    func updateSelection(_ selected: Bool, appearance: Appearance) {
        let themeColor = theme.color(for: .themeColor, appearance: appearance)
        let swatchColor = theme == .pure ? .white : themeColor
        let selectedBorderColor = theme == .pure
            ? NSColor.black
            : theme.color(for: .windowOverlayBackground, appearance: appearance).withAlphaComponent(1)
        let unselectedBorderColor = NSColor.black.withAlphaComponent(0.12)
        
        swatchView.layer?.backgroundColor = swatchColor.cgColor
        swatchView.layer?.borderWidth = selected ? 2 : 0
        swatchView.layer?.borderColor = (selected ? selectedBorderColor : unselectedBorderColor).cgColor
    }
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()

        color.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)

        image.unlockFocus()
        return image
    }
}

class KnobView: NSView {
    var knobColor: NSColor = .white

    override func layout() {
        super.layout()
        self.wantsLayer = true
        self.layer?.cornerRadius = min(self.bounds.width, self.bounds.height) / 2
        self.layer?.masksToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        knobColor.setFill()
        dirtyRect.fill()
    }
}
