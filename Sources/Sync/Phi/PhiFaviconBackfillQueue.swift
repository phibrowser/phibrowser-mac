// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Darwin
import Dispatch
import Foundation

// MARK: - Boundaries

/// Favicon fetch boundary (M3-3 §8.2 / plan ruling V32). Do not reuse ProfileScopedFaviconFetching: its
/// private MainActor production implementation is inaccessible to the engine actor. PhiFaviconFetcher is a
/// small MainActor bridge wrapper; the queue retains only this protocol.
@MainActor
protocol PhiFaviconFetching: AnyObject {
    /// Step 1 queries Chromium's history-backed favicon service, which returns bytes only for URLs actually
    /// visited in that Profile; nil is normal. The caller imposes a deadline because the bridge continuation
    /// may never receive a callback, otherwise blocking drainOnce on the serialized engine queue.
    func chromiumFavicon(profileId: String, pageURL: URL) async -> Data?

    /// Step 2 fetches over the network after caller-side PhiFaviconHostFilter checks. The implementation must
    /// recheck each redirect and enforce size limits; redirect hops are invisible to the caller.
    func networkFavicon(at url: URL) async throws -> Data

    /// Cancel all in-flight fetches and permanently retire this fetcher (§8.3: cancel queue and discard
    /// unfinished items on engine retirement). Queue stop calls this once.
    func cancelAll()
}

/// Narrow backfill-only write boundary. Favicon is deliberately not an ApplyOp: it is absent from snapshots
/// and must not enter phase sorting, landing transactions or §5.7 deduplication fields. Both bookmark/pin
/// access protocols refine this; two production implementations and two fakes implement it. The queue needs
/// neither snapshot reads nor general apply access.
@MainActor
protocol PhiFaviconWriting: AnyObject {
    /// Combine the round's writes into one background transaction. Throw means none persisted.
    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws
}

/// Sink for backfill counts, enabling tests to capture log lines and verify R12: counts/success rates only,
/// never hosts.
@MainActor
protocol PhiFaviconLogSink: AnyObject {
    func record(_ line: String)
}

/// Production sink forwards to AppLogInfo.
@MainActor
final class PhiFaviconAppLogSink: PhiFaviconLogSink {
    func record(_ line: String) { AppLogInfo(line) }
}

/// Step-2 failure categories contain metadata only (status codes/enums), safe to log under R12.
enum PhiFaviconFetchError: Error, Equatable {
    /// This hop's scheme or host fails the filter.
    case blockedHost
    /// More than three redirects.
    case tooManyRedirects
    /// Response exceeds 64 KiB.
    case tooLarge
    /// The row exhausted its 5 s budget.
    case timedOut
    case badStatus(Int)
    /// Bytes arrived but NSImage cannot decode them.
    case notAnImage
}

// MARK: - Host filter

/// Whether a URL may be requested. Recheck every redirect: validating only the first hop permits a 302 into
/// loopback (SSRF; CASE 10.6). Require HTTP(S), a nonempty host, no localhost/.local names, and no numeric IP
/// literal in any notation.
///
/// Reject all numeric literals rather than manually matching private ranges. getaddrinfo accepts expanded IPv6
/// loopback, IPv4-mapped hex forms, octal and integer IPv4 representations that evade simple string checks.
/// Bookmark favicon hosts should be DNS names, so numeric hosts have no legitimate purpose here. Use
/// inet_pton/inet_aton, matching the underlying network parsers.
enum PhiFaviconHostFilter {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let rawHost = url.host, !rawHost.isEmpty else { return false }
        // Some APIs return bracketed IPv6 hosts and others do not.
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        // mDNS .local resolves on the local link; requesting it broadcasts on the current Wi-Fi.
        if host == "local" || host.hasSuffix(".local") { return false }
        if isNumericIPLiteral(host) { return false }
        return true
    }

    /// Detect numeric IP literals in every accepted notation. inet_pton(AF_INET6) handles expanded/mapped
    /// IPv6; inet_pton(AF_INET) handles strict dotted decimal; inet_aton also accepts octal 0177.0.0.1, hex
    /// 0x7f.0.0.1, abbreviated 127.1 and integer 2130706433. getaddrinfo accepts those too, so omitting the
    /// last check would permit bypasses.
    private static func isNumericIPLiteral(_ host: String) -> Bool {
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        if inet_aton(host, &v4) == 1 { return true }
        return false
    }
}

// MARK: - Queue

/// Bounded favicon backfill at each round's end (§8.2). It changes no cursors/baselines and triggers no
/// pushes: favicon is excluded from §5.7 value snapshots, making writes invisible to sync state.
///
/// Bounds and serial requests protect privacy: fetching hundreds of imported bookmark hosts or concurrent
/// bursts would expose browsing interests as an observable scan. Each row shares one 5 s budget across both
/// steps and retry; the entire round budget is 20 × 5 s with no second budget (§8.2). drainOnce occupies the
/// engine roundQueue while awaited, directly delaying settings sync and Space intents.
///
/// Failed writeback permanently discards fetched icons because rows leave pending when dequeued. This is
/// intentional best-effort decoration: requeueing would repeatedly refetch from a persistently failing store.
/// The failed counter exposes discarded work.
@MainActor
final class PhiFaviconBackfillQueue {
    /// Maximum rows fetched per round.
    static let maxRowsPerRound = 20
    /// Per-response byte limit, enforced while downloading.
    static let maxBytes = 65_536
    /// Total budget per row across both fetch steps and retry; timeouts count as failed.
    static let perItemTimeout: TimeInterval = 5
    /// History lookup's sub-budget must be strictly less than perItemTimeout. A slow bridge consuming all 5 s
    /// would starve network fallback entirely; withDeadline would not even start it and the row is never
    /// requeued. Logs would misleadingly show from_network=0, just like complete history coverage.
    static let historyLookupTimeout: TimeInterval = 1
    /// Maximum redirect hops.
    static let maxRedirects = 3
    /// Queue depth cap. Drop new rows beyond it: best-effort decoration must not enqueue an unbounded imported
    /// tree.
    static let maxQueueDepth = 500

    /// Common row projection for both kinds: writeback GUID, page URL, history Profile and destination
    /// accessor are all backfill needs.
    private struct Row {
        var guid: String
        var url: URL
        var profileId: String
        var isPin: Bool
    }

    /// Fetched bytes and source step, for §11.3 from_history/from_network counts.
    private struct Fetched {
        var data: Data
        var fromHistory: Bool
    }

    /// Per-row deadline uses monotonic DispatchTime, unaffected by system-clock changes.
    private struct Deadline {
        private let end: DispatchTime

        init(seconds: TimeInterval) {
            end = DispatchTime.now() + seconds
        }

        /// Remaining nanoseconds, or 0 after expiration.
        var remainingNanoseconds: UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            let end = self.end.uptimeNanoseconds
            return end > now ? end - now : 0
        }

        var isExpired: Bool { remainingNanoseconds == 0 }
    }

    private let fetcher: any PhiFaviconFetching
    /// Bookmark writeback accessor.
    private let access: any PhiFaviconWriting
    /// Pin writeback accessor; nil means this queue does not accept pins.
    private let pinAccess: (any PhiFaviconWriting)?
    private let defaultFaviconGate: (URL) -> Bool
    private let logSink: any PhiFaviconLogSink

    private var pending: [Row] = []
    /// Queued GUIDs for deduplication: landing the same row in adjacent rounds must not make a duplicate host
    /// request.
    private var queuedGuids: Set<String> = []

    /// Retirement flag in a locked box, not actor state, like PhiSyncEngine.StopSignal: nonisolated shutdown
    /// must take effect synchronously without an actor hop.
    private final class StopSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private let stopSignal = StopSignal()
    private var isStopped: Bool { stopSignal.isStopped }

    init(fetcher: any PhiFaviconFetching,
         access: any PhiFaviconWriting,
         pinAccess: (any PhiFaviconWriting)? = nil,
         defaultFaviconGate: @escaping (URL) -> Bool =
            FaviconConfiguration.shouldUseDefaultFavicon(for:),
         logSink: any PhiFaviconLogSink) {
        self.fetcher = fetcher
        self.access = access
        self.pinAccess = pinAccess
        self.defaultFaviconGate = defaultFaviconGate
        self.logSink = logSink
    }

    /// Shares the engine lifecycle; shutdown calls stop, making later enqueue/drain no-ops. Nonisolated
    /// synchronous flag-setting lets main-thread account exit proceed immediately. Schedule
    /// cleanup/discard/cancel on the main actor; the flag, not cleanup timing, blocks new work.
    ///
    /// Strongly capture self for cleanup: the coordinator releases the engine shortly after shutdown, and it
    /// is the queue's only owner. A weak capture could deallocate before invalidateAndCancel runs, leaking the
    /// ephemeral session/connection pool. The task ends promptly, so no lasting cycle.
    nonisolated func stop() {
        stopSignal.stop()
        Task { @MainActor [self] in self.discardAndCancel() }
    }

    /// Enqueue newly landed bookmarks, never folders: their placeholder https://bookmark.phi/folder would
    /// create an unwanted request.
    func enqueue(_ rows: [PhiLocalBookmark]) {
        appendRows(rows.lazy.filter { !$0.isFolder }.map {
            Row(guid: $0.guid, url: $0.url, profileId: $0.profileId, isPin: false)
        })
    }

    /// Enqueue newly landed pins as required by §8.2, excluding dormant rows.
    func enqueue(_ rows: [PhiLocalPin]) {
        appendRows(rows.lazy.filter { !$0.isDormant }.map {
            Row(guid: $0.guid,
                url: $0.url,
                profileId: $0.profileId ?? LocalStore.defaultProfileId,
                isPin: true)
        })
    }

    /// Drain one round: at most 20 rows serially and one writeback per kind. Return per-round, not cumulative
    /// counts. attempted excludes step-0 skips; succeeded + failed == attempted.
    @discardableResult
    func drainOnce() async -> (attempted: Int, succeeded: Int, failed: Int) {
        guard !isStopped else { return (0, 0, 0) }
        let startedAt = DispatchTime.now()
        var taken = 0
        var attempted = 0
        var succeeded = 0
        var failed = 0
        var fromHistory = 0
        var fromNetwork = 0
        var bookmarkWrites: [(guid: String, data: Data)] = []
        var pinWrites: [(guid: String, data: Data)] = []

        while taken < Self.maxRowsPerRound, !pending.isEmpty {
            guard !isStopped else { break }
            let row = pending.removeFirst()
            queuedGuids.remove(row.guid)
            taken += 1
            // Step 0: internal pages use default icons; skip both fetch steps.
            if defaultFaviconGate(row.url) { continue }
            attempted += 1
            guard let fetched = await resolve(row) else {
                failed += 1
                continue
            }
            succeeded += 1
            if fetched.fromHistory { fromHistory += 1 } else { fromNetwork += 1 }
            if row.isPin {
                pinWrites.append((guid: row.guid, data: fetched.data))
            } else {
                bookmarkWrites.append((guid: row.guid, data: fetched.data))
            }
        }

        // One writeback per kind for the entire round (CASE 10.11). Separate accessors still yield just one
        // write for bookmark-only batches.
        var lost = 0
        if isStopped {
            // Never persist bytes fetched during retirement; the store is being dismantled.
            lost = bookmarkWrites.count + pinWrites.count
        } else {
            lost = await writeBack(bookmarkWrites, to: access)
            if let pinAccess {
                lost += await writeBack(pinWrites, to: pinAccess)
            } else {
                lost += pinWrites.count
            }
        }
        succeeded -= lost
        failed += lost

        // §11.3 diagnostic: counts and elapsed time only, no hosts, URLs or titles (R12).
        // from_history/from_network report where bytes came from, independent of writeback success: §8.3's
        // privacy signal is whether third-party requests happened, which failed persistence must not erase.
        if taken > 0 {
            let elapsedMs =
                (DispatchTime.now().uptimeNanoseconds &- startedAt.uptimeNanoseconds) / 1_000_000
            logSink.record("[phi-sync] favicon backfill: queued=\(taken) "
                           + "from_history=\(fromHistory) from_network=\(fromNetwork) "
                           + "failed=\(failed) ms=\(elapsedMs) "
                           + "attempted=\(attempted) skipped=\(taken - attempted) "
                           + "remaining=\(pending.count)")
        }
        return (attempted, succeeded, failed)
    }

    // MARK: - Private helpers

    private func appendRows<S: Sequence>(_ rows: S) where S.Element == Row {
        guard !isStopped else { return }
        for row in rows {
            guard pending.count < Self.maxQueueDepth else { return }
            guard !queuedGuids.contains(row.guid) else { continue }
            queuedGuids.insert(row.guid)
            pending.append(row)
        }
    }

    /// §8.3: discard unfinished items and cancel in-flight fetches.
    private func discardAndCancel() {
        pending = []
        queuedGuids = []
        fetcher.cancelAll()
    }

    /// Write one batch; return the number not persisted. A throw means the entire batch failed.
    private func writeBack(_ writes: [(guid: String, data: Data)],
                           to sink: any PhiFaviconWriting) async -> Int {
        guard !writes.isEmpty else { return 0 }
        do {
            try await sink.setFavicon(writes)
            return 0
        } catch {
            logSink.record("[phi-sync] favicon backfill write failed count=\(writes.count) "
                           + "(\(PhiSyncLog.describe(error)))")
            return writes.count
        }
    }

    /// Both fetch steps share one 5 s row budget. Nil means failure.
    private func resolve(_ row: Row) async -> Fetched? {
        let deadline = Deadline(seconds: Self.perItemTimeout)
        let fetcher = self.fetcher
        let profileId = row.profileId
        let pageURL = row.url

        // Step 1 uses Chromium history, usually absent for newly landed URLs but avoiding network requests
        // when available. Apply the smaller of history's sub-budget and the row's remaining total budget,
        // preserving time for network fallback.
        //
        // Deadlines only signal timeout; PhiFaviconFetcher.chromiumFavicon must respond to cancellation
        // through its handler. Task groups await children, so an unresponsive continuation would still block
        // drainOnce and the engine queue regardless of timer layers.
        let historyDeadline = Deadline(seconds: min(Self.historyLookupTimeout,
                                                    Self.perItemTimeout))
        let historical = (try? await withDeadline(historyDeadline) {
            await fetcher.chromiumFavicon(profileId: profileId, pageURL: pageURL)
        }) ?? nil
        if let data = historical, accepts(data) {
            return Fetched(data: data, fromHistory: true)
        }
        guard !isStopped, let target = Self.faviconURL(for: row.url) else { return nil }

        // Step 2: HTTPS host favicon.ico with at most one retry. Retry consumes the same remaining budget,
        // never a fresh 5 s; otherwise worst-case row/round time doubles to 10/200 s.
        for attempt in 0...1 {
            guard !isStopped, !deadline.isExpired else { return nil }
            do {
                let data = try await withDeadline(deadline) {
                    try await fetcher.networkFavicon(at: target)
                }
                // Do not retry undecodable bytes: the same host would likely return the same HTML again (CASE
                // 10.9), which UI would try to decode as an image.
                return accepts(data) ? Fetched(data: data, fromHistory: false) : nil
            } catch {
                if attempt == 1 { return nil }
            }
        }
        return nil
    }

    /// Race one fetch against the row's remaining budget; if exhausted, time out without starting it.
    private func withDeadline<T: Sendable>(
        _ deadline: Deadline,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let remaining = deadline.remainingNanoseconds
        guard remaining > 0 else { throw PhiFaviconFetchError.timedOut }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: remaining)
                throw PhiFaviconFetchError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PhiFaviconFetchError.timedOut }
            return first
        }
    }

    /// Accept only nonempty, size-bounded bytes NSImage can decode. Size validation is a backup guard:
    /// production must stop mid-stream, but this also prevents oversized persistence after a fetcher
    /// regression.
    private func accepts(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= Self.maxBytes else { return false }
        return NSImage(data: data) != nil
    }

    /// Construct HTTPS-only https://host/favicon.ico without a port. Filter both the source page URL and
    /// resulting request URL.
    static func faviconURL(for pageURL: URL) -> URL? {
        guard PhiFaviconHostFilter.allows(pageURL), let host = pageURL.host else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/favicon.ico"
        guard let url = components.url, PhiFaviconHostFilter.allows(url) else { return nil }
        return url
    }
}

// MARK: - Production fetcher

/// Production fetcher uses Chromium bridge for history and an ephemeral URLSession for network. Disable
/// cookies, credentials and cache so backfill carries no browser-session identity.
@MainActor
final class PhiFaviconFetcher: PhiFaviconFetching {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = PhiFaviconBackfillQueue.perItemTimeout
        configuration.timeoutIntervalForResource = PhiFaviconBackfillQueue.perItemTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: configuration)
    }

    /// §8.3: invalidateAndCancel on retirement, not merely task cancellation. A URLSession may outlive its
    /// owner and retain its connection pool unless invalidated. The fetcher is intentionally unusable
    /// afterward, matching stop semantics.
    func cancelAll() {
        session.invalidateAndCancel()
    }

    /// Must respond to cancellation: task groups wait for children, so a bare continuation with a lost bridge
    /// callback would permanently block withDeadline, drainOnce and serialized sync. stop's between-row flag
    /// cannot release it. Use a cancellation handler plus a one-shot mailbox: callback/cancellation race, and
    /// only the first resumes the continuation.
    func chromiumFavicon(profileId: String, pageURL: URL) async -> Data? {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return nil }
        let urlString = pageURL.absoluteString
        let box = ContinuationBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                box.arm(continuation)
                bridge.getFaviconForURL(urlString, profileId: profileId) { data in
                    box.settle(with: data)
                }
            }
        } onCancel: {
            box.settle(with: nil)
        }
    }

    /// Exactly-once continuation mailbox. Arming, bridge callback and cancellation may arrive in any order on
    /// different threads. Already-canceled tasks can run the handler before operation, so retain an early
    /// result until arm rather than losing it and hanging.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var settled = false
        private var earlyResult: Data?
        private var hasEarlyResult = false

        /// Install the continuation and immediately deliver any earlier result.
        func arm(_ continuation: CheckedContinuation<Data?, Never>) {
            lock.lock()
            guard !settled else {
                lock.unlock()
                return
            }
            if hasEarlyResult {
                let result = earlyResult
                settled = true
                hasEarlyResult = false
                earlyResult = nil
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        /// The first event settles; ignore all later events.
        func settle(with data: Data?) {
            lock.lock()
            guard !settled else {
                lock.unlock()
                return
            }
            guard let continuation else {
                // Continuation not armed yet: retain the result for arm.
                hasEarlyResult = true
                earlyResult = data
                lock.unlock()
                return
            }
            settled = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: data)
        }
    }

    /// Count bytes while streaming with URLSession.bytes(for:), canceling immediately beyond 64 KiB. Checking
    /// only after download permits an unbounded response without Content-Length to exhaust memory.
    func networkFavicon(at url: URL) async throws -> Data {
        guard PhiFaviconHostFilter.allows(url) else { throw PhiFaviconFetchError.blockedHost }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = PhiFaviconBackfillQueue.perItemTimeout

        // One redirect guard per request: hop count is request-local, not shared delegate state.
        let guardDelegate = RedirectGuard(maxRedirects: PhiFaviconBackfillQueue.maxRedirects)
        let (stream, response) = try await session.bytes(for: request, delegate: guardDelegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            stream.task.cancel()
            throw PhiFaviconFetchError.badStatus(http.statusCode)
        }
        return try await Self.readBounded(stream, limit: PhiFaviconBackfillQueue.maxBytes)
    }

    /// Bounded reading is nonisolated to keep tens of thousands of async byte iterations for a 64 KiB response
    /// off the main actor.
    private nonisolated static func readBounded(_ stream: URLSession.AsyncBytes,
                                                limit: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(4096)
        for try await byte in stream {
            data.append(byte)
            if data.count > limit {
                stream.task.cancel()
                throw PhiFaviconFetchError.tooLarge
            }
        }
        return data
    }

    /// Recheck the filter and hop limit for every redirect. Returning nil refuses the hop, leaving the 3xx
    /// response for the badStatus check above. Protect hop count with a lock: URLSession delegate callbacks
    /// use its queue and the protocol requires Sendable. Per-request serialization alone does not express that
    /// guarantee to the type system.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let maxRedirects: Int
        private let lock = NSLock()
        private var hops = 0

        init(maxRedirects: Int) {
            self.maxRedirects = maxRedirects
        }

        /// Increment hop count and return the new value.
        private func nextHop() -> Int {
            lock.lock()
            defer { lock.unlock() }
            hops += 1
            return hops
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            let hop = nextHop()
            guard hop <= maxRedirects,
                  let url = request.url,
                  PhiFaviconHostFilter.allows(url) else {
                completionHandler(nil)
                return
            }
            var next = request
            next.httpShouldHandleCookies = false
            completionHandler(next)
        }
    }
}
