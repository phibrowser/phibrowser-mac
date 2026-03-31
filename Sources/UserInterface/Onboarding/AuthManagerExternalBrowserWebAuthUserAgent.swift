// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import Auth0

private enum AuthManagerBrowserTarget {
    case defaultBrowser
    case safari
}

final class AuthManagerExternalBrowserWebAuthUserAgent: WebAuthUserAgent {

    private let authorizeURL: URL
    private let callback: WebAuthProviderCallback
    private let registerCallbackURLListener: (@escaping (URL) -> Void) -> (() -> Void)
    private let queue = DispatchQueue(label: "com.phi.auth.external-browser-provider")

    private var isFinished = false
    private var unregisterCallbackURLListener: (() -> Void)?

    init(
        authorizeURL: URL,
        callback: @escaping WebAuthProviderCallback,
        registerCallbackURLListener: @escaping (@escaping (URL) -> Void) -> (() -> Void)
    ) {
        self.authorizeURL = authorizeURL
        self.callback = callback
        self.registerCallbackURLListener = registerCallbackURLListener
    }

    func start() {
        unregisterCallbackURLListener = registerCallbackURLListener { callbackURL in
            _ = WebAuthentication.resume(with: callbackURL)
        }

        let target = Self.resolveTarget()
        guard Self.open(authorizeURL, target: target) else {
            WebAuthentication.cancel()
            return
        }
    }

    func finish(with result: WebAuthResult<Void>) {
        let unregister = queue.sync { () -> (() -> Void)? in
            guard !isFinished else { return nil }
            isFinished = true
            let callback = unregisterCallbackURLListener
            unregisterCallbackURLListener = nil
            return callback
        }

        unregister?()
        callback(result)
    }

    private static func resolveTarget() -> AuthManagerBrowserTarget {
        guard let defaultBrowserBundleID = defaultBrowserBundleIdentifier(),
              let appBundleID = Bundle.main.bundleIdentifier else {
            return .defaultBrowser
        }
        return defaultBrowserBundleID == appBundleID ? .safari : .defaultBrowser
    }

    private static func open(_ url: URL, target: AuthManagerBrowserTarget) -> Bool {
        switch target {
        case .defaultBrowser:
            return NSWorkspace.shared.open(url)
        case .safari:
            guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
                return NSWorkspace.shared.open(url)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: safariURL, configuration: configuration)
            return true
        }
    }

    private static func defaultBrowserBundleIdentifier() -> String? {
        guard let probeURL = URL(string: "http://example.com"),
              let appURL = LSCopyDefaultApplicationURLForURL(probeURL as CFURL, .all, nil)?.takeRetainedValue() as URL?,
              let bundle = Bundle(url: appURL) else {
            return nil
        }
        return bundle.bundleIdentifier
    }

}
