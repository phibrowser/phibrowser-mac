// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Darwin
import Dispatch
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
    ///
    /// **调用方会给它套一个截止时间**：生产实现是一个 `withCheckedContinuation` 包着
    /// bridge 的回调，而一个永不到达的回调会把 `drainOnce` 挂死在引擎那条串行轮次队列上。
    func chromiumFavicon(profileId: String, pageURL: URL) async -> Data?

    /// 第 2 步：网络取图。**调用方已经过完过滤表**（`PhiFaviconHostFilter`），实现负责
    /// 逐跳重过与大小上限——重定向发生在实现内部，调用方看不见那些跳。
    func networkFavicon(at url: URL) async throws -> Data

    /// 取消一切在飞的取图，并让这个取图器此后不再工作（§8.3：引擎退休时「取消队列并丢弃
    /// 未完成项」）。队列的 `stop()` 调它一次。
    func cancelAll()
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
    /// 这一行的 5 s 预算用完了。
    case timedOut
    case badStatus(Int)
    /// 字节拿到了，但 `NSImage` 解不开。
    case notAnImage
}

// MARK: - 过滤表

/// 「这个 URL 可以被请求吗」。**每一跳都要重问一次**——只过第一跳的实现会被一个 302 带进
/// 本机回环，那正是 SSRF 的形状（CASE 10.6）。
///
/// 判据：scheme ∈ {http, https} ∧ host 非空 ∧ host 不是 `localhost` / `.local` 这类本地
/// 名字 ∧ host **不是任何记法的数字 IP 字面量**。
///
/// **数字字面量一律拒，而不是「拒掉私有网段」**：手写的网段判断挡不住实际会被
/// `getaddrinfo` 收下的那些写法——`0:0:0:0:0:0:0:1`（展开的回环）、`::ffff:7f00:1`
/// （十六进制 v4 映射）、`0177.0.0.1`（八进制）、`2130706433`（十进制整数）全都解析成
/// 127.0.0.1，而其中没有一个长得像 `127.x`。favicon 的 host 来自书签里的页面 URL，那些是
/// DNS 名字；一条**数字**主机在这条路径上没有合法用途，所以整类拒掉，判断交给
/// `inet_pton` / `inet_aton`（CFNetwork 背后就是它们）而不是字符串匹配。
enum PhiFaviconHostFilter {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let rawHost = url.host, !rawHost.isEmpty else { return false }
        // IPv6 字面量在有些 API 上带方括号回来，在有些上不带。
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        // mDNS：`.local` 名字只在本地链路上解析，一次请求就是一次对同一 Wi-Fi 的广播。
        if host == "local" || host.hasSuffix(".local") { return false }
        if isNumericIPLiteral(host) { return false }
        return true
    }

    /// 这个 host 是不是一个数字 IP 字面量——**任何**记法。
    ///
    /// 三问，因为三者收的集合不同：`inet_pton(AF_INET6,…)` 认全部 IPv6 写法（含展开形与
    /// v4 映射形）；`inet_pton(AF_INET,…)` 认严格的点分四段十进制；`inet_aton` 比它宽，
    /// 八进制（`0177.0.0.1`）、十六进制（`0x7f.0.0.1`）、两段 / 三段（`127.1`）与单个
    /// 十进制整数（`2130706433`）它都收——**而 `getaddrinfo` 同样收**，所以少问这一句就等于
    /// 放行这些写法。
    private static func isNumericIPLiteral(_ host: String) -> Bool {
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        if inet_aton(host, &v4) == 1 { return true }
        return false
    }
}

// MARK: - 队列

/// 每轮末尾的一趟有界图标回填（§8.2）。
///
/// **这条队列不碰任何游标、不写任何基线、不触发任何推送**：favicon 不在快照里，那次写
/// 在 §5.7 的值快照去重那里就被吃掉，所以它对同步状态完全不可见。
///
/// 有界是安全属性，不是性能属性：无界队列在一次 500 条的导入之后会对 500 个 host 各发一次
/// 请求，那是一次可被外部观察到的、暴露用户书签的扫描。串行同理——并发发出去的 20 个请求，
/// 对一个共享域名的服务器看起来就是一次小规模突发扫描。
///
/// **一行一份 5 s 预算，两步与那次重试都在同一份里花**（§8.2：「每轮的总预算就是那 20 条
/// × 5 s，没有第二层预算」）。这条上限是真的要紧：`drainOnce()` 被 `run(_:)` await 着，
/// 整个期间这一轮占着引擎的 `roundQueue`，所以每一秒都直接推迟下一次设置同步与下一个
/// Space 意图。
///
/// **一次失败的写回会永久丢掉那一轮已经取到的图标**：行在被取出时就离开了 `pending`，不会
/// 重新排队。这是有意的——回填是尽力而为的装饰，重排会让一个持续写失败的库把同一批行每轮
/// 重取一遍；丢掉的那些在计数行的 `failed` 里看得见。
@MainActor
final class PhiFaviconBackfillQueue {
    /// 每轮最多取这么多条。
    static let maxRowsPerRound = 20
    /// 单条响应体上限，**边下边计**。
    static let maxBytes = 65_536
    /// **一行**的总预算（两步 + 那次重试），**计入 `failed`**。
    static let perItemTimeout: TimeInterval = 5
    /// 第 1 步（本机历史查询）自己的子预算，**必须严格小于 `perItemTimeout`**。
    ///
    /// 一次本地查询用不了一秒。给它整份 5 s 的话，一个系统性变慢的 bridge 会把第 2 步饿到
    /// **恰好零**——预算用完时 `withDeadline` 连请求都不发，那一行就这么失败掉，而且不会
    /// 重新排队。那种故障在日志上只表现为 `from_network=0`，看起来与「本机历史里什么都有」
    /// 一模一样。
    static let historyLookupTimeout: TimeInterval = 1
    /// 最多跟几跳重定向。
    static let maxRedirects = 3
    /// 队列本身的深度上限。越过之后新来的行**直接丢**——回填是尽力而为的装饰，而一条无界
    /// 增长的队列在一次大导入之后会把整棵树排进来。
    static let maxQueueDepth = 500

    /// 队列眼里的一行。两种 kind 都投影成它：回填只需要「写回按哪个 guid 定位」「问哪个
    /// 页面 URL」「用哪个 profile 查历史」，以及写回该走哪一个 access。
    private struct Row {
        var guid: String
        var url: URL
        var profileId: String
        var isPin: Bool
    }

    /// 一条行取到的图，以及它来自哪一步（§11.3 的 `from_history` / `from_network`）。
    private struct Fetched {
        var data: Data
        var fromHistory: Bool
    }

    /// 一行的截止时刻。单调钟（`DispatchTime`），所以改系统时间影响不到它。
    private struct Deadline {
        private let end: DispatchTime

        init(seconds: TimeInterval) {
            end = DispatchTime.now() + seconds
        }

        /// 还剩多少纳秒；已经过期就是 0。
        var remainingNanoseconds: UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            let end = self.end.uptimeNanoseconds
            return end > now ? end - now : 0
        }

        var isExpired: Bool { remainingNanoseconds == 0 }
    }

    private let fetcher: any PhiFaviconFetching
    /// 书签行的写回口。
    private let access: any PhiFaviconWriting
    /// pin 行的写回口。nil = 这个队列不收 pin。
    private let pinAccess: (any PhiFaviconWriting)?
    private let defaultFaviconGate: (URL) -> Bool
    private let logSink: any PhiFaviconLogSink

    private var pending: [Row] = []
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

    /// 与引擎同生命周期：`PhiSyncEngine.shutdown()` 调它，此后入队与排空都是空操作。
    ///
    /// `nonisolated` 且**同步返回**，所以退出账户那条主线程路径上不需要等一次 actor hop；
    /// 真正的清理（丢掉未完成项、取消在飞的请求）排一次主 actor 跃迁再做——它不需要同步，
    /// 挡住后续工作的是那一位标志，不是这次清理。
    /// **强捕获 `self`，不是 `[weak self]`。** 退出账户那条路上协调器在调完 `shutdown()`
    /// 之后两句就把引擎丢掉，而引擎是这个队列唯一的强持有者；没有轮次在飞时队列会在这个
    /// 任务拿到执行机会**之前**就析构，于是 `invalidateAndCancel()` 一次都不跑，那个
    /// ephemeral 会话连同它的连接池一起漏掉。任务立刻结束，所以没有循环引用可担心。
    nonisolated func stop() {
        stopSignal.stop()
        Task { @MainActor [self] in self.discardAndCancel() }
    }

    /// 本轮新落地的书签行排进队尾。**文件夹一概不收**：它们带的是占位 URL
    /// `https://bookmark.phi/folder`，一次回填就是对那个域名的一次请求。
    func enqueue(_ rows: [PhiLocalBookmark]) {
        appendRows(rows.lazy.filter { !$0.isFolder }.map {
            Row(guid: $0.guid, url: $0.url, profileId: $0.profileId, isPin: false)
        })
    }

    /// 本轮新落地的 pin 行排进队尾（§8.2 开头那句「落地的书签**与 pin**」）。休眠行不收。
    func enqueue(_ rows: [PhiLocalPin]) {
        appendRows(rows.lazy.filter { !$0.isDormant }.map {
            Row(guid: $0.guid,
                url: $0.url,
                profileId: $0.profileId ?? LocalStore.defaultProfileId,
                isPin: true)
        })
    }

    /// 排空**一轮**：最多 20 条，串行，每种 kind 至多**一次**写回。
    ///
    /// 返回的三个数是这一轮的计数，不是队列的累计：`attempted` 不含被第 0 步闸掉的那些
    /// （它们两步都不做），`succeeded + failed == attempted`。
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
            // 第 0 步：内部页面用默认图标，**两步都不做**。
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

        // 写回：每种 kind 整轮**一次**（CASE 10.11）。两个口是两个 access 协议实例，所以一批
        // 纯书签的行仍然只产生一次写。
        var lost = 0
        if isStopped {
            // 退休途中取到的字节一个都不写：库正在被拆。
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

        // §11.3 那条诊断行。R12：只有计数与耗时，**没有 host、没有 URL、没有标题**。
        // `from_history` / `from_network` 数的是**字节从哪一步取到的**，不是最后写没写成——
        // 它回答的是「这条队列到底有没有在向第三方发请求」，那是 §8.3 唯一一个与隐私相关的
        // 数，写回失败不该把它抹掉。
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

    // MARK: - 私有

    private func appendRows<S: Sequence>(_ rows: S) where S.Element == Row {
        guard !isStopped else { return }
        for row in rows {
            guard pending.count < Self.maxQueueDepth else { return }
            guard !queuedGuids.contains(row.guid) else { continue }
            queuedGuids.insert(row.guid)
            pending.append(row)
        }
    }

    /// §8.3：丢掉未完成项并取消在飞的取图。
    private func discardAndCancel() {
        pending = []
        queuedGuids = []
        fetcher.cancelAll()
    }

    /// 一批写回。返回**没能落地**的条数（抛错 = 整批没落）。
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

    /// 一条行的两步取图，**共用一份 5 s 预算**。返回 nil = 这一条失败了。
    private func resolve(_ row: Row) async -> Fetched? {
        let deadline = Deadline(seconds: Self.perItemTimeout)
        let fetcher = self.fetcher
        let profileId = row.profileId
        let pageURL = row.url

        // 第 1 步：Chromium 的 favicon 服务。它只对本 Profile 真正访问过的 URL 有货，所以
        // 大多数新落地的行在这里拿不到东西——但拿得到的那些一个网络请求都不用发。
        //
        // **套两层截止时间**：一层是这一行的总预算，另一层是第 1 步自己的子预算，取较小的
        // 那个。子预算保证一个慢 bridge 饿不死第 2 步；总预算保证一行不会超支。
        //
        // 这两层都只是**报时**——真正让子任务回来的是取图器那一侧对取消的反应
        // （`PhiFaviconFetcher.chromiumFavicon` 的 `withTaskCancellationHandler`）。一个任务组
        // 在它的子任务返回之前不会解开，所以一个不理会取消的第 1 步会把 `drainOnce()` 连同
        // 引擎那条串行轮次队列一起钉死，套多少层截止时间都没用。
        let historyDeadline = Deadline(seconds: min(Self.historyLookupTimeout,
                                                    Self.perItemTimeout))
        let historical = (try? await withDeadline(historyDeadline) {
            await fetcher.chromiumFavicon(profileId: profileId, pageURL: pageURL)
        }) ?? nil
        if let data = historical, accepts(data) {
            return Fetched(data: data, fromHistory: true)
        }
        guard !isStopped, let target = Self.faviconURL(for: row.url) else { return nil }

        // 第 2 步：`GET https://<host>/favicon.ico`，失败至多再试 **1** 次。**重试花的是
        // 同一份预算里剩下的时间**，不是新的 5 s——否则一行的最坏情形是 10 s，一轮 200 s。
        for attempt in 0...1 {
            guard !isStopped, !deadline.isExpired else { return nil }
            do {
                let data = try await withDeadline(deadline) {
                    try await fetcher.networkFavicon(at: target)
                }
                // 解不开的字节**不重试**：同一个 host 再发一次只会拿回同一段 HTML
                // （CASE 10.9），而那段 HTML 会被 UI 当图片解。
                return accepts(data) ? Fetched(data: data, fromHistory: false) : nil
            } catch {
                if attempt == 1 { return nil }
            }
        }
        return nil
    }

    /// 把一次取图与这一行剩下的预算赛跑。预算已经用完就当场超时，不再发起。
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

    /// 接受判据：非空、不超上限、`NSImage` 真的解得开。
    ///
    /// 大小那一条是**后备闸**：生产取图器在流中途就该收手，这里再拦一次，于是一个在那条
    /// 路径上回归的构建也写不进一段超限的字节。
    private func accepts(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= Self.maxBytes else { return false }
        return NSImage(data: data) != nil
    }

    /// 页面 URL ⇒ 取图 URL。**https-only**，不带端口：`https://<host>/favicon.ico`。
    /// 页面 URL 自己先过一遍过滤表，合成出来的那条再过一遍。
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

// MARK: - 生产取图器

/// 生产实现：第 1 步走 Chromium bridge，第 2 步走一个 **ephemeral** `URLSession`。
///
/// 连接是刻意贫瘠的：无 cookie、无凭据、无缓存，于是一次回填请求在对端眼里与这台机器的
/// 浏览会话没有任何关联。
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

    /// §8.3：引擎退休时取消在飞的请求。**`invalidateAndCancel` 而不是只 cancel task**：
    /// 一个 `URLSession(configuration:)` 建出来的会话会比它的持有者活得久，不作废的话它连同
    /// 它的连接池一起留着。这个取图器此后不再可用，而那正是 `stop()` 的语义。
    func cancelAll() {
        session.invalidateAndCancel()
    }

    /// **必须对取消有反应**，否则给它套截止时间是没有意义的：一个任务组在它的子任务返回
    /// 之前不会解开，所以一个挂在裸 `withCheckedContinuation` 里的子任务会把
    /// `withDeadline` 连同 `drainOnce()` 一起钉死——而 `drainOnce()` 正被引擎那条串行轮次
    /// 队列 await 着。丢了回调的 bridge 于是会永久停掉这台机器的同步，`stop()` 也够不着它
    /// （那一位标志只在行与行之间被读到）。
    ///
    /// `withTaskCancellationHandler` 加一个只结账一次的信箱：回调与取消谁先到谁算数，晚到
    /// 的那个被忽略而不是把 continuation resume 第二次。
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

    /// 恰好 resume 一次的信箱。
    ///
    /// 三个事件可能以任意顺序到达，而且来自不同线程：装上 continuation（`arm`）、bridge 的
    /// 回调、取消处理器。取消处理器甚至可能跑在 `operation` 之前——任务在进入
    /// `withTaskCancellationHandler` 时就已经被取消的话就是这样——所以先到的结果要能被记下来
    /// 等 `arm` 来结账，而不是丢掉（那会把挂死换成另一种挂死）。
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var settled = false
        private var earlyResult: Data?
        private var hasEarlyResult = false

        /// 装上 continuation；结果已经先到了就当场结账。
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

        /// 第一个到达的事件结账，后到的一律忽略。
        func settle(with data: Data?) {
            lock.lock()
            guard !settled else {
                lock.unlock()
                return
            }
            guard let continuation else {
                // continuation 还没装上：记下来，`arm` 时结账。
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
        return try await Self.readBounded(stream, limit: PhiFaviconBackfillQueue.maxBytes)
    }

    /// 有界读取。**`nonisolated`，所以这个循环不跑在主 actor 上**：整个队列是 `@MainActor`，
    /// 而一条 64 KiB 的响应在这里是六万多次异步迭代，没有理由把它们全排到主线程的执行器上。
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

    /// 逐跳重过过滤表，并数跳数。返回 `nil` = 不跟这一跳，于是那次 3xx 响应原样交回来，
    /// 被上面的状态码检查判成 `badStatus`。
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
