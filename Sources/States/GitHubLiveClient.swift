// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension LiveFolderError: Error {}

/// Turns GitHub's private pages into pull requests, for example `/pulls?q=` JSON or the classic HTML list.
/// The routes can change without notice; LiveFolderTests holds the supported shapes.
enum GitHubLiveClient {
    struct Page: Equatable {
        var pullRequests: [LivePullRequest] = []
        var viewer: String?
        var ssoOrganizations: [String] = []
    }

    typealias Failure = LiveFolderError

    static func query(for attribute: GitHubLiveFilter.Attributes) -> String {
        let who: String
        switch attribute {
        case .authored: who = "author:@me"
        case .reviewRequests: who = "user-review-requested:@me"
        default: who = "review-requested:@me"
        }
        return "is:pr is:open archived:false \(who) sort:updated-desc"
    }

    static func pullsURL(query: String) -> String {
        var c = URLComponents(string: "https://github.com/pulls")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url!.absoluteString
    }

    static func searchURL(query: String) -> String {
        var c = URLComponents(string: "https://github.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "pullrequests")]
        return c.url!.absoluteString
    }

    static let jsonHeaders = [
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest",
        "GitHub-Verified-Fetch": "true",
    ]

    // MARK: Responses

    static func read(status: Int, finalURL: String, body: String) -> Result<Page, Failure> {
        if status == 0 { return .failure(.network) }
        if let path = URL(string: finalURL)?.path, path == "/login" || path.hasPrefix("/session") {
            return .failure(.notSignedIn)
        }
        if status == 429 || (status == 403 && body.localizedCaseInsensitiveContains("rate limit")) { return .failure(.rateLimited) }
        // Signed out, /pulls answers 404 and search a 200 with "logged_in": false.
        if status == 401 || (body.count < 2000 && body.localizedCaseInsensitiveContains("authenticate you")) { return .failure(.notSignedIn) }
        if body.contains("\"logged_in\":false") { return .failure(.notSignedIn) }
        guard (200..<300).contains(status) else { return .failure(.unexpectedPage) }

        var page = Page()
        page.ssoOrganizations = ssoOrganizations(in: body)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return .failure(.unexpectedPage) }
            page.viewer = viewer(inJSON: json)
            page.pullRequests = pullRequests(inJSON: json)
            return .success(page)
        }
        page.viewer = metaContent("user-login", in: body) ?? metaContent("octolytics-actor-login", in: body)
        if page.viewer?.isEmpty ?? true, body.contains("name=\"user-login\"") { return .failure(.notSignedIn) }
        var found: [LivePullRequest] = []
        var sawPayload = false
        for blob in embeddedJSON(in: body) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(blob.utf8)) else { continue }
            sawPayload = true
            if page.viewer?.isEmpty ?? true { page.viewer = viewer(inJSON: json) }
            found += pullRequests(inJSON: json)
        }
        if found.isEmpty { found = pullRequests(inHTML: body) }
        page.pullRequests = unique(found)
        if page.pullRequests.isEmpty && !sawPayload && !body.contains("blankslate") { return .failure(.unexpectedPage) }
        return .success(page)
    }

    // MARK: Merging

    static func merge(_ pages: [(GitHubLiveFilter.Attributes, Page)]) -> [LivePullRequest] {
        let viewer = pages.lazy.compactMap(\.1.viewer).first { !$0.isEmpty }
        var byURL: [String: LivePullRequest] = [:]
        var order: [String] = []
        for (attribute, page) in pages {
            for var pullRequest in page.pullRequests {
                if pullRequest.author == nil, attribute == .authored { pullRequest.author = viewer }
                if var seen = byURL[pullRequest.url] {
                    seen.author = seen.author ?? pullRequest.author
                    seen.createdAt = seen.createdAt ?? pullRequest.createdAt
                    seen.updatedAt = seen.updatedAt ?? pullRequest.updatedAt
                    byURL[pullRequest.url] = seen
                } else {
                    byURL[pullRequest.url] = pullRequest
                    order.append(pullRequest.url)
                }
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.compactMap { byURL[$0] }.sorted {
            if let a = $0.createdAt ?? $0.updatedAt, let b = $1.createdAt ?? $1.updatedAt, a != b { return a > b }
            return rank[$0.url]! < rank[$1.url]!
        }
    }

    // MARK: JSON

    /// Finds pull requests at any depth, because GitHub's routes nest and name the same facts differently.
    static func pullRequests(inJSON root: Any) -> [LivePullRequest] {
        var out: [LivePullRequest] = []
        func walk(_ v: Any, depth: Int) {
            guard depth < 40 else { return }
            if let d = v as? [String: Any] {
                if let pr = pullRequest(from: d) { out.append(pr); return }
                for (_, child) in d { walk(child, depth: depth + 1) }
            } else if let a = v as? [Any] {
                for child in a { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return unique(out)
    }

    static func pullRequest(from d: [String: Any]) -> LivePullRequest? {
        let typename = (d["__typename"] as? String) ?? (d["type"] as? String) ?? ""
        if !typename.isEmpty, typename != "PullRequest", !typename.lowercased().contains("pull") { return nil }
        guard let number = int(d["number"]) ?? int(d["num"]) else { return nil }
        guard let rawTitle = (d["title"] as? String) ?? (d["hl_title"] as? String) ?? (d["titleHTML"] as? String) else { return nil }
        let link = ["url", "permalink", "html_url", "resourcePath", "path", "href"].lazy.compactMap { d[$0] as? String }.first
        var owner: String?, repo: String?
        if let link, let m = pullPath(link), m.number == number { owner = m.owner; repo = m.repo }
        if owner == nil, let r = repository(d["repository"] ?? d["repo"] ?? d["repoNameWithOwner"] ?? d["repository_nwo"]) {
            owner = r.owner; repo = r.repo
        }
        guard let owner, let repo else { return nil }
        // Search results carry no link, so these fields are what mark one as a pull request.
        let issue = (d["issue"] as? [String: Any])?["issue"] as? [String: Any]
        let isPull = link.map { $0.contains("/pull/") } ?? false || typename == "PullRequest"
            || d["isDraft"] != nil || d["is_draft"] != nil || d["reviewDecision"] != nil || d["pull_request"] != nil
            || issue?["pull_request_id"] != nil || d["reviewable_state"] != nil || d["merged"] != nil
        guard isPull || d["num"] != nil else { return nil }

        var pr = LivePullRequest(owner: owner, repo: repo, number: number, title: plainText(rawTitle))
        pr.author = login(d["author"]) ?? login(d["user"]) ?? (d["author_name"] as? String) ?? (d["authorLogin"] as? String)
        let state = ((d["state"] as? String) ?? "open").lowercased()
        if state == "merged" || (d["merged"] as? Bool) == true || (d["mergedAt"] as? String) != nil || (d["merged_at"] as? String) != nil {
            pr.state = .merged
        } else if state == "closed" {
            pr.state = .closed
        } else if state == "draft" || (d["isDraft"] as? Bool) == true || (d["is_draft"] as? Bool) == true || (d["draft"] as? Bool) == true {
            pr.state = .draft
        }
        pr.createdAt = date(d["createdAt"] ?? d["created_at"] ?? d["created"])
        pr.updatedAt = date(d["updatedAt"] ?? d["updated_at"] ?? d["updated"])
        return pr
    }

    static func viewer(inJSON root: Any) -> String? {
        var found: String?
        func walk(_ v: Any, depth: Int) {
            guard found == nil, depth < 12 else { return }
            if let d = v as? [String: Any] {
                for key in ["viewer", "currentUser", "current_user"] {
                    if let l = login(d[key]) { found = l; return }
                }
                if let l = (d["current_user_login"] as? String) ?? (d["viewerLogin"] as? String), !l.isEmpty { found = l; return }
                for (_, child) in d { walk(child, depth: depth + 1) }
            } else if let a = v as? [Any] {
                for child in a { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return found
    }

    // MARK: HTML

    static func embeddedJSON(in html: String) -> [String] {
        matches(#"<script[^>]*type="application/json"[^>]*>([\s\S]*?)</script>"#, in: html).compactMap { $0.count > 1 ? $0[1] : nil }
    }

    /// The classic issue list, for example `<div class="js-issue-row"><a href="/o/r/pull/1">Title</a>`.
    static func pullRequests(inHTML html: String) -> [LivePullRequest] {
        let chunks = html.components(separatedBy: "js-issue-row")
        var out: [LivePullRequest] = []
        for chunk in chunks.count > 1 ? Array(chunks.dropFirst()) : chunks {
            for m in matches(#"<a\b([^>]*)>([\s\S]*?)</a>"#, in: chunk) where m.count > 2 {
                let attrs = m[1]
                guard let href = attribute("href", in: attrs), let p = pullPath(href), href.hasSuffix("/pull/\(p.number)") else { continue }
                let hovercard = attribute("data-hovercard-type", in: attrs)
                guard hovercard == "pull_request" || attrs.contains("markdown-title") || attrs.contains("js-navigation-open") else { continue }
                let title = plainText(m[2])
                guard !title.isEmpty else { continue }
                var pr = LivePullRequest(owner: p.owner, repo: p.repo, number: p.number, title: title)
                if let by = matches(#"<a\b[^>]*data-hovercard-type="user"[^>]*>([\s\S]*?)</a>"#, in: chunk).first, by.count > 1 {
                    pr.author = plainText(by[1])
                }
                if chunk.contains("octicon-git-pull-request-draft") { pr.state = .draft }
                if let t = matches(#"<relative-time[^>]*datetime="([^"]+)""#, in: chunk).first, t.count > 1 { pr.createdAt = date(t[1]) }
                out.append(pr)
                if chunks.count > 1 { break }
            }
        }
        return unique(out)
    }

    /// Orgs holding back pull requests until a SAML sign-in, for example a link to `/orgs/acme/sso`.
    static func ssoOrganizations(in body: String) -> [String] {
        var seen: [String] = []
        var found = matches(#"/orgs/([A-Za-z0-9_.-]+)/sso"#, in: body).compactMap { $0.count > 1 ? $0[1] : nil }
        for list in matches(#""protected_org_logins"\s*:\s*\[([^\]]*)\]"#, in: body) where list.count > 1 {
            found += matches(#""([A-Za-z0-9_.-]+)""#, in: list[1]).compactMap { $0.count > 1 ? $0[1] : nil }
        }
        for org in found where !seen.contains(org) { seen.append(org) }
        return seen
    }

    // MARK: Helpers

    static func pullPath(_ link: String) -> (owner: String, repo: String, number: Int)? {
        guard let m = matches(#"(?:^|github\.com)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)"#, in: link).first, m.count > 3,
              let n = Int(m[3]) else { return nil }
        return (m[1], m[2], n)
    }

    private static func repository(_ v: Any?) -> (owner: String, repo: String)? {
        if let s = v as? String {
            let parts = s.split(separator: "/")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
        guard let d = v as? [String: Any] else { return nil }
        if let inner = d["repository"] { return repository(inner) }
        if let nwo = d["nameWithOwner"] as? String ?? d["name_with_owner"] as? String ?? d["full_name"] as? String { return repository(nwo) }
        guard let name = d["name"] as? String else { return nil }
        let owner = login(d["owner"]) ?? (d["owner"] as? String) ?? (d["owner_login"] as? String) ?? (d["ownerLogin"] as? String)
        return owner.map { ($0, name) }
    }

    private static func login(_ v: Any?) -> String? {
        guard let d = v as? [String: Any] else { return nil }
        // The signed-in pulls dashboard uses displayLogin, not login.
        let l = (d["login"] as? String) ?? (d["displayLogin"] as? String) ?? (d["display_login"] as? String)
        return l?.isEmpty == false ? l : nil
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func date(_ v: Any?) -> Date? {
        if let s = v as? String { return iso.date(from: s) ?? isoFull.date(from: s) }
        if let n = v as? Double { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        if let n = v as? Int { return Date(timeIntervalSince1970: Double(n) > 1e11 ? Double(n) / 1000 : Double(n)) }
        return nil
    }

    static func metaContent(_ name: String, in html: String) -> String? {
        for m in matches(#"<meta\b[^>]*>"#, in: html) {
            guard attribute("name", in: m[0]) == name else { continue }
            return attribute("content", in: m[0]).map(decodeEntities)
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        matches(#"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: name) + #"="([^"]*)""#, in: tag).first.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    static func plainText(_ s: String) -> String {
        let stripped = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(stripped).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        for m in matches(#"&#(x?)([0-9a-fA-F]+);"#, in: out) where m.count > 2 {
            if let code = UInt32(m[2], radix: m[1].isEmpty ? 10 : 16), let scalar = Unicode.Scalar(code) {
                out = out.replacingOccurrences(of: m[0], with: String(Character(scalar)))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func matches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }

    private static func unique(_ prs: [LivePullRequest]) -> [LivePullRequest] {
        var seen = Set<String>()
        return prs.filter { seen.insert($0.url.lowercased()).inserted }
    }
}
