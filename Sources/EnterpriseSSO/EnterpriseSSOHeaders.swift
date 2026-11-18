// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit

/// The framework half of the Extensible SSO integration.
///
/// The headers the OS extension returns are only useful if the network stack
/// attaches them to its own requests to the IdP origin, which only the framework
/// can do; Chromium calls the same extension from
/// `enterprise_auth::PlatformAuthProviderManager`. The call is optional for the
/// same reason every other new bridge call is: a framework build that predates
/// it must not crash the client (see `PhiChromiumBridgeHeader.h`).
enum EnterpriseSSOBridge {
    private static var bridge: PhiChromiumBridgeProtocol? {
        ChromiumLauncher.sharedInstance().bridge
    }

    /// Whether the running framework build can attach SSO headers.
    static var supportsHeaderInstallation: Bool {
        guard let bridge else { return false }
        return bridge.responds(
            to: #selector(PhiChromiumBridgeProtocol.setEnterpriseSSORequestHeaders(_:forIdPHost:)))
    }

    /// Hands `headers` to the framework for `host`. Returns NO when the framework
    /// build predates the call or refused the values.
    @discardableResult
    static func install(headers: [String: String], host: String) -> Bool {
        guard !headers.isEmpty, supportsHeaderInstallation, let bridge else { return false }
        // Optional protocol member: a framework build that predates it answers nil
        // here, which is the same NO as a refusal.
        return bridge.setEnterpriseSSORequestHeaders?(headers, forIdPHost: host) ?? false
    }
}

/// Asks the device's Extensible SSO extension for Microsoft Entra headers when a
/// tab reaches the IdP, and installs them for the rest of the session's requests
/// to that origin.
///
/// This is the client half of issue #383: on a Mac managed with the Microsoft
/// Enterprise SSO plug-in, Entra's device-authentication hand-off
/// (`device.login.microsoftonline.com` -> `/common/DeviceAuthTls/reprocess`)
/// needs the PRT/device credentials the extension holds. Without them the
/// hand-off becomes a GET on a POST-only endpoint and the sign-in dies with
/// `AADSTS900561`. Chrome, Edge, Firefox and Safari all consult the extension;
/// Phi did not.
///
/// The client cannot attach request headers, so it installs them per IdP host and
/// lets the framework apply them. Until `EnterpriseSSOBridge` reports support
/// this is a no-op that logs once.
final class EnterpriseSSOHeaders {
    static let shared = EnterpriseSSOHeaders()

    private let lock = NSLock()
    private var policy = EnterpriseSSOHeaderRequestPolicy()
    private var inFlightHosts: Set<String> = []
    private var didLogUnsupportedFramework = false
    private var providers: [String: EnterpriseSSOHeaderProvider] = [:]

    private init() {}

    /// Called for every committed tab URL. Cheap: the IdP host check is a set
    /// lookup, and non-IdP navigations return before touching the lock.
    func noteCommittedURL(_ urlString: String?) {
        guard let host = EnterpriseSSOIdentityProvider.microsoftIdentityProviderHost(for: urlString),
              let url = urlString.flatMap(URL.init(string:)) else { return }

        lock.lock()
        let supported = EnterpriseSSOBridge.supportsHeaderInstallation
        if !supported {
            let shouldLog = !didLogUnsupportedFramework
            didLogUnsupportedFramework = true
            lock.unlock()
            if shouldLog {
                AppLogInfo("[EnterpriseSSO] framework build has no SSO header hook; "
                           + "\(host) requests go out without device credentials (issue #383)")
            }
            return
        }
        guard policy.shouldRequest(host: host), !inFlightHosts.contains(host) else {
            lock.unlock()
            return
        }
        inFlightHosts.insert(host)
        lock.unlock()

        requestHeaders(for: url, host: host)
    }

    private func requestHeaders(for url: URL, host: String) {
        let provider = EnterpriseSSOHeaderProvider()
        lock.lock()
        providers[host] = provider
        lock.unlock()

        let windowProvider: (() -> NSWindow?) = {
            NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        }

        let deliver: () -> Void = { [weak self] in
            guard let self else { return }
            provider.requestHeaders(for: url, presentationAnchor: windowProvider) { headers in
                self.finish(host: host, headers: headers)
            }
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private func finish(host: String, headers: [String: String]) {
        let installed = EnterpriseSSOBridge.install(headers: headers, host: host)

        lock.lock()
        if installed || !headers.isEmpty {
            policy.didRequest(host: host)
        } else {
            // Nothing came back: let the next IdP navigation try again instead of
            // waiting out the TTL, which is what a user signing in right after
            // Company Portal finished its own registration needs.
            policy.didFail(host: host)
        }
        inFlightHosts.remove(host)
        providers.removeValue(forKey: host)
        lock.unlock()

        if installed {
            AppLogInfo("[EnterpriseSSO] installed \(headers.count) header(s) for \(host)")
        }
    }
}
