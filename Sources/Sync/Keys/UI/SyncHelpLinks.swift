import AppKit
import Foundation

/// Help Center articles linked from the sync setup pages.
///
/// The Help Center serves English at `/help/...` and each translated UI
/// language at `/help/<locale>/...`, using the same locale codes as
/// `SupportedAppLanguage`.
enum SyncHelpLinks {
    private static let helpRoot = "https://phibrowser.com/help/"

    /// Where an article opens.
    ///
    /// The sync setup window parks the main run loop in `NSApp.runModal(for:)`
    /// (`AppModalPairingHost.present`), so a Phi tab opened while setup is up
    /// sits behind the modal window and cannot be read or used until setup is
    /// closed. When Phi itself is the default browser, handing the URL to the
    /// system would do exactly that, so the article goes to Safari instead,
    /// the way `AuthManagerExternalBrowserWebAuthUserAgent` sends sign-in to
    /// Safari for the same reason.
    enum Target: Equatable {
        /// The system default browser, which is not this app.
        case defaultBrowser
        /// Safari, because this app is the default browser or the default
        /// browser could not be determined.
        case safari
    }

    /// The "Forgot your recovery code?" article, in the language Phi's UI is
    /// currently running in.
    static func forgotRecoveryCodeURL(
        for language: SupportedAppLanguage = PhiPreferences.GeneralSettings.activeProcessAppLanguage()
    ) -> URL {
        URL(string: helpRoot + localePathPrefix(for: language) + "sync/#forgot-your-recovery-code")!
    }

    /// Opens the article somewhere the user can read it while the setup
    /// window stays open.
    static func openForgotRecoveryCode() {
        open(forgotRecoveryCodeURL(), target: target())
    }

    /// The anchor of the "Start over without the old data" section. Provisional until the
    /// Help Center article is rewritten; change it here only.
    static let startOverAnchor = "start-over-without-the-old-data"

    /// The "Start over without the old data" article, in the language Phi's UI is currently
    /// running in, under the same locale rule as `forgotRecoveryCodeURL`.
    static func startOverURL(
        for language: SupportedAppLanguage = PhiPreferences.GeneralSettings.activeProcessAppLanguage()
    ) -> URL {
        URL(string: helpRoot + localePathPrefix(for: language) + "sync/#" + startOverAnchor)!
    }

    /// Opens the start over article where it can be read while the setup window stays open.
    static func openStartOver() {
        open(startOverURL(), target: target())
    }

    /// `.defaultBrowser` only when web links are handled by an application
    /// other than this one. When the default browser is this app, or cannot
    /// be determined, the article must not land behind the modal setup
    /// window, so the target is `.safari`.
    static func target(
        defaultBrowserBundleIdentifier: String? = defaultBrowserBundleIdentifier(),
        appBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Target {
        if let defaultBrowserBundleIdentifier, let appBundleIdentifier,
           defaultBrowserBundleIdentifier != appBundleIdentifier {
            return .defaultBrowser
        }
        return .safari
    }

    /// Hands the URL to the target application. Falls back to the default
    /// browser when Safari cannot be located, which does not happen on a
    /// stock macOS install.
    @discardableResult
    static func open(_ url: URL, target: Target) -> Bool {
        switch target {
        case .defaultBrowser:
            return NSWorkspace.shared.open(url)
        case .safari:
            guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
                return NSWorkspace.shared.open(url)
            }
            NSWorkspace.shared.open([url], withApplicationAt: safariURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
    }

    /// The bundle identifier of the application macOS currently opens web
    /// links with, or nil when it cannot be determined.
    static func defaultBrowserBundleIdentifier() -> String? {
        guard let probeURL = URL(string: helpRoot),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else {
            return nil
        }
        return Bundle(url: appURL)?.bundleIdentifier
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
