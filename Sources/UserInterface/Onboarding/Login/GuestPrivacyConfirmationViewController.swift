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
                value: "I agree to the %1$@ and %2$@",
                comment: "Guest privacy confirmation - Required legal agreement; first placeholder is the Privacy Policy link and second is the Terms of Service link"
            ),
            privacyTitle: NSLocalizedString(
                "oobe.guestPrivacy.privacyPolicyLink",
                value: "Privacy Policy",
                comment: "Guest privacy confirmation - Link title for the Phi privacy policy"
            ),
            termsTitle: NSLocalizedString(
                "oobe.guestPrivacy.termsOfServiceLink",
                value: "Terms of Service",
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
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
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
        NextStepLinkGradient.apply(to: attributedTitle, range: range)
    }
}

struct GuestPrivacyGuideView: View {
    let noticeTitles: [String]

    private enum Layout {
        static let noticeFontSize: CGFloat = 20
        static let bulletFontSize: CGFloat = 28
        static let noticeSpacing: CGFloat = 20
        static let horizontalPadding: CGFloat = 24
        static let verticalPadding: CGFloat = 20
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Layout.noticeSpacing) {
                    ForEach(Array(noticeTitles.enumerated()), id: \.offset) { _, title in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: "·")
                                .font(.system(size: Layout.bulletFontSize, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))

                            Text(title)
                                .font(.system(size: Layout.noticeFontSize, weight: .regular))
                                .foregroundStyle(.white.opacity(0.9))
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.vertical, Layout.verticalPadding)
                .frame(width: viewport.size.width)
                .frame(
                    minHeight: viewport.size.height,
                    alignment: .center
                )
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

final class GuestPrivacyConfirmationViewController: OnboardingBaseViewController {
    private enum Metrics {
        static let contentTopSpacing: CGFloat = 12
        static let dividerHeight: CGFloat = 1
        static let dividerToConsentSpacing: CGFloat = 28
        static let consentSpacing: CGFloat = 12
        static let cardBottomPadding: CGFloat = 20
        static let contentBottomSpacing: CGFloat = 24
    }

    private var consentState = NextStepConsentState()
    private var isSavingMetricsConsent = false

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
            GuestPrivacyGuideView(noticeTitles: localizedNoticeTitles)
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

    private lazy var metricsConsentRow = OnboardingCheckboxRow(
        title: NSLocalizedString(
            "oobe.guestPrivacy.metricsConsent",
            value: "Help make Phi better by sharing usage metrics and crash reports",
            comment: "Guest privacy confirmation - Optional checkbox for sharing usage metrics and crash reports"
        ),
        isChecked: consentState.sharesUsageMetrics
    )

    private lazy var consentStackView: NSStackView = {
        let stackView = NSStackView(views: [legalConsentRow, metricsConsentRow])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = Metrics.consentSpacing
        return stackView
    }()

    private var localizedNoticeTitles: [String] {
        [
            NSLocalizedString(
                "oobe.guestPrivacy.aiFeaturesUnavailable",
                value: "No AI features until you sign in",
                comment: "Guest privacy confirmation - Notice that AI features require signing in"
            ),
            NSLocalizedString(
                "oobe.guestPrivacy.browserMemoryUnavailable",
                value: "No Browser Memory either",
                comment: "Guest privacy confirmation - Notice that Browser Memory is unavailable without signing in"
            ),
            NSLocalizedString(
                "oobe.guestPrivacy.signInAnytime",
                value: "Sign in whenever you're ready",
                comment: "Guest privacy confirmation - Notice that the user can sign in later"
            )
        ]
    }

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

        skipButton.isHidden = true
        let beginButtonTitle = NSLocalizedString(
            "oobe.guestPrivacy.beginButton",
            value: "Let's Begin",
            comment: "Guest privacy confirmation - Button that confirms the choices and enters Guest Mode"
        )
        nextButton.title = beginButtonTitle
        nextButton.snp.updateConstraints { make in
            make.width.equalTo(NextStepFinishButtonLayout.width(for: beginButtonTitle))
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
            make.height.equalTo(NextStepGuideLayout.cardHeight).priority(.high)
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
                .inset(NextStepGuideLayout.horizontalPadding)
            make.height.equalTo(Metrics.dividerHeight)
        }

        consentStackView.snp.makeConstraints { make in
            make.top.equalTo(dividerView.snp.bottom)
                .offset(Metrics.dividerToConsentSpacing)
            make.left.right.equalToSuperview()
                .inset(NextStepGuideLayout.horizontalPadding)
            make.bottom.equalToSuperview().offset(-Metrics.cardBottomPadding)
        }

        for row in [legalConsentRow, metricsConsentRow] {
            row.snp.makeConstraints { make in
                make.width.equalTo(NextStepGuideLayout.innerContentWidth)
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
        nextButton.isEnabled = isEnabled
        nextButton.alphaValue = isEnabled ? 1 : 0.5
    }

}
