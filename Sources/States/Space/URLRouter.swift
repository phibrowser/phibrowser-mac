// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Pure, allocation-light matcher mirroring the C++ `phi::PhiURLRouter` in
/// `chrome/browser/phinomenon/phi_url_router.{h,cc}`. Both sides MUST agree
/// on the rule semantics or a URL routed by typing-in-omnibox would diverge
/// from the same URL routed by link click / redirect. `URLRouterTests` pins
/// the Swift semantics (host exact/wildcard/contains, path-prefix boundary,
/// specificity ordering) and is the ONLY automated pinning of the shared
/// semantics — the C++ side has no unit test. When you change a matching
/// rule here, mirror it in the C++ matcher by hand and verify manually;
/// nothing catches drift between the two automatically.
enum URLRouter {

    /// Resolves `url` against `rules`. Returns the `spaceId` of the most
    /// specific matching rule, or nil when nothing matches. Specificity is
    /// (in order): longer `pathPrefix` wins, then the host tier — exact
    /// host beats `*.host` suffix wildcard beats `*needle*` contains —
    /// then lower `sortOrder` wins.
    static func resolve(url: URL, rules: [SpaceURLRule]) -> String? {
        // Mirror `PhiURLRouter::Resolve`: Space routing applies to websites
        // only, so non-http(s) URLs (chrome:, file:, data:, view-source:, …)
        // never match — a broad rule must not re-home or prompt on them.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        // Use the percent-encoded path so non-ASCII characters survive in
        // their canonical form. GURL.path() on the C++ side returns the
        // same encoded shape, and `LocalStore.URLRuleDraft.init` stores
        // prefixes already encoded — comparing against `url.path` (which
        // Foundation percent-decodes) would silently diverge for any rule
        // containing characters outside `.urlPathAllowed`.
        // Empty path coerces to "/" for prefix matching so a rule with
        // `pathPrefix == nil` still matches a host-only URL like `https://a`.
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedPath ?? ""
        let path = encodedPath.isEmpty ? "/" : encodedPath

        var best: (rule: SpaceURLRule, specificity: (Int, Int, Int))?
        for rule in rules {
            guard hostMatches(rule: rule, urlHost: host) else { continue }
            guard pathMatches(rule: rule, urlPath: path) else { continue }
            let score = specificity(of: rule)
            if best == nil || score > best!.specificity {
                best = (rule, score)
            }
        }
        return best?.rule.spaceId
    }

    private static func hostMatches(rule: SpaceURLRule, urlHost: String) -> Bool {
        let ruleHost = rule.host.lowercased()
        // Contains form ("*needle*") must be detected before the suffix
        // form: a needle starting with "." (e.g. "*.git.*") also carries
        // the "*." prefix. Mirrors the flag compilation in
        // PhiChromiumBridge.mm's setSpaceRoutingTable.
        if ruleHost.count > 2, ruleHost.hasPrefix("*"), ruleHost.hasSuffix("*") {
            let needle = ruleHost.dropFirst().dropLast()
            return urlHost.contains(needle)
        }
        if !ruleHost.hasPrefix("*.") {
            return ruleHost == urlHost
        }
        let bare = String(ruleHost.dropFirst(2))
        guard !bare.isEmpty else { return false }
        if urlHost == bare { return true }
        // A wildcard "*.foo.com" matches sub-host "x.foo.com" but not
        // "barfoo.com" — require a dot before the bare suffix.
        guard urlHost.count > bare.count + 1 else { return false }
        let suffixStart = urlHost.index(urlHost.endIndex, offsetBy: -(bare.count + 1))
        return urlHost[suffixStart] == "." &&
               urlHost[urlHost.index(after: suffixStart)...] == bare
    }

    private static func pathMatches(rule: SpaceURLRule, urlPath: String) -> Bool {
        guard let prefix = rule.pathPrefix, !prefix.isEmpty else { return true }
        guard urlPath.hasPrefix(prefix) else { return false }
        // Require a "/" boundary so "/foo" doesn't match "/foobar".
        return urlPath.count == prefix.count ||
               urlPath[urlPath.index(urlPath.startIndex, offsetBy: prefix.count)] == "/"
    }

    private static func specificity(of rule: SpaceURLRule) -> (Int, Int, Int) {
        let pathLength = rule.pathPrefix?.count ?? 0
        // Host tiers mirror the C++ Specificity(): exact (2) beats
        // "*.suffix" (1) beats "*contains*" (0).
        let host = rule.host
        let hostTier: Int
        if host.count > 2, host.hasPrefix("*"), host.hasSuffix("*") {
            hostTier = 0
        } else if host.hasPrefix("*.") {
            hostTier = 1
        } else {
            hostTier = 2
        }
        // Negate sortOrder so larger tuple = better rule under tuple comparison.
        return (pathLength, hostTier, -rule.sortOrder)
    }
}
