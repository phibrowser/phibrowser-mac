// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// One row of the floating history panel.
struct HistoryPanelEntry: Identifiable, Equatable {
    let url: String
    let title: String
    let domain: String
    let time: Date
    /// Chromium's localized time of day ("4:53 PM").
    let timeOfDay: String
    /// The letter Chromium draws when a page has no favicon.
    let fallbackLetter: String

    var id: String { "\(url)|\(time.timeIntervalSince1970)" }
}

/// Reads the profile's browsing history for the floating history panel
/// (`HistoryPanelController`).
///
/// Phi Framework publishes no history query, and the History SQLite file is
/// held under an exclusive lock while the browser runs. So this keeps one
/// hidden, detached `chrome://history` WebContents (never in a tab strip) and
/// asks that page's own history handler over the app's in-process CDP session
/// (`AppDevToolsPageSession`): no port, no listener, nothing reachable from
/// outside. Queries are serialized, because a session runs one command at a
/// time. Favicons come from the profile's favicon database over the bridge.
///
/// One instance per browser window (the window's profile), from
/// `service(windowId:profileId:)`. It stays warm between panel openings, so
/// reopening (also after switching apps) is instant, and releases its hidden
/// page after `idleRelease` without use, or at once when the window closes.
@MainActor
final class HistoryPanelService {
    private static var services: [Int64: HistoryPanelService] = [:]
    private static let idleRelease: TimeInterval = 600

    static func service(windowId: Int64, profileId: String) -> HistoryPanelService {
        if let existing = services[windowId], existing.profileId == profileId {
            existing.releaseWork?.cancel()
            existing.releaseWork = nil
            return existing
        }
        services[windowId]?.close()
        let service = HistoryPanelService(windowId: windowId, profileId: profileId)
        services[windowId] = service
        return service
    }

    /// Releases the window's service now (the window closed).
    static func release(windowId: Int64) {
        services.removeValue(forKey: windowId)?.close()
    }

    /// Keeps the service for `idleRelease`, then releases its hidden page.
    func scheduleRelease() {
        releaseWork?.cancel()
        let work = DispatchWorkItem { [windowId] in
            MainActor.assumeIsolated { Self.release(windowId: windowId) }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleRelease, execute: work)
    }

    private var releaseWork: DispatchWorkItem?
    /// The panel's opening view (no search, its default range) from the last
    /// time it was shown, painted at once on the next open while it refreshes.
    var lastOpeningResults: [HistoryPanelEntry]?

    private let windowId: Int64
    private let profileId: String
    private var wrapper: (any WebContentWrapper)?
    private var session: AppDevToolsPageSession?
    private var tail: Task<Void, Never>?
    private let favicons = NSCache<NSString, NSImage>()
    private var faviconWaiters: [String: [(NSImage?) -> Void]] = [:]

    private init(windowId: Int64, profileId: String) {
        self.windowId = windowId
        self.profileId = profileId
        favicons.countLimit = 600
    }

    func close() {
        session?.close()
        session = nil
        wrapper?.close()
        wrapper = nil
    }

    // MARK: History

    /// History matching `text` (all history when empty), newest first, at
    /// most `limit` rows, optionally only visits since `since`.
    func query(_ text: String, since: Date?, limit: Int) async -> [HistoryPanelEntry] {
        await serialized { [weak self] in
            guard let self else { return [] }
            for attempt in 0..<2 {
                guard let session = await self.openSessionIfNeeded() else { return [] }
                do {
                    return try await self.runQuery(text, since: since, limit: limit, on: session)
                } catch {
                    AppLogWarn("[HistoryPanel] query failed (attempt \(attempt + 1)): \(error)")
                    // The hidden page or its session went away; start over once.
                    self.close()
                }
            }
            return []
        }
    }

    private func runQuery(_ text: String, since: Date?, limit: Int,
                          on session: AppDevToolsPageSession) async throws -> [HistoryPanelEntry] {
        let textLiteral = String(data: try JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let begin = since.map { String(format: "%.0f", $0.timeIntervalSince1970 * 1000) } ?? "null"
        let script = """
        (async()=>{const m=await import('chrome://history/history.js');\
        const h=m.BrowserProxyImpl.getInstance().handler;\
        const r=await h.queryHistory(\(textLiteral),\(max(1, limit)),\(begin),true,true);\
        return r.results.value.map(e=>[e.url,e.title,e.domain,e.time,e.dateTimeOfDay,e.fallbackFaviconText]);})()
        """
        let reply = try await session.command("Runtime.evaluate", params: [
            "expression": script, "awaitPromise": true, "returnByValue": true
        ], timeout: 10)
        if let exception = reply["exceptionDetails"] {
            throw AppDevToolsPageSession.SessionError.commandFailed("\(exception)")
        }
        guard let rows = (reply["result"] as? [String: Any])?["value"] as? [[Any]] else { return [] }
        let cutoff = since ?? .distantPast
        return rows.compactMap { row in
            guard row.count >= 6, let url = row[0] as? String,
                  let millis = (row[3] as? NSNumber)?.doubleValue else { return nil }
            let time = Date(timeIntervalSince1970: millis / 1000)
            guard time >= cutoff else { return nil }
            let title = (row[1] as? String) ?? ""
            return HistoryPanelEntry(
                url: url,
                title: title.isEmpty ? url : title,
                domain: (row[2] as? String) ?? "",
                time: time,
                timeOfDay: (row[4] as? String) ?? "",
                fallbackLetter: (row[5] as? String) ?? ""
            )
        }
    }

    private func openSessionIfNeeded() async -> AppDevToolsPageSession? {
        if let session { return session }
        if wrapper == nil {
            wrapper = ChromiumLauncher.sharedInstance().bridge?
                .newWebContents(forUrl: "chrome://history/", windowId: windowId)
        }
        guard let wrapper else { return nil }
        // The target id appears with the page; a fresh contents takes a few
        // hundred milliseconds.
        for _ in 0..<60 where wrapper.devToolsTargetId == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let targetId = wrapper.devToolsTargetId,
              let session = try? await AppDevToolsPageSession.open(targetId: targetId) else {
            AppLogWarn("[HistoryPanel] could not open a session on the history page")
            return nil
        }
        self.session = session
        return session
    }

    /// Runs `operation` after every operation queued before it.
    private func serialized<T>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Favicons

    func cachedFavicon(for url: String) -> NSImage? {
        favicons.object(forKey: url as NSString)
    }

    /// Calls back on the main thread, at most once, with the page's favicon.
    /// The bridge may drop a request when the profile shuts down; then the
    /// callback never runs, which only leaves the fallback letter showing.
    func loadFavicon(for url: String, completion: @escaping (NSImage?) -> Void) {
        if let image = favicons.object(forKey: url as NSString) {
            completion(image)
            return
        }
        if faviconWaiters[url] != nil {
            faviconWaiters[url]?.append(completion)
            return
        }
        faviconWaiters[url] = [completion]
        ChromiumLauncher.sharedInstance().bridge?.getFaviconForURL(url, profileId: profileId) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                let image = data.flatMap(NSImage.init(data:))
                if let image { self.favicons.setObject(image, forKey: url as NSString) }
                let waiters = self.faviconWaiters.removeValue(forKey: url) ?? []
                waiters.forEach { $0(image) }
            }
        }
    }
}
