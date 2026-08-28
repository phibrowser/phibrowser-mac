// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Resolves a URL to a Space, mirroring the C++ `phi::PhiURLRouter` in
/// `chrome/browser/phinomenon/phi_url_router.{h,cc}`. Both sides MUST agree
/// on the rule semantics or a URL routed by typing-in-omnibox would diverge
/// from the same URL routed by link click / redirect. `URLRouterTests` pins
/// the Swift semantics (host exact/wildcard/contains, path-prefix boundary,
/// specificity ordering) and is the ONLY automated pinning of the shared
/// semantics — the C++ side has no unit test. When you change a matching
/// rule here, mirror it in the C++ matcher by hand and verify manually;
/// nothing catches drift between the two automatically.
///
/// The matching itself lives in `URLPatternMatcher`, shared with Reader
/// View's site-rule table. This type owns only the Space-specific part:
/// which rules to consider and what to return.
enum URLRouter {

    /// Resolves `url` against `rules`. Returns the `spaceId` of the most
    /// specific matching rule, or nil when nothing matches. Specificity is
    /// (in order): longer `pathPrefix` wins, then the host tier — exact
    /// host beats `*.host` suffix wildcard beats `*needle*` contains —
    /// then lower `sortOrder` wins.
    static func resolve(url: URL, rules: [SpaceURLRule]) -> String? {
        matchingRule(for: url, rules: rules)?.spaceId
    }

    /// Returns the winning rule itself. Callers that need routing policy in
    /// addition to the destination (for example, whether the rule asks before
    /// routing) must use the same specificity decision as `resolve` rather
    /// than looking up a second rule by target Space.
    static func matchingRule(
        for url: URL,
        rules: [SpaceURLRule]
    ) -> SpaceURLRule? {
        // Mirror `PhiURLRouter::Resolve`: Space routing applies to websites
        // only, so non-http(s) URLs (chrome:, file:, data:, view-source:, …)
        // never match — a broad rule must not re-home or prompt on them.
        guard let target = URLPatternMatcher.target(for: url) else { return nil }

        var best: (rule: SpaceURLRule, specificity: (Int, Int, Int))?
        for rule in rules {
            guard URLPatternMatcher.hostMatches(pattern: rule.host,
                                                host: target.host) else { continue }
            guard URLPatternMatcher.pathMatches(prefix: rule.pathPrefix,
                                                path: target.path) else { continue }
            let base = URLPatternMatcher.specificity(host: rule.host,
                                                     pathPrefix: rule.pathPrefix)
            // Negate sortOrder so larger tuple = better rule under tuple
            // comparison.
            let score = (base.0, base.1, -rule.sortOrder)
            if best == nil || score > best!.specificity {
                best = (rule, score)
            }
        }
        return best?.rule
    }
}
