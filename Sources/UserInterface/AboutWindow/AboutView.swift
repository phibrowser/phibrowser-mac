// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme
    static let contentSize = NSSize(width: 290, height: 392)

    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                         Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Phi"

    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"

    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    private static let chromiumInfoKey = "Chromium version"
    private static let frameworkShortVersionKey = "CFBundleShortVersionString"

    /// Chromium project home — linked from the first 'Chromium' in acknowledgements.
    private static let chromiumProjectURL = URL(string: "https://www.chromium.org/Home/")!
    /// Chromium source tree — linked from 'open source software' after 'Chromium's'.
    private static let chromiumSourceURL = URL(string: "chrome://credits")!
    /// Third-party credits page shipped with the app (`Resources/credits.html`, Copy Bundle Resources).
    private static let phiCreditsURL: URL = {
        guard let url = Bundle.main.url(forResource: "credits", withExtension: "html") else {
            assertionFailure("About: credits.html missing from app bundle (Copy Bundle Resources)")
            return URL(string: "https://www.chromium.org/developers/credits/")!
        }
        return url
    }()

    private static let acknowledgementsLayoutWidth: CGFloat = 250
    private static let chromiumProjectLinkMarker = "__PHI_CHROMIUM_PROJECT_LINK__"
    private static let chromiumSourceLinkMarker = "__PHI_CHROMIUM_SOURCE_LINK__"
    private static let otherOpenSourceLinkMarker = "__PHI_OTHER_OPEN_SOURCE_LINK__"

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var chromiumVersion: String {
        #if DEBUG
        if let version = Self.chromiumVersionFromFramework() {
            return version
        }
        #endif

        if let version = Bundle.main.object(forInfoDictionaryKey: Self.chromiumInfoKey) as? String,
           !version.isEmpty {
            return version
        }

        return "Unknown"
    }

    private static func chromiumVersionFromFramework() -> String? {
        let frameworksURL = Bundle.main.privateFrameworksURL ??
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
        let infoPlistURL = frameworksURL.appendingPathComponent(
            "Phi Framework.framework/Versions/Current/Resources/Info.plist"
        )

        guard let info = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
              let version = info[frameworkShortVersionKey] as? String,
              !version.isEmpty else {
            return nil
        }

        return version
    }

    /// Attributed string for `NSTextView`: applies caption sizing and label color on plain runs; links use link styling from `linkTextAttributes`.
    private var acknowledgementsNSAttributedString: NSAttributedString {
        let format = NSLocalizedString(
            "about.acknowledgements.text",
            value: "Phi is made possible by the %1$@ open source project, Chromium's %2$@, as well as other %3$@.",
            comment: "About window - Acknowledgements sentence; the three placeholders are, in order, the Chromium project name link, Chromium's open source software link, and other open source software link"
        )
        let title = String(
            format: format,
            Self.chromiumProjectLinkMarker,
            Self.chromiumSourceLinkMarker,
            Self.otherOpenSourceLinkMarker
        )
        let mutable = NSMutableAttributedString(string: title)
        Self.replaceLinkMarker(
            in: mutable,
            marker: Self.chromiumProjectLinkMarker,
            title: NSLocalizedString(
                "about.acknowledgements.chromiumProjectLink",
                value: "Chromium",
                comment: "About window - Link text to the Chromium project home"
            ),
            url: Self.chromiumProjectURL
        )
        Self.replaceLinkMarker(
            in: mutable,
            marker: Self.chromiumSourceLinkMarker,
            title: NSLocalizedString(
                "about.acknowledgements.chromiumSourceLink",
                value: "open source software",
                comment: "About window - Link text to Chromium's open source software credits"
            ),
            url: Self.chromiumSourceURL
        )
        Self.replaceLinkMarker(
            in: mutable,
            marker: Self.otherOpenSourceLinkMarker,
            title: NSLocalizedString(
                "about.acknowledgements.otherOpenSourceLink",
                value: "open source software",
                comment: "About window - Link text to the browser's other open source software credits"
            ),
            url: Self.phiCreditsURL
        )
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let labelColor = NSColor.labelColor
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttributes([.font: font, .foregroundColor: labelColor], range: fullRange)
        mutable.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            mutable.removeAttribute(.foregroundColor, range: range)
            mutable.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }
        return mutable
    }

    private static func replaceLinkMarker(
        in attributedString: NSMutableAttributedString,
        marker: String,
        title: String,
        url: URL
    ) {
        let markerRange = (attributedString.string as NSString).range(of: marker)
        guard markerRange.location != NSNotFound else { return }

        attributedString.replaceCharacters(in: markerRange, with: title)
        attributedString.addAttributes(
            [
                .link: url,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand
            ],
            range: NSRange(location: markerRange.location, length: (title as NSString).length)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            VStack(spacing: 18) {
                AboutConchView(mapping: selectedMapping)
                    .frame(width: 112, height: 120)
                    .padding(.bottom, 10)
                    .accessibilityLabel(Text(NSLocalizedString(
                        "about.conch.accessibilityLabel",
                        value: "Interactive 3D conch",
                        comment: "About window - Accessible name of the draggable conch illustration"
                    )))
                    .help(NSLocalizedString(
                        "about.conch.dragHint",
                        value: "Drag to rotate the conch",
                        comment: "About window - Tooltip explaining how to interact with the conch"
                    ))

                Text(appName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                VStack(spacing: 2) {
                    Text(String(format: NSLocalizedString("about.versionLabel", value: "Version %@ (%@)", comment: "About window - App version and build number label"), appVersion, buildNumber))
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.labelColor))

                    Text(String(format: NSLocalizedString("about.chromiumVersionLabel", value: "Chromium Engine Version %@", comment: "About window - Chromium engine version label"), chromiumVersion))
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.labelColor))
                }

                VStack(spacing: 8) {
                    Text(String(format: NSLocalizedString("about.copyrightNotice", value: "© %d Phinomenon. All rights reserved.", comment: "About window - Copyright notice at bottom"), currentYear))
                        .font(.caption)
                        .foregroundColor(Color(NSColor.labelColor))
                        .padding(.top, 5)

                    AboutAcknowledgementsTextView(
                        attributedString: acknowledgementsNSAttributedString,
                        layoutWidth: Self.acknowledgementsLayoutWidth
                    )
                    .frame(maxWidth: Self.acknowledgementsLayoutWidth)
                }
            }

            Spacer(minLength: 42)
        }
        .padding(.horizontal, 20)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var selectedMapping: AboutConchMapping {
        colorScheme == .dark ? .dark : .light
    }
}

private struct AboutConchMapping: Equatable {
    var shadows: Double
    var midtones: Double
    var highlights: Double
    var coverage: Double = 256

    static let light = Self(shadows: 1, midtones: 0.696387993092399, highlights: 0.4919679985226069, coverage: 512)
    static let dark = Self(shadows: 0.105127427184466, midtones: 0.5108214383518463, highlights: 0.7292919779196909, coverage: 512)
}

/// Interactive logo using the existing multi-angle conch frames.
private struct AboutConchView: NSViewControllerRepresentable {
    let mapping: AboutConchMapping

    func makeNSViewController(context: Context) -> AboutConchViewController {
        let controller = AboutConchViewController()
        controller.updateMapping(mapping)
        return controller
    }

    func updateNSViewController(_ controller: AboutConchViewController, context: Context) {
        controller.updateMapping(mapping)
    }

    static func dismantleNSViewController(_ controller: AboutConchViewController, coordinator: ()) {
        controller.tearDown()
    }
}

private final class AboutConchViewController: ConchFrameAnimationBaseViewController {
    private var mapping = AboutConchMapping.light
    override var imageNamagePrefix: String { "setting_" }
    override var usesTransparentBackground: Bool { true }
    override var transparentBackgroundGain: CGFloat { mapping.coverage }
    override var gradientStartColor: NSColor { gray(mapping.shadows) }
    override var gradientMidtoneColor: NSColor? { gray(mapping.midtones) }

    private func gray(_ value: Double) -> NSColor {
        NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
    }

    func updateMapping(_ mapping: AboutConchMapping) {
        guard self.mapping != mapping else { return }
        self.mapping = mapping
        guard isViewLoaded else { return }
        themChanged(h: 0, s: 0, b: mapping.highlights, refreshMapping: true)
    }

    override func loadView() {
        view = AboutConchInteractionView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        // Crop the empty source margins so the shell fills the logo's hit area.
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 108),
            imageView.heightAnchor.constraint(equalToConstant: 171)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        themChanged(h: 0, s: 0, b: mapping.highlights, refreshMapping: true)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        NSCursor.openHand.set()
    }
}

private final class AboutConchInteractionView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // Keep the logo draggable, including the decorative image subview.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

/// Read-only multi-line text with clickable URLs, underline on links, and pointing-hand cursor over links (About panel acknowledgements).
private struct AboutAcknowledgementsTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let layoutWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.alignment = .center
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: layoutWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: layoutWidth, height: 0)
        textView.maxSize = NSSize(width: layoutWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.autoresizingMask = []
        textView.linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
            .foregroundColor: NSColor.linkColor
        ]
        textView.textStorage?.setAttributedString(attributedString)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        textView.textStorage?.setAttributedString(attributedString)
        textView.textContainer?.containerSize = NSSize(width: layoutWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.alignment = .center
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width.map { min($0, layoutWidth) } ?? layoutWidth
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return CGSize(width: width, height: 44)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = textView.textContainerInset
        let height = ceil(used.height + inset.height * 2 + 2)
        return CGSize(width: width, height: max(height, 22))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            let url: URL?
            if let u = link as? URL {
                url = u
            } else if let s = link as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            guard let url else {
                return false
            }
//            NSWorkspace.shared.open(url)
            SpaceSessionControllersManager.shared.activeWindowController?.browserState.openTab(url.absoluteString)
            return true
        }
    }
}

#Preview {
    AboutView()
}
