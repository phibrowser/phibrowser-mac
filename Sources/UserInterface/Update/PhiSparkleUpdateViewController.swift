//
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.
    

#if !PHI_OSS_BUILD
import Cocoa
import Sparkle
import WebKit
@MainActor
class PhiSparkleUpdateViewController: NSViewController, WKNavigationDelegate {
    var onSkip: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onInstall: (() -> Void)?

    var automaticallyDownloadsEnabled: Bool {
        automaticDownloadsCheckbox.state == .on
    }

    private let appcastItem: SUAppcastItem
    private let mode: PhiSparkleUpdateWindowMode
    private let automaticDownloadsInitiallyEnabled: Bool
    private let allowsAutomaticUpdates: Bool
    private let themeProvider: ThemeStateProvider
    private var themeObservation: AnyObject?
    private var releaseNotesLoadInProgress = false
    private var didInstallExternalReferenceBlocker = false

    private let headerIconView = NSImageView()
    private let releaseNotesContainer = NSView()
    private let releaseNotesResourceSchemeHandler: PhiSparkleReleaseNotesResourceSchemeHandler
    private let releaseNotesWebView: WKWebView
    private let releaseNotesPlaceholder = NSTextField(labelWithString: "")
    private let automaticDownloadsCheckbox = NSButton()
    private let skipButton = PhiSparkleUpdateButton(style: .secondary)
    private let remindButton = PhiSparkleUpdateButton(style: .secondary)
    private let installButton = PhiSparkleUpdateButton(style: .primary)

    init(appcastItem: SUAppcastItem,
         mode: PhiSparkleUpdateWindowMode,
         automaticDownloadsEnabled: Bool,
         allowsAutomaticUpdates: Bool,
         themeProvider: ThemeStateProvider) {
        self.appcastItem = appcastItem
        self.mode = mode
        automaticDownloadsInitiallyEnabled = automaticDownloadsEnabled
        self.allowsAutomaticUpdates = allowsAutomaticUpdates
        self.themeProvider = themeProvider

        let configuration = WKWebViewConfiguration()
        let resourceSchemeHandler = PhiSparkleReleaseNotesResourceSchemeHandler(bundle: .main)
        configuration.setURLSchemeHandler(
            resourceSchemeHandler,
            forURLScheme: PhiSparkleReleaseNotesResourceSchemeHandler.scheme
        )
        releaseNotesResourceSchemeHandler = resourceSchemeHandler
        let javaScriptEnabled = (Bundle.main.object(forInfoDictionaryKey: "SUEnableJavaScript") as? Bool) ?? false
        if #available(macOS 11.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScriptEnabled
        } else {
            configuration.preferences.javaScriptEnabled = javaScriptEnabled
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        releaseNotesWebView = WKWebView(frame: .zero, configuration: configuration)

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = PhiSparkleRootView(frame: NSRect(x: 0, y: 0, width: 520, height: 588))
        rootView.appearanceDidChange = { [weak self] in
            self?.applyAppearance()
        }
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 24
        rootView.layer?.masksToBounds = true
        view = rootView

        buildLayout(in: rootView)
        bindThemeProvider()
        applyAppearance()
        loadInitialReleaseNotes()
    }

    private func bindThemeProvider() {
        themeObservation = themeProvider.subscribe { [weak self] _, _ in
            self?.applyAppearance()
        }
    }

    func refreshAppearance() {
        applyAppearance()
    }

    private func buildLayout(in rootView: NSView) {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(contentView)

        let headerView = NSStackView()
        headerView.orientation = .horizontal
        headerView.alignment = .centerY
        headerView.spacing = 8
        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerView)

        let iconImage = (NSImage(named: "update-icon") ??
            NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Update"))?.copy() as? NSImage
        iconImage?.isTemplate = true
        headerIconView.image = iconImage
        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addArrangedSubview(headerIconView)

        let titleLabel = NSTextField(labelWithString: mode.title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        headerView.addArrangedSubview(titleLabel)

        configureReleaseNotesContainer()
        contentView.addSubview(releaseNotesContainer)

        configureAutomaticDownloadsCheckbox()
        contentView.addSubview(automaticDownloadsCheckbox)

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .height
        buttonStack.spacing = 8
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonStack)

        skipButton.title = NSLocalizedString("updates.updateWindow.skipVersionButton", value: "Skip This Version", comment: "Update window - Skip update button")
        skipButton.themeProvider = themeProvider
        skipButton.target = self
        skipButton.action = #selector(skipButtonClicked)
        buttonStack.addArrangedSubview(skipButton)

        remindButton.title = mode.dismissButtonTitle
        remindButton.themeProvider = themeProvider
        remindButton.target = self
        remindButton.action = #selector(remindButtonClicked)
        buttonStack.addArrangedSubview(remindButton)

        installButton.title = mode.installButtonTitle
        installButton.themeProvider = themeProvider
        installButton.target = self
        installButton.action = #selector(installButtonClicked)
        buttonStack.addArrangedSubview(installButton)

        let constraints = [
            contentView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 36),
            contentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -36),
            contentView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 36),
            contentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -36),

            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 24),

            headerIconView.widthAnchor.constraint(equalToConstant: 24),
            headerIconView.heightAnchor.constraint(equalToConstant: 24),

            releaseNotesContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            releaseNotesContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            releaseNotesContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 24),
            releaseNotesContainer.heightAnchor.constraint(equalToConstant: 364),

            automaticDownloadsCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            automaticDownloadsCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            automaticDownloadsCheckbox.topAnchor.constraint(equalTo: releaseNotesContainer.bottomAnchor, constant: 10),
            automaticDownloadsCheckbox.heightAnchor.constraint(equalToConstant: 16),

            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 32),
            skipButton.heightAnchor.constraint(equalToConstant: 32),
            remindButton.heightAnchor.constraint(equalToConstant: 32),
            installButton.heightAnchor.constraint(equalToConstant: 32)
        ]

        NSLayoutConstraint.activate(constraints)
    }

    private func configureReleaseNotesContainer() {
        releaseNotesContainer.translatesAutoresizingMaskIntoConstraints = false
        releaseNotesContainer.wantsLayer = true
        releaseNotesContainer.layer?.cornerRadius = 8
        releaseNotesContainer.layer?.masksToBounds = true

        releaseNotesWebView.translatesAutoresizingMaskIntoConstraints = false
        releaseNotesWebView.navigationDelegate = self
        releaseNotesContainer.addSubview(releaseNotesWebView)

        releaseNotesPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        releaseNotesPlaceholder.font = .systemFont(ofSize: 13)
        releaseNotesPlaceholder.textColor = .secondaryLabelColor
        releaseNotesPlaceholder.alignment = .center
        releaseNotesContainer.addSubview(releaseNotesPlaceholder)

        NSLayoutConstraint.activate([
            releaseNotesWebView.leadingAnchor.constraint(equalTo: releaseNotesContainer.leadingAnchor),
            releaseNotesWebView.trailingAnchor.constraint(equalTo: releaseNotesContainer.trailingAnchor),
            releaseNotesWebView.topAnchor.constraint(equalTo: releaseNotesContainer.topAnchor),
            releaseNotesWebView.bottomAnchor.constraint(equalTo: releaseNotesContainer.bottomAnchor),

            releaseNotesPlaceholder.centerXAnchor.constraint(equalTo: releaseNotesContainer.centerXAnchor),
            releaseNotesPlaceholder.centerYAnchor.constraint(equalTo: releaseNotesContainer.centerYAnchor),
            releaseNotesPlaceholder.leadingAnchor.constraint(greaterThanOrEqualTo: releaseNotesContainer.leadingAnchor, constant: 24),
            releaseNotesPlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: releaseNotesContainer.trailingAnchor, constant: -24)
        ])
    }

    private func configureAutomaticDownloadsCheckbox() {
        automaticDownloadsCheckbox.translatesAutoresizingMaskIntoConstraints = false
        automaticDownloadsCheckbox.setButtonType(.switch)
        automaticDownloadsCheckbox.title = NSLocalizedString("updates.updateWindow.automaticDownloadToggle", value: "Automatically download and install updates in the future",
            comment: "Update window - Automatic update download checkbox"
        )
        automaticDownloadsCheckbox.font = .systemFont(ofSize: 13)
        automaticDownloadsCheckbox.state = automaticDownloadsInitiallyEnabled ? .on : .off
        automaticDownloadsCheckbox.isEnabled = allowsAutomaticUpdates
    }

    private func applyAppearance() {
        let appearance = themeProvider.currentAppearance
        view.window?.appearance = appearance.nsAppearance

        (appearance.nsAppearance ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            releaseNotesContainer.layer?.backgroundColor = releaseNotesBackgroundColor.cgColor
            releaseNotesWebView.underPageBackgroundColor = releaseNotesBackgroundColor
            headerIconView.contentTintColor = headerIconTintColor
        }

        skipButton.updateAppearance()
        remindButton.updateAppearance()
        installButton.updateAppearance()
    }

    private var releaseNotesBackgroundColor: NSColor {
        if themeProvider.currentAppearance.isDark {
            return NSColor(calibratedWhite: 0.16, alpha: 1)
        }

        return NSColor(calibratedWhite: 0.94, alpha: 1)
    }

    private var headerIconTintColor: NSColor {
        if themeProvider.currentAppearance.isDark {
            return NSColor(white: 1, alpha: 0.92)
        }

        return NSColor(white: 0, alpha: 0.92)
    }

    private func loadInitialReleaseNotes() {
        guard let itemDescription = appcastItem.itemDescription, !itemDescription.isEmpty else {
            if appcastItem.releaseNotesURL != nil {
                showReleaseNotesPlaceholder(NSLocalizedString("updates.updateWindow.releaseNotes.loadingPlaceholder", value: "Loading release notes...",
                    comment: "Update window - Release notes loading placeholder"
                ))
            } else {
                showReleaseNotesPlaceholder(NSLocalizedString("updates.updateWindow.releaseNotes.unavailablePlaceholder", value: "No release notes available.",
                    comment: "Update window - Missing release notes placeholder"
                ))
            }
            return
        }

        if shouldRenderReleaseNotesAsPlainText(descriptionFormat: appcastItem.itemDescriptionFormat) {
            loadReleaseNotesHTMLString(plainTextHTML(from: itemDescription), baseURL: nil)
        } else {
            loadReleaseNotesHTMLString(itemDescription, baseURL: nil)
        }
    }

    func showReleaseNotes(_ downloadData: SPUDownloadData) {
        let mimeType = downloadData.mimeType ?? "text/html"
        let encodingName = downloadData.textEncodingName ?? "utf-8"
        let data = downloadData.data as Data

        if shouldRenderReleaseNotesAsPlainText(mimeType: mimeType, url: downloadData.url) {
            let text = string(from: data, encodingName: encodingName) ?? ""
            loadReleaseNotesHTMLString(plainTextHTML(from: text), baseURL: nil)
        } else {
            loadReleaseNotesData(
                data,
                mimeType: mimeType,
                encodingName: encodingName,
                baseURL: downloadData.url.deletingLastPathComponent()
            )
        }
    }

    func showReleaseNotesError(_ error: Error) {
        showReleaseNotesPlaceholder(error.localizedDescription)
    }

    private func showReleaseNotesWebView() {
        releaseNotesWebView.isHidden = false
        releaseNotesPlaceholder.isHidden = true
    }

    private func showReleaseNotesPlaceholder(_ text: String) {
        releaseNotesWebView.isHidden = true
        releaseNotesPlaceholder.isHidden = false
        releaseNotesPlaceholder.stringValue = text
    }

    private func loadReleaseNotesHTMLString(_ htmlString: String, baseURL: URL?) {
        showReleaseNotesWebView()
        prepareReleaseNotesWebContent {
            self.releaseNotesLoadInProgress = true
            self.releaseNotesWebView.loadHTMLString(htmlString, baseURL: baseURL)
        }
    }

    private func loadReleaseNotesData(_ data: Data,
                                      mimeType: String,
                                      encodingName: String,
                                      baseURL: URL) {
        showReleaseNotesWebView()
        prepareReleaseNotesWebContent {
            self.releaseNotesLoadInProgress = true
            self.releaseNotesWebView.load(
                data,
                mimeType: mimeType,
                characterEncodingName: encodingName,
                baseURL: baseURL
            )
        }
    }

    private func prepareReleaseNotesWebContent(_ load: @escaping () -> Void) {
        guard shouldBlockExternalReleaseNoteReferences, !didInstallExternalReferenceBlocker else {
            load()
            return
        }

        let encodedContentRuleList = """
        [
          {"trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
          {
            "trigger": {
              "url-filter": "\(PhiSparkleReleaseNotesResourceSchemeHandler.fontContentRuleURLFilter)"
            },
            "action": { "type": "ignore-previous-rules" }
          }
        ]
        """

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "phi-sparkle-release-notes",
            encodedContentRuleList: encodedContentRuleList
        ) { [weak self] contentRuleList, error in
            Task { @MainActor in
                guard let self else { return }
                if let contentRuleList {
                    self.releaseNotesWebView.configuration.userContentController.add(contentRuleList)
                    self.didInstallExternalReferenceBlocker = true
                } else if let error {
                    AppLogWarn("Sparkle: failed to block external release note references: \(error.localizedDescription)")
                }

                load()
            }
        }
    }

    private var shouldBlockExternalReleaseNoteReferences: Bool {
        appcastItem.signingValidationStatus != .skipped
    }

    private func shouldRenderReleaseNotesAsPlainText(descriptionFormat: String?) -> Bool {
        guard let descriptionFormat = descriptionFormat?.lowercased() else { return false }
        return descriptionFormat == "plain-text" || descriptionFormat == "markdown"
    }

    private func shouldRenderReleaseNotesAsPlainText(mimeType: String, url: URL) -> Bool {
        let normalizedMimeType = mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? mimeType.lowercased()
        let pathExtension = url.pathExtension.lowercased()

        return normalizedMimeType == "text/plain" ||
            normalizedMimeType == "text/markdown" ||
            normalizedMimeType == "text/x-markdown" ||
            pathExtension == "txt" ||
            pathExtension == "md" ||
            pathExtension == "markdown"
    }

    private func string(from data: Data, encodingName: String) -> String? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            let encoding = String.Encoding(rawValue: nsEncoding)
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }

        return String(data: data, encoding: .utf8)
    }

    private func plainTextHTML(from text: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            :root {
              color-scheme: light dark;
            }
            body {
              margin: 36px;
              color: CanvasText;
              font: 16px -apple-system, BlinkMacSystemFont, sans-serif;
              line-height: 1.45;
              background: transparent;
            }
            pre {
              margin: 0;
              white-space: pre-wrap;
              font: inherit;
            }
          </style>
        </head>
        <body><pre>\(escapedHTML(text))</pre></body>
        </html>
        """
    }

    private func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    @objc private func skipButtonClicked() {
        onSkip?()
    }

    @objc private func remindButtonClicked() {
        onDismiss?()
    }

    @objc private func installButtonClicked() {
        onInstall?()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let safety = releaseNotesURLSafety(for: url)
        guard safety.isSafe else {
            AppLogWarn("Sparkle: blocked unsafe release note URL scheme: \(url.scheme ?? "none")")
            decisionHandler(.cancel)
            return
        }

        if navigationAction.navigationType == .linkActivated ||
            (!releaseNotesLoadInProgress && !safety.isAboutBlank) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        releaseNotesLoadInProgress = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        releaseNotesLoadInProgress = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        releaseNotesLoadInProgress = false
    }

    private func releaseNotesURLSafety(for url: URL) -> (isSafe: Bool, isAboutBlank: Bool) {
        let absoluteString = url.absoluteString
        let isAboutBlank = absoluteString == "about:blank" || absoluteString == "about:srcdoc"
        let scheme = url.scheme?.lowercased() ?? ""
        let standardAllowedSchemes: Set<String> = [
            "http",
            "https",
            "macappstore",
            "macappstores",
            "itms-apps",
            "itms-appss"
        ]

        let isSafe = isAboutBlank ||
            standardAllowedSchemes.contains(scheme) ||
            customAllowedReleaseNotesSchemes.contains(scheme)

        return (isSafe, isAboutBlank)
    }

    private var customAllowedReleaseNotesSchemes: Set<String> {
        guard let schemes = Bundle.main.object(forInfoDictionaryKey: "SUAllowedURLSchemes") as? [String] else {
            return []
        }

        return Set(schemes.map { $0.lowercased() }.filter { $0 != "file" })
    }
}

@MainActor
private final class PhiSparkleReleaseNotesResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "phi-resources"
    static let fontContentRuleURLFilter =
        "^phi-resources://fonts/ivy-presto-display-semi-bold[.]otf$"

    private static let fontHost = "fonts"
    private static let fontPath = "/ivy-presto-display-semi-bold.otf"
    private static let fontResourceName = "ivy-presto-display-semi-bold"
    private static let fontResourceExtension = "otf"

    private let bundle: Bundle

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme?.caseInsensitiveCompare(Self.scheme) == .orderedSame,
              requestURL.host?.lowercased() == Self.fontHost,
              requestURL.path == Self.fontPath else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }

        guard let fontURL = bundle.url(
            forResource: Self.fontResourceName,
            withExtension: Self.fontResourceExtension,
            subdirectory: "Fonts"
        ) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let fontData = try Data(contentsOf: fontURL, options: .mappedIfSafe)
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Access-Control-Allow-Origin": "*",
                    "Content-Length": String(fontData.count),
                    "Content-Type": "font/otf"
                ]
            ) else {
                urlSchemeTask.didFailWithError(URLError(.badServerResponse))
                return
            }

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(fontData)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class PhiSparkleUpdateButton: NSButton {
    enum Style {
        case primary
        case secondary

        func backgroundColor(themeProvider: ThemeStateProvider, isHovered: Bool) -> NSColor {
            let appearance = themeProvider.currentAppearance

            switch self {
            case .primary:
                let color = isHovered ? ThemedColor.themeColorOnHover : ThemedColor.themeColor
                return color.resolve(theme: themeProvider.currentTheme, appearance: appearance)
            case .secondary:
                if appearance.isDark {
                    return NSColor(calibratedWhite: isHovered ? 0.30 : 0.24, alpha: 1)
                }

                return NSColor(calibratedWhite: isHovered ? 0.82 : 0.88, alpha: 1)
            }
        }

        var textColor: NSColor {
            switch self {
            case .primary:
                return .white
            case .secondary:
                return .labelColor
            }
        }
    }

    private let style: Style
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateAppearance(animated: true)
        }
    }

    var themeProvider: ThemeStateProvider = ThemeManager.shared {
        didSet {
            updateAppearance()
        }
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 13, weight: .regular)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var title: String {
        didSet {
            updateAppearance()
        }
    }

    override var isEnabled: Bool {
        didSet {
            updateAppearance()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            updateAppearance()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }

        updateHoverStateFromMouseLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHoverStateFromMouseLocation()
    }

    func updateAppearance(animated: Bool = false) {
        let backgroundColor = style.backgroundColor(
            themeProvider: themeProvider,
            isHovered: isEnabled && isHovered
        )

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.12 : 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundColor.cgColor
        }
        CATransaction.commit()

        alphaValue = currentAlphaValue
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: style.textColor
            ]
        )
    }

    private var currentAlphaValue: CGFloat {
        if !isEnabled {
            return 0.55
        }

        return isHighlighted ? 0.82 : 1
    }

    private func updateHoverStateFromMouseLocation() {
        guard let window else { return }

        let mouseLocation = window.mouseLocationOutsideOfEventStream
        let localPoint = convert(mouseLocation, from: nil)
        isHovered = bounds.contains(localPoint)
    }
}

@MainActor
private final class PhiSparkleRootView: NSView {
    var appearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange?()
    }
}

@MainActor
final class PhiSparkleUpdateWindowController: NSWindowController, NSWindowDelegate {
    var onSkip: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onInstall: (() -> Void)?

    var automaticallyDownloadsEnabled: Bool {
        viewController.automaticallyDownloadsEnabled
    }

    private let viewController: PhiSparkleUpdateViewController
    private let activatesApplicationOnShow: Bool
    private var canDismissOnClose = true

    init(appcastItem: SUAppcastItem,
         mode: PhiSparkleUpdateWindowMode,
         automaticDownloadsEnabled: Bool,
         allowsAutomaticUpdates: Bool,
         themeProvider: ThemeStateProvider,
         activatesApplicationOnShow: Bool) {
        viewController = PhiSparkleUpdateViewController(
            appcastItem: appcastItem,
            mode: mode,
            automaticDownloadsEnabled: automaticDownloadsEnabled,
            allowsAutomaticUpdates: allowsAutomaticUpdates,
            themeProvider: themeProvider
        )

        let window = PhiSparkleUpdatePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 588),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentViewController = viewController
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        self.activatesApplicationOnShow = activatesApplicationOnShow

        super.init(window: window)

        window.delegate = self
        viewController.onSkip = { [weak self] in self?.onSkip?() }
        viewController.onDismiss = { [weak self] in self?.onDismiss?() }
        viewController.onInstall = { [weak self] in self?.onInstall?() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        viewController.refreshAppearance()
        window?.center()
        if activatesApplicationOnShow {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(sender)
        } else {
            window?.orderFront(sender)
        }
        window?.invalidateShadow()
    }

    override func close() {
        canDismissOnClose = false
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard canDismissOnClose else { return }
        onDismiss?()
    }

    func showReleaseNotes(_ downloadData: SPUDownloadData) {
        viewController.showReleaseNotes(downloadData)
    }

    func showReleaseNotesError(_ error: Error) {
        viewController.showReleaseNotesError(error)
    }
}

private final class PhiSparkleUpdatePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

enum PhiSparkleUpdateWindowMode {
    case available
    case readyToInstall

    var title: String {
        switch self {
        case .available:
            return NSLocalizedString("updates.updateWindow.availableTitle", value: "A new version of Phi is available",
                comment: "Update window - Title"
            )
        case .readyToInstall:
            return NSLocalizedString("updates.updateWindow.readyToInstallTitle", value: "A new version of Phi is ready to install",
                comment: "Update window - Ready to install title"
            )
        }
    }

    var dismissButtonTitle: String {
        switch self {
        case .available:
            return NSLocalizedString("updates.updateWindow.remindLaterButton", value: "Remind Me Later", comment: "Update window - Remind later button")
        case .readyToInstall:
            return NSLocalizedString("updates.updateWindow.installOnQuitButton", value: "Install on Quit", comment: "Update window - Install downloaded update on quit button")
        }
    }

    var installButtonTitle: String {
        switch self {
        case .available:
            return NSLocalizedString("updates.updateWindow.installUpdateButton", value: "Install Update", comment: "Update window - Install update button")
        case .readyToInstall:
            return NSLocalizedString("updates.updateWindow.installAndRelaunchButton", value: "Install and Relaunch", comment: "Update window - Install downloaded update and relaunch button")
        }
    }
}
#endif
