// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// A distilled article, ready for presentation.
struct ReaderArticle: Equatable {
    let title: String
    let byline: String?
    let siteName: String?
    let lang: String?
    /// Sanitised, URL-absolutised article markup. Rendered with scripting
    /// disabled, so this is trusted only as inert markup.
    let contentHTML: String
    let sourceURL: String
    /// Which rung of the ladder produced this — "rule", "readability", or
    /// "structural". Carried for diagnostics and future rule tuning.
    let rung: String
    /// Extracted text as a fraction of the page's total visible text.
    let coverage: Double
    /// The text of each `<pre>` in `contentHTML`, in document order, indexed
    /// by the `data-phi-code` attribute on that element. Taken from the live
    /// DOM during extraction because syntax highlighting shreds a sample into
    /// nested spans that cannot be reassembled reliably from markup.
    var codeBlocks: [String] = []
    /// False while more of the document is still being captured. Only the
    /// accessibility path produces partial articles; the DOM path always has
    /// the whole page in hand.
    var isComplete: Bool = true
    /// Pages captured so far, for the "still loading" affordance. Nil outside
    /// the paginated (PDF) path.
    var pageCount: Int?
    /// The article rendered as markdown, present only when the extraction
    /// asked for it (`extractArticle(includeMarkdown:)`). Converted in-page
    /// by the extension; the accessibility path renders its own.
    var contentMarkdown: String?
}

enum ReaderExtractionError: Error {
    /// The tab has no live page to extract from.
    case noTarget
    /// The Phi Reader extension did not answer — not loaded, or the bridge
    /// is down.
    case transportUnavailable
    /// Every rung declined; the page is not an article.
    case noArticleDetected
    /// Something extracted, but too little of the page to be a real article.
    case belowCoverageFloor(best: Double)
    case failed(String)
}

/// Extracts a readable article from a live tab.
///
/// The DOM ladder — site rules, Readability, the structural fallback, and
/// the accept policy over them — lives in the Phi Reader extension
/// (`phi-ai/ai-extension/reader`); this service reaches it through
/// `ReaderExtensionBridge.extractArticle`. What stays native is the
/// accessibility-tree path, which rescues documents whose markup defeats
/// every DOM rung and needs the framework's snapshot API rather than
/// anything a content script can see.
@MainActor
final class ReaderExtractionService {

    static let shared = ReaderExtractionService()

    private init() {}

    /// Whether the reader could conceivably have anything to offer for this
    /// URL — the fast gate under the button, and the whole test for surfaces
    /// that cannot wait for a verdict (the Chromium context menu mirrors it).
    ///
    /// A PDF is excluded because extraction declines one, and a button whose
    /// only outcome is "Reader View is unavailable on this page" is worse
    /// than no button.
    ///
    /// The path extension is the only URL-side signal the client has: a tab's
    /// content type does not cross the bridge. So a PDF served from a URL
    /// that does not end in .pdf still passes here, and still refuses when
    /// pressed — the refusal is the guarantee, this is only the tidying.
    nonisolated static func canOfferReader(forURLString urlString: String?) -> Bool {
        guard let urlString, !urlString.isEmpty, !urlString.isLocalUrlString,
              let url = URL(string: urlString) else {
            return false
        }
        return url.pathExtension.lowercased() != "pdf"
    }

    /// Extracts an article: the extension's DOM ladder first, then the
    /// accessibility tree for a page whose markup defeats every DOM rung.
    func extract(from tab: Tab) async throws -> ReaderArticle {
        do {
            let outcome = try await ReaderExtensionBridge.extractArticle(from: tab)
            AppLogDebug("[Reader] extension extraction succeeded " +
                        "rung=\(outcome.article.rung) " +
                        "coverage=\(outcome.article.coverage)")
            return outcome.article
        } catch {
            let canFallBack = Self.shouldFallBackToAccessibility(after: error)
            AppLogDebug("[Reader] extension extraction failed: \(error) " +
                        "accessibilityFallback=\(canFallBack)")
            guard canFallBack else {
                throw error
            }
            let article = try await extractFromAccessibilityTree(tab: tab)
            AppLogDebug("[Reader] accessibility path produced " +
                        "pages=\(article.pageCount ?? -1) " +
                        "complete=\(article.isComplete)")
            return article
        }
    }

    /// Extracts an article and reports which site rule, if any, produced it.
    /// The agent API surfaces the rule host as a diagnostic; the
    /// accessibility fallback has no rule to name.
    func extractWithRule(from tab: Tab) async throws -> (article: ReaderArticle,
                                                         ruleHost: String?) {
        do {
            let outcome = try await ReaderExtensionBridge.extractArticle(from: tab)
            return (outcome.article, outcome.ruleHost)
        } catch {
            guard Self.shouldFallBackToAccessibility(after: error) else {
                throw error
            }
            return (try await extractFromAccessibilityTree(tab: tab), nil)
        }
    }

    /// Whether a DOM-side miss is worth a second attempt through the
    /// accessibility tree.
    ///
    /// A PDF is deliberately excluded, which means Reader View declines every
    /// PDF: the accessibility tree was the only route into one, so refusing it
    /// here turns the feature off for them. The reader could read a PDF, but
    /// not well enough to be worth offering.
    private static func shouldFallBackToAccessibility(after error: Error) -> Bool {
        switch error {
        case ReaderExtractionError.noArticleDetected,
             ReaderExtractionError.belowCoverageFloor:
            return true
        default:
            // A PDF, no target, or the extension unreachable: nothing the
            // fallback can fix.
            return false
        }
    }

    // MARK: - Accessibility path

    /// Pages captured before the article is served. A long document builds
    /// its tree page by page, so waiting for all of it would stall the caller
    /// for seconds; this is enough to start with while the rest is captured
    /// on request.
    static let initialPageCount = 5
    private static let initialCaptureTimeoutMs = 6000
    private static let fullCaptureTimeoutMs = 60000

    func extractFromAccessibilityTree(tab: Tab,
                                      minimumPages: Int,
                                      timeoutMs: Int) async throws -> ReaderArticle {
        guard let wrapper = tab.webContentWrapper else {
            throw ReaderExtractionError.noTarget
        }
        let snapshot: [String: Any]? = await withCheckedContinuation { continuation in
            wrapper.requestAccessibilityTreeSnapshot(
                withMinimumPages: minimumPages,
                timeoutMs: timeoutMs) { result in
                    continuation.resume(returning: result)
                }
        }
        guard let snapshot else {
            throw ReaderExtractionError.noArticleDetected
        }
        var article = try ReaderAccessibilityExtractor.article(
            from: snapshot,
            fallbackTitle: tab.title,
            sourceURL: tab.url ?? "")
        article.isComplete = snapshot["complete"] as? Bool ?? true
        article.pageCount = snapshot["pageCount"] as? Int
        return article
    }

    private func extractFromAccessibilityTree(tab: Tab) async throws -> ReaderArticle {
        try await extractFromAccessibilityTree(
            tab: tab,
            minimumPages: Self.initialPageCount,
            timeoutMs: Self.initialCaptureTimeoutMs)
    }

    /// Captures the whole document, for a caller that asked for `complete`.
    func extractCompleteAccessibilityArticle(tab: Tab) async throws -> ReaderArticle {
        try await extractFromAccessibilityTree(
            tab: tab,
            minimumPages: 0,
            timeoutMs: Self.fullCaptureTimeoutMs)
    }
}
