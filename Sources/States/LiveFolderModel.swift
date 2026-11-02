// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct GitHubLiveFilter: Codable, Equatable {
    struct Attributes: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let authored = Attributes(rawValue: 1)
        static let reviewRequests = Attributes(rawValue: 2)
        static let teamReviewRequests = Attributes(rawValue: 4)
        static let all: Attributes = [.authored, .reviewRequests, .teamReviewRequests]
    }

    var attributes: Attributes = .all
    var hiddenRepositories: [String] = []
}

enum LiveFolderError: String, Codable, Equatable {
    case notSignedIn, rateLimited, unexpectedPage, network
}

struct LivePullRequest: Equatable, Identifiable {
    enum State: String, Codable { case open, draft, merged, closed }

    var owner: String
    var repo: String
    var number: Int
    var title: String
    var author: String?
    var state: State = .open
    var createdAt: Date?
    var updatedAt: Date?

    var id: String { url }
    var url: String { "https://github.com/\(owner)/\(repo)/pull/\(number)" }
    var repository: String { "\(owner)/\(repo)" }
}

struct LiveFolderRow: Codable, Equatable, Identifiable {
    static let tabMarkerPrefix = "live-pr:"

    var url: String
    var title: String
    var author: String?
    var repository: String
    var isDraft = false
    var isUnread = false
    var createdAt: Date?
    var goneAt: Date?

    var id: String { url }

    /// Derived from the URL so a restored tab finds its row again.
    var tabMarker: String { Self.tabMarkerPrefix + url.lowercased() }

    static func isTabMarker(_ value: String?) -> Bool {
        value?.hasPrefix(tabMarkerPrefix) == true
    }
}

/// Must stay out of the bookmark store, so neither the folder nor its rows reach sync.
struct LiveFolderData: Codable, Equatable {
    /// Grace period so a merge or review doesn't pull a row out from under the user.
    static let retention: TimeInterval = 120
    static let hiddenItemLimit = 200

    var filter = GitHubLiveFilter()
    var rows: [LiveFolderRow] = []
    var hiddenItems: [String] = []
    var isExpanded = true
    var lastFetch: Date?
    var lastError: LiveFolderError?
    var ssoOrganizations: [String] = []

    var needsSignIn: Bool {
        lastError == .notSignedIn || (lastError == nil && !ssoOrganizations.isEmpty)
    }

    /// A row from an organization whose SSO session lapsed was only held back, so it isn't marked gone.
    mutating func apply(_ pullRequests: [LivePullRequest], ssoOrganizations organizations: [String], now: Date = Date()) {
        let hidden = Set(hiddenItems)
        let hiddenRepositories = Set(filter.hiddenRepositories.map { $0.lowercased() })
        let wanted = pullRequests.filter {
            !hidden.contains($0.url) && !hiddenRepositories.contains($0.repository.lowercased())
        }
        var existing = Dictionary(rows.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let isFirstFill = lastFetch == nil || (lastError != nil && rows.isEmpty)

        var updated: [LiveFolderRow] = wanted.map { pullRequest in
            var row = existing.removeValue(forKey: pullRequest.url) ?? LiveFolderRow(
                url: pullRequest.url,
                title: pullRequest.title,
                repository: pullRequest.repository,
                isUnread: !isFirstFill,
                createdAt: pullRequest.createdAt
            )
            row.title = pullRequest.title
            row.author = pullRequest.author
            row.isDraft = pullRequest.state == .draft
            row.goneAt = nil
            return row
        }

        let heldBack = Set(organizations.map { $0.lowercased() })
        for var row in rows where existing[row.url] != nil {
            guard !hidden.contains(row.url),
                  !hiddenRepositories.contains(row.repository.lowercased()) else { continue }
            let owner = row.repository.split(separator: "/").first.map { $0.lowercased() }
            if !heldBack.contains(owner ?? ""), row.goneAt == nil { row.goneAt = now }
            updated.append(row)
        }

        rows = updated
        lastFetch = now
        lastError = nil
        ssoOrganizations = organizations
    }

    /// A saved error may only mean the app quit mid-refresh, so a launch retries instead of showing it.
    func clearingStaleError() -> LiveFolderData {
        guard lastError != nil else { return self }
        var folder = self
        folder.lastError = nil
        folder.lastFetch = .distantPast
        return folder
    }

    mutating func applyFailure(_ error: LiveFolderError, now: Date = Date()) {
        lastFetch = now
        lastError = error
    }

    @discardableResult
    mutating func expireRows(openTabMarkers: Set<String>, now: Date = Date()) -> Bool {
        let before = rows.count
        rows.removeAll { row in
            guard let goneAt = row.goneAt, !openTabMarkers.contains(row.tabMarker) else { return false }
            return now.timeIntervalSince(goneAt) >= Self.retention
        }
        return rows.count != before
    }

    mutating func hide(url: String) {
        rows.removeAll { $0.url == url }
        if !hiddenItems.contains(url) { hiddenItems.append(url) }
        if hiddenItems.count > Self.hiddenItemLimit {
            hiddenItems.removeFirst(hiddenItems.count - Self.hiddenItemLimit)
        }
    }

    mutating func setRepository(_ repository: String, hidden: Bool) {
        let key = repository.lowercased()
        filter.hiddenRepositories.removeAll { $0.lowercased() == key }
        guard hidden else { return }
        filter.hiddenRepositories.append(repository)
        rows.removeAll { $0.repository.lowercased() == key }
    }
}
