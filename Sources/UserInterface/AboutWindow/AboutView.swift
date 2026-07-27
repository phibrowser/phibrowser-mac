// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

struct AboutView: View {
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

    /// Acknowledgements paragraph (English only); three links: Chromium name and two 'open source software' spans.
    private var acknowledgementsAttributedString: AttributedString {
        var result = AttributedString()
        result.append(AttributedString("Phi is made possible by the "))

        var chromiumLink = AttributedString("Chromium")
        chromiumLink.link = Self.chromiumProjectURL
        chromiumLink.underlineStyle = .single
        result.append(chromiumLink)

        result.append(AttributedString(" open source project, Chromium's "))

        var chromiumOSSLink = AttributedString("open source software")
        chromiumOSSLink.link = Self.chromiumSourceURL
        chromiumOSSLink.underlineStyle = .single
        result.append(chromiumOSSLink)

        result.append(AttributedString(", as well as other "))

        var otherOSSLink = AttributedString("open source software")
        otherOSSLink.link = Self.phiCreditsURL
        otherOSSLink.underlineStyle = .single
        result.append(otherOSSLink)

        result.append(AttributedString("."))
        return result
    }

    /// Attributed string for `NSTextView`: applies caption sizing and label color on plain runs; links use link styling from `linkTextAttributes`.
    private var acknowledgementsNSAttributedString: NSAttributedString {
        let converted = NSAttributedString(acknowledgementsAttributedString)
        let mutable = NSMutableAttributedString(attributedString: converted)
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

    var body: some View {
        VStack {
            Spacer(minLength: 10)

            VStack(spacing: 10) {
                // App Icon
                Group {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 58, height: 58)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.accentColor)
                            .frame(width: 48, height: 48)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)

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

            Spacer(minLength: 12)
        }
        .padding(20)
        .frame(width: 290, height: 280)
        .background(Color(NSColor.windowBackgroundColor))
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

    // The sizeThatFits requirement only exists on macOS 13+; macOS 12 falls
    // back to the hosting view's intrinsic sizing.
    @available(macOS 13.0, *)
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
            MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.openTab(url.absoluteString)
            return true
        }
    }
}

#Preview {
    AboutView()
}
