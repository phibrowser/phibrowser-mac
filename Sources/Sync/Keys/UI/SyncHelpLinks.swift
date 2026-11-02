import AppKit
import Foundation

/// Help Center articles linked from the sync setup pages.
///
/// The Help Center serves English at `/help/...` and each translated UI
/// language at `/help/<locale>/...`, using the same locale codes as
/// `SupportedAppLanguage`.
enum SyncHelpLinks {
    private static let helpRoot = "https://phibrowser.com/help/"

    /// The "Forgot your recovery code?" article, in the language Phi's UI is
    /// currently running in.
    static func forgotRecoveryCodeURL(
        for language: SupportedAppLanguage = PhiPreferences.GeneralSettings.activeProcessAppLanguage()
    ) -> URL {
        URL(string: helpRoot + localePathPrefix(for: language) + "sync/#forgot-your-recovery-code")!
    }

    /// Opens the article in the default browser. The sync setup window is an
    /// app-modal panel, so a Phi tab opened behind it could not be read or
    /// used until setup is closed.
    static func openForgotRecoveryCode() {
        NSWorkspace.shared.open(forgotRecoveryCodeURL())
    }

    private static func localePathPrefix(for language: SupportedAppLanguage) -> String {
        switch language {
        case .english:
            return ""
        case .simplifiedChinese, .traditionalChinese, .japanese, .french,
             .german, .dutch, .spanish, .korean:
            return language.rawValue + "/"
        }
    }
}
