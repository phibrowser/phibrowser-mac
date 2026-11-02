// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Runs with the user's signed-in session, so it must only ever read github.com.
/// The page must be same-site: a frame elsewhere loses the SameSite cookies. See docs/live-folders.md.
@MainActor
final class GitHubSessionFetcher {
    struct Response: Equatable {
        var status: Int
        var finalURL: String
        var body: String
    }

    enum FetchError: Error {
        case profileUnavailable
        case pageUnavailable
        case refusedURL
    }

    private static let origin = "https://github.com"
    private static let pageLoadTimeout: TimeInterval = 10
    private static let requestTimeout: TimeInterval = 30

    private let browser: AppDevToolsPageSession
    private let page: AppDevToolsPageSession
    private let targetId: String

    private init(browser: AppDevToolsPageSession, page: AppDevToolsPageSession, targetId: String) {
        self.browser = browser
        self.page = page
        self.targetId = targetId
    }

    /// `anchorTargetId` is any page of the wanted profile. Pair with `close()`.
    static func open(anchorTargetId: String) async throws -> GitHubSessionFetcher {
        let browser = try await AppDevToolsPageSession.openBrowser()
        do {
            let targets = try await browser.command("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
            guard let context = targets.first(where: { $0["targetId"] as? String == anchorTargetId })?["browserContextId"] as? String else {
                throw FetchError.profileUnavailable
            }
            let created = try await browser.command("Target.createTarget", params: [
                "url": origin + "/robots.txt",
                "browserContextId": context,
                "hidden": true,
                "background": true,
            ])
            guard let targetId = created["targetId"] as? String else { throw FetchError.pageUnavailable }
            do {
                let page = try await AppDevToolsPageSession.open(targetId: targetId)
                let fetcher = GitHubSessionFetcher(browser: browser, page: page, targetId: targetId)
                do {
                    try await fetcher.waitForPage()
                } catch {
                    await fetcher.close()
                    throw error
                }
                return fetcher
            } catch {
                _ = try? await browser.command("Target.closeTarget", params: ["targetId": targetId])
                throw error
            }
        } catch {
            browser.close()
            throw error
        }
    }

    func get(_ url: String, headers: [String: String]) async throws -> Response {
        guard let expression = Self.fetchExpression(url: url, headers: headers) else {
            throw FetchError.refusedURL
        }
        let reply = try await page.command("Runtime.evaluate", params: [
            "expression": expression,
            "awaitPromise": true,
            "returnByValue": true,
        ], timeout: Self.requestTimeout)
        guard let value = (reply["result"] as? [String: Any])?["value"] as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            return Response(status: 0, finalURL: url, body: "")
        }
        return Response(
            status: json["status"] as? Int ?? 0,
            finalURL: json["url"] as? String ?? url,
            body: json["body"] as? String ?? ""
        )
    }

    func close() async {
        page.close()
        _ = try? await browser.command("Target.closeTarget", params: ["targetId": targetId])
        browser.close()
    }

    private func waitForPage() async throws {
        let deadline = Date().addingTimeInterval(Self.pageLoadTimeout)
        let check = "location.origin + ' ' + document.readyState"
        while Date() < deadline {
            let reply = try await page.command("Runtime.evaluate", params: [
                "expression": check,
                "returnByValue": true,
            ])
            if (reply["result"] as? [String: Any])?["value"] as? String == "\(Self.origin) complete" {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw FetchError.pageUnavailable
    }

    /// Nil for anything but https://github.com. Values go in as JSON literals so a URL can't escape the string.
    nonisolated static func fetchExpression(url: String, headers: [String: String]) -> String? {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host == "github.com",
              parsed.port == nil, parsed.user == nil,
              let urlLiteral = jsonLiteral(url), let headersLiteral = jsonLiteral(headers) else {
            return nil
        }
        return """
        fetch(\(urlLiteral),{credentials:'include',cache:'no-store',headers:\(headersLiteral)})\
        .then(async r=>JSON.stringify({status:r.status,url:r.url,body:await r.text()}))\
        .catch(()=>JSON.stringify({status:0,url:'',body:''}))
        """
    }

    private nonisolated static func jsonLiteral(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
