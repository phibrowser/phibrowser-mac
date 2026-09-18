// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension AgentSpaceRouter {

    /// `agentSpace.readerArticle` — run Reader View extraction on a tab and
    /// return the distilled article.
    ///
    /// This is the shipping pipeline, not a re-implementation: the same site
    /// rule lookup, the same three-rung ladder, the same coverage gate, and
    /// the same accessibility fallback the reader button uses. An agent that
    /// wants an article rather than a page scrape gets exactly what the reader
    /// would show, and a rule change is observable here the moment it lands.
    ///
    /// Extraction does not touch the page's own state beyond the preparation
    /// pass the reader already performs, and it never navigates the tab, so
    /// this is passive with respect to what the user sees.
    ///
    /// Payload: `{taskId, targetId?, includeHTML?, complete?}`. `targetId`
    /// defaults to the Space's active tab; `includeHTML` defaults to true and
    /// can be turned off when only the verdict is wanted, since a long
    /// article's markup dwarfs everything else in the response. `complete`
    /// waits for the whole of a paginated document instead of the first pages
    /// the reader opens with — the reader fills the rest in behind itself,
    /// which an API caller has no equivalent of.
    static func handleReaderArticle(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else {
            return invalid()
        }
        let targetId = obj["targetId"] as? String
        let includeHTML = obj["includeHTML"] as? Bool ?? true
        let complete = obj["complete"] as? Bool ?? false
        // Reading is passive, so it does not require control of the Space —
        // but it is still restricted to the task's own driver.
        guard callerMayControl(taskId: taskId, context: context,
                               touchKeepAlive: false) else {
            return unknownTask()
        }

        Task { @MainActor in
            let response: String
            do {
                let tab = try Self.readerTab(taskId: taskId, targetId: targetId)
                let service = ReaderExtractionService.shared
                var (article, ruleHost) = try await service.extractWithRule(from: tab)
                if complete, !article.isComplete {
                    article = try await service
                        .extractCompleteAccessibilityArticle(tab: tab)
                }
                response = Self.readerResponse(article,
                                               ruleHost: ruleHost,
                                               includeHTML: includeHTML)
            } catch {
                response = Self.readerFailure(error)
            }
            ExtensionMessaging.shared.sendResponse(response,
                                                   requestId: context.requestId)
        }
        return nil
    }

    /// `agentSpace.readerDocument` — the distilled article as one standalone
    /// HTML document, the same file the reader's "Save Article as HTML…"
    /// writes.
    ///
    /// The counterpart for the original page is `Page.captureSnapshot`, which
    /// a driver already reaches over CDP, so only this half needs an API: the
    /// reader document is assembled from the extraction, the reading style and
    /// the image inliner, none of which exist outside the app.
    ///
    /// Payload: `{taskId, targetId?, complete?, inlineImages?}`. `complete`
    /// waits for the whole of a paginated document, as in `readerArticle`.
    /// `inlineImages` defaults to true, which is what makes the file
    /// self-contained; turning it off leaves the images as origin URLs, which
    /// is smaller to carry and enough when the caller only wants the markup.
    static func handleReaderDocument(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else {
            return invalid()
        }
        let targetId = obj["targetId"] as? String
        let complete = obj["complete"] as? Bool ?? false
        let inlineImages = obj["inlineImages"] as? Bool ?? true
        guard callerMayControl(taskId: taskId, context: context,
                               touchKeepAlive: false) else {
            return unknownTask()
        }

        Task { @MainActor in
            let response: String
            do {
                let tab = try Self.readerTab(taskId: taskId, targetId: targetId)
                let service = ReaderExtractionService.shared
                var article = try await service.extract(from: tab)
                if complete, !article.isComplete {
                    article = try await service
                        .extractCompleteAccessibilityArticle(tab: tab)
                }
                // The reader's own defaults: an agent has no reading style of
                // its own, and a saved file has no browser appearance to match.
                let document = await ReaderExportService.makeArticleDocument(
                    article: article,
                    style: ReaderStyle.current,
                    appearanceIsDark: false,
                    inlineImages: inlineImages)
                response = jsonString([
                    "ok": true,
                    "title": article.title,
                    "sourceURL": article.sourceURL,
                    "rung": article.rung,
                    "isComplete": article.isComplete,
                    "suggestedFileName": ReaderExportService.suggestedFileName(
                        title: article.title, extension: "html"),
                    "document": String(decoding: document, as: UTF8.self),
                ]) ?? "{\"ok\":false,\"error\":\"encode_failed\"}"
            } catch {
                response = Self.readerFailure(error)
            }
            ExtensionMessaging.shared.sendResponse(response,
                                                   requestId: context.requestId)
        }
        return nil
    }

    // MARK: - Tab resolution

    private enum ReaderAPIError: Error {
        case unknownTask
        case unknownTarget
    }

    @MainActor
    private static func readerTab(taskId: String, targetId: String?) throws -> Tab {
        guard let windowId = AgentSpaceManager.shared.task(forTaskId: taskId)?.windowId,
              windowId != 0,
              let controller = SpaceSessionControllersManager.shared
                  .controller(for: windowId) else {
            throw ReaderAPIError.unknownTask
        }
        let state = controller.browserState
        guard let targetId, !targetId.isEmpty else {
            guard let active = state.focusingTab else {
                throw ReaderAPIError.unknownTarget
            }
            return active
        }
        // `devToolsTargetId` is derived from the live WebContents, so this
        // matches the same identifier the driver used to attach over CDP.
        guard let tab = state.tabs.first(where: {
            $0.webContentWrapper?.devToolsTargetId == targetId
        }) else {
            throw ReaderAPIError.unknownTarget
        }
        return tab
    }

    // MARK: - Serialisation

    @MainActor
    private static func readerResponse(_ article: ReaderArticle,
                                       ruleHost: String?,
                                       includeHTML: Bool) -> String {
        var payload: [String: Any] = [
            "ok": true,
            "title": article.title,
            "sourceURL": article.sourceURL,
            "rung": article.rung,
            "coverage": article.coverage,
            "isComplete": article.isComplete,
            // Character count of the markup, which is what a caller comparing
            // one extraction against another actually wants; the full markup
            // is optional and often huge.
            "htmlLength": article.contentHTML.count,
            // Each one carries a copy control in the reader, so the count is
            // worth seeing when checking a site's code samples survived.
            "codeBlockCount": article.codeBlocks.count,
        ]
        payload["byline"] = article.byline
        payload["siteName"] = article.siteName
        payload["lang"] = article.lang
        payload["pageCount"] = article.pageCount
        // Which rule, if any, applied — the single most useful thing to see
        // when working out why a site extracted the way it did. Reported by
        // the extension, which owns the rule corpus.
        payload["rule"] = ruleHost
        if includeHTML {
            payload["contentHTML"] = article.contentHTML
        }
        return jsonString(payload) ?? "{\"ok\":false,\"error\":\"encode_failed\"}"
    }

    private static func readerFailure(_ error: Error) -> String {
        let reason: String
        switch error {
        case ReaderAPIError.unknownTask:
            reason = "unknown_task"
        case ReaderAPIError.unknownTarget:
            reason = "unknown_target"
        case ReaderExtractionError.noArticleDetected:
            reason = "no_article_detected"
        case ReaderExtractionError.belowCoverageFloor(let best):
            // The best rung's coverage travels with the refusal, because the
            // number is the whole point when tuning the floor.
            return jsonString(["ok": false,
                               "error": "below_coverage_floor",
                               "bestCoverage": best])
                ?? "{\"ok\":false,\"error\":\"below_coverage_floor\"}"
        case ReaderExtractionError.noTarget:
            reason = "no_target"
        case ReaderExtractionError.transportUnavailable:
            reason = "transport_unavailable"
        case ReaderExtractionError.failed(let detail):
            reason = detail
        default:
            reason = "extraction_failed"
        }
        return jsonString(["ok": false, "error": reason])
            ?? "{\"ok\":false,\"error\":\"extraction_failed\"}"
    }

    private static func jsonString(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
