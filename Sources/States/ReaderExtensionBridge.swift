// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// App side of the Phi Reader extension (`phi-ai/ai-extension/reader`).
///
/// The extension probes every page and, when the Developer flag routes Reader
/// View to it, owns the whole reading surface; the app only relays intent.
/// Three message types meet here: `reader.offerable` and `reader.state`
/// arrive from the extension through `ExtensionMessageRouter`, and
/// `reader.open` / `reader.close` are broadcast back when the user asks for
/// the reader. Payload field names are shared with the extension's
/// `src/common/messages.ts`; keep both in sync.
enum ReaderExtensionBridge {

    /// The stable ID of the extension hosting the reader feature — Mirage
    /// (`ai-extension/mirage`, which carries Reader View alongside its
    /// per-site page fixes), derived from its manifest signing key. Reader
    /// messages from any other sender are dropped: every extension shares
    /// the one bridge, and a page-installed extension must not be able to
    /// light the reader button or flip tab state.
    static let extensionId = "ickhcgejficcoofnjnnobadfdnfbilnm"

    private struct OfferablePayload: Decodable {
        let tabId: Int
        let offerable: Bool
        /// The document the verdict is about, so the tab can hold the grant
        /// exactly as long as it stays on that URL.
        let url: String?
    }

    private struct StatePayload: Decodable {
        let tabId: Int
        let active: Bool
        /// The extractor's refusal reason when an open request produced no
        /// article; mirrored into the same toast the native reader shows.
        let error: String?
    }

    /// The style wire format shared with the extension's `style.ts`. Field
    /// names and axis raw values match the Swift enums; the extension maps
    /// `matchBrowser` to its "follow the browser appearance" state.
    private struct WireStyle: Codable {
        var fontSize: Int
        var width: String
        var theme: String
        var typeface: String
        var lineHeight: String
        var letterSpacing: String
        var showsImages: Bool
        var highlightsLinks: Bool
    }

    /// The article URL a reader page stands in for, recovered from the `src`
    /// fragment parameter the extension appends when it navigates a tab to
    /// `reader.html` (`readerPageUrl` in the extension's background script).
    /// Anything else — including a reader page from an extension build
    /// without the parameter — returns nil.
    static func sourceURLString(fromReaderPageURL urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              components.scheme == "chrome-extension",
              components.host == extensionId,
              components.path == "/reader.html",
              let fragment = components.percentEncodedFragment else { return nil }
        for pair in fragment.split(separator: "&") where pair.hasPrefix("src=") {
            return String(pair.dropFirst("src=".count)).removingPercentEncoding
        }
        return nil
    }

    /// `reader.offerable`: the extension's in-page probe verdict for a tab's
    /// current document.
    static func handleOfferable(_ context: ExtensionMessageContext) {
        guard context.senderId == extensionId else {
            AppLogDebug("[Reader] offerable dropped: sender=\(context.senderId)")
            return
        }
        guard let payload: OfferablePayload = decode(context.payload) else {
            AppLogDebug("[Reader] offerable dropped: bad payload \(context.payload)")
            return
        }
        guard payload.offerable else { return }
        MainActor.assumeIsolated {
            guard let found = findTab(payload.tabId) else {
                AppLogDebug("[Reader] offerable: no tab for id \(payload.tabId)")
                return
            }
            AppLogDebug("[Reader] offerable granted tab=\(payload.tabId)")
            found.tab.noteExtensionReaderOfferable(forURLString: payload.url)
        }
    }

    /// `reader.state`: the extension's surface mounted or left a tab. An
    /// inactive report carrying an error is a refused open — surface the
    /// same toast the native reader shows for its own refusals.
    static func handleState(_ context: ExtensionMessageContext) {
        guard context.senderId == extensionId else { return }
        guard let payload: StatePayload = decode(context.payload) else { return }
        MainActor.assumeIsolated {
            guard let (tab, state) = findTab(payload.tabId) else { return }
            let wasActive = tab.extensionReaderActive
            tab.extensionReaderActive = payload.active
            if payload.active, !wasActive {
                ReaderViewAnalytics.surfaceMounted(tabId: payload.tabId)
            }
            guard !payload.active, let error = payload.error else { return }
            ReaderViewAnalytics.openRefused(tabId: payload.tabId, reason: error)
            let title: String
            switch error {
            case "no_article_detected", "below_coverage_floor":
                title = NSLocalizedString(
                    "browser.readerView.noArticleFound",
                    value: "No article found on this page",
                    comment: "Reader View - Toast shown when the page has no article content to display")
            default:
                title = NSLocalizedString(
                    "browser.readerView.unavailable",
                    value: "Reader View is unavailable on this page",
                    comment: "Reader View - Toast shown when reader extraction could not run at all")
            }
            OverlayToastCenter.shared.show(title: title, in: state)
        }
    }

    /// `reader.getStyle`: the extension reader page mounting; returns the
    /// native style so both surfaces read from one preference store.
    static func handleGetStyle(_ context: ExtensionMessageContext) -> String? {
        guard context.senderId == extensionId else { return "{}" }
        return MainActor.assumeIsolated { encodeCurrentStyle() } ?? "{}"
    }

    /// `reader.setStyle`: a control on the extension surface changed an
    /// axis. Persisted through `PhiPreferences.Reader` and echoed to every
    /// reader page so multiple reader tabs stay in agreement.
    static func handleSetStyle(_ context: ExtensionMessageContext) {
        guard context.senderId == extensionId else { return }
        guard let style: WireStyle = decode(context.payload) else { return }
        MainActor.assumeIsolated {
            PhiPreferences.Reader.fontSize = style.fontSize
            if let width = ReaderStyle.Width(rawValue: style.width) {
                PhiPreferences.Reader.width = width
            }
            if let theme = ReaderStyle.Theme(rawValue: style.theme) {
                PhiPreferences.Reader.theme = theme
            }
            if let typeface = ReaderStyle.Typeface(rawValue: style.typeface) {
                PhiPreferences.Reader.typeface = typeface
            }
            if let lineHeight = ReaderStyle.LineHeight(rawValue: style.lineHeight) {
                PhiPreferences.Reader.lineHeight = lineHeight
            }
            if let spacing = ReaderStyle.LetterSpacing(rawValue: style.letterSpacing) {
                PhiPreferences.Reader.letterSpacing = spacing
            }
            PhiPreferences.Reader.showsImages = style.showsImages
            PhiPreferences.Reader.highlightsLinks = style.highlightsLinks
            if let json = encodeCurrentStyle() {
                ExtensionMessaging.shared.broadcast(
                    type: "reader.styleChanged", payload: json)
            }
        }
    }

    @MainActor
    private static func encodeCurrentStyle() -> String? {
        let style = ReaderStyle.current
        let wire = WireStyle(
            fontSize: style.fontSize,
            width: style.width.rawValue,
            theme: style.theme.rawValue,
            typeface: style.typeface.rawValue,
            lineHeight: style.lineHeight.rawValue,
            letterSpacing: style.letterSpacing.rawValue,
            showsImages: style.showsImages,
            highlightsLinks: style.highlightsLinks)
        guard let data = try? JSONEncoder().encode(wire) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Extraction RPC

    /// An accepted extraction, with which site rule (if any) produced it —
    /// the single most useful diagnostic when working out why a site
    /// extracted the way it did.
    struct ExtractOutcome {
        let article: ReaderArticle
        let ruleHost: String?
    }

    /// The `reader.extractResult` wire format (`ExtractResultReport` on the
    /// extension side).
    private struct ExtractResult: Decodable {
        let requestId: String
        let ok: Bool
        let article: WireArticle?
        let ruleHost: String?
        let error: String?
        let bestCoverage: Double?
    }

    /// The extension's `ExtractedArticle` shape.
    private struct WireArticle: Decodable {
        let sourceUrl: String
        let title: String
        let byline: String?
        let siteName: String?
        let lang: String?
        let contentHtml: String
        let rung: String
        let coverage: Double
        let codeBlocks: [String]
    }

    /// In-flight `reader.extract` requests, keyed by the requestId the
    /// extension echoes back. Broadcast out, report back — the bridge has no
    /// app-to-extension request channel, so the RPC is correlated by id and
    /// bounded by a timeout that resolves to `transport_unavailable` (the
    /// shape an unloaded extension produces: silence).
    @MainActor
    private static var pendingExtractions:
        [String: CheckedContinuation<ExtractResult, Never>] = [:]

    /// Extracts a tab's article through the extension without changing what
    /// the tab shows. `settle` walks the page for lazy content first —
    /// callers with no user watching the tab only (the agent API).
    @MainActor
    static func extractArticle(from tab: Tab,
                               settle: Bool = true,
                               timeout: TimeInterval = 45) async throws -> ExtractOutcome {
        let requestId = UUID().uuidString
        ExtensionMessaging.shared.broadcast(
            type: "reader.extract",
            payload: "{\"tabId\":\(tab.guid),\"requestId\":\"\(requestId)\"," +
                     "\"settle\":\(settle)}")
        let result: ExtractResult = await withCheckedContinuation { continuation in
            pendingExtractions[requestId] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                pendingExtractions.removeValue(forKey: requestId)?
                    .resume(returning: ExtractResult(
                        requestId: requestId, ok: false, article: nil,
                        ruleHost: nil, error: "transport_unavailable",
                        bestCoverage: nil))
            }
        }
        guard result.ok, let wire = result.article else {
            switch result.error {
            case "no_article_detected":
                throw ReaderExtractionError.noArticleDetected
            case "below_coverage_floor":
                throw ReaderExtractionError.belowCoverageFloor(
                    best: result.bestCoverage ?? 0)
            case "no_target":
                throw ReaderExtractionError.noTarget
            case "transport_unavailable":
                throw ReaderExtractionError.transportUnavailable
            default:
                throw ReaderExtractionError.failed(
                    result.error ?? "extraction_failed")
            }
        }
        let article = ReaderArticle(
            title: wire.title,
            byline: wire.byline,
            siteName: wire.siteName,
            lang: wire.lang,
            contentHTML: wire.contentHtml,
            sourceURL: wire.sourceUrl,
            rung: wire.rung,
            coverage: wire.coverage,
            codeBlocks: wire.codeBlocks)
        return ExtractOutcome(article: article, ruleHost: result.ruleHost)
    }

    /// `reader.extractResult`: the reply to an extraction request.
    static func handleExtractResult(_ context: ExtensionMessageContext) {
        guard context.senderId == extensionId else { return }
        guard let result: ExtractResult = decode(context.payload) else { return }
        MainActor.assumeIsolated {
            pendingExtractions.removeValue(forKey: result.requestId)?
                .resume(returning: result)
        }
    }

    @MainActor
    static func open(_ tab: Tab) {
        ExtensionMessaging.shared.broadcast(
            type: "reader.open", payload: "{\"tabId\":\(tab.guid)}")
    }

    @MainActor
    static func close(_ tab: Tab) {
        ExtensionMessaging.shared.broadcast(
            type: "reader.close", payload: "{\"tabId\":\(tab.guid)}")
    }

    private static func decode<T: Decodable>(_ payload: String) -> T? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The extension speaks in Chromium tab ids, which is what `Tab.guid`
    /// holds; the tab can be in any window.
    @MainActor
    private static func findTab(_ tabId: Int) -> (tab: Tab, state: BrowserState)? {
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            let state = controller.browserState
            if let tab = state.tabs.first(where: { $0.guid == tabId }) {
                return (tab, state)
            }
        }
        return nil
    }
}
