import XCTest
@testable import Phi

/// The "Forgot your recovery code?" Help link (docs/sync.md, recovery code pages): English uses the
/// unprefixed Help path, every other UI language uses its own locale code in the path, and the
/// article never opens in Phi itself while the app-modal setup window is up.
final class SyncHelpLinksTests: XCTestCase {
    func testEnglishUsesUnprefixedHelpPath() {
        XCTAssertEqual(SyncHelpLinks.forgotRecoveryCodeURL(for: .english).absoluteString,
                       "https://phibrowser.com/help/sync/#forgot-your-recovery-code")
    }

    func testTranslatedLanguagesUseLocalePath() {
        let expected: [SupportedAppLanguage: String] = [
            .german: "de", .spanish: "es", .french: "fr", .japanese: "ja", .korean: "ko",
            .dutch: "nl", .simplifiedChinese: "zh-Hans", .traditionalChinese: "zh-Hant",
        ]
        XCTAssertEqual(Set(expected.keys).union([.english]), Set(SupportedAppLanguage.allCases))
        for (language, locale) in expected {
            XCTAssertEqual(SyncHelpLinks.forgotRecoveryCodeURL(for: language).absoluteString,
                           "https://phibrowser.com/help/\(locale)/sync/#forgot-your-recovery-code",
                           "\(language)")
        }
    }

    // MARK: Target

    func testAnotherDefaultBrowserReceivesTheArticle() {
        XCTAssertEqual(SyncHelpLinks.target(defaultBrowserBundleIdentifier: "com.apple.Safari",
                                            appBundleIdentifier: "com.phibrowser.Mac"),
                       .defaultBrowser)
        XCTAssertEqual(SyncHelpLinks.target(defaultBrowserBundleIdentifier: "com.google.Chrome",
                                            appBundleIdentifier: "com.phibrowser.canary.Mac"),
                       .defaultBrowser)
    }

    func testAnotherPhiBuildCountsAsAnotherBrowser() {
        // Stable Phi as the default browser while Canary runs setup: the tab opens in a
        // different process, not behind this app's modal window.
        XCTAssertEqual(SyncHelpLinks.target(defaultBrowserBundleIdentifier: "com.phibrowser.Mac",
                                            appBundleIdentifier: "com.phibrowser.canary.Mac"),
                       .defaultBrowser)
    }

    func testPhiAsDefaultBrowserSendsTheArticleToSafari() {
        XCTAssertEqual(SyncHelpLinks.target(defaultBrowserBundleIdentifier: "com.phibrowser.Mac",
                                            appBundleIdentifier: "com.phibrowser.Mac"),
                       .safari)
        XCTAssertEqual(SyncHelpLinks.target(defaultBrowserBundleIdentifier: "com.phibrowser.canary.Mac",
                                            appBundleIdentifier: "com.phibrowser.canary.Mac"),
                       .safari)
    }

    func testUnknownDefaultBrowserSendsTheArticleToSafari() {
        XCTAssertEqual(SyncHelpLinks.target(defaultBrowserBundleIdentifier: nil,
                                            appBundleIdentifier: "com.phibrowser.Mac"),
                       .safari)
        XCTAssertEqual(SyncHelpLinks.target(defaultBrowserBundleIdentifier: "com.apple.Safari",
                                            appBundleIdentifier: nil),
                       .safari)
    }
}
