// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Pins the Swift-side URL routing semantics that `URLRouter` shares with the
/// C++ `phi::PhiURLRouter`. Since M3-4a the Swift matcher is the test-side
/// oracle (design §9.1): the production matcher is the C++ one, and the
/// tie-break comparator is pinned on BOTH sides by one fixture table (§9.3).
/// Every table under "Tie-break parity" below (CASE R-2 … R-6) is copied
/// verbatim, in the same entry order, into
/// `chrome/browser/phinomenon/phi_url_router_unittest.cc`; R-7 (ask is
/// invisible to `resolve`) exists only there, R-8 (soft-deleted rows) only
/// here. DISCIPLINE: a change to the comparison rule on either
/// side changes both tables in the same commit — there is no shared
/// generator, so nothing catches drift between the two automatically.
/// Non-ASCII hosts stay out of the tables: the two sides normalize input
/// differently (R-M3-4a-1), so such a row would pin a known divergence.
@MainActor
final class URLRouterTests: XCTestCase {

    override func tearDownWithError() throws {
        // CASE 10.1 assembles a resolver on the process-wide manager; put the
        // unassembled default back so no later test inherits it.
        SpaceManager.shared.ruleTieBreakKeyResolver = { _ in nil }
    }

    private func rule(id: String = UUID().uuidString,
                      space: String,
                      host: String,
                      path: String? = nil,
                      ask: Bool = false,
                      askBeforeRouting: Bool? = nil,
                      sortOrder: Int = 0,
                      deletedDate: Date? = nil) -> SpaceRoutingRule {
        let r = SpaceRoutingRule(
            id: id,
            spaceId: space,
            host: host,
            pathPrefix: path,
            askBeforeRouting: askBeforeRouting ?? ask,
            sortOrder: sortOrder,
            deletedDate: deletedDate
        )
        return r
    }

    private func resolve(_ urlString: String, _ rules: [SpaceRoutingRule]) -> String? {
        URLRouter.resolve(url: URL(string: urlString)!,
                          rules: rules,
                          tieBreakKey: { $0.spaceId },
                          ruleId: { $0.id })
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

    func testKioskTargetSurvivesRuleResolution() {
        let rules = [
            rule(
                space: LocalStore.kioskURLRuleTargetId,
                host: "kiosk.example"
            ),
        ]

        XCTAssertEqual(
            resolve("https://kiosk.example/page", rules),
            LocalStore.kioskURLRuleTargetId
        )
    }

    func testExternalKioskUsesDeterministicRuleTargetIdentity() {
        let rules = [
            rule(space: "personal", host: "*.example.com"),
            rule(space: "work", host: "mail.example.com"),
        ]

        XCTAssertEqual(
            ExternalKioskURLRuleResolver.decision(
                for: URL(string: "https://mail.example.com/inbox")!,
                rules: rules
            ),
            .useKioskWithSpaceIdentity("work")
        )
    }

    func testExternalKioskPreservesAskAndExplicitKioskRules() {
        let askRules = [
            rule(
                space: "work",
                host: "ask.example",
                askBeforeRouting: true
            ),
        ]
        let kioskRules = [
            rule(
                space: LocalStore.kioskURLRuleTargetId,
                host: "kiosk.example"
            ),
        ]

        XCTAssertEqual(
            ExternalKioskURLRuleResolver.decision(
                for: URL(string: "https://ask.example/")!,
                rules: askRules
            ),
            .ask(defaultSpaceId: "work")
        )
        XCTAssertEqual(
            ExternalKioskURLRuleResolver.decision(
                for: URL(string: "https://kiosk.example/")!,
                rules: kioskRules
            ),
            .useKiosk
        )
        XCTAssertEqual(
            ExternalKioskURLRuleResolver.decision(
                for: URL(string: "https://unmatched.example/")!,
                rules: askRules + kioskRules
            ),
            .useKiosk
        )
    }

    func testExternalKioskPreservesIncognitoRuleRouting() {
        let rules = [
            rule(
                space: SpaceManager.incognitoRuleTargetId,
                host: "private.example"
            ),
        ]

        XCTAssertEqual(
            ExternalKioskURLRuleResolver.decision(
                for: URL(string: "https://private.example/")!,
                rules: rules
            ),
            .openInSpace(SpaceManager.incognitoRuleTargetId)
        )
    }

    func testURLWithoutHostReturnsNil() {
        let rules = [rule(space: "work", host: "h.com")]
        XCTAssertNil(URLRouter.resolve(url: URL(string: "about:blank")!,
                                       rules: rules,
                                       tieBreakKey: { $0.spaceId },
                                       ruleId: { $0.id }))
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

    // MARK: - Tie-break parity (design §9.2 / §9.3; CASE R-2 … R-6, R-8, 10.1)

    /// One fixture row = (host, pathPrefix, ask, sortOrder, tieBreakKey,
    /// targetSpaceId, ruleId) — the shape §9.3 fixes for both sides. Each
    /// table below appears VERBATIM and in the same entry order in
    /// `phi_url_router_unittest.cc`; change one, change both, one commit.
    private typealias FixtureRow = (host: String,
                                    pathPrefix: String?,
                                    ask: Bool,
                                    sortOrder: Int,
                                    tieBreakKey: String,
                                    targetSpaceId: String,
                                    ruleId: String)

    /// Materializes `table` in the given order and resolves `urlString` with
    /// the production-shaped closures: the tie-break key comes from the
    /// table's column (looked up by rule id), `ruleId` is `syncId ?? id`.
    /// A scratch context per call: the two array-order runs of one CASE
    /// insert the same rule ids, and `id` is `@Attribute(.unique)`.
    private func resolveTable(_ table: [FixtureRow], _ urlString: String) -> String? {
        var keys: [String: String] = [:]
        let rules = table.map { row -> SpaceRoutingRule in
            keys[row.ruleId] = row.tieBreakKey
            let r = SpaceRoutingRule(id: row.ruleId,
                                 spaceId: row.targetSpaceId,
                                 host: row.host,
                                 pathPrefix: row.pathPrefix,
                                 askBeforeRouting: row.ask,
                                 sortOrder: row.sortOrder)
            return r
        }
        return URLRouter.resolve(url: URL(string: urlString)!,
                                 rules: rules,
                                 tieBreakKey: { keys[$0.id]! },
                                 ruleId: { $0.syncId ?? $0.id })
    }

    func testR2_SmallerTieBreakKeyWinsEitherArrayOrder() {
        // Three-way specificity tie across two Spaces: the smaller key wins,
        // whichever rule the array lists first. A tuple `>` implementation
        // keeps the first one encountered and answers differently per order.
        let table: [FixtureRow] = [
            ("h.com", nil, false, 0, "aaa", "S1", "r1"),
            ("h.com", nil, false, 0, "bbb", "S2", "r2"),
        ]
        XCTAssertEqual(resolveTable(table, "https://h.com/p"), "S1")
        XCTAssertEqual(resolveTable(Array(table.reversed()), "https://h.com/p"), "S1")
    }

    func testR3_EmptyTieBreakKeySortsLast() {
        // A malformed payload's empty key must never win a tie — raw byte
        // order ("" < "zzz") would let it win every one.
        let table: [FixtureRow] = [
            ("h.com", nil, false, 0, "", "S1", "r1"),
            ("h.com", nil, false, 0, "zzz", "S2", "r2"),
        ]
        XCTAssertEqual(resolveTable(table, "https://h.com/p"), "S2")
        XCTAssertEqual(resolveTable(Array(table.reversed()), "https://h.com/p"), "S2")
    }

    func testR4_SpecificityOutranksTieBreakKey() {
        // The key only decides when all three specificity components tie:
        // the longer path wins here although its key is the larger one.
        let table: [FixtureRow] = [
            ("h.com", "/docs", false, 0, "zzz", "S2", "r2"),
            ("h.com", nil, false, 0, "aaa", "S1", "r1"),
        ]
        XCTAssertEqual(resolveTable(table, "https://h.com/docs/x"), "S2")
    }

    func testR5_LocalSpaceIdSwapDoesNotChangeWinner() {
        // D15's target: the same two account rules on two devices whose LOCAL
        // space ids happen to be swapped. Deciding on (targetSpaceId,
        // sortOrder) would route them to different Spaces; the account-level
        // key picks the "uuid-1" rule on both.
        let firstDevice: [FixtureRow] = [
            ("h.com", nil, false, 0, "uuid-1", "L1", "r1"),
            ("h.com", nil, false, 0, "uuid-2", "L2", "r2"),
        ]
        let secondDevice: [FixtureRow] = [
            ("h.com", nil, false, 0, "uuid-1", "L2", "r1"),
            ("h.com", nil, false, 0, "uuid-2", "L1", "r2"),
        ]
        XCTAssertEqual(resolveTable(firstDevice, "https://h.com/p"), "L1")
        XCTAssertEqual(resolveTable(secondDevice, "https://h.com/p"), "L2")
    }

    func testR6a_FallbackKeysAreOrderIndependent() {
        // Neither Space has a sync uuid, so both keys fall back to the local
        // spaceId (R-M3-4a-22). Still a total order: same winner for both
        // array orders and on repeated runs — an "unmapped ⇒ empty key" design
        // would make every tie here fall back to the (unstable) array order.
        let table: [FixtureRow] = [
            ("h.com", nil, false, 0, "L2", "L2", "r1"),
            ("h.com", nil, false, 0, "L1", "L1", "r2"),
        ]
        for _ in 0..<3 {
            XCTAssertEqual(resolveTable(table, "https://h.com/p"), "L1")
            XCTAssertEqual(resolveTable(Array(table.reversed()), "https://h.com/p"), "L1")
        }
    }

    func testR6b_RuleIdBreaksTheFinalTie() {
        // Two exact duplicates in ONE target Space (§1.9 allows them): same
        // key, same sortOrder. `resolve` answers "L1" either way, so the
        // comparator itself is the observation — exactly one direction holds
        // (strict total order). A `target spaceId` fallback would be false in
        // both directions and degrade to "first one encountered" (RR-R4).
        // The C++ port makes the winner visible through `is_ask` instead.
        let table: [FixtureRow] = [
            ("h.com", nil, false, 0, "uuid-1", "L1", "rule-a"),
            ("h.com", nil, false, 0, "uuid-1", "L1", "rule-b"),
        ]
        XCTAssertEqual(resolveTable(table, "https://h.com/p"), "L1")
        XCTAssertEqual(resolveTable(Array(table.reversed()), "https://h.com/p"), "L1")
        // Both rows score (0, 2, 0): no path, exact host, -sortOrder.
        let a = URLRouter.Candidate(specificity: (0, 2, 0), tieBreakKey: "uuid-1", ruleId: "rule-a")
        let b = URLRouter.Candidate(specificity: (0, 2, 0), tieBreakKey: "uuid-1", ruleId: "rule-b")
        XCTAssertTrue(URLRouter.isMoreSpecific(a, b))
        XCTAssertFalse(URLRouter.isMoreSpecific(b, a))
    }

    func testR8_SoftDeletedRowsDoNotChangeAnyDecision() {
        // Swift-only (the C++ table never sees `deletedDate`). Device A's
        // bucket L1 (key "uuid-1") holds a soft-deleted row and a live row;
        // the dense order skipped the dead row, so the live one is 0. Device
        // B hard-deleted that row already. A′ replays the BAD implementation
        // that counted the dead row into the dense order (live row at 1).
        // sortOrder is the third specificity component and ranks BEFORE the
        // key, so that one hole is enough to flip the winner (R-M3-4a-51).
        let keys = ["L1": "uuid-1", "L2": "uuid-2"]
        func resolveLive(_ rows: [SpaceRoutingRule]) -> String? {
            URLRouter.resolve(url: URL(string: "https://h.com/p")!,
                              rules: rows.filter { $0.deletedDate == nil },
                              tieBreakKey: { keys[$0.spaceId]! },
                              ruleId: { $0.syncId ?? $0.id })
        }
        let deviceA = [
            rule(id: "a-dead", space: "L1", host: "z.com", sortOrder: 0, deletedDate: Date()),
            rule(id: "a-live", space: "L1", host: "h.com", sortOrder: 0),
            rule(id: "a-l2", space: "L2", host: "h.com", sortOrder: 0),
        ]
        let deviceB = [
            rule(id: "b-live", space: "L1", host: "h.com", sortOrder: 0),
            rule(id: "b-l2", space: "L2", host: "h.com", sortOrder: 0),
        ]
        let deviceAPrime = [
            rule(id: "p-dead", space: "L1", host: "z.com", sortOrder: 0, deletedDate: Date()),
            rule(id: "p-live", space: "L1", host: "h.com", sortOrder: 1),
            rule(id: "p-l2", space: "L2", host: "h.com", sortOrder: 0),
        ]
        XCTAssertEqual(resolveLive(deviceA), "L1")
        XCTAssertEqual(resolveLive(deviceB), "L1")
        XCTAssertEqual(resolveLive(deviceAPrime), "L2")
    }

    func testIncognitoTargetTieBreakKeyComesFromTheInjectedResolver() {
        // CASE 10.1. Production shape of the closure `PhiChromiumCoordinator`
        // injects: the Incognito branch lives in the closure, NOT in
        // `SpaceManager` — the state layer has zero knowledge of
        // "incognito-space" (plan ruling 1). `stub` replays what
        // `SpaceSyncMappingManager.syncUuid(forSpaceId:)` knows: "L1" is
        // mapped, "L9" is not, and no incognito id ever is.
        let stub: [String: String] = ["L1": "uuid-1"]
        SpaceManager.shared.ruleTieBreakKeyResolver = { spaceId in
            SpaceManager.isIncognitoSpaceId(spaceId)
                ? SyncableSpaces.incognitoSpaceUuid
                : stub[spaceId]
        }
        let incognitoKey = SpaceManager.shared.ruleTieBreakKey(
            forTargetSpaceId: SpaceManager.incognitoRuleTargetId)
        XCTAssertEqual(incognitoKey, SyncableSpaces.incognitoSpaceUuid)
        XCTAssertEqual(incognitoKey, "incognito-space")
        XCTAssertEqual(SpaceManager.shared.ruleTieBreakKey(forTargetSpaceId: "L1"), "uuid-1")
        // Unmapped ⇒ falls back to the local id (R-M3-4a-22).
        XCTAssertEqual(SpaceManager.shared.ruleTieBreakKey(forTargetSpaceId: "L9"), "L9")

        // Before the coordinator assembles a resolver (and only then) the
        // default `{ _ in nil }` yields the LOCAL reserved id for Incognito —
        // a cross-device constant, but not the account entity's
        // `target_space_uuid` (§7.2). Pinned so nobody mistakes it for the
        // assembled behaviour above.
        SpaceManager.shared.ruleTieBreakKeyResolver = { _ in nil }
        let unassembledKey = SpaceManager.shared.ruleTieBreakKey(
            forTargetSpaceId: SpaceManager.incognitoRuleTargetId)
        XCTAssertEqual(unassembledKey, SpaceManager.incognitoRuleTargetId)
        XCTAssertEqual(unassembledKey, "space.incognito")
    }

    // MARK: - normalizedPathPrefix (§8.1: "/" is root-only, nil is any path)

    func testNormalizeBareSlashBecomesRootOnly() {
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/"), "/")
    }

    func testNormalizeMultipleSlashesCollapseToRootOnly() {
        XCTAssertEqual(LocalStore.normalizedPathPrefix("///"), "/")
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
