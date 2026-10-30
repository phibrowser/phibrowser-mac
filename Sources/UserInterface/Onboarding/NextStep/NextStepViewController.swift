// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

enum NextStepGuideLayout {
    static let contentWidth: CGFloat = 472
    static let cardHeight: CGFloat = 459
    static let minimumGuideHeight: CGFloat = 260
    static let cornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 24
    static let verticalPadding: CGFloat = 20
    static let markerSize: CGFloat = 24
    static let markerToContentSpacing: CGFloat = 14
    static let connectorGap: CGFloat = 6
    static let stepSpacing: CGFloat = 18
    static let illustrationSpacing: CGFloat = 12
    static let illustrationWidth: CGFloat = 329
    static let illustrationHeight: CGFloat = 112
    static let illustrationVisibleLeadingInset: CGFloat = 45
    static let illustrationAspectRatio: CGFloat = 329 / 112
    static let checkboxSize: CGFloat = 18
    static let checkboxToTitleSpacing: CGFloat = 10

    static var innerContentWidth: CGFloat {
        contentWidth - (horizontalPadding * 2)
    }

    static var consentTitleWidth: CGFloat {
        innerContentWidth - checkboxSize - checkboxToTitleSpacing
    }
}

enum NextStepGuideOverflow {
    private static let visibilityTolerance: CGFloat = 2

    static func shouldShowIndicator(
        contentBottom: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        viewportHeight > 0 && contentBottom > viewportHeight + visibilityTolerance
    }
}

enum NextStepFinishButtonLayout {
    static let minimumWidth: CGFloat = 120
    static let maximumWidth = NextStepGuideLayout.contentWidth
    private static let horizontalTitlePadding: CGFloat = 16

    static func width(for title: String) -> CGFloat {
        let titleWidth = (title as NSString).size(
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium)
            ]
        ).width
        let proposedWidth = ceil(titleWidth + (horizontalTitlePadding * 2))
        return min(max(proposedWidth, minimumWidth), maximumWidth)
    }
}

enum NextStepLinkStyle {
    static func apply(to attributedString: NSMutableAttributedString, range: NSRange) {
        attributedString.addAttribute(
            .foregroundColor,
            value: NSColor(srgbRed: 184 / 255, green: 154 / 255, blue: 1, alpha: 1),
            range: range
        )
    }
}

struct NextStepConsentState {
    // UN M49 region code for geographic Europe.
    private static let geographicEuropeRegion = Locale.Region("150")
    private static let europeanUnionRegions = Set(Locale.Region("EU").subRegions)

    var hasAcceptedLegalTerms = false
    var sharesUsageMetrics: Bool

    init(sharesUsageMetrics: Bool) {
        self.sharesUsageMetrics = sharesUsageMetrics
    }

    init(locale: Locale = .current) {
        guard let region = locale.region else {
            sharesUsageMetrics = false
            return
        }

        let isEuropeanPrivacyRegion =
            region.continent == Self.geographicEuropeRegion ||
            Self.europeanUnionRegions.contains(region)
        sharesUsageMetrics = !isEuropeanPrivacyRegion
    }

    var canBegin: Bool {
        hasAcceptedLegalTerms
    }
}

final class NextStepViewController: OnboardingBaseViewController {
    private enum Metrics {
        static let dividerHeight: CGFloat = 1
        static let dividerToConsentSpacing: CGFloat = 28
        static let consentSpacing: CGFloat = 12
        static let cardBottomPadding: CGFloat = 20
        static let contentBottomSpacing: CGFloat = 24
    }

    private static let privacyURL = URL(string: "http://phibrowser.com/privacy/")!
    private static let termsURL = URL(string: "http://phibrowser.com/terms/")!
    private static let privacyLinkMarker = "__PHI_PRIVACY_LINK__"
    private static let termsLinkMarker = "__PHI_TERMS_LINK__"

    private var consentState = NextStepConsentState()
    private var isSavingMetricsConsent = false

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
            NextStepGuideView(
                accessibilityTitle: String.localizedStringWithFormat(
                    NSLocalizedString(
                        "oobe.nextSteps.guideVoiceOverDescription",
                        value: "Next steps, %lld steps",
                        comment: "Onboarding next steps - VoiceOver name of the scrollable area listing the steps; the placeholder is the number of steps"
                    ),
                    localizedStepTitles.count
                ),
                stepTitles: localizedStepTitles
            )
                .environment(\.colorScheme, .dark)
        )
    )

    private lazy var legalConsentRow = OnboardingCheckboxRow(
        attributedTitle: legalAgreementTitle,
        accessibilityTitle: legalAgreementTitle.string,
        isChecked: consentState.hasAcceptedLegalTerms
    )

    private lazy var metricsConsentRow = OnboardingCheckboxRow(
        title: NSLocalizedString(
            "oobe.nextSteps.metricsConsent",
            value: "Help make Phi better by sharing usage metrics and crash reports",
            comment: "Onboarding next steps - Optional checkbox for sharing usage metrics and crash reports"
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

    private var localizedTitle: String {
        NSLocalizedString(
            "oobe.nextSteps.title",
            value: "Next steps",
            comment: "Onboarding next steps - Page title"
        )
    }

    private var localizedStepTitles: [String] {
        [
            NSLocalizedString(
                "oobe.nextSteps.onboardAssistant",
                value: "Onboard your AI assistant",
                comment: "Onboarding next steps - First guide step for setting up the AI assistant"
            ),
            NSLocalizedString(
                "oobe.nextSteps.importBrowserData",
                value: "Import data from another browser",
                comment: "Onboarding next steps - Second guide step for importing browser data"
            ),
            NSLocalizedString(
                "oobe.nextSteps.understandFinePrint",
                value: "Have your AI assistant help you understand the fine print 👇",
                comment: "Onboarding next steps - Third guide step for using the AI assistant to understand detailed text"
            ),
            NSLocalizedString(
                "oobe.nextSteps.enjoyPhi",
                value: "Enjoy using Phi Browser 🎉",
                comment: "Onboarding next steps - Fourth guide step welcoming the user to Phi Browser"
            )
        ]
    }

    private var legalAgreementTitle: NSAttributedString {
        let privacyTitle = NSLocalizedString(
            "oobe.nextSteps.privacyLink",
            value: "Privacy Policy",
            comment: "Onboarding next steps - Link title for the Phi privacy policy"
        )
        let termsTitle = NSLocalizedString(
            "oobe.nextSteps.termsLink",
            value: "Terms of Use",
            comment: "Onboarding next steps - Link title for the Phi terms of service"
        )
        let format = NSLocalizedString(
            "oobe.nextSteps.legalAgreement",
            value: "I agree to the %1$@ and %2$@",
            comment: "Onboarding next steps - Required legal agreement; first placeholder is the Privacy link and second is the Terms link"
        )
        let title = String(
            format: format,
            Self.privacyLinkMarker,
            Self.termsLinkMarker
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
            marker: Self.privacyLinkMarker,
            title: privacyTitle,
            url: Self.privacyURL
        )
        replaceLinkMarker(
            in: attributedTitle,
            marker: Self.termsLinkMarker,
            title: termsTitle,
            url: Self.termsURL
        )
        return attributedTitle
    }

    override func loadView() {
        super.loadView()

        setTitle(localizedTitle)

        let beginButtonTitle = NSLocalizedString(
            "oobe.nextSteps.beginButton",
            value: "Let's begin",
            comment: "Onboarding next steps - Final button that completes onboarding"
        )
        configureFooterButtons(.init(
            leftTitle: NSLocalizedString(
                "oobe.navigation.backButton",
                value: "Back",
                comment: "OOBE navigation - Button to return to the previous step"
            ),
            rightTitle: beginButtonTitle
        ))

        setupContent()
        setupActions()
        updateBeginButton()
    }

    override func leftButtonTapped() {
        guard !isSavingMetricsConsent else { return }
        super.leftButtonTapped()
    }

    override func nextButtonTapped(_ sender: NSButton? = nil) {
        guard consentState.canBegin, !isSavingMetricsConsent else { return }

        isSavingMetricsConsent = true
        updateBeginButton()

        if let bridge = ChromiumLauncher.sharedInstance().bridge {
            bridge.setMetricsReportingEnabled(consentState.sharesUsageMetrics) { _ in }
        } else {
            AppLogError("[NextStep] Unable to save metrics consent without the Chromium bridge")
        }

        nextClosure?(true)
    }

    private func setupContent() {
        view.addSubview(contentContainer)
        contentContainer.addSubview(guideHostingView)
        contentContainer.addSubview(dividerView)
        contentContainer.addSubview(consentStackView)

        // Anchor the dense final-step content to the CTA so it cannot compress the base title.
        contentContainer.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.width.equalTo(NextStepGuideLayout.contentWidth)
            make.height.equalTo(NextStepGuideLayout.cardHeight)
            make.bottom.equalTo(nextButton.snp.top).offset(-Metrics.contentBottomSpacing)
        }

        guideHostingView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.bottom.equalTo(dividerView.snp.top)
            make.height
                .greaterThanOrEqualTo(NextStepGuideLayout.minimumGuideHeight)
                .priority(.high)
        }

        dividerView.snp.makeConstraints { make in
            make.left.right.equalToSuperview().inset(NextStepGuideLayout.horizontalPadding)
            make.height.equalTo(Metrics.dividerHeight)
        }

        consentStackView.snp.makeConstraints { make in
            make.top.equalTo(dividerView.snp.bottom).offset(Metrics.dividerToConsentSpacing)
            make.left.right.equalToSuperview().inset(NextStepGuideLayout.horizontalPadding)
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
            self.consentState.hasAcceptedLegalTerms = isChecked
            self.updateBeginButton()
        }
        metricsConsentRow.onToggle = { [weak self] isChecked in
            self?.consentState.sharesUsageMetrics = isChecked
        }
    }

    private func updateBeginButton() {
        let isEnabled = consentState.canBegin && !isSavingMetricsConsent
        leftButton.isEnabled = !isSavingMetricsConsent
        leftButton.alphaValue = isSavingMetricsConsent ? 0.5 : 1
        nextButton.isEnabled = isEnabled
        nextButton.alphaValue = isEnabled ? 1 : 0.5
    }

    private func replaceLinkMarker(
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

struct NextStepGuideView: View {
    private static let scrollCoordinateSpaceName = "NextStepGuideScroll"

    /// VoiceOver name for the scroll area that holds the steps.
    let accessibilityTitle: String
    let stepTitles: [String]
    @State private var showsOverflowIndicator = false

    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                NextStepGuideContentView(stepTitles: stepTitles)
                    .padding(.horizontal, NextStepGuideLayout.horizontalPadding)
                    .padding(.vertical, NextStepGuideLayout.verticalPadding)
                    .background {
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: NextStepGuideOverflowPreferenceKey.self,
                                value: NextStepGuideOverflow.shouldShowIndicator(
                                    contentBottom: contentGeometry.frame(
                                        in: .named(Self.scrollCoordinateSpaceName)
                                    ).maxY,
                                    viewportHeight: viewport.size.height
                                )
                            )
                        }
                    }
            }
            .accessibilityLabel(Text(verbatim: accessibilityTitle))
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(NextStepGuideOverflowPreferenceKey.self) { newValue in
                if showsOverflowIndicator != newValue {
                    showsOverflowIndicator = newValue
                }
            }
            .overlay(alignment: .bottom) {
                if showsOverflowIndicator {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24, height: 20)
                        .background(.black.opacity(0.25), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                        .padding(.bottom, 4)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showsOverflowIndicator)
        }
    }
}

private struct NextStepGuideOverflowPreferenceKey: PreferenceKey {
    static var defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct NextStepGuideContentView: View {
    let stepTitles: [String]
    let illustrationStepIndex: Int?

    init(stepTitles: [String], illustrationStepIndex: Int? = 1) {
        self.stepTitles = stepTitles
        self.illustrationStepIndex = illustrationStepIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, title in
                stepRow(index: index, title: title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // VoiceOver reads the steps as a list; the markers, connectors and
        // illustration stay visual only.
        .accessibilityRepresentation {
            List(Array(stepTitles.enumerated()), id: \.offset) { index, title in
                Text(verbatim: Self.spokenStep(index: index, title: title))
            }
        }
    }

    /// "[number], [title]" with the decorative emoji (👇, 🎉) removed.
    static func spokenStep(index: Int, title: String) -> String {
        let spokenTitle = String(title.filter { character in
            !character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        })
        .trimmingCharacters(in: .whitespaces)
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "oobe.nextSteps.stepVoiceOverDescription",
                value: "%1$lld, %2$@",
                comment: "Onboarding next steps - VoiceOver description of one step; first placeholder is the step number, second is the step text"
            ),
            index + 1,
            spokenTitle
        )
    }

    private func stepRow(index: Int, title: String) -> some View {
        let isLastStep = index == stepTitles.count - 1

        return HStack(alignment: .top, spacing: NextStepGuideLayout.markerToContentSpacing) {
            Text(String(index + 1))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .frame(
                    width: NextStepGuideLayout.markerSize,
                    height: NextStepGuideLayout.markerSize
                )
                .background {
                    Circle()
                        .fill(.white.opacity(0.1))
                }
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: NextStepGuideLayout.illustrationSpacing) {
                Text(title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                if index == illustrationStepIndex {
                    ImportHintIllustration()
                        .offset(x: -NextStepGuideLayout.illustrationVisibleLeadingInset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, isLastStep ? 0 : NextStepGuideLayout.stepSpacing)
        .overlay(alignment: .topLeading) {
            if !isLastStep {
                Rectangle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 1)
                    .padding(.top, NextStepGuideLayout.markerSize + NextStepGuideLayout.connectorGap)
                    .padding(.bottom, NextStepGuideLayout.connectorGap)
                    .offset(x: (NextStepGuideLayout.markerSize - 1) / 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ImportHintIllustration: View {
    // The supplied SVG outlines its English menu label, so non-English UIs
    // replace that label with a language-neutral placeholder.
    private var shouldCoverEmbeddedEnglishCopy: Bool {
        guard let localization = Bundle.main.preferredLocalizations.first else {
            return false
        }
        return !localization.hasPrefix("en")
    }

    var body: some View {
        Image(.importHint)
            .resizable()
            .scaledToFit()
            .aspectRatio(
                NextStepGuideLayout.illustrationAspectRatio,
                contentMode: .fit
            )
            .frame(
                width: NextStepGuideLayout.illustrationWidth,
                height: NextStepGuideLayout.illustrationHeight
            )
            .overlay {
                if shouldCoverEmbeddedEnglishCopy {
                    embeddedCopyCover
                }
            }
            .accessibilityHidden(true)
    }

    private var embeddedCopyCover: some View {
        GeometryReader { proxy in
            let horizontalScale = proxy.size.width / 329
            let verticalScale = proxy.size.height / 112
            let cornerScale = min(horizontalScale, verticalScale)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: cornerScale, style: .continuous)
                    .fill(Color(red: 68 / 255, green: 68 / 255, blue: 68 / 255))
                    .frame(width: 57 * horizontalScale, height: 9 * verticalScale)
                    .offset(x: 68 * horizontalScale, y: 51 * verticalScale)

                RoundedRectangle(cornerRadius: cornerScale, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .frame(width: 40 * horizontalScale, height: 6 * verticalScale)
                    .offset(x: 69 * horizontalScale, y: 52 * verticalScale)
            }
        }
    }
}

final class OnboardingCheckboxRow: NSView {
    var onToggle: ((Bool) -> Void)?

    private var isChecked: Bool

    private lazy var checkboxButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggleCheckbox)
        button.setAccessibilityRole(.checkBox)
        return button
    }()

    private let titleView: NSView

    convenience init(title: String, isChecked: Bool) {
        let attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85)
            ]
        )
        self.init(
            attributedTitle: attributedTitle,
            accessibilityTitle: title,
            isChecked: isChecked
        )
    }

    init(
        attributedTitle: NSAttributedString,
        accessibilityTitle: String,
        isChecked: Bool
    ) {
        self.isChecked = isChecked
        if attributedTitle.containsAttachmentsOrLinks {
            self.titleView = NextStepLinkTextView(
                attributedString: attributedTitle,
                preferredLayoutWidth: NextStepGuideLayout.consentTitleWidth
            )
        } else {
            let titleLabel = NSTextField(wrappingLabelWithString: "")
            titleLabel.attributedStringValue = attributedTitle
            titleLabel.isSelectable = false
            titleLabel.maximumNumberOfLines = 0
            titleLabel.lineBreakMode = .byWordWrapping
            self.titleView = titleLabel
        }
        super.init(frame: .zero)

        if let linkTextView = titleView as? NextStepLinkTextView {
            linkTextView.onNonLinkClick = { [weak self] in
                self?.toggleCheckbox()
            }
        } else {
            titleView.addGestureRecognizer(
                NSClickGestureRecognizer(target: self, action: #selector(toggleCheckbox))
            )
        }

        checkboxButton.setAccessibilityLabel(accessibilityTitle)
        addSubview(checkboxButton)
        addSubview(titleView)

        checkboxButton.snp.makeConstraints { make in
            make.left.equalToSuperview()
            make.top.equalToSuperview().offset(1)
            make.width.height.equalTo(NextStepGuideLayout.checkboxSize)
        }

        titleView.snp.makeConstraints { make in
            make.left.equalTo(checkboxButton.snp.right)
                .offset(NextStepGuideLayout.checkboxToTitleSpacing)
            make.top.right.bottom.equalToSuperview()
        }

        updateCheckboxAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleCheckbox() {
        isChecked.toggle()
        updateCheckboxAppearance()
        onToggle?(isChecked)
    }

    private func updateCheckboxAppearance() {
        checkboxButton.image = isChecked
            ? NSImage(resource: .check)
            : NSImage(resource: .uncheck)
        checkboxButton.setAccessibilityValue(
            isChecked ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue
        )
    }
}

final class NextStepLinkTextView: NSTextView {
    var onNonLinkClick: (() -> Void)?

    private let preferredLayoutWidth: CGFloat
    private let backingTextStorage: NSTextStorage

    init(
        attributedString: NSAttributedString,
        preferredLayoutWidth: CGFloat
    ) {
        let textStorage = NSTextStorage(attributedString: attributedString)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(
                width: preferredLayoutWidth,
                height: .greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        self.preferredLayoutWidth = preferredLayoutWidth
        self.backingTextStorage = textStorage
        super.init(frame: .zero, textContainer: textContainer)

        isEditable = false
        isSelectable = true
        drawsBackground = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.containerSize = NSSize(
            width: preferredLayoutWidth,
            height: .greatestFiniteMagnitude
        )
        isHorizontallyResizable = false
        isVerticallyResizable = false
        linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard let textContainer, let layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 18)
        }

        let layoutWidth = bounds.width > 0 ? bounds.width : preferredLayoutWidth
        textContainer.containerSize = NSSize(
            width: layoutWidth,
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let height = ceil(usedRect.height + (textContainerInset.height * 2) + 2)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 18))
    }

    override func mouseDown(with event: NSEvent) {
        guard let onNonLinkClick else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        if let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 {
            let glyphIndex = layoutManager.glyphIndex(for: textPoint, in: textContainer)
            let glyphRange = NSRange(location: glyphIndex, length: 1)
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            if layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .contains(textPoint),
                backingTextStorage.attribute(.link, at: characterIndex, effectiveRange: nil) != nil {
                super.mouseDown(with: event)
                return
            }
        }

        onNonLinkClick()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
        }
    }
}

private extension NSAttributedString {
    var containsAttachmentsOrLinks: Bool {
        var containsLink = false
        enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: length)
        ) { value, _, stop in
            guard value != nil else { return }
            containsLink = true
            stop.pointee = true
        }
        return containsLink
    }
}
