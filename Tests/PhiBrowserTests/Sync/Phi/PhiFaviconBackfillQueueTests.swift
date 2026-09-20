// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation
import XCTest
@testable import Phi

// MARK: - Fakes

/// In-memory PhiFaviconFetching records both steps: chromiumLookups counts step 1,
/// while requests records every URL actually requested in step 2.
/// The fake follows redirects and checks each hop with the shared PhiFaviconHostFilter.
/// CASE 10.6 asserts that a redirect to loopback is never requested. Production
/// enforces this in URLSessionTaskDelegate, beyond the fake's reach; sharing the
/// predicate tests the real filter rather than a copied policy.
@MainActor
final class RecordingFetcher: PhiFaviconFetching {
    /// Record each requested hop, including the initial URL; filtered hops are never requested or recorded.
    private(set) var requests: [URL] = []
    /// Peak in-flight count; serial execution keeps it at one.
    private(set) var maxConcurrent = 0
    /// Number of step-1 lookups.
    private(set) var chromiumLookups = 0
    /// Bytes actually read into memory by streamedBytes, measured per attempt; retain the latest count.
    private(set) var bytesActuallyRead = 0
    /// cancelAll call count; stop cancels the queue and discards unfinished entries (§8.3).
    private(set) var cancelAllCalls = 0

    /// Every step-2 attempt fails with HTTP 500.
    var alwaysFail = false
    /// Every step-2 attempt times out.
    var alwaysTimeout = false
    /// Redirect chain consumed in hop order.
    var redirectChain: [String] = []
    /// Successful response bytes; nil supplies a genuinely decodable PNG.
    var responseBytes: Data?
    /// Total response-body bytes for an oversized stream; positive values enable incremental counting.
    var streamedBytes = 0
    /// Step-1 bytes; nil means Chromium has no favicon for this URL.
    var chromiumResponse: Data?
    /// Step 1 returns only on cancellation, modeling a lost bridge callback. Production
    /// uses withTaskCancellationHandler to guarantee this: ignoring cancellation would
    /// block the task group and drainOnce forever, regardless of outer deadlines.
    var chromiumNeverCompletes = false

    private var inFlight = 0

    func cancelAll() { cancelAllCalls += 1 }

    func chromiumFavicon(profileId: String, pageURL: URL) async -> Data? {
        chromiumLookups += 1
        if chromiumNeverCompletes {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return nil
        }
        return chromiumResponse
    }

    func networkFavicon(at url: URL) async throws -> Data {
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        defer { inFlight -= 1 }

        // Filter each hop before requesting; rejected hops never enter requests.
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
            // Deliberately omit a fake stream limit to model a fetcher failing to stop in time.
            // This tests the queue's real accepts fallback, not a fake-loop constant. Production
            // readBounded streaming enforcement needs a URLProtocol fixture outside this task's scope.
            bytesActuallyRead = streamedBytes
            return Data(count: streamedBytes)
        }
        return responseBytes ?? validPNGBytes()
    }
}

/// Capture the backfill diagnostic line for CASE 10.12.
@MainActor
final class CapturingLogSink: PhiFaviconLogSink {
    private(set) var lines: [String] = []

    func record(_ line: String) { lines.append(line) }
}

/// A 16×16 PNG that NSImage can decode. Use NSBitmapImageRep instead of lockFocus,
/// which requires the main thread and a drawing context; the fixture only needs valid PNG bytes.
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

// MARK: - Tests

@MainActor
final class PhiFaviconBackfillQueueTests: XCTestCase {

    // MARK: Test support

    private struct Harness {
        var queue: PhiFaviconBackfillQueue
        var fetcher: RecordingFetcher
        var access: FakeBookmarkAccess
        var sink: CapturingLogSink
    }

    /// Default gate always allows processing: false means this row should not use
    /// the default icon. Only CASE 10.10 may skip silently at step 0.
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

    // MARK: CASE 10.1: Process at most 20 entries per round; defer the rest

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

    // MARK: CASE 10.2: Serial execution

    func testFetchesRunOneAtATime() async {
        let harness = makeHarness()
        harness.queue.enqueue(rows((0..<5).map { "https://h\($0).example/page" }))

        _ = await harness.queue.drainOnce()

        let concurrent = harness.fetcher.maxConcurrent
        XCTAssertEqual(concurrent, 1)
    }

    // MARK: CASE 10.3: At most one retry after failure

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

    // MARK: CASE 10.4: Timeouts count as failed and write nothing

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

    // MARK: CASE 10.5: Filtered hosts make zero network calls

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

    // MARK: CASE 10.6: Recheck the filter at every redirect hop

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

    // MARK: CASE 10.7: Stop after three redirects

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

    // MARK: CASE 10.8: Queue fallback rejects oversized responses

    /// Assert production behavior: even if the fetcher returns the full 1 MB instead
    /// of stopping midstream, the queue's accepts gate rejects it. The limit is shared
    /// with production streaming reads, so this also fixes the expected bound.
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

    // MARK: CASE 10.9: Reject undecodable bytes

    func testUndecodableBytesAreRejected() async {
        let harness = makeHarness()
        harness.fetcher.responseBytes = Data("<html>404</html>".utf8)
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.succeeded, 0)
        let writes = harness.access.faviconWrites.count
        XCTAssertEqual(writes, 0)
    }

    // MARK: CASE 10.10: Step-0 gate skips both fetch steps

    func testTheDefaultFaviconGateSkipsBothSteps() async {
        let harness = makeHarness(gate: { _ in true })
        harness.queue.enqueue(rows(["https://h0.example/page", "https://h1.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertTrue(harness.fetcher.requests.isEmpty)
        let lookups = harness.fetcher.chromiumLookups
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(result.attempted, 0)
    }

    // MARK: CASE 10.11: One writeback per round

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

    // MARK: CASE 10.12: Log counts without hosts

    func testTheRoundLineCarriesCountsButNoHost() async {
        let harness = makeHarness()
        harness.queue.enqueue(rows(["https://secret-host.example/page"]))

        _ = await harness.queue.drainOnce()

        let lines = harness.sink.lines
        XCTAssertFalse(lines.contains { $0.contains("secret-host") },
                       "R12: a back-fill log line must never carry a host")
        XCTAssertTrue(lines.contains { $0.contains("attempted=") })
    }

    // MARK: §11.3: Diagnostic fields

    /// §11.3 specifies exactly:
    /// [phi-sync] favicon backfill: queued=<n> from_history=<n> from_network=<n> failed=<n> ms=<n>
    /// The history/network split is §8.3's privacy-relevant count: it shows whether
    /// the queue sends any third-party requests.
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

    // MARK: §8.2: A blocked step 1 still reaches step 2 and completes the round

    /// Lost bridge callback. The first effective assertion is that this test returns:
    /// a cancellation-insensitive step 1 blocks the task group, drainOnce, run, and
    /// every later engine round. That manifests as a hang, not a failed assertion.
    func testALostBridgeCallbackFallsThroughToStepTwo() async {
        let harness = makeHarness()
        harness.fetcher.chromiumNeverCompletes = true
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        let result = await harness.queue.drainOnce()

        XCTAssertEqual(result.attempted, 1)
        XCTAssertEqual(result.succeeded, 1, "step 2 must still run and land the icon")
        let requests = harness.fetcher.requests.count
        XCTAssertGreaterThanOrEqual(requests, 1)
        let writes = harness.access.faviconWrites.count
        XCTAssertEqual(writes, 1)
    }

    // MARK: §8.2: Step 1's budget is strictly smaller than the total per-row budget

    /// Without a sub-budget, a consistently slow bridge leaves zero time for step 2:
    /// no request is sent, the row fails, and it is not requeued. Logs show from_network=0,
    /// indistinguishable from finding every icon in local history.
    func testStepOneCannotConsumeTheWholeRowBudget() async {
        XCTAssertLessThan(PhiFaviconBackfillQueue.historyLookupTimeout,
                          PhiFaviconBackfillQueue.perItemTimeout)

        let harness = makeHarness()
        harness.fetcher.chromiumNeverCompletes = true
        harness.queue.enqueue(rows(["https://h0.example/page"]))

        _ = await harness.queue.drainOnce()

        guard let line = harness.sink.lines.first(where: { $0.contains("favicon backfill:") }) else {
            XCTFail("the round must emit the §11.3 diagnostic line")
            return
        }
        XCTAssertTrue(line.contains("from_network=1"),
                      "a stalled step 1 must not starve step 2 out of the row budget")
        XCTAssertTrue(line.contains("from_history=0"))
    }

    // MARK: §8.3: Retirement discards unfinished entries and cancels in-flight requests

    func testStopDiscardsPendingRowsAndCancelsTheFetcher() async {
        let harness = makeHarness()
        harness.queue.enqueue(rows((0..<30).map { "https://h\($0).example/page" }))

        harness.queue.stop()
        let afterStop = await harness.queue.drainOnce()

        XCTAssertEqual(afterStop.attempted, 0)
        XCTAssertEqual(afterStop.succeeded, 0)
        XCTAssertEqual(afterStop.failed, 0)
        // stop returns synchronously; cleanup follows one main-actor hop.
        for _ in 0..<20 { await Task.yield() }
        let cancels = harness.fetcher.cancelAllCalls
        XCTAssertEqual(cancels, 1)
    }
}

// MARK: - Host filter

/// Table-driven tests of PhiFaviconHostFilter.allows. This directly covers the
/// production predicate; CASE 10.5/10.6 use it indirectly for only six hosts.
/// Alternate spellings are critical: expanded IPv6 loopback, hexadecimal IPv4
/// mappings, octal IPv4, and integer IPv4 all resolve to loopback without looking like 127.x.
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

    /// Review identified these four bypass spellings, each resolving to 127.0.0.1.
    func testAlternateIPv4AndIPv6EncodingsAreRejected() {
        check("http://0177.0.0.1/x", false)        // Octal: 0177 = 127
        check("http://2130706433/x", false)        // Decimal integer
        check("http://127.1/x", false)             // Two-part IPv4
        check("http://0x7f.0.0.1/x", false)        // Hexadecimal
        check("http://[::1]/x", false)             // Compressed IPv6 loopback
        check("http://[0:0:0:0:0:0:0:1]/x", false) // Expanded form of the same address
        check("http://[::ffff:7f00:1]/x", false)   // Hexadecimal IPv4-mapped form
        check("http://[fe80::1]/x", false)         // link-local
        check("http://[fd00::1]/x", false)         // unique local
    }

    /// Reject all numeric address literals, including public addresses. Favicon hosts
    /// come from bookmarked page URLs and are expected to be DNS names.
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
