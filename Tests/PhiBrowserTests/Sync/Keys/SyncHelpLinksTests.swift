import XCTest
@testable import Phi

/// The "Forgot your recovery code?" Help link (docs/sync.md, recovery code pages): English uses the
/// unprefixed Help path, every other UI language uses its own locale code in the path.
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
}
