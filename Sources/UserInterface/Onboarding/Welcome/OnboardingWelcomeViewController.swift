// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import SwiftUI
import PostHog

class OnboardingWelcomeViewController: OnboardingBaseViewController {
    private let cardView = HolographicCardView()
    private var profileTask: Task<Void, Never>?

    private lazy var randomButton: NSButton = {
        let button = NSButton(image: NSImage(resource: .oobeDice), target: self, action: #selector(randomizeCard))
        let title = NSLocalizedString("oobe.welcome.randomizeCard", value: "Randomize",
            comment: "Onboarding membership card - Randomly choose a theme, background texture and ornament")
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        button.layer?.cornerRadius = 20
        return button
    }()

    private var selectedThemeId: String = Theme.pure.id

    private var themes: [Theme] {
        Theme.builtInThemes.map { builtInTheme in
            ThemeManager.shared.registeredThemes[builtInTheme.id] ?? builtInTheme
        }
    }

    var userName: String? {
        didSet {
            cardView.name = userName ?? "Phi"
        }
    }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        cardView.style = LoginController.shared.accountForOnboarding?.userDefaults.codableValue(
            forKey: AccountUserDefaults.DefaultsKey.profileCardStyle.rawValue) ?? .default
        selectedThemeId = cardView.style.palette.themeID
        cardView.isPresentationActive = true
        profileTask?.cancel()
        profileTask = Task { [weak self] in await self?.requestProfile() }
        if let theme = themes.first(where: { $0.id == selectedThemeId }) ?? themes.first {
            themeChanged(theme)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cardView.isPresentationActive = false
        profileTask?.cancel()
        profileTask = nil
    }

    private func requestProfile() async {
        guard let accountUserID = LoginController.shared.accountForOnboarding?.userID else {
            AppLogWarn("[OOBEWelcome] Skip profile request: no onboarding account")
            return
        }
        cardView.memberID = HolographicCardView.memberID(sub: accountUserID)
        do {
            let profile = try await APIClient.shared.getOnboardingAccountProfile(accountUserID: accountUserID).data
            guard !Task.isCancelled else { return }
            // A profile read must not overwrite a name just saved in this flow.
            cardView.name = userName ?? profile.name
            cardView.joinedDate = HolographicCardView.formattedJoinDate(profile.created_at)
        } catch {
            guard !Task.isCancelled else { return }
            AppLogWarn("[OOBEWelcome] Failed to load profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Setup
    private func setupUI() {
        titleLabel.isHidden = true
        configureFooterButtons(.init(
            leftTitle: NSLocalizedString(
                "oobe.navigation.backButton",
                value: "Back",
                comment: "OOBE navigation - Button to return to the previous step"
            ),
            rightTitle: nextButton.title
        ))
        nextButton.backgroundColor = Color.white.opacity(0.05)

        view.addSubview(cardView)
        view.addSubview(randomButton)

        cardView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalTo(view.snp.top).offset(337.5)
            make.size.equalTo(HolographicCardView.designSize)
        }

        randomButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(585)
            make.width.height.equalTo(40)
        }
    }

    // MARK: - Actions
    @objc private func randomizeCard() {
        let style = HolographicCardStyle.random()
        guard saveCardStyle(style) else { return }
        cardView.style = style
        if let theme = themes.first(where: { $0.id == cardView.style.palette.themeID }) {
            themeChanged(theme)
        }
    }

    private func themeChanged(_ theme: Theme) {
        selectedThemeId = theme.id
        ThemeManager.shared.switchTheme(to: theme.id)
        cardView.style.palette = .init(themeID: theme.id)
    }

    private func saveCardStyle(_ style: HolographicCardStyle) -> Bool {
        if let defaults = LoginController.shared.accountForOnboarding?.userDefaults,
           !defaults.set(style, forCodableKey: AccountUserDefaults.DefaultsKey.profileCardStyle.rawValue) {
            let message = NSLocalizedString("oobe.welcome.cardSaveFailed", value: "Your card could not be saved. Please try again.",
                comment: "Onboarding membership card - Error when the selected card style cannot be saved")
            NSApp.presentError(NSError(domain: "Phi.ProfileCard", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
            return false
        }
        return true
    }

    override func nextButtonTapped(_ sender: NSButton? = nil) {
        guard saveCardStyle(cardView.style) else { return }
        let accentColor = themes.first(where: { $0.id == selectedThemeId }).map(accentColor(for:))
        PostHogSDK.shared.capture("onboarding_completed", properties: [
            "theme_id": selectedThemeId,
            "accent_color": accentColor.map(colorToHex) ?? "",
        ])
        super.nextButtonTapped(sender)
    }

    // MARK: - Helpers
    private func accentColor(for theme: Theme) -> NSColor {
        guard theme != .pure else { return .black }
        let appearance = ThemeManager.shared.currentAppearance
        let overlayColor = theme.color(for: .windowOverlayBackground, appearance: appearance).withAlphaComponent(1)
        let hue = overlayColor.usingColorSpace(.deviceRGB)?.hueComponent ?? 0
        return NSColor(hue: hue, saturation: 1, brightness: 0.37, alpha: 1)
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
