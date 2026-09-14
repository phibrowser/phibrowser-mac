// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation
import XCTest
@testable import Phi

// MARK: - 假件

/// 内存版 `PhiFaviconFetching`。两步取图都记在这里：第 1 步只数次数
/// （`chromiumLookups`），第 2 步把**每一跳**真的会发出去的 URL 记进 `requests`。
///
/// **重定向由假件自己走一遍，而且逐跳过同一张过滤表**（`PhiFaviconHostFilter`）：
/// CASE 10.6 断言的正是「被 302 带到回环地址的那一跳从来没被请求过」，而那条判断住在
/// 生产 fetcher 的 `URLSessionTaskDelegate` 里，假件够不着。两边共用同一个谓词，于是
/// 用例测的是真的那张表，不是假件自己的一份复制品。
@MainActor
final class RecordingFetcher: PhiFaviconFetching {
    /// 逐跳记录，包含初始那一跳。被过滤表挡下的那一跳**不进这里**——它根本没发出去。
    private(set) var requests: [URL] = []
    /// 同时在飞的最大条数。串行 ⇒ 恒为 1。
    private(set) var maxConcurrent = 0
    /// 第 1 步被问了几次。
    private(set) var chromiumLookups = 0
    /// `streamedBytes` 那条路上真的读进内存的字节数（每次尝试各自计，取最后一次）。
    private(set) var bytesActuallyRead = 0
    /// `cancelAll()` 被调了几次（`stop()` ⇒ §8.3 的「取消队列并丢弃未完成项」）。
    private(set) var cancelAllCalls = 0

    /// 第 2 步每次都失败（HTTP 500）。
    var alwaysFail = false
    /// 第 2 步每次都超时。
    var alwaysTimeout = false
    /// 逐跳的重定向链，按顺序消费。
    var redirectChain: [String] = []
    /// 成功时交回的字节。nil ⇒ 一张真的能解码的 PNG。
    var responseBytes: Data?
    /// 响应体一共有多少字节（模拟一个超限的流）。> 0 时走边下边计那条路。
    var streamedBytes = 0
    /// 第 1 步交回的字节。nil ⇒ Chromium 那边没有这条 URL 的图标。
    var chromiumResponse: Data?

    private var inFlight = 0

    func cancelAll() { cancelAllCalls += 1 }

    func chromiumFavicon(profileId: String, pageURL: URL) async -> Data? {
        chromiumLookups += 1
        return chromiumResponse
    }

    func networkFavicon(at url: URL) async throws -> Data {
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        defer { inFlight -= 1 }

        // 逐跳：每一跳都先过过滤表，过不了就当场断，**不记进 `requests`**。
        var current = url
        var hops = 0
        while true {
            guard PhiFaviconHostFilter.allows(current) else {
                throw PhiFaviconFetchError.blockedHost
            }
            requests.append(current)
            guard hops < redirectChain.count else { break }
            guard hops < PhiFaviconBackfillQueue.maxRedirects else {
                throw PhiFaviconFetchError.tooManyRedirects
            }
            guard let next = URL(string: redirectChain[hops]) else { break }
            hops += 1
            current = next
        }

        if alwaysTimeout { throw PhiFaviconFetchError.timedOut }
        if alwaysFail { throw PhiFaviconFetchError.badStatus(500) }

        if streamedBytes > 0 {
            // **假件刻意不自设上限**：它模拟的是一个没能在流中途收手的取图器，于是用例断言
            // 的是队列自己那道 `accepts` 后备闸（真的生产行为），而不是假件循环里的一个常量。
            // 生产侧那道边下边断住在 `PhiFaviconFetcher.readBounded`，测它要一个 URLProtocol
            // 夹具，不在本任务范围内。
            bytesActuallyRead = streamedBytes
            return Data(count: streamedBytes)
        }
        return responseBytes ?? validPNGBytes()
    }
}

/// 把回填那一行日志抓下来的 sink（CASE 10.12）。
@MainActor
final class CapturingLogSink: PhiFaviconLogSink {
    private(set) var lines: [String] = []

    func record(_ line: String) { lines.append(line) }
}

/// 一张 16×16、`NSImage` 真的解得开的 PNG。
///
/// 走 `NSBitmapImageRep` 而不是 `NSImage.lockFocus()`：后者要求主线程且会碰绘图上下文，
/// 而这个 fixture 只需要一段合法的 PNG 字节。
func validPNGBytes() -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: 16,
                                     pixelsHigh: 16,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else { return Data() }
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

// MARK: - 用例

@MainActor
final class PhiFaviconBackfillQueueTests: XCTestCase {

    // MARK: 脚手架

    private struct Harness {
        var queue: PhiFaviconBackfillQueue
        var fetcher: RecordingFetcher
        var access: FakeBookmarkAccess
        var sink: CapturingLogSink
    }

    /// 默认闸一律**放行**（`{ _ in false }` = 「这条不该用默认图标」），于是除了 CASE 10.10
    /// 之外没有一条用例会因为第 0 步而静默跳过。
    private func makeHarness(gate: @escaping (URL) -> Bool = { _ in false }) -> Harness {
        let fetcher = RecordingFetcher()
        let access = FakeBookmarkAccess()
        let sink = CapturingLogSink()
        let queue = PhiFaviconBackfillQueue(fetcher: fetcher,
                                            access: access,
                                            defaultFaviconGate: gate,
                                            logSink: sink)
        return Harness(queue: queue, fetcher: fetcher, access: access, sink: sink)
    }

    private func rows(_ urls: [String]) -> [PhiLocalBookmark] {
        urls.enumerated().map { index, string in
            PhiLocalBookmark.fixture(guid: "G\(index)",
                                     url: URL(string: string) ?? URL(fileURLWithPath: "/dev/null"))
        }
    }

    // MARK: CASE 10.1 — 每轮最多 20 条，其余留到下一轮

    func testDrainOnceTakesAtMostTwentyRowsAndLeavesTheRestQueued() async {
        let harness = makeHarness()
        harness.queue.enqueue(rows((0..<50).map { "https://h\($0).example/page" }))

        let first = await harness.queue.drainOnce()
        let second = await harness.queue.drainOnce()
        let third = await harness.queue.drainOnce()
        let fourth = await harness.queue.drainOnce()

        XCTAssertEqual(first.attempted, 20)
        XCTAssertEqual(second.attempted, 20)
        XCTAssertEqual(third.attempted, 10)
        XCTAssertEqual(fourth.attempted, 0)
    }

    // MARK: CASE 10.2 — 串行

    func testFetchesRunOneAtATime() async {
        let harness = makeHarness()
        harness.queue.enqueue(rows((0..<5).map { "https://h\($0).example/page" }))

        _ = await harness.queue.drainOnce()

        let concurrent = harness.fetcher.maxConcurrent
        XCTAssertEqual(concurrent, 1)
    }

    // MARK: CASE 10.3 — 失败至多再试一次

    func testAFailingFetchIsRetriedExactlyOnce() async {
        let harness = makeHarness()
        harness.fetcher.alwaysFail = true
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        let requestCount = harness.fetcher.requests.count
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.succeeded, 0)
    }

    // MARK: CASE 10.4 — 超时计入 failed，且不写回

    func testATimeoutCountsAsFailedAndWritesNothing() async {
        let harness = makeHarness()
        harness.fetcher.alwaysTimeout = true
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.succeeded, 0)
        let writes = harness.access.faviconWrites.count
        XCTAssertEqual(writes, 0)
    }

    // MARK: CASE 10.5 — 过滤表逐条，零网络调用

    func testBlockedSchemesAndPrivateHostsNeverReachTheNetwork() async {
        let harness = makeHarness()
        harness.queue.enqueue(rows(["file:///etc/passwd",
                                    "https:///x",
                                    "http://127.0.0.1/x",
                                    "http://192.168.1.1/x",
                                    "http://169.254.1.1/x",
                                    "http://printer.local/x"]))

        let result = await harness.queue.drainOnce()

        let requests = harness.fetcher.requests
        XCTAssertTrue(requests.isEmpty, "a filtered row must not produce any request")
        XCTAssertEqual(result.succeeded, 0)
    }

    // MARK: CASE 10.6 — 每一跳重定向都重新过过滤表

    func testEveryRedirectHopIsRefiltered() async {
        let harness = makeHarness()
        harness.fetcher.redirectChain = ["https://a.example/favicon.ico",
                                         "http://127.0.0.1:9000/x.ico"]
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.succeeded, 0)
        let loopbackHops = harness.fetcher.requests.filter { $0.host == "127.0.0.1" }.count
        XCTAssertEqual(loopbackHops, 0, "a 302 into loopback must never be requested")
    }

    // MARK: CASE 10.7 — 超过三跳放弃

    func testMoreThanThreeRedirectsIsAbandoned() async {
        let harness = makeHarness()
        harness.fetcher.redirectChain = ["https://a.example/1.ico",
                                         "https://b.example/2.ico",
                                         "https://c.example/3.ico",
                                         "https://d.example/4.ico"]
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.failed, 1)
        let fourthHop = harness.fetcher.requests.filter { $0.host == "d.example" }.count
        XCTAssertEqual(fourthHop, 0, "the fourth hop is past the limit and must not be requested")
    }

    // MARK: CASE 10.8 — 超限响应被拒，队列自己有一道后备闸

    /// 断言的是**生产行为**：即使取图器没能在流中途收手、把整段 1 MB 交了回来，队列的
    /// `accepts` 也不会让它落地。上限常量与生产流式读取用的是同一个，所以这条用例同时把
    /// 那个数钉住。
    func testAnOversizedBodyIsRejectedEvenWhenTheFetcherFailsToCapIt() async {
        let harness = makeHarness()
        harness.fetcher.streamedBytes = 1_000_000
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.failed, 1)
        let writes = harness.access.faviconWrites.count
        XCTAssertEqual(writes, 0, "an over-size body must never reach the store")
        let read = harness.fetcher.bytesActuallyRead
        XCTAssertEqual(read, 1_000_000, "the fake deliberately read it all; the queue still refused")
        XCTAssertEqual(PhiFaviconBackfillQueue.maxBytes, 65_536)
    }

    // MARK: CASE 10.9 — 解不开的字节被拒

    func testUndecodableBytesAreRejected() async {
        let harness = makeHarness()
        harness.fetcher.responseBytes = Data("<html>404</html>".utf8)
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.succeeded, 0)
        let writes = harness.access.faviconWrites.count
        XCTAssertEqual(writes, 0)
    }

    // MARK: CASE 10.10 — 第 0 步的闸让两步都跳过

    func testTheDefaultFaviconGateSkipsBothSteps() async {
        let harness = makeHarness(gate: { _ in true })
        harness.queue.enqueue(rows(["https://h0.example/page", "https://h1.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertTrue(harness.fetcher.requests.isEmpty)
        let lookups = harness.fetcher.chromiumLookups
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(result.attempted, 0)
    }

    // MARK: CASE 10.11 — 整轮一次写回

    func testOneRoundProducesExactlyOneWriteBack() async {
        let harness = makeHarness()
        harness.fetcher.responseBytes = validPNGBytes()
        harness.queue.enqueue(rows((0..<5).map { "https://h\($0).example/page" }))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.succeeded, 5)
        let writes = harness.access.faviconWrites.count
        XCTAssertEqual(writes, 5)
        let calls = harness.access.faviconWriteCalls
        XCTAssertEqual(calls, 1, "a round writes back once, not once per row")
        let applyCalls = harness.access.calls.filter {
            if case .apply = $0 { return true }
            return false
        }.count
        XCTAssertEqual(applyCalls, 0, "favicon never travels through the …ApplyOp path")
    }

    // MARK: CASE 10.12 — 日志有计数、没有 host

    func testTheRoundLineCarriesCountsButNoHost() async {
        let harness = makeHarness()
        harness.queue.enqueue(rows(["https://secret-host.example/page"]))

        _ = await harness.queue.drainOnce()

        let lines = harness.sink.lines
        XCTAssertFalse(lines.contains { $0.contains("secret-host") },
                       "R12: a back-fill log line must never carry a host")
        XCTAssertTrue(lines.contains { $0.contains("attempted=") })
    }

    // MARK: §11.3 — 那条诊断行的字段

    /// spec §11.3 逐字规定了
    /// `[phi-sync] favicon backfill: queued=<n> from_history=<n> from_network=<n> failed=<n> ms=<n>`。
    /// `from_history` / `from_network` 的分法是 §8.3 里唯一一个与隐私相关的数：它回答「这条
    /// 队列到底有没有在向第三方发请求」。
    func testTheRoundLineCarriesTheSpecMandatedCounters() async {
        let harness = makeHarness()
        harness.fetcher.chromiumResponse = validPNGBytes()
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        _ = await harness.queue.drainOnce()

        guard let line = harness.sink.lines.first(where: { $0.contains("favicon backfill:") }) else {
            XCTFail("the round must emit the §11.3 diagnostic line")
            return
        }
        XCTAssertTrue(line.contains("queued=1"))
        XCTAssertTrue(line.contains("from_history=1"),
                      "a row served from Chromium history must not be counted as a network fetch")
        XCTAssertTrue(line.contains("from_network=0"))
        XCTAssertTrue(line.contains("failed=0"))
        XCTAssertTrue(line.contains("ms="))
        let requests = harness.fetcher.requests
        XCTAssertTrue(requests.isEmpty, "step 1 hitting means step 2 must never run")
    }

    // MARK: §8.3 — 退休时丢弃未完成项并取消在飞的请求

    func testStopDiscardsPendingRowsAndCancelsTheFetcher() async {
        let harness = makeHarness()
        harness.queue.enqueue(rows((0..<30).map { "https://h\($0).example/page" }))

        harness.queue.stop()
        let afterStop = await harness.queue.drainOnce()

        XCTAssertEqual(afterStop.attempted, 0)
        XCTAssertEqual(afterStop.succeeded, 0)
        XCTAssertEqual(afterStop.failed, 0)
        // `stop()` 同步返回，清理排一次主 actor 跃迁再做。
        for _ in 0..<20 { await Task.yield() }
        let cancels = harness.fetcher.cancelAllCalls
        XCTAssertEqual(cancels, 1)
    }
}

// MARK: - 过滤表

/// `PhiFaviconHostFilter.allows` 的表驱动用例。
///
/// 这是本任务唯一一块直接测生产判据的覆盖：CASE 10.5 / 10.6 经由假件间接用到它，但那两条
/// 只走六个 host。真正危险的是**同一个地址的别的写法**——展开的 IPv6 回环、十六进制 v4
/// 映射、八进制与十进制整数 IPv4 —— 它们全都解析成 127.0.0.1，而没有一个长得像 `127.x`。
@MainActor
final class PhiFaviconHostFilterTests: XCTestCase {

    private func check(_ string: String, _ expected: Bool, line: UInt = #line) {
        guard let url = URL(string: string) else {
            XCTAssertFalse(expected, "\(string) did not parse as a URL at all", line: line)
            return
        }
        let allowed = PhiFaviconHostFilter.allows(url)
        XCTAssertEqual(allowed, expected, "wrong verdict for \(string)", line: line)
    }

    func testSchemeAndEmptyHostAreRejected() {
        check("file:///etc/passwd", false)
        check("https:///x", false)
        check("ftp://example.com/x", false)
        check("phi://newtab", false)
    }

    func testLocalNamesAreRejected() {
        check("http://localhost/x", false)
        check("http://app.localhost/x", false)
        check("http://printer.local/x", false)
        check("http://local/x", false)
    }

    func testDottedDecimalPrivateAndLoopbackAreRejected() {
        check("http://127.0.0.1/x", false)
        check("http://192.168.1.1/x", false)
        check("http://10.0.0.5/x", false)
        check("http://172.16.0.1/x", false)
        check("http://169.254.1.1/x", false)
        check("http://100.64.0.1/x", false)
        check("http://0.0.0.0/x", false)
    }

    /// 这四行是审阅点名的四种绕过写法，每一种都落在 127.0.0.1 上。
    func testAlternateIPv4AndIPv6EncodingsAreRejected() {
        check("http://0177.0.0.1/x", false)        // 八进制：0177 = 127
        check("http://2130706433/x", false)        // 十进制整数
        check("http://127.1/x", false)             // 两段
        check("http://0x7f.0.0.1/x", false)        // 十六进制
        check("http://[::1]/x", false)             // 紧凑 IPv6 回环
        check("http://[0:0:0:0:0:0:0:1]/x", false) // 展开的同一个地址
        check("http://[::ffff:7f00:1]/x", false)   // 十六进制 v4 映射
        check("http://[fe80::1]/x", false)         // link-local
        check("http://[fd00::1]/x", false)         // unique local
    }

    /// 规则是「数字字面量一律拒」，公网地址也不例外——favicon 的 host 来自书签里的页面
    /// URL，那些是 DNS 名字。
    func testEvenAPublicIPLiteralIsRejected() {
        check("https://93.184.216.34/x", false)
    }

    func testOrdinaryDNSNamesAreAllowed() {
        check("https://example.com/x", true)
        check("http://sub.example.co.uk/page", true)
        check("https://secret-host.example/page", true)
        check("https://localhost.example.com/x", true)
        check("https://example.local.com/x", true)
        check("https://1and1.com/x", true)
    }
}
