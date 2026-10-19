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
/// specificity ordering). The C++ tests pin the same tie-break fixtures.
/// When changing a matching rule, update both matchers and their fixtures;
/// nothing catches drift between the two automatically.
///
/// The matching itself lives in `URLPatternMatcher`, shared with Reader
/// View's site-rule table. This type owns only the Space-specific part:
/// which rules to consider and what to return.
///
/// App rules (`SpaceRoutingRule.sourceAppBundleId != nil`, host
/// `app:<bundle id>`) are Swift-only: the URL matcher skips them explicitly,
/// they are never pushed to Chromium, and only `matchingSourceAppRule`
/// evaluates them, for external opens. See docs/url-rules.md.
enum URLRouter {

    /// One rule's comparison inputs — the three things the C++
    /// `IsMoreSpecific` (`phi_url_router.cc`) reads off `PhiURLRouter::Rule`.
    /// Internal, not private: `resolve` only returns a spaceId, so CASE R-6(b)
    /// (two rules sharing ONE target Space, decided by `ruleId`) can only be
    /// pinned by calling the comparator itself.
    struct Candidate {
        let specificity: (Int, Int, Int)
        let tieBreakKey: String
        let ruleId: String
    }

    /// Strict total order over rules. Returns true when `a` should beat `b`.
    /// Line-for-line mirror of `IsMoreSpecific` in `phi_url_router.cc` — keep
    /// the two in one commit (design §9.2 / R-M3-4a-4).
    static func isMoreSpecific(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.specificity != b.specificity { return a.specificity > b.specificity }
        // All three components tie. Decide on the account-level key so two
        // devices reach the same answer. Empty keys sort last, and the final
        // ruleId clause keeps the order total even then — NEVER fall back to
        // the target spaceId: an equal tieBreakKey already implies an equal
        // target, so that clause would be false in both directions and the
        // order would degenerate to "first one encountered" (R-M3-4a-43).
        if a.tieBreakKey.isEmpty != b.tieBreakKey.isEmpty { return b.tieBreakKey.isEmpty }
        if a.tieBreakKey != b.tieBreakKey { return a.tieBreakKey < b.tieBreakKey }
        return a.ruleId < b.ruleId
    }


    /// Resolves `url` against `rules`. Returns the `spaceId` of the most
    /// specific matching rule, or nil when nothing matches. Specificity is
    /// (in order): longer `pathPrefix` wins, then the host tier — exact
    /// host beats `*.host` suffix wildcard beats `*needle*` contains —
    /// then lower `sortOrder` wins.
    static func resolve(url: URL, rules: [SpaceRoutingRule]) -> String? {
        matchingRule(for: url, rules: rules)?.spaceId
    }

    static func resolve(url: URL, rules: [SpaceRoutingRule],
                        tieBreakKey: (SpaceRoutingRule) -> String,
                        ruleId: (SpaceRoutingRule) -> String) -> String? {
        matchingRule(for: url, rules: rules, tieBreakKey: tieBreakKey, ruleId: ruleId)?.spaceId
    }

    /// Returns the winning rule itself. Callers that need routing policy in
    /// addition to the destination (for example, whether the rule asks before
    /// routing) must use the same specificity decision as `resolve` rather
    /// than looking up a second rule by target Space.
    static func matchingRule(
        for url: URL,
        rules: [SpaceRoutingRule],
        tieBreakKey: (SpaceRoutingRule) -> String = {
            SpaceManager.shared.ruleTieBreakKey(forTargetSpaceId: $0.spaceId)
        },
        ruleId: (SpaceRoutingRule) -> String = { $0.syncId ?? $0.id }
    ) -> SpaceRoutingRule? {
        // Mirror `PhiURLRouter::Resolve`: Space routing applies to websites
        // only, so non-http(s) URLs (chrome:, file:, data:, view-source:, …)
        // never match — a broad rule must not re-home or prompt on them.
        guard let target = URLPatternMatcher.target(for: url) else { return nil }

        var best: (rule: SpaceRoutingRule, candidate: Candidate)?
        for rule in rules {
            // App rules match a sender application, never a URL.
            guard rule.sourceAppBundleId == nil else { continue }
            guard URLPatternMatcher.hostMatches(pattern: rule.host,
                                                host: target.host) else { continue }
            guard URLPatternMatcher.pathMatches(prefix: rule.pathPrefix,
                                                path: target.path) else { continue }
            let base = URLPatternMatcher.specificity(host: rule.host,
                                                     pathPrefix: rule.pathPrefix)
            // Negate sortOrder so larger tuple = better rule under tuple
            // comparison.
            let score = (base.0, base.1, -rule.sortOrder)
            let candidate = Candidate(specificity: score, tieBreakKey: tieBreakKey(rule), ruleId: ruleId(rule))
            if best == nil || isMoreSpecific(candidate, best!.candidate) {
                best = (rule, candidate)
            }
        }
        return best?.rule
    }

    /// Returns the App rule for an external open sent by `bundleId`, or nil.
    /// Bundle ids compare case-insensitively. Soft-deleted rules never match.
    /// Several matching rules are ordered by lower `sortOrder`, then by the
    /// same account-level tie-break `isMoreSpecific` applies to URL rules.
    static func matchingSourceAppRule(
        bundleId: String,
        rules: [SpaceRoutingRule],
        tieBreakKey: (SpaceRoutingRule) -> String = {
            SpaceManager.shared.ruleTieBreakKey(forTargetSpaceId: $0.spaceId)
        },
        ruleId: (SpaceRoutingRule) -> String = { $0.syncId ?? $0.id }
    ) -> SpaceRoutingRule? {
        let wanted = bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        var best: (rule: SpaceRoutingRule, candidate: Candidate)?
        for rule in rules where rule.deletedDate == nil && rule.sourceAppBundleId == wanted {
            // Host and path components are equal for every App rule, so only
            // the negated sortOrder and the final keys decide.
            let candidate = Candidate(specificity: (0, 0, -rule.sortOrder),
                                      tieBreakKey: tieBreakKey(rule), ruleId: ruleId(rule))
            if best == nil || isMoreSpecific(candidate, best!.candidate) {
                best = (rule, candidate)
            }
        }
        return best?.rule
    }
}
