// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The Microsoft Entra ID origins an Apple Extensible SSO payload can claim.
///
/// The profile an MDM installs for the Microsoft Enterprise SSO plug-in lists
/// exactly these URL prefixes for its `Redirect` payload, so asking the OS
/// extension about the same set keeps Phi's answer identical to Chrome's
/// (`chrome/browser/enterprise/platform_auth/extensible_enterprise_sso*`).
/// Whether the device can actually authenticate for a given origin is decided by
/// `ASAuthorizationSingleSignOnProvider.canPerformAuthorization`, never by this
/// list: a Mac with no SSO extension configured answers NO for all of them.
enum EnterpriseSSOIdentityProvider {
    static let microsoftOrigins: [String] = [
        "https://login.microsoftonline.com",
        "https://login.microsoft.com",
        "https://sts.windows.net",
        "https://login.partner.microsoftonline.cn",
        "https://login.chinacloudapi.cn",
        "https://login.microsoftonline.us",
        "https://login-us.microsoftonline.com",
    ]

    /// Hosts of `microsoftOrigins`, used as the key the bridge attaches headers to.
    static let microsoftHosts: Set<String> = Set(microsoftOrigins.compactMap { URL(string: $0)?.host() })

    /// `scheme://host` of `url`, lowercased; nil unless `url` is an http(s) URL
    /// with a host.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else {
            return nil
        }
        return "\(scheme)://\(host)"
    }

    /// The IdP host `url` belongs to, or nil when `url` is not on one of the
    /// Microsoft identity-provider origins.
    static func microsoftIdentityProviderHost(for url: URL) -> String? {
        guard let host = url.host()?.lowercased(), microsoftHosts.contains(host) else {
            return nil
        }
        return host
    }

    /// Same test for the string form a tab carries.
    static func microsoftIdentityProviderHost(for urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return microsoftIdentityProviderHost(for: url)
    }
}

/// Rate limit for asking the OS extension for IdP headers.
///
/// Chromium asks per request because it sits inside the network stack. The
/// client can only install headers for a host, so it asks when a tab first
/// reaches the IdP and again after `ttl`: an Entra sign-in chain issues many
/// requests to the IdP in a row, and re-asking for each of them would both
/// swamp the extension and hand it a different PRT mid-flow.
struct EnterpriseSSOHeaderRequestPolicy {
    let ttl: TimeInterval
    private var lastRequestByHost: [String: Date] = [:]

    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    /// Whether `host` should be asked about now. Does not record the request.
    func shouldRequest(host: String, now: Date = Date()) -> Bool {
        guard let lastRequest = lastRequestByHost[host] else { return true }
        return now.timeIntervalSince(lastRequest) >= ttl
    }

    /// Records that `host` was asked about, so the next request waits for `ttl`.
    mutating func didRequest(host: String, now: Date = Date()) {
        lastRequestByHost[host] = now
    }

    /// Forgets a failed attempt so the next IdP navigation retries immediately.
    mutating func didFail(host: String) {
        lastRequestByHost.removeValue(forKey: host)
    }
}
