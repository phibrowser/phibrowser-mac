// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

enum GuestPrivacyLegalAgreement {
    static let privacyURL = URL(string: "http://phibrowser.com/privacy/")!
    static let termsURL = URL(string: "http://phibrowser.com/terms/")!

    private static let privacyLinkMarker = "__PHI_GUEST_PRIVACY_LINK__"
    private static let termsLinkMarker = "__PHI_GUEST_TERMS_LINK__"

    static var localizedTitle: NSAttributedString {
        makeAttributedTitle(
            format: NSLocalizedString(
                "oobe.guestPrivacy.legalAgreement",
                value: "I agree to the %2$@ and %1$@",
                comment: "Guest privacy confirmation - Required legal agreement; first placeholder is the Privacy Policy link and second is the Terms of Use link"
            ),
            privacyTitle: NSLocalizedString(
                "oobe.guestPrivacy.privacyPolicyLink",
                value: "Privacy Policy",
                comment: "Guest privacy confirmation - Link title for the Phi privacy policy"
            ),
            termsTitle: NSLocalizedString(
                "oobe.guestPrivacy.termsOfServiceLink",
                value: "Terms of Use",
                comment: "Guest privacy confirmation - Link title for the Phi terms of service"
            )
        )
    }

    static func makeAttributedTitle(
        format: String,
        privacyTitle: String,
        termsTitle: String
    ) -> NSAttributedString {
        let title = String(
            format: format,
            privacyLinkMarker,
            termsLinkMarker
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributedTitle = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6),
                .paragraphStyle: paragraphStyle
            ]
        )
        replaceLinkMarker(
            in: attributedTitle,
            marker: privacyLinkMarker,
            title: privacyTitle,
            url: privacyURL
        )
        replaceLinkMarker(
            in: attributedTitle,
            marker: termsLinkMarker,
            title: termsTitle,
            url: termsURL
        )
        return attributedTitle
    }

    private static func replaceLinkMarker(
        in attributedTitle: NSMutableAttributedString,
        marker: String,
        title: String,
        url: URL
    ) {
        let markerRange = (attributedTitle.string as NSString).range(of: marker)
        guard markerRange.location != NSNotFound else { return }

        attributedTitle.replaceCharacters(in: markerRange, with: title)
        let range = NSRange(
            location: markerRange.location,
            length: (title as NSString).length
        )
        attributedTitle.addAttributes(
            [
                .link: url,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand
            ],
            range: range
        )
        NextStepLinkStyle.apply(to: attributedTitle, range: range)
    }
}

struct GuestPrivacyGuideView: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(NSLocalizedString(
                        "oobe.guestPrivacy.availableNow", value: "Available now",
                        comment: "Guest confirmation - Heading for features available without signing in"
                    ))
                    HStack(alignment: .top, spacing: 12) {
                        icon("🌐")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString(
                                "oobe.guestPrivacy.browserTitle", value: "Full-fledged browser",
                                comment: "Guest confirmation - Title of the available browser features"
                            ))
                            .font(.system(size: 18, weight: .medium))
                            Text(NSLocalizedString(
                                "oobe.guestPrivacy.browserDescription",
                                value: "All browser features, including Tabs, Profiles, Spaces and Developer Tools",
                                comment: "Guest confirmation - Description of features available without signing in"
                            ))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(NSLocalizedString(
                        "oobe.guestPrivacy.requiresSignIn", value: "Requires a Phi account and sign-in",
                        comment: "Guest confirmation - Heading for features that require signing in"
                    ))
                    VStack(alignment: .leading, spacing: 16) {
                        feature("🔄", title: NSLocalizedString(
                            "oobe.guestPrivacy.sync", value: "Sync",
                            comment: "Guest confirmation - Sync feature requiring sign-in"
                        ))
                        feature("✨", title: NSLocalizedString(
                            "oobe.guestPrivacy.aiFeatures", value: "AI features",
                            comment: "Guest confirmation - AI features requiring sign-in"
                        ))
                        feature("🧠", title: NSLocalizedString(
                            "oobe.guestPrivacy.browserMemory", value: "Browser Memory",
                            comment: "Guest confirmation - Browser Memory feature requiring sign-in"
                        ))
                        feature("···", title: NSLocalizedString(
                            "oobe.guestPrivacy.moreFeatures", value: "and much more",
                            comment: "Guest confirmation - Additional features available after sign-in"
                        ))
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func icon(_ symbol: String) -> some View {
        Text(verbatim: symbol)
            .font(.system(size: 18, weight: .medium))
            .frame(width: 28, height: 22)
            .accessibilityHidden(true)
    }

    private func feature(_ symbol: String, title: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(symbol)
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

final class GuestPrivacyConfirmationViewController: OnboardingBaseViewController {
    private enum Metrics {
        static let contentTopSpacing: CGFloat = 18
        static let dividerHeight: CGFloat = 1
        static let dividerToConsentSpacing: CGFloat = 18
        static let consentSpacing: CGFloat = 4
        static let cardBottomPadding: CGFloat = 18
        static let contentBottomSpacing: CGFloat = 24
    }

    private var consentState = NextStepConsentState()
    private var isSavingMetricsConsent = false

    var onSignIn: (() -> Void)?

    var onConfirm: ((Bool) -> Void)?

    private lazy var contentContainer: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = NextStepGuideLayout.cornerRadius
        container.layer?.masksToBounds = true
        return container
    }()

    private lazy var dividerView: NSView = {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        return divider
    }()

    private lazy var guideHostingView = ZeroSafeAreaHostingView(
        rootView: AnyView(
            GuestPrivacyGuideView()
                .environment(\.colorScheme, .dark)
        )
    )

    private lazy var legalConsentRow: OnboardingCheckboxRow = {
        let title = GuestPrivacyLegalAgreement.localizedTitle
        return OnboardingCheckboxRow(
            attributedTitle: title,
            accessibilityTitle: title.string,
            isChecked: consentState.hasAcceptedLegalTerms
        )
    }()

    private lazy var metricsConsentRow: OnboardingCheckboxRow = {
        let title = NSLocalizedString(
            "oobe.guestPrivacy.metricsConsent",
            value: "Help make Phi better by sharing usage metrics and crash reports",
            comment: "Guest privacy confirmation - Optional checkbox for sharing usage metrics and crash reports"
        )
        return OnboardingCheckboxRow(
            attributedTitle: NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6)
            ]),
            accessibilityTitle: title,
            isChecked: consentState.sharesUsageMetrics
        )
    }()

    private lazy var consentStackView: NSStackView = {
        let stackView = NSStackView(views: [legalConsentRow, metricsConsentRow])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = Metrics.consentSpacing
        return stackView
    }()

    override func loadView() {
        super.loadView()

        setTitle(NSLocalizedString(
            "oobe.guestPrivacy.title",
            value: "Before we begin",
            comment: "Guest privacy confirmation - Page title shown before entering Guest Mode"
        ))
        // AppKit's fixed-baseline single-line mode clips the tall display font
        // (NextStepViewController records the same). The height is a floor, not
        // a fixed size: at 46pt this line wants 68pt, and pinning it to 64 left
        // the glyphs nothing to overflow into.
        titleLabel.cell?.usesSingleLineMode = false
        titleLabel.cell?.wraps = false
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byClipping
        titleLabel.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualToSuperview().offset(30)
            make.trailing.lessThanOrEqualToSuperview().offset(-30)
            make.height.greaterThanOrEqualTo(64)
        }

        skipButton.title = NSLocalizedString(
            "oobe.guestPrivacy.signInInstead", value: "Sign in instead",
            comment: "Guest confirmation - Button returning to the sign-in page"
        )
        skipButton.font = .systemFont(ofSize: 15)
        skipButton.contentTintColor = .white.withAlphaComponent(0.7)
        skipButton.snp.remakeConstraints { make in
            make.top.equalTo(nextButton.snp.bottom).offset(16)
            make.centerX.equalToSuperview()
            make.width.greaterThanOrEqualTo(222)
            make.height.equalTo(28)
        }
        let beginButtonTitle = NSLocalizedString(
            "oobe.guestPrivacy.beginButton",
            value: "Let’s begin",
            comment: "Guest privacy confirmation - Button that confirms the choices and enters Guest Mode"
        )
        nextButton.title = beginButtonTitle
        nextButton.snp.updateConstraints { make in
            make.width.equalTo(max(200, NextStepFinishButtonLayout.width(for: beginButtonTitle)))
        }

        setupContent()
        setupActions()
        updateBeginButton()
    }

    override func nextButtonTapped(_ sender: NSButton? = nil) {
        guard consentState.canBegin, !isSavingMetricsConsent else { return }

        isSavingMetricsConsent = true
        updateBeginButton()
        onConfirm?(consentState.sharesUsageMetrics)
    }

    override func skipButtonTapped(_ sender: NSButton) {
        guard !isSavingMetricsConsent else { return }
        onSignIn?()
    }

    func resetAfterGuestEntryFailure() {
        guard isSavingMetricsConsent else { return }
        isSavingMetricsConsent = false
        updateBeginButton()
    }

    private func setupContent() {
        view.addSubview(contentContainer)
        contentContainer.addSubview(guideHostingView)
        contentContainer.addSubview(dividerView)
        contentContainer.addSubview(consentStackView)

        contentContainer.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(Metrics.contentTopSpacing)
            make.centerX.equalToSuperview()
            make.width.equalTo(NextStepGuideLayout.contentWidth)
            make.height.equalTo(417).priority(.high)
            make.bottom.lessThanOrEqualTo(nextButton.snp.top)
                .offset(-Metrics.contentBottomSpacing)
        }

        guideHostingView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.bottom.equalTo(dividerView.snp.top)
            make.height
                .greaterThanOrEqualTo(NextStepGuideLayout.minimumGuideHeight)
                .priority(.high)
        }

        dividerView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
                .inset(18)
            make.height.equalTo(Metrics.dividerHeight)
        }

        consentStackView.snp.makeConstraints { make in
            make.top.equalTo(dividerView.snp.bottom)
                .offset(Metrics.dividerToConsentSpacing)
            make.left.right.equalToSuperview()
                .inset(18)
            make.bottom.equalToSuperview().offset(-Metrics.cardBottomPadding)
        }

        for row in [legalConsentRow, metricsConsentRow] {
            row.snp.makeConstraints { make in
                make.width.equalTo(NextStepGuideLayout.contentWidth - 36)
                make.height.greaterThanOrEqualTo(26)
            }
        }
    }

    private func setupActions() {
        legalConsentRow.onToggle = { [weak self] isChecked in
            guard let self else { return }
            consentState.hasAcceptedLegalTerms = isChecked
            updateBeginButton()
        }
        metricsConsentRow.onToggle = { [weak self] isChecked in
            self?.consentState.sharesUsageMetrics = isChecked
        }
    }

    private func updateBeginButton() {
        let isEnabled = consentState.canBegin && !isSavingMetricsConsent
        skipButton.isEnabled = !isSavingMetricsConsent
        nextButton.isEnabled = isEnabled
        nextButton.alphaValue = isEnabled ? 1 : 0.5
    }

}
