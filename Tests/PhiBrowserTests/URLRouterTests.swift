// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import SwiftData
@testable import Phi

/// Pins the Swift-side URL routing semantics that `URLRouter` shares with the
/// C++ `phi::PhiURLRouter`. When a matching rule changes here, mirror it in
/// the C++ unit test by hand — there is no shared cross-language vector.
@MainActor
final class URLRouterTests: XCTestCase {

    // SpaceURLRule is a SwiftData @Model; host it in an in-memory store so the
    // rows behave exactly as the ones `URLRouter` reads in production.
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([SpaceURLRule.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private func rule(space: String,
                      host: String,
                      path: String? = nil,
                      sortOrder: Int = 0) -> SpaceURLRule {
        let r = SpaceURLRule(
            spaceId: space,
            host: host,
            pathPrefix: path,
            sortOrder: sortOrder
        )
        context.insert(r)
        return r
    }

    private func resolve(_ urlString: String, _ rules: [SpaceURLRule]) -> String? {
        URLRouter.resolve(url: URL(string: urlString)!, rules: rules)
    }

    // MARK: - Host matching

    func testExactHostMatches() {
        let rules = [rule(space: "work", host: "github.com")]
        XCTAssertEqual(resolve("https://github.com/anything/here", rules), "work")
    }

    func testExactHostRejectsDifferentHost() {
        let rules = [rule(space: "work", host: "github.com")]
        XCTAssertNil(resolve("https://gitlab.com/x", rules))
    }

    func testExactHostRejectsSubdomain() {
        let rules = [rule(space: "work", host: "github.com")]
        XCTAssertNil(resolve("https://www.github.com/x", rules))
    }

    func testHostMatchIsCaseInsensitive() {
        let rules = [rule(space: "work", host: "GitHub.com")]
        XCTAssertEqual(resolve("https://GITHUB.COM/x", rules), "work")
    }

    func testWildcardMatchesSubdomain() {
        let rules = [rule(space: "design", host: "*.figma.com")]
        XCTAssertEqual(resolve("https://board.figma.com/f/abc", rules), "design")
    }

    func testWildcardMatchesBareDomain() {
        let rules = [rule(space: "design", host: "*.figma.com")]
        XCTAssertEqual(resolve("https://figma.com/", rules), "design")
    }

    func testWildcardRejectsSuffixImpostor() {
        // "notfigma.com" ends with "figma.com" but has no dot boundary.
        let rules = [rule(space: "design", host: "*.figma.com")]
        XCTAssertNil(resolve("https://notfigma.com/x", rules))
    }

    func testContainsMatchesSubstringAnywhere() {
        let rules = [rule(space: "code", host: "*git*")]
        XCTAssertEqual(resolve("https://github.com/x", rules), "code")
        XCTAssertEqual(resolve("https://gitlab.io/y", rules), "code")
        XCTAssertEqual(resolve("https://my.gitea.dev/z", rules), "code")
    }

    func testContainsRejectsHostWithoutSubstring() {
        let rules = [rule(space: "code", host: "*git*")]
        XCTAssertNil(resolve("https://example.com/git", rules))
    }

    func testContainsWithLeadingDotNeedleIsNotParsedAsWildcard() {
        // "*.git.*" starts with "*." but is the CONTAINS form (needle
        // ".git.") — the contains check must run before the suffix check,
        // mirroring PhiChromiumBridge.mm and the C++ HostMatches.
        let rules = [rule(space: "code", host: "*.git.*")]
        XCTAssertEqual(resolve("https://x.git.io/p", rules), "code")
        // "git.io" lacks the leading dot of the needle.
        XCTAssertNil(resolve("https://git.io/p", rules))
    }

    // MARK: - Path-prefix matching

    func testPathPrefixMatchesExactPath() {
        let rules = [rule(space: "docs", host: "a.com", path: "/foo")]
        XCTAssertEqual(resolve("https://a.com/foo", rules), "docs")
    }

    func testPathPrefixMatchesSubpath() {
        let rules = [rule(space: "docs", host: "a.com", path: "/foo")]
        XCTAssertEqual(resolve("https://a.com/foo/bar", rules), "docs")
    }

    func testPathPrefixRejectsNonBoundaryMatch() {
        // "/foo" must not match "/foobar".
        let rules = [rule(space: "docs", host: "a.com", path: "/foo")]
        XCTAssertNil(resolve("https://a.com/foobar", rules))
    }

    func testNilPathMatchesAnyPath() {
        let rules = [rule(space: "docs", host: "a.com", path: nil)]
        XCTAssertEqual(resolve("https://a.com/deep/nested/page", rules), "docs")
    }

    func testNilPathMatchesHostOnlyURL() {
        // Host-only URL has an empty percent-encoded path; the router coerces
        // it to "/" so a nil-prefix (any-path) rule still matches.
        let rules = [rule(space: "docs", host: "a.com", path: nil)]
        XCTAssertEqual(resolve("https://a.com", rules), "docs")
    }

    // MARK: - Specificity ordering

    func testLongerPathPrefixWins() {
        let rules = [
            rule(space: "short", host: "h.com", path: "/a"),
            rule(space: "long", host: "h.com", path: "/a/b"),
        ]
        XCTAssertEqual(resolve("https://h.com/a/b/c", rules), "long")
    }

    func testExactHostBeatsWildcard() {
        let rules = [
            rule(space: "wild", host: "*.h.com"),
            rule(space: "exact", host: "x.h.com"),
        ]
        XCTAssertEqual(resolve("https://x.h.com/p", rules), "exact")
    }

    func testWildcardBeatsContains() {
        let rules = [
            rule(space: "contains", host: "*h.com*"),
            rule(space: "wild", host: "*.h.com"),
        ]
        XCTAssertEqual(resolve("https://x.h.com/p", rules), "wild")
    }

    func testExactHostBeatsContains() {
        let rules = [
            rule(space: "contains", host: "*h.com*"),
            rule(space: "exact", host: "h.com"),
        ]
        XCTAssertEqual(resolve("https://h.com/p", rules), "exact")
    }

    func testLowerSortOrderWinsOnSpecificityTie() {
        let rules = [
            rule(space: "first", host: "h.com", sortOrder: 0),
            rule(space: "second", host: "h.com", sortOrder: 1),
        ]
        XCTAssertEqual(resolve("https://h.com/p", rules), "first")
    }

    func testURLWithoutHostReturnsNil() {
        let rules = [rule(space: "work", host: "h.com")]
        XCTAssertNil(URLRouter.resolve(url: URL(string: "about:blank")!, rules: rules))
    }

    func testNonHTTPSchemesAreNotRouted() {
        // A broad "*contains*" rule would otherwise match the host of a
        // privileged/local URL (chrome://settings has host "settings"); the
        // scheme gate must keep Space routing to websites only. Mirrors
        // `PhiURLRouter::Resolve`'s SchemeIsHTTPOrHTTPS guard.
        let rules = [rule(space: "work", host: "*settings*")]
        XCTAssertEqual(resolve("https://settings.example.com/", rules), "work")
        XCTAssertNil(resolve("chrome://settings", rules))
        XCTAssertNil(resolve("file://settings/x", rules))
    }

    func testEmptyRuleSetReturnsNil() {
        XCTAssertNil(resolve("https://h.com/p", []))
    }

    // MARK: - normalizedPathPrefix (issue #2: bare "/" must not be inert)

    func testNormalizeBareSlashBecomesNil() {
        XCTAssertNil(LocalStore.normalizedPathPrefix("/"))
    }

    func testNormalizeMultipleSlashesBecomesNil() {
        XCTAssertNil(LocalStore.normalizedPathPrefix("///"))
    }

    func testNormalizeEmptyAndWhitespaceBecomeNil() {
        XCTAssertNil(LocalStore.normalizedPathPrefix(""))
        XCTAssertNil(LocalStore.normalizedPathPrefix("   "))
        XCTAssertNil(LocalStore.normalizedPathPrefix(nil))
    }

    func testNormalizeStripsTrailingSlash() {
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/foo/"), "/foo")
    }

    func testNormalizeAddsLeadingSlash() {
        XCTAssertEqual(LocalStore.normalizedPathPrefix("foo"), "/foo")
    }

    func testNormalizeEncodesUnicodeAndIsIdempotent() {
        let fromRaw = LocalStore.normalizedPathPrefix("/résumé")
        let fromEncoded = LocalStore.normalizedPathPrefix("/r%C3%A9sum%C3%A9")
        XCTAssertEqual(fromRaw, "/r%C3%A9sum%C3%A9")
        XCTAssertEqual(fromEncoded, "/r%C3%A9sum%C3%A9")
        XCTAssertEqual(LocalStore.normalizedPathPrefix(fromRaw), fromRaw)
    }

    func testNormalizeEscapesLiteralPercent() {
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/100%complete"), "/100%25complete")
    }

    // MARK: - MatchType.encode (host-only; tolerates a pasted full URL)

    func testEncodeDomainSuffixAddsWildcard() {
        let (host, path) = URLRulesEditor.MatchType.domainSuffix.encode(value: "example.com")
        XCTAssertEqual(host, "*.example.com")
        XCTAssertNil(path)
    }

    func testEncodeDomainSuffixKeepsExistingWildcard() {
        let (host, path) = URLRulesEditor.MatchType.domainSuffix.encode(value: "*.example.com")
        XCTAssertEqual(host, "*.example.com")
        XCTAssertNil(path)
    }

    func testEncodeDomainSuffixStripsSchemeAndPath() {
        let (host, path) = URLRulesEditor.MatchType.domainSuffix.encode(value: "https://example.com/foo")
        XCTAssertEqual(host, "*.example.com")
        XCTAssertNil(path)
    }

    func testEncodeDomainSuffixRejectsBareWildcard() {
        // "*." reduces to an empty host, which save() drops — the degenerate
        // "*." rule must never reach the matcher (the C++ side would match
        // trailing-dot FQDN hosts with it).
        let (host, _) = URLRulesEditor.MatchType.domainSuffix.encode(value: "*.")
        XCTAssertEqual(host, "")
    }

    func testEncodeDomainIsExactHost() {
        let (host, path) = URLRulesEditor.MatchType.domain.encode(value: "www.example.com")
        XCTAssertEqual(host, "www.example.com")
        XCTAssertNil(path)
    }

    func testEncodeDomainStripsWildcardPrefix() {
        // The mode picker, not a typed "*.", decides wildcarding — an exact
        // Domain rule must never persist a host the matcher would treat as
        // a suffix pattern.
        let (host, path) = URLRulesEditor.MatchType.domain.encode(value: "*.example.com")
        XCTAssertEqual(host, "example.com")
        XCTAssertNil(path)
    }

    func testEncodeDomainStripsSchemeAndPath() {
        let (host, path) = URLRulesEditor.MatchType.domain.encode(value: "https://example.com/foo")
        XCTAssertEqual(host, "example.com")
        XCTAssertNil(path)
    }

    func testEncodeStripsPort() {
        let (exact, _) = URLRulesEditor.MatchType.domain.encode(value: "localhost:3000")
        XCTAssertEqual(exact, "localhost")
        let (suffix, _) = URLRulesEditor.MatchType.domainSuffix.encode(value: "https://example.com:8080/x")
        XCTAssertEqual(suffix, "*.example.com")
    }

    func testEncodeLeavesBareIPv6Alone() {
        // "[::1]" has colons but no digits-only suffix after the last one —
        // the port cut must not mangle it.
        let (host, _) = URLRulesEditor.MatchType.domain.encode(value: "[::1]")
        XCTAssertEqual(host, "[::1]")
    }

    func testEncodeDomainContainsWrapsNeedle() {
        let (host, path) = URLRulesEditor.MatchType.domainContains.encode(value: "git")
        XCTAssertEqual(host, "*git*")
        XCTAssertNil(path)
    }

    func testEncodeDomainContainsStripsTypedStars() {
        // The "*"s are the wire sentinel, not user input — typed ones are
        // stripped so the stored form is always exactly "*needle*".
        let (host, _) = URLRulesEditor.MatchType.domainContains.encode(value: "*git*")
        XCTAssertEqual(host, "*git*")
    }

    func testEncodeDomainContainsRejectsEmptyNeedle() {
        let (host, _) = URLRulesEditor.MatchType.domainContains.encode(value: "**")
        XCTAssertEqual(host, "")
    }

    // MARK: - MatchType.decode

    func testDecodeWildcardHostAsDomainSuffix() {
        let (type, value) = URLRulesEditor.MatchType.decode(host: "*.example.com", pathPrefix: nil)
        XCTAssertEqual(type, .domainSuffix)
        XCTAssertEqual(value, "example.com")
    }

    func testDecodeContainsHostAsDomainContains() {
        let (type, value) = URLRulesEditor.MatchType.decode(host: "*git*", pathPrefix: nil)
        XCTAssertEqual(type, .domainContains)
        XCTAssertEqual(value, "git")
    }

    func testDecodeContainsWithLeadingDotNeedle() {
        // "*.git.*" must decode as contains (needle ".git."), not as a
        // suffix rule — same parse order as the matchers.
        let (type, value) = URLRulesEditor.MatchType.decode(host: "*.git.*", pathPrefix: nil)
        XCTAssertEqual(type, .domainContains)
        XCTAssertEqual(value, ".git.")
    }

    func testDecodePathPrefixAsURL() {
        // A stored path prefix means the rule was authored as a URL match;
        // host and path are shown joined back together.
        let (type, value) = URLRulesEditor.MatchType.decode(host: "example.com", pathPrefix: "/foo")
        XCTAssertEqual(type, .url)
        XCTAssertEqual(value, "example.com/foo")
    }

    // MARK: - MatchType.url (exact host + path prefix)

    func testEncodeURLSplitsHostAndPath() {
        let (host, path) = URLRulesEditor.MatchType.url.encode(value: "https://github.com/anthropics")
        XCTAssertEqual(host, "github.com")
        XCTAssertEqual(path, "/anthropics")
    }

    func testEncodeURLWithoutPathHasNilPath() {
        // A URL rule with no path reduces to a bare exact host.
        let (host, path) = URLRulesEditor.MatchType.url.encode(value: "github.com")
        XCTAssertEqual(host, "github.com")
        XCTAssertNil(path)
    }

    func testEncodeURLStripsSchemeAndPort() {
        let (host, path) = URLRulesEditor.MatchType.url.encode(value: "https://example.com:8080/foo/bar")
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(path, "/foo/bar")
    }

    func testEncodeURLStripsWildcardPrefixOnHost() {
        // The host of a URL rule is matched exactly, so a typed "*." is
        // stripped (the path is what makes it specific).
        let (host, path) = URLRulesEditor.MatchType.url.encode(value: "*.example.com/foo")
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(path, "/foo")
    }

    func testURLRuleRoundTripsThroughDraftAndMatches() {
        // encode → draft (canonicalizes the path) → decode round-trips, and
        // the persisted rule matches the path and its subpaths but not others.
        let (host, rawPath) = URLRulesEditor.MatchType.url.encode(value: "https://github.com/anthropics")
        let draft = LocalStore.URLRuleDraft(host: host, pathPrefix: rawPath)
        let r = rule(space: "work", host: draft.host, path: draft.pathPrefix)
        XCTAssertEqual(resolve("https://github.com/anthropics", [r]), "work")
        XCTAssertEqual(resolve("https://github.com/anthropics/claude", [r]), "work")
        XCTAssertNil(resolve("https://github.com/other", [r]))

        let (type, value) = URLRulesEditor.MatchType.decode(host: r.host, pathPrefix: r.pathPrefix)
        XCTAssertEqual(type, .url)
        XCTAssertEqual(value, "github.com/anthropics")
    }
}
