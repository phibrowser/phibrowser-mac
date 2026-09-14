// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

// MARK: - 接缝

/// 回填队列的取图接缝（M3-3 §8.2 / 计划裁定 V32）。
///
/// **不复用 `ProfileScopedFaviconFetching`**：它的生产实现
/// `ChromiumBridgeProfileScopedFaviconFetcher`（`FaviconDataProvider.swift`）是 `private`
/// 且 `@MainActor`，引擎那个非 MainActor 的 actor 既拿不到也造不出它。这里的生产实现是
/// `PhiFaviconFetcher`——一个 `@MainActor` 小类，它内部再去够 bridge，而队列持有的只是
/// 这个协议。
@MainActor
protocol PhiFaviconFetching: AnyObject {
    /// 第 1 步：问 Chromium 的 history-backed favicon 服务。它只对该 Profile **真正访问
    /// 过**的 URL 返回字节，所以答 nil 是常态，不是错误。
    func chromiumFavicon(profileId: String, pageURL: URL) async -> Data?

    /// 第 2 步：网络取图。**调用方已经过完过滤表**（`PhiFaviconHostFilter`），实现负责
    /// 逐跳重过与大小上限——重定向发生在实现内部，调用方看不见那些跳。
    func networkFavicon(at url: URL) async throws -> Data
}

/// 回填专用的**窄写入口**。
///
/// **刻意不做成 `…ApplyOp` 的一个 case**：favicon 不在快照里，它的写入不该经过三相排序、
/// 不该与同步落地共用事务，也不该让 §5.7 的值快照去重多认一个字段。
///
/// 两个归属 access 协议（`PhiBookmarkLocalAccess` / `PhiPinnedTabLocalAccess`）都精化它，
/// 于是四个实现（两个生产类 + 两个假件）各自落地一次，而回填队列只认这一个窄协议——它
/// 既不需要读快照，也不需要施加操作。
@MainActor
protocol PhiFaviconWriting: AnyObject {
    /// 一轮的若干条**合成一次**后台写。抛错 = 一条都没写。
    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws
}

/// 回填那一行计数往哪去。存在的理由只有一个：R12 要求「日志只记条数与成功率，绝不记
/// host」，而一条断言「没有任何一行含这个 host」的用例需要把行抓下来。
@MainActor
protocol PhiFaviconLogSink: AnyObject {
    func record(_ line: String)
}

/// 生产 sink：直接转 `AppLogInfo`。
@MainActor
final class PhiFaviconAppLogSink: PhiFaviconLogSink {
    func record(_ line: String) { AppLogInfo(line) }
}

/// 第 2 步的失败分类。**全部是元数据**（状态码、枚举），所以整个值进日志也不违反 R12。
enum PhiFaviconFetchError: Error, Equatable {
    /// 这一跳的 scheme / host 过不了过滤表。
    case blockedHost
    /// 超过三跳。
    case tooManyRedirects
    /// 响应体越过 64 KiB。
    case tooLarge
    /// 单条超过 5 s。
    case timedOut
    case badStatus(Int)
    /// 字节拿到了，但 `NSImage` 解不开。
    case notAnImage
}

// MARK: - 过滤表

/// 「这个 URL 可以被请求吗」。**每一跳都要重问一次**——只过第一跳的实现会被一个 302 带进
/// 本机回环，那正是 SSRF 的形状（CASE 10.6）。
///
/// 判据：scheme ∈ {http, https} ∧ host 非空 ∧ 不是 loopback / 私有网段 / link-local /
/// `.local`。一次对 `http://192.168.1.1/favicon.ico` 的请求会把用户的书签内容泄露给同一
/// 局域网里的设备，所以这张表宁可过严。
enum PhiFaviconHostFilter {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let rawHost = url.host, !rawHost.isEmpty else { return false }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        // mDNS：`.local` 名字只在本地链路上解析，一次请求就是一次对同一 Wi-Fi 的广播。
        if host == "local" || host.hasSuffix(".local") { return false }
        if let quad = ipv4Quad(host) { return !isBlockedIPv4(quad) }
        if host.contains(":") { return !isBlockedIPv6(host) }
        return true
    }

    /// 点分四段 ⇒ 四个字节；不是字面量 IPv4 就 nil（那是个域名，交给 DNS）。
    private static func ipv4Quad(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            out.append(value)
        }
        return out
    }

    /// RFC 1918 / 回环 / link-local / 未指定 / CGNAT / 组播 / 保留。
    private static func isBlockedIPv4(_ quad: [Int]) -> Bool {
        switch (quad[0], quad[1]) {
        case (0, _): return true                                    // 0.0.0.0/8
        case (10, _): return true                                   // 10/8
        case (127, _): return true                                  // 回环
        case (169, 254): return true                                // link-local
        case (172, 16...31): return true                            // 172.16/12
        case (192, 168): return true                                // 192.168/16
        case (100, 64...127): return true                           // CGNAT 100.64/10
        case (192, 0): return true                                  // 192.0.0/24 与 192.0.2/24
        case (198, 18...19): return true                            // 基准测试网段
        case (224...255, _): return true                            // 组播与保留
        default: return false
        }
    }

    /// 字面量 IPv6。`::ffff:127.0.0.1` 这种 v4 映射地址走 v4 那张表。
    private static func isBlockedIPv6(_ host: String) -> Bool {
        if host.contains("."), let last = host.split(separator: ":").last,
           let quad = ipv4Quad(String(last)) {
            return isBlockedIPv4(quad)
        }
        let compact = host.replacingOccurrences(of: "0", with: "")
        if compact == "::1" || compact == "::" || host == "::1" || host == "::" { return true }
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }     // unique local fc00::/7
        if host.hasPrefix("fe8") || host.hasPrefix("fe9")
            || host.hasPrefix("fea") || host.hasPrefix("feb") { return true }   // fe80::/10
        return false
    }
}

// MARK: - 队列

/// 每轮末尾的一趟有界图标回填（§8.2）。
///
/// **这条队列不碰任何游标、不写任何基线、不触发任何推送**：`favicon` 不在快照里，那次写
/// 在 §5.7 的值快照去重那里就被吃掉，所以它对同步状态完全不可见。
///
/// 有界是安全属性，不是性能属性：无界队列在一次 500 条的导入之后会对 500 个 host 各发一次
/// 请求，那是一次可被外部观察到的、暴露用户书签的扫描。串行同理——并发发出去的 20 个请求，
/// 对一个共享域名的服务器看起来就是一次小规模突发扫描。
@MainActor
final class PhiFaviconBackfillQueue {
    /// 每轮最多取这么多条。
    static let maxRowsPerRound = 20
    /// 单条响应体上限，**边下边计**。
    static let maxBytes = 65_536
    /// 单条超时，**计入 `failed`**。
    static let perItemTimeout: TimeInterval = 5
    /// 最多跟几跳重定向。
    static let maxRedirects = 3
    /// 队列本身的深度上限。越过之后新来的行**直接丢**——回填是尽力而为的装饰，而一条无界
    /// 增长的队列在一次大导入之后会把整棵树排进来。
    static let maxQueueDepth = 500

    private let fetcher: any PhiFaviconFetching
    private let access: any PhiFaviconWriting
    private let defaultFaviconGate: (URL) -> Bool
    private let logSink: any PhiFaviconLogSink

    private var pending: [PhiLocalBookmark] = []
    /// 已经排队的 guid，用来去重：同一条行在相邻两轮里各落地一次的话，排两次队只会对同一个
    /// host 多发一次请求。
    private var queuedGuids: Set<String> = []

    /// 退休标志。**住在锁盒子里而不是 actor 状态里**，理由与 `PhiSyncEngine.StopSignal`
    /// 逐字相同：`shutdown()` 是 `nonisolated` 且要**同步**生效，一次 hop 等不起。
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
         defaultFaviconGate: @escaping (URL) -> Bool =
            FaviconConfiguration.shouldUseDefaultFavicon(for:),
         logSink: any PhiFaviconLogSink) {
        self.fetcher = fetcher
        self.access = access
        self.defaultFaviconGate = defaultFaviconGate
        self.logSink = logSink
    }

    /// 与引擎同生命周期：`PhiSyncEngine.shutdown()` 调它，此后入队与排空都是空操作。
    /// `nonisolated`，所以退出账户那条主线程路径上不需要等一次 actor hop。
    nonisolated func stop() { stopSignal.stop() }

    /// 本轮新落地的行排进队尾。**文件夹一概不收**：它们带的是占位 URL
    /// `https://bookmark.phi/folder`，一次回填就是对那个域名的一次请求。
    func enqueue(_ rows: [PhiLocalBookmark]) {
        guard !isStopped else { return }
        for row in rows where !row.isFolder {
            guard pending.count < Self.maxQueueDepth else { return }
            guard !queuedGuids.contains(row.guid) else { continue }
            queuedGuids.insert(row.guid)
            pending.append(row)
        }
    }

    /// 排空**一轮**：最多 20 条，串行，整轮**一次**写回。
    ///
    /// 返回的三个数是这一轮的计数，不是队列的累计：`attempted` 不含被第 0 步闸掉的那些
    /// （它们两步都不做），`succeeded + failed == attempted`。
    @discardableResult
    func drainOnce() async -> (attempted: Int, succeeded: Int, failed: Int) {
        guard !isStopped else { return (0, 0, 0) }
        var taken = 0
        var attempted = 0
        var succeeded = 0
        var failed = 0
        var writes: [(guid: String, data: Data)] = []

        while taken < Self.maxRowsPerRound, !pending.isEmpty {
            guard !isStopped else { break }
            let row = pending.removeFirst()
            queuedGuids.remove(row.guid)
            taken += 1
            // 第 0 步：内部页面用默认图标，**两步都不做**。
            if defaultFaviconGate(row.url) { continue }
            attempted += 1
            if let data = await resolve(row) {
                succeeded += 1
                writes.append((guid: row.guid, data: data))
            } else {
                failed += 1
            }
        }

        // 整轮**一次**写回（CASE 10.11）。
        if !writes.isEmpty {
            do {
                try await access.setFavicon(writes)
            } catch {
                // 写回失败不是取图失败，但对这一轮来说结果一样：那些字节没有落地。
                failed += writes.count
                succeeded -= writes.count
                logSink.record("[phi-sync] favicon backfill write failed count=\(writes.count) "
                               + "(\(PhiSyncLog.describe(error)))")
            }
        }

        // R12：条数与成功率，**没有 host、没有 URL、没有标题**。
        if taken > 0 {
            logSink.record("[phi-sync] favicon backfill attempted=\(attempted) "
                           + "succeeded=\(succeeded) failed=\(failed) "
                           + "skipped=\(taken - attempted) remaining=\(pending.count)")
        }
        return (attempted, succeeded, failed)
    }

    // MARK: - 私有

    /// 一条行的两步取图。返回 nil = 这一条失败了。
    private func resolve(_ row: PhiLocalBookmark) async -> Data? {
        // 第 1 步：Chromium 的 favicon 服务。它只对本 Profile 真正访问过的 URL 有货，所以
        // 大多数新落地的行在这里拿不到东西——但拿得到的那些一个网络请求都不用发。
        if let data = await fetcher.chromiumFavicon(profileId: row.profileId, pageURL: row.url),
           accepts(data) {
            return data
        }
        guard !isStopped, let target = Self.faviconURL(for: row.url) else { return nil }

        // 第 2 步：`GET https://<host>/favicon.ico`，失败至多再试 **1** 次。
        for attempt in 0...1 {
            guard !isStopped else { return nil }
            do {
                let data = try await fetchWithDeadline(target)
                // 解不开的字节**不重试**：同一个 host 再发一次只会拿回同一段 HTML
                // （CASE 10.9），而那段 HTML 会被 UI 当图片解。
                return accepts(data) ? data : nil
            } catch {
                if attempt == 1 { return nil }
            }
        }
        return nil
    }

    /// 单条 5 s 的硬上限。生产 fetcher 自己也设了 `timeoutIntervalForRequest`，但那一条管
    /// 不到一个卡在读取循环里的响应，而一条挂住的取图会把整轮回填一起挂住。
    private func fetchWithDeadline(_ url: URL) async throws -> Data {
        let fetcher = self.fetcher
        let timeout = Self.perItemTimeout
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await fetcher.networkFavicon(at: url) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PhiFaviconFetchError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PhiFaviconFetchError.timedOut }
            return first
        }
    }

    /// 接受判据：非空、不超上限、`NSImage` 真的解得开。
    private func accepts(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= Self.maxBytes else { return false }
        return NSImage(data: data) != nil
    }

    /// 页面 URL ⇒ 取图 URL。**https-only**，不带端口：`https://<host>/favicon.ico`。
    /// 页面 URL 自己先过一遍过滤表，合成出来的那条再过一遍。
    static func faviconURL(for pageURL: URL) -> URL? {
        guard allows(pageURL), let host = pageURL.host else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/favicon.ico"
        guard let url = components.url, allows(url) else { return nil }
        return url
    }

    private static func allows(_ url: URL) -> Bool { PhiFaviconHostFilter.allows(url) }
}

// MARK: - 生产取图器

/// 生产实现：第 1 步走 Chromium bridge，第 2 步走一个 **ephemeral** `URLSession`。
///
/// 连接是刻意贫瘠的：无 cookie、无凭据、无缓存、无 `User-Agent` 之外的身份，于是一次回填
/// 请求在对端眼里与这台机器的浏览会话没有任何关联。
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

    func chromiumFavicon(profileId: String, pageURL: URL) async -> Data? {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return nil }
        let urlString = pageURL.absoluteString
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            bridge.getFaviconForURL(urlString, profileId: profileId) { data in
                continuation.resume(returning: data)
            }
        }
    }

    /// 边下边计（`URLSession.bytes(for:)`），越过 64 KiB 立刻取消——只在下载完成后检查
    /// `count` 的实现，对一个不声明 `Content-Length` 的无限响应会一直读到内存耗尽。
    func networkFavicon(at url: URL) async throws -> Data {
        guard PhiFaviconHostFilter.allows(url) else { throw PhiFaviconFetchError.blockedHost }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = PhiFaviconBackfillQueue.perItemTimeout

        // 每条请求一个 guard 实例：跳数是**这一条**的状态，一个跨请求共享的委托数不对。
        let guardDelegate = RedirectGuard(maxRedirects: PhiFaviconBackfillQueue.maxRedirects)
        let (stream, response) = try await session.bytes(for: request, delegate: guardDelegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            stream.task.cancel()
            throw PhiFaviconFetchError.badStatus(http.statusCode)
        }
        var data = Data()
        data.reserveCapacity(4096)
        for try await byte in stream {
            data.append(byte)
            if data.count > PhiFaviconBackfillQueue.maxBytes {
                stream.task.cancel()
                throw PhiFaviconFetchError.tooLarge
            }
        }
        return data
    }

    /// 逐跳重过过滤表，并数跳数。返回 `nil` = 不跟这一跳，于是那次 302 的响应体原样交回来，
    /// 到 `accepts` 那里解不开被拒。
    ///
    /// 跳数住在锁后面：`URLSession` 的委托回调跑在它自己的队列上，而这个类隐式满足
    /// `Sendable`（`URLSessionTaskDelegate` 要求）。一个实例只服务一条请求，所以实际上不会
    /// 有并发，但「实际上不会」不是类型系统认得的理由。
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let maxRedirects: Int
        private let lock = NSLock()
        private var hops = 0

        init(maxRedirects: Int) {
            self.maxRedirects = maxRedirects
        }

        /// 这一跳是第几跳。自增并交回新值。
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
