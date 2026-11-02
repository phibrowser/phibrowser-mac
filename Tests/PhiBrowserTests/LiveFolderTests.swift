// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class LiveFolderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pullRequest(_ number: Int, repo: String = "phi", title: String? = nil) -> LivePullRequest {
        LivePullRequest(owner: "acme", repo: repo, number: number, title: title ?? "PR \(number)")
    }

    // MARK: Reconciling results

    func testFirstFillIsNotUnreadButLaterArrivalsAre() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        XCTAssertEqual(folder.rows.map(\.isUnread), [false])

        folder.apply([pullRequest(2), pullRequest(1)], ssoOrganizations: [], now: now)
        XCTAssertEqual(folder.rows.map(\.url), [pullRequest(2).url, pullRequest(1).url])
        XCTAssertEqual(folder.rows.map(\.isUnread), [true, false])
    }

    func testRefreshKeepsReadStateAndUpdatesTitle() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        folder.apply([pullRequest(2)], ssoOrganizations: [], now: now)
        folder.rows[0].isUnread = false
        folder.apply([pullRequest(2, title: "Renamed")], ssoOrganizations: [], now: now)
        XCTAssertEqual(folder.rows.first?.title, "Renamed")
        XCTAssertEqual(folder.rows.first?.isUnread, false)
    }

    func testRowLeavingResultsExpiresAfterRetention() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        folder.apply([], ssoOrganizations: [], now: now)
        XCTAssertEqual(folder.rows.first?.goneAt, now)

        XCTAssertFalse(folder.expireRows(openTabMarkers: [], now: now.addingTimeInterval(LiveFolderData.retention - 1)))
        XCTAssertTrue(folder.expireRows(openTabMarkers: [], now: now.addingTimeInterval(LiveFolderData.retention)))
        XCTAssertTrue(folder.rows.isEmpty)
    }

    func testRowWithOpenTabOutlivesRetention() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        folder.apply([], ssoOrganizations: [], now: now)
        let marker = folder.rows[0].tabMarker
        XCTAssertFalse(folder.expireRows(openTabMarkers: [marker], now: now.addingTimeInterval(3600)))
        XCTAssertEqual(folder.rows.count, 1)
    }

    func testRowReturningToResultsClearsGoneMark() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        folder.apply([], ssoOrganizations: [], now: now)
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        XCTAssertNil(folder.rows.first?.goneAt)
    }

    func testRowHeldBackBySSOIsNotMarkedGone() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        folder.apply([], ssoOrganizations: ["ACME"], now: now)
        XCTAssertEqual(folder.rows.count, 1)
        XCTAssertNil(folder.rows.first?.goneAt)
        XCTAssertTrue(folder.needsSignIn)
    }

    func testHiddenPullRequestStaysOut() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1), pullRequest(2)], ssoOrganizations: [], now: now)
        folder.hide(url: pullRequest(1).url)
        folder.apply([pullRequest(1), pullRequest(2)], ssoOrganizations: [], now: now)
        XCTAssertEqual(folder.rows.map(\.url), [pullRequest(2).url])
    }

    func testHiddenItemsAreBounded() {
        var folder = LiveFolderData()
        for number in 0..<(LiveFolderData.hiddenItemLimit + 5) {
            folder.hide(url: "https://github.com/acme/phi/pull/\(number)")
        }
        XCTAssertEqual(folder.hiddenItems.count, LiveFolderData.hiddenItemLimit)
    }

    func testRepositoryFilterRemovesRowsAtOnceAndRestoresOnRefresh() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1), pullRequest(2, repo: "other")], ssoOrganizations: [], now: now)
        folder.setRepository("acme/OTHER", hidden: true)
        XCTAssertEqual(folder.rows.map(\.repository), ["acme/phi"])

        folder.apply([pullRequest(1), pullRequest(2, repo: "other")], ssoOrganizations: [], now: now)
        XCTAssertEqual(folder.rows.map(\.repository), ["acme/phi"], "hidden repositories match without regard to case")
        XCTAssertNil(folder.rows.first?.goneAt)

        folder.setRepository("acme/other", hidden: false)
        folder.apply([pullRequest(1), pullRequest(2, repo: "other")], ssoOrganizations: [], now: now)
        XCTAssertEqual(folder.rows.count, 2)
    }

    func testFailureKeepsRows() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        folder.applyFailure(.notSignedIn, now: now)
        XCTAssertEqual(folder.rows.count, 1)
        XCTAssertTrue(folder.needsSignIn)
    }

    func testLaunchDropsSavedErrorAndStaysDueForRefresh() {
        var folder = LiveFolderData()
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        folder.applyFailure(.network, now: now)

        let loaded = folder.clearingStaleError()
        XCTAssertNil(loaded.lastError)
        XCTAssertEqual(loaded.lastFetch, .distantPast)
        XCTAssertEqual(loaded.rows.count, 1)

        var refreshed = loaded
        refreshed.apply([pullRequest(1), pullRequest(2)], ssoOrganizations: [], now: now)
        XCTAssertEqual(refreshed.rows.first { $0.url == pullRequest(2).url }?.isUnread, true, "not a first fill")
    }

    func testFolderRoundTripsThroughStorage() throws {
        var folder = LiveFolderData()
        folder.filter.attributes = [.authored]
        folder.apply([pullRequest(1)], ssoOrganizations: [], now: now)
        let decoded = try JSONDecoder().decode(LiveFolderData.self, from: JSONEncoder().encode(folder))
        XCTAssertEqual(decoded, folder)
    }

    // MARK: Tab markers

    func testTabMarkerIsStableAcrossURLCase() {
        let row = LiveFolderRow(url: "https://github.com/Acme/Phi/pull/1", title: "", repository: "Acme/Phi")
        XCTAssertEqual(row.tabMarker, "live-pr:https://github.com/acme/phi/pull/1")
        XCTAssertTrue(LiveFolderRow.isTabMarker(row.tabMarker))
        XCTAssertFalse(LiveFolderRow.isTabMarker(UUID().uuidString))
        XCTAssertFalse(LiveFolderRow.isTabMarker(nil))
    }

    // MARK: Reading GitHub

    func testSignedOutResponsesReadAsNotSignedIn() {
        let pulls = GitHubLiveClient.read(status: 404, finalURL: "https://github.com/pulls?q=x", body: #"{"error":"Couldn’t authenticate you"}"#)
        XCTAssertEqual(pulls, .failure(.notSignedIn))
        let redirected = GitHubLiveClient.read(status: 200, finalURL: "https://github.com/login?return_to=x", body: "<html></html>")
        XCTAssertEqual(redirected, .failure(.notSignedIn))
    }

    func testRateLimitAndNetworkFailures() {
        XCTAssertEqual(GitHubLiveClient.read(status: 429, finalURL: "https://github.com/pulls", body: ""), .failure(.rateLimited))
        XCTAssertEqual(GitHubLiveClient.read(status: 0, finalURL: "https://github.com/pulls", body: ""), .failure(.network))
    }

    func testReadsPullsDashboardJSON() throws {
        let body = #"""
        {"payload":{"pullsDashboardSurfaceContentRoute":{"results":[{"number":7,"title":"Add &amp; fix","permalink":"https://github.com/acme/phi/pull/7","repoNameWithOwner":"acme/phi","author":{"displayLogin":"octo"},"state":"OPEN","isDraft":true,"createdAt":"2026-10-01T10:00:00Z"}]}}}
        """#
        let page = try GitHubLiveClient.read(status: 200, finalURL: "https://github.com/pulls", body: body).get()
        XCTAssertEqual(page.pullRequests.count, 1)
        let pullRequest = try XCTUnwrap(page.pullRequests.first)
        XCTAssertEqual(pullRequest.url, "https://github.com/acme/phi/pull/7")
        XCTAssertEqual(pullRequest.title, "Add & fix")
        XCTAssertEqual(pullRequest.author, "octo")
        XCTAssertEqual(pullRequest.state, .draft)
        XCTAssertNotNil(pullRequest.createdAt)
    }

    func testReadsSearchRouteJSON() throws {
        let body = #"""
        {"payload":{"blackbirdSearchRoute":{"results":[{"number":9,"hl_title":"Fix <em>bug</em>","author_name":"octo","state":"open","merged":false,"created":"2026-10-01T10:00:00+02:00","repo":{"repository":{"owner_login":"acme","name":"phi"}},"issue":{"issue":{"pull_request_id":1}}}]}}}
        """#
        let page = try GitHubLiveClient.read(status: 200, finalURL: "https://github.com/search", body: body).get()
        XCTAssertEqual(page.pullRequests.first?.title, "Fix bug")
        XCTAssertEqual(page.pullRequests.first?.repository, "acme/phi")
    }

    func testFindsSSOOrganizations() {
        XCTAssertEqual(GitHubLiveClient.ssoOrganizations(in: #"<a href="/orgs/acme/sso">"protected_org_logins":["other"]"#), ["acme", "other"])
    }

    func testMergeDeduplicatesAcrossSearchesAndSortsNewestFirst() {
        var older = pullRequest(1)
        older.createdAt = now
        var newer = pullRequest(2)
        newer.createdAt = now.addingTimeInterval(60)
        var authored = GitHubLiveClient.Page(pullRequests: [older])
        authored.viewer = "me"
        let reviews = GitHubLiveClient.Page(pullRequests: [older, newer])

        let merged = GitHubLiveClient.merge([(.authored, authored), (.reviewRequests, reviews)])
        XCTAssertEqual(merged.map(\.number), [2, 1])
        XCTAssertEqual(merged.last?.author, "me")
    }

    func testQueriesMatchTheFilterKinds() {
        XCTAssertTrue(GitHubLiveClient.query(for: .authored).contains("author:@me"))
        XCTAssertTrue(GitHubLiveClient.query(for: .reviewRequests).contains("user-review-requested:@me"))
        XCTAssertTrue(GitHubLiveClient.query(for: .teamReviewRequests).contains(" review-requested:@me"))
    }

    // MARK: Session boundary

    func testSessionFetcherOnlyReadsGitHub() {
        for url in [
            "https://evil.example/pulls",
            "http://github.com/pulls",
            "https://github.com.evil.example/pulls",
            "https://user@github.com/pulls",
            "https://github.com:8443/pulls",
            "javascript:alert(1)",
        ] {
            XCTAssertNil(GitHubSessionFetcher.fetchExpression(url: url, headers: [:]), url)
        }
        XCTAssertNotNil(GitHubSessionFetcher.fetchExpression(url: "https://github.com/pulls?q=a", headers: [:]))
    }

    func testSessionFetcherEscapesValuesIntoTheScript() throws {
        let url = "https://github.com/pulls?q=a'%22);alert(1)//"
        let expression = try XCTUnwrap(GitHubSessionFetcher.fetchExpression(url: url, headers: ["A": "b\"c"]))
        XCTAssertTrue(expression.hasPrefix("fetch(\"https:"))
        XCTAssertTrue(expression.contains(#""A":"b\"c""#))
    }
}
