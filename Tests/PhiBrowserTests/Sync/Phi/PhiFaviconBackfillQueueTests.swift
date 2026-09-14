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
            // 边下边计：一块一块读，越过上限立刻断，**绝不先读完再看 `count`**。
            var read = 0
            while read < streamedBytes {
                read += min(4096, streamedBytes - read)
                bytesActuallyRead = read
                if read > PhiFaviconBackfillQueue.maxBytes {
                    throw PhiFaviconFetchError.tooLarge
                }
                await Task.yield()
            }
            return Data(count: read)
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

    // MARK: CASE 10.8 — 超限响应边下边断

    func testAnOversizedResponseIsAbandonedMidStream() async {
        let harness = makeHarness()
        harness.fetcher.streamedBytes = 1_000_000
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.succeeded, 0)
        let read = harness.fetcher.bytesActuallyRead
        XCTAssertLessThanOrEqual(read, PhiFaviconBackfillQueue.maxBytes + 4096)
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
}
